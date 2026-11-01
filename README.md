# kakehashi

[![DOI](https://zenodo.org/badge/DOI/10.5281/zenodo.23863325.svg)](https://doi.org/10.5281/zenodo.23863325)

*kakehashi* (架け橋, "bridge"), or SCM-JP (Sign–Concept Mapper for Japanese),
is a research instrument. It makes the mapping from Japanese kanji to readings,
words and concepts explicit, queryable and testable as a property graph. It
was built for the article *"Writing Systems as Cultural Maps: Semantic
Alignment in Script Transfer"* (Grafematik 2026).

Its central query finds **homophones by writing**: native words that are one
word in speech but several words in writing, such as はかる → 測る 計る 図る 諮る
量る. Each kanji brings a distinction from Chinese that the native word lacked.
The instrument then tests across the whole lexicon whether kanji were chosen
for native words by perceived similarity of meaning (Handel 2019).

## Citing

If you use kakehashi, please cite the archived release (see `CITATION.cff`):

> Küster, Marc Wilhelm (2026). *kakehashi: A Sign–Concept Mapper for Japanese*
> (version 0.1.0.0). Software. Zenodo. https://doi.org/10.5281/zenodo.23863326

Version 0.1.0.0 is the version used for the Grafematik 2026 article. The
concept DOI [10.5281/zenodo.23863325](https://doi.org/10.5281/zenodo.23863325)
always resolves to the latest version.

## Requirements

- GHC 9.6.7 and cabal (the dependency freeze file pins `base-4.18`; with
  [ghcup](https://www.haskell.org/ghcup/): `ghcup install ghc 9.6.7`).
- Docker (or Podman) with compose, for Neo4j **4.4**. The `hasbolt` driver
  speaks Bolt protocol v1–v3. Neo4j 5 dropped Bolt v3, so 4.4 is the newest
  compatible server.
- Python ≥ 3.11 for the evaluator in `eval/` (see `eval/README.md`).

## Quick start

```sh
make neo4j-up        # Neo4j 4.4 in a container, reachable from localhost only
make build
make test            # unit tests of the pure parts
make init-db         # apply cypher/ schema, smoke-test the Bolt round-trip
cabal run kakehashi -- --help
```

The CLI connects to `localhost:7687` as `neo4j` with the password
`changeme-on-first-run`. Set `KAKEHASHI_NEO4J_HOST`, `KAKEHASHI_NEO4J_PORT`,
`KAKEHASHI_NEO4J_USER` or `KAKEHASHI_NEO4J_PASSWORD` to change this; the compose
file uses `KAKEHASHI_NEO4J_PASSWORD` as the initial password of a new database.

## Data

No data are included in this repository. Download the sources into `data/`
(which is git-ignored):

| source | file(s) in `data/` | where to get it | licence |
|---|---|---|---|
| KANJIDIC2 | `kanjidic2.xml` | <http://www.edrdg.org/kanjidic/kanjidic2.xml.gz> (gunzip) | CC BY-SA 4.0 (EDRDG) |
| JMdict, English | `JMdict_e` | <http://ftp.edrdg.org/pub/Nihongo/JMdict_e.gz> (gunzip) | CC BY-SA 4.0 (EDRDG) |
| Unihan | `Unihan_Readings.txt`, `Unihan_Variants.txt` | <https://www.unicode.org/Public/UCD/latest/ucd/Unihan.zip> (unzip) | Unicode License v3 |
| Wiktionary (Chinese) | `kaikki-Chinese.jsonl` | Wiktextract dump at <https://kaikki.org/dictionary/Chinese/> | CC BY-SA 4.0 |
| Baxter–Sagart Old Chinese | `BaxterSagartOC2015-10-13.xlsx` | <https://sites.lsa.umich.edu/ocbaxtersagart/> | **no stated licence** – see below |

The article used KANJIDIC2 and JMdict of 30 May 2026, Unihan 17.0.0, the
Wiktextract dump of 3 June 2026 and Baxter–Sagart v1.1 (file of 2015-10-13).
Later snapshots work but will give slightly different counts.

**Licensing of derived data.** The code is licensed under the GNU GPL v3 or later (`LICENSE`). The data
keep their own licences: anything derived from EDRDG or Wiktionary data must be
shared under CC BY-SA. The Baxter–Sagart dataset has no redistribution licence.
Download it yourself, keep it in `data/`, and do not redistribute it or graph
dumps that contain it. Results that depend on it can be reproduced only by
readers who obtain the file themselves. `mappings/kyujitai.tsv` (a curated list
of shinjitai → kyūjitai pairs that Unihan omits) is original work under the
code's licence (GPL v3 or later).

**Quotations in the tests.** The unit tests (`test/Spec.hs`) quote a few
individual entries as test data: glosses from JMdict and KANJIDIC2 (© EDRDG,
CC BY-SA 4.0), definitions from Unihan (© Unicode, Inc., Unicode License v3),
and three entries of the Baxter–Sagart reconstruction (測, 計, 公; Baxter &
Sagart 2014), quoted for scholarly reference. None of the datasets is included.

## Pipeline

```sh
make init-db
make ingest                   # KANJIDIC2 (first), JMdict, Unihan
make rq3-venv                 # one-time Python venv for eval/

# Chinese-side sources (optional, each adds SiniticSense nodes)
eval/.venv/bin/pip install openpyxl
eval/.venv/bin/python eval/extract_baxter_sagart.py --xlsx data/BaxterSagartOC2015-10-13.xlsx
make ingest-baxter-sagart
make ingest-wiktionary
make bridge-kyujitai          # link shinjitai signs to their kyūjitai's senses

# Queries and exports
make homophones               # F5: homophone-by-writing sets
make homophones-paper         # common verbs (conjugation classes), CSV + LaTeX
cabal run kakehashi -- lens reading はかる
make report                   # graph-derived corpus summary → data/report.md

# Curation (manual step in the middle)
make curate READING=はかる     # TOML skeleton → data/curation_はかる.toml
make align FILE=data/curation_はかる.toml
```

`align` never overwrites a stored judgement that differs from the file; it
reports the conflict instead (`--replace` overrides this).

Scholarly disagreement is stored, not resolved. Contested alignments are
separate `Alignment` records joined by `:DISPUTES`, never overwrites. See
`docs/data-model.md` for the graph schema.

## Reproducing the article

Every number in the article's results section comes from one of these
targets. Outputs land in `data/`.

| result | command | output |
|---|---|---|
| homophone-by-writing universe and its subsets | `make universe` | `universe_report.md` |
| RQ3, modern glosses (Unihan) | `make eval-pairs rq3` | `rq3_report.md` |
| RQ3, Old Chinese glosses (Baxter–Sagart) | `make rq3-period` | `rq3_report_bs.md` |
| RQ3, Wiktionary glosses | `make rq3-wiktionary` | `rq3_report_wikt.md` |
| RQ3 by writing type (*kun* / *on* / compounds) | `make rq3-strata` | `rq3_strata{,_bs,_wikt}.md` |
| RQ3 with pool and within-set controls | `make rq3-controls` | `rq3_controls.md` |
| RQ3 without shared gloss words (circularity check) | `make rq3-overlap` | `rq3_overlap.md` |
| stability of the random controls across seeds | `make rq3-seeds` | `rq3_seeds.md` |
| distribution figure data | `make fig-rq3` | `fig_rq3_hist.csv` |
| encoding vs decoding (gloss readings) | `make fossil` | `fossil_report.md` |

`universe` and `fossil` read the raw files directly and need no database. The
RQ3 targets need the graph (for `eval-pairs`) and the Python venv. Random
control pairs are seeded (`eval-pairs --seed`, default 42), and the Haskell
dependencies are frozen in `cabal.project.freeze`.

## Layout

```
app/Main.hs            CLI (optparse-applicative)
src/Kakehashi/
  Model.hs             Data types (Sign, Reading, Lexeme, Concept, SiniticSense, Alignment)
  Graph.hs             Neo4j (Bolt) client, schema application
  Kanji.hs             Kanji signatures and okurigana handling
  OldJapanese.hs       Old Japanese kō/otsu (上代特殊仮名遣い) susceptibility
  Ingest/              KANJIDIC2, JMdict, Unihan, Baxter–Sagart, generic Sinitic,
                       kyūjitai bridge, curated alignments, similarity scores
  Query/               Homophones, lenses (F1–F6), worksheets, eval pairs, report
  Export/              CSV, LaTeX, Markdown worksheet, TOML curation skeleton
cypher/                Schema (constraints + indexes), applied by init-db
eval/                  Python evaluator and raw-file analyses (see eval/README.md)
mappings/kyujitai.tsv  Curated shinjitai → kyūjitai pairs
deploy/                compose.yaml (Neo4j 4.4)
docs/                  Data model
test/                  hspec test suite
```

## Note on development

AI coding assistants (Claude Code) were heavily used in developing this software and supported the analytics. 
The results reported in the article were checked against the data.

## Licence

Copyright © 2026 Marc Wilhelm Küster.

This program is free software: you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation, either version 3 of the License, or (at your option) any later
version. It is distributed WITHOUT ANY WARRANTY; see `LICENSE` for
the full text. Data sources keep their own licences (see above).
