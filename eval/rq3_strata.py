"""RQ3 by writing type: native (kun) writings vs Sino-Japanese (on) writings.

The RQ3 population (all common writings of readings with >= 2 writings)
mixes two kinds of writing.  For a Sino-Japanese word written with its own
character (国史 *kokushi*, 史 = 'history'), the native gloss and the Sinitic
gloss describe the *same borrowed morpheme*, so high similarity is expected
by construction.  The thesis concerns *kun* writings, where a native word was
assigned to a character by meaning.  This script re-runs the paired test per
stratum:

  kun-okurigana  one kanji + kana (測る, 取る)            -> native word
  kun-single     one kanji, reading not an on reading     -> native word
  on-single      one kanji read with one of its on readings, alone (国) or
                 as a Sino-Japanese verb with する/ずる/じる/ぜる (愛する, 感じる)
  compound       two or more kanji (mostly Sino-Japanese), or a
                 reduplication with 々 (人々, 段々)

Kanji are counted as in the Haskell code and universe.py (CJK ideographs incl.
the Supplementary Ideographic Plane, not 々).

Effect sizes: win rate (actual > control), the sign-based effect
(wins - losses) / (wins + losses) (mislabelled "rank-biserial" in reports
before 2026-10-19), and the matched-pairs rank-biserial correlation proper
(Kerby 2014): (sum of positive ranks - sum of negative ranks) / total rank
sum. The one-sided Wilcoxon test is reported as z (normal approximation) and
log10 p, since p itself underflows to 0 at these sample sizes.

    eval/.venv/bin/python eval/rq3_strata.py [--pairs data/eval_pairs.csv]
"""

import argparse
import re
from pathlib import Path

import numpy as np
import pandas as pd
from scipy.stats import norm, rankdata, wilcoxon

from embed import embed, model_name
from universe import is_kanji, sino_verb


def kata_to_hira(s):
    return "".join(chr(ord(c) - 0x60) if "ァ" <= c <= "ヶ" else c for c in s)


def on_readings(kanjidic):
    text = Path(kanjidic).read_text(encoding="utf-8")
    on = {}
    for m in re.finditer(r"<character>.*?</character>", text, re.S):
        c = m.group(0)
        lit = re.search(r"<literal>(.*?)</literal>", c).group(1)
        on[lit] = {kata_to_hira(r) for r in re.findall(r'r_type="ja_on">(.*?)<', c)}
    return on


def stratum(orth, reading, on):
    ks = [c for c in orth if is_kanji(c)]
    if len(ks) >= 2 or "々" in orth:
        return "compound"
    if len(orth) > 1:
        return "on-single" if sino_verb(reading, orth, on) else "kun-okurigana"
    return "on-single" if reading in on.get(orth, set()) else "kun-single"


def stats(piv):
    a, c = piv["actual"].to_numpy(), piv["control"].to_numpy()
    d = a - c
    pos, neg = int((d > 0).sum()), int((d < 0).sum())
    nz = d[d != 0]
    r = rankdata(np.abs(nz))
    rbc = (r[nz > 0].sum() - r[nz < 0].sum()) / r.sum() if len(nz) else 0.0
    if len(d) > 10:
        z = float(wilcoxon(a, c, alternative="greater", method="approx").zstatistic)
        log10p = float(norm.logsf(z) / np.log(10))
    else:
        z = log10p = float("nan")
    return dict(n=len(d), win=pos / len(d), sign_effect=(pos - neg) / (pos + neg),
                rank_biserial=rbc, med_actual=np.median(a), med_control=np.median(c),
                z=z, log10p=log10p)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pairs", default="data/eval_pairs.csv")
    ap.add_argument("--kanjidic", default="data/kanjidic2.xml")
    ap.add_argument("--report", default="data/rq3_strata.md")
    args = ap.parse_args()

    df = pd.read_csv(args.pairs).dropna(subset=["native_gloss", "sinitic_gloss"])
    texts = pd.unique(pd.concat([df.native_gloss, df.sinitic_gloss]))
    V = embed(texts)
    idx = {t: i for i, t in enumerate(texts)}
    df["cos"] = np.sum(V[df.native_gloss.map(idx).to_numpy()] * V[df.sinitic_gloss.map(idx).to_numpy()], axis=1)

    on = on_readings(args.kanjidic)
    act = df[df.kind == "actual"].copy()
    act["stratum"] = [stratum(o, r, on) for o, r in zip(act.orthography, act.reading)]
    df = df.merge(act[["pair_id", "stratum"]], on="pair_id")

    rows = []
    for name, sub in [("all", df)] + [(s, df[df.stratum == s]) for s in
                                       ["kun-okurigana", "kun-single", "on-single", "compound"]]:
        piv = sub.pivot_table(index="pair_id", columns="kind", values="cos").dropna()
        rows.append(dict(stratum=name, **stats(piv)))
    kun = df[df.stratum.isin(["kun-okurigana", "kun-single"])]
    rows.append(dict(stratum="kun (both)", **stats(kun.pivot_table(index="pair_id", columns="kind", values="cos").dropna())))
    out = pd.DataFrame(rows)

    lines = [f"# RQ3 by writing type ({args.pairs}, {model_name()})", "",
             "| stratum | pairs | actual > control | sign effect | rank-biserial | median actual | median control | z (Wilcoxon) | log₁₀ p |",
             "|---|---|---|---|---|---|---|---|---|"]
    for r in out.itertuples():
        lines.append(f"| {r.stratum} | {r.n} | {r.win:.1%} | {r.sign_effect:.3f} | {r.rank_biserial:.3f} | "
                     f"{r.med_actual:.3f} | {r.med_control:.3f} | {r.z:.1f} | {r.log10p:.0f} |")
    text = "\n".join(lines) + "\n"
    Path(args.report).write_text(text, encoding="utf-8")
    print(text)


if __name__ == "__main__":
    main()
