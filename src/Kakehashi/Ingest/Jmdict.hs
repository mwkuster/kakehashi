-- | JMdict XML ingest (Phase 1).
--
-- Parses the EDRDG JMdict file into Lexeme nodes (one per kanji-writing /
-- reading pair) and links each to the Sign nodes its orthography is written
-- with (@WRITTEN_WITH@). Kanji are matched against Signs already loaded from
-- KANJIDIC2 — run @ingest kanjidic@ first.
--
-- Search-only forms (kanji forms tagged @ke_inf@ @sK@, readings tagged
-- @re_inf@ @sk@) are skipped: JMdict keeps them only so that searches find the
-- entry, they are not forms in use. A (reading, writing) pair that JMdict lists
-- in several entries becomes one Lexeme with the union of their POS and
-- priority tags and of their senses ('mergeLexemes').
--
-- DOM via @Text.XML.Cursor@. JMdict's DTD entities (@&v5r;@, @&n;@, …) are
-- kept as their bare names by 'decodeEntity', so @<pos>&v5r;</pos>@ ingests as
-- the POS code @"v5r"@. (At ~60 MB DOM is comfortable in memory; switch to a
-- streaming parser if inputs grow.)
module Kakehashi.Ingest.Jmdict
  ( IngestStats (..)
  , ingest
    -- * Pure parsing (exposed for testing)
  , PLexeme (..)
  , lexemesFromText
  , mergeLexemes
  ) where

import Control.Monad (forM_)
import Data.Containers.ListUtils (nubOrd, nubOrdOn)
import Data.List (nub)
import qualified Data.Map.Strict as Map
import Data.Maybe (catMaybes)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Lazy as TL
import Data.XML.Types (Content (..))
import Kakehashi.Bolt (Pipe, Value (..), queryP, run)
import qualified Text.XML as XML
import Text.XML.Cursor

import Kakehashi.Kanji (kanjiCodepoints)

-- Parsed shapes ------------------------------------------------------------

-- | One (reading, kanji-writing) pairing — a Lexeme plus the kanji codepoints
-- its orthography contains and the senses (Concepts) it means.
data PLexeme = PLexeme
  { plPhonology   :: !Text
  , plOrthography :: !Text
  , plPos         :: !(Maybe Text)
  , plPriority    :: !(Maybe Text)  -- ^ this writing's @ke_pri@ tags (news1, ichi1, …)
  , plSigns       :: ![Int]
  , plConcepts    :: ![(Text, Text)]  -- ^ (conceptId, gloss) senses this writing means
  }
  deriving (Eq, Show)

-- | A JMdict @\<sense\>@: a Concept skeleton plus the kanji/reading it is
-- restricted to (@stagk@/@stagr@; empty = applies to all).
data Sense = Sense
  { senseId    :: !Text
  , senseStagk :: ![Text]
  , senseStagr :: ![Text]
  , senseGloss :: !Text
  }
  deriving (Eq, Show)

data IngestStats = IngestStats
  { statLexemes  :: !Int  -- ^ Lexeme nodes written
  , statLinks    :: !Int  -- ^ WRITTEN_WITH edges attempted (matched if Sign exists)
  , statConcepts :: !Int  -- ^ MEANS edges (Lexeme → Concept)
  }
  deriving (Eq, Show)

-- Parsing ------------------------------------------------------------------

parseEntry :: Cursor -> [PLexeme]
parseEntry e =
  [ PLexeme
      { plPhonology   = reb
      , plOrthography = keb
      , plPos         = pos
      , plPriority    = joinTags (Map.findWithDefault [] keb priorities)
      , plSigns       = kanjiCodepoints keb
      , plConcepts    = [ (senseId s, senseGloss s) | s <- senses, applies keb reb s ]
      }
  | r          <- e $/ element "r_ele"
  , (reb, keb) <- rElePairs kebs r
  ]
  where
    -- each k_ele: its keb and the ke_pri tags that mark how common that
    -- writing is; search-only forms (ke_inf sK) are not writings and skipped
    kEles      = [ (keb, k $/ element "ke_pri" &/ content)
                 | k   <- e $/ element "k_ele"
                 , "sK" `notElem` (k $/ element "ke_inf" &/ content)
                 , keb <- k $/ element "keb" &/ content
                 ]
    kebs       = map fst kEles
    priorities = Map.fromList kEles
    pos        = joinTags (nub (e $/ element "sense" &/ element "pos" &/ content))
    senses     = parseSenses e

-- | A sense applies to a (keb, reb) pair unless restricted away by stagk/stagr.
applies :: Text -> Text -> Sense -> Bool
applies keb reb s =
     (null (senseStagk s) || keb `elem` senseStagk s)
  && (null (senseStagr s) || reb `elem` senseStagr s)

-- | Parse an entry's senses into Concept skeletons, keyed @entSeq:index@.
-- Senses with no English gloss (xref-only) are dropped.
parseSenses :: Cursor -> [Sense]
parseSenses e =
  [ Sense
      { senseId    = entSeq <> ":" <> tshow i
      , senseStagk = s $/ element "stagk" &/ content
      , senseStagr = s $/ element "stagr" &/ content
      , senseGloss = gloss
      }
  | (i, s) <- zip [1 :: Int ..] (e $/ element "sense")
  , let gloss = T.intercalate "; " (s $/ element "gloss" &/ content)
  , not (T.null gloss)
  ]
  where
    entSeq = T.concat (e $/ element "ent_seq" &/ content)

joinTags :: [Text] -> Maybe Text
joinTags [] = Nothing
joinTags ts = Just (T.intercalate "," ts)

