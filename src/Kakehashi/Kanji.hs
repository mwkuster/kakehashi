-- | Kanji (Han ideograph) detection over Unicode codepoints.
module Kakehashi.Kanji
  ( isKanji
  , kanjiCodepoints
  ) where

import Data.Char (ord)
import Data.List (nub)
import Data.Text (Text)
import qualified Data.Text as T

-- | CJK Unified Ideographs (incl. Ext. A), compatibility ideographs, and the
-- Supplementary Ideographic Plane. Excludes kana, the iteration mark, and
-- full-width latin/digits.
isKanji :: Int -> Bool
isKanji c =
     (c >= 0x4E00 && c <= 0x9FFF)
  || (c >= 0x3400 && c <= 0x4DBF)
  || (c >= 0xF900 && c <= 0xFAFF)
  || (c >= 0x20000 && c <= 0x2FFFF)

-- | The distinct kanji codepoints of a string, in first-occurrence order.
-- Doubles as a word's "kanji signature": writings that differ only in
-- okurigana (測る vs 測ル) share one signature, while 山川 and 川山 differ.
kanjiCodepoints :: Text -> [Int]
kanjiCodepoints = nub . filter isKanji . map ord . T.unpack
