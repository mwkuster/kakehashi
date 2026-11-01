-- | LaTeX @longtable@ export of homophone-by-writing sets, for the article.
-- Assumes @booktabs@ + @longtable@ and a CJK-capable engine (XeLaTeX/LuaLaTeX).
module Kakehashi.Export.Latex
  ( writeHomophoneLongtable
  , latexEscape
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO

import Kakehashi.Query.Homophone (HomophoneSet (..), Writing (..))

-- | Write sets as a @longtable@: the reading spans its block (shown on the
-- first row), one row per distinct-kanji writing (reading, writing, signs,
-- gloss), sets separated by @\midrule@.
writeHomophoneLongtable :: FilePath -> [HomophoneSet] -> IO ()
writeHomophoneLongtable path sets =
  TIO.writeFile path (T.unlines (preamble <> blocks <> closing))
  where
    blocks = intercalateMidrule (map setBlock sets)

preamble :: [Text]
preamble =
  [ "% Requires: \\usepackage{longtable,booktabs}  (XeLaTeX/LuaLaTeX for CJK)"
  , "\\begin{longtable}{llll}"
  , "\\toprule"
  , "Reading & Writing & Sign(s) & Gloss \\\\"
  , "\\midrule"
  , "\\endhead"
  ]

closing :: [Text]
closing = ["\\bottomrule", "\\end{longtable}"]

-- | The rows for one set; the reading appears only on the first row.
setBlock :: HomophoneSet -> [Text]
setBlock hs =
  [ cells [ if i == 0 then latexEscape (hsPhonology hs) else ""
          , latexEscape (wOrthography w)
          , latexEscape (T.intercalate "、" (wSigns w))
          , latexEscape (maybe "" id (wGloss w))
          ]
  | (i, w) <- zip [0 :: Int ..] (hsWritings hs)
  ]

cells :: [Text] -> Text
cells xs = T.intercalate " & " xs <> " \\\\"

intercalateMidrule :: [[Text]] -> [Text]
intercalateMidrule = concat . prependSep
  where
    prependSep []       = []
    prependSep (b : bs) = b : map ("\\midrule" :) bs

-- | Escape the LaTeX specials that may appear (POS codes, stray punctuation).
latexEscape :: Text -> Text
latexEscape = T.concatMap escChar
  where
    escChar c
      | c `elem` ("&%$#_{}" :: String) = T.pack ['\\', c]
      | c == '\\'                      = "\\textbackslash{}"
      | c == '~'                       = "\\textasciitilde{}"
      | c == '^'                       = "\\textasciicircum{}"
      | otherwise                      = T.singleton c
