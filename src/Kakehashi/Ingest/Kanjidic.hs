-- | KANJIDIC2 XML ingest (Phase 1).
--
-- Parses the EDRDG KANJIDIC2 file into Sign nodes (one per kanji) and Reading
-- nodes (on/kun), linked by @HAS_READING@ edges. A Reading node is shared by
-- all characters with that reading, so the okurigana of a kun reading — which
-- belongs to the character (測 はか.る) — is stored on the @HAS_READING@ edge, as
-- the list of the splits KANJIDIC2 gives (圧: おさ.える and お.さえる; @""@ for a
-- form without okurigana). Meanings are deferred to the Phase 2 Concept layer.
--
-- Uses the DOM (@Text.XML@) rather than streaming: KANJIDIC2 is ~15 MB / ~13k
-- characters, which fits comfortably in memory. JMdict (larger) may warrant
-- @Text.XML.Stream.Parse@.
module Kakehashi.Ingest.Kanjidic
  ( IngestStats (..)
  , ingest
    -- * Variant cross-references
  , readVariantLinks
  , variantLinksFromText
    -- * Pure helpers (exposed for testing)
  , splitKun
  , isJoyo
  ) where

import Control.Monad (forM_)
import qualified Data.Map.Strict as Map
import Data.Containers.ListUtils (nubOrd)
import Data.Maybe (fromMaybe, listToMaybe, mapMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Lazy as TL
import Kakehashi.Bolt (Pipe, Value (..), queryP, run)
import Numeric (readHex, showHex)
import qualified Text.XML as XML
import Text.XML.Cursor

-- Parsed shapes ------------------------------------------------------------

data RKind = On | Kun
  deriving (Eq, Ord, Show)

data PReading = PReading
  { prValue     :: !Text
  , prKind      :: !RKind
  , prOkurigana :: !(Maybe Text)
  }
  deriving (Eq, Show)

data PChar = PChar
  { pcCodepoint :: !Int
  , pcLiteral   :: !Text
  , pcRadical   :: !(Maybe Int)
  , pcStrokes   :: !(Maybe Int)
  , pcJoyo      :: !Bool
  , pcReadings  :: ![PReading]
  }
  deriving (Eq, Show)

data IngestStats = IngestStats
  { statChars    :: !Int
  , statReadings :: !Int
  }
  deriving (Eq, Show)

-- Parsing ------------------------------------------------------------------

parseDocument :: XML.Document -> [PChar]
parseDocument doc = mapMaybe parseChar (fromDocument doc $// element "character")

parseChar :: Cursor -> Maybe PChar
parseChar c = do
  hex <- ucsHex c
  cp  <- readHexT hex
  let strokes = readIntT =<< firstContent "stroke_count" miscC
      grade   = readIntT =<< firstContent "grade" miscC
      miscC   = c $/ element "misc"
  pure PChar
    { pcCodepoint = cp
    , pcLiteral   = T.concat (c $/ element "literal" &/ content)
    , pcRadical   = classicalRadical c
    , pcStrokes   = strokes
    , pcJoyo      = isJoyo grade
    , pcReadings  = parseReadings c
    }
  where
    firstContent name cs = listToMaybe (cs >>= ($/ element name) >>= ($/ content))

-- | The UCS codepoint as a hex string (e.g. @"6e2c"@).
ucsHex :: Cursor -> Maybe Text
ucsHex c = listToMaybe
  [ t
  | cp <- c $/ element "codepoint" &/ element "cp_value"
  , attribute "cp_type" cp == ["ucs"]
  , t  <- cp $/ content
  ]

classicalRadical :: Cursor -> Maybe Int
classicalRadical c = readIntT =<< listToMaybe
  [ t
  | rv <- c $/ element "radical" &/ element "rad_value"
  , attribute "rad_type" rv == ["classical"]
  , t  <- rv $/ content
  ]

parseReadings :: Cursor -> [PReading]
parseReadings c = mapMaybe toReading
  [ (rt, txt)
  | rd  <- c $/ element "reading_meaning" &/ element "rmgroup" &/ element "reading"
  , rt  <- attribute "r_type" rd
  , txt <- rd $/ content
  ]
  where
    toReading (rt, txt)
      | rt == "ja_on"  = Just (PReading txt On Nothing)
      | rt == "ja_kun" = let (v, oku) = splitKun txt in Just (PReading v Kun oku)
      | otherwise      = Nothing

-- | Split a KANJIDIC2 kun reading (@"はか.る"@, @"-もと"@) into the full kana
-- value and its okurigana tail. Leading/trailing @-@ affix markers are dropped;
-- the @.@ marks where okurigana begins.
splitKun :: Text -> (Text, Maybe Text)
splitKun raw =
  let noAffix      = T.dropAround (== '-') raw
      (stem, rest) = T.breakOn "." noAffix
  in if T.null rest
       then (stem, Nothing)
       else let oku = T.drop 1 rest in (stem <> oku, Just oku)

-- | Jōyō kanji are grades 1–6 (kyōiku) plus 8 (the remaining general-use set);
-- grades 9–10 are jinmeiyō (name kanji), not jōyō.
isJoyo :: Maybe Int -> Bool
isJoyo (Just g) = g `elem` [1, 2, 3, 4, 5, 6, 8]
isJoyo Nothing  = False

readIntT :: Text -> Maybe Int
readIntT t = case reads (T.unpack t) of
  [(n, "")] -> Just n
  _         -> Nothing

readHexT :: Text -> Maybe Int
readHexT t = case readHex (T.unpack t) of
  [(n, "")] -> Just n
  _         -> Nothing

-- Variant cross-references --------------------------------------------------

-- | Variant cross-references between characters, as (character, variant)
-- codepoint pairs. KANJIDIC2 gives a variant as a JIS or UCS code
-- (@\<variant var_type="jis208"\>1-52-06\</variant\>@ under 図, i.e. 圖);
-- JIS codes are resolved through the @cp_value@s of all characters. Index
-- codes that name no character (De Roo, Nelson, …) resolve to nothing.
variantLinks :: XML.Document -> [(Int, Int)]
variantLinks doc =
  [ (cp, v)
  | (cp, c) <- chars
  , var     <- c $/ element "misc" &/ element "variant"
  , vt      <- attribute "var_type" var
  , val     <- var $/ content
  , Just v  <- [resolve vt val]
  , v /= cp
  ]
  where
    chars = [ (cp, c) | c <- fromDocument doc $// element "character"
                      , Just cp <- [readHexT =<< ucsHex c] ]
    codes = Map.fromList
      [ ((ty, val), cp)
      | (cp, c) <- chars
      , cv  <- c $/ element "codepoint" &/ element "cp_value"
      , ty  <- attribute "cp_type" cv
      , val <- cv $/ content
      ]
    resolve "ucs" val = readHexT val
    resolve vt val    = Map.lookup (vt, val) codes

-- | 'variantLinks' of a KANJIDIC2 file.
readVariantLinks :: FilePath -> IO [(Int, Int)]
readVariantLinks path = variantLinks <$> XML.readFile XML.def path

-- | 'variantLinks' from KANJIDIC2 XML text (used by the tests).
variantLinksFromText :: TL.Text -> Either String [(Int, Int)]
variantLinksFromText = either (Left . show) (Right . variantLinks) . XML.parseText XML.def

-- Writing ------------------------------------------------------------------

ingest :: Pipe -> FilePath -> IO IngestStats
ingest pipe path = do
  doc <- XML.readFile XML.def path
  let pcs = parseDocument doc
  writeChars pipe pcs
  pure IngestStats
    { statChars    = length pcs
    , statReadings = sum (map (length . pcReadings) pcs)
    }

batchSize :: Int
batchSize = 256

writeChars :: Pipe -> [PChar] -> IO ()
writeChars pipe pcs =
  forM_ (chunksOf batchSize pcs) $ \batch ->
    run pipe $ queryP upsertCypher
      (Map.fromList [("rows", L (map charToRow batch))]) >> pure ()

upsertCypher :: Text
upsertCypher =
  "UNWIND $rows AS row \
  \MERGE (s:Sign {codepoint: row.codepoint}) \
  \SET s.literal = row.literal, s.radical = row.radical, \
  \    s.strokes = row.strokes, s.joyo = row.joyo, s.unihanId = row.unihanId \
  \WITH s, row \
  \UNWIND row.readings AS rd \
  \MERGE (r:Reading {value: rd.value, type: rd.type}) \
  \MERGE (s)-[h:HAS_READING]->(r) \
  \SET h.okurigana = rd.okurigana"

charToRow :: PChar -> Value
charToRow pc = M $ Map.fromList
  [ ("codepoint", I (pcCodepoint pc))
  , ("literal",   T (pcLiteral pc))
  , ("radical",   maybeI (pcRadical pc))
  , ("strokes",   maybeI (pcStrokes pc))
  , ("joyo",      B (pcJoyo pc))
  , ("unihanId",  T (unihanId (pcCodepoint pc)))
  , ("readings",  L (readingRows (pcReadings pc)))
  ]

-- | One row per (reading, type) of a character. A kun reading carries the list
-- of its okurigana splits, an on reading none.
readingRows :: [PReading] -> [Value]
readingRows prs =
  [ M $ Map.fromList
      [ ("value",     T v)
      , ("type",      T (kindText k))
      , ("okurigana", okurigana k oks)
      ]
  | ((v, k), oks) <- Map.toList grouped
  ]
  where
    grouped = Map.fromListWith (flip (<>)) [ ((prValue p, prKind p), [prOkurigana p]) | p <- prs ]
    okurigana On  _   = N ()
    okurigana Kun oks = L (map (T . fromMaybe "") (nubOrd oks))

kindText :: RKind -> Text
kindText On  = "on"
kindText Kun = "kun"

unihanId :: Int -> Text
unihanId cp = "U+" <> T.justifyRight 4 '0' (T.toUpper (T.pack (showHex cp "")))

maybeI :: Maybe Int -> Value
maybeI = maybe (N ()) I

chunksOf :: Int -> [a] -> [[a]]
chunksOf _ [] = []
chunksOf n xs = let (h, t) = splitAt n xs in h : chunksOf n t
