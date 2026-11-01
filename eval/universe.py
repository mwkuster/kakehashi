"""Homophone-by-writing universe (F5) from the raw JMdict file, by subset.

Re-implements the F5 definition of `kakehashi homophones` without Neo4j, so
the counts can be split further:

  * one Lexeme per (reading, kanji writing), honouring re_nokanji / re_restr;
  * search-only forms (kanji forms tagged sK, readings tagged sk) are skipped:
    JMdict keeps them only so that searches find the entry;
  * a writing's signature = its distinct kanji in order of first occurrence;
  * writings without kanji are dropped;
  * a reading belongs to the universe if it has >= 2 distinct signatures.

Subsets reported: all; common (JMdict ke_pri) writings only; by part of
speech (verbs vs nouns); a sensitivity check without outdated, irregular and
rarely used kanji forms (oK / iK / rK); the raw count of spellings; and
on-type vs kun-type readings (a reading is on-type if every member writing
reads as the concatenation of on readings of its kanji, kun-type if every
member is a single kanji not so segmentable; otherwise mixed).

    python3 eval/universe.py [--data data] [--report data/universe_report.md]
"""

import argparse
import collections
import re
from pathlib import Path


def is_kanji(ch):
    c = ord(ch)
    return (0x4E00 <= c <= 0x9FFF or 0x3400 <= c <= 0x4DBF
            or 0xF900 <= c <= 0xFAFF or 0x20000 <= c <= 0x2FFFF)


def signature(orth):
    seen = []
    for ch in orth:
        if is_kanji(ch) and ch not in seen:
            seen.append(ch)
    return tuple(seen)


SINO_VERB_TAILS = ("する", "ずる", "じる", "ぜる")


def sino_verb(reb, keb, on):
    """Is a one-kanji writing a Sino-Japanese verb: an on reading of the kanji
    followed by する/ずる/じる/ぜる (愛する あいする, 感じる かんじる, 察する さっする)?
    One-mora す forms (期す きす) are not detected, because the same shape occurs
    in native verbs (差す さす)."""
    sig = signature(keb)
    if len(sig) != 1 or not keb.startswith(sig[0]):
        return False
    tail = keb[1:]
    if tail not in SINO_VERB_TAILS or not reb.endswith(tail):
        return False
    stem = reb[: len(reb) - len(tail)]
    return any(stem == o or (o[-1] in "くつちき" and stem == o[:-1] + "っ")
               for o in on.get(sig[0], ()))


VOICE = dict(zip("かきくけこさしすせそたちつてとはひふへほ", "がぎぐげござじずぜぞだぢづでどばびぶべぼ"))
VOICE.update(zip("はひふへほ", "ぱぴぷぺぽ"))


def kata_to_hira(s):
    return "".join(chr(ord(c) - 0x60) if "ァ" <= c <= "ヶ" else c for c in s)


def load_lexemes(path):
    """(reading, orthography, pos set, common?, kanji-form tags) per (reading x kanji writing)."""
    text = Path(path).read_text(encoding="utf-8")
    out = []
    for e in re.findall(r"<entry>.*?</entry>", text, re.S):
        kebs = []
        for ke in re.findall(r"<k_ele>(.*?)</k_ele>", e, re.S):
            inf = set(re.findall(r"<ke_inf>&(.*?);</ke_inf>", ke))
            if "sK" in inf:                      # search-only kanji form
                continue
            keb = re.search(r"<keb>(.*?)</keb>", ke).group(1)
            kebs.append((keb, "<ke_pri>" in ke, inf))
        pos = set(re.findall(r"<pos>&(.*?);</pos>", e))
        for re_ in re.findall(r"<r_ele>(.*?)</r_ele>", e, re.S):
            reb = re.search(r"<reb>(.*?)</reb>", re_).group(1)
            if "<re_nokanji" in re_ or "<re_inf>&sk;</re_inf>" in re_:   # search-only reading
                continue
            restr = re.findall(r"<re_restr>(.*?)</re_restr>", re_)
            for keb, pri, inf in kebs:
                if restr and keb not in restr:
                    continue
                out.append((reb, keb, pos, pri, inf))
    return out


def load_readings(path):
    text = Path(path).read_text(encoding="utf-8")
    on, kun = {}, {}
    for m in re.finditer(r"<character>.*?</character>", text, re.S):
        c = m.group(0)
        lit = re.search(r"<literal>(.*?)</literal>", c).group(1)
        on[lit] = {kata_to_hira(r) for r in re.findall(r'r_type="ja_on">(.*?)<', c)}
        kun[lit] = {r.split(".")[0].strip("-") for r in re.findall(r'r_type="ja_kun">(.*?)<', c)}
    return on, kun


