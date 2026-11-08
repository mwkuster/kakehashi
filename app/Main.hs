module Main where

import Control.Monad (forM_)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Options.Applicative
import System.Directory (doesFileExist)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

import qualified Kakehashi.Export.Csv as Csv
import qualified Kakehashi.Export.Latex as Latex
import Kakehashi.Graph
  (Pipe, applySchema, roundTripSign, schemaFiles, withDefaultConnection)
import qualified Kakehashi.Ingest.Alignment as Alignment
import qualified Kakehashi.Ingest.BaxterSagart as BaxterSagart
import qualified Kakehashi.Ingest.Jmdict as Jmdict
import qualified Kakehashi.Ingest.Kanjidic as Kanjidic
import qualified Kakehashi.Ingest.Kyujitai as Kyujitai
import qualified Kakehashi.Ingest.Sinitic as Sinitic
import qualified Kakehashi.Ingest.Similarity as Similarity
import qualified Kakehashi.Ingest.Unihan as Unihan
import Kakehashi.Model (Sign (..))
import Kakehashi.Export.Curation (renderCuration, writeCuration)
import Kakehashi.Export.Worksheet (renderWorksheet, writeWorksheet)
import Kakehashi.Query.Homophone
  (HomophoneFilter (..), HomophoneSet (..), Writing (..), discoverAll)
import Kakehashi.Query.Eval
  (EvalPair (..), fetchActuals, fetchPool, samplePairs, siniticSources, sourceCoverage)
import qualified Kakehashi.Query.Lens as Lens
import Kakehashi.Query.Report (corpusReport)
import Kakehashi.Query.Worksheet (worksheetFor, wsRows)

data Cmd
  = InitDb
  | Ingest IngestOpts
  | Homophones HomophonesOpts
  | Worksheet WorksheetOpts
  | Curate WorksheetOpts
  | Align FilePath Bool
  | EvalPairs EvalOpts
  | SimLoad FilePath
  | BridgeKyujitai BridgeOpts
  | Lens LensCmd
  | Report (Maybe FilePath)

data BridgeOpts = BridgeOpts
  { boVariants :: FilePath
  , boKanjidic :: FilePath
  , boCurated  :: FilePath
  }

data LensCmd
  = LReading Text
  | LSign Text
  | LConcept Text
  | LAlignment (Maybe Text)
  | LOkurigana Text

data EvalOpts = EvalOpts
  { eoSeed   :: Int
  , eoSource :: Text
  , eoSample :: Maybe Int
  , eoOut    :: Maybe FilePath
  }

data WorksheetOpts = WorksheetOpts
  { woReading :: Text
  , woCommon  :: Bool
  , woOut     :: Maybe FilePath
  }

data IngestOpts = IngestOpts
  { ingestSource :: String
  , ingestFile   :: FilePath
  , ingestAs     :: Maybe Text  -- ^ SiniticSense source tag for `ingest sinitic`
  }

data HomophonesOpts = HomophonesOpts
  { hoMinSize  :: Int
  , hoPos      :: Maybe Text
  , hoVerbs    :: Bool
  , hoJoyoOnly :: Bool
  , hoCommon   :: Bool
  , hoLimit    :: Maybe Int
  , hoCsv      :: Maybe FilePath
  , hoLatex    :: Maybe FilePath
  }

main :: IO ()
main = do
  cmd <- execParser opts
  case cmd of
    InitDb       -> initDb
    Ingest o     -> ingest o
    Homophones o -> homophones o
    Worksheet o  -> worksheet o
    Curate o     -> curate o
    Align f r    -> align f r
    EvalPairs o  -> evalPairs o
    SimLoad f    -> simLoad f
    BridgeKyujitai o -> bridgeKyujitai o
    Lens lc      -> lens lc
    Report out   -> report out

