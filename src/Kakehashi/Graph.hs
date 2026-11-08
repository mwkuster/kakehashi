-- | Neo4j Bolt client and Cypher helpers (Phase 0).
--
-- Wraps the Neo4j driver ('Kakehashi.Bolt') with a small surface the rest of
-- kakehashi uses: open a connection, apply the @cypher/@ schema, and
-- round-trip a 'Sign' node to prove the pipe works end to end.
module Kakehashi.Graph
  ( -- * Connection
    Pipe
  , BoltConfig (..)
  , defaultBoltConfig
  , boltConfigFromEnv
  , toBoltCfg
  , withConnection
  , withDefaultConnection
    -- * Schema
  , schemaFiles
  , applySchema
    -- * Smoke test
  , roundTripSign
  ) where

import Control.Exception (bracket)
import Control.Monad (forM_)
import Data.Default (def)
import Data.List (sort)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Kakehashi.Bolt
import System.Directory (doesDirectoryExist, listDirectory)
import System.Environment (lookupEnv)
import Text.Read (readMaybe)
import System.FilePath (takeExtension, (</>))

import Kakehashi.Model (Sign (..))

-- | kakehashi's own connection settings; translated to a 'BoltCfg' on connect.
data BoltConfig = BoltConfig
  { boltHost     :: String
  , boltPort     :: Int
  , boltUser     :: Text
  , boltPassword :: Text
  }
  deriving (Eq, Show)

-- | Matches the defaults in @deploy/compose.yaml@.
defaultBoltConfig :: BoltConfig
defaultBoltConfig = BoltConfig
  { boltHost     = "localhost"
  , boltPort     = 7687
  , boltUser     = "neo4j"
  , boltPassword = "changeme-on-first-run"
  }

toBoltCfg :: BoltConfig -> BoltCfg
toBoltCfg c = def
  { host     = boltHost c
  , port     = boltPort c
  , user     = boltUser c
  , password = boltPassword c
  }

-- | 'defaultBoltConfig', overridden by @KAKEHASHI_NEO4J_HOST@, @_PORT@, @_USER@
-- and @_PASSWORD@ where set (the compose file reads the same password
-- variable when it initialises the database).
boltConfigFromEnv :: IO BoltConfig
boltConfigFromEnv = do
  h  <- lookupEnv "KAKEHASHI_NEO4J_HOST"
  pt <- lookupEnv "KAKEHASHI_NEO4J_PORT"
  u  <- lookupEnv "KAKEHASHI_NEO4J_USER"
  pw <- lookupEnv "KAKEHASHI_NEO4J_PASSWORD"
  let d = defaultBoltConfig
  pure BoltConfig
    { boltHost     = maybe (boltHost d) id h
    , boltPort     = maybe (boltPort d) id (readMaybe =<< pt)
    , boltUser     = maybe (boltUser d) T.pack u
    , boltPassword = maybe (boltPassword d) T.pack pw
    }

-- | Open a Bolt connection, run an action, and always close the pipe.
withConnection :: BoltConfig -> (Pipe -> IO a) -> IO a
withConnection c = bracket (connect (toBoltCfg c)) close

-- | 'withConnection' with the settings of 'boltConfigFromEnv'.
withDefaultConnection :: (Pipe -> IO a) -> IO a
withDefaultConnection act = boltConfigFromEnv >>= \c -> withConnection c act

-- | The @*.cypher@ schema files under a directory (default @cypher/@), sorted
-- so numeric prefixes (@001_@, @002_@, …) apply in order.
schemaFiles :: FilePath -> IO [FilePath]
schemaFiles dir = do
  exists <- doesDirectoryExist dir
  if not exists
    then pure []
    else do
      entries <- listDirectory dir
      pure $ sort [dir </> e | e <- entries, takeExtension e == ".cypher"]

-- | Apply each schema file, statement by statement. Constraints/indexes use
-- @IF NOT EXISTS@, so this is idempotent.
applySchema :: Pipe -> [FilePath] -> IO ()
applySchema pipe paths = forM_ paths $ \p -> do
  stmts <- cypherStatements <$> TIO.readFile p
  run pipe $ forM_ stmts query_

-- | Split a @.cypher@ file into runnable statements: drop @//@ comment lines,
-- then split on @;@. (Our schema files only use full-line comments.)
cypherStatements :: Text -> [Text]
cypherStatements =
    filter (not . T.null)
  . map T.strip
  . T.splitOn ";"
  . T.unlines
  . filter (not . ("//" `T.isPrefixOf`))
  . map T.strip
  . T.lines

-- | MERGE a 'Sign' node and read its codepoint back, proving the round-trip.
-- Returns the codepoint as stored by Neo4j.
roundTripSign :: Pipe -> Sign -> IO Int
roundTripSign pipe s = do
  records <- run pipe $ queryP
    "MERGE (n:Sign {codepoint: $cp}) \
    \SET n.radical = $radical, n.strokes = $strokes, \
    \    n.joyo = $joyo, n.unihanId = $unihanId \
    \RETURN n.codepoint AS codepoint"
    (signParams s)
  case records of
    (r : _) -> case Map.lookup "codepoint" r of
      Just (I cp) -> pure cp
      Just v      -> fail ("roundTripSign: unexpected codepoint value " <> show v)
      Nothing     -> fail "roundTripSign: result missing codepoint column"
    [] -> fail "roundTripSign: MERGE returned no record"

signParams :: Sign -> Map Text Value
signParams s = Map.fromList
  [ ("cp",       I (signCodepoint s))
  , ("radical",  maybe (N ()) I (signRadical s))
  , ("strokes",  maybe (N ()) I (signStrokes s))
  , ("joyo",     B (signJoyo s))
  , ("unihanId", maybe (N ()) T (signUnihanId s))
  ]
