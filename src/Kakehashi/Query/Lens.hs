-- | Lens views over the graph (F1–F4, F6 of the functional requirements).
--
--   * F1 'readingLens'   — a reading → its kanji writings, signs, on-readings,
--     native concept, and stored meaning-similarity.
--   * F2 'signLens'      — a sign → its readings, all its Sinitic senses (with
--     source and reading type), and the lexemes written with it.
--   * F3 'conceptLens'   — a gloss query → matching Concepts, the lexemes that
--     mean them, and their signs.
--   * F4 'alignmentLens' — list curated Alignments, or inspect one (basis,
--     period, confidence, sources, native vs Sinitic, disputes).
--   * F6 'okuriganaSplit'/'okuriganaSections' — mark a writing's kanji
--     (concept-bearing) vs kana (grammatical) runs. Pure.
--
-- Each DB lens returns @[Section]@ (title, header, rows of text cells); the CLI
-- renders them. Cypher RETURN aliases are simple; pretty headers are separate.
module Kakehashi.Query.Lens
  ( Section
  , readingLens
  , signLens
  , conceptLens
  , alignmentLens
  , okuriganaSplit
  , okuriganaSections
  ) where

import Data.Char (ord)
import Data.Function (on)
import Data.List (groupBy)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (listToMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Database.Bolt (Pipe, Value (..), queryP, run)
import Numeric (showFFloat)

import Kakehashi.Kanji (isKanji)

-- | (title, column header, rows of cells).
type Section = (Text, [Text], [[Text]])

-- F1 — reading lens ---------------------------------------------------------

readingLens :: Pipe -> Text -> IO [Section]
readingLens pipe r = do
  rows <- table pipe cy (params [("reading", T r)]) qcols
  pure [("Writings of " <> r <> "  (F1 — reading lens)", header, rows)]
  where
    qcols  = ["writing", "sign", "onyomi", "gloss", "sim", "pri"]
    header = ["writing", "sign", "on-reading", "concept (sense 1)", "meaningSim", "priority"]
    cy =
      "MATCH (l:Lexeme {phonology: $reading})-[w:WRITTEN_WITH]->(s:Sign) \
      \OPTIONAL MATCH (l)-[:MEANS]->(c:Concept) \
      \WITH l, w, s, c ORDER BY toInteger(split(c.id, ':')[0]), toInteger(split(c.id, ':')[1]) \
      \WITH l, w, s, head(collect(c.gloss)) AS gloss \
      \OPTIONAL MATCH (s)-[:HAS_READING]->(ro:Reading {type:'on'}) \
      \WITH l, w, s, gloss, collect(DISTINCT ro.value) AS onyomi \
      \RETURN l.orthography AS writing, s.literal AS sign, onyomi AS onyomi, \
      \       gloss AS gloss, w.meaningSim AS sim, l.priority AS pri \
      \ORDER BY sim IS NULL, sim DESC, writing"

-- F2 — sign lens ------------------------------------------------------------

signLens :: Pipe -> Text -> IO [Section]
signLens pipe sg = do
  info <- run pipe (queryP infoCy (params [("sign", T sg)]))
  let kv = case listToMaybe info of
        Nothing -> []
        Just rec ->
          [ [lbl, cell (Map.lookup k rec)]
          | (lbl, k) <- [ ("literal", "sign"), ("strokes", "strokes"), ("jōyō", "joyo")
                        , ("on", "ons"), ("kun", "kuns") ] ]
  senses <- table pipe sensesCy (params [("sign", T sg)]) ["source", "reading", "gloss", "via"]
  lexes  <- table pipe lexCy (params [("sign", T sg)]) lqcols
  pure
    [ ("Sign " <> sg <> "  (F2 — sign lens)", ["property", "value"], kv)
    , ("Sinitic senses of " <> sg, ["source", "reading", "gloss", "via kyūjitai"], senses)
    , ("Lexemes written with " <> sg <> " (top 50 by meaningSim)", lheader, lexes)
    ]
  where
    infoCy =
      "MATCH (s:Sign {literal: $sign}) \
      \OPTIONAL MATCH (s)-[:HAS_READING]->(ro:Reading {type:'on'}) \
      \WITH s, collect(DISTINCT ro.value) AS ons \
      \OPTIONAL MATCH (s)-[:HAS_READING]->(rk:Reading {type:'kun'}) \
      \WITH s, ons, collect(DISTINCT rk.value) AS kuns \
      \RETURN s.literal AS sign, s.strokes AS strokes, s.joyo AS joyo, \
      \       ons AS ons, kuns AS kuns"
    -- Each source gives a different kind of reading: Unihan modern Mandarin,
    -- Baxter–Sagart Old Chinese (plus Middle Chinese), Wiktionary Middle Chinese.
    sensesCy =
      "MATCH (s:Sign {literal: $sign})-[r:HAS_SINITIC_SENSE]->(ss:SiniticSense) \
      \WITH ss, r, CASE WHEN coalesce(ss.reading, '') = '' THEN '—' ELSE ss.reading END AS rd \
      \RETURN ss.source AS source, \
      \       CASE ss.source \
      \         WHEN 'unihan' THEN 'Mandarin ' + rd \
      \         WHEN 'baxter-sagart' THEN 'OC ' + rd + ' · MC ' + coalesce(ss.mc, '—') \
      \         WHEN 'wiktionary' THEN 'MC ' + rd \
      \         ELSE rd END AS reading, \
      \       ss.gloss AS gloss, r.viaKyujitai AS via \
      \ORDER BY source, ss.id"
    lqcols  = ["reading", "writing", "gloss", "sim"]
    lheader = ["reading", "writing", "concept (sense 1)", "meaningSim"]
    lexCy =
      "MATCH (l:Lexeme)-[w:WRITTEN_WITH]->(s:Sign {literal: $sign}) \
      \OPTIONAL MATCH (l)-[:MEANS]->(c:Concept) \
      \WITH l, w, c ORDER BY toInteger(split(c.id, ':')[0]), toInteger(split(c.id, ':')[1]) \
      \WITH l, w, head(collect(c.gloss)) AS gloss \
      \RETURN l.phonology AS reading, l.orthography AS writing, gloss AS gloss, \
      \       w.meaningSim AS sim \
      \ORDER BY sim IS NULL, sim DESC, writing LIMIT 50"

-- F3 — concept lens ---------------------------------------------------------

conceptLens :: Pipe -> Text -> IO [Section]
conceptLens pipe q = do
  rows <- table pipe cy (params [("q", T q)]) qcols
  pure [("Concepts matching \"" <> q <> "\"  (F3 — concept lens)", header, rows)]
  where
    qcols  = ["cid", "gloss", "reading", "writing", "signs"]
    header = ["concept id", "gloss", "reading", "writing", "signs"]
    cy =
      "MATCH (c:Concept) WHERE toLower(c.gloss) CONTAINS toLower($q) \
      \WITH c LIMIT 8 \
      \MATCH (l:Lexeme)-[:MEANS]->(c) \
      \OPTIONAL MATCH (l)-[:WRITTEN_WITH]->(s:Sign) \
      \WITH c, l, collect(DISTINCT s.literal) AS signs \
      \RETURN c.id AS cid, c.gloss AS gloss, l.phonology AS reading, \
      \       l.orthography AS writing, signs AS signs \
      \ORDER BY cid, writing"

-- F4 — alignment inspector --------------------------------------------------

alignmentLens :: Pipe -> Maybe Text -> IO [Section]
alignmentLens pipe Nothing = do
  rows <- table pipe cy (params []) qcols
  pure [("Curated alignments  (F4 — alignment inspector)", header, rows)]
  where
    qcols  = ["id", "reading", "writing", "basis", "confidence"]
    header = ["id", "reading", "writing", "basis", "confidence"]
    cy =
      "MATCH (a:Alignment) \
      \OPTIONAL MATCH (a)-[:ALIGNS_LEXEME]->(l:Lexeme) \
      \RETURN a.id AS id, l.phonology AS reading, l.orthography AS writing, \
      \       a.basis AS basis, a.confidence AS confidence \
      \ORDER BY id"
alignmentLens pipe (Just aid) = do
  recs <- run pipe (queryP cy (params [("id", T aid)]))
  pure $ case listToMaybe recs of
    Nothing  -> [("Alignment " <> aid, ["field", "value"], [["(not found)", ""]])]
    Just rec ->
      [ ( "Alignment " <> aid <> "  (F4 — alignment inspector)"
        , ["field", "value"]
        , [ [lbl, cell (Map.lookup k rec)]
          | (lbl, k) <- [ ("writing", "writing"), ("sign", "sign")
                        , ("native concept", "native"), ("Sinitic sense", "sinitic")
                        , ("basis", "basis"), ("period reading", "period")
                        , ("period sense", "periodSense"), ("confidence", "confidence")
                        , ("sources", "sources"), ("notes", "notes")
                        , ("disputes", "disputes") ] ] )
      ]
  where
    cy =
      "MATCH (a:Alignment {id: $id}) \
      \OPTIONAL MATCH (a)-[:ALIGNS_LEXEME]->(l:Lexeme) \
      \OPTIONAL MATCH (a)-[:ALIGNS_SIGN]->(sg:Sign) \
      \OPTIONAL MATCH (a)-[:ALIGNS_CONCEPT]->(c:Concept) \
      \OPTIONAL MATCH (a)-[:ALIGNS_SINITIC]->(ss:SiniticSense) \
      \OPTIONAL MATCH (a)-[:DISPUTES]->(d:Alignment) \
      \RETURN a.basis AS basis, a.period AS period, a.periodSense AS periodSense, \
      \       a.confidence AS confidence, a.sources AS sources, a.notes AS notes, \
      \       l.orthography AS writing, sg.literal AS sign, c.gloss AS native, \
      \       ss.gloss AS sinitic, collect(DISTINCT d.id) AS disputes"

-- F6 — okurigana split (pure) ----------------------------------------------

-- | Split a writing into consecutive runs, flagging each as kanji or kana.
-- e.g. @"取り消す"@ → @[("取",True),("り",False),("消",True),("す",False)]@.
okuriganaSplit :: Text -> [(Text, Bool)]
okuriganaSplit =
  map (\g -> (T.pack g, isKanji (ord (head g))))
    . groupBy ((==) `on` (isKanji . ord))
    . T.unpack

okuriganaSections :: Text -> [Section]
okuriganaSections orth =
  [ ( "Okurigana split: " <> orth <> "  (F6)"
    , ["segment", "role"]
    , [ [seg, if k then "kanji (concept-bearing)" else "kana (grammatical)"]
      | (seg, k) <- okuriganaSplit orth ] )
  ]

-- helpers -------------------------------------------------------------------

params :: [(Text, Value)] -> Map Text Value
params = Map.fromList

table :: Pipe -> Text -> Map Text Value -> [Text] -> IO [[Text]]
table pipe cy ps qcols = do
  recs <- run pipe (queryP cy ps)
  pure [ [ cell (Map.lookup c r) | c <- qcols ] | r <- recs ]

-- | Render a Bolt value as a display cell.
cell :: Maybe Value -> Text
cell Nothing        = ""
cell (Just (T t))   = t
cell (Just (I i))   = T.pack (show i)
cell (Just (F f))   = T.pack (showFFloat (Just 3) f "")
cell (Just (B b))   = if b then "yes" else "no"
cell (Just (L xs))  = T.intercalate "・" (filter (not . T.null) (map (cell . Just) xs))
cell (Just (N _))   = ""
cell (Just _)       = ""