-- | Step B: link shinjitai Signs to their kyūjitai's non-Unihan senses
-- (Baxter–Sagart, Wiktionary, …), and report the coverage lift per source.
bridgeKyujitai :: BridgeOpts -> IO ()
bridgeKyujitai o = withDefaultConnection $ \pipe -> do
  sources <- siniticSources pipe
  before  <- mapM (sourceCoverage pipe) sources
  vtxt  <- TIO.readFile (boVariants o)
  ctxt  <- readIfExists (boCurated o)
  links <- Kanjidic.readVariantLinks (boKanjidic o)
  let unihan  = Kyujitai.shinKyuPairsFromVariants vtxt
      curated = Kyujitai.parseCuratedPairs ctxt
      pairs   = Kyujitai.confirmedPairs links curated unihan
  Kyujitai.bridge pipe pairs
  after <- mapM (sourceCoverage pipe) sources
  putStrLn $ "kakehashi: kyūjitai bridge — " <> show (length pairs) <> " old/new pairs ("
          <> show (length unihan) <> " Unihan candidates, kept where KANJIDIC2 confirms; "
          <> show (length curated) <> " curated)"
  forM_ (zip3 sources before after) $ \(src, (b, total), (a, _)) ->
    putStrLn $ "kakehashi:   " <> T.unpack src <> " coverage of the population's signs: "
            <> show b <> " → " <> show a <> "/" <> show total
            <> " (" <> pct a total <> ")"

readIfExists :: FilePath -> IO Text
readIfExists f = do
  ok <- doesFileExist f
  if ok then TIO.readFile f else pure ""

-- | Graph-derived corpus & findings report (Markdown).
report :: Maybe FilePath -> IO ()
report out = withDefaultConnection $ \pipe -> do
  md <- corpusReport pipe
  case out of
    Nothing -> TIO.putStr md
    Just f  -> do
      TIO.writeFile f md
      putStrLn $ "kakehashi: wrote report " <> f

-- | F1–F4 / F6 lens views. Okurigana (F6) is pure — no DB connection needed.
lens :: LensCmd -> IO ()
lens (LOkurigana o)   = printSections (Lens.okuriganaSections o)
lens (LReading r)     = withDbLens (\p -> Lens.readingLens p r)
lens (LSign s)        = withDbLens (\p -> Lens.signLens p s)
lens (LConcept q)     = withDbLens (\p -> Lens.conceptLens p q)
lens (LAlignment mid) = withDbLens (\p -> Lens.alignmentLens p mid)

withDbLens :: (Pipe -> IO [Lens.Section]) -> IO ()
withDbLens f = withDefaultConnection (\p -> f p >>= printSections)

printSections :: [Lens.Section] -> IO ()
printSections = TIO.putStr . T.unlines . concatMap render
  where
    render (title, hdr, rows) =
      ["## " <> title, ""]
        <> (if null rows
              then ["_(no results)_"]
              else mdRow hdr : mdRow (map (const "---") hdr) : map mdRow rows)
        <> [""]
    mdRow cs = "| " <> T.intercalate " | " cs <> " |"

-- | Phase 3: write precomputed meaning-similarity scores onto WRITTEN_WITH edges.
simLoad :: FilePath -> IO ()
simLoad f = withDefaultConnection $ \pipe -> do
  n <- Similarity.loadSimilarities pipe f
  putStrLn $ "kakehashi: set meaningSim on " <> show n <> " writings from " <> f

-- | Phase 3 slice 1: export the actual+control gloss-pair dataset for RQ3.
evalPairs :: EvalOpts -> IO ()
evalPairs o = withDefaultConnection $ \pipe -> do
  actuals <- fetchActuals pipe (eoSource o)
  pool    <- fetchPool pipe (eoSource o)
  let pairs = samplePairs (eoSeed o) (eoSample o) actuals pool
      csv   = T.unlines (evalHeader : map evalRow pairs)
  case eoOut o of
    Nothing -> TIO.putStr csv
    Just f  -> do
      TIO.writeFile f csv
      putStrLn $ "kakehashi: wrote " <> f <> " (" <> show (length pairs)
              <> " rows = " <> show (length pairs `div` 2) <> " pairs; pool "
              <> show (length pool) <> ")"

