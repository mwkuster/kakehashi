"""Historical kana check of the homophone-by-writing universe (F5).

`Kakehashi.OldJapanese` flags only the kō/otsu (甲/乙) vowel distinctions of
eighth-century Old Japanese.  Several later mergers also turned distinct words
into modern homophones after their characters had been assigned:

  * wo/o  (を/お),  wi/i (ゐ/い),  we/e (ゑ/え)            — c. 10th–13th c.
  * medial h > w > zero (ハ行転呼: かへる > かえる)          — c. 11th c.
  * di/zi, du/zu (ぢ/じ, づ/ず, the yotsugana)             — c. 16th–17th c.

This script asks whether these mergers matter for the native-type sets.  It
takes the historical spelling (歴史的仮名遣い) of each writing from the English
Wiktionary (kaikki.org Japanese JSONL, CC BY-SA; head-template arguments
`hhira` / `hist*`), and compares, inside each set of `universe.py`, the
historical spellings of the member writings.

A set is *historically split* if its writings with a known historical spelling
fall into >= 2 different spellings: the modern reading then merges words that
were spelled, and pronounced, differently in Old/Early Middle Japanese.  Such
a set is a class (iii) candidate of the article's typology, like a kō/otsu
pair, but the existing hint does not flag it.

A writing whose Wiktionary entry gives no historical-spelling argument is
taken to be spelled as today only if its reading contains no kana that a
merger could have produced (お い え じ ず anywhere; わ う and the vowel kana
after the first mora).  Otherwise it is *unknown*: many entries simply lack
the argument (遭う, 侵す, 薫る have none, though historically あふ, をかす,
かをる).  A writing with no entry is *unknown* as well.

The same kana test gives a data-free count: the sets a merger-aware hint
would have to flag (column "merger-susceptible").

Also reported: the overlap with the kō/otsu flag, the article's worked
examples, and the RQ3 win rate with and without historically split sets.

    python3 eval/historical_kana.py [--data data] [--report data/historical_kana.md]
"""

import argparse
import collections
import csv
import json
import re
from pathlib import Path

from universe import load_lexemes, load_readings, signature, sino_verb, universe

KO_OTSU = set("きひみぎびけへめげべこそとのよろもごぞど")   # mirrors Kakehashi.OldJapanese


def merger_susceptible(reading):
    """Could a later merger have produced this modern spelling?"""
    return (any(c in "おいえじず" for c in reading)
            or any(c in "わうぁぃぅぇぉ" for c in reading[1:]))
# Hand review (2026-11-07) of every candidate and of all 63 merger-susceptible
# common native-type verb sets.  Genuine later-merger sets, with the evidence:
VERIFIED = {
    "える": "得る える (ア行) vs 彫る ゑる: we/e",
    "おる": "織る おる vs 居る・折る をる: wo/o",
    "たえる": "絶える たゆ (ヤ行) vs 堪える・耐える たふ (ハ行): medial h",
    "いる": "入る・要る・射る・鋳る いる vs 居る・率る ゐる: wi/i (居る not common-tagged)",
    "おす": "押す・推す おす vs 食す をす: wo/o (食す not common-tagged)",
    "いう": "言う いふ vs 結う ゆふ (いう a variant reading of 結う): medial h + iu > yū",
    "ゆう": "結う ゆふ vs 言う いふ (ゆう a variant reading of 言う): medial h + iu > yū",
}
# Candidates rejected on review: Wiktionary lacks the historical spelling of one
# member, which in fact matches the others.
REJECTED = {
    "うえる": "飢える is also うゑる", "おかす": "侵す is also をかす",
    "しずめる": "沈める is also しづめる", "もうける": "設ける is also まうける",
    "おさむ": "修む・収む are also をさむ", "かおる": "薫る is also かをる",
    "きわめる": "究める is also きはめる", "たたえる": "湛える is also たたへる",
    "ついえる": "潰える is also つひえる", "やとう": "傭う is also やとふ", "とおる": "透る is also とほる",
}
WORKED = ["はかる", "とる", "みる", "なおす", "こす", "かく", "きく", "おか", "さける"]


def is_kana(s):
    return bool(s) and all("ぁ" <= c <= "ゖ" or c in "ー" for c in s)


