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
import qualified Feeds.Gdax.Types.Feed as F (Request(..),ReqTyp(..),ChannelSubscription(..),Channel(..),GdaxMessage)
import qualified Data.Vector as V (fromList)
import Feeds.Common.Types (LogType(..),HdlInfo)
import Feeds.Clients.Utils (logWriters,putLogStr)
import Feeds.Clients.Internal (toSum)

-- This is a websocket client to connect to GDAX websocket feed
client :: IORef (Maybe HdlInfo,Maybe HdlInfo) -> MVar F.GdaxMessage -> IO ()
client hdlinfo msgChan = let
                    req = F.Request F.Subscribe  (V.fromList $ map (\(reqtyp,prdids) -> F.ChannelSubscription reqtyp (V.fromList prdids)) [(F.ChannelHeartbeat,["LTC-USD","ETH-USD", "BTC-USD","ETH-BTC", "ETH-EUR"]),(F.ChannelLevel2,["LTC-USD","ETH-USD", "BTC-USD","ETH-BTC", "ETH-EUR"]),(F.ChannelTicker,["LTC-USD","ETH-USD", "BTC-USD","ETH-BTC", "ETH-EUR"])]) Nothing
                 in runSecureClient "ws-feed.gdax.com" 443 "/" (ws hdlinfo ("logs/gdax","1") msgChan req)

-- Decode websocket json text - retain text if decoding failure else return decoded data
msgDecode :: (A.FromJSON a, B.Store a) => LBS.ByteString -> Either LBS.ByteString a
msgDecode inp = case A.decode inp of
          Just val -> Right val
          Nothing -> Left inp

-- Given a web socket connection, turn it into message stream - we will connect it to other streams like file append stream etc. to save down the data
streamMsgsFromConn :: forall m. (MonadIO m, Monad m) => Connection -> S.Stream (S.Of (Either BS.ByteString F.GdaxMessage)) m ()
streamMsgsFromConn conn = loop where
              loop = do
                -- Block waiting for the message
                msg <- liftIO $ receiveData conn
                case (msgDecode msg :: Either LBS.ByteString F.GdaxMessage) of
                  Left blob -> (S.yield :: a -> S.Stream (S.Of a) m ()) . Left . LBS.toStrict $ blob
                  Right res -> (S.yield :: a -> S.Stream (S.Of a) m ()) . Right $ res  -- explicit type signature for S.yield because the compiler can't deduce it is the same monad m from type signature - use forall to enforce scoped types
                loop

logNPubData :: Connection -> (LogType ->  BS.ByteString -> IO()) -> MVar F.GdaxMessage -> IO()
logNPubData conn logMsg msgChan = S.mapM_ (\x -> logMsg Normal (B.encodeMessage . B.Message $ x) >> putMVar msgChan x) . S.mapM_ (liftIO . logMsg Error) . S.separate . toSum . streamMsgsFromConn $ conn
              
ws :: IORef (Maybe HdlInfo,Maybe HdlInfo) -> (FilePath,FilePath) -> MVar F.GdaxMessage -> F.Request -> ClientApp ()
ws hdlinfo logfpath msgChan req connection = do
  dieSignal <- newEmptyMVar :: IO (MVar String)

  -- Kick off log rotator thread - it will present us with the log handles to save data to
  (ltid,loggers) <- logWriters 60000000 logfpath hdlinfo dieSignal
  threadDelay 1000000 -- Delay for one second to allow for logs to be created in above background thread

  -- Kick off web socket data capture - this will be saved to logs using the log handles from log rotator above
  tid <- forkFinally (logNPubData connection loggers msgChan) (either (putMVar dieSignal . show) (\_ -> putMVar dieSignal "Done with processing messages - test mode"))

  -- Let us build and send a JSON request for heartbeat to ETH-EUR instrument
  let wsReq = A.encodeToLazyText req
  -- Send heartbeat subscription message - this will cause logNPubData function kicked off above to start 
  -- receiving the data
  _ <- forkFinally (sendTextData connection wsReq) (either (putMVar dieSignal . show) (\_ -> return ()))

  -- Don't do any resource cleanup before mvar otherwise we will free resources while they are in use!
  -- let us wait for procMsg to exit
  dieMsg <- takeMVar dieSignal
  putLogStr "Killing logger thread and its parent before exit"
  mapM_ killThread [ltid,tid]
  sendClose connection (pack "Bye!")
  putLogStr dieMsg -- To do - log to error log
  exitSuccess


{-- Authentication over web socket

 toJSON (Subscribe auth pids) =
    object
      [ "type" .= ("subscribe" :: Text)
      , "product_ids" .= pids
      , "signature" .= authSignature auth
      , "key" .= authKey auth
      , "passphrase" .= authPassphrase auth
      , "timestamp" .= authTimestamp auth
      ]

  data Auth = Auth
  { authSignature  :: Text
  , authKey        :: Text
  , authPassphrase :: Text
  , authTimestamp  :: Text
  } deriving (Eq, Show, Read, Data, Typeable, Generic, NFData)

mkAuth :: ExchangeConf -> IO Auth
mkAuth conf = do
    let meth = "GET"
        p = "/users/self"
    case authToken conf of
        Just tok -> do
            time <-
                liftM (realToFrac . utcTimeToPOSIXSeconds) (liftIO getCurrentTime) >>= \t ->
                    return . CBS.pack $ printf "%.0f" (t :: Double)
            let presign = CBS.concat [time, meth, CBS.pack p]
                sign = Base64.encode $ toBytes (hmac (secret tok) presign :: HMAC SHA256)
            return
                Auth
                { authSignature = T.decodeUtf8 sign
                , authKey = T.decodeUtf8 $ key tok
                , authPassphrase = T.decodeUtf8 $ passphrase tok
                , authTimestamp = T.decodeUtf8 time
                }
        Nothing -> throw $ AuthenticationRequiredFailure $ T.pack p

--}
