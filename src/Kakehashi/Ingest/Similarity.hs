-- | Write precomputed meaning-similarity scores back onto the graph
-- (Phase 3 — precompute & store). Reads the scores CSV emitted by
-- @eval/rq3.py@ (reading, orthography, sign, cosine, model) and sets
-- @meaningSim@ / @simModel@ on the matching @WRITTEN_WITH@ edge — the cosine
-- between a word's native concept (sense 1) and that kanji's Sinitic source
-- sense. This is the stored basis for an F7 similarity view.
module Kakehashi.Ingest.Similarity
  ( SimRow (..)
  , parseScores
  , loadSimilarities
  ) where

import Control.Monad (forM_)
import qualified Data.Map.Strict as Map
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Kakehashi.Bolt (Pipe, Value (..), queryP, run)
import Text.Read (readMaybe)

data SimRow = SimRow
  { srReading :: !Text
  , srOrth    :: !Text
  , srSign    :: !Text
  , srCosine  :: !Double
  , srModel   :: !Text
  }
  deriving (Eq, Show)

-- | Parse the scores CSV (header + rows). Fields are comma-separated and never
-- quoted (no field contains a comma: glosses are excluded by design).
parseScores :: Text -> [SimRow]
parseScores = mapMaybe parseRow . drop 1 . T.lines

parseRow :: Text -> Maybe SimRow
parseRow line = case T.splitOn "," line of
  (reading : orth : sign : cosT : modelParts) | not (null modelParts) -> do
    c <- readMaybe (T.unpack cosT)
    pure SimRow
      { srReading = reading
      , srOrth    = orth
      , srSign    = sign
      , srCosine  = c
      , srModel   = T.intercalate "," modelParts
      }
  _ -> Nothing

loadSimilarities :: Pipe -> FilePath -> IO Int
loadSimilarities pipe path = do
  rows <- parseScores <$> TIO.readFile path
  forM_ (chunksOf 1000 rows) $ \batch ->
    run pipe $ queryP upsertCypher
      (Map.fromList [("rows", L (map simRow batch))]) >> pure ()
  pure (length rows)

upsertCypher :: Text
upsertCypher =
  "UNWIND $rows AS row \
  \MATCH (l:Lexeme {phonology: row.reading, orthography: row.orth}) \
  \      -[w:WRITTEN_WITH]->(s:Sign {literal: row.sign}) \
  \SET w.meaningSim = row.cosine, w.simModel = row.model"

simRow :: SimRow -> Value
simRow r = M $ Map.fromList
  [ ("reading", T (srReading r))
  , ("orth",    T (srOrth r))
  , ("sign",    T (srSign r))
  , ("cosine",  F (srCosine r))
  , ("model",   T (srModel r))
  ]

chunksOf :: Int -> [a] -> [[a]]
chunksOf _ [] = []
chunksOf n xs = let (h, t) = splitAt n xs in h : chunksOf n t
