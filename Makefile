.PHONY: build test neo4j-up neo4j-down init-db ingest ingest-kanjidic ingest-jmdict ingest-unihan ingest-baxter-sagart bridge-kyujitai ingest-wiktionary rq3-wiktionary homophones homophones-paper worksheet curate align eval-pairs rq3-venv rq3 sim-load rq3-period fossil rq3-strata rq3-controls universe native-sets fig-rq3 rq3-overlap rq3-seeds report historical-kana graph-fingerprint clean

build:
	cabal build all

test:
	cabal test

# Container engine: rootless Podman if installed, else Docker. Override with
# `make neo4j-up COMPOSE="docker compose"` (or "podman-compose").
COMPOSE ?= $(shell command -v podman >/dev/null 2>&1 && echo "podman compose" || echo "docker compose")

neo4j-up:
	$(COMPOSE) -f deploy/compose.yaml up -d neo4j

neo4j-down:
	$(COMPOSE) -f deploy/compose.yaml down

init-db:
	cabal run kakehashi -- init-db

ingest: ingest-kanjidic ingest-jmdict ingest-unihan

ingest-kanjidic:
	cabal run kakehashi -- ingest kanjidic data/kanjidic2.xml

ingest-jmdict:
	cabal run kakehashi -- ingest jmdict data/JMdict_e

ingest-unihan:
	cabal run kakehashi -- ingest unihan data/Unihan_Readings.txt

# Period-accurate Sinitic senses. Needs data/baxter_sagart.tsv from
# eval/extract_baxter_sagart.py (user-supplied .xlsx; no redistribution licence).
ingest-baxter-sagart:
	cabal run kakehashi -- ingest baxter-sagart data/baxter_sagart.tsv

# Bridge shinjitai signs to their kyūjitai's Sinitic senses (run after ingesting a source).
bridge-kyujitai:
	cabal run kakehashi -- bridge-kyujitai

# Wiktionary Sinitic senses (open, CC BY-SA; richer + higher coverage than B&S).
# Download the kaikki.org Chinese JSONL to data/kaikki-Chinese.jsonl first.
ingest-wiktionary:
	eval/.venv/bin/python eval/extract_wiktionary.py --jsonl data/kaikki-Chinese.jsonl --out data/wiktionary_sinitic.tsv
	cabal run kakehashi -- ingest sinitic data/wiktionary_sinitic.tsv --as wiktionary

# RQ3 with Wiktionary senses.
rq3-wiktionary:
	cabal run kakehashi -- eval-pairs --source wiktionary --out data/eval_pairs_wikt.csv
	eval/.venv/bin/python eval/rq3.py --pairs data/eval_pairs_wikt.csv \
	  --report data/rq3_report_wikt.md --scores data/sim_scores_wikt.csv

homophones:
	cabal run kakehashi -- homophones

# Paper artefact: common verb homophone-by-writing sets (CSV + LaTeX).
homophones-paper:
	cabal run kakehashi -- homophones --verbs --common \
	  --csv data/homophones_verb_common.csv \
	  --latex data/homophones_verb_common.tex

# Curation artefacts for one reading, e.g. make worksheet READING=はかる
READING ?= はかる
worksheet:
	cabal run kakehashi -- worksheet $(READING) --out data/worksheet_$(READING).md

# TOML curation skeleton (loader input), e.g. make curate READING=はかる
curate:
	cabal run kakehashi -- curate $(READING) --out data/curation_$(READING).toml

# Load a filled curation file, e.g. make align FILE=data/curation_はかる.toml
align:
	cabal run kakehashi -- align $(FILE)

# RQ3 evaluation dataset (actual+control gloss pairs) for the Python evaluator.
eval-pairs:
	cabal run kakehashi -- eval-pairs --out data/eval_pairs.csv

# One-time: create the Python venv for the RQ3 evaluator.
rq3-venv:
	python3 -m venv eval/.venv && eval/.venv/bin/pip install -q -r eval/requirements.txt

# RQ3 evaluation: embed glosses, paired Wilcoxon, write report + scores.
rq3:
	eval/.venv/bin/python eval/rq3.py

# Store the precomputed similarities on WRITTEN_WITH edges (after rq3).
sim-load:
	cabal run kakehashi -- sim-load data/sim_scores.csv

