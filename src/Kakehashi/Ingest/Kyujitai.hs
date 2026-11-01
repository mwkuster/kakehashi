-- | Kyūjitai↔shinjitai bridge for Baxter–Sagart coverage (Phase 2, step B).
--
-- B&S keys traditional characters; a Japanese shinjitai with a different
-- codepoint (図 U+56F3 vs 圖 U+5716) misses the direct match. This links a
-- shinjitai Sign to the non-Unihan 'SiniticSense's (Baxter–Sagart, Wiktionary,
-- …) already attached to its kyūjitai Sign, using two sources of old↔new
-- pairs:
--
--   * Unihan @kTraditionalVariant@ / @kZVariant@, kept only where KANJIDIC2
--     also records the two characters as variants ('confirmedPairs').
--     @kTraditionalVariant@ is the simplified-Chinese relation, not the
--     Japanese one: unfiltered it links 机 'desk' to 機 'machine' or 出 to 齣
--     'act of a play';
--   * a curated supplement TSV for Japan-only simplifications Unihan omits
--     (e.g. 図→圖) — extend with the full jōyō old/new list.
--
-- The bulk of the remaining gap is characters B&S does not cover at all
-- (its ~5,000-item selection), which no bridge can close.
module Kakehashi.Ingest.Kyujitai
  ( shinKyuPairsFromVariants
  , parseCuratedPairs
  , confirmedPairs
  , bridge
  ) where

import Control.Monad (forM_)
import Data.Char (isHexDigit, ord)
import Data.Containers.ListUtils (nubOrd)
import Data.List (nub)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import Database.Bolt (Pipe, Value (..), queryP, run)
import Numeric (readHex)

-- | (shinjitai codepoint, kyūjitai codepoint) pairs from Unihan variant fields.
shinKyuPairsFromVariants :: Text -> [(Int, Int)]
shinKyuPairsFromVariants txt =
  [ (src, tgt)
  | line <- T.lines txt
  , not ("#" `T.isPrefixOf` line)
  , cpT : field : val : _ <- [T.splitOn "\t" line]
  , field == "kTraditionalVariant" || field == "kZVariant"
  , Just src <- [parseU cpT]
  , tgt <- extractUs val
  ]

-- | Curated supplement: tab-separated @shinjitai<TAB>kyūjitai@ (the first
-- character of each field), @#@ comments and blanks skipped.
parseCuratedPairs :: Text -> [(Int, Int)]
parseCuratedPairs txt =
  [ (ord s, ord k)
  | line <- T.lines txt
  , let t = T.strip line
  , not (T.null t), not ("#" `T.isPrefixOf` t)
  , a : b : _ <- [T.splitOn "\t" t]
  , Just s <- [firstChar a], Just k <- [firstChar b]
  ]
  where firstChar x = case T.unpack (T.strip x) of (c : _) -> Just c; _ -> Nothing

-- | The old/new pairs to bridge: Unihan pairs that KANJIDIC2 confirms (the two
-- characters are variants of each other in its cross-references), plus all
-- curated pairs. Self-pairs (Unihan lists some characters as their own
-- traditional variant) are dropped, so a direct edge is never marked as
-- bridged.
confirmedPairs
  :: [(Int, Int)]  -- ^ KANJIDIC2 variant links ('Kakehashi.Ingest.Kanjidic.readVariantLinks')
  -> [(Int, Int)]  -- ^ curated pairs
  -> [(Int, Int)]  -- ^ Unihan pairs ('shinKyuPairsFromVariants')
  -> [(Int, Int)]
confirmedPairs links curated unihan =
  nubOrd ([ p | p@(s, k) <- unihan, s /= k, linked s k ] <> [ p | p@(s, k) <- curated, s /= k ])
  where
    linkSet    = Set.fromList links
    linked s k = Set.member (s, k) linkSet || Set.member (k, s) linkSet

-- | Link each shinjitai Sign to the non-Unihan senses of its kyūjitai Sign.
bridge :: Pipe -> [(Int, Int)] -> IO ()
bridge pipe pairs =
  forM_ (chunksOf 500 (nub pairs)) $ \batch ->
    run pipe $ queryP cy
      (Map.fromList [("pairs", L [ M (Map.fromList [("shin", I s), ("kyu", I k)])
                                 | (s, k) <- batch ])]) >> pure ()
  where
    cy =
      "UNWIND $pairs AS p \
      \MATCH (shin:Sign {codepoint: p.shin}) \
      \MATCH (kyu:Sign {codepoint: p.kyu})-[:HAS_SINITIC_SENSE]->(ss:SiniticSense) \
      \WHERE ss.source <> 'unihan' \
      \MERGE (shin)-[r:HAS_SINITIC_SENSE]->(ss) \
      \SET r.viaKyujitai = kyu.literal"

-- helpers -------------------------------------------------------------------

parseU :: Text -> Maybe Int
parseU t = T.stripPrefix "U+" t >>= readHexMaybe

extractUs :: Text -> [Int]
extractUs v =
  [ cp
  | (_, rest) <- T.breakOnAll "U+" v
  , let hexd = T.takeWhile isHexDigit (T.drop 2 rest)
  , not (T.null hexd)
  , Just cp <- [readHexMaybe hexd]
  ]

readHexMaybe :: Text -> Maybe Int
readHexMaybe t = case readHex (T.unpack t) of
  [(n, "")] -> Just n
  _         -> Nothing

chunksOf :: Int -> [a] -> [[a]]
chunksOf _ [] = []
chunksOf n xs = let (h, t) = splitAt n xs in h : chunksOf n t
