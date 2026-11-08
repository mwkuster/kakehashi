-- | F5 — homophone-by-writing discovery across the whole lexicon (Phase 1).
--
-- Groups Lexemes that share a reading (@phonology@) but are written with
-- different /kanji/, producing the "homophone-by-writing set" — the project's
-- core evidence that script transfer multiplied writings onto one spoken form.
--
-- Set membership is by distinct __kanji signature__, not raw orthography:
--
--   * okurigana variants of one kanji collapse (上がる / 上る / 上ル → 上);
--   * purely phonetic writings with no kanji (kana, ４, ＣＤ…) are dropped, so a
--     word's kana spelling is not counted beside its kanji (the こう/公 case);
--   * writings count as different only if they /compete/: different kanji
--     stand for overlapping parts of the reading ('competes'). しびれを切らす /
--     痺れをきらす, which differ only in which part is written in kana, do not;
--   * expressions (Lexemes whose JMdict entries all start with an @exp@ sense,
--     コーヒーを入れる, 気を付ける) are not words and are left out; the verb
--     they contain is counted on its own.
--
-- Optional filters separate the two families the raw universe conflates:
-- Sino-Japanese on-reading collapses (こう → 公候効…, nominal) versus native
-- kun lexemes split across kanji (はかる → 測る計る…, verbal). 'hfVerbs' keeps
-- lexemes with a verb conjugation class (v1, v5r, vk, …), which foregrounds the
-- latter; a POS token prefix ('hfPos') is the general filter, but note that
-- @"v"@ also matches the suru-noun tag @vs@ and the transitivity tags @vt@ /
-- @vi@, i.e. Sino-Japanese nouns. 'hfJoyoOnly' restricts to jōyō kanji;
-- 'hfCommon' keeps only writings JMdict marks as common (@ke_pri@), which trims
-- archaic variants from a set.
module Kakehashi.Query.Homophone
  ( HomophoneFilter (..)
  , defaultFilter
  , HomophoneSet (..)
  , Writing (..)
  , RawWriting (..)
  , discoverAll
  , commonSetReadings
  , refineSet
  ) where

import Data.Char (chr)
import Data.List (sortOn)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (mapMaybe)
import Data.Ord (Down (..))
import Data.Text (Text)
import qualified Data.Text as T
import Kakehashi.Bolt (Pipe, Record, Value (..), queryP, run)

import Kakehashi.Kanji (competes, kanjiCodepoints, kanjiSpans)

-- | One distinct-kanji writing within a homophone set.
data Writing = Writing
  { wOrthography :: !Text         -- ^ representative orthography (shortest)
  , wVariants    :: ![Text]       -- ^ other orthographies sharing this kanji set
  , wPos         :: !(Maybe Text)
  , wPriority    :: !(Maybe Text) -- ^ JMdict @ke_pri@ tags of the representative
  , wGloss       :: !(Maybe Text) -- ^ primary sense gloss (Concept) of the representative
  , wSigns       :: ![Text]       -- ^ the kanji (signature), as literals
  }
  deriving (Eq, Show)

-- | A reading and the ≥2 distinct kanji writings that share it.
data HomophoneSet = HomophoneSet
  { hsPhonology :: !Text
  , hsSize      :: !Int
  , hsWritings  :: ![Writing]
  }
  deriving (Eq, Show)

-- | A single Lexeme writing as read back from the graph, before collapsing.
data RawWriting = RawWriting
  { rwOrthography :: !Text
  , rwPos         :: !(Maybe Text)
  , rwPriority    :: !(Maybe Text)
  , rwGloss       :: !(Maybe Text)
  }
  deriving (Eq, Show)

data HomophoneFilter = HomophoneFilter
  { hfMinSize  :: !Int           -- ^ minimum distinct kanji writings (≥ 2)
  , hfPos      :: !(Maybe Text)  -- ^ keep Lexemes with a POS token starting with this
  , hfVerbs    :: !Bool          -- ^ keep only Lexemes with a verb conjugation class
  , hfJoyoOnly :: !Bool          -- ^ keep only Lexemes written wholly in jōyō kanji
  , hfCommon   :: !Bool          -- ^ keep only Lexemes JMdict marks common (ke_pri)
  }
  deriving (Eq, Show)

defaultFilter :: HomophoneFilter
defaultFilter = HomophoneFilter
  { hfMinSize  = 2
  , hfPos      = Nothing
  , hfVerbs    = False
  , hfJoyoOnly = False
  , hfCommon   = False
  }

discoverAll :: Pipe -> HomophoneFilter -> IO [HomophoneSet]
discoverAll pipe hf = do
  recs <- run pipe $ queryP cypher params
  let sets = mapMaybe (refineSet (hfMinSize hf) . decodeRow) recs
  pure (sortOn (\hs -> (Down (hsSize hs), hsPhonology hs)) sets)
  where
    params = Map.fromList
      [ ("minSize",  I (hfMinSize hf))
      , ("pos",      T (maybe "" id (hfPos hf)))
      , ("verbs",    B (hfVerbs hf))
      , ("joyoOnly", B (hfJoyoOnly hf))
      , ("common",   B (hfCommon hf))
      ]

-- | Readings whose JMdict-common writings form a homophone-by-writing set
-- (≥ 2 distinct kanji signatures). This is the RQ3 population and the
-- denominator of source coverage; okurigana variants of one word (有難い /
-- 有り難い) do not make a set.
commonSetReadings :: Pipe -> IO [Text]
commonSetReadings pipe =
  map hsPhonology <$> discoverAll pipe defaultFilter { hfCommon = True }

