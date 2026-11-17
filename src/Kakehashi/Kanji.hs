-- | Kanji (Han ideograph) detection over Unicode codepoints, what counts as a
-- kanji writing, and the alignment of a writing's kanji with its reading.
module Kakehashi.Kanji
  ( isKanji
  , isKana
  , isKanjiWriting
  , kanjiCodepoints
  , kataToHira
  , normKana
  , kanjiSpans
  , competes
  ) where

import Data.Char (chr, ord)
import Data.List (nub)
import Data.Maybe (listToMaybe, mapMaybe)
import qualified Data.Set as Set
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

-- | Kana: hiragana (with the small forms and ゕゖ), katakana (with the counter
-- marks ヵヶ) and the long-vowel mark ー.
isKana :: Char -> Bool
isKana c = (c >= '\x3041' && c <= '\x3096') || (c >= '\x30A1' && c <= '\x30FA') || c == 'ー'

-- | A kanji writing of a word: at least one kanji, and nothing but kanji, kana
-- and the iteration mark 々. Forms with Arabic numerals (１月), Latin letters
-- (Ｘ線) or symbols are not kanji writings, any more than kana-only forms.
isKanjiWriting :: Text -> Bool
isKanjiWriting t =
  T.any (isKanji . ord) t && T.all (\c -> isKanji (ord c) || isKana c || c == '々') t

-- | The distinct kanji codepoints of a string, in first-occurrence order.
-- Doubles as a word's "kanji signature": writings that differ only in
-- okurigana (測る vs 測ル) share one signature, while 山川 and 川山 differ.
kanjiCodepoints :: Text -> [Int]
kanjiCodepoints = nub . filter isKanji . map ord . T.unpack

-- | Katakana ァ–ヶ to hiragana (ー and other marks unchanged).
kataToHira :: String -> String
kataToHira = map (\c -> if c >= 'ァ' && c <= 'ヶ' then chr (ord c - 0x60) else c)

-- | Normalise one kana for alignment: katakana → hiragana, the counter marks
-- ヵヶ → か, historical を ゐ ゑ → お い え, ぢ づ → the same as じ ず, ゔ → う,
-- and dakuten / handakuten removed (が → か, ぱ → は). The same table as
-- @eval/universe.py@'s @norm_kana@.
normKana :: Char -> Char
normKana c0 = maybe c (id) (lookup c normTable)
  where c = case kataToHira [c0] of (x : _) -> x; [] -> c0

normTable :: [(Char, Char)]
normTable = zip "ゕゖをゐゑゔがぎぐげござじずぜぞだぢづでどばびぶべぼぱぴぷぺぽ"
                "かかおいえうかきくけこさしすせそたしすてとはひふへほはひふへほ"

-- | Does a kana of the writing stand for a kana of the (normalised) reading?
-- ー stands for any vowel (ヒコーキ ひこうき), the counter ケ for か (一ケ月), and
-- a medial h-row kana for its modern w-row value (侍ふ さぶらう).
kanaMatches :: Bool -> Char -> Char -> Bool
kanaMatches medial w r
  | n == 'ー'            = r `elem` ("あいうえおぁぃぅぇぉー" :: String)
  | n == r               = True
  | w == 'ケ' && r == 'か' = True
  | medial               = lookup n hRow == Just r
  | otherwise            = False
  where
    n    = normKana w
    hRow = zip "はひふへほ" "わいうえお"

-- | Align a writing with its reading: each run of kanji with the stretch of the
-- reading it stands for, as (run, start, end) in characters of the reading;
-- 'Nothing' if the writing's kana do not match the reading. A run takes the
-- shortest stretch that lets the rest match, trying the shortest first (the
-- same result as @eval/universe.py@'s @.+?@ regex). 々 continues the kanji run
-- before it (人々 is one run).
--
-- >>> kanjiSpans "しびれをきらす" "しびれを切らす"
-- Just [("切",4,5)]
kanjiSpans :: Text -> Text -> Maybe [(Text, Int, Int)]
kanjiSpans reading orth = go (segments (T.unpack orth)) (map normKana (T.unpack reading)) 0 0
  where
    -- go segments readingRest readingPos writingPos
    go [] [] _ _ = Just []
    go [] _  _ _ = Nothing
    go (Left lit : rest) s p q
      | Just s' <- matchLit lit s q = go rest s' (p + length lit) (q + length lit)
      | otherwise                   = Nothing
    go (Right run : rest) s p q =
      listToMaybe (mapMaybe try [1 .. length s])
      where
        try n = ((T.pack run, p, p + n) :) <$> go rest (drop n s) (p + n) (q + length run)

    matchLit [] s _ = Just s
    matchLit (w : ws) (r : rs) q
      | kanaMatches (q > 0) w r = matchLit ws rs (q + 1)
    matchLit _ _ _ = Nothing

-- | A writing as alternating runs: Left = kana, Right = kanji (with any 々).
segments :: String -> [Either String String]
segments [] = []
segments (c : cs)
  | isKanji (ord c) = let (run, rest) = span (\x -> isKanji (ord x) || x == '々') cs
                      in Right (c : run) : segments rest
  | otherwise       = let (lit, rest) = span (not . isKanji . ord) cs
                      in Left (c : lit) : segments rest

-- | Do two writings of one reading compete, i.e. put different kanji on
-- overlapping parts of the reading? 痺れをきらす (痺 = しび) and しびれを切らす
-- (切 = き) do not; 入れる / 淹れる (both い) and 表す / 現わす (あらわ / あら)
-- do. Inside a run of several kanji the share of each kanji is unknown, so a
-- kanji that both runs contain is taken to stand for the same part: 挨拶代わり
-- and あいさつ代わり (代 in both) do not compete, 会社 and 会者 (社 / 者) do. A
-- writing that cannot be aligned competes with every other one.
competes :: Maybe [(Text, Int, Int)] -> Maybe [(Text, Int, Int)] -> Bool
competes (Just sa) (Just sb) =
  or [ s1 < e2 && s2 < e1 && not (ka `Set.isSubsetOf` kb || kb `Set.isSubsetOf` ka)
     | (ra, s1, e1) <- sa, (rb, s2, e2) <- sb
     , let ka = kanjiSet ra, let kb = kanjiSet rb ]
  where kanjiSet = Set.fromList . filter isKanji . map ord . T.unpack
competes _ _ = True
