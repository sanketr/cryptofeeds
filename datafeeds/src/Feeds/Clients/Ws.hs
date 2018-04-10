{-# LANGUAGE OverloadedStrings,ScopedTypeVariables #-}
module Feeds.Clients.Ws
(
 client
)
where

import Wuss -- Websocket secure client - small wrapper around websockets library

import Control.Concurrent (MVar,newEmptyMVar,takeMVar,putMVar,forkFinally,threadDelay,killThread)
import Data.IORef
import Data.Text (pack)
import Network.WebSockets (ClientApp, Connection, receiveData, sendClose, sendTextData)
import Data.Aeson.Text as A (encodeToLazyText)
import Data.Aeson as A (decode)
import qualified Data.Store as B (Store) -- Fast binary serialization and deserialization
import qualified Data.Store.Streaming as B (Message(..),encodeMessage)
import qualified Data.Aeson.Types as A (FromJSON)
import qualified Data.ByteString as BS (ByteString)
import qualified Data.ByteString.Lazy as LBS (ByteString,toStrict)
import qualified Streaming.Prelude as S (Of(..), Stream, yield, mapM_,separate)
import Control.Monad.IO.Class (liftIO,MonadIO)
import System.Exit (exitSuccess)
import GHC.IO.Handle.Types (Handle)

import Feeds.Gdax.Types (GdaxRsp,RspTyp(..),ReqTyp(..),Request(..),RequestMsg(..),Channels(..))
import Feeds.Clients.Utils (logWriters,LogType(..),HdlInfo,putLogStr)
import Feeds.Clients.Internal (toSum)

-- This is a websocket client to connect to GDAX websocket feed
client :: IORef (Maybe HdlInfo,Maybe HdlInfo) -> IO ()
client hdlinfo = runSecureClient "ws-feed.gdax.com" 443 "/" (ws hdlinfo)

-- Decode websocket json text - retain text if decoding failure else return decoded data
msgDecode :: (A.FromJSON a, B.Store a) => LBS.ByteString -> Either LBS.ByteString a
msgDecode inp = case A.decode inp of
          Just val -> Right val
          Nothing -> Left inp

-- Given a web socket connection, turn it into message stream - we will connect it to other streams like file append stream etc. to save down the data
streamMsgsFromConn :: forall m. (MonadIO m, Monad m) => Connection -> S.Stream (S.Of (Either BS.ByteString BS.ByteString)) m ()
streamMsgsFromConn conn = loop where
              loop = do
                -- Block waiting for the message
                msg <- liftIO $ receiveData conn
                case (msgDecode msg :: Either LBS.ByteString GdaxRsp) of
                  Left blob -> (S.yield :: a -> S.Stream (S.Of a) m ()) . Left . LBS.toStrict $ blob
                  Right res -> (S.yield :: a -> S.Stream (S.Of a) m ()) . Right . B.encodeMessage . B.Message $ res  -- explicit type signature for S.yield because the compiler can't deduce it is the same monad m from type signature - use forall to enforce scoped types
                loop

logDataToFile :: Connection -> (LogType ->  BS.ByteString -> IO()) -> IO()
--logDataToFile conn logMsg = S.mapM_ (either (logMsg Error) (logMsg Normal)) $ S.take 100 $ (streamMsgsFromConn conn)
logDataToFile conn logMsg = S.mapM_ (logMsg Normal) . S.mapM_ (liftIO . logMsg Error) . S.separate . toSum . streamMsgsFromConn $ conn
              
ws :: IORef (Maybe HdlInfo,Maybe HdlInfo) -> ClientApp ()
ws hdlinfo connection = do
  dieSignal <- newEmptyMVar :: IO (MVar String)

  -- Kick off log rotator thread - it will present us with the log handles to save data to
  (ltid,loggers) <- logWriters 60000000 ("logs/gdax","1") hdlinfo dieSignal
  threadDelay 1000000 -- Delay for one second to allow for logs to be created in above background thread

  -- Kick off web socket data capture - this will be saved to logs using the log handles from log rotator above
  tid <- forkFinally (logDataToFile connection loggers) (either (putMVar dieSignal . show) (\_ -> putMVar dieSignal "Done with processing messages - test mode"))

  -- Let us build and send a JSON request for heartbeat to ETH-EUR instrument
  let req = A.encodeToLazyText Request {_req_type = Subscribe, _req_channels = RequestMsg $ map (\(reqtyp,prdids) -> Channels {_channel_name = reqtyp, _channel_product_ids = prdids}) [(HeartbeatTyp,["LTC-USD","ETH-USD", "BTC-USD","ETH-BTC", "ETH-EUR"]),(Level2Typ,["LTC-USD","ETH-USD", "BTC-USD","ETH-BTC", "ETH-EUR"]),(TickerTyp,["LTC-USD","ETH-USD", "BTC-USD","ETH-BTC", "ETH-EUR"])]}
  -- Send heartbeat subscription message - this will cause logDataToFile function kicked off above to start 
  -- receiving the data
  sendTextData connection req

  -- Don't do any resource cleanup before mvar otherwise we will free resources while they are in use!
  -- let us wait for procMsg to exit
  dieMsg <- takeMVar dieSignal
  putLogStr "Killing logger thread before exit"
  killThread ltid
  putLogStr "Killing logger parent thread before exit"
  killThread tid
  -- Will replace with some kind of clean shutdown mechanism later
  sendClose connection (pack "Bye!")
  putLogStr dieMsg -- To do - log to error log
  exitSuccess
