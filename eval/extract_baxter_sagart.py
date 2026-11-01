"""Convert the official Baxter–Sagart .xlsx to the TSV kakehashi ingests.

Local processing of a user-downloaded file. The B&S dataset has NO
redistribution license (all rights reserved; free for scholarly use) — keep the
output in data/ (gitignored) and never commit or republish it.

Usage:
  eval/.venv/bin/pip install openpyxl pandas      # one-time
  eval/.venv/bin/python eval/extract_baxter_sagart.py --xlsx BaxterSagartOC....xlsx
  # -> data/baxter_sagart.tsv  (codepoint  zi  py  mc  oc  gloss  gsr)
"""
from __future__ import annotations

import argparse

import pandas as pd


def find(cols, *names):
    low = {c.lower(): c for c in cols}
    for n in names:
        if n in low:
            return low[n]
    return None


def codepoint(zi, uni):
    # Prefer an explicit Unicode column (e.g. "U+5716"); else derive from the glyph.
    if isinstance(uni, str) and uni.upper().startswith("U+"):
        try:
            return int(uni[2:], 16)
        except ValueError:
            pass
    if isinstance(zi, str) and zi:
        return ord(zi[0])
    return None


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--xlsx", required=True)
    ap.add_argument("--out", default="data/baxter_sagart.tsv")
    args = ap.parse_args()

    df = pd.read_excel(args.xlsx, dtype=str).fillna("")
    cols = list(df.columns)
    c_zi    = find(cols, "zi", "字", "character")
    c_py    = find(cols, "py", "pinyin")
    c_mc    = find(cols, "mc", "middle chinese")
    c_oc    = find(cols, "oc", "old chinese")
    c_gloss = find(cols, "gloss")
    c_gsr   = find(cols, "gsr")
    c_uni   = find(cols, "unicode", "code")
    if c_zi is None or c_oc is None:
        raise SystemExit(f"could not locate zi/oc columns in {cols}")

    def cell(row, c):
        return str(row[c]).strip() if c else ""

    rows, kept = [], 0
    for _, r in df.iterrows():
        cp = codepoint(cell(r, c_zi), cell(r, c_uni))
        if cp is None:
            continue
        rows.append("\t".join([str(cp), cell(r, c_zi), cell(r, c_py),
                               cell(r, c_mc), cell(r, c_oc), cell(r, c_gloss),
                               cell(r, c_gsr)]))
        kept += 1

    with open(args.out, "w") as fh:
        fh.write("codepoint\tzi\tpy\tmc\toc\tgloss\tgsr\n")
        fh.write("\n".join(rows) + "\n")
    print(f"[bs] wrote {args.out} ({kept} rows)")


if __name__ == "__main__":
    main()
