"""RQ3 — are kanji selected for native words by perceived similarity of meaning?

Reads the actual+control gloss-pair dataset exported by
`kakehashi eval-pairs` and tests whether the embedding cosine similarity of the
native concept gloss to the *real* Sinitic source sense beats the similarity to
a *random* (control) Sinitic sense, paired by pair_id.

  actual  = cos( native_gloss , real Sinitic gloss )
  control = cos( native_gloss , random other Sinitic gloss )

H1: actual > control (paired). Tested with a Wilcoxon signed-rank test.

Usage:  python eval/rq3.py [--pairs data/eval_pairs.csv] [--report data/rq3_report.md]
"""
from __future__ import annotations

import argparse

import numpy as np
import pandas as pd
from scipy.stats import rankdata, wilcoxon

from embed import embed, model_name


def main() -> None:
    ap = argparse.ArgumentParser(description="kakehashi RQ3 evaluation")
    ap.add_argument("--pairs", default="data/eval_pairs.csv")
    ap.add_argument("--report", default="data/rq3_report.md")
    ap.add_argument("--scores", default="data/sim_scores.csv",
                    help="actual-pairing cosines for write-back to the graph")
    args = ap.parse_args()

    df = pd.read_csv(args.pairs).dropna(subset=["native_gloss", "sinitic_gloss"])

    # Embed every distinct gloss once, then cosine via dot of normalized vectors.
    texts = pd.unique(pd.concat([df.native_gloss, df.sinitic_gloss]))
    print(f"[rq3] embedding {len(texts)} distinct glosses with {model_name()} ...")
    V = embed(texts)
    idx = {t: i for i, t in enumerate(texts)}
    ni = df.native_gloss.map(idx).to_numpy()
    si = df.sinitic_gloss.map(idx).to_numpy()
    df["cos"] = np.sum(V[ni] * V[si], axis=1)

    piv = (
        df.pivot_table(index="pair_id", columns="kind", values="cos")
        .dropna(subset=["actual", "control"])
    )
    actual, control = piv["actual"].to_numpy(), piv["control"].to_numpy()
    diff = actual - control
    n = len(diff)
    pos, neg = int((diff > 0).sum()), int((diff < 0).sum())
    # Sign-based effect: (wins - losses) / (wins + losses).  Earlier reports
    # mislabelled this as the rank-biserial correlation.
    sign_eff = (pos - neg) / (pos + neg) if (pos + neg) else 0.0
    # Matched-pairs rank-biserial correlation (Kerby 2014): difference of the
    # positive and negative rank sums over the total rank sum (zeros dropped).
    nz = diff[diff != 0]
    ranks = rankdata(np.abs(nz))
    rbc = (ranks[nz > 0].sum() - ranks[nz < 0].sum()) / ranks.sum() if len(nz) else 0.0
    stat, p = wilcoxon(actual, control, alternative="greater")

    report = render_report(args.pairs, n, actual, control, diff, pos, neg, sign_eff, rbc, stat, p, df)
    with open(args.report, "w") as fh:
        fh.write(report)
    print(report)
    print(f"[rq3] wrote {args.report}")

    # Scores for write-back to the graph (actual pairings only): one row per
    # (reading, orthography, sign) WRITTEN_WITH edge with its meaning similarity.
    act = df[df.kind == "actual"].copy()
    act["cosine"] = act["cos"].round(4)
    act["model"] = model_name()
    act[["reading", "orthography", "sign", "cosine", "model"]].to_csv(args.scores, index=False)
    print(f"[rq3] wrote {args.scores} ({len(act)} actual-pairing scores)")


def render_report(pairs_path, n, actual, control, diff, pos, neg, sign_eff, rbc, stat, p, df) -> str:
    lines = [
        "# RQ3 — perceived similarity of meaning (kakehashi)",
        "",
        f"- Source: `{pairs_path}` · model: `{model_name()}` · pairs: **{n}**",
        "- H1 (one-sided): native↔real-Sinitic similarity > native↔random-Sinitic.",
        "",
        "## Result",
        f"- median cosine **actual = {np.median(actual):.3f}** vs "
        f"**control = {np.median(control):.3f}** (Δ median = {np.median(diff):.3f})",
        f"- mean Δ = {diff.mean():.3f}",
        f"- actual > control in **{pos}/{n}** pairs ({100*pos/n:.1f}%); "
        f"control > actual in {neg} ({100*neg/n:.1f}%)",
        f"- Wilcoxon signed-rank (greater): W = {stat:.0f}, **p = {p:.3g}**",
        f"- matched-pairs rank-biserial correlation = **{rbc:.3f}**",
        f"- sign effect (wins − losses) / (wins + losses) = {sign_eff:.3f}",
        "",
        "## Worked-example readings",
        "",
        example_table(df),
        "",
        "## Threats / caveats",
        "- The Sinitic glosses come from the source of the pairs file (Unihan: modern;",
        "  Baxter–Sagart: Old Chinese; Wiktionary: all periods combined). None is dated",
        "  to the borrowing period itself.",
        "- Both glosses are English dictionary glosses — a proxy for meaning, embedded",
        "  monolingually; gloss style/length differences add noise.",
        "- Control = one random other Sinitic gloss (excludes the real one); a single",
        "  draw per pair. Re-run with other `--seed` values (eval-pairs) to check stability.",
        "- Population = the common writings of readings whose common writings form a",
        "  homophone-by-writing set (the phenomenon under study).",
        "",
    ]
    return "\n".join(lines)


def example_table(df: pd.DataFrame, readings=("はかる", "とる", "かく", "きく", "なおす")) -> str:
    rows = ["| reading | writing | kind | sign | cos |", "|---|---|---|---|---|"]
    sub = df[df.reading.isin(readings)].sort_values(["reading", "pair_id", "kind"])
    for _, r in sub.iterrows():
        rows.append(
            f"| {r.reading} | {r.orthography} | {r.kind} | {r.sign} | {r.cos:.3f} |"
        )
    return "\n".join(rows) if len(rows) > 2 else "_(curated example readings not in this sample)_"


if __name__ == "__main__":
    main()
