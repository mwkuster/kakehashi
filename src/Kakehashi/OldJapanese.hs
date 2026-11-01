-- | Old-Japanese triage helpers for the period-homophony question.
--
-- A modern homophone set may not have been homophonous at the moment of kanji
-- takeover: 8th-c. Japanese kept the 上代特殊仮名遣い (Jōdai Tokushu Kanazukai)
-- kō/otsu (甲/乙) vowel distinctions in certain syllables, since merged
-- (神 /kamï/ ≠ 上 /kami/). 'koOtsuMora' flags which mora in a reading carried
-- such a distinction, so the curator knows when an Old-Japanese check is needed.
-- It is an *advisory hint*, not a determination — the actual answer needs the
-- word's man'yōgana spellings / etymology.
module Kakehashi.OldJapanese
  ( koOtsuMora
  , jtkSusceptible
  ) where

import Data.List (nub)
import Data.Text (Text)
import qualified Data.Text as T

-- | Hiragana mora that distinguished kō- and otsu-rui in Old Japanese
-- (i-rui キ ヒ ミ ギ ビ; e-rui ケ ヘ メ ゲ ベ; o-rui コ ソ ト ノ ヨ ロ モ ゴ ゾ ド).
jtkSet :: [Char]
jtkSet = "きひみぎびけへめげべこそとのよろもごぞど"

-- | The distinct kō/otsu-susceptible mora occurring in a reading, in order.
koOtsuMora :: Text -> [Text]
koOtsuMora t = nub [ T.singleton c | c <- T.unpack t, c `elem` jtkSet ]

-- | Does the reading contain any 上代特殊仮名遣い-susceptible mora?
jtkSusceptible :: Text -> Bool
jtkSusceptible = not . null . koOtsuMora