# Period-accurate RQ3 using Baxter–Sagart senses (after ingest-baxter-sagart + bridge).
rq3-period:
	cabal run kakehashi -- eval-pairs --source baxter-sagart --out data/eval_pairs_bs.csv
	eval/.venv/bin/python eval/rq3.py --pairs data/eval_pairs_bs.csv \
	  --report data/rq3_report_bs.md --scores data/sim_scores_bs.csv

# Graph-derived corpus & findings report (Markdown).
report:
	cabal run kakehashi -- report --out data/report.md

clean:
	cabal clean

# Encoding vs decoding ("fossil" hypothesis): gloss readings in the kun network.
# Reads data/kanjidic2.xml, data/JMdict_e, data/baxter_sagart.tsv; stdlib only.
fossil:
	python3 eval/fossil.py --data data --report data/fossil_report.md

# The three RQ3 pair files that the analyses below read. They come from the graph:
# make eval-pairs (Unihan), make rq3-period (Baxter–Sagart), make rq3-wiktionary.
PAIRS = data/eval_pairs.csv data/eval_pairs_bs.csv data/eval_pairs_wikt.csv
$(PAIRS):
	@echo "missing $@: run make eval-pairs, make rq3-period and make rq3-wiktionary first" >&2; exit 1

# RQ3 split by writing type (kun vs on vs compounds), for all three Sinitic sources.
rq3-strata: $(PAIRS)
	eval/.venv/bin/python eval/rq3_strata.py --pairs data/eval_pairs.csv --report data/rq3_strata.md
	eval/.venv/bin/python eval/rq3_strata.py --pairs data/eval_pairs_bs.csv --report data/rq3_strata_bs.md
	eval/.venv/bin/python eval/rq3_strata.py --pairs data/eval_pairs_wikt.csv --report data/rq3_strata_wikt.md

# RQ3 with stronger controls: pool percentiles, jōyō pool, within-set discrimination,
# period re-anchoring (Unihan vs Baxter-Sagart).
rq3-controls: $(PAIRS)
	eval/.venv/bin/python eval/rq3_controls.py --data data --report data/rq3_controls.md

# Homophone-by-writing universe from raw JMdict, split by subset (stdlib only).
universe:
	python3 eval/universe.py --data data --report data/universe_report.md

# The native-type verb sets of the universe, listed set by set (stdlib only).
native-sets:
	python3 eval/native_sets.py --data data --report data/native_sets.md

# Binned actual-vs-control similarity distributions for the article figure.
fig-rq3: data/eval_pairs.csv
	eval/.venv/bin/python eval/fig_rq3.py --pairs data/eval_pairs.csv --out data/fig_rq3_hist.csv

# Gloss circularity check: share of pairs with a shared English word, and the
# RQ3 win rate after excluding them.
rq3-overlap: $(PAIRS)
	eval/.venv/bin/python eval/rq3_overlap.py --data data --report data/rq3_overlap.md

# Stability of the random-control results: the same population with other
# eval-pairs seeds (42 is the default used for the reported run), per source.
SEEDS ?= 42 1 2 3 4 5 6 7 8 9
SEED_SOURCES ?= unihan baxter-sagart wiktionary
rq3-seeds:
	mkdir -p data/seeds
	for src in $(SEED_SOURCES); do \
	  for s in $(SEEDS); do \
	    cabal run -v0 kakehashi -- eval-pairs --source $$src --seed $$s \
	      --out data/seeds/eval_pairs_$${src}_s$$s.csv || exit 1; \
	  done; \
	done
	eval/.venv/bin/python eval/rq3_seeds.py --data data/seeds --sources $(SEED_SOURCES) \
	  --seeds $(SEEDS) --report data/rq3_seeds.md

# Later kana mergers (wo/o, wi/i, we/e, medial h, yotsugana) in the native-type
# verb sets, from Wiktionary historical spellings (data/kaikki-Japanese.jsonl,
# https://kaikki.org/dictionary/Japanese/kaikki.org-dictionary-Japanese.jsonl).
historical-kana: data/eval_pairs.csv
	cd eval && .venv/bin/python historical_kana.py --data ../data --report ../data/historical_kana.md

# Content fingerprint of the graph (every node and relationship, one canonical
# line each, SHA-256 per label and type), for comparing two graphs, e.g. built
# with another driver or Neo4j version: diff the SUMMARY.txt of two runs.
graph-fingerprint:
	python3 eval/graph_fingerprint.py --out data/fingerprint
