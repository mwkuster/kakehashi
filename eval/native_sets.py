"""List of the native-type verb sets of the homophone-by-writing universe (F5).

`universe.py` counts the native-type verb sets (1,044 in all, 187 among common
writings, 803 without outdated, irregular and rarely used kanji forms, for the
JMdict snapshot of the article). This script lists them, with the same
selection, so the counts can be looked up set by set:

  * a set = a reading with >= 2 kanji signatures among its verb writings;
  * native-type = each writing uses a single kanji (with okurigana) and is not
    a Sino-Japanese verb (愛する, 感じる);
  * search-only forms are skipped, okurigana variants count once;
  * writings compete only if different kanji stand for overlapping parts of
    the reading (`universe.kanji_spans`), so しびれを切らす / 痺れをきらす is
    not a set; characters that compete with no other writing are left out.

For each character of a set the report gives its writings and the first sense
of the first JMdict entry that has the writing. Common (ke_pri) writings are in
bold; ° marks a character found only in oK / iK / rK forms. The sets are listed
twice: the common ones (common writings only), then all of them by reading.
Nothing is classified: the list mixes the classes (i)-(iii) of the article.

    python3 eval/native_sets.py [--data data] [--report data/native_sets.md]

Standard library only; reads the raw JMdict and KANJIDIC2 files, no database.
"""

import argparse
import collections
import re
from pathlib import Path

from universe import kata_to_hira, load_lexemes, load_readings, signature, sino_verb, universe

GLOSS_WIDTH = 48

# Hepburn-style romanisation, without macrons (long vowels spelled out: とおる tooru)
ROMAJI = dict(zip(
    "あいうえおかきくけこさしすせそたちつてとなにぬねのはひふへほまみむめもやゆよらりるれろわをん"
    "がぎぐげござじずぜぞだぢづでどばびぶべぼぱぴぷぺぽゐゑ",
    "a i u e o ka ki ku ke ko sa shi su se so ta chi tsu te to na ni nu ne no "
    "ha hi fu he ho ma mi mu me mo ya yu yo ra ri ru re ro wa o n "
    "ga gi gu ge go za ji zu ze zo da ji zu de do ba bi bu be bo pa pi pu pe po i e".split()))
SMALL_Y = {"ゃ": "a", "ゅ": "u", "ょ": "o"}

# gojūon rows for the headings of the full list
ROWS = [("あ", "あいうえお"), ("か", "かきくけこがぎぐげご"), ("さ", "さしすせそざじずぜぞ"),
        ("た", "たちつてとだぢづでど"), ("な", "なにぬねの"),
        ("は", "はひふへほばびぶべぼぱぴぷぺぽ"), ("ま", "まみむめも"), ("や", "やゆよ"),
        ("ら", "らりるれろ"), ("わ", "わゐゑをん")]


def romaji(s):
    s = kata_to_hira(s)
    out, i = "", 0
    while i < len(s):
        c, nxt = s[i], s[i + 1] if i + 1 < len(s) else ""
        if c == "っ" and nxt in ROMAJI:
            r = ROMAJI[nxt]
            out += "t" if r.startswith("ch") else r[0]
        elif nxt and nxt in SMALL_Y:
            r = ROMAJI.get(c, c)
            out += r[:-1] + SMALL_Y[nxt] if r[:-1] in ("sh", "ch", "j") else r[:-1] + "y" + SMALL_Y[nxt]
            i += 1
        elif c == "ん" and nxt and ROMAJI.get(nxt, "x")[0] in "aiueoy":
            out += "n'"
        elif c == "ー" and out and out[-1] in "aiueo":
            out += out[-1]
        else:
            out += ROMAJI.get(c, c)
        i += 1
    return out


def first_glosses(path):
    """(reading, kanji writing) -> first-sense gloss of the first entry that has it."""
    text = Path(path).read_text(encoding="utf-8")
    out = {}
    for e in re.findall(r"<entry>.*?</entry>", text, re.S):
        sense = re.search(r"<sense>(.*?)</sense>", e, re.S)
        g = "; ".join(re.findall(r"<gloss>(.*?)</gloss>", sense.group(1))) if sense else ""
        kebs = re.findall(r"<keb>(.*?)</keb>", e)
        for reb in re.findall(r"<reb>(.*?)</reb>", e):
            for keb in kebs:
                out.setdefault((reb, keb), g)
    return out


