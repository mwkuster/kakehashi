-- | The @report@ command: a graph-derived corpus & findings summary (Markdown).
--
-- Bundles the paper's structural numbers — node/edge counts, the
-- homophone-by-writing universe and its size distribution, the worked-example
-- sets with concept glosses, and the Sinitic alignment / similarity layer — into
-- one reproducible artifact. (The RQ3 *statistical* report — embeddings + the
-- significance test — is produced by @eval/rq3.py@.)
module Kakehashi.Query.Report
  ( corpusReport
  ) where

import Data.List (sortOn)
import qualified Data.Map.Strict as Map
import Data.Ord (Down (..))
import Data.Text (Text)
import qualified Data.Text as T
import Database.Bolt (Pipe, Value (..), query, run)
import Numeric (showFFloat)

import Kakehashi.Query.Homophone
  (HomophoneFilter (..), HomophoneSet (..), Writing (..), defaultFilter, discoverAll)

exemplars :: [Text]
exemplars = ["はかる", "とる", "かく", "きく", "なおす"]

corpusReport :: Pipe -> IO Text
corpusReport pipe = do
  counts          <- mapM (\(lbl, cy) -> (,) lbl <$> oneInt pipe cy) corpusQueries
  sets            <- discoverAll pipe defaultFilter
  -- exemplars are native verbs: restrict to common verb writings (conjugation
  -- classes) so the tables don't fold in the Sino on-reading homophones (e.g.
  -- かく 各/客/核).
  verbSets        <- discoverAll pipe defaultFilter { hfCommon = True, hfVerbs = True }
  (simN, simMean) <- simCoverage pipe
  aligns          <- alignmentsByBasis pipe
  let hist     = Map.toList (Map.fromListWith (+) [ (hsSize s, 1 :: Int) | s <- sets ])
      topSizes = take 10 (sortOn (Down . fst) hist)
      top10    = take 10 sets
      exSets   = [ s | r <- exemplars, s <- verbSets, hsPhonology s == r ]
  pure $ T.unlines $
    [ "# kakehashi — corpus & findings report"
    , ""
    , "Generated from the graph (`kakehashi report`). The RQ3 significance test"
    , "lives in `data/rq3_report.md` (`eval/rq3.py`)."
    , ""
    , "## Corpus" , "" ]
    <> mdTable ["item", "count"] [ [lbl, tshow n] | (lbl, n) <- counts ]
    <> [ "", "## Homophone-by-writing universe", ""
       , "**" <> tshow (length sets) <> "** readings have ≥ 2 distinct-kanji writings."
       , "", "Size distribution (largest sizes):", "" ]
    <> mdTable ["set size", "# readings"] [ [tshow sz, tshow c] | (sz, c) <- topSizes ]
    <> [ "", "Largest sets:", "" ]
    <> mdTable ["reading", "size", "sample writings"]
         [ [hsPhonology s, tshow (hsSize s), sampleWritings s] | s <- top10 ]
    <> [ "", "## Worked-example sets (common writings)", "" ]
    <> concatMap exemplarBlock exSets
    <> [ "## Sinitic alignment & similarity", ""
       , "- meaning-similarity stored on **" <> tshow simN <> "** writings (mean cosine "
           <> rnd simMean <> ")."
       , "- curated alignments by basis:", "" ]
    <> mdTable ["basis", "count"] [ [b, tshow n] | (b, n) <- aligns ]

corpusQueries :: [(Text, Text)]
corpusQueries =
  [ ("Sign nodes",            "MATCH (s:Sign) RETURN count(s) AS n")
  , ("Reading nodes",         "MATCH (r:Reading) RETURN count(r) AS n")
  , ("Lexeme nodes",          "MATCH (l:Lexeme) RETURN count(l) AS n")
  , ("Concept nodes",         "MATCH (c:Concept) RETURN count(c) AS n")
  , ("SiniticSense nodes",    "MATCH (x:SiniticSense) RETURN count(x) AS n")
  , ("Alignment nodes",       "MATCH (a:Alignment) RETURN count(a) AS n")
  , ("HAS_READING edges",     "MATCH ()-[e:HAS_READING]->() RETURN count(e) AS n")
  , ("WRITTEN_WITH edges",    "MATCH ()-[e:WRITTEN_WITH]->() RETURN count(e) AS n")
  , ("MEANS edges",           "MATCH ()-[e:MEANS]->() RETURN count(e) AS n")
  , ("HAS_SINITIC_SENSE edges","MATCH ()-[e:HAS_SINITIC_SENSE]->() RETURN count(e) AS n")
  ]

sampleWritings :: HomophoneSet -> Text
sampleWritings = T.intercalate " " . take 6 . map wOrthography . hsWritings

exemplarBlock :: HomophoneSet -> [Text]
exemplarBlock s =
  [ "### " <> hsPhonology s, "" ]
  <> mdTable ["writing", "sign", "concept (sense 1)"]
       [ [wOrthography w, T.intercalate "・" (wSigns w), maybe "" id (wGloss w)]
       | w <- hsWritings s ]
  <> [ "" ]

-- queries / decoding -------------------------------------------------------

oneInt :: Pipe -> Text -> IO Int
oneInt pipe cy = do
  recs <- run pipe (query cy)
  pure $ case recs of
    (r : _) -> intOf (Map.lookup "n" r)
    _       -> 0

simCoverage :: Pipe -> IO (Int, Double)
simCoverage pipe = do
  recs <- run pipe (query
    "MATCH ()-[w:WRITTEN_WITH]->() WHERE w.meaningSim IS NOT NULL \
    \RETURN count(w) AS n, avg(w.meaningSim) AS mean")
  pure $ case recs of
    (r : _) -> (intOf (Map.lookup "n" r), dblOf (Map.lookup "mean" r))
    _       -> (0, 0)

alignmentsByBasis :: Pipe -> IO [(Text, Int)]
alignmentsByBasis pipe = do
  recs <- run pipe (query
    "MATCH (a:Alignment) RETURN coalesce(a.basis, '(none)') AS basis, count(*) AS n \
    \ORDER BY basis")
  pure [ (txtOf (Map.lookup "basis" r), intOf (Map.lookup "n" r)) | r <- recs ]

intOf :: Maybe Value -> Int
intOf (Just (I n)) = n
intOf _            = 0

dblOf :: Maybe Value -> Double
dblOf (Just (F f)) = f
dblOf _            = 0

txtOf :: Maybe Value -> Text
txtOf (Just (T t)) = t
txtOf _            = ""

-- markdown helpers ---------------------------------------------------------

mdTable :: [Text] -> [[Text]] -> [Text]
mdTable header rows = mdRow header : mdRow (map (const "---") header) : map mdRow rows
  where mdRow cs = "| " <> T.intercalate " | " cs <> " |"

tshow :: Show a => a -> Text
tshow = T.pack . show

rnd :: Double -> Text
rnd d = T.pack (showFFloat (Just 3) d "")
