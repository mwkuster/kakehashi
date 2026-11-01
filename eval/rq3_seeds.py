"""Stability of the random-control results across eval-pairs seeds.

`kakehashi eval-pairs --seed N` draws each control at random; the actual
pairs are the same for every seed. This script reads the pair files of
several seeds (`make rq3-seeds`) and reports, per Sinitic source and writing
type, the share of actual pairs that beat their control, for each seed and as
a range. The pool-based and within-set tests (rq3_controls.py) draw nothing at
random and need no such check.

    eval/.venv/bin/python eval/rq3_seeds.py --data data/seeds \
        --sources unihan baxter-sagart wiktionary --seeds 42 1 2 3
"""

import argparse
from pathlib import Path

import numpy as np
import pandas as pd

from embed import embed, model_name
from rq3_strata import on_readings, stratum

GROUPS = [("all", None), ("kun", {"kun-okurigana", "kun-single"}), ("compound", {"compound"})]


def win_rates(df, V, ix, on):
    """Share of actual > control, overall and per writing type, for one pair file."""
    df = df.assign(cos=np.sum(V[df.native_gloss.map(ix).to_numpy()]
                              * V[df.sinitic_gloss.map(ix).to_numpy()], axis=1))
    piv = df.pivot_table(index="pair_id", columns="kind", values="cos").dropna()
    act = df[df.kind == "actual"].set_index("pair_id").loc[piv.index]
    st = np.array([stratum(o, r, on) for o, r in zip(act.orthography, act.reading)])
    win = (piv["actual"] > piv["control"]).to_numpy()
    rates = {g: (win.mean() if members is None else win[np.isin(st, list(members))].mean())
             for g, members in GROUPS}
    rates["n"] = len(win)
    return rates


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", default="data/seeds", type=Path)
    ap.add_argument("--sources", nargs="+", default=["unihan"])
    ap.add_argument("--seeds", nargs="+", type=int, default=[42])
    ap.add_argument("--kanjidic", default="data/kanjidic2.xml")
    ap.add_argument("--report", default="data/rq3_seeds.md", type=Path)
    args = ap.parse_args()

    on = on_readings(args.kanjidic)
    lines = [f"# RQ3: random-control results across seeds ({model_name()})", "",
             "Share of actual pairs that beat their random control. The actual pairs are "
             "the same for every seed; only the controls are redrawn.", ""]
    for src in args.sources:
        frames = {s: pd.read_csv(args.data / f"eval_pairs_{src}_s{s}.csv")
                        .dropna(subset=["native_gloss", "sinitic_gloss"])
                  for s in args.seeds}
        texts = pd.unique(pd.concat([pd.concat([d.native_gloss, d.sinitic_gloss])
                                     for d in frames.values()]))
        V = embed(texts)
        ix = {t: i for i, t in enumerate(texts)}
        res = {s: win_rates(df, V, ix, on) for s, df in frames.items()}

        lines += [f"## {src}", "", "| seed | pairs | all | kun | compound |", "|---|---|---|---|---|"]
        for s in args.seeds:
            r = res[s]
            lines.append(f"| {s} | {r['n']} | {r['all']:.1%} | {r['kun']:.1%} | {r['compound']:.1%} |")
        lines.append("")
        for g, _ in GROUPS:
            v = np.array([res[s][g] for s in args.seeds])
            lines.append(f"- {g}: mean {v.mean():.1%}, range {v.min():.1%}–{v.max():.1%} "
                         f"(sd {v.std(ddof=1):.2%}, {len(v)} seeds)")
        lines.append("")
    text = "\n".join(lines) + "\n"
    args.report.write_text(text, encoding="utf-8")
    print(text)


if __name__ == "__main__":
    main()
