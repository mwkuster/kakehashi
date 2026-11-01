module Main where

import Data.List (sort)
import Data.Maybe (fromJust)
import qualified Data.Map.Strict as Map
import qualified Data.Text as T
import qualified Data.Text.Lazy as TL
import Database.Bolt (Value (..))
import Test.Hspec

import Kakehashi.Export.Csv (csvField)
import Kakehashi.Export.Latex (latexEscape)
import Kakehashi.Ingest.BaxterSagart (BSRow (..), bsId, parseRow)
import Kakehashi.Ingest.Jmdict (PLexeme (..), lexemesFromText)
import Kakehashi.Ingest.Kanjidic (isJoyo, splitKun, variantLinksFromText)
import Kakehashi.Ingest.Kyujitai (confirmedPairs, parseCuratedPairs, shinKyuPairsFromVariants)
import Kakehashi.Ingest.Similarity (SimRow (..), parseScores)
import Kakehashi.Ingest.Sinitic (SinRow (..), parseSiniticRow)
import Kakehashi.Ingest.Unihan (parseReadingLine)
import Kakehashi.Kanji (isKanji, kanjiCodepoints)
import Kakehashi.Model
import Kakehashi.OldJapanese (jtkSusceptible, koOtsuMora)
import Kakehashi.Export.Curation (renderCuration)
import Kakehashi.Ingest.Alignment
  (AlignmentRow (..), CurationFile (..), parseCuration, sameAlignment)
import Kakehashi.Export.Worksheet (renderWorksheet)
import Kakehashi.Query.Eval (Actual (..), EvalPair (..), samplePairs)
import Kakehashi.Query.Homophone
  (HomophoneSet (..), RawWriting (..), Writing (..), refineSet)
import Kakehashi.Query.Lens (okuriganaSplit)
import Kakehashi.Query.Worksheet (Worksheet (..), WsRow (..), WsSign (..), collapseRows)

