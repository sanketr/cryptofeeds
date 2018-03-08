{-# LANGUAGE OverloadedStrings,ScopedTypeVariables #-}
module Feeds.Clients.Utils
(
 switchFiles,
)
where

import Control.Concurrent (MVar,newMVar,isEmptyMVar,readMVar,putMVar,tryPutMVar,takeMVar,tryTakeMVar,threadDelay,forkFinally)
import Control.Concurrent.Async (async,waitCatch)
import Control.Exception.Safe (bracket,bracketOnError,try)
import System.Directory (createDirectoryIfMissing,listDirectory)
import System.FilePath (takeDirectory,(</>))
import System.IO (openBinaryFile,IOMode(..),hSetBuffering, BufferMode(..),hClose)
import GHC.IO.Handle (Handle)
import Data.Time (formatTime,defaultTimeLocale,toModifiedJulianDay,utctDay)
import Data.Time.Clock.System (systemToUTCTime,getSystemTime)
import Data.List (foldl')
import Data.Char (toLower)

{-- |
Top level - retry on exception, log retry event with details on what happened:
a) connection was dropped
b) any of the log handles couldn't be used

Connection ->

acquire file handle1 with bracket - put in mvar - on cleanup, Left Exception in mvar - users should exit on error
acquire file handle2 with bracket - put in mvar 

if any async exception, cancel the thread that uses those handles, throw exception
--}

-- Simple utility to open a binary file - makes sure that parent directories are created if they don't exist
openFile :: FilePath -> IOMode -> IO Handle
openFile fpath mode = do
  let dir = takeDirectory fpath
  createDirectoryIfMissing True dir
  h <- openBinaryFile fpath mode
  h `hSetBuffering` NoBuffering
  return h

-- a function that switches from one filepath to another
-- Takes handle to old file path, closes it, and returns handle to new file path
-- Can throw async exception
switchFiles :: Maybe Handle -> FilePath -> IOMode -> IO Handle
switchFiles ohdl npath mode = do
  case ohdl of
    Just hdl -> hClose hdl
    Nothing -> return () -- first time when we use it, there is no old handle
  openFile npath mode -- return handle to new file

-- Get date as integer as well as string - we use string to create directories etc. and integer to keep track of date rollover
getDate :: IO (Integer,String)
getDate = do
  t <- systemToUTCTime <$> getSystemTime
  let datestr = formatTime defaultTimeLocale "%Y.%m.%d" t
      dayint = toModifiedJulianDay . utctDay $ t -- day today with day 1858-11-17 as 0.
  return (dayint,datestr)

-- TODO - keep state for file handles - should be filled before IO so it persists across exceptions  
-- State to keep - date, current file number 
data LogState = LogState {logdt:: Integer, logctr:: Int, logstart :: Bool } deriving (Show)
data LogType = Normal | Error deriving (Show)

getLogCtr :: FilePath -> IO (Maybe Int)
getLogCtr fpath = do
  r <- waitCatch =<< (async $ listDirectory fpath)
  case r of
    Left _ -> return Nothing
    Right files -> undefined -- Todo - look for file pattern for log typ, and get max number if exists. Else Nothing

-- We will execute this one in a separate thread and continously monitor for date change
-- Can throw exception while MVar is already blocked by takeMVar
logSwitchH :: Int -> FilePath -> LogState -> MVar (Maybe Handle,Maybe Handle) -> IO ()
logSwitchH interval logbasedir st mvar = do
  let loop state = do
        threadDelay interval -- Wait for specified interval and then check below if date changed
        (ndt,ndtstr) <- getDate
        case (logdt state < ndt) || logstart state of
          True -> do -- Either date incremented or first time
                let newctr = if logdt state < ndt then 1 else 1 + logctr state -- In case of new date, start with 1
                bracketOnError (takeMVar mvar) (tryPutMVar mvar) $ \(h1,h2) ->
                  bracket (switchFiles h1 (getLogPath Normal ndtstr newctr) WriteMode) hClose $ \hdl1 ->
                    bracket (switchFiles h2 (getLogPath Error ndtstr newctr) WriteMode) hClose $ \hdl2 ->
                      putMVar mvar (Just hdl1,Just hdl2)
                -- TODO - make sure numbering is correct
                loop LogState { logdt = ndt, logctr = newctr, logstart = False }
          False -> loop state
        where
          getLogPath :: LogType -> String -> Int -> FilePath
          getLogPath typ dt num = Data.List.foldl' (</>) "" [logbasedir,dt,map toLower (show typ) ++ show num ++ ".log"]

  loop st -- loop forever until killed - make sure to do forkFinally for handle cleanup - use tryTakeMVar to avoid blocking

-- This function takes care of creating log file handles, and closing them - async exceptions are handled
logSwitch :: Int -> FilePath -> IO (MVar (Maybe Handle,Maybe Handle))
logSwitch interval logbasedir = do
  (dt,dtstr) <- getDate
  mvar <- newMVar (Nothing,Nothing)
  let initst = LogState { logdt = dt, logctr = 0, logstart = True}
      cleanUp = do
              hdls <- tryTakeMVar mvar -- mvar may not be filled in case of exception - so, don't block
              maybe (return ()) (\(h1,h2) -> mapM_ (maybe (return ()) hClose) [h1,h2]) hdls
              tryPutMVar mvar (Nothing,Nothing) >> return () -- Make sure to put empty values in MVar
  forkFinally (logSwitchH interval logbasedir initst mvar) (\_ -> cleanUp)
  return mvar
