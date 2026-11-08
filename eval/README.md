# kakehashi — RQ3 evaluator

Tests the article's claim that **kanji are selected for native words by perceived
similarity of meaning** (Phase 3). Batch, reproducible; no running service.

## Pipeline
1. Export the dataset from the graph (Haskell, system of record):
   ```sh
   make eval-pairs          # -> data/eval_pairs.csv  (actual + control pairs)
   ```
2. Run the evaluator (Python):
   ```sh
   python3 -m venv eval/.venv && eval/.venv/bin/pip install -r eval/requirements.txt
   eval/.venv/bin/python eval/rq3.py        # -> data/rq3_report.md
   ```

## What it does
For each real (native concept gloss ↔ real Sinitic source gloss) pairing it
compares the embedding cosine similarity against a **control** (same native
gloss vs a random other Sinitic gloss), paired by `pair_id`, and runs a
one-sided Wilcoxon signed-rank test (H1: actual > control), reporting median Δ,
win rate, p-value, and a rank-biserial effect size.

## Notes
- **Monolingual on purpose:** both glosses are English (JMdict gloss / Unihan
  `kDefinition`), so MiniLM (`all-MiniLM-L6-v2`) suffices — no LaBSE.
- Embedding lives in `embed.py` (one `embed()` function) so it can be wrapped in
  an HTTP sidecar later for an interactive F7 panel without rewriting.
- Override the model with `KAKEHASHI_EMBED_MODEL=...`.
- Caveat: `kMandarin`/`kDefinition` are modern; curated Baxter–Sagart senses
  (the `align` workflow) will give a period-accurate re-run.

## Encoding vs decoding (`fossil.py`)
Tests whether *several kanji → one kun reading* (はかる) behaves like a trace of
decoding (kanbun kundoku), as opposed to *one kanji → several kun readings*
(Handel 2019, p. 184 n. 22: encoding). For every (jōyō kanji, KANJIDIC2 kun
reading) pair it checks whether JMdict has a written form with that kanji and
reading (search-only forms do not count); pairs without one are *gloss
readings*. Verbs are native words that KANJIDIC2 gives with okurigana and that
end in -u. Reports their share by pattern
class and degree, plus Baxter–Sagart coverage.

```sh
make fossil              # -> data/fossil_report.md (stdlib only, no Neo4j)
```

Result (2026-11-01, search-only forms excluded): gloss readings make up 4.8%
of 1:1 pairs but 25.2% where both kanji and native word are polyvalent (はかる:
6 of 12 kanji gloss-only).
Both degrees contribute, so the *direction* of alignment cannot be inferred
from synchronic data; diachronic attestation would be needed.

## Effect sizes and strata (`rq3_strata.py`)
`rq3.py` reports the matched-pairs rank-biserial correlation (Kerby 2014) and,
separately, the sign effect (wins − losses)/(wins + losses). Reports before
2026-10-19 labelled the sign effect (0.759) as "rank-biserial"; the proper value
is 0.913.

The RQ3 population mixes *kun* writings with Sino-Japanese compounds (87% of
pairs), where native and Sinitic glosses describe the same borrowed morpheme.
`rq3_strata.py` re-runs the paired test per writing type. Sino-Japanese verbs
written with one kanji (愛する, 感じる) count as *on* writings, reduplications with
々 as compounds:

```sh
make rq3-strata          # -> data/rq3_strata{,_bs,_wikt}.md
```

The report gives the Wilcoxon test as z (normal approximation) and log₁₀ p,
since p itself underflows to 0.

Result (2026-11-08, with the competition rule and without expressions): *kun* writings (1,406 pairs) win 93.1% / 89.7% / 94.9% (Unihan / Baxter–Sagart / Wiktionary), rank-biserial 0.968, z = 31.5; compounds 87.8% / 80.6% / 88.4%.

## Stronger controls (`rq3_controls.py`), universe (`universe.py`), figure (`fig_rq3.py`)
- `make rq3-controls` → `data/rq3_controls.md`: (A) each actual pair ranked against
  the native gloss's similarity to every character in the pool (all KANJIDIC2 /
  jōyō only); (B) within-set discrimination: own character vs the other characters
  of the same homophone set (kun writings, chance = 50%); (C) period re-anchoring:
  modern vs Old Chinese pool percentiles, with the regression-to-the-mean caveat.
  Result (2026-11-08, Unihan): kun writings at the 93rd percentile on average; own character wins 86.6% of 1,600 within-set comparisons (359 sets).
