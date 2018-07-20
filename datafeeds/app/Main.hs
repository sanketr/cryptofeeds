module Main where

import Feeds.Clients.Ws as C (client)
import Control.Concurrent.Async (async,waitCatch)
import Control.Concurrent (threadDelay,forkIO)
import System.IO
import Data.Time.Clock.System (systemToUTCTime,getSystemTime)
import Data.IORef
import Feeds.Clients.Utils (compressLog,putLogStr)
import Feeds.Common.Types (HdlInfo(..))


main :: IO ()
main = do
  -- Flush all logging immediately to file
  hSetBuffering stdout LineBuffering
  hSetBuffering stderr LineBuffering
  hdlinfo <- newIORef (Nothing,Nothing)  -- we always pass a IORef to the client to let it tell us which logs were being written when it crashed. We then compress them
  let loop = do
          putLogStr ": Started new connection"
          cl <- async $ C.client hdlinfo
          res <- waitCatch cl -- If the client crashes, we capture the exception that caused it to crash, and then we restart the client
          case res of 
            Left e -> putLogStr (show e) -- log error along with UTC time stamp that it happened
            _ -> return ()
          (h1,h2) <- readIORef hdlinfo
          putLogStr (" Closing and compressing the logs " ++ show (fmap fpath h1) ++ "," ++ show (fmap fpath h2))
          -- Close the log handles to avoid file locking error at haskell API level
          maybe (return ()) (hClose . hdl) h1 
          maybe (return ()) (hClose . hdl) h2 
          writeIORef hdlinfo (Nothing,Nothing) -- Reset the IORef since we have grabbed handles now
          -- Kick off the compression of logs in background
          _ <- forkIO $ compressLog h1
          _ <- forkIO $ compressLog h2
          threadDelay 1000000 -- Delay for one second before restarting the client on crash
          loop -- Restart the client
  loop
