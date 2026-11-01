"""Encoding vs decoding ("fossil" hypothesis): gloss readings in the kun network.

Handel (2019, p. 184 n. 22) reads one kanji -> several kun readings as a trace of
*encoding* (native word -> closest character).  The hypothesis tested here is
that the reverse, several kanji -> one kun reading (はかる), is a trace of
*decoding* (Chinese word -> closest native gloss, i.e. kanbun kundoku).

For every (jōyō kanji, kun reading) pair in KANJIDIC2 the script checks whether
JMdict has any written form with that kanji (+ okurigana) and that reading.
Pairs without one are "gloss readings": recorded for the character, never used
to write the word.  Their distribution over the network is reported by pattern
class and degree, together with Baxter–Sagart (Old Chinese) coverage.

Pure standard library; reads the raw data files directly (no Neo4j needed).

    python3 eval/fossil.py [--data data] [--report data/fossil_report.md]
"""

import argparse
import collections
import re
from pathlib import Path

VERB_ENDINGS = "うくぐすつぬぶむる"


def load_written(jmdict):
    """(keb, reb) pairs attested in JMdict, and the subset with a ke_pri tag.

    A reading pairs only with the kanji forms it applies to (re_restr,
    re_nokanji), and search-only forms (kanji forms tagged sK, readings tagged
    sk) do not count as written: JMdict keeps them only for searching.
    """
    written, common = set(), set()
    text = jmdict.read_text(encoding="utf-8")
    for entry in re.findall(r"<entry>.*?</entry>", text, re.S):
        kebs = []
        for k_ele in re.findall(r"<k_ele>(.*?)</k_ele>", entry, re.S):
            if "<ke_inf>&sK;</ke_inf>" in k_ele:
                continue
            kebs.append((re.search(r"<keb>(.*?)</keb>", k_ele).group(1), "<ke_pri>" in k_ele))
        for r_ele in re.findall(r"<r_ele>(.*?)</r_ele>", entry, re.S):
            if "<re_nokanji" in r_ele or "<re_inf>&sk;</re_inf>" in r_ele:
                continue
            reb = re.search(r"<reb>(.*?)</reb>", r_ele).group(1)
            restr = re.findall(r"<re_restr>(.*?)</re_restr>", r_ele)
            for keb, pri in kebs:
                if restr and keb not in restr:
                    continue
                written.add((keb, reb))
                if pri:
                    common.add((keb, reb))
    return written, common


def load_pairs(kanjidic, written, common):
    """(kanji, word, written?, common?) for the kun readings of jōyō kanji, and
    the set of verbs: native words that KANJIDIC2 gives with okurigana (はか.る)
    and that end in -u. (A word's final kana alone would count nouns such as
    夏 なつ or 夜 よる as verbs.)"""
    pairs, verbs = [], set()
    text = kanjidic.read_text(encoding="utf-8")
    for m in re.finditer(r"<character>.*?</character>", text, re.S):
        char = m.group(0)
        literal = re.search(r"<literal>(.*?)</literal>", char).group(1)
        grade = re.findall(r"<grade>(\d+)</grade>", char)
        if not grade or int(grade[0]) > 8:  # jōyō = grades 1–8
            continue
        for kun in re.findall(r'r_type="ja_kun">(.*?)<', char):
            if "-" in kun:  # prefixes / suffixes
                continue
            stem, _, okuri = kun.partition(".")
            word = stem + okuri
            keb = literal + okuri
            pairs.append((literal, word, (keb, word) in written, (keb, word) in common))
            if okuri and word[-1] in VERB_ENDINGS:
                verbs.add(word)
    return pairs, verbs


def load_bs(path):
    chars = set()
    if path.exists():
        for line in path.read_text(encoding="utf-8").splitlines():
            field = line.split("\t", 1)[0]
            if field.isdigit():
                chars.add(chr(int(field)))
    return chars


def pct(a, b):
    return f"{a / b:.1%}" if b else "–"