- `make universe` → `data/universe_report.md`: F5 universe from raw JMdict,
  search-only forms and expressions excluded, writings compared by which part of the reading their kanji stand for (27,159 readings; 898 native-type verb sets, 187 among common writings; 660 without outdated, irregular and rare forms). The report also gives the counts before the two rules (33,510; 1,044; 803).
  Native-type: single-kanji verb writings, without Sino-Japanese verbs (感じる).
- `make native-sets` → `data/native_sets.md`: the native-type verb sets of
  `universe.py` listed set by set (same selection), each character with its
  writings and first JMdict gloss; common writings in bold, ° for characters
  found only in oK/iK/rK forms, ★ for sets counted among common writings.
- `make fig-rq3` → `data/fig_rq3_hist.csv`, input for the article's pgfplots figure.

## Gloss circularity (`rq3_overlap.py`)
`make rq3-overlap` → `data/rq3_overlap.md`: how often native and Sinitic glosses
share an English content word (actual vs control), and the win rate after
excluding every pair in which either side shares one. Result (2026-11-01, kun
writings): shared word in 57% of actual pairs vs 0.4% of controls (Baxter–Sagart:
48%); without shared words, 84.9% (Unihan, 635 pairs) / 82.9% (B&S, 608) still win.

## Seed stability (`rq3_seeds.py`)
`make rq3-seeds` exports the pairs again with ten `eval-pairs` seeds per Sinitic
source (the actual pairs stay the same; only the random controls change) →
`data/rq3_seeds.md`: the share of actual pairs that beat their control, per seed
and as a range. The pool-based and within-set tests draw nothing at random.
Result (2026-11-08), *kun* writings over ten seeds: 92.0–93.7% (Unihan), 89.0–91.6% (Baxter–Sagart), 94.0–95.4% (Wiktionary); all writings vary by less than one point.

## Later kana mergers (`historical_kana.py`)
`OldJapanese.hs` flags only the kō/otsu syllables of Old Japanese. Later sound
changes also turned distinct words into modern homophones: *wo/o*, *wi/i*,
*we/e*, *h* between vowels (ハ行転呼) and the yotsugana (ぢ/じ, づ/ず).
`historical_kana.py` takes the historical kana spelling (歴史的仮名遣い) of each
writing from the English Wiktionary (`data/kaikki-Japanese.jsonl`, head-template
arguments `hhira` / `hist*`) and compares the spellings inside each native-type
set of `universe.py`:

```sh
make historical-kana     # -> data/historical_kana.md
```

Many Wiktionary entries lack the historical spelling, so the script reports
*candidates*, not decisions. The hand review is recorded in the script
(`VERIFIED`, `REJECTED`). The report also counts the readings that a
merger-aware hint would flag, checks the article's worked examples, and reruns
the RQ3 win rate without the readings of the verified sets.

Result (2026-11-07): of the 187 common native-type sets, 63 contain a syllable
a merger may have produced (72 contain a kō/otsu syllable), but only える (得 /
彫), おる (織 / 居・折) and たえる (絶 / 堪・耐) are genuine later-merger sets, plus
いう / ゆう through variant readings of 言う and 結う. In the full set: 16
candidates, 5 genuine (also いる 入 / 居・率 and おす 押 / 食), 11 rejected. The
worked examples (はかる, とる, みる, なおす, こす, かく, きく) each have one historical
spelling. RQ3 without the verified readings: unchanged (88.4%, 2026-11-08).

## Graph fingerprint (`graph_fingerprint.py`)
`make graph-fingerprint` → `data/fingerprint/`: one file per node label and per
relationship type, with every item as a canonical JSON line (nodes identified by
their natural key), and `SUMMARY.txt` with the count and a SHA-256 per file. The
result depends neither on the driver nor on internal ids or the Neo4j version, so
two graphs compare with `diff A/SUMMARY.txt B/SUMMARY.txt`. Connection settings
come from the `KAKEHASHI_NEO4J_*` variables (HTTP port `KAKEHASHI_NEO4J_HTTP_PORT`,
default 7474). Result (2026-11-02): the graph built with bolty on Neo4j 5.26
equals the one built with hasbolt on Neo4j 4.4 (7 labels, 11 relationship types).
