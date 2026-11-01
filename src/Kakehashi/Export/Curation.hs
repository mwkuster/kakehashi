-- | Render a TOML curation skeleton (Phase 2, slice 4 input).
--
-- One @[[alignment]]@ table per (writing × sign × candidate Sinitic sense),
-- pre-filled with the stable ids and candidate data (so the curator never types
-- a codepoint or concept id) and blank judgement fields. The alignment id ends
-- in the SiniticSense id, so a sign with senses from several sources yields
-- distinct alignments rather than one id that would be overwritten. The curator fills these and feeds the file to the
-- alignment loader (@kakehashi align@). The Markdown worksheet
-- ('Kakehashi.Export.Worksheet') remains the human-readable companion.
module Kakehashi.Export.Curation
  ( renderCuration
  , writeCuration
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Numeric (showHex)

import Kakehashi.OldJapanese (koOtsuMora)
import Kakehashi.Query.Worksheet (Worksheet (..), WsRow (..), WsSign (..), readingLabel)

writeCuration :: FilePath -> Worksheet -> IO ()
writeCuration path = TIO.writeFile path . renderCuration

renderCuration :: Worksheet -> Text
renderCuration ws = T.unlines (header <> blocks)
  where
    header =
      [ "# kakehashi curation — " <> wsReading ws
      , "# Fill the blank fields, then:  kakehashi align <this-file>"
      , "# NOTE: each sinitic comment names its source and reading type; Unihan"
      , "#       readings are MODERN Mandarin. The borrowing-era sound is Middle"
      , "#       Chinese (the on'yomi stratum); fill period_reading from Baxter–Sagart"
      , "#       Old Chinese — an earlier, pre-drift proxy, not the Middle-Chinese"
      , "#       value itself. A competing judgement goes into a copy of the block"
      , "#       with a new id and disputes = \"<id>\"; align does not overwrite."
      , ""
      , "reading = " <> tomlStr (wsReading ws)
      , ""
      , "# ---- set classification (period-homophony typology) ----"
      , "# Were these writings homophones *in Old Japanese, at the moment of"
      , "# takeover*?  The 38k uses MODERN readings, so distinguish:"
      , "#   split        — one native etymon → Sinitic distinctions (はかる)"
      , "#   disambiguation— distinct etyma kept apart in writing (欠く vs 書く)"
      , "#   oj-artifact   — distinct in Old Japanese (kō/otsu since merged)"
      , "#   mixed"
      , "# " <> jtkHint (wsReading ws)
      , "oj_etymon          = \"\"   # single | distinct | mixed"
      , "period_homophonous = \"\"   # yes | no | unknown"
      , "class              = \"\"   # split | disambiguation | oj-artifact | mixed"
      , "oj_notes           = \"\""
      , "oj_sources         = []      # e.g. [\"@NihonKokugoDaijiten\"]"
      , ""
      ]
    jtkHint r = case koOtsuMora r of
      []   -> "OJ kō/otsu hint: no susceptible mora — homophony likely stable across OJ."
      mora -> "OJ kō/otsu hint: " <> T.intercalate "・" mora
                <> " carried a 甲/乙 distinction in OJ — check man'yōgana spellings."
    blocks
      | null (wsRows ws) = ["# (no kanji writings found for this reading)"]
      | otherwise        = concatMap rowBlocks (wsRows ws)

    rowBlocks r = concatMap (alignmentBlock r) (wsSigns r)

    alignmentBlock r s =
      [ "[[alignment]]"
      , "id       = " <> tomlStr (T.intercalate "/" ([wsReading ws, wsWriting r, wsSign s]
                                              <> maybe [] pure (wsSiniticId s)))
      , "writing  = " <> tomlStr (wsWriting r)
      , "sign     = " <> tomlStr (wsSign s) <> "  # " <> codepoint (wsSignCp s)
      , "concept  = " <> tomlStr (orEmpty (wsConceptId r)) <> "  # native: " <> orDash (wsNative r)
      , "sinitic  = " <> tomlStr (orEmpty (wsSiniticId s))
          <> "  # candidate (" <> orDash (wsSource s) <> "): " <> orDash (wsSinitic s)
          <> " / " <> readingLabel (wsSource s) <> " " <> orDash (wsSignReading s)
      , "# ---- curate ----"
      , "period_reading = \"\"           # Old Chinese (Baxter–Sagart), pre-drift proxy"
      , "period_sense   = \"\"           # Old Chinese sense (not the modern gloss)"
      , "basis          = \"\"           # meaning | sound | both | disputed"
      , "confidence     = \"\"           # 0.0–1.0"
      , "sources        = []           # e.g. [\"@Handel2019Sinography\"]"
      , "notes          = \"\""
      , "# disputes = \"<other id>\"     # uncomment for a competing alignment"
      , ""
      ]

-- | A TOML basic string: wrap in quotes, escaping backslash and double-quote.
tomlStr :: Text -> Text
tomlStr t = "\"" <> T.replace "\"" "\\\"" (T.replace "\\" "\\\\" t) <> "\""

codepoint :: Int -> Text
codepoint cp = "U+" <> T.justifyRight 4 '0' (T.toUpper (T.pack (showHex cp "")))

orEmpty :: Maybe Text -> Text
orEmpty = maybe "" id

orDash :: Maybe Text -> Text
orDash = maybe "—" (\t -> if T.null t then "—" else t)