evalHeader :: Text
evalHeader = csvLine ["pair_id", "kind", "reading", "orthography", "sign", "native_gloss", "sinitic_gloss"]

evalRow :: EvalPair -> Text
evalRow p = csvLine
  [ T.pack (show (epPairId p)), epKind p, epReading p, epOrth p
  , epSign p, epNative p, epSinitic p ]

csvLine :: [Text] -> Text
csvLine = T.intercalate "," . map Csv.csvField

-- | Phase 2 slice 4: load curated Alignment records from a filled TOML file.
-- Records stored with a different judgement are kept unless @--replace@.
align :: FilePath -> Bool -> IO ()
align f replace = withDefaultConnection $ \pipe -> do
  ensureSchema pipe
  result <- Alignment.loadAlignments pipe replace f
  case result of
    Left err -> do
      hPutStrLn stderr ("kakehashi: could not parse " <> f <> ":\n" <> err)
      exitFailure
    Right s -> do
      putStrLn $ "kakehashi: loaded " <> show (Alignment.statLoaded s)
              <> " alignment(s), " <> show (Alignment.statDisputes s) <> " dispute edge(s); skipped "
              <> show (Alignment.statSkipped s) <> " uncurated row(s)"
              <> (if Alignment.statClassified s then "; set classification stored" else "")
      let conflicts = Alignment.statConflicts s
      if null conflicts && not (Alignment.statClassConflict s)
        then pure ()
        else do
          forM_ conflicts $ \i ->
            hPutStrLn stderr ("kakehashi: kept the stored alignment " <> T.unpack i
                              <> " (it records a different judgement)")
          if Alignment.statClassConflict s
            then hPutStrLn stderr "kakehashi: kept the stored set classification (it differs)"
            else pure ()
          hPutStrLn stderr "kakehashi: record a competing judgement under a new id with \
                           \disputes = \"<id>\", or rerun with --replace to overwrite"
          exitFailure

-- | Phase 2 slice 3: emit a Markdown curation worksheet for one reading.
worksheet :: WorksheetOpts -> IO ()
worksheet o = withDefaultConnection $ \pipe -> do
  ws <- worksheetFor pipe (woCommon o) (woReading o)
  let md = renderWorksheet ws
  case woOut o of
    Nothing -> TIO.putStr md
    Just f  -> do
      writeWorksheet f ws
      putStrLn $ "kakehashi: wrote worksheet " <> f
              <> " (" <> show (length (wsRows ws)) <> " writings)"

-- | Phase 2 slice 4: emit the TOML curation skeleton for one reading.
curate :: WorksheetOpts -> IO ()
curate o = withDefaultConnection $ \pipe -> do
  ws <- worksheetFor pipe (woCommon o) (woReading o)
  case woOut o of
    Nothing -> TIO.putStr (renderCuration ws)
    Just f  -> do
      writeCuration f ws
      putStrLn $ "kakehashi: wrote curation file " <> f
              <> " (" <> show (length (wsRows ws)) <> " writings)"