-- | Prefilter at orthography count ≥ minSize: safe because distinct-kanji count
-- ≤ orthography count, so no genuine set is dropped here. The exact
-- distinct-kanji size is recomputed in 'refineSet'.
--
-- The verb classes are those of @eval/universe.py@. The jōyō test compares the
-- number of jōyō signs a lexeme is written with to its number of distinct kanji
-- (@kanjiCount@), so a kanji missing from KANJIDIC2 fails it. Senses are ordered
-- by entry and sense number as integers (a text sort would put sense 10 before
-- sense 2).
cypher :: Text
cypher =
  "MATCH (l:Lexeme) \
  \WHERE NOT coalesce(l.expression, false) \
  \  AND ($pos = '' \
  \       OR ANY(p IN split(coalesce(l.pos, ''), ',') WHERE p STARTS WITH $pos)) \
  \  AND ((NOT $verbs) \
  \       OR ANY(p IN split(coalesce(l.pos, ''), ',') \
  \              WHERE p =~ 'v(1|2|4|5|k|n|r|z|-unspec).*')) \
  \  AND ((NOT $common) OR coalesce(l.priority, '') <> '') \
  \  AND ((NOT $joyoOnly) \
  \       OR size([(l)-[:WRITTEN_WITH]->(s:Sign) WHERE s.joyo | s]) \
  \          = coalesce(l.kanjiCount, -1)) \
  \OPTIONAL MATCH (l)-[:MEANS]->(c:Concept) \
  \WITH l, c ORDER BY toInteger(split(c.id, ':')[0]), toInteger(split(c.id, ':')[1]) \
  \WITH l, head(collect(c.gloss)) AS gloss \
  \WITH l.phonology AS phon, \
  \     collect({orthography: l.orthography, pos: l.pos, \
  \              priority: l.priority, gloss: gloss}) AS writings \
  \WHERE size(writings) >= $minSize \
  \RETURN phon AS phon, writings AS writings"

-- Refinement (pure) --------------------------------------------------------

-- | Collapse a reading's competing raw writings into distinct-kanji writings,
-- drop kanji-less ones, and keep the set only if ≥ minSize remain.
refineSet :: Int -> (Text, [RawWriting]) -> Maybe HomophoneSet
refineSet minSize (phon, raws)
  | length writings >= minSize =
      Just HomophoneSet { hsPhonology = phon, hsSize = length writings, hsWritings = writings }
  | otherwise = Nothing
  where
    writings = collapseWritings (competingWritings phon raws)

-- | The writings that compete with a writing of another kanji signature
-- ('competes'); writings without kanji are kept for 'collapseWritings' to drop.
competingWritings :: Text -> [RawWriting] -> [RawWriting]
competingWritings phon raws =
  [ w | (w, sig, sp) <- annotated
      , null sig || or [ sig /= sig' && competes sp sp' | (_, sig', sp') <- annotated, not (null sig') ] ]
  where
    annotated = [ (w, kanjiCodepoints o, kanjiSpans phon o) | w <- raws, let o = rwOrthography w ]

-- | Group writings by kanji signature (first-occurrence order preserved),
-- dropping any with no kanji. Within a group the shortest orthography is the
-- representative; the rest become variants. Result sorted by representative.
collapseWritings :: [RawWriting] -> [Writing]
collapseWritings raws =
  sortOn wOrthography
    [ mkWriting sig group
    | (sig, group) <- Map.toList grouped
    ]
  where
    grouped :: Map [Int] [RawWriting]
    grouped = Map.fromListWith (++)
      [ (sig, [w])
      | w <- raws
      , let sig = kanjiCodepoints (rwOrthography w)
      , not (null sig)
      ]

mkWriting :: [Int] -> [RawWriting] -> Writing
mkWriting sig group =
  Writing
    { wOrthography = rwOrthography primary
    , wVariants    = map rwOrthography rest
    , wPos         = rwPos primary
    , wPriority    = rwPriority primary
    , wGloss       = rwGloss primary
    , wSigns       = map (T.singleton . chr) sig
    }
  where
    ordered          = sortOn (\w -> (T.length (rwOrthography w), rwOrthography w)) group
    (primary, rest)  = (head ordered, tail ordered)

-- Decoding -----------------------------------------------------------------

decodeRow :: Record -> (Text, [RawWriting])
decodeRow rec =
  ( maybe "" id (asText =<< Map.lookup "phon" rec)
  , mapMaybe decodeWriting (asList (Map.lookup "writings" rec))
  )

decodeWriting :: Value -> Maybe RawWriting
decodeWriting v = do
  m    <- asMap v
  orth <- asText =<< Map.lookup "orthography" m
  pure RawWriting
    { rwOrthography = orth
    , rwPos         = asText =<< Map.lookup "pos" m
    , rwPriority    = asText =<< Map.lookup "priority" m
    , rwGloss       = asText =<< Map.lookup "gloss" m
    }

asText :: Value -> Maybe Text
asText (T t) = Just t
asText _     = Nothing

asMap :: Value -> Maybe (Map Text Value)
asMap (M m) = Just m
asMap _     = Nothing

asList :: Maybe Value -> [Value]
asList (Just (L xs)) = xs
asList _             = []
