-- | RQ3 evaluation dataset (Phase 3, slice 1).
--
-- Exports paired gloss data for the "characters are selected by perceived
-- similarity of meaning" test. The population is the homophone-by-writing
-- phenomenon itself: the common writings of readings whose common writings
-- form a homophone-by-writing set ('commonSetReadings'). For each
-- real (native concept ↔ Sinitic sense) pairing it emits an __actual__ row and
-- a __control__ row (the same native gloss against a random other Sinitic
-- gloss), sharing a @pair_id@ for a paired test. Control selection is a seeded
-- LCG, so the dataset is reproducible.
--
-- Both glosses are English (JMdict gloss / Unihan kDefinition), so downstream
-- embedding is monolingual — no multilingual model needed.
module Kakehashi.Query.Eval
  ( Actual (..)
  , EvalPair (..)
  , fetchActuals
  , fetchPool
  , samplePairs
  , sourceCoverage
  , siniticSources
  ) where

import Data.Array (Array, listArray, (!))
import Data.List (mapAccumL, sortOn)
import qualified Data.Map.Strict as Map
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Database.Bolt (Pipe, Record, Value (..), queryP, run)

import Kakehashi.Query.Homophone (commonSetReadings)

-- | A real (lexeme writing → sign → Sinitic sense) pairing with its native sense.
data Actual = Actual
  { aReading :: !Text
  , aOrth    :: !Text
  , aSign    :: !Text
  , aNative  :: !Text
  , aSinitic :: !Text
  }
  deriving (Eq, Show)

-- | One row of the exported dataset (actual or control), paired by 'epPairId'.
data EvalPair = EvalPair
  { epPairId  :: !Int
  , epKind    :: !Text   -- ^ "actual" | "control"
  , epReading :: !Text
  , epOrth    :: !Text
  , epSign    :: !Text
  , epNative  :: !Text
  , epSinitic :: !Text
  }
  deriving (Eq, Show)

-- Fetching -----------------------------------------------------------------

-- | Actual pairings over the homophone-common population, using SiniticSenses
-- of the given @source@ (@"unihan"@ modern, @"baxter-sagart"@ period). A sign's
-- senses of that source are joined into one gloss.
fetchActuals :: Pipe -> Text -> IO [Actual]
fetchActuals pipe source = do
  readings <- commonSetReadings pipe
  mapMaybe decodeActual <$> run pipe (queryP actualsCypher (Map.fromList
    [("source", T source), ("readings", L (map T readings))]))

-- Senses are ordered by entry and sense number as integers, so the native
-- gloss is the first sense (a text sort puts sense 10 before sense 2). The
-- secondary key ss.id fixes the order in which a sign's Sinitic senses are
-- joined, so the exported glosses do not depend on the store's internal order.
actualsCypher :: Text
actualsCypher =
  "MATCH (l:Lexeme)-[:WRITTEN_WITH]->(s:Sign) \
  \WHERE l.priority IS NOT NULL AND l.phonology IN $readings \
  \MATCH (s)-[:HAS_SINITIC_SENSE]->(ss:SiniticSense) \
  \WHERE ss.source = $source AND ss.gloss IS NOT NULL \
  \MATCH (l)-[:MEANS]->(c:Concept) \
  \WITH l, s, c, ss ORDER BY toInteger(split(c.id, ':')[0]), toInteger(split(c.id, ':')[1]), ss.id \
  \WITH l, s, head(collect(c.gloss)) AS native, collect(DISTINCT ss.gloss) AS sgs \
  \WHERE native IS NOT NULL AND size(sgs) > 0 \
  \RETURN l.phonology AS reading, l.orthography AS orth, s.literal AS sign, \
  \       native AS native, \
  \       reduce(a = '', g IN sgs | a + CASE WHEN a = '' THEN '' ELSE '; ' END + g) AS sinitic \
  \ORDER BY reading, orth, sign"

-- | The control pool: distinct (sign, Sinitic gloss) of the given source.
fetchPool :: Pipe -> Text -> IO [(Text, Text)]
fetchPool pipe source =
  mapMaybe decodePool <$> run pipe (queryP poolCypher (Map.fromList [("source", T source)]))

