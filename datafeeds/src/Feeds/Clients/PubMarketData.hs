{-# LANGUAGE OverloadedStrings #-}

module Feeds.Clients.PubMarketData
(
runMdataPubServer
)
where

import Feeds.Common.Broadcast
import qualified Network.WebSockets as WS (Connection,sendBinaryData,sendClose,PendingConnection,acceptRequest,forkPingThread,receiveDataMessage,ConnectionOptions(..),defaultConnectionOptions,SizeLimit(..))
import qualified Network.WebSockets.Snap as WS
import Control.Exception.Safe (try,SomeException,catch)
import qualified Data.UUID as U (UUID)
import qualified Data.UUID.V4 as U (nextRandom)
import qualified Data.ByteString.Lazy as LBS
import qualified Data.ByteString as BS (ByteString)
import Data.ByteString.Lazy.Char8 as BSC (pack)
import Snap.Http.Server (httpServe,emptyConfig,setPort,ConfigLog(..),setErrorLog,setAccessLog)
import Snap.Core
import Snap.Util.Proxy
import Control.Concurrent.MVar (MVar,newEmptyMVar,takeMVar)
import Control.Concurrent.Async (async,waitEitherCatchCancel)
import Feeds.Gdax.Types.Feed (GdaxMessage(..),PubMdataMsg(..))
import Feeds.Gdax.Types.Shared (ProductId)
import Feeds.Clients.Orderbook (HashTable,updateHTbl,OData)
import Feeds.Clients.Utils (putLogStr)
import Data.Store as B (encode)
import Data.Maybe (catMaybes)

data WsConn = WsConn !U.UUID !WS.Connection 

instance Show WsConn where
  show (WsConn a _) = show a

instance Eq WsConn where
  (==) (WsConn a _) (WsConn b _) = a == b

-- Takes a websocket connection, and returns a unique WsConn that will be used for book-keeping of that
-- connection
getUniqueWsId :: WS.Connection -> IO WsConn
getUniqueWsId conn = flip WsConn conn <$> U.nextRandom

sendWsMsg :: WsConn -> LBS.ByteString -> IO ()
sendWsMsg (WsConn _ conn) msg = do
                ok <- try $ WS.sendBinaryData conn msg :: IO (Either SomeException ())
                case ok of
                  -- Close connection in case of exception when sending data
                  Left e -> WS.sendClose conn (pack . show $ e)
                  Right _ -> return ()

wsApp :: Broadcast WsConn -> Snap()
wsApp bcast = behindProxy X_Forwarded_For $ route [("/ws1/marketdata", mdataApp bcast)]

mdataApp :: Broadcast WsConn -> Snap()
mdataApp bcast = do
    raddr <- getsRequest rqClientAddr
    -- put a 1MB size limit on incoming message to prevent Denial-of-Service attack
    WS.runWebSocketsSnapWith (WS.defaultConnectionOptions {WS.connectionMessageDataSizeLimit = WS.SizeLimit 1048576}) $ pubMdata bcast raddr

handler ::  SomeException -> IO ()
handler ex = putStrLn $ "Caught exception: " ++ show ex
            
pubMdata :: Broadcast WsConn -> BS.ByteString -> WS.PendingConnection -> IO ()
pubMdata bcast raddr pending = do
    -- TODO - reject connection request if remote address is not local
    conn <- WS.acceptRequest pending
    WS.forkPingThread conn 30 -- keep alive in web-browser
    connid <- getUniqueWsId conn
    -- add the client to broadcast of market data
    addListener bcast connid
    let loop = do
            _ <- WS.receiveDataMessage conn -- ignore all incoming data
            loop
    catch loop ((\_ -> delListener bcast connid) :: SomeException -> IO ())
    loop

getTrade :: GdaxMessage -> Maybe PubMdataMsg
getTrade (GdaxTicker t) = Just (PubTicker t)
getTrade _              = Nothing

runMdataPubServer :: MVar GdaxMessage -> HashTable ProductId OData -> IO ()
runMdataPubServer msgChan htbl = do
    bcast <- newBroadcast    
    wsServer <- async $ httpServe (setErrorLog ConfigNoLog $ setAccessLog ConfigNoLog $ setPort 8001 emptyConfig) $ wsApp bcast
    let bcastH msg =  broadcast (flip sendWsMsg) bcast (LBS.fromStrict . B.encode $ msg)
        bcastLoop = do
          msg <- takeMVar msgChan
          obook <- fmap PubObook <$> updateHTbl htbl 5 msg -- Get updated Level 5 orderbook - Just only on changes, else Nothing
          mapM_ bcastH $ catMaybes [getTrade msg,obook]
          bcastLoop
    bcastServer <- async bcastLoop
    res <- waitEitherCatchCancel wsServer bcastServer
    let logMsg = either (putLogStr . show) (\_ -> return ()) in either logMsg logMsg res
    return ()

{--
test :: IO()
test = do
    msgChan <- newEmptyMVar
    res <- async $ runMdataPubServer msgChan
    let loop = do
          putMVar msgChan "test broadcast"
          threadDelay 1000000 -- Delay for one second
          loop
    bcast <- async loop
    threadDelay 10000000
    cancel res
    cancel bcast
--}
