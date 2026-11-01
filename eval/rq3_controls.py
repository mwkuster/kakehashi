"""RQ3 with stronger controls (answers critique points #4 and #7).

The paired test in rq3.py compares each actual (native gloss, Sinitic gloss)
pair with ONE random control.  This script adds three sharper checks:

A. Pool percentile.  Each actual similarity is ranked against the native
   gloss's similarity to *every* character in a control pool, (a) all
   KANJIDIC2 characters with a gloss in the source, (b) jōyō characters only
   (a frequency-matched pool).  Reported: mean percentile, share above the
   pool median and above the 90th percentile.

B. Within-set discrimination (the strictest matched control).  Inside one
   homophone-by-writing set, does a writing's native gloss fit its OWN
   character better than the other characters of the same set?  Only
   characters whose writings carry a different native gloss are compared, so
   JMdict variants of one lexeme (計る/測る/量る) do not count against each
   other.  Chance = 50%.

C. Period re-anchoring as a prediction.  For pairs scored with both Unihan
   (modern) and Baxter–Sagart (Old Chinese) glosses, compare pool
   percentiles: if modern misses reflect sense drift, they should improve
   under the older senses more than regression to the mean alone explains
   (compared with the change for pairs that were not misses).

    eval/.venv/bin/python eval/rq3_controls.py [--data data]
"""

import argparse
import collections
from pathlib import Path

import numpy as np
import pandas as pd
from scipy.stats import binomtest

from embed import embed, model_name
from rq3_strata import on_readings, stratum

KUN = {"kun-okurigana", "kun-single"}


def kanjidic_chars(path):
    import re
    text = Path(path).read_text(encoding="utf-8")
    chars, joyo = [], set()
    for m in re.finditer(r"<character>.*?</character>", text, re.S):
        c = m.group(0)
        lit = re.search(r"<literal>(.*?)</literal>", c).group(1)
        g = re.findall(r"<grade>(\d+)</grade>", c)
        chars.append(lit)
        if g and int(g[0]) <= 8:
            joyo.add(lit)
    return chars, joyo


def pools(data, chars):
    uni, bs, wk = {}, collections.defaultdict(list), {}
    for line in (data / "Unihan_Readings.txt").read_text(encoding="utf-8").splitlines():
        if "\tkDefinition\t" in line:
            cp, _, d = line.split("\t")
            uni[chr(int(cp[2:], 16))] = d
    for line in (data / "baxter_sagart.tsv").read_text(encoding="utf-8").splitlines():
        f = line.split("\t")
        if f[0].isdigit() and len(f) > 5 and f[5] and f[5] not in bs[chr(int(f[0]))]:
            bs[chr(int(f[0]))].append(f[5])
    for line in (data / "wiktionary_sinitic.tsv").read_text(encoding="utf-8").splitlines():
        f = line.split("\t")
        if f[0].isdigit() and len(f) > 2 and f[2]:
            wk[chr(int(f[0]))] = f[2]
    cs = set(chars)
    return {
        "unihan": {c: g for c, g in uni.items() if c in cs},
        "bs": {c: "; ".join(g) for c, g in bs.items() if c in cs},
        "wikt": {c: g for c, g in wk.items() if c in cs},
    }