def source_versions(data):
    head = (data / "JMdict_e").read_text(encoding="utf-8")[:5000]
    jm = re.search(r"JMdict created: ([0-9-]+)", head)
    kd = re.search(r"<database_version>(.*?)</database_version>",
                   (data / "kanjidic2.xml").read_text(encoding="utf-8")[:5000])
    return (jm.group(1) if jm else "?"), (kd.group(1) if kd else "?")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", default="data", type=Path)
    ap.add_argument("--report", default=None, type=Path)
    args = ap.parse_args()
    lex = load_lexemes(args.data / "JMdict_e")
    on, _ = load_readings(args.data / "kanjidic2.xml")
    gloss = first_glosses(args.data / "JMdict_e")

    # the selection of universe.py (main), unchanged
    is_verb = lambda pos: any(re.match(r"v(1|2|4|5|k|n|r|z|-unspec)", p) for p in pos)
    usual = lambda l: not l[4] & {"oK", "iK", "rK"}
    single_verb = lambda l: (is_verb(l[2]) and len(signature(l[1])) == 1
                             and not sino_verb(l[0], l[1], on))
    nv = [l for l in lex if single_verb(l)]
    u_all = universe(nv)
    u_com = universe([l for l in nv if l[3]])
    u_usual = universe([l for l in nv if usual(l)])

    # reading -> kanji -> {writings: [(orth, common)], common, usual, gloss}
    sets = {r: collections.OrderedDict() for r in u_all}
    for reb, keb, pos, pri, inf in nv:
        if reb not in sets or signature(keb) not in u_all[reb]:   # competing writings only
            continue
        d = sets[reb].setdefault(signature(keb)[0],
                                 {"writings": [], "common": False, "usual": False, "gloss": None})
        if keb not in [w for w, _ in d["writings"]]:
            d["writings"].append((keb, pri))
        d["common"] |= pri
        d["usual"] |= not inf & {"oK", "iK", "rK"}
        if d["gloss"] is None:
            d["gloss"] = gloss.get((reb, keb), "")
    for r in u_all:
        assert len(sets[r]) == len(u_all[r]), r

    def cell(reb, common_only=False):
        parts = []
        for k, d in sets[reb].items():
            if common_only and (k,) not in u_com[reb]:
                continue
            ws = [w if common_only else (f"**{w}**" if pri else w)
                  for w, pri in d["writings"] if pri or not common_only]
            g = d["gloss"].replace("|", "/")
            if len(g) > GLOSS_WIDTH:
                g = g[:GLOSS_WIDTH - 2].rstrip("; ,") + "…"
            parts.append(f"{', '.join(ws)}{'' if d['usual'] else '°'} *{g}*")
        return " · ".join(parts)

    jm, kd = source_versions(args.data)
    lines = [
        "# Native-type verb sets of the homophone-by-writing universe", "",
        f"From the raw JMdict_e (created {jm}) and KANJIDIC2 (database {kd}), with the "
        "selection of `universe.py`.", "",
        f"- native-type verb sets: {len(u_all):,}",
        f"- among common writings: {len(u_com):,}",
        f"- without outdated, irregular and rarely used kanji forms (oK/iK/rK): {len(u_usual):,}", "",
        "A set is a reading with at least two different kanji among its verb writings, each "
        "writing using a single kanji with okurigana; Sino-Japanese verbs (愛する, 感じる) and "
        "search-only forms are left out, okurigana variants count once. Writings count as "
        "different only if different kanji stand for overlapping parts of the reading "
        "(しびれを切らす / 痺れをきらす is not a set). Some entries are set "
        "phrases that JMdict tags as verbs (コーヒーを入れる). The list mixes single-word "
        "splits, distinct words and Old Japanese artefacts; nothing is classified.", "",
        "Each character is given with its writings and the first sense of the first JMdict "
        "entry that has the writing. **Bold**: common writing (ke_pri). °: character found only "
        f"in oK/iK/rK forms. ★: set also counted among common writings. Glosses are cut at "
        f"about {GLOSS_WIDTH - 3} characters.", "",
        f"## The {len(u_com)} sets among common writings", "",
        "Common writings only, by number of characters, then by reading.", "",
        "| reading | | n | characters (common writings) |", "|---|---|---|---|",
    ]
    for r in sorted(u_com, key=lambda r: (-len(u_com[r]), r)):
        lines.append(f"| {r} | *{romaji(r)}* | {len(u_com[r])} | {cell(r, common_only=True)} |")

    groups = collections.OrderedDict((h, []) for h, _ in ROWS)
    groups["other"] = []
    for r in sorted(u_all):
        h = next((h for h, chars in ROWS if kata_to_hira(r[0]) in chars), "other")
        groups[h].append(r)
    lines += ["", f"## All {len(u_all):,} sets", "",
              "By reading, grouped by the first kana. n = number of characters in all writings.", "",
              " · ".join(f"{h}行 ({len(rs)})" for h, rs in groups.items() if rs and h != "other")]
    for h, rs in groups.items():
        if not rs:
            continue
        lines += ["", f"### {h}行" if h != "other" else "### other", "",
                  "| reading | | n | ★ | characters and writings |", "|---|---|---|---|---|"]
        for r in rs:
            lines.append(f"| {r} | *{romaji(r)}* | {len(sets[r])} | {'★' if r in u_com else ''} | {cell(r)} |")

    text = "\n".join(lines) + "\n"
    (args.report or args.data / "native_sets.md").write_text(text, encoding="utf-8")
    print(f"native-type verb sets: {len(u_all):,} (common {len(u_com):,}, "
          f"without oK/iK/rK {len(u_usual):,}) -> {args.report or args.data / 'native_sets.md'}")


if __name__ == "__main__":
    main()
