-- | Render a curation worksheet (Phase 2, slice 3) as Markdown: one section per
-- distinct-kanji writing, showing the native concept and the candidate Sinitic
-- source sense, with blank fields for the curator to fill (Baxter–Sagart period
-- reading + alignment judgement). The filled worksheet feeds the Alignment
-- records of slice 4.
module Kakehashi.Export.Worksheet
  ( renderWorksheet
  , writeWorksheet
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO

import Kakehashi.OldJapanese (koOtsuMora)
import Kakehashi.Query.Worksheet (Worksheet (..), WsRow (..), WsSign (..), readingLabel, rowSigns)

writeWorksheet :: FilePath -> Worksheet -> IO ()
writeWorksheet path = TIO.writeFile path . renderWorksheet

renderWorksheet :: Worksheet -> Text
renderWorksheet ws = T.unlines (header <> body)
  where
    header =
      [ "# Curation worksheet — " <> wsReading ws
      , ""
      , "Reading **" <> wsReading ws <> "**: one spoken word, several kanji writings."
      , "For each writing, compare the native concept (JMdict sense 1) with the"
      , "candidate Sinitic senses of its characters, each labelled with its source:"
      , "Unihan (modern gloss, Mandarin reading), Baxter–Sagart (Old Chinese gloss"
      , "and reconstruction, with Middle Chinese), Wiktionary (all senses, Middle"
      , "Chinese reading)."
      , ""
      , "> ⚠️ Unihan's Mandarin readings are **modern**. The borrowing-era *sound* is"
      , "> **Middle Chinese** (the on'yomi stratum); for the period-*semantic* check"
      , "> fill the fields below from **Baxter–Sagart Old Chinese** — an earlier,"
      , "> pre-drift proxy, *not* the Middle-Chinese sense itself."
      , ""
      , "## Set classification (period-homophony)"
      , ""
      , "Were these homophones *in Old Japanese, at takeover*, or is the homophony"
      , "later? Classify the set:"
      , ""
      , "- **OJ etymon:** [ ] single  [ ] distinct  [ ] mixed"
      , "- **Period-homophonous (OJ)?:** [ ] yes  [ ] no  [ ] unknown"
      , "- **Class:** [ ] split (one etymon → Sinitic distinctions, はかる)  "
        <> "[ ] disambiguation (distinct etyma kept apart, 欠く vs 書く)  "
        <> "[ ] oj-artifact (distinct in OJ; kō/otsu)  [ ] mixed"
      , "- _" <> jtkHint (wsReading ws) <> "_"
      , "- **OJ notes / sources:** "
      , ""
      ]
    jtkHint r = case koOtsuMora r of
      []   -> "OJ kō/otsu hint: no susceptible mora — homophony likely stable across OJ."
      mora -> "OJ kō/otsu hint: " <> T.intercalate "・" mora
                <> " carried a 甲/乙 distinction in OJ — check the man'yōgana spellings."
    body = concatMap rowSection (wsRows ws)
          <> if null (wsRows ws) then ["_(no kanji writings found for this reading)_"] else []

rowSection :: WsRow -> [Text]
rowSection r =
  [ "## " <> wsWriting r <> " (" <> T.intercalate "、" (rowSigns r) <> ")"
  , ""
  , "- POS: " <> orDash (wsPos r)
  , "- Native concept (JMdict sense 1): " <> orDash (wsNative r)
  ]
  <> map siniticLine (wsSigns r)
  <>
  [ "- **Period reading (Old Chinese, Baxter–Sagart — pre-drift proxy):** "
  , "- **Period sense (Old Chinese):** "
  , "- **Alignment basis:** [ ] perceived similarity of meaning  [ ] sound  [ ] both  [ ] disputed"
  , "- **Confidence (0–1):** "
  , "- **Sources (citekeys):** "
  , "- **Notes:** "
  , ""
  ]

siniticLine :: WsSign -> Text
siniticLine s =
  "- Sinitic candidate (" <> orDash (wsSource s) <> ") — " <> wsSign s <> ": "
    <> orDash (wsSinitic s)
    <> " — " <> readingLabel (wsSource s) <> " " <> orDash (wsSignReading s)

orDash :: Maybe Text -> Text
orDash = maybe "—" (\t -> if T.null t then "—" else t)
