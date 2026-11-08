-- | Unihan database ingest (Phase 2).
--
-- Reads the @Unihan_Readings.txt@ field file and seeds, for every kanji already
-- present as a Sign, a candidate 'SiniticSense' from @kDefinition@ (gloss) and
-- @kMandarin@ (reading), linked @Sign -[:HAS_SINITIC_SENSE]-> SiniticSense@.
--
-- These are __candidates__, not curated source senses: @kMandarin@ is a modern
-- reading. The borrowing-era sound is Middle Chinese (the on'yomi stratum); the
-- period-semantic anchor is Old Chinese (Baxter–Sagart) — an earlier, pre-drift
-- proxy, not the Middle-Chinese sense itself. Curated period values come later
-- via the curation worksheet (@curate@ / @align@).
-- Provenance is recorded as @source = "unihan"@ on each node.
module Kakehashi.Ingest.Unihan
  ( IngestStats (..)
  , ingest
  , parseReadingLine
  ) where

import Control.Applicative ((<|>))
import Control.Monad (forM_)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Kakehashi.Bolt (Pipe, Value (..), queryP, run)
import Numeric (readHex, showHex)

newtype IngestStats = IngestStats
  { statCandidates :: Int  -- ^ SiniticSense candidates with a definition (Sign-matched ones are linked)
  }
  deriving (Eq, Show)

-- | A candidate Sinitic sense for one character.
data USense = USense
  { usCodepoint :: !Int
  , usGloss     :: !(Maybe Text)
  , usReading   :: !(Maybe Text)
  }
  deriving (Eq, Show)

ingest :: Pipe -> FilePath -> IO IngestStats
ingest pipe path = do
  txt <- TIO.readFile path
  let senses = [ s | s <- parseReadings txt, hasGloss s ]
  writeSenses pipe senses
  pure IngestStats { statCandidates = length senses }
  where
    hasGloss s = maybe False (not . T.null) (usGloss s)

-- Parsing ------------------------------------------------------------------

-- | Group @kDefinition@ / @kMandarin@ lines by codepoint into 'USense' values.
parseReadings :: Text -> [USense]
parseReadings txt =
  [ USense cp (fst gv) (snd gv)
  | (cp, gv) <- Map.toList grouped
  ]
  where
    grouped = Map.fromListWith merge
      [ (cp, toGV field value)
      | Just (cp, field, value) <- map parseReadingLine (T.lines txt)
      ]
    toGV "kDefinition" v = (Just v, Nothing)
    toGV "kMandarin"   v = (Nothing, Just v)
    toGV _             _ = (Nothing, Nothing)
    merge (g1, r1) (g2, r2) = (g1 <|> g2, r1 <|> r2)

-- | Parse one Unihan field line, keeping only @kDefinition@/@kMandarin@.
-- Format: @U+6E2C\\tkDefinition\\tmeasure, estimate, conjecture@.
parseReadingLine :: Text -> Maybe (Int, Text, Text)
parseReadingLine line
  | "#" `T.isPrefixOf` line = Nothing
  | otherwise = case T.splitOn "\t" line of
      (cpT : field : value : _)
        | field == "kDefinition" || field == "kMandarin" ->
            (\cp -> (cp, field, value)) <$> parseCodepoint cpT
      _ -> Nothing

parseCodepoint :: Text -> Maybe Int
parseCodepoint t = do
  hex <- T.stripPrefix "U+" t
  case readHex (T.unpack hex) of
    [(n, "")] -> Just n
    _         -> Nothing

-- Writing ------------------------------------------------------------------

writeSenses :: Pipe -> [USense] -> IO ()
writeSenses pipe senses =
  forM_ (chunksOf batchSize senses) $ \batch ->
    run pipe $ queryP upsertCypher
      (Map.fromList [("rows", L (map senseRow batch))]) >> pure ()

batchSize :: Int
batchSize = 500

-- | MATCH the Sign first, so candidates for characters outside KANJIDIC2 are
-- skipped rather than left as orphan SiniticSense nodes.
upsertCypher :: Text
upsertCypher =
  "UNWIND $rows AS row \
  \MATCH (s:Sign {codepoint: row.codepoint}) \
  \MERGE (ss:SiniticSense {id: row.id}) \
  \SET ss.gloss = row.gloss, ss.reading = row.reading, ss.source = 'unihan' \
  \MERGE (s)-[:HAS_SINITIC_SENSE]->(ss)"

senseRow :: USense -> Value
senseRow u = M $ Map.fromList
  [ ("codepoint", I (usCodepoint u))
  , ("id",        T ("unihan:U+" <> T.toUpper (T.pack (showHex (usCodepoint u) ""))))
  , ("gloss",     maybe (N ()) T (usGloss u))
  , ("reading",   maybe (N ()) T (usReading u))
  ]

chunksOf :: Int -> [a] -> [[a]]
chunksOf _ [] = []
chunksOf n xs = let (h, t) = splitAt n xs in h : chunksOf n t