tshow :: Show a => a -> Text
tshow = T.pack . show

-- | Pair a reading element with the kanji writings it applies to, honouring
-- @re_nokanji@ (kana-only reading → no kanji writing) and @re_restr@ (reading
-- limited to specific writings). With neither, the reading applies to all.
-- Search-only readings (re_inf sk) pair with nothing, and a @re_restr@ that
-- names only search-only writings leaves the reading without a writing.
rElePairs :: [Text] -> Cursor -> [(Text, Text)]
rElePairs kebs r
  | nokanji || searchOnly || T.null reb = []
  | otherwise                           = [ (reb, keb) | keb <- targets ]
  where
    reb        = T.concat (r $/ element "reb" &/ content)
    nokanji    = not (null (r $/ element "re_nokanji"))
    searchOnly = "sk" `elem` (r $/ element "re_inf" &/ content)
    restr      = r $/ element "re_restr" &/ content
    targets    = if null restr then kebs else filter (`elem` kebs) restr

-- | One Lexeme per (reading, writing). JMdict lists some pairs in several
-- entries (homographs such as 家 うち); merging keeps the union of their POS
-- and priority tags and of their senses, instead of letting the last entry
-- overwrite the others when the rows are MERGEd into the graph.
mergeLexemes :: [PLexeme] -> [PLexeme]
mergeLexemes ls =
  Map.elems (Map.fromListWith (flip combine)
               [ ((plPhonology l, plOrthography l), l) | l <- ls ])
  where
    combine a b = a
      { plPos      = unionTags (plPos a) (plPos b)
      , plPriority = unionTags (plPriority a) (plPriority b)
      , plConcepts = nubOrdOn fst (plConcepts a <> plConcepts b)
      }

unionTags :: Maybe Text -> Maybe Text -> Maybe Text
unionTags a b = joinTags (nubOrd (concatMap (T.splitOn ",") (catMaybes [a, b])))

-- | All Lexemes of a JMdict document, merged across entries.
lexemesFromDocument :: XML.Document -> [PLexeme]
lexemesFromDocument doc =
  mergeLexemes (concatMap parseEntry (fromDocument doc $// element "entry"))

-- | 'lexemesFromDocument' from JMdict XML text (used by the tests).
lexemesFromText :: TL.Text -> Either String [PLexeme]
lexemesFromText =
  either (Left . show) (Right . lexemesFromDocument) . XML.parseText parseSettings

-- Writing ------------------------------------------------------------------

ingest :: Pipe -> FilePath -> IO IngestStats
ingest pipe path = do
  doc <- XML.readFile parseSettings path
  let lexemes = lexemesFromDocument doc
  writeLexemes pipe lexemes
  pure IngestStats
    { statLexemes  = length lexemes
    , statLinks    = sum (map (length . plSigns) lexemes)
    , statConcepts = sum (map (length . plConcepts) lexemes)
    }

-- | Keep JMdict's DTD entities as their bare names (mapping the five XML
-- predefined entities to their characters).
parseSettings :: XML.ParseSettings
parseSettings = XML.def { XML.psDecodeEntities = decodeEntity }

decodeEntity :: Text -> Content
decodeEntity "amp"  = ContentText "&"
decodeEntity "lt"   = ContentText "<"
decodeEntity "gt"   = ContentText ">"
decodeEntity "quot" = ContentText "\""
decodeEntity "apos" = ContentText "'"
decodeEntity e      = ContentText e

batchSize :: Int
batchSize = 500

writeLexemes :: Pipe -> [PLexeme] -> IO ()
writeLexemes pipe lexemes =
  forM_ (chunksOf batchSize lexemes) $ \batch -> do
    let rows = Map.fromList [("rows", L (map lexRow batch))]
    run pipe $ queryP lexemeCypher rows >> pure ()
    run pipe $ queryP conceptCypher rows >> pure ()

-- Lexeme nodes + WRITTEN_WITH to existing Signs.
lexemeCypher :: Text
lexemeCypher =
  "UNWIND $rows AS row \
  \MERGE (l:Lexeme {phonology: row.phonology, orthography: row.orthography}) \
  \SET l.pos = row.pos, l.priority = row.priority, l.kanjiCount = size(row.signs) \
  \WITH l, row \
  \UNWIND row.signs AS cp \
  \MATCH (s:Sign {codepoint: cp}) \
  \MERGE (l)-[:WRITTEN_WITH]->(s)"

-- Concept nodes + MEANS edges. Separate pass so kanji-less lexemes (whose
-- WRITTEN_WITH UNWIND is empty) still receive their senses.
conceptCypher :: Text
conceptCypher =
  "UNWIND $rows AS row \
  \UNWIND row.concepts AS c \
  \MERGE (l:Lexeme {phonology: row.phonology, orthography: row.orthography}) \
  \MERGE (concept:Concept {id: c.id}) \
  \SET concept.gloss = c.gloss \
  \MERGE (l)-[:MEANS]->(concept)"

lexRow :: PLexeme -> Value
lexRow l = M $ Map.fromList
  [ ("phonology",   T (plPhonology l))
  , ("orthography", T (plOrthography l))
  , ("pos",         maybe (N ()) T (plPos l))
  , ("priority",    maybe (N ()) T (plPriority l))
  , ("signs",       L (map I (plSigns l)))
  , ("concepts",    L [ M (Map.fromList [("id", T cid), ("gloss", T g)])
                      | (cid, g) <- plConcepts l ])
  ]

chunksOf :: Int -> [a] -> [[a]]
chunksOf _ [] = []
chunksOf n xs = let (h, t) = splitAt n xs in h : chunksOf n t
