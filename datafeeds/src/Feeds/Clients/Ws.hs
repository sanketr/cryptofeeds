{-# LANGUAGE OverloadedStrings,ScopedTypeVariables #-}
module Feeds.Clients.Ws
(
 client
)
where

import Wuss -- Websocket secure client - small wrapper around websockets library

import Control.Concurrent (MVar,newEmptyMVar,readMVar,putMVar,forkFinally,threadDelay)
import Control.Monad (forever)
import Control.Exception(Exception,throw)
import Data.Text (pack)
import Network.WebSockets (ClientApp, Connection, receiveData, sendClose, sendTextData)
import Data.Aeson.Text as A (encodeToLazyText)
import Data.Text.Lazy.Encoding as LT (encodeUtf8)
import Data.Aeson as A (decode)
import qualified Data.Store as B (Store,encode) -- Fast binary serialization and deserialization
import qualified Data.Text.Lazy as LT (Text)
import qualified Data.Aeson.Types as A (FromJSON)
import qualified Data.ByteString.Lazy as LBS (ByteString,hPut,fromStrict)
import qualified Streaming.Prelude as S (Of, Stream, yield, mapM_,take)
import Control.Monad.IO.Class (liftIO,MonadIO)
import GHC.IO.Handle (Handle)
import System.Exit (exitSuccess)

import Feeds.Gdax.Types (GdaxRsp,RspTyp(..),ReqTyp(..),Request(..),RequestMsg(..),Channels(..))
import Feeds.Clients.Utils (logSwitch)

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

data NoLogFileException = NormalLogException String | ErrorLogException String

instance Show NoLogFileException where
  show (NormalLogException e) = "NormalLogException: There was an issue when accessing normal log file. " ++ e
  show (ErrorLogException e) = "ErrorLogException: There was an issue when accessing normal log file. " ++ e

instance Exception NoLogFileException

logDataToFile :: Connection -> MVar (Maybe Handle,Maybe Handle) -> IO()
logDataToFile conn mvarhdls = S.mapM_ (either logToError logToNormal) $ S.take 10 (streamMsgsFromConn conn)
            where
              -- We get current log handle for respective log, and write to it - if for any reasons, no log handle
              -- is found, an exception is thrown which will kill the main thread. We can add logic to restart the
              -- the whole data capture process
              logToNormal :: LBS.ByteString -> IO()
              logToNormal msg = do
                (hlog,_) <- readMVar mvarhdls
                maybe (throw $ ErrorLogException "Normal log file couldnt be opened") (`LBS.hPut` msg) hlog
              
              logToError :: LT.Text -> IO()
              logToError msg = do
                (_,hlogerr) <- readMVar mvarhdls
                maybe (throw $ ErrorLogException "Error log file couldnt be opened") (\x -> LBS.hPut x $ LT.encodeUtf8 msg) hlogerr 
              

ws :: ClientApp ()
ws connection = do
  putStrLn "Connected!"
  dieSignal <- newEmptyMVar :: IO (MVar String)

  mvarLogHdls <- logSwitch 60000000 "test/gdax" dieSignal
  threadDelay 1000000 -- Delay for one second to allow for logs to be created in above background thread
  forkFinally (logDataToFile connection mvarLogHdls) (either (putMVar dieSignal . show) (\_ -> putMVar dieSignal "Done with processing messages - test mode"))

  -- Let us build a JSON request for heartbeat to ETH-EUR instrument
  let req1 = A.encodeToLazyText Request {_req_type = Subscribe, _req_channels = RequestMsg $ map (\(reqtyp,prdids) -> Channels {_channel_name = reqtyp, _channel_product_ids = prdids}) [(HeartbeatTyp,["ETH-EUR"]),(Level2Typ,["ETH-EUR"]),(TickerTyp,["ETH-EUR"])]}
  -- Send heartbeat subscription message
  sendTextData connection req1

  -- Don't do any resource cleanup before mvar otherwise we will free resources while they are in use!
  -- let us wait for procMsg to exit
  dieMsg <- readMVar dieSignal
  -- Will replace with some kind of clean shutdown mechanism later
  sendClose connection (pack "Bye!")
  print dieMsg
  exitSuccess
