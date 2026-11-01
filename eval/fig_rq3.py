"""Binned similarity distributions (actual vs control) for the article figure.

Writes data/fig_rq3_hist.csv with the share of pairs per cosine bin, for
kun writings and for compounds, actual and control, plus the medians, for a
pgfplots figure (figures/fig_rq3_distribution.tex in the article folder).

    eval/.venv/bin/python eval/fig_rq3.py [--pairs data/eval_pairs.csv]
"""

import argparse
from pathlib import Path

import numpy as np
import pandas as pd

from embed import embed
from rq3_strata import on_readings, stratum

KUN = {"kun-okurigana", "kun-single"}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pairs", default="data/eval_pairs.csv")
    ap.add_argument("--kanjidic", default="data/kanjidic2.xml")
    ap.add_argument("--out", default="data/fig_rq3_hist.csv")
    ap.add_argument("--width", type=float, default=0.05)
    args = ap.parse_args()

    df = pd.read_csv(args.pairs).dropna(subset=["native_gloss", "sinitic_gloss"])
    texts = pd.unique(pd.concat([df.native_gloss, df.sinitic_gloss]))
    V = embed(texts)
    ix = {t: i for i, t in enumerate(texts)}
    df["cos"] = np.sum(V[df.native_gloss.map(ix).to_numpy()] * V[df.sinitic_gloss.map(ix).to_numpy()], axis=1)
    on = on_readings(args.kanjidic)
    act = df[df.kind == "actual"]
    strat = {p: stratum(o, r, on) for p, o, r in zip(act.pair_id, act.orthography, act.reading)}
    df["group"] = ["kun" if strat[p] in KUN else ("compound" if strat[p] == "compound" else "other") for p in df.pair_id]

    edges = np.arange(-0.2, 1.0 + 1e-9, args.width)
    out = pd.DataFrame({"x": edges[:-1]})
    for g in ["kun", "compound"]:
        for kind in ["actual", "control"]:
            v = df[(df.group == g) & (df.kind == kind)].cos.to_numpy()
            h, _ = np.histogram(np.clip(v, edges[0], edges[-1] - 1e-9), bins=edges)
            out[f"{g}_{kind}"] = 100 * h / len(v)
            print(f"{g} {kind}: n={len(v)} median={np.median(v):.3f}")
    # pgfplots 'const plot' needs a closing row
    last = {c: out[c].iloc[-1] for c in out.columns}
    last["x"] = edges[-1]
    out = pd.concat([out, pd.DataFrame([last])], ignore_index=True)
    out.round(3).to_csv(args.out, index=False)
    print(f"wrote {args.out}")


if __name__ == "__main__":
    main()
