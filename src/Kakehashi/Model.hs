-- | Core data types for the SCM-JP property graph: the conceptual model of
-- docs/data-model.md as Haskell types. Only 'Sign' is used in code (the
-- @init-db@ round trip); the ingests write their nodes directly as Cypher
-- parameter maps, and those carry more than these records (e.g. the @source@
-- of a SiniticSense, okurigana on @HAS_READING@ edges, the judgement fields
-- of an Alignment).
module Kakehashi.Model
  ( Sign (..)
  , Reading (..)
  , ReadingType (..)
  , OnClass (..)
  , Lexeme (..)
  , Concept (..)
  , SiniticSense (..)
  , Alignment (..)
  , AlignmentBasis (..)
  ) where

import Data.Text (Text)

-- | A Han character (kanji).
data Sign = Sign
  { signCodepoint :: !Int
  , signRadical   :: !(Maybe Int)
  , signStrokes   :: !(Maybe Int)
  , signJoyo      :: !Bool
  , signUnihanId  :: !(Maybe Text)
  }
  deriving (Eq, Show)

data OnClass = GoOn | KanOn | ToOn | Kanyo
  deriving (Eq, Show)

data ReadingType
  = OnReading !(Maybe OnClass)  -- not populated: KANJIDIC2 does not give go-on/kan-on classes
  | KunReading !(Maybe Text)    -- okurigana (in the graph: on the HAS_READING edge)
  deriving (Eq, Show)

data Reading = Reading
  { readingValue :: !Text
  , readingType  :: !ReadingType
  }
  deriving (Eq, Show)

-- | A Japanese word / morpheme.
data Lexeme = Lexeme
  { lexemePhonology   :: !Text          -- kana reading, e.g. はかる
  , lexemeOrthography :: !Text          -- surface form, e.g. 測る
  , lexemePos         :: !(Maybe Text)
  }
  deriving (Eq, Show)

-- | A (near) language-independent sense.
data Concept = Concept
  { conceptId    :: !Text
  , conceptGloss :: !Text
  }
  deriving (Eq, Show)

-- | The source-language anchor: a Chinese sense and reading of a character,
-- from one source. None of the sources is dated to the borrowing period
-- itself: Unihan is modern, Baxter–Sagart Old Chinese (an earlier, pre-drift
-- proxy; its Middle Chinese readings are the borrowing-era sound),
-- Wiktionary mixes all periods.
data SiniticSense = SiniticSense
  { siniticGloss   :: !Text
  , siniticReading :: !(Maybe Text)
  , siniticPeriod  :: !(Maybe Text)
  }
  deriving (Eq, Show)

data AlignmentBasis = MeaningBasis | SoundBasis | BothBasis | DisputedBasis
  deriving (Eq, Show)

-- | A reified alignment event (Lexeme attached to Sign by some basis).
-- Disagreement is encoded by storing competing Alignment records joined by a
-- :DISPUTES edge at the graph layer ('Kakehashi.Ingest.Alignment').
data Alignment = Alignment
  { alignmentLexemePhonology   :: !Text
  , alignmentLexemeOrthography :: !Text
  , alignmentSign              :: !Int
  , alignmentConcept           :: !Text
  , alignmentBasis             :: !AlignmentBasis
  , alignmentPeriod            :: !(Maybe Text)
  , alignmentSources           :: ![Text]   -- biblatex citekeys
  , alignmentConfidence        :: !(Maybe Double)
  }
  deriving (Eq, Show)