def analyse(name, pairs_csv, pool, joyo, on, out):
    df = pd.read_csv(pairs_csv).dropna(subset=["native_gloss", "sinitic_gloss"])
    act = df[df.kind == "actual"].copy()
    act["stratum"] = [stratum(o, r, on) for o, r in zip(act.orthography, act.reading)]

    pool_chars = list(pool)
    natives = list(pd.unique(act.native_gloss))
    texts = list(pd.unique(pd.concat([pd.Series(natives), act.sinitic_gloss, pd.Series([pool[c] for c in pool_chars])])))
    V = embed(texts)
    ix = {t: i for i, t in enumerate(texts)}
    N = V[[ix[t] for t in natives]]
    P = V[[ix[pool[c]] for c in pool_chars]]
    joyo_mask = np.array([c in joyo for c in pool_chars])
    nat_row = {t: i for i, t in enumerate(natives)}
    char_col = {c: i for i, c in enumerate(pool_chars)}

    # A: pool percentiles (excluding the character itself)
    sims_cache = {}
    def sims(native):
        if native not in sims_cache:
            sims_cache[native] = P @ N[nat_row[native]]
        return sims_cache[native]
    act["cos"] = [float(V[ix[n]] @ V[ix[s]]) for n, s in zip(act.native_gloss, act.sinitic_gloss)]
    pa, pj = [], []
    for n, sgn, c in zip(act.native_gloss, act.sign, act.cos):
        s = sims(n)
        keep = np.ones(len(s), bool)
        if sgn in char_col:
            keep[char_col[sgn]] = False
        pa.append(float((s[keep] < c).mean()))
        pj.append(float((s[keep & joyo_mask] < c).mean()))
    act["pct_all"], act["pct_joyo"] = pa, pj

    out.append(f"## {name}: {pairs_csv.name} ({len(act)} actual pairs; pool {len(pool_chars)} chars, jōyō {int(joyo_mask.sum())})\n")
    out.append("### A. Percentile of the actual pair within the control pool\n")
    out.append("| stratum | pairs | mean pct (all) | > median (all) | > 90th (all) | mean pct (jōyō) | > median (jōyō) |")
    out.append("|---|---|---|---|---|---|---|")
    for label, sub in [("all", act), ("kun", act[act.stratum.isin(KUN)]), ("compound", act[act.stratum == "compound"])]:
        out.append(f"| {label} | {len(sub)} | {sub.pct_all.mean():.3f} | {(sub.pct_all > .5).mean():.1%} | "
                   f"{(sub.pct_all > .9).mean():.1%} | {sub.pct_joyo.mean():.3f} | {(sub.pct_joyo > .5).mean():.1%} |")

    # B: within-set discrimination, kun writings only
    kun = act[act.stratum.isin(KUN)]
    wins = losses = ties = 0
    set_scores = []
    for reading, grp in kun.groupby("reading"):
        rows = list(grp.itertuples())
        sw = sl = 0
        for r in rows:
            for o in rows:
                if o.sign == r.sign or o.native_gloss == r.native_gloss:
                    continue
                own = r.cos
                other = float(V[ix[r.native_gloss]] @ V[ix[o.sinitic_gloss]])
                if own > other:
                    wins += 1; sw += 1
                elif own < other:
                    losses += 1; sl += 1
                else:
                    ties += 1
        if sw + sl:
            set_scores.append(sw / (sw + sl))
    n = wins + losses
    bt = binomtest(wins, n, 0.5, alternative="greater") if n else None
    out.append("\n### B. Within-set discrimination (kun writings; own character vs other characters of the same set)\n")
    if n:
        out.append(f"- comparisons: {n} (ties {ties}) in {len(set_scores)} sets; own character fits better in **{wins / n:.1%}** "
                   f"(binomial p = {bt.pvalue:.2g}; comparisons are not independent, see per-set figure)")
        out.append(f"- per set: mean share of wins {np.mean(set_scores):.1%}; sets with a majority of wins {np.mean(np.array(set_scores) > .5):.1%}, "
                   f"exactly half {np.mean(np.array(set_scores) == .5):.1%}")
    out.append("")
    return act


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", default="data", type=Path)
    ap.add_argument("--report", default=None, type=Path)
    args = ap.parse_args()
    chars, joyo = kanjidic_chars(args.data / "kanjidic2.xml")
    on = on_readings(args.data / "kanjidic2.xml")
    P = pools(args.data, chars)
    out = [f"# RQ3 with stronger controls ({model_name()})\n"]
    res = {}
    for name, csv, key in [("Unihan (modern)", "eval_pairs.csv", "unihan"),
                           ("Baxter–Sagart (Old Chinese)", "eval_pairs_bs.csv", "bs"),
                           ("Wiktionary", "eval_pairs_wikt.csv", "wikt")]:
        res[key] = analyse(name, args.data / csv, P[key], joyo, on, out)

    # C: period re-anchoring
    k = ["reading", "orthography", "sign"]
    m = res["unihan"][k + ["pct_all", "stratum"]].merge(res["bs"][k + ["pct_all"]], on=k, suffixes=("_mod", "_oc"))
    out.append("## C. Period re-anchoring: modern (Unihan) vs Old Chinese (Baxter–Sagart) pool percentiles\n")
    out.append("| subset | group (modern) | pairs | mean pct modern | mean pct OC | change | share now > median |")
    out.append("|---|---|---|---|---|---|---|")
    for label, sub in [("all", m), ("kun", m[m.stratum.isin(KUN)])]:
        for g, gs in [("miss (< median)", sub[sub.pct_all_mod < .5]), ("low (median–75th)", sub[(sub.pct_all_mod >= .5) & (sub.pct_all_mod < .75)]),
                      ("high (≥ 75th)", sub[sub.pct_all_mod >= .75])]:
            if len(gs):
                out.append(f"| {label} | {g} | {len(gs)} | {gs.pct_all_mod.mean():.3f} | {gs.pct_all_oc.mean():.3f} | "
                           f"{gs.pct_all_oc.mean() - gs.pct_all_mod.mean():+.3f} | {(gs.pct_all_oc > .5).mean():.1%} |")
    for w in ["計る", "図る", "直す", "治す"]:
        r = m[m.orthography == w]
        if len(r):
            out.append(f"\n{w}: modern pct {r.pct_all_mod.iloc[0]:.3f} → OC pct {r.pct_all_oc.iloc[0]:.3f}")
    text = "\n".join(out) + "\n"
    (args.report or args.data / "rq3_controls.md").write_text(text, encoding="utf-8")
    print(text)


if __name__ == "__main__":
    main()
