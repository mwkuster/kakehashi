"""Homophone-by-writing universe (F5) from the raw JMdict file, by subset.

Re-implements the F5 definition of `kakehashi homophones` without Neo4j, so
the counts can be split further:

  * one Lexeme per (reading, kanji writing), honouring re_nokanji / re_restr;
  * search-only forms (kanji forms tagged sK, readings tagged sk) are skipped:
    JMdict keeps them only so that searches find the entry;
  * expressions are skipped: entries whose first sense is tagged exp
    (コーヒーを入れる, 気を付ける), plus those listed in mappings/expressions.tsv
    (目につく, tagged v5k). They are not words, and the verb they
    contain is counted on its own. The first sense decides, since some verbs
    (上がる) have an exp sense further down;
  * a writing's signature = its distinct kanji in order of first occurrence;
  * only kanji writings count (`is_kanji_writing`): forms without kanji are
    dropped, and so are forms with numerals, Latin letters or other symbols
    (１月 beside 一月, Ｘ線), which are not kanji writings of the word;
  * two writings *compete* only if different kanji stand for overlapping
    parts of the reading (`kanji_spans`): 痺れをきらす (痺 = しび) and
    しびれを切らす (切 = き) do not, so a word whose writings differ only in
    which part is written in kana is not a set; 入れる / 淹れる (both い) and
    表す / 現わす (あらわ / あら) do. Inside a run of several kanji the share
    of each kanji is unknown, so a kanji that both runs contain is taken to
    stand for the same part: 挨拶代わり / あいさつ代わり (代 in both) do not
    compete, 会社 / 会者 (社 / 者) do. This holds only for spellings of one
    word (writings of one JMdict entry): 風 / 風邪 and 兄 / 義兄 are two words and
    compete. Kana are matched leniently (katakana,
    ー, the counter ケ/ヶ, dakuten, historical spellings such as 侍ふ); a
    writing that still cannot be aligned competes with every other one;
  * a reading belongs to the universe if >= 2 distinct signatures remain
    among its competing writings.

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


def is_kana(ch):
    """Hiragana (with the small forms and ゕゖ), katakana (with ヵヶ) or ー."""
    return "ぁ" <= ch <= "ゖ" or "ァ" <= ch <= "ヺ" or ch == "ー"


def is_kanji_writing(orth):
    """A kanji writing: at least one kanji, and nothing but kanji, kana and 々."""
    return any(is_kanji(c) for c in orth) and all(is_kanji(c) or is_kana(c) or c == "々" for c in orth)


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


# alignment normalisation (the same table as Kakehashi.Kanji.normKana): ヵヶ → か,
# historical を ゐ ゑ → お い え, ぢ づ as じ ず, ゔ → う, dakuten / handakuten removed
NORM = str.maketrans("ゕゖをゐゑゔがぎぐげござじずぜぞだぢづでどばびぶべぼぱぴぷぺぽ",
                     "かかおいえうかきくけこさしすせそたしすてとはひふへほはひふへほ")
H_ROW = dict(zip("はひふへほ", "わいうえお"))


def norm_kana(s):
    return kata_to_hira(s).translate(NORM)


def kana_pattern(ch, medial):
    """Regex for one kana of a writing against the normalised reading: ー stands for
    any vowel (ヒコーキ ひこうき), the counter ケ for か (一ケ月), and a medial h-row
    kana also for its modern w-row value (侍ふ さぶらう)."""
    n = norm_kana(ch)
    if n == "ー":
        return "[あいうえおぁぃぅぇぉー]"
    alts = {n}
    if ch == "ケ":
        alts.add("か")
    if medial and n in H_ROW:
        alts.add(H_ROW[n])
    return re.escape(n) if len(alts) == 1 else "[" + "".join(sorted(alts)) + "]"


# further expressions that JMdict does not tag exp (目につく), shared with the Haskell ingest
EXPRESSIONS_FILE = Path(__file__).resolve().parent.parent / "mappings" / "expressions.tsv"


def load_expression_list(path=EXPRESSIONS_FILE):
    """ent_seq numbers from the first column of mappings/expressions.tsv."""
    return {line.split("\t")[0].strip() for line in Path(path).read_text(encoding="utf-8").splitlines()
            if line.strip() and not line.lstrip().startswith("#")}


def is_expression(entry, extra=frozenset()):
    """Is a JMdict entry an expression: is its first sense tagged exp, or is it listed?"""
    seq = re.search(r"<ent_seq>(\d+)</ent_seq>", entry)
    if seq and seq.group(1) in extra:
        return True
    s = re.search(r"<sense>(.*?)</sense>", entry, re.S)
    return bool(s) and "<pos>&exp;</pos>" in s.group(1)


def load_lexemes(path, expressions=False):
    """(reading, orthography, pos set, common?, kanji-form tags, ent_seq) per (reading x
    kanji writing) and entry. Expression entries are skipped unless expressions=True."""
    text = Path(path).read_text(encoding="utf-8")
    extra = load_expression_list()
    out = []
    for e in re.findall(r"<entry>.*?</entry>", text, re.S):
        if not expressions and is_expression(e, extra):
            continue
        kebs = []
        for ke in re.findall(r"<k_ele>(.*?)</k_ele>", e, re.S):
            inf = set(re.findall(r"<ke_inf>&(.*?);</ke_inf>", ke))
            if "sK" in inf:                      # search-only kanji form
                continue
            keb = re.search(r"<keb>(.*?)</keb>", ke).group(1)
            kebs.append((keb, "<ke_pri>" in ke, inf))
        pos = set(re.findall(r"<pos>&(.*?);</pos>", e))
        seq = re.search(r"<ent_seq>(\d+)</ent_seq>", e).group(1)
        for re_ in re.findall(r"<r_ele>(.*?)</r_ele>", e, re.S):
            reb = re.search(r"<reb>(.*?)</reb>", re_).group(1)
            if "<re_nokanji" in re_ or "<re_inf>&sk;</re_inf>" in re_:   # search-only reading
                continue
            restr = re.findall(r"<re_restr>(.*?)</re_restr>", re_)
            for keb, pri, inf in kebs:
                if restr and keb not in restr:
                    continue
                out.append((reb, keb, pos, pri, inf, seq))
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


def kanji_spans(reb, orth):
    """Align a writing with its reading: [(kanji run, start, end)] in the reading
    (kana normalised, `norm_kana`), or None if the kana of the writing do not
    match the reading. Each run of kanji takes the shortest stretch of the
    reading that lets the rest match (leftmost-shortest, as `.+?`); 々 continues
    the kanji run before it (人々 is one run)."""
    runs = []
    for ch in orth:
        k = is_kanji(ch) or (ch == "々" and bool(runs) and runs[-1][0])
        if runs and runs[-1][0] == k:
            runs[-1][1] += ch
        else:
            runs.append([k, ch])
    parts, pos = [], 0
    for k, s in runs:
        parts.append("(.+?)" if k else "".join(kana_pattern(c, pos + j > 0) for j, c in enumerate(s)))
        pos += len(s)
    m = re.fullmatch("".join(parts), norm_kana(reb))
    if not m:
        return None
    kruns = [s for k, s in runs if k]
    return [(s, m.start(i + 1), m.end(i + 1)) for i, s in enumerate(kruns)]


def kanji_set(run):
    return {c for c in run if is_kanji(c)}


def compete(sa, sb, same_word=True):
    """Do two writings (their kanji_spans) put different kanji on overlapping
    parts of the reading? For two spellings of one word (`same_word`: they share a
    JMdict entry), runs whose kanji sets are nested do not compete: a shared kanji
    stands for the same part (相づち / 相槌). Two different words always compete on
    different kanji (風 / 風邪, 兄 / 義兄). An unaligned writing (None) competes."""
    if sa is None or sb is None:
        return True
    def nested(ka, kb):
        return kanji_set(ka) <= kanji_set(kb) or kanji_set(kb) <= kanji_set(ka)
    return any(s1 < e2 and s2 < e1 and kanji_set(ka) != kanji_set(kb) and not (same_word and nested(ka, kb))
               for ka, s1, e1 in sa for kb, s2, e2 in sb)


def competing(reb, orths, entries=None):
    """The writings of a reading that compete with a writing of another signature.
    `entries`: (reading, writing) -> JMdict entries; without it every pair counts
    as one word."""
    orths = list(orths)
    sp = {o: kanji_spans(reb, o) for o in orths}
    sig = {o: signature(o) for o in orths}
    same = (lambda a, b: True) if entries is None else \
        (lambda a, b: bool(entries.get((reb, a), set()) & entries.get((reb, b), set())))
    return {a for a in orths
            if any(sig[a] != sig[b] and compete(sp[a], sp[b], same(a, b)) for b in orths)}


def entry_map(lexemes):
    """(reading, writing) -> the JMdict entries (ent_seq) that have the pair."""
    m = collections.defaultdict(set)
    for l in lexemes:
        m[(l[0], l[1])].add(l[5])
    return m


def universe(lexemes):
    """reading -> the signatures of its competing writings, for readings with >= 2."""
    orths = collections.defaultdict(set)
    for reb, keb, *_ in lexemes:
        if is_kanji_writing(keb):
            orths[reb].add(keb)
    entries = entry_map(lexemes)
    out = {}
    for r, os in orths.items():
        if len({signature(o) for o in os}) < 2:
            continue
        sigs = {signature(o) for o in competing(r, os, entries)}
        if len(sigs) >= 2:
            out[r] = sigs
    return out


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
    lex_exp = load_lexemes(args.data / "JMdict_e", expressions=True)   # for the comparison
    on, kun = load_readings(args.data / "kanjidic2.xml")

    # conjugation-class tags only (v1, v5r, vk, vz, ...); vt/vi mark transitivity, vs = suru-nouns
    is_verb = lambda pos: any(re.match(r"v(1|2|4|5|k|n|r|z|-unspec)", p) for p in pos)
    is_noun = lambda pos: any(p.startswith("n") for p in pos)
    usual = lambda l: not l[4] & {"oK", "iK", "rK"}   # no outdated / irregular / rare kanji form
    # native-type verb writing: one kanji, not a Sino-Japanese verb (愛する, 感じる)
    single_verb = lambda l: (is_verb(l[2]) and len(signature(l[1])) == 1
                             and not sino_verb(l[0], l[1], on))
    def make_subsets(lex):
        return [
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
    subsets = make_subsets(lex)
    lines = ["# Homophone-by-writing universe (F5, from raw JMdict)", "",
             "| subset | readings with ≥ 2 kanji signatures | largest sets |", "|---|---|---|"]
    for name, sub in subsets:
        u = universe(sub)
        top = sorted(u, key=lambda r: -len(u[r]))[:5]
        lines.append(f"| {name} | {len(u):,} | " + ", ".join(f"{r} ({len(u[r])})" for r in top) + " |")
    lines += ["", "Native-type verbs: verb writings with a single kanji, leaving out Sino-Japanese "
              "verbs read as an on reading + する/ずる/じる/ぜる (愛する, 感じる)."]

    # what the two rules remove: the competition rule (sets that differ only in which part
    # is in kana) and the exclusion of expressions (コーヒーを入れる, 気を付ける)
    lines += ["", "The two rules of the set definition, and what they remove. *Competition*: two "
              "writings count as different only if different kanji stand for overlapping parts of "
              "the reading (しびれを切らす / 痺れをきらす do not; 入れる / 淹れる do). *Expressions*: "
              "entries whose first sense is tagged exp (コーヒーを入れる, 気を付ける) are left out.", "",
              "| subset | signatures only | + competition | + no expressions (= above) |",
              "|---|---|---|---|"]
    final = dict(subsets)
    for name, sub in make_subsets(lex_exp):
        sigs = collections.defaultdict(set)
        for reb, keb, *_ in sub:
            if is_kanji_writing(keb):
                sigs[reb].add(signature(keb))
        before = sum(len(s) >= 2 for s in sigs.values())
        lines.append(f"| {name} | {before:,} | {len(universe(sub)):,} | {len(universe(final[name])):,} |")
    kanji_writings = [(reb, keb) for reb, keb, *_ in lex if is_kanji_writing(keb)]
    unaligned = sum(kanji_spans(reb, keb) is None for reb, keb in kanji_writings)
    not_writings = sum(1 for l in lex if signature(l[1]) and not is_kanji_writing(l[1]))
    lines += ["", f"Kanji writings that cannot be aligned with their reading (kept, as competing): "
              f"{unaligned:,} of {len(kanji_writings):,}. Forms with kanji that are not kanji writings "
              f"(numerals, Latin letters, symbols; left out): {not_writings:,}."]

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
