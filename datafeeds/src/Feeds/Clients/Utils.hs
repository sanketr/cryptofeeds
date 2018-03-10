{-# LANGUAGE OverloadedStrings,ScopedTypeVariables #-}
module Feeds.Clients.Utils
(
 logSwitch
)
where

import Control.Concurrent (MVar,newMVar,putMVar,tryPutMVar,takeMVar,tryTakeMVar,threadDelay,forkFinally)
import Control.Monad (unless)
import Control.Exception.Safe (bracket,bracketOnError)
import System.Directory (createDirectoryIfMissing,doesFileExist)
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

acquire file handle1 with bracket - put in mvar
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
switchFiles :: Maybe Handle -> IOMode -> Int -> (Int -> FilePath) -> IO Handle
switchFiles ohdl mode ctr getPath = do
  case ohdl of
    Just hdl -> hClose hdl
    Nothing -> return () -- first time when we use it, there is no old handle
  -- First check if the file with number ctr already exists - if it does, keep incrementing the counter until
  -- we find a filename that hasn't been created before. This lets us handle restart from multiple crashes by
  -- creating a new log instead of accidentally overwriting an existing log
  let loop num = do
            exists <- doesFileExist $ getPath num
            -- Warning - might overflow since there is no upper bound - partial function
            if exists then loop (num + 1) else openFile (getPath num) mode
  loop ctr -- return handle to new file

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

-- We will execute this one in a separate thread and continously monitor for date change
-- Can throw exception while MVar is already blocked by takeMVar
logSwitchH :: Int -> FilePath -> LogState -> MVar (Maybe Handle,Maybe Handle) -> IO ()
logSwitchH interval logbasedir st mvar = do
  let loop state = do
        unless (logstart state) $ threadDelay interval -- Dont delay first iteration
        (ndt,ndtstr) <- getDate
        case (logdt state < ndt) || logstart state of
          True -> do -- Either date rolled over to next day or first time
                let newctr = if logdt state < ndt then 1 else 1 + logctr state -- In case of new date, start with 1
                bracketOnError (takeMVar mvar) (tryPutMVar mvar) $ \(h1,h2) ->
                  bracketOnError (switchFiles h1 WriteMode newctr (getLogPath Normal ndtstr)) hClose $ \hdl1 ->
                    bracketOnError (switchFiles h2 WriteMode newctr (getLogPath Error ndtstr)) hClose $ \hdl2 ->
                      putMVar mvar (Just hdl1,Just hdl2)
                -- TODO - make sure numbering is correct
                loop LogState { logdt = ndt, logctr = newctr, logstart = False }
          False -> loop state
        where
          getLogPath :: LogType -> String -> Int -> FilePath
          getLogPath typ dt num = Data.List.foldl' (</>) "" [logbasedir,dt,map toLower (show typ) ++ show num ++ ".log"]
  loop st -- loop forever until killed - make sure to do forkFinally for handle cleanup 

-- This function takes care of creating log file handles, and closing them - async exceptions are handled
logSwitch :: Int -> FilePath -> MVar String -> IO (MVar (Maybe Handle,Maybe Handle))
logSwitch interval logbasedir dieSignal = do
  (dt,dtstr) <- getDate
  mvar <- newMVar (Nothing,Nothing)
  let initst = LogState { logdt = dt, logctr = 0, logstart = True}
      cleanUp = do
              hdls <- tryTakeMVar mvar -- mvar may not be filled in case of exception - so, don't block
              maybe (return ()) (\(h1,h2) -> mapM_ (maybe (return ()) hClose) [h1,h2]) hdls
              print "Cleaning up"
              tryPutMVar mvar (Nothing,Nothing) >> putMVar dieSignal "Exception during log switch logic" -- Make sure to put empty values in MVar
  forkFinally (logSwitchH interval logbasedir initst mvar) (const cleanUp)
  return mvar

{--
main = do
  dieSignal <- newEmptyMVar
  mvarLogHdls <- logSwitch 60000000 "test/test/abc" dieSignal
  print "acquired mvar"
  takeMVar dieSignal
--}
