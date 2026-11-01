"""Gloss circularity check: does the RQ3 signal survive without shared words?

If JMdict glossers wrote 'consult' for 諮る because 諮 means 'consult', native
and Sinitic glosses would often share an English content word, and the
similarity test would partly measure lexicographic copying.  This script
reports, per source and stratum, how often actual and control pairs share a
content word, and the win rate (actual > control) after excluding every pair
in which either side shares a word.

    eval/.venv/bin/python eval/rq3_overlap.py [--data data]
"""

import argparse
import re
from pathlib import Path

import numpy as np
import pandas as pd

from embed import embed
from rq3_strata import on_readings, stratum

STOP = set("a an the to of in on at by for with from and or as be is are been one's oneself "
           "something someone etc up out off into over about".split())


def words(gloss):
    return {w for w in re.findall(r"[a-z]+", gloss.lower()) if w not in STOP and len(w) > 2}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", default="data", type=Path)
    ap.add_argument("--report", default=None, type=Path)
    args = ap.parse_args()
    on = on_readings(args.data / "kanjidic2.xml")
    lines = ["# Gloss circularity: shared words and win rates", "",
             "| source | stratum | pairs | actual shares a word | control shares a word | win rate | win rate without shared words (pairs) |",
             "|---|---|---|---|---|---|---|"]
    for name, f in [("Unihan", "eval_pairs.csv"), ("Baxter–Sagart", "eval_pairs_bs.csv"), ("Wiktionary", "eval_pairs_wikt.csv")]:
        df = pd.read_csv(args.data / f).dropna(subset=["native_gloss", "sinitic_gloss"])
        texts = pd.unique(pd.concat([df.native_gloss, df.sinitic_gloss]))
        V = embed(texts)
        ix = {t: i for i, t in enumerate(texts)}
        df["cos"] = np.sum(V[df.native_gloss.map(ix).to_numpy()] * V[df.sinitic_gloss.map(ix).to_numpy()], axis=1)
        df["overlap"] = [float(bool(words(a) & words(b))) for a, b in zip(df.native_gloss, df.sinitic_gloss)]
        act = df[df.kind == "actual"]
        st = {p: stratum(o, r, on) for p, o, r in zip(act.pair_id, act.orthography, act.reading)}
        df["kun"] = df.pair_id.map(lambda p: st[p] in ("kun-okurigana", "kun-single"))
        for label, sub in [("all", df), ("kun", df[df.kun])]:
            piv = sub.pivot_table(index="pair_id", columns="kind", values=["cos", "overlap"]).dropna()
            a_ov = piv[("overlap", "actual")] > 0
            c_ov = piv[("overlap", "control")] > 0
            win = piv[("cos", "actual")] > piv[("cos", "control")]
            keep = ~a_ov & ~c_ov
            lines.append(f"| {name} | {label} | {len(piv)} | {a_ov.mean():.1%} | {c_ov.mean():.1%} | "
                         f"{win.mean():.1%} | {win[keep].mean():.1%} ({int(keep.sum())}) |")
    text = "\n".join(lines) + "\n"
    (args.report or args.data / "rq3_overlap.md").write_text(text, encoding="utf-8")
    print(text)


if __name__ == "__main__":
    main()
