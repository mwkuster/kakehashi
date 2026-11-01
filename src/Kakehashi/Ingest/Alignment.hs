{-# LANGUAGE RecordWildCards #-}

-- | Load curated Alignment records from a filled TOML curation file
-- (Phase 2, slice 4). Reifies each curated (lexeme, sign, concept, sinitic)
-- alignment as an :Alignment node carrying basis / period / confidence /
-- sources / notes, links it to its parts, records the model's @IMPORTED_FROM@
-- (Concept→SiniticSense) anchor, and joins competing alignments with
-- @:DISPUTES@. Uncurated (all-blank) rows are skipped, so a freshly generated
-- skeleton loads nothing.
--
-- Disagreement is recorded, not resolved by overwriting: an Alignment (or set
-- classification) that already exists with a different judgement is left
-- unchanged and reported as a conflict. A competing judgement belongs in a new
-- record with its own id and @disputes = "<id>"@; @--replace@ overrides this
-- for corrections of one's own records.
module Kakehashi.Ingest.Alignment
  ( LoadStats (..)
  , AlignmentRow (..)
  , CurationFile (..)
  , parseCuration
  , loadAlignments
  , sameAlignment
  ) where

import Control.Monad (filterM, forM_, when)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, listToMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Database.Bolt (Pipe, Value (..), queryP, run)
import Text.Read (readMaybe)
import Toml (Result (..), decode)
import Toml.Schema (FromValue (..), ParseTable, optKey, parseTableFromValue, reqKey)

data AlignmentRow = AlignmentRow
  { arId            :: !Text
  , arWriting       :: !Text
  , arSign          :: !Text
  , arConcept       :: !Text
  , arSinitic       :: !Text
  , arPeriodReading :: !Text
  , arPeriodSense   :: !Text
  , arBasis         :: !Text
  , arConfidence    :: !Text
  , arSources       :: ![Text]
  , arNotes         :: !Text
  , arDisputes      :: !(Maybe Text)
  }
  deriving (Eq, Show)

data CurationFile = CurationFile
  { cfReading           :: !Text
  , cfRows              :: ![AlignmentRow]
  , cfOjEtymon          :: !Text   -- ^ single | distinct | mixed
  , cfPeriodHomophonous :: !Text   -- ^ yes | no | unknown
  , cfClass             :: !Text   -- ^ split | disambiguation | oj-artifact | mixed
  , cfOjNotes           :: !Text
  , cfOjSources         :: ![Text]
  }
  deriving (Eq, Show)

data LoadStats = LoadStats
  { statLoaded        :: !Int
  , statSkipped       :: !Int
  , statDisputes      :: !Int
  , statClassified    :: !Bool    -- ^ a set classification was written
  , statConflicts     :: ![Text]  -- ^ ids left unchanged: stored with a different judgement
  , statClassConflict :: !Bool    -- ^ the stored set classification differs and was kept
  }
  deriving (Eq, Show)

-- Decoding -----------------------------------------------------------------

opt :: Text -> ParseTable l Text
opt k = fromMaybe "" <$> optKey k

instance FromValue AlignmentRow where
  fromValue = parseTableFromValue $ do
    arId            <- reqKey "id"
    arWriting       <- reqKey "writing"
    arSign          <- reqKey "sign"
    arConcept       <- opt "concept"
    arSinitic       <- opt "sinitic"
    arPeriodReading <- opt "period_reading"
    arPeriodSense   <- opt "period_sense"
    arBasis         <- opt "basis"
    arConfidence    <- opt "confidence"
    arSources       <- fromMaybe [] <$> optKey "sources"
    arNotes         <- opt "notes"
    arDisputes      <- optKey "disputes"
    pure AlignmentRow {..}

instance FromValue CurationFile where
  fromValue = parseTableFromValue $ do
    cfReading           <- reqKey "reading"
    cfRows              <- fromMaybe [] <$> optKey "alignment"
    cfOjEtymon          <- opt "oj_etymon"
    cfPeriodHomophonous <- opt "period_homophonous"
    cfClass             <- opt "class"
    cfOjNotes           <- opt "oj_notes"
    cfOjSources         <- fromMaybe [] <$> optKey "oj_sources"
    pure CurationFile {..}

-- | True once the curator has filled any set-classification field.
isClassified :: CurationFile -> Bool
isClassified cf =
  any (not . T.null) [cfOjEtymon cf, cfPeriodHomophonous cf, cfClass cf, cfOjNotes cf]
  || not (null (cfOjSources cf))

parseCuration :: Text -> Either String CurationFile
parseCuration t = case decode t of
  Success _ cf -> Right cf
  Failure errs -> Left (unlines errs)

-- | A row counts as curated once any judgement field is filled in.
isCurated :: AlignmentRow -> Bool
isCurated r =
  any (not . T.null)
      [ arBasis r, arPeriodReading r, arPeriodSense r, arConfidence r, arNotes r ]
  || not (null (arSources r))

-- Loading ------------------------------------------------------------------

loadAlignments :: Pipe -> Bool -> FilePath -> IO (Either String LoadStats)
loadAlignments pipe replace path = do
  txt <- TIO.readFile path
  case parseCuration txt of
    Left err -> pure (Left err)
    Right cf -> do
      let curated = filter isCurated (cfRows cf)
      writable <- if replace then pure curated else filterM (canWrite pipe) curated
      let conflicts = [ arId r | r <- curated, arId r `notElem` map arId writable ]
          disputes  = [ (arId r, d) | r <- writable, Just d <- [arDisputes r], not (T.null d) ]
          classify  = isClassified cf
      forM_ writable (writeAlignment pipe (cfReading cf))
      forM_ disputes (writeDispute pipe)
      classOk <- if classify && not replace then canClassify pipe cf else pure True
      when (classify && classOk) (writeClassification pipe cf)
      pure $ Right LoadStats
        { statLoaded        = length writable
        , statSkipped       = length (cfRows cf) - length curated
        , statDisputes      = length disputes
        , statClassified    = classify && classOk
        , statConflicts     = conflicts
        , statClassConflict = classify && not classOk
        }

-- | A row may be written if no Alignment with its id exists yet, or if the
-- stored one carries the same judgement (reloading a file is idempotent).
canWrite :: Pipe -> AlignmentRow -> IO Bool
canWrite pipe r = do
  recs <- run pipe (queryP
    "MATCH (a:Alignment {id: $id}) \
    \RETURN a.basis AS basis, a.period AS period, a.periodSense AS periodSense, \
    \       a.confidence AS confidence, a.sources AS sources, a.notes AS notes"
    (Map.fromList [("id", T (arId r))]))
  pure (maybe True (`sameAlignment` r) (listToMaybe recs))

-- | Does a stored Alignment (its judgement fields) match a curated row?
sameAlignment :: Map Text Value -> AlignmentRow -> Bool
sameAlignment stored r =
     txt "basis" == arBasis r
  && txt "period" == arPeriodReading r
  && txt "periodSense" == arPeriodSense r
  && txt "notes" == arNotes r
  && conf == (readMaybe (T.unpack (arConfidence r)) :: Maybe Double)
  && srcs == arSources r
  where
    txt k = case Map.lookup k stored of Just (T t) -> t; _ -> ""
    conf  = case Map.lookup "confidence" stored of
      Just (F d) -> Just d
      Just (I i) -> Just (fromIntegral i)
      _          -> Nothing
    srcs  = case Map.lookup "sources" stored of
      Just (L vs) -> [ t | T t <- vs ]
      _           -> []

-- | The set classification may be written if none is stored for the reading or
-- the stored one is the same.
canClassify :: Pipe -> CurationFile -> IO Bool
canClassify pipe cf = do
  recs <- run pipe (queryP
    "MATCH (hs:HomophoneSet {reading: $reading}) \
    \RETURN hs.ojEtymon AS ojEtymon, hs.periodHomophonous AS periodHomo, \
    \       hs.class AS class, hs.ojNotes AS ojNotes, hs.ojSources AS ojSources"
    (Map.fromList [("reading", T (cfReading cf))]))
  pure $ case listToMaybe recs of
    Nothing  -> True
    Just rec ->
         txt rec "ojEtymon" == cfOjEtymon cf
      && txt rec "periodHomo" == cfPeriodHomophonous cf
      && txt rec "class" == cfClass cf
      && txt rec "ojNotes" == cfOjNotes cf
      && list rec "ojSources" == cfOjSources cf
  where
    txt rec k  = case Map.lookup k rec of Just (T t) -> t; _ -> ""
    list rec k = case Map.lookup k rec of Just (L vs) -> [ t | T t <- vs ]; _ -> []

-- | Reify the set classification on a :HomophoneSet node, linked to its writings.
writeClassification :: Pipe -> CurationFile -> IO ()
writeClassification pipe cf =
  run pipe (queryP cy params >> pure ())
  where
    writings = [ arWriting r | r <- cfRows cf ]
    params = Map.fromList
      [ ("reading",     T (cfReading cf))
      , ("ojEtymon",    T (cfOjEtymon cf))
      , ("periodHomo",  T (cfPeriodHomophonous cf))
      , ("class",       T (cfClass cf))
      , ("ojNotes",     T (cfOjNotes cf))
      , ("ojSources",   L (map T (cfOjSources cf)))
      , ("writings",    L (map T writings))
      ]
    cy =
      "MERGE (hs:HomophoneSet {reading: $reading}) \
      \SET hs.ojEtymon = $ojEtymon, hs.periodHomophonous = $periodHomo, \
      \    hs.class = $class, hs.ojNotes = $ojNotes, hs.ojSources = $ojSources \
      \WITH hs \
      \UNWIND $writings AS w \
      \MATCH (l:Lexeme {phonology: $reading, orthography: w}) \
      \MERGE (hs)-[:SET_INCLUDES]->(l)"

writeAlignment :: Pipe -> Text -> AlignmentRow -> IO ()
writeAlignment pipe reading r =
  run pipe (queryP alignmentCypher params >> pure ())
  where
    params = Map.fromList
      [ ("id",          T (arId r))
      , ("reading",     T reading)
      , ("writing",     T (arWriting r))
      , ("sign",        T (arSign r))
      , ("concept",     T (arConcept r))
      , ("sinitic",     T (arSinitic r))
      , ("basis",       T (arBasis r))
      , ("period",      T (arPeriodReading r))
      , ("periodSense", T (arPeriodSense r))
      , ("confidence",  confidenceVal (arConfidence r))
      , ("sources",     L (map T (arSources r)))
      , ("notes",       T (arNotes r))
      ]

confidenceVal :: Text -> Value
confidenceVal t = maybe (N ()) F (readMaybe (T.unpack t) :: Maybe Double)

-- Reify the alignment, link it to lexeme/sign/concept/sinitic (those that
-- resolve), and record the Concept→SiniticSense IMPORTED_FROM anchor.
alignmentCypher :: Text
alignmentCypher =
  "MERGE (a:Alignment {id: $id}) \
  \SET a.basis = $basis, a.period = $period, a.periodSense = $periodSense, \
  \    a.confidence = $confidence, a.sources = $sources, a.notes = $notes, \
  \    a.source = 'curated' \
  \WITH a \
  \MATCH (l:Lexeme {phonology: $reading, orthography: $writing}) \
  \MERGE (a)-[:ALIGNS_LEXEME]->(l) \
  \WITH a \
  \OPTIONAL MATCH (s:Sign {literal: $sign}) \
  \FOREACH (_ IN CASE WHEN s IS NULL THEN [] ELSE [1] END | \
  \         MERGE (a)-[:ALIGNS_SIGN]->(s)) \
  \WITH a \
  \OPTIONAL MATCH (c:Concept {id: $concept}) \
  \OPTIONAL MATCH (ss:SiniticSense {id: $sinitic}) \
  \FOREACH (_ IN CASE WHEN c IS NULL THEN [] ELSE [1] END | \
  \         MERGE (a)-[:ALIGNS_CONCEPT]->(c)) \
  \FOREACH (_ IN CASE WHEN ss IS NULL THEN [] ELSE [1] END | \
  \         MERGE (a)-[:ALIGNS_SINITIC]->(ss)) \
  \FOREACH (_ IN CASE WHEN c IS NULL OR ss IS NULL THEN [] ELSE [1] END | \
  \         MERGE (c)-[:IMPORTED_FROM]->(ss))"

writeDispute :: Pipe -> (Text, Text) -> IO ()
writeDispute pipe (aid, other) =
  run pipe (queryP cy (Map.fromList [("a", T aid), ("b", T other)]) >> pure ())
  where
    cy = "MATCH (a:Alignment {id: $a}), (b:Alignment {id: $b}) \
         \MERGE (a)-[:DISPUTES]->(b)"
