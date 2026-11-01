-- | Generic Sinitic-sense ingest: a TSV (@codepoint<TAB>reading<TAB>gloss@,
-- header skipped) → 'SiniticSense' per matched Sign under an arbitrary
-- @source@ tag. Makes any additional source — Kroll (from a user's licensed
-- local export), Wiktionary Middle-Chinese glosses, etc. — a one-liner beside
-- the built-in Unihan and Baxter–Sagart ingests.
--
-- NB: respect each source's licence. Commercial dictionaries (e.g. Kroll) are
-- local-use only and must not be redistributed — keep the TSV in data/ (gitignored).
module Kakehashi.Ingest.Sinitic
  ( SinRow (..)
  , parseSiniticRow
  , ingestTsv
  ) where

import Control.Monad (forM_)
import qualified Data.Map.Strict as Map
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Database.Bolt (Pipe, Value (..), queryP, run)
import Text.Read (readMaybe)

data SinRow = SinRow
  { srCp      :: !Int
  , srReading :: !Text
  , srGloss   :: !Text
  }
  deriving (Eq, Show)

-- | @codepoint<TAB>reading<TAB>gloss@ (codepoint decimal). Extra columns ignored.
parseSiniticRow :: Text -> Maybe SinRow
parseSiniticRow line = case T.splitOn "\t" line of
  (cpT : reading : gloss : _) -> do
    cp <- readMaybe (T.unpack cpT)
    pure (SinRow cp reading gloss)
  _ -> Nothing

ingestTsv :: Pipe -> Text -> FilePath -> IO Int
ingestTsv pipe source path = do
  rows <- mapMaybe parseSiniticRow . drop 1 . T.lines <$> TIO.readFile path
  forM_ (chunksOf 500 rows) $ \batch ->
    run pipe $ queryP cypher
      (Map.fromList [("src", T source), ("rows", L (map (rowVal source) batch))]) >> pure ()
  pure (length rows)

cypher :: Text
cypher =
  "UNWIND $rows AS row \
  \MATCH (s:Sign {codepoint: row.cp}) \
  \MERGE (ss:SiniticSense {id: row.id}) \
  \SET ss.gloss = row.gloss, ss.reading = row.reading, ss.source = $src \
  \MERGE (s)-[:HAS_SINITIC_SENSE]->(ss)"

rowVal :: Text -> SinRow -> Value
rowVal source r = M $ Map.fromList
  [ ("cp",      I (srCp r))
  , ("id",      T (T.intercalate "|" [source, T.pack (show (srCp r)), srReading r, T.take 48 (srGloss r)]))
  , ("reading", T (srReading r))
  , ("gloss",   T (srGloss r))
  ]

chunksOf :: Int -> [a] -> [[a]]
chunksOf _ [] = []
chunksOf n xs = let (h, t) = splitAt n xs in h : chunksOf n t
