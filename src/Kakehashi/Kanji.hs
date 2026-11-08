-- | Kanji (Han ideograph) detection over Unicode codepoints, and the alignment
-- of a writing's kanji with its reading.
module Kakehashi.Kanji
  ( isKanji
  , kanjiCodepoints
  , kataToHira
  , kanjiSpans
  , competes
  ) where

import Data.Char (chr, ord)
import Data.List (isPrefixOf, nub)
import Data.Maybe (listToMaybe, mapMaybe)
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

-- | Katakana ァ–ヶ to hiragana (ー and other marks unchanged).
kataToHira :: String -> String
kataToHira = map (\c -> if c >= 'ァ' && c <= 'ヶ' then chr (ord c - 0x60) else c)

-- | Align a writing with its reading: each run of kanji with the stretch of the
-- reading it stands for, as (run, start, end) in characters of the reading;
-- 'Nothing' if the writing's kana do not match the reading (ateji, 々).
-- A run takes the shortest stretch that lets the rest match, trying the
-- shortest first (the same result as @eval/universe.py@'s @.+?@ regex).
--
-- >>> kanjiSpans "しびれをきらす" "しびれを切らす"
-- Just [("切",4,5)]
kanjiSpans :: Text -> Text -> Maybe [(Text, Int, Int)]
kanjiSpans reading orth = go (segments (T.unpack orth)) (kataToHira (T.unpack reading)) 0
  where
    go [] [] _ = Just []
    go [] _  _ = Nothing
    go (Left lit : rest) s p
      | lit `isPrefixOf` s = go rest (drop (length lit) s) (p + length lit)
      | otherwise          = Nothing
    go (Right run : rest) s p =
      listToMaybe (mapMaybe try [1 .. length s])
      where
        try n = ((T.pack run, p, p + n) :) <$> go rest (drop n s) (p + n)

-- | A writing as alternating runs: Left = kana (as hiragana), Right = kanji.
segments :: String -> [Either String String]
segments = foldr step []
  where
    step c acc
      | isKanji (ord c) = case acc of
          Right r : more -> Right (c : r) : more
          _              -> Right [c] : acc
      | otherwise = case acc of
          Left l : more -> Left (kataToHira [c] ++ l) : more
          _             -> Left (kataToHira [c]) : acc

-- | Do two writings of one reading compete, i.e. put different kanji on
-- overlapping parts of the reading? 痺れをきらす (痺 = しび) and しびれを切らす
-- (切 = き) do not; 入れる / 淹れる (both い) and 表す / 現わす (あらわ / あら)
-- do. A writing that cannot be aligned competes with every other one.
competes :: Maybe [(Text, Int, Int)] -> Maybe [(Text, Int, Int)] -> Bool
competes (Just sa) (Just sb) =
  or [ ka /= kb && s1 < e2 && s2 < e1 | (ka, s1, e1) <- sa, (kb, s2, e2) <- sb ]
competes _ _ = True