def has_kanji(s):
    return any("一" <= c <= "鿿" or "㐀" <= c <= "䶿" for c in s)


def ruby_reading(form):
    """Reading of a canonical form from its ruby: 会(あ)う -> あう."""
    ruby = form.get("ruby") or []
    out, i, text = [], 0, form.get("form", "")
    for base, rd in ruby:
        j = text.find(base, i)
        if j < 0:
            return None
        out.append(text[i:j]); out.append(rd); i = j + len(base)
    out.append(text[i:])
    r = "".join(out)
    return r if is_kana(r) else None


A_ROW, O_ROW = "あかさたなはまやらわがざだばぱ", "おこそとのほもよろおごぞどぼぽ"


def modernize(h):
    """Modern kana spelling of a historical spelling (the main rules of 現代仮名遣い)."""
    s = h.translate(str.maketrans("をゐゑぢづ", "おいえじず"))
    s = s[:1] + s[1:].translate(str.maketrans("はひふへほ", "わいうえお"))
    out = list(s)
    for i in range(len(out) - 1):                 # a-row + う -> o-row + う (かう > こう)
        if out[i + 1] == "う" and out[i] in A_ROW:
            out[i] = O_ROW[A_ROW.index(out[i])]
    s = "".join(out)
    return s.replace("いう", "ゆう")