def universe(lexemes):
    sigs = collections.defaultdict(set)
    for reb, keb, *_ in lexemes:
        s = signature(keb)
        if s:
            sigs[reb].add(s)
    return {r: s for r, s in sigs.items() if len(s) >= 2}


def is_on_writing(reb, sig, on):
    """Can reb be segmented as on readings of the kanji in order? (small DP)"""
    def go(i, k):
        if k == len(sig):
            return i == len(reb)
        for o in on.get(sig[k], ()):
            variants = {o}
            if k > 0 and o[0] in VOICE:
                variants.add(VOICE[o[0]] + o[1:])          # rendaku
            if k < len(sig) - 1 and o[-1] in "くつちき":
                variants.add(o[:-1] + "っ")                 # sokuon (学校 がっこう)
            if any(reb.startswith(v, i) and go(i + len(v), k + 1) for v in variants):
                return True
        return False
    return go(0, 0)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", default="data", type=Path)
    ap.add_argument("--report", default=None, type=Path)
    args = ap.parse_args()
    lex = load_lexemes(args.data / "JMdict_e")
    on, kun = load_readings(args.data / "kanjidic2.xml")

    # conjugation-class tags only (v1, v5r, vk, vz, ...); vt/vi mark transitivity, vs = suru-nouns
    is_verb = lambda pos: any(re.match(r"v(1|2|4|5|k|n|r|z|-unspec)", p) for p in pos)
    is_noun = lambda pos: any(p.startswith("n") for p in pos)
    usual = lambda l: not l[4] & {"oK", "iK", "rK"}   # no outdated / irregular / rare kanji form
    # native-type verb writing: one kanji, not a Sino-Japanese verb (愛する, 感じる)
    single_verb = lambda l: (is_verb(l[2]) and len(signature(l[1])) == 1
                             and not sino_verb(l[0], l[1], on))
    subsets = [
        ("all writings", lex),
        ("common writings", [l for l in lex if l[3]]),
        ("verbs (all)", [l for l in lex if is_verb(l[2])]),
        ("verbs (common)", [l for l in lex if is_verb(l[2]) and l[3]]),
        ("nouns (all)", [l for l in lex if is_noun(l[2])]),
        ("native-type verbs (single kanji)", [l for l in lex if single_verb(l)]),
        ("native-type verbs, common", [l for l in lex if single_verb(l) and l[3]]),
        ("all writings, without oK/iK/rK forms", [l for l in lex if usual(l)]),
        ("native-type verbs, without oK/iK/rK forms", [l for l in lex if single_verb(l) and usual(l)]),
    ]
    lines = ["# Homophone-by-writing universe (F5, from raw JMdict)", "",
             "| subset | readings with ≥ 2 kanji signatures | largest sets |", "|---|---|---|"]
    for name, sub in subsets:
        u = universe(sub)
        top = sorted(u, key=lambda r: -len(u[r]))[:5]
        lines.append(f"| {name} | {len(u):,} | " + ", ".join(f"{r} ({len(u[r])})" for r in top) + " |")
    lines += ["", "Native-type verbs: verb writings with a single kanji, leaving out Sino-Japanese "
              "verbs read as an on reading + する/ずる/じる/ぜる (愛する, 感じる)."]

    # raw spellings: readings with >= 2 distinct written forms, before okurigana
    # variants are collapsed and kanji-less forms dropped
    spellings = collections.defaultdict(set)
    for reb, keb, *_ in lex:
        spellings[reb].add(keb)
    raw = sum(len(v) >= 2 for v in spellings.values())
    lines += ["", f"Raw spellings (readings with ≥ 2 distinct written forms, before collapsing "
              f"okurigana variants and dropping kanji-less forms): {raw:,}"]

    # on-type vs kun-type readings in the full universe
    u = universe(lex)
    cls = collections.Counter()
    for reb, sigs in u.items():
        kinds = set()
        for sig in sigs:
            if is_on_writing(reb, sig, on):
                kinds.add("on")
            elif len(sig) == 1:
                kinds.add("kun")
            else:
                kinds.add("other")
        cls["on only" if kinds == {"on"} else "kun only" if kinds == {"kun"} else "mixed"] += 1
    lines += ["", "Full universe by type of writing (on = segmentable into on readings; "
              "kun = single kanji not so segmentable; other = kun/mixed compounds):", ""]
    for k in ["on only", "kun only", "mixed"]:
        lines.append(f"- {k}: {cls[k]:,} ({cls[k] / len(u):.1%})")
    text = "\n".join(lines) + "\n"
    (args.report or args.data / "universe_report.md").write_text(text, encoding="utf-8")
    print(text)


if __name__ == "__main__":
    main()
