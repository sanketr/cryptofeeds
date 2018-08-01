module Main where

import Feeds.Clients.Ws as C (client)
import Control.Concurrent.Async (async,waitCatch,waitEitherCatchCancel)
import Control.Concurrent (threadDelay,forkIO,ThreadId,MVar,newEmptyMVar,putMVar,takeMVar)
import System.IO
import Data.Time.Clock.System (systemToUTCTime,getSystemTime)
import Data.IORef
import Feeds.Clients.Utils (compressLog,putLogStr)
import Feeds.Common.Types (HdlInfo(..))
import qualified Feeds.Gdax.Types.Feed as F (GdaxMessage)
import Feeds.Clients.PubMarketData (runMdataPubServer)
import Feeds.Clients.Orderbook (HashTable)
import qualified Data.HashTable.IO as H (new)
import Data.ByteString.Lazy as LBS (ByteString,empty)

main :: IO ()
main = do
  -- Flush all logging immediately to file
  hSetBuffering stdout LineBuffering
  hSetBuffering stderr LineBuffering
  hdlinfo <- newIORef (Nothing,Nothing)  -- we always pass a IORef to the client to let it tell us which logs were being written when it crashed. We then compress them
  msgChan <- newEmptyMVar :: IO (MVar F.GdaxMessage)
  obhtbl <- H.new -- Initialize orderbook table here so that it can persist across marketdata sub restarts
  {--
  -- Algorithm:
  -- First loop:
  --  -- Run market data subscriber that grabs the data from exchange
      -- Subscriber saves data to log
      -- Subscriber also writes that data to msgChan mvar

  -- Second loop:
  --  -- Run market data publisher - it is a websocket server that keeps track of each active client connection
      -- When subscriber in first loop writes to msgChan mvar, publisher writes it after processing to each of the active client
      -- Thus, each of subscriber's client get the processed market data

  -- Both loops run in parallel. Termination of either of them will terminate other one as well
  --}
  let mDataSubLoop = do
          putLogStr "Starting new market data subscriber"
          cl <- async $ C.client hdlinfo msgChan
          res <- waitCatch cl -- If the client crashes, we capture the exception that caused it to crash, and then we restart the client
          case res of 
            Left e -> putLogStr (show e) -- log error along with UTC time stamp that it happened
            _ -> return ()
          (h1,h2) <- readIORef hdlinfo
          putLogStr (" Closing and compressing the logs " ++ show h1 ++ "," ++ show h2)
          -- Close the log handles to avoid file locking error at haskell API level
          maybe (return ()) (hClose . hdl) h1 
          maybe (return ()) (hClose . hdl) h2 
          writeIORef hdlinfo (Nothing,Nothing) -- Reset the IORef since we have grabbed handles now
          -- Kick off the compression of logs in background
          _ <- forkIO $ compressLog h1
          _ <- forkIO $ compressLog h2
          threadDelay 1000000 -- Delay for one second before restarting the client on crash
          mDataSubLoop -- Restart the client
  let mDataPubLoop = do
          putLogStr "Starting new market data publisher"
          pubServer <- async $ runMdataPubServer msgChan obhtbl
          res <- waitCatch pubServer
          case res of
            Left e -> putLogStr ("Market data server crashed: " ++ show e) 
            _ -> return ()
          mDataPubLoop
  bgmDataSubLoop <- async mDataSubLoop
  bgmDataPubLoop <- async mDataPubLoop
  res <- waitEitherCatchCancel bgmDataSubLoop bgmDataPubLoop
  let logMsg = either (putLogStr . show) (\_ -> return ()) in either logMsg logMsg res
  return ()
