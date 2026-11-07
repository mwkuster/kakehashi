-- | Data for a per-homophone-set curation worksheet (Phase 2, slice 3).
--
-- For one reading, gathers each distinct-kanji writing with its native concept
-- (JMdict sense 1) and the candidate Sinitic senses of each of its signs, from
-- every source in the graph (Unihan, Baxter–Sagart, Wiktionary, …), each
-- labelled with its source. This is the raw material a human curator annotates
-- with period readings and alignment judgements ('Kakehashi.Export.Worksheet').
module Kakehashi.Query.Worksheet
  ( WsSign (..)
  , WsRow (..)
  , Worksheet (..)
  , worksheetFor
  , collapseRows
  , rowSigns
  , readingLabel
  ) where

import Data.Char (chr)
import Data.List (nub, sortOn)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Database.Bolt (Pipe, Record, Value (..), queryP, run)

import Kakehashi.Kanji (kanjiCodepoints)

-- | A sign within a writing and one candidate Sinitic sense of it.
data WsSign = WsSign
  { wsSign      :: !Text
  , wsSinitic   :: !(Maybe Text)  -- ^ gloss
  , wsSignReading :: !(Maybe Text)  -- ^ reading, of the type given by 'readingLabel'
  , wsSignCp    :: !Int           -- ^ codepoint (for reference/curation)
  , wsSiniticId :: !(Maybe Text)  -- ^ SiniticSense node id, if any
  , wsSource    :: !(Maybe Text)  -- ^ SiniticSense source (unihan, baxter-sagart, …)
  }
  deriving (Eq, Show)

-- | What kind of reading a source gives: Unihan a modern Mandarin reading,
-- Baxter–Sagart an Old Chinese reconstruction (with Middle Chinese),
-- Wiktionary a Middle Chinese reading.
readingLabel :: Maybe Text -> Text
readingLabel (Just "unihan")        = "Mandarin (modern)"
readingLabel (Just "baxter-sagart") = "Old Chinese"
readingLabel (Just "wiktionary")    = "Middle Chinese"
readingLabel _                      = "reading"

-- | One distinct-kanji writing of the reading.
data WsRow = WsRow
  { wsWriting   :: !Text
  , wsPos       :: !(Maybe Text)
  , wsNative    :: !(Maybe Text)
  , wsConceptId :: !(Maybe Text)  -- ^ primary (sense-1) Concept id
  , wsSigns     :: ![WsSign]
  }
  deriving (Eq, Show)

data Worksheet = Worksheet
  { wsReading :: !Text
  , wsRows    :: ![WsRow]
  }
  deriving (Eq, Show)

-- | Build the worksheet for a reading. @common@ restricts to JMdict-common
-- writings (as for @homophones --common@).
worksheetFor :: Pipe -> Bool -> Text -> IO Worksheet
worksheetFor pipe common reading = do
  recs <- run pipe $ queryP cypher
    (Map.fromList [("reading", T reading), ("common", B common)])
  pure Worksheet { wsReading = reading, wsRows = collapseRows (mapMaybe decodeRow recs) }

cypher :: Text
cypher =
  "MATCH (l:Lexeme {phonology: $reading}) \
  \WHERE ((NOT $common) OR coalesce(l.priority, '') <> '') \
  \OPTIONAL MATCH (l)-[:MEANS]->(c:Concept) \
  \WITH l, c ORDER BY toInteger(split(c.id, ':')[0]), toInteger(split(c.id, ':')[1]) \
  \WITH l, head(collect(c.gloss)) AS native, head(collect(c.id)) AS conceptId \
  \OPTIONAL MATCH (l)-[:WRITTEN_WITH]->(s:Sign) \
  \OPTIONAL MATCH (s)-[:HAS_SINITIC_SENSE]->(ss:SiniticSense) \
  \WITH l, native, conceptId, \
  \     collect({sign: s.literal, cp: s.codepoint, sinitic: ss.gloss, \
  \              reading: CASE ss.source WHEN 'baxter-sagart' \
  \                         THEN coalesce(ss.reading, '—') + ' · MC ' + coalesce(ss.mc, '—') \
  \                         ELSE ss.reading END, \
  \              sid: ss.id, source: ss.source}) AS signs \
  \RETURN l.orthography AS writing, l.pos AS pos, \
  \       native AS native, conceptId AS conceptId, signs AS signs \
  \ORDER BY writing"

-- | Drop kanji-less writings, then collapse writings sharing the same kanji
-- sequence (okurigana variants), keeping the shortest as representative.
collapseRows :: [WsRow] -> [WsRow]
collapseRows rows =
  sortOn wsWriting
    [ representative group
    | (_, group) <- Map.toList grouped
    ]
  where
    grouped :: Map [Text] [WsRow]
    grouped = Map.fromListWith (++)
      [ (rowSigns r, [r]) | r <- rows, not (null (wsSigns r)) ]
    representative = head . sortOn (\r -> (T.length (wsWriting r), wsWriting r))

-- | The distinct signs of a writing, in written order. 'wsSigns' holds one
-- entry per candidate Sinitic sense, so a sign recurs once per source, and the
-- query returns the entries in no guaranteed order. Signs that do not occur in
-- the writing's text (not expected) are kept at the end.
rowSigns :: WsRow -> [Text]
rowSigns r = inWriting <> filter (`notElem` inWriting) signs
  where
    signs     = nub (map wsSign (wsSigns r))
    inWriting = filter (`elem` signs) (map (T.singleton . chr) (kanjiCodepoints (wsWriting r)))

-- Decoding -----------------------------------------------------------------

decodeRow :: Record -> Maybe WsRow
decodeRow rec = do
  writing <- asText =<< Map.lookup "writing" rec
  pure WsRow
    { wsWriting   = writing
    , wsPos       = asText =<< Map.lookup "pos" rec
    , wsNative    = asText =<< Map.lookup "native" rec
    , wsConceptId = asText =<< Map.lookup "conceptId" rec
    , wsSigns     = mapMaybe decodeSign (asList (Map.lookup "signs" rec))
    }

decodeSign :: Value -> Maybe WsSign
decodeSign v = do
  m    <- asMap v
  lit  <- asText =<< Map.lookup "sign" m  -- Nothing when the lexeme has no kanji
  cp   <- asInt  =<< Map.lookup "cp" m
  pure WsSign
    { wsSign      = lit
    , wsSinitic   = asText =<< Map.lookup "sinitic" m
    , wsSignReading = asText =<< Map.lookup "reading" m
    , wsSignCp    = cp
    , wsSiniticId = asText =<< Map.lookup "sid" m
    , wsSource    = asText =<< Map.lookup "source" m
    }

asText :: Value -> Maybe Text
asText (T t) = Just t
asText _     = Nothing

asInt :: Value -> Maybe Int
asInt (I i) = Just i
asInt _     = Nothing

asMap :: Value -> Maybe (Map Text Value)
asMap (M m) = Just m
asMap _     = Nothing

asList :: Maybe Value -> [Value]
asList (Just (L xs)) = xs
asList _             = []