-- | Dispatch an ingest by source kind.
ingest :: IngestOpts -> IO ()
ingest o = case ingestSource o of
  "kanjidic" -> withDefaultConnection $ \pipe -> do
    ensureSchema pipe
    stats <- Kanjidic.ingest pipe (ingestFile o)
    putStrLn $ "kakehashi: ingested " <> show (Kanjidic.statChars stats)
            <> " kanji, " <> show (Kanjidic.statReadings stats) <> " readings"
  "jmdict" -> withDefaultConnection $ \pipe -> do
    ensureSchema pipe
    stats <- Jmdict.ingest pipe (ingestFile o)
    putStrLn $ "kakehashi: ingested " <> show (Jmdict.statLexemes stats)
            <> " lexemes, " <> show (Jmdict.statLinks stats) <> " written-with links, "
            <> show (Jmdict.statConcepts stats) <> " concept (means) links"
  "sinitic" -> case ingestAs o of
    Nothing  -> failWith "kakehashi: ingest sinitic requires --as NAME (the SiniticSense source tag)"
    Just tag -> withDefaultConnection $ \pipe -> do
      ensureSchema pipe
      n <- Sinitic.ingestTsv pipe tag (ingestFile o)
      (covered, total) <- sourceCoverage pipe tag
      putStrLn $ "kakehashi: ingested " <> show n <> " '" <> T.unpack tag
              <> "' Sinitic senses (Sign-matched ones linked)"
      putStrLn $ "kakehashi: coverage of the population's signs: " <> show covered <> "/"
              <> show total <> " (" <> pct covered total <> ")"
  "unihan" -> withDefaultConnection $ \pipe -> do
    ensureSchema pipe
    stats <- Unihan.ingest pipe (ingestFile o)
    putStrLn $ "kakehashi: ingested " <> show (Unihan.statCandidates stats)
            <> " Sinitic-sense candidates (Sign-matched ones linked)"
  "baxter-sagart" -> withDefaultConnection $ \pipe -> do
    ensureSchema pipe
    stats <- BaxterSagart.ingest pipe (ingestFile o)
    (covered, total) <- sourceCoverage pipe "baxter-sagart"
    putStrLn $ "kakehashi: ingested " <> show (BaxterSagart.statRows stats)
            <> " B&S rows → " <> show (BaxterSagart.statSigns stats) <> " signs"
    putStrLn $ "kakehashi: coverage of the population's signs: " <> show covered <> "/"
            <> show total <> " (" <> pct covered total <> ")"
  other    -> failWith $ "kakehashi: unknown ingest source '" <> other
                      <> "' (expected: kanjidic | jmdict | unihan | baxter-sagart | sinitic)"

-- | Report an error on stderr and exit with a failure status.
failWith :: String -> IO ()
failWith msg = hPutStrLn stderr msg >> exitFailure

-- | Percentage as a string, guarding division by zero.
pct :: Int -> Int -> String
pct _ 0 = "n/a"
pct a b = show (round (100 * fromIntegral a / fromIntegral b :: Double) :: Int) <> "%"

-- | Apply the cypher/ schema (idempotent) before writing nodes.
ensureSchema :: Pipe -> IO ()
ensureSchema pipe = schemaFiles "cypher" >>= applySchema pipe

-- | F5: discover homophone-by-writing sets, print a summary + the top sets,
-- and optionally export CSV / LaTeX.
homophones :: HomophonesOpts -> IO ()
homophones o = withDefaultConnection $ \pipe -> do
  sets <- discoverAll pipe HomophoneFilter
    { hfMinSize  = hoMinSize o
    , hfPos      = hoPos o
    , hfVerbs    = hoVerbs o
    , hfJoyoOnly = hoJoyoOnly o
    , hfCommon   = hoCommon o
    }
  let shown = maybe id take (hoLimit o) sets
  putStrLn $ "kakehashi: " <> show (length sets)
          <> " homophone-by-writing sets (min size " <> show (hoMinSize o) <> ")"
          <> maybe "" (\p -> ", pos~" <> T.unpack p) (hoPos o)
          <> (if hoVerbs o then ", verbs" else "")
          <> (if hoJoyoOnly o then ", jōyō only" else "")
          <> (if hoCommon o then ", common only" else "")
  forM_ (take 25 shown) $ \hs ->
    TIO.putStrLn $ "  " <> hsPhonology hs <> " (" <> tshow (hsSize hs) <> "): "
                 <> T.intercalate " " (map wOrthography (hsWritings hs))
  forM_ (hoCsv o) $ \f -> do
    Csv.writeHomophoneSets f shown
    putStrLn $ "kakehashi: wrote CSV " <> f <> " (" <> show (length shown) <> " sets)"
  forM_ (hoLatex o) $ \f -> do
    Latex.writeHomophoneLongtable f shown
    putStrLn $ "kakehashi: wrote LaTeX " <> f <> " (" <> show (length shown) <> " sets)"