def report(pairs, bs, verbs):
    is_verb = verbs.__contains__
    out = []
    kun_of = collections.defaultdict(set)
    kanji_of = collections.defaultdict(set)
    for k, w, _, _ in pairs:
        kun_of[k].add(w)
        kanji_of[w].add(k)
    n_kun = {k: len(v) for k, v in kun_of.items()}
    n_kanji = {w: len(v) for w, v in kanji_of.items()}

    out.append("# Encoding vs decoding: gloss readings in the kun network\n")
    out.append(f"Pairs: {len(pairs)} (jōyō kanji × KANJIDIC2 kun readings); "
               f"kanji: {len(kun_of)}; native words: {len(kanji_of)}.\n")

    out.append("## 1. Prevalence of the two patterns\n")
    out.append("| subset | kanji with ≥2 kun (A) | native words with ≥2 kanji (B) |")
    out.append("|---|---|---|")
    for label, pred in [("all", lambda w: True), ("verbs", is_verb),
                        ("non-verbs", lambda w: not is_verb(w))]:
        K = {k: {w for w in ws if pred(w)} for k, ws in kun_of.items()}
        K = {k: ws for k, ws in K.items() if ws}
        W = collections.defaultdict(set)
        for k, ws in K.items():
            for w in ws:
                W[w].add(k)
        a = sum(len(ws) >= 2 for ws in K.values())
        b = sum(len(ks) >= 2 for ks in W.values())
        out.append(f"| {label} | {a} / {len(K)} ({pct(a, len(K))}) | {b} / {len(W)} ({pct(b, len(W))}) |")
    largest_b = sorted((w for w in kanji_of if n_kanji[w] >= 2), key=lambda w: -n_kanji[w])[:10]
    out.append("\nLargest B sets: " + "; ".join(
        f"{w} ({n_kanji[w]}: {''.join(sorted(kanji_of[w]))})" for w in largest_b))
    largest_a = sorted(kun_of, key=lambda k: -n_kun[k])[:8]
    out.append("\nLargest A kanji: " + "; ".join(f"{k} ({n_kun[k]})" for k in largest_a) + "\n")

    def cls(k, w):
        return {(False, False): "1:1", (True, False): "A only",
                (False, True): "B only", (True, True): "A and B"}[(n_kun[k] >= 2, n_kanji[w] >= 2)]

    out.append("## 2. Gloss readings (never written in JMdict) by pattern class\n")
    for label, pred in [("all", lambda w: True), ("verbs", is_verb)]:
        out.append(f"**{label}**\n")
        out.append("| class | pairs | gloss-only | not a common writing | B&S coverage of kanji |")
        out.append("|---|---|---|---|---|")
        t = collections.defaultdict(lambda: [0, 0, 0])
        kanji_in = collections.defaultdict(set)
        for k, w, wr, cm in pairs:
            if not pred(w):
                continue
            c = cls(k, w)
            t[c][0] += 1
            t[c][1] += not wr
            t[c][2] += not cm
            kanji_in[c].add(k)
        for c in ["1:1", "A only", "B only", "A and B"]:
            n, g, nc = t[c]
            ks = kanji_in[c]
            out.append(f"| {c} | {n} | {pct(g, n)} | {pct(nc, n)} | {pct(len(ks & bs), len(ks))} |")
        out.append("")

    out.append("## 3. Verbs: gloss-only share by both degrees\n")
    out.append("Rows: number of kun readings of the kanji; columns: number of kanji of the native word.\n")
    bucket = lambda n: "1" if n == 1 else ("2–3" if n <= 3 else "4+")
    t = collections.defaultdict(lambda: [0, 0])
    for k, w, wr, _ in pairs:
        if is_verb(w):
            cell = t[(bucket(n_kun[k]), bucket(n_kanji[w]))]
            cell[0] += 1
            cell[1] += not wr
    out.append("| kanji \\ word | 1 | 2–3 | 4+ |")
    out.append("|---|---|---|---|")
    for r in ["1", "2–3", "4+"]:
        cells = [f"{pct(t[(r, c)][1], t[(r, c)][0])} ({t[(r, c)][0]})" for c in ["1", "2–3", "4+"]]
        out.append(f"| {r} | " + " | ".join(cells) + " |")

    out.append("\n## 4. Example: はかる\n")
    for k, w, wr, cm in sorted(p for p in pairs if p[1] == "はかる"):
        status = "common writing" if cm else ("written" if wr else "gloss-only")
        out.append(f"- {k}: {status}")
    out.append("")
    return "\n".join(out)


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--data", default="data", type=Path)
    ap.add_argument("--report", default=None, type=Path)
    args = ap.parse_args()
    written, common = load_written(args.data / "JMdict_e")
    pairs, verbs = load_pairs(args.data / "kanjidic2.xml", written, common)
    text = report(pairs, load_bs(args.data / "baxter_sagart.tsv"), verbs)
    out = args.report or args.data / "fossil_report.md"
    out.write_text(text, encoding="utf-8")
    print(text)


if __name__ == "__main__":
    main()
