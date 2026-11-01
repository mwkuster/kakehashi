-- | CSV export of homophone-by-writing sets (one row per writing, long form).
module Kakehashi.Export.Csv
  ( writeHomophoneSets
  , csvField
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO

import Kakehashi.Query.Homophone (HomophoneSet (..), Writing (..))

-- | Write sets as CSV, one row per distinct-kanji writing, with columns
-- reading, set_size, orthography, signs, gloss, pos, priority, variants.
-- All fields are quoted, so commas in POS (@v5r,vt@) are safe.
writeHomophoneSets :: FilePath -> [HomophoneSet] -> IO ()
writeHomophoneSets path sets =
  TIO.writeFile path (T.unlines (header : concatMap setRows sets))
  where
    header = row [ "reading", "set_size", "orthography", "signs"
                 , "gloss", "pos", "priority", "variants" ]

setRows :: HomophoneSet -> [Text]
setRows hs =
  [ row [ hsPhonology hs
        , T.pack (show (hsSize hs))
        , wOrthography w
        , T.intercalate " " (wSigns w)
        , maybe "" id (wGloss w)
        , maybe "" id (wPos w)
        , maybe "" id (wPriority w)
        , T.intercalate " " (wVariants w)
        ]
  | w <- hsWritings hs
  ]

row :: [Text] -> Text
row = T.intercalate "," . map csvField

-- | Quote a CSV field, doubling embedded quotes (RFC 4180).
csvField :: Text -> Text
csvField t = "\"" <> T.replace "\"" "\"\"" t <> "\""