tshow :: Show a => a -> Text
tshow = T.pack . show

-- | Phase 0 smoke test: apply the cypher/ schema, then MERGE a sample Sign and
-- read it back to prove the driver round-trip works.
initDb :: IO ()
initDb = withDefaultConnection $ \pipe -> do
  files <- schemaFiles "cypher"
  applySchema pipe files
  putStrLn $ "kakehashi: applied schema (" <> show (length files) <> " file(s))"
  let sample = Sign
        { signCodepoint = 0x6E2C  -- 測
        , signRadical   = Just 85
        , signStrokes   = Just 12
        , signJoyo      = True
        , signUnihanId  = Just "U+6E2C"
        }
  cp <- roundTripSign pipe sample
  putStrLn $ "kakehashi: round-tripped Sign codepoint " <> show cp <> " (測) via Neo4j"

opts :: ParserInfo Cmd
opts = info (cmdParser <**> helper)
  ( fullDesc
 <> progDesc "Sign-Concept Mapper for Japanese (SCM-JP)"
 <> header "kakehashi — the bridge between Sinitic signs and Japanese meaning"
  )

cmdParser :: Parser Cmd
cmdParser = subparser
  ( command "init-db"
      (info (pure InitDb <**> helper)
            (progDesc "Apply the cypher/ schema and round-trip a sample Sign node"))
 <> command "ingest"
      (info (Ingest <$> ingestParser <**> helper)
            (progDesc "Ingest a source dataset (KANJIDIC2, JMdict, Unihan, Baxter–Sagart, any Sinitic TSV)"))
 <> command "homophones"
      (info (Homophones <$> homophonesParser <**> helper)
            (progDesc "Generate homophone-by-writing sets across the lexicon"))
 <> command "worksheet"
      (info (Worksheet <$> worksheetParser <**> helper)
            (progDesc "Emit a Markdown curation worksheet for one reading"))
 <> command "curate"
      (info (Curate <$> worksheetParser <**> helper)
            (progDesc "Emit a TOML curation skeleton for one reading (loader input)"))
 <> command "align"
      (info (Align <$> strArgument (metavar "FILE" <> help "Filled TOML curation file")
                   <*> switch (long "replace"
                         <> help "Overwrite stored records that carry a different judgement")
                   <**> helper)
            (progDesc "Load curated Alignment records from a TOML file"))
 <> command "eval-pairs"
      (info (EvalPairs <$> evalParser <**> helper)
            (progDesc "Export the actual+control gloss-pair dataset for RQ3 (CSV)"))
 <> command "sim-load"
      (info (SimLoad <$> strArgument (metavar "FILE" <> help "Scores CSV from eval/rq3.py") <**> helper)
            (progDesc "Store precomputed meaning-similarity on WRITTEN_WITH edges"))
 <> command "bridge-kyujitai"
      (info (BridgeKyujitai <$> bridgeParser <**> helper)
            (progDesc "Link shinjitai signs to their kyūjitai's non-Unihan Sinitic senses"))
 <> command "lens"
      (info (Lens <$> lensParser <**> helper)
            (progDesc "Lens views: reading (F1), sign (F2), concept (F3), alignment (F4), okurigana (F6)"))
 <> command "report"
      (info (Report <$> optional (strOption (long "out" <> metavar "FILE"
                                             <> help "Write report to FILE (default: stdout)"))
                    <**> helper)
            (progDesc "Graph-derived corpus & findings report (Markdown)"))
  )

ingestParser :: Parser IngestOpts
ingestParser = IngestOpts
  <$> strArgument (metavar "SOURCE" <> help "kanjidic | jmdict | unihan | baxter-sagart | sinitic")
  <*> strArgument (metavar "FILE" <> help "Source data file")
  <*> optional (strOption (long "as" <> metavar "NAME"
        <> help "For 'sinitic': the SiniticSense source tag (e.g. kroll, wiktionary)"))