def load_historical(path):
    """{(modern reading, kanji writing): (explicit historical spellings, entry exists)}.
    Only historical spellings that modernize to the reading are kept (drops
    variant word forms such as たつとぶ given under とうとぶ)."""
    hist = {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            e = json.loads(line)
            if e.get("lang_code") != "ja" or not e.get("head_templates"):
                continue
            word = e["word"]
            forms = e.get("forms", [])
            for h in e["head_templates"]:
                a = h.get("args", {})
                hs = {v for k, v in a.items()
                      if (k == "hhira" or re.fullmatch(r"hist\d?", k)) and is_kana(v)}
                if is_kana(word):                       # kana-titled entry: kanji in forms
                    reading = word
                    writings = {x["form"] for x in forms
                                if "kanji" in (x.get("tags") or []) and has_kanji(x["form"])}
                else:                                   # kanji-titled entry
                    writings = {word}
                    reading = next((a[k] for k in ("1", "2") if is_kana(a.get(k, ""))), None)
                    if reading is None:
                        canon = next((x for x in forms if "canonical" in (x.get("tags") or [])), None)
                        reading = canon and ruby_reading(canon)
                if not reading:
                    continue
                hs = {x for x in hs if modernize(x) == reading}
                for w in writings:
                    hist.setdefault((reading, w), set()).update(hs)
    return hist


def merger_types(a, b):
    """Which known mergers make the historical spellings a and b both modern-homophonous?"""
    t = set()
    pairs = {("を", "お"): "wo/o", ("ゐ", "い"): "wi/i", ("ゑ", "え"): "we/e",
             ("ぢ", "じ"): "di/zi", ("づ", "ず"): "du/zu"}
    hrow = set("はひふへほ")
    if len(a) == len(b):
        for i, (x, y) in enumerate(zip(a, b)):
            if x == y:
                continue
            k = pairs.get((x, y)) or pairs.get((y, x))
            if k:
                t.add(k)
            elif i > 0 and (x in hrow or y in hrow):
                t.add("medial h (ハ行転呼)")
            else:
                t.add("other")
    else:
        t.add("other (length)")
    return t


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", default="data", type=Path)
    ap.add_argument("--report", default=None, type=Path)
    args = ap.parse_args()
    lex = load_lexemes(args.data / "JMdict_e")
    on, _ = load_readings(args.data / "kanjidic2.xml")
    hist = load_historical(args.data / "kaikki-Japanese.jsonl")
    by_reading_char = collections.defaultdict(set)      # fallback: (reading, first kanji)
    for (r, w), hs in hist.items():
        s = signature(w)
        if len(s) == 1:
            by_reading_char[(r, s[0])] |= hs

    is_verb = lambda pos: any(re.match(r"v(1|2|4|5|k|n|r|z|-unspec)", p) for p in pos)
    usual = lambda l: not l[4] & {"oK", "iK", "rK"}
    single_verb = lambda l: (is_verb(l[2]) and len(signature(l[1])) == 1
                             and not sino_verb(l[0], l[1], on))
    nv = [l for l in lex if single_verb(l)]
    subsets = [
        ("native-type verbs", nv),
        ("native-type verbs, common", [l for l in nv if l[3]]),
        ("native-type verbs, without oK/iK/rK", [l for l in nv if usual(l)]),
    ]

    def hist_of(reb, keb):
        """Historical spellings of a writing: explicit ones; else {reb} marked as
        assumed ("=") if a Wiktionary entry exists; None if no entry."""
        hs = hist.get((reb, keb))
        if hs is None and len(signature(keb)) == 1:
            hs = by_reading_char.get((reb, signature(keb)[0]))
        if hs is None:
            return None
        return set(hs) if hs else {"=" + reb}

    def analyse_set(reb, members):
        """members: {signature: [orthographies]} -> (status, groups, types)."""
        groups = collections.defaultdict(set)          # historical spelling -> signatures
        unknown = []
        for sig, orths in members.items():
            hs = set()
            for o in orths:
                hs |= hist_of(reb, o) or set()
            if not hs:
                unknown.append(sig)
            for h in hs:
                groups[h].add(sig)
        merged = collections.defaultdict(set)
        for h, sigs in groups.items():
            merged[h.lstrip("=")] |= sigs
        if len(merged) >= 2:
            spellings = sorted(merged)
            types = set()
            for i, a in enumerate(spellings):
                for b in spellings[i + 1:]:
                    types |= merger_types(a, b)
            return "candidate", groups, types, unknown
        if not groups:
            return "unknown", groups, set(), unknown
        explicit = any(not h.startswith("=") for h in groups)
        return ("uniform" if explicit and not unknown else "uniform-partial"), groups, set(), unknown

    out = ["# Historical kana check of the homophone-by-writing universe", "",
           "Generated by `eval/historical_kana.py`. Historical spellings from the English "
           "Wiktionary (kaikki.org Japanese JSONL). *candidate* = at least one writing has an explicit "
           "historical spelling that differs from the (explicit or assumed) spelling of another writing: "
           "a possible merger, to be checked by hand; *uniform* = all writings found, at least one with an "
           "explicit historical spelling, no difference; *uniform-partial* = no difference, but some writings "
           "not found or only assumed; *unknown* = no writing found. In the tables, `=x` marks an assumed "
           "spelling (entry without historical-spelling argument).", ""]
    split_readings = {}
    for name, ls in subsets:
        sets = universe(ls)
        members = collections.defaultdict(lambda: collections.defaultdict(list))
        for reb, keb, *_ in ls:
            if reb in sets:
                members[reb][signature(keb)].append(keb)
        stat = collections.Counter(); types = collections.Counter(); ko = collections.Counter()
        susc = sum(merger_susceptible(r) for r in sets)
        either = sum(merger_susceptible(r) or any(c in KO_OTSU for c in r) for r in sets)
        rows = []
        for reb in sorted(sets):
            st, groups, ty, unk = analyse_set(reb, members[reb])
            stat[st] += 1
            flagged = any(c in KO_OTSU for c in reb)
            ko[(st, flagged)] += 1
            for t in ty:
                types[t] += 1
            if st == "candidate":
                rows.append((reb, len(sets[reb]), groups, ty, flagged))
                if name == "native-type verbs, common":
                    split_readings[reb] = groups
                if name == "native-type verbs":
                    split_readings.setdefault(("all", reb), groups)
        n = len(sets)
        out += [f"## {name}: {n} sets", "",
                "| status | sets | share | of which kō/otsu-flagged |", "|---|---|---|---|"]
        for st in ("uniform", "uniform-partial", "candidate", "unknown"):
            out.append(f"| {st} | {stat[st]} | {stat[st] / n:.1%} | {ko[(st, True)]} |")
        flagged_total = sum(v for (s, f), v in ko.items() if f)
        out += ["", f"kō/otsu-flagged sets in this subset: {flagged_total} ({flagged_total / n:.1%}). "
                f"Historically split sets *not* flagged by the kō/otsu hint: {ko[('candidate', False)]}.", "",
                "Merger types among split sets (a set can show several): "
                + ", ".join(f"{t} {c}" for t, c in types.most_common()) + ".", "",
                f"Merger-susceptible readings (a merger-aware hint would flag them): {susc} ({susc / n:.1%}); "
                f"flagged by kō/otsu or merger hint: {either} ({either / n:.1%}).", ""]
        if True:
            out += ["| reading | set size | historical spellings → kanji | mergers | kō/otsu flag |",
                    "|---|---|---|---|---|"]
            for reb, size, groups, ty, flagged in rows:
                g = "; ".join(f"{h}: {'・'.join(''.join(s) for s in sorted(groups[h]))}" for h in sorted(groups))
                out.append(f"| {reb} | {size} | {g} | {', '.join(sorted(ty))} | {'yes' if flagged else ''} |")
            out.append("")

    # worked examples of the article and the case notes (all single-kanji writings, any POS)
    out += ["## Worked examples", "", "All writings of the reading with one kanji, any part of speech.", "",
            "| reading | writing → historical spelling |", "|---|---|"]
    for reb in WORKED:
        ws = sorted({keb for r, keb, *_ in lex if r == reb and len(signature(keb)) == 1})
        cells = [f"{w} {'/'.join(sorted(hist_of(reb, w))) if hist_of(reb, w) else '?'}" for w in ws]
        out.append(f"| {reb} | {', '.join(cells)} |")
    out.append("")

    # RQ3 robustness: native single-kanji writings in historically split sets vs the rest
    pairs = args.data / "eval_pairs.csv"
    if pairs.exists():
        out += ["## RQ3 by historical status (modern Unihan run)", ""]
        out.append(rq3_split(pairs, set(VERIFIED)))
    out += ["## Hand review", "", "Genuine later-merger sets:", ""]
    out += [f"- **{r}**: {v}" for r, v in VERIFIED.items()]
    out += ["", "Rejected candidates:", ""] + [f"- {r}: {v}" for r, v in REJECTED.items()]
    out += ["", "All 63 merger-susceptible *common* sets were reviewed; apart from える, おる, たえる, "
            "いう and ゆう their writings share one historical spelling. The 274 susceptible sets "
            "outside the common subset were not reviewed beyond the automatic candidates.", ""]
    text = "\n".join(out) + "\n"
    if args.report:
        args.report.write_text(text, encoding="utf-8")
    print(text)


def rq3_split(pairs_csv, split_readings):
    """Win rate (actual > control) of eval pairs, with and without the readings of
    the hand-verified later-merger sets."""
    try:
        import numpy as np
        from embed import embed
    except Exception as exc:               # no venv: skip the RQ3 part
        return f"(skipped: {exc})\n"
    rows = list(csv.DictReader(open(pairs_csv, encoding="utf-8")))
    by_pair = collections.defaultdict(dict)
    for r in rows:
        by_pair[r["pair_id"]][r["kind"]] = r
    texts = sorted({t for r in rows for t in (r["native_gloss"], r["sinitic_gloss"]) if t})
    E = embed(texts); E = E / np.linalg.norm(E, axis=1, keepdims=True)
    idx = {t: i for i, t in enumerate(texts)}
    cos = lambda a, b: float(E[idx[a]] @ E[idx[b]])
    common_split = set(split_readings)
    res = collections.defaultdict(lambda: [0, 0])
    for p in by_pair.values():
        if "actual" not in p or "control" not in p:
            continue
        a, c = p["actual"], p["control"]
        if not (a["native_gloss"] and a["sinitic_gloss"] and c["sinitic_gloss"]):
            continue
        win = cos(a["native_gloss"], a["sinitic_gloss"]) > cos(c["native_gloss"], c["sinitic_gloss"])
        key = "readings of verified merger sets" if a["reading"] in common_split else "without them"
        res[key][0] += win; res[key][1] += 1
        res["all pairs"][0] += win; res["all pairs"][1] += 1
    lines = ["| population | pairs | actual > control |", "|---|---|---|"]
    for k in ("all pairs", "without them", "readings of verified merger sets"):
        w, n = res[k]
        lines.append(f"| {k} | {n} | {w / n:.1%} |" if n else f"| {k} | 0 | – |")
    return "\n".join(lines) + "\n"


if __name__ == "__main__":
    main()
