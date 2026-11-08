-- | The part of a Neo4j driver API that kakehashi uses, implemented on the
-- @bolty@ driver (Bolt 4.4–5.4).
--
-- It keeps the names and the value type kakehashi was written against
-- (formerly @hasbolt@, Bolt v1–v3): 'Value' with the constructors 'N', 'B',
-- 'I', 'F', 'T', 'L' and 'M'; records as maps from column names to values;
-- @'run' pipe ('queryP' cypher params)@. Every query runs in its own
-- auto-commit transaction, and a failed query throws an exception. The rest of
-- the code base therefore only imports this module instead of the driver, and
-- a later change of driver stays inside it.
module Kakehashi.Bolt
  ( -- * Connection
    Pipe
  , BoltCfg (..)
  , connect
  , close
    -- * Values and records
  , Value (..)
  , Record
    -- * Running queries
  , BoltActionT
  , run
  , query
  , queryP
  , query_
  ) where

import Control.Exception (Exception, IOException, throwIO, try)
import Control.Monad (void)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Trans.Reader (ReaderT, ask, runReaderT)
import Data.Default (Default (..))
import qualified Data.HashMap.Strict as H
import Data.List (nub)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (catMaybes)
import Data.PackStream.Integer (fromPSInteger, toPSInteger)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Vector as V
import qualified Database.Bolty as Bolty
import qualified Network.Socket as NS
import Validation (Validation (..))

-- | An open connection to the database.
newtype Pipe = Pipe Bolty.Connection

-- | Connection settings (field names as in hasbolt's configuration).
data BoltCfg = BoltCfg
  { host     :: String
  , port     :: Int
  , user     :: Text
  , password :: Text
  }
  deriving (Eq, Show)

instance Default BoltCfg where
  def = BoltCfg { host = "127.0.0.1", port = 7687, user = "neo4j", password = "neo4j" }

-- | A value sent as a query parameter or received in a record.
data Value
  = N ()
  | B Bool
  | I Int
  | F Double
  | T Text
  | L [Value]
  | M (Map Text Value)
  deriving (Eq, Show)

-- | One result row: column name to value.
type Record = Map Text Value

-- | Actions over an open connection; run them with 'run'.
type BoltActionT m = ReaderT Bolty.Connection m

-- | A result value this module does not translate (nodes, paths, temporal
-- and spatial types); kakehashi's queries return plain properties only.
newtype UnsupportedValue = UnsupportedValue String
  deriving Show

instance Exception UnsupportedValue

-- | A configuration bolty rejects.
newtype InvalidConfig = InvalidConfig [Text]
  deriving Show

instance Exception InvalidConfig

-- | Open a connection: plain TCP (the database is bound to localhost) and a
-- read timeout long enough for the largest ingest batches, since bolty applies
-- its timeout to every read from the socket, not only to connecting.
--
-- bolty connects only to the first address a host name resolves to. Where
-- @localhost@ resolves to @::1@ first and the server listens on 127.0.0.1
-- only (as in @deploy/compose.yaml@), that fails; so each address is tried in
-- turn, as hasbolt did, and the error of the last one is reported.
connect :: BoltCfg -> IO Pipe
connect c = do
  addrs <- NS.getAddrInfo (Just NS.defaultHints { NS.addrSocketType = NS.Stream })
                          (Just (host c)) (Just (show (port c)))
  hosts <- nub . catMaybes <$>
    traverse (fmap fst . NS.getNameInfo [NS.NI_NUMERICHOST] True False . NS.addrAddress) addrs
  firstReachable (if null hosts then [host c] else hosts)
  where
    firstReachable (h : hs@(_ : _)) =
      try (connectTo h) >>= either (\(_ :: IOException) -> firstReachable hs) pure
    firstReachable hs = connectTo (concat (take 1 hs))
    connectTo h = case Bolty.validateConfig (cfg h) of
      Failure errs -> throwIO (InvalidConfig errs)
      Success vc   -> Pipe <$> Bolty.connect vc
    cfg h = (def :: Bolty.Config)
      { Bolty.host    = T.pack h
      , Bolty.port    = fromIntegral (port c)
      , Bolty.scheme  = Bolty.Basic (user c) (password c)
      , Bolty.use_tls = False
      , Bolty.timeout = 3600 * 1000
      }

close :: Pipe -> IO ()
close (Pipe conn) = Bolty.close conn

-- | Run an action on a connection.
run :: Pipe -> BoltActionT IO a -> IO a
run (Pipe conn) act = runReaderT act conn

query :: MonadIO m => Text -> BoltActionT m [Record]
query cypher = queryP cypher Map.empty

-- | Run a parameterised query in its own transaction and return all records.
queryP :: MonadIO m => Text -> Map Text Value -> BoltActionT m [Record]
queryP cypher params = do
  conn <- ask
  rs <- liftIO $ Bolty.runBolt conn $
    Bolty.queryResult cypher (H.fromList [ (k, toPs v) | (k, v) <- Map.toList params ])
  let cols = V.toList (Bolty.fields rs)
  liftIO $ either (throwIO . UnsupportedValue) pure $
    traverse (fmap (Map.fromList . zip cols) . traverse fromBolt . V.toList) (V.toList (Bolty.records rs))

query_ :: MonadIO m => Text -> BoltActionT m ()
query_ = void . query

toPs :: Value -> Bolty.Ps
toPs (N ())  = Bolty.PsNull
toPs (B b)   = Bolty.PsBoolean b
toPs (I i)   = Bolty.PsInteger (toPSInteger i)
toPs (F d)   = Bolty.PsFloat d
toPs (T t)   = Bolty.PsString t
toPs (L xs)  = Bolty.PsList (V.fromList (map toPs xs))
toPs (M m)   = Bolty.PsDictionary (H.fromList [ (k, toPs v) | (k, v) <- Map.toList m ])

fromBolt :: Bolty.Bolt -> Either String Value
fromBolt Bolty.BoltNull            = Right (N ())
fromBolt (Bolty.BoltBoolean b)     = Right (B b)
fromBolt (Bolty.BoltInteger n)     = maybe (Left "integer out of the range of Int") (Right . I) (fromPSInteger n)
fromBolt (Bolty.BoltFloat d)       = Right (F d)
fromBolt (Bolty.BoltString t)      = Right (T t)
fromBolt (Bolty.BoltList xs)       = L <$> traverse fromBolt (V.toList xs)
fromBolt (Bolty.BoltDictionary h)  = M . Map.fromList <$> traverse (traverse fromBolt) (H.toList h)
fromBolt other                     = Left ("unsupported result value: " <> show other)