homophonesParser :: Parser HomophonesOpts
homophonesParser = HomophonesOpts
  <$> option auto
        (long "min-size" <> metavar "N" <> value 2 <> showDefault
         <> help "Minimum number of distinct writings per set")
  <*> optional (strOption
        (long "pos" <> metavar "SUBSTR"
         <> help "Keep lexemes with a POS token starting with SUBSTR (e.g. adj; \
                 \note that v also matches the suru-noun tag vs — use --verbs)"))
  <*> switch
        (long "verbs" <> help "Keep lexemes with a verb conjugation class (v1, v5…, vk, vz, …)")
  <*> switch
        (long "joyo" <> help "Restrict to writings using only jōyō kanji")
  <*> switch
        (long "common" <> help "Restrict to writings JMdict marks common (ke_pri)")
  <*> optional (option auto
        (long "limit" <> metavar "N" <> help "Keep only the top-N largest sets"))
  <*> optional (strOption
        (long "csv" <> metavar "FILE" <> help "Write sets to FILE as CSV"))
  <*> optional (strOption
        (long "latex" <> metavar "FILE" <> help "Write sets to FILE as a LaTeX longtable"))

bridgeParser :: Parser BridgeOpts
bridgeParser = BridgeOpts
  <$> strOption (long "variants" <> metavar "FILE" <> value "data/Unihan_Variants.txt"
        <> showDefault <> help "Unihan_Variants.txt (kTraditionalVariant / kZVariant)")
  <*> strOption (long "kanjidic" <> metavar "FILE" <> value "data/kanjidic2.xml"
        <> showDefault <> help "KANJIDIC2, whose variant cross-references confirm the Unihan pairs")
  <*> strOption (long "curated" <> metavar "FILE" <> value "mappings/kyujitai.tsv"
        <> showDefault <> help "Curated shinjitai<TAB>kyūjitai supplement")

lensParser :: Parser LensCmd
lensParser = subparser
  ( command "reading"
      (info (LReading <$> strArgument (metavar "READING") <**> helper)
            (progDesc "F1 — a reading → its kanji writings, signs, concepts, similarity"))
 <> command "sign"
      (info (LSign <$> strArgument (metavar "SIGN") <**> helper)
            (progDesc "F2 — a kanji → readings, Sinitic sense, lexemes written with it"))
 <> command "concept"
      (info (LConcept <$> strArgument (metavar "QUERY") <**> helper)
            (progDesc "F3 — gloss substring → matching concepts and their lexemes"))
 <> command "alignment"
      (info (LAlignment <$> optional (strArgument (metavar "ID")) <**> helper)
            (progDesc "F4 — inspect an alignment by id, or list all"))
 <> command "okurigana"
      (info (LOkurigana <$> strArgument (metavar "ORTHOGRAPHY") <**> helper)
            (progDesc "F6 — mark a writing's kanji vs okurigana kana"))
  )

evalParser :: Parser EvalOpts
evalParser = EvalOpts
  <$> option auto (long "seed" <> metavar "N" <> value 42 <> showDefault
        <> help "Seed for reproducible control sampling")
  <*> strOption (long "source" <> metavar "SRC" <> value "unihan" <> showDefault
        <> help "SiniticSense source: unihan (modern) | baxter-sagart (Old Chinese) | wiktionary")
  <*> optional (option auto
        (long "sample" <> metavar "N" <> help "Subsample N actual pairs (default: all)"))
  <*> optional (strOption
        (long "out" <> metavar "FILE" <> help "Write CSV to FILE (default: stdout)"))

worksheetParser :: Parser WorksheetOpts
worksheetParser = WorksheetOpts
  <$> strArgument (metavar "READING" <> help "Reading (kana), e.g. はかる")
  <*> switch (long "common" <> help "Restrict to JMdict-common writings")
  <*> optional (strOption
        (long "out" <> metavar "FILE" <> help "Write to FILE (default: stdout)"))
