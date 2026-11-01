{-# LANGUAGE RecordWildCards #-}

-- | Baxter–Sagart Old Chinese ingest (Phase 2 — period-accurate SiniticSense).
--
-- Reads a TSV (codepoint, zi, py, mc, oc, gloss, gsr) produced by
-- @eval/extract_baxter_sagart.py@ from the official B&S dataset, and seeds a
-- __period-accurate__ 'SiniticSense' per matched Sign (Old Chinese
-- reconstruction as reading, B&S gloss, Middle Chinese, GSR), @source='baxter-
-- sagart'@. These sit alongside the modern Unihan candidates.
--
-- Signs are matched by codepoint (B&S keys traditional characters). Japanese
-- shinjitai whose traditional form has a different codepoint (図 U+56F3 vs 圖
-- U+5716) will not match directly; @bridge-kyujitai@ links them, and
-- 'Kakehashi.Query.Eval.sourceCoverage' measures what remains uncovered.
--
-- NB: the B&S dataset has no redistribution license; this reads a
-- user-supplied local file (gitignored) and never republishes it.
module Kakehashi.Ingest.BaxterSagart
  ( BSRow (..)
  , parseRow
  , parseTsv
  , bsId
  , IngestStats (..)
  , ingest
  ) where

import Control.Monad (forM_)
import qualified Data.Map.Strict as Map
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Database.Bolt (Pipe, Value (..), query, queryP, run)
import Text.Read (readMaybe)

data BSRow = BSRow
  { bsCp    :: !Int
  , bsZi    :: !Text
  , bsPy    :: !Text
  , bsMc    :: !Text
  , bsOc    :: !Text
  , bsGloss :: !Text
  , bsGsr   :: !Text
  }
  deriving (Eq, Show)

data IngestStats = IngestStats
  { statRows   :: !Int  -- ^ B&S rows parsed
  , statSigns  :: !Int  -- ^ distinct Signs that received a B&S sense
  }
  deriving (Eq, Show)

-- Parsing (pure) -----------------------------------------------------------

parseTsv :: Text -> [BSRow]
parseTsv = mapMaybe parseRow . drop 1 . T.lines

-- | One TSV row: @codepoint\\tzi\\tpy\\tmc\\toc\\tgloss\\tgsr@ (codepoint decimal).
parseRow :: Text -> Maybe BSRow
parseRow line = case T.splitOn "\t" line of
  (cpT : bsZi : bsPy : bsMc : bsOc : bsGloss : rest) -> do
    bsCp <- readMaybe (T.unpack cpT)
    let bsGsr = case rest of (g : _) -> g; _ -> ""
    pure BSRow {..}
  _ -> Nothing

-- Loading ------------------------------------------------------------------

ingest :: Pipe -> FilePath -> IO IngestStats
ingest pipe path = do
  rows <- parseTsv <$> TIO.readFile path
  forM_ (chunksOf 500 rows) $ \batch ->
    run pipe $ queryP upsertCypher (Map.fromList [("rows", L (map rowValue batch))]) >> pure ()
  signs <- oneInt pipe
    "MATCH (s:Sign)-[:HAS_SINITIC_SENSE]->(:SiniticSense {source:'baxter-sagart'}) \
    \RETURN count(DISTINCT s) AS n"
  pure IngestStats { statRows = length rows, statSigns = signs }

upsertCypher :: Text
upsertCypher =
  "UNWIND $rows AS row \
  \MATCH (s:Sign {codepoint: row.cp}) \
  \MERGE (ss:SiniticSense {id: row.id}) \
  \SET ss.gloss = row.gloss, ss.reading = row.oc, ss.mc = row.mc, \
  \    ss.gsr = row.gsr, ss.source = 'baxter-sagart' \
  \MERGE (s)-[:HAS_SINITIC_SENSE]->(ss)"

rowValue :: BSRow -> Value
rowValue r = M $ Map.fromList
  [ ("cp",    I (bsCp r))
  , ("id",    T (bsId r))
  , ("oc",    T (bsOc r))
  , ("mc",    T (bsMc r))
  , ("gloss", T (bsGloss r))
  , ("gsr",   T (bsGsr r))
  ]

-- | The node id of a row. It must tell every row apart: one character can
-- have several rows with the same GSR number and Old Chinese reconstruction
-- but a different Middle Chinese reading or gloss (公 'father' / 'prince' /
-- 'impartial, just; public'), and an id without MC and gloss merged them, so
-- that only the last row's gloss survived.
bsId :: BSRow -> Text
bsId r = T.intercalate ":" ["bs", T.pack (show (bsCp r)), bsGsr r, bsOc r, bsMc r, bsGloss r]

-- helpers -------------------------------------------------------------------

oneInt :: Pipe -> Text -> IO Int
oneInt pipe cy = do
  recs <- run pipe (query cy)
  pure $ case recs of
    (r : _) | Just (I n) <- Map.lookup "n" r -> n
    _                                        -> 0

chunksOf :: Int -> [a] -> [[a]]
chunksOf _ [] = []
chunksOf n xs = let (h, t) = splitAt n xs in h : chunksOf n t
