"""Extract a Sinitic-sense TSV from a kaikki.org (Wiktextract) Chinese JSONL.

For every single Han character it aggregates the English glosses and a Middle
Chinese reading into one row:  codepoint<TAB>reading<TAB>gloss
→ ingest with:  kakehashi ingest sinitic data/wiktionary_sinitic.tsv --as wiktionary

Wiktionary is CC BY-SA (share-alike) — redistributable, unlike Kroll/B&S.

Usage:
  eval/.venv/bin/python eval/extract_wiktionary.py \
    --jsonl data/kaikki-Chinese.jsonl --out data/wiktionary_sinitic.tsv
"""
from __future__ import annotations

import argparse
import json


def is_han(cp: int) -> bool:
    return (
        0x4E00 <= cp <= 0x9FFF
        or 0x3400 <= cp <= 0x4DBF
        or 0xF900 <= cp <= 0xFAFF
        or 0x20000 <= cp <= 0x2FFFF
    )


def clean(text: str) -> str:
    """Tabs and line breaks inside a field would break the TSV row."""
    return text.replace("\t", " ").replace("\r", " ").replace("\n", " ")


def middle_chinese(obj) -> str:
    for s in obj.get("sounds", []):
        tags = s.get("tags", [])
        if any("Middle Chinese" in t for t in tags):
            for k in ("zh-pron", "other", "roman", "ipa"):
                if s.get(k):
                    return str(s[k])
    return ""


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--jsonl", default="data/kaikki-Chinese.jsonl")
    ap.add_argument("--out", default="data/wiktionary_sinitic.tsv")
    ap.add_argument("--max-glosses", type=int, default=6)
    args = ap.parse_args()

    glosses: dict[int, list[str]] = {}
    reading: dict[int, str] = {}

    with open(args.jsonl, encoding="utf-8") as fh:
        for line in fh:
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue
            if obj.get("lang_code") != "zh":
                continue
            w = obj.get("word", "")
            if len(w) != 1 or not is_han(ord(w)):
                continue
            cp = ord(w)
            gl = glosses.setdefault(cp, [])
            for sense in obj.get("senses", []):
                for g in sense.get("glosses", []) or sense.get("raw_glosses", []):
                    g = g.strip()
                    if g and g not in gl:
                        gl.append(g)
            if cp not in reading:
                mc = middle_chinese(obj)
                if mc:
                    reading[cp] = mc

    rows = 0
    with open(args.out, "w", encoding="utf-8") as out:
        out.write("codepoint\treading\tgloss\n")
        for cp in sorted(glosses):
            gl = glosses[cp][: args.max_glosses]
            if not gl:
                continue
            gloss = clean("; ".join(gl))[:300]
            out.write(f"{cp}\t{clean(reading.get(cp, ''))}\t{gloss}\n")
            rows += 1
    print(f"[wikt] wrote {args.out} ({rows} characters)")


if __name__ == "__main__":
    main()