poolCypher :: Text
poolCypher =
  "MATCH (s:Sign)-[:HAS_SINITIC_SENSE]->(ss:SiniticSense) \
  \WHERE ss.source = $source AND ss.gloss IS NOT NULL \
  \RETURN DISTINCT s.literal AS sign, ss.gloss AS gloss ORDER BY gloss, sign"

-- | The non-Unihan Sinitic sources present in the graph (those the kyūjitai
-- bridge extends), e.g. @baxter-sagart@, @wiktionary@.
siniticSources :: Pipe -> IO [Text]
siniticSources pipe = do
  recs <- run pipe (queryP
    "MATCH (ss:SiniticSense) WHERE ss.source <> 'unihan' \
    \RETURN DISTINCT ss.source AS source ORDER BY source" Map.empty)
  pure (mapMaybe (\r -> asText =<< Map.lookup "source" r) recs)

-- | Coverage of the population's signs by a Sinitic source: (signs with a
-- sense of that source, all signs of the population's common writings).
sourceCoverage :: Pipe -> Text -> IO (Int, Int)
sourceCoverage pipe source = do
  readings <- commonSetReadings pipe
  let params = Map.fromList [("source", T source), ("readings", L (map T readings))]
      count cy = do
        recs <- run pipe (queryP cy params)
        pure $ case recs of
          (r : _) | Just (I n) <- Map.lookup "n" r -> n
          _                                        -> 0
  total   <- count (populationSigns "")
  covered <- count (populationSigns
    "AND EXISTS { MATCH (s)-[:HAS_SINITIC_SENSE]->(ss:SiniticSense) WHERE ss.source = $source } ")
  pure (covered, total)
  where
    populationSigns extra =
      "MATCH (l:Lexeme)-[:WRITTEN_WITH]->(s:Sign) \
      \WHERE l.priority IS NOT NULL AND l.phonology IN $readings " <> extra <>
      "RETURN count(DISTINCT s) AS n"

-- Pairing (pure) -----------------------------------------------------------

-- | Build actual+control rows. @sampleN@ (if given) seeded-subsamples the
-- actuals first; each actual then gets one control drawn from the pool.
samplePairs :: Int -> Maybe Int -> [Actual] -> [(Text, Text)] -> [EvalPair]
samplePairs seed sampleN actuals pool
  | null pool = []
  | otherwise = concat (snd (mapAccumL step (nextLCG seed) (zip [0 ..] chosen)))
  where
    chosen = maybe id (take . max 0) sampleN (seededShuffle seed actuals)
    n      = length pool
    arr    = listArray (0, n - 1) pool :: Array Int (Text, Text)

    step st (pid, a) =
      let st'           = nextLCG st
          (csign, csin) = pickControl st' (aSinitic a)
      in (st', [actualRow pid a, controlRow pid a csign csin])

    pickControl st real =
      let (s, g) = arr ! (st `mod` n)
      in if g == real && n > 1
           then arr ! ((st `div` n + 1) `mod` n)
           else (s, g)

actualRow :: Int -> Actual -> EvalPair
actualRow pid a = EvalPair pid "actual" (aReading a) (aOrth a) (aSign a) (aNative a) (aSinitic a)

controlRow :: Int -> Actual -> Text -> Text -> EvalPair
controlRow pid a csign csin = EvalPair pid "control" (aReading a) (aOrth a) csign (aNative a) csin

-- | Decorate-sort shuffle with a seeded LCG stream — deterministic.
seededShuffle :: Int -> [a] -> [a]
seededShuffle seed xs = map snd (sortOn fst (zip (lcgStream seed) xs))

lcgStream :: Int -> [Int]
lcgStream = tail . iterate nextLCG

nextLCG :: Int -> Int
nextLCG s = (1103515245 * s + 12345) `mod` 2147483648

-- Decoding -----------------------------------------------------------------

decodeActual :: Record -> Maybe Actual
decodeActual r =
  Actual <$> txt "reading" <*> txt "orth" <*> txt "sign" <*> txt "native" <*> txt "sinitic"
  where txt k = asText =<< Map.lookup k r

decodePool :: Record -> Maybe (Text, Text)
decodePool r = (,) <$> (asText =<< Map.lookup "sign" r) <*> (asText =<< Map.lookup "gloss" r)

asText :: Value -> Maybe Text
asText (T t) = Just t
asText _     = Nothing
