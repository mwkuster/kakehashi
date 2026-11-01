# Data model

kakehashi stores the Japanese writing system as a Neo4j property graph. The
three mappings of a writing system (sign to sound, sign to word, sign to
concept) are edge types over shared nodes. The schema is in `cypher/` and is
applied by `kakehashi init-db`.

## Nodes

| label | key | what it is | populated by |
|---|---|---|---|
| `Sign` | `codepoint` | a kanji, with stroke count, grade, jōyō flag | KANJIDIC2 |
| `Reading` | (value, type) | an *on* or *kun* reading, shared by every character that has it | KANJIDIC2 |
| `Lexeme` | (reading, orthography) | one word in one kanji writing (測る), with POS and JMdict priority; search-only forms are skipped, and a pair listed in several JMdict entries is one Lexeme with the union of their tags | JMdict |
| `Concept` | `entSeq:senseIndex` | one JMdict sense, with its English gloss | JMdict |
| `SiniticSense` | `id` | a Chinese sense and reading of a character, tagged by `source` (`unihan`, `baxter-sagart`, `wiktionary`, …) | Unihan, Baxter–Sagart, any TSV via `ingest sinitic --as NAME` |
| `Alignment` | `id` | a curated judgement that a native lexeme was attached to a sign by meaning, sound or both | `align` (curation TOML) |
| `HomophoneSet` | `reading` | a curated classification of one homophone-by-writing set (single-etymon split, distinct-etymon disambiguation, Old Japanese artefact, mixed) | `align` |

## Edges

| edge | from → to | meaning |
|---|---|---|
| `HAS_READING` | Sign → Reading | sign to sound; for a *kun* reading, `okurigana` lists the character's okurigana splits (圧: おさ.える, お.さえる; `""` = none) |
| `WRITTEN_WITH` | Lexeme → Sign | sign to word; carries `meaningSim` / `simModel` after `sim-load` |
| `MEANS` | Lexeme → Concept | the native meaning |
| `HAS_SINITIC_SENSE` | Sign → SiniticSense | candidate Chinese sense; `viaKyujitai` marks senses reached through the kyūjitai bridge (Unihan variant pairs confirmed by KANJIDIC2, plus `mappings/kyujitai.tsv`) |
| `IMPORTED_FROM` | Concept → SiniticSense | the alignment anchor, set from a curated Alignment |
| `ALIGNS_LEXEME`, `ALIGNS_SIGN`, `ALIGNS_CONCEPT`, `ALIGNS_SINITIC` | Alignment → … | what an Alignment is about |
| `DISPUTES` | Alignment → Alignment | a competing judgement on the same pairing |
| `SET_INCLUDES` | HomophoneSet → Lexeme | members of a classified set |

## The Alignment record

The historical event of attaching a native word to a kanji is reified so it can
carry evidence: `basis` (meaning | sound | both | disputed), `period`,
`periodSense`, `confidence` (0–1), `sources` (citation keys) and `notes`.

Disagreement is encoded, not resolved. Contested alignments are stored as
competing `Alignment` records joined by `:DISPUTES`. `align` does not overwrite
an existing record that carries a different judgement (nor a stored set
classification): it reports the conflict, and the competing judgement goes into
a new record with its own id and `disputes = "<id>"`. `--replace` overrides
this for corrections. The ids that `curate` generates end in the SiniticSense
id, so each candidate sense of a character has its own alignment.

## Derived, not stored

- **Homophone-by-writing set**: lexemes sharing a reading whose writings differ
  in their distinct kanji. Okurigana variants of one kanji collapse (上がる / 上る
  → 上), and writings without kanji are dropped. はかる ⇒ {測, 計, 図, 謀, 諮, 量}.
- ***on*/*kun* divergence**: the same sign with a native *kun* and a Sinitic *on*
  reading.
