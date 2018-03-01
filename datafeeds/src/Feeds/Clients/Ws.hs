{-# LANGUAGE OverloadedStrings,DeriveGeneric,ScopedTypeVariables #-}
module Feeds.Clients.Ws
(
 client
)
where

import Wuss -- Websocket secure client - small wrapper around websockets library

import Control.Concurrent (MVar,newEmptyMVar,readMVar,putMVar,forkIO,threadDelay)
import Control.Monad (forever, unless, void)
import Data.Text (Text, pack)
import Network.WebSockets (ClientApp, Connection, receiveData, sendClose, sendTextData)
import Feeds.Gdax.Types (Heartbeat(..),GdaxRsp,RspTyp(..),ReqTyp(..),Request(..),RequestMsg(..),Channels(..))
import Data.Aeson.Text as A (encodeToLazyText)
import Data.Text.Lazy.Encoding as LT (encodeUtf8)
import Data.Aeson as A (decode)
import qualified Data.Binary.Get as B
import qualified Data.Store as B (Store,encode)
import qualified Data.Text.Lazy as LT (Text)
import Data.Maybe (maybe, fromJust)
import qualified Data.Aeson.Types as A (FromJSON)
import qualified Data.ByteString.Lazy as LBS (ByteString,hPut,fromStrict)
import qualified Streaming.Prelude as S (Of, Stream, yield, mapM_,take)
import Control.Monad.IO.Class (liftIO,MonadIO)
import GHC.IO.Handle (Handle)
import System.IO (openBinaryFile, IOMode(..), hFlush, hSetBuffering, BufferMode(..), hClose)
import System.Exit (exitSuccess)

-- | Imports for deriving Generic and Typeable
import GHC.Generics
import Data.Typeable

-- This is a websocket client to connect to GDAX websocket feed
client :: IO ()
client = runSecureClient "ws-feed.gdax.com" 443 "/" ws

-- Decode websocket json text - retain text if decoding failure else return decoded data
msgDecode :: (A.FromJSON a, B.Store a) => LT.Text -> Either LT.Text a
msgDecode inp = case A.decode . LT.encodeUtf8 $ inp of
          Just val -> Right val
          Nothing -> Left inp 

-- Given a web socket connection, turn it into message stream - we will connect it to other streams like file append stream etc. to save down the data
streamMsgsFromConn :: forall m. (MonadIO m, Monad m) => Connection -> S.Stream (S.Of (Either LT.Text LBS.ByteString)) m ()
streamMsgsFromConn conn = forever $ do
                -- Block waiting for the message
                msg <- liftIO $ receiveData conn
                case (msgDecode msg :: Either LT.Text GdaxRsp) of
                  Left blob -> (S.yield :: a -> S.Stream (S.Of a) m () ) . Left $ blob
                  Right res -> (S.yield :: a -> S.Stream (S.Of a) m () ) . Right . LBS.fromStrict . B.encode $ res  -- explicit type signature for S.yield because the compiler can't deduce it is the same monad m from type signature - use forall to enforce scoped types

data LogType = Normal | Error deriving (Show,Generic,Typeable)

getFileHandle :: LogType -> IO Handle
getFileHandle logtyp = case logtyp of
                Normal -> openBinaryFile "normal.log" AppendMode
                Error -> openBinaryFile "unknown.log" AppendMode
                  

logDataToFile :: Connection -> Handle -> Handle -> IO()
logDataToFile conn hlog hlogerr = do
                  -- msg is of type: Stream (Of (Either Text BS) m ().
                  -- Append to log if no error. Else log to logerr handle
                  S.mapM_ (either (\x -> LBS.hPut hlogerr (LT.encodeUtf8 x)) (\x -> LBS.hPut hlog x)) $ S.take 10 (streamMsgsFromConn conn)

ws :: ClientApp ()
ws connection = do
  putStrLn "Connected!"
  dieSignal <- newEmptyMVar :: IO (MVar String)
  hlog <- getFileHandle Normal -- file handle for normal logging
  hlogerr <- getFileHandle Error -- file handle for error logging
  mapM_ (`hSetBuffering` NoBuffering) [hlog,hlogerr] -- flush to disk immediately

  forkIO $ do
    logDataToFile connection hlog hlogerr
    putMVar dieSignal "Done with processing first 10 messages - test mode"

  -- Let us build a JSON request for heartbeat to ETH-EUR instrument
  let req1 = A.encodeToLazyText Request {_req_type = Subscribe, _req_channels = RequestMsg $ map (\(reqtyp,prdids) -> Channels {_channel_name = reqtyp, _channel_product_ids = prdids}) [(HeartbeatTyp,["ETH-EUR"]),(Level2Typ,["ETH-EUR"])]}
  -- Send heartbeat subscription message
  sendTextData connection req1

  -- Don't do any resource cleanup before mvar otherwise we will free resources while they are in use!
  -- let us wait for procMsg to exit
  dieMsg <- readMVar dieSignal
  -- Will replace with some kind of clean shutdown mechanism later
  sendClose connection (pack "Bye!")
  mapM_ hClose [hlog,hlogerr] -- Close all file handles when done -- To do - resourceT version instead
  print dieMsg
  exitSuccess