main :: IO ()
main = hspec $ do
  describe "Kakehashi.Model" $ do
    it "constructs a Sign" $ do
      let s = Sign { signCodepoint = 0x6E2C  -- 測
                   , signRadical   = Just 85
                   , signStrokes   = Just 12
                   , signJoyo      = True
                   , signUnihanId  = Just "U+6E2C"
                   }
      signCodepoint s `shouldBe` 0x6E2C

  describe "Kakehashi.Ingest.Kanjidic.splitKun" $ do
    it "splits a reading with okurigana" $
      splitKun "はか.る" `shouldBe` ("はかる", Just "る")
    it "handles a reading without okurigana" $
      splitKun "もと" `shouldBe` ("もと", Nothing)
    it "strips a leading affix marker" $
      splitKun "-もと" `shouldBe` ("もと", Nothing)
    it "strips a trailing affix marker" $
      splitKun "あい-" `shouldBe` ("あい", Nothing)
    it "keeps okurigana after stripping affix markers" $
      splitKun "あ.う" `shouldBe` ("あう", Just "う")

  describe "Kakehashi.Ingest.Kanjidic.isJoyo" $ do
    it "treats kyōiku grades 1–6 as jōyō" $
      map (isJoyo . Just) [1 .. 6] `shouldBe` replicate 6 True
    it "treats grade 8 (general-use) as jōyō" $
      isJoyo (Just 8) `shouldBe` True
    it "treats grade 7 (unused) as non-jōyō" $
      isJoyo (Just 7) `shouldBe` False
    it "treats jinmeiyō grades 9–10 as non-jōyō" $
      map (isJoyo . Just) [9, 10] `shouldBe` [False, False]
    it "treats ungraded kanji as non-jōyō" $
      isJoyo Nothing `shouldBe` False

  describe "Kakehashi.Kanji.kanjiCodepoints" $ do
    it "extracts the kanji codepoint, dropping okurigana kana" $
      kanjiCodepoints "測る" `shouldBe` [0x6E2C]
    it "extracts multiple distinct kanji in order" $
      kanjiCodepoints "取り消す" `shouldBe` [0x53D6, 0x6D88]
    it "returns nothing for an all-kana writing" $
      kanjiCodepoints "ひらがな" `shouldBe` []
    it "deduplicates a repeated kanji" $
      kanjiCodepoints "段段" `shouldBe` [0x6BB5]

  describe "Kakehashi.Kanji.isKanji" $ do
    it "accepts a CJK Unified ideograph" $
      isKanji 0x6E2C `shouldBe` True
    it "rejects hiragana" $
      isKanji 0x308B `shouldBe` False  -- る
    it "rejects the iteration mark 々" $
      isKanji 0x3005 `shouldBe` False

  describe "Kakehashi.Query.Homophone.refineSet" $ do
    let raw o p = RawWriting o (Just p) Nothing Nothing
    it "collapses okurigana variants of the same kanji" $
      -- 上がる / 上る share kanji 上; 挙がる is a second kanji → size 2, not 3
      fmap hsSize (refineSet 2 ("あがる",
        [raw "上がる" "v5", raw "上る" "v5", raw "挙がる" "v5"]))
        `shouldBe` Just 2
    it "drops kana-only writings (the こう/公 case)" $
      -- only 公 carries kanji; こう (kana) is dropped → 1 writing → below min 2
      refineSet 2 ("こう", [raw "公" "n", RawWriting "こう" Nothing Nothing Nothing])
        `shouldBe` Nothing
    it "keeps distinct-kanji sets and records collapsed forms as variants" $ do
      let hs = fromJust $ refineSet 2 ("はかる",
            [raw "測る" "v5r", raw "測ル" "v5r", raw "計る" "v5r"])
      hsSize hs `shouldBe` 2
      map wOrthography (hsWritings hs) `shouldBe` ["測る", "計る"]
      wVariants (head (hsWritings hs)) `shouldBe` ["測ル"]
    it "carries the representative's priority through the collapse" $ do
      let hs = fromJust $ refineSet 2 ("はかる",
            [ RawWriting "測る" (Just "v5r") (Just "ichi1,news1") (Just "to measure")
            , RawWriting "計る" (Just "v5r") (Just "ichi1") (Just "to measure") ])
      wPriority (head (hsWritings hs)) `shouldBe` Just "ichi1,news1"
      wGloss    (head (hsWritings hs)) `shouldBe` Just "to measure"

  -- Real homophone-by-writing sets surfaced by the F5 analysis (common verbs):
  -- one spoken word, several kanji each carrying a distinct concept — the same
  -- phenomenon as はかる. Glosses are the JMdict sense-1 first clauses.
  describe "homophone-by-writing exemplars (data-derived, like はかる)" $ do
    let w o g = RawWriting o (Just "v5r,vt") (Just "ichi1") (Just g)
        glossFor o hs = lookup o [ (wOrthography x, wGloss x) | x <- hsWritings hs ]
        sized n reading raws = do
          let hs = fromJust $ refineSet 2 (reading, raws)
          hsSize hs `shouldBe` n
          sort (map wOrthography (hsWritings hs)) `shouldBe` sort (map rwOrthography raws)
          pure hs

    it "とる — 6 kanji, 6 concepts (take / conduct / catch / adopt / ingest / photograph)" $ do
      hs <- sized 6 "とる"
        [ w "取る" "to take"
        , w "執る" "to take (trouble); to command (an army)"
        , w "捕る" "to catch (an animal)"
        , w "採る" "to adopt (a method); to decide on"
        , w "摂る" "to ingest (e.g. vitamins)"
        , w "撮る" "to take (a photograph)"
        ]
      glossFor "撮る" hs `shouldBe` Just (Just "to take (a photograph)")
      glossFor "摂る" hs `shouldBe` Just (Just "to ingest (e.g. vitamins)")

    it "きく — 5 kanji clustering into 3 concepts (be effective / hear / ask)" $ do
      hs <- sized 5 "きく"
        [ w "利く" "to be effective"
        , w "効く" "to be effective"
        , w "聞く" "to hear"
        , w "聴く" "to listen"
        , w "訊く" "to ask; to enquire"
        ]
      glossFor "訊く" hs `shouldBe` Just (Just "to ask; to enquire")
      glossFor "効く" hs `shouldBe` Just (Just "to be effective")

    it "なおす — the minimal pair 治す (cure) vs 直す (fix)" $ do
      hs <- sized 2 "なおす"
        [ w "治す" "to cure; to heal"
        , w "直す" "to repair; to mend; to fix"
        ]
      glossFor "治す" hs `shouldBe` Just (Just "to cure; to heal")
      glossFor "直す" hs `shouldBe` Just (Just "to repair; to mend; to fix")

    it "かく — 4 kanji, 4 concepts (write / draw / scratch / chip)" $ do
      hs <- sized 4 "かく"
        [ w "書く" "to write; to compose; to pen"
        , w "描く" "to draw; to paint; to sketch"
        , w "掻く" "to scratch"
        , w "欠く" "to chip; to nick; to lack"
        ]
      glossFor "書く" hs `shouldBe` Just (Just "to write; to compose; to pen")
      glossFor "掻く" hs `shouldBe` Just (Just "to scratch")

  describe "Kakehashi.Query.Lens.okuriganaSplit" $ do
    it "splits a stem + okurigana verb" $
      okuriganaSplit "測る" `shouldBe` [("測", True), ("る", False)]
    it "marks infixed kana in a compound verb" $
      okuriganaSplit "取り消す"
        `shouldBe` [("取", True), ("り", False), ("消", True), ("す", False)]
    it "treats an all-kanji compound as one kanji run" $
      okuriganaSplit "会計" `shouldBe` [("会計", True)]
    it "treats an all-kana writing as one kana run" $
      okuriganaSplit "はかる" `shouldBe` [("はかる", False)]

  describe "Kakehashi.Query.Eval.samplePairs" $ do
    let actuals = [ Actual "はかる" "測る" "測" "to measure" "measure, estimate"
                  , Actual "はかる" "図る" "図" "to plan"    "diagram, map" ]
        pool    = [ ("測", "measure, estimate"), ("鉱", "mine, ore"), ("諮", "consult") ]
        sinOf out k i = head [ epSinitic p | p <- out, epPairId p == i, epKind p == k ]
    it "emits one actual and one control per actual, sharing pair_id" $ do
      let out = samplePairs 42 Nothing actuals pool
      length out `shouldBe` 4
      sort (map epKind out) `shouldBe` ["actual", "actual", "control", "control"]
    it "draws a control with a different Sinitic gloss than the actual" $ do
      let out = samplePairs 42 Nothing actuals pool
      (sinOf out "actual" 0 /= sinOf out "control" 0) `shouldBe` True
      (sinOf out "actual" 1 /= sinOf out "control" 1) `shouldBe` True
    it "keeps the native gloss identical across an actual/control pair" $ do
      let out = samplePairs 42 Nothing actuals pool
          nat k i = head [ epNative p | p <- out, epPairId p == i, epKind p == k ]
      nat "actual" 0 `shouldBe` nat "control" 0
    it "respects the sample limit" $
      length (samplePairs 42 (Just 1) actuals pool) `shouldBe` 2
    it "is deterministic for a fixed seed" $
      samplePairs 7 Nothing actuals pool `shouldBe` samplePairs 7 Nothing actuals pool
    it "returns nothing with an empty pool" $
      samplePairs 42 Nothing actuals [] `shouldBe` []

  describe "Kakehashi.Query.Worksheet.collapseRows" $ do
    it "collapses okurigana variants and drops kanji-less writings" $ do
      let sign l = WsSign l Nothing Nothing 0x4E0A Nothing Nothing
          rows = [ WsRow "上がる" (Just "v5") (Just "to rise") Nothing [sign "上"]
                 , WsRow "上る"  (Just "v5") (Just "to rise") Nothing [sign "上"]
                 , WsRow "あがる" Nothing (Just "kana") Nothing [] ]
      map wsWriting (collapseRows rows) `shouldBe` ["上る"]

  let measureWs = Worksheet "はかる"
        [ WsRow "測る" (Just "v5r,vt") (Just "to measure") (Just "1600650:1")
            [ WsSign "測" (Just "measure, estimate") (Just "cè") 0x6E2C
                     (Just "unihan:U+6E2C") (Just "unihan") ] ]
      twoSourceWs = Worksheet "はかる"
        [ WsRow "測る" (Just "v5r,vt") (Just "to measure") (Just "1600650:1")
            [ WsSign "測" (Just "measure, estimate") (Just "cè") 0x6E2C
                     (Just "unihan:U+6E2C") (Just "unihan")
            , WsSign "測" (Just "fathom (v.)") (Just "*[tsʰ]rək · MC tsrhik") 0x6E2C
                     (Just "bs:28204:0906f:*[tsʰ]rək:tsrhik:fathom (v.)") (Just "baxter-sagart") ] ]

  describe "Kakehashi.Export.Worksheet.renderWorksheet" $ do
    it "renders a section per writing with Sinitic candidate and curation fields" $ do
      let md = renderWorksheet measureWs
      T.isInfixOf "## 測る (測)" md                 `shouldBe` True
      T.isInfixOf "測: measure, estimate"  md       `shouldBe` True
      T.isInfixOf "Mandarin (modern) cè" md         `shouldBe` True
      T.isInfixOf "**Alignment basis:**" md         `shouldBe` True

  describe "Kakehashi.Export.Curation.renderCuration" $ do
    it "emits a TOML [[alignment]] table with ids pre-filled and blank fields" $ do
      let toml = renderCuration measureWs
      T.isInfixOf "reading = \"はかる\"" toml                 `shouldBe` True
      T.isInfixOf "[[alignment]]" toml                       `shouldBe` True
      T.isInfixOf "id       = \"はかる/測る/測/unihan:U+6E2C\"" toml `shouldBe` True
      T.isInfixOf "concept  = \"1600650:1\"" toml            `shouldBe` True
      T.isInfixOf "sinitic  = \"unihan:U+6E2C\"" toml        `shouldBe` True
      T.isInfixOf "basis          = \"\"" toml               `shouldBe` True

  describe "Kakehashi.Export.Curation.renderCuration (several sources)" $ do
    it "gives each candidate sense its own alignment id and labels its reading" $ do
      let toml = renderCuration twoSourceWs
          ids  = [ l | l <- T.lines toml, "id       = " `T.isPrefixOf` l ]
      length ids `shouldBe` 2
      (ids !! 0 /= ids !! 1) `shouldBe` True
      T.isInfixOf "# candidate (baxter-sagart): fathom (v.) / Old Chinese *[tsʰ]rək" toml `shouldBe` True

  describe "Kakehashi.Ingest.Alignment.sameAlignment" $ do
    let row = AlignmentRow "はかる/計る/計" "計る" "計" "1600650:1" "unihan:U+8A08"
                "*kˤij-s" "calculate" "meaning" "0.6" ["@Handel2019Sinography"] "" Nothing
        stored b = Map.fromList
          [ ("basis", T b), ("period", T "*kˤij-s"), ("periodSense", T "calculate")
          , ("confidence", F 0.6), ("sources", L [T "@Handel2019Sinography"]), ("notes", T "") ]
    it "accepts a stored record with the same judgement (reloading is idempotent)" $
      sameAlignment (stored "meaning") row `shouldBe` True
    it "rejects a stored record with a different judgement" $
      sameAlignment (stored "disputed") row `shouldBe` False

  describe "Kakehashi.OldJapanese.koOtsuMora" $ do
    it "finds no kō/otsu mora in はかる (a/u stem)" $ do
      koOtsuMora "はかる" `shouldBe` []
      jtkSusceptible "はかる" `shouldBe` False
    it "flags み in みる (i-rui had a 甲/乙 distinction)" $ do
      koOtsuMora "みる" `shouldBe` ["み"]
      jtkSusceptible "みる" `shouldBe` True
    it "lists distinct susceptible mora in order" $
      koOtsuMora "ところ" `shouldBe` ["と", "こ", "ろ"]

  describe "Kakehashi.Ingest.Alignment.parseCuration" $ do
    it "parses the reading and an alignment table with lists and defaults" $ do
      let toml = T.unlines
            [ "reading = \"はかる\""
            , "[[alignment]]"
            , "id = \"はかる/測る/測\""
            , "writing = \"測る\""
            , "sign = \"測\""
            , "concept = \"1600650:1\""
            , "sinitic = \"unihan:U+6E2C\""
            , "basis = \"meaning\""
            , "confidence = \"0.9\""
            , "sources = [\"@Handel2019\", \"@Seeley1991\"]"
            , "disputes = \"other\""
            ]
      case parseCuration toml of
        Left e   -> expectationFailure e
        Right cf -> do
          cfReading cf       `shouldBe` "はかる"
          length (cfRows cf) `shouldBe` 1
          let r = head (cfRows cf)
          arBasis r        `shouldBe` "meaning"
          arSources r      `shouldBe` ["@Handel2019", "@Seeley1991"]
          arDisputes r     `shouldBe` Just "other"
          arPeriodReading r `shouldBe` ""        -- absent key defaults to empty
    it "reports an error for malformed TOML" $
      case parseCuration "reading = " of
        Left _  -> pure ()
        Right _ -> expectationFailure "expected a parse failure"
    it "parses the set-classification fields" $ do
      let toml = T.unlines
            [ "reading = \"はかる\""
            , "oj_etymon = \"single\""
            , "period_homophonous = \"yes\""
            , "class = \"split\""
            , "oj_sources = [\"@NKD\"]"
            ]
      case parseCuration toml of
        Left e   -> expectationFailure e
        Right cf -> do
          cfOjEtymon cf          `shouldBe` "single"
          cfPeriodHomophonous cf `shouldBe` "yes"
          cfClass cf             `shouldBe` "split"
          cfOjSources cf         `shouldBe` ["@NKD"]

  describe "Kakehashi.Ingest.BaxterSagart.parseRow" $ do
    it "parses a B&S TSV row (測)" $
      parseRow "28204\t測\tcè\ttsrhik\t*[tsʰ]rək\tfathom (v.)\t0906f"
        `shouldBe` Just (BSRow 28204 "測" "cè" "tsrhik" "*[tsʰ]rək" "fathom (v.)" "0906f")
    it "tolerates a missing gsr field" $
      fmap bsGsr (parseRow "35336\t計\tjì\tkejH\t*kˤij-s\tcalculate")
        `shouldBe` Just ""
    it "rejects a row with a non-numeric codepoint" $
      parseRow "U+6E2C\t測\tcè\ttsrhik\t*x\tfathom\t0906f" `shouldBe` Nothing

  describe "Kakehashi.Ingest.BaxterSagart.bsId" $ do
    it "gives rows with the same GSR and OC but different glosses different ids" $ do
      let row g = BSRow 20844 "公" "gōng" "kuwng" "*kˤoŋ" g "1173a"
      (bsId (row "father; prince") /= bsId (row "impartial, just; public")) `shouldBe` True
    it "is stable for identical rows" $ do
      let r = BSRow 28204 "測" "cè" "tsrhik" "*[tsʰ]rək" "fathom (v.)" "0906f"
      bsId r `shouldBe` bsId r

  describe "Kakehashi.Ingest.Jmdict.lexemesFromText" $ do
    let doc = TL.unlines
          [ "<JMdict>"
          , "<entry><ent_seq>1</ent_seq>"
          , "<k_ele><keb>測る</keb><ke_pri>news1</ke_pri></k_ele>"
          , "<k_ele><keb>議る</keb><ke_inf>&sK;</ke_inf></k_ele>"
          , "<r_ele><reb>はかる</reb></r_ele>"
          , "<r_ele><reb>はかるう</reb><re_inf>&sk;</re_inf></r_ele>"
          , "<r_ele><reb>はかり</reb><re_restr>議る</re_restr></r_ele>"
          , "<sense><pos>&v5r;</pos><gloss>to measure</gloss></sense>"
          , "</entry>"
          , "<entry><ent_seq>2</ent_seq>"
          , "<k_ele><keb>測る</keb><ke_pri>ichi1</ke_pri></k_ele>"
          , "<r_ele><reb>はかる</reb></r_ele>"
          , "<sense><pos>&vt;</pos><gloss>to fathom</gloss></sense>"
          , "</entry>"
          , "</JMdict>" ]
        ls = either (const []) id (lexemesFromText doc)
    it "skips search-only kanji forms and readings, and readings restricted to them" $
      [ (plPhonology l, plOrthography l) | l <- ls ] `shouldBe` [("はかる", "測る")]
    it "merges a (reading, writing) pair listed in two entries" $ do
      map plPriority ls `shouldBe` [Just "news1,ichi1"]
      map plPos ls      `shouldBe` [Just "v5r,vt"]
      map plConcepts ls `shouldBe` [[("1:1", "to measure"), ("2:1", "to fathom")]]

  describe "Kakehashi.Ingest.Kanjidic.variantLinksFromText" $ do
    it "resolves JIS and UCS variant codes to codepoints and ignores index codes" $ do
      let doc = TL.unlines
            [ "<kanjidic2>"
            , "<character><literal>図</literal><codepoint>"
            , "<cp_value cp_type=\"ucs\">56f3</cp_value><cp_value cp_type=\"jis208\">1-31-62</cp_value>"
            , "</codepoint><misc><variant var_type=\"jis208\">1-52-06</variant>"
            , "<variant var_type=\"deroo\">3675</variant></misc></character>"
            , "<character><literal>圖</literal><codepoint>"
            , "<cp_value cp_type=\"ucs\">5716</cp_value><cp_value cp_type=\"jis208\">1-52-06</cp_value>"
            , "</codepoint><misc><variant var_type=\"ucs\">56f3</variant></misc></character>"
            , "</kanjidic2>" ]
      variantLinksFromText doc `shouldBe` Right [(0x56F3, 0x5716), (0x5716, 0x56F3)]

  describe "Kakehashi.Ingest.Kyujitai.confirmedPairs" $ do
    it "keeps Unihan pairs that KANJIDIC2 confirms, all curated pairs, and no self-pairs" $
      confirmedPairs
        [(0x4F53, 0x9AD4)]                                  -- KANJIDIC2: 体 ~ 體
        [(0x56F3, 0x5716)]                                  -- curated: 図 → 圖
        [(0x4F53, 0x9AD4), (0x673A, 0x6A5F), (0x4E7E, 0x4E7E)]  -- Unihan: 体→體, 机→機, 乾→乾
        `shouldBe` [(0x4F53, 0x9AD4), (0x56F3, 0x5716)]

  describe "Kakehashi.Ingest.Kyujitai" $ do
    it "extracts shin→kyū pairs from Unihan variant lines" $
      shinKyuPairsFromVariants
        "U+7D4C\tkTraditionalVariant\tU+7D93\n\
        \U+56F3\tkMandarin\ttú\n\
        \U+4E9C\tkZVariant\tU+4E9E\n"
        `shouldBe` [(0x7D4C, 0x7D93), (0x4E9C, 0x4E9E)]
    it "parses curated shinjitai→kyūjitai char pairs (図→圖)" $
      parseCuratedPairs "# c\n図\t圖\n弐\t貳\n"
        `shouldBe` [(0x56F3, 0x5716), (0x5F10, 0x8CB3)]

  describe "Kakehashi.Ingest.Similarity.parseScores" $ do
    it "parses score rows and skips the header" $ do
      let csv = T.unlines
            [ "reading,orthography,sign,cosine,model"
            , "はかる,測る,測,0.3081,sentence-transformers/all-MiniLM-L6-v2"
            , "はかる,図る,図,0.066,all-MiniLM" ]
          rows = parseScores csv
      length rows           `shouldBe` 2
      srSign (head rows)    `shouldBe` "測"
      srCosine (head rows)  `shouldBe` 0.3081
      srModel (head rows)   `shouldBe` "sentence-transformers/all-MiniLM-L6-v2"
    it "skips a row with an unparseable cosine" $
      parseScores "reading,orthography,sign,cosine,model\nx,y,z,abc,m" `shouldBe` []

  describe "Kakehashi.Ingest.Sinitic.parseSiniticRow" $ do
    it "parses a generic codepoint/reading/gloss row" $
      parseSiniticRow "22259\ttú\tto consider; to plan (Middle Chinese)"
        `shouldBe` Just (SinRow 22259 "tú" "to consider; to plan (Middle Chinese)")
    it "ignores extra trailing columns" $
      fmap srCp (parseSiniticRow "28204\tcè\tto fathom\textra\tcols") `shouldBe` Just 28204
    it "rejects a non-numeric codepoint" $
      parseSiniticRow "U+56F3\ttú\tplan" `shouldBe` Nothing

  describe "Kakehashi.Ingest.Unihan.parseReadingLine" $ do
    it "parses a kDefinition line" $
      parseReadingLine "U+6E2C\tkDefinition\tmeasure, estimate, conjecture"
        `shouldBe` Just (0x6E2C, "kDefinition", "measure, estimate, conjecture")
    it "parses a kMandarin line" $
      parseReadingLine "U+6E2C\tkMandarin\tcè"
        `shouldBe` Just (0x6E2C, "kMandarin", "cè")
    it "ignores fields other than kDefinition/kMandarin" $
      parseReadingLine "U+6E2C\tkJapaneseOn\tSOKU" `shouldBe` Nothing
    it "ignores comment lines" $
      parseReadingLine "# Unihan_Readings.txt" `shouldBe` Nothing

  describe "Kakehashi.Export.Csv.csvField" $ do
    it "wraps a plain field in quotes" $
      csvField "v5r,vt" `shouldBe` "\"v5r,vt\""
    it "doubles embedded quotes" $
      csvField "a\"b" `shouldBe` "\"a\"\"b\""

  describe "Kakehashi.Export.Latex.latexEscape" $ do
    it "leaves Japanese text untouched" $
      latexEscape "測る" `shouldBe` "測る"
    it "escapes ampersand and underscore" $
      latexEscape "a_b&c" `shouldBe` "a\\_b\\&c"
    it "escapes a backslash" $
      latexEscape "\\" `shouldBe` "\\textbackslash{}"
