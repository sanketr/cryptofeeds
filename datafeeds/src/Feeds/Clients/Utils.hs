{-# LANGUAGE OverloadedStrings,ScopedTypeVariables #-}
module Feeds.Clients.Utils
(
 logWriters,
 logWritersTest,
 LogType(..),
 compressLog,
 genSignature,
 HdlInfo(..),
 putLogStr
)
where

import Control.Concurrent (MVar,newMVar,putMVar,tryPutMVar,takeMVar,tryTakeMVar,threadDelay,forkFinally,forkIO)
import Data.IORef
import Control.Monad (unless)
import Control.Exception.Safe (bracketOnError,bracket)
import System.Directory (createDirectoryIfMissing,doesFileExist,removeFile)
import System.FilePath (takeDirectory,(</>),(<.>))
import System.IO (openBinaryFile,IOMode(..),hSetBuffering, BufferMode(..),hClose)
import GHC.IO.Handle.Types (Handle(..))
import Data.Time (formatTime,defaultTimeLocale,toModifiedJulianDay,utctDay)
import Data.Time.Clock.System (systemToUTCTime,getSystemTime)
import Data.List (foldl')
import Data.Char (toLower)
import qualified Data.ByteString as BS (ByteString,hPut)
import Control.Exception(Exception,throw)
import Feeds.Clients.Internal (compressLogZstd)
import Data.ByteArray.Encoding (convertToBase, Base (Base64))
import Crypto.Hash (HashAlgorithm, Digest)
import Crypto.MAC.HMAC (hmac, hmacGetDigest)
--import Data.Time.Clock(addUTCTime,nominalDay) -- used for testing date rollover by faking date changes

signMsg :: (HashAlgorithm a) => BS.ByteString -> BS.ByteString -> Digest a
signMsg key msg = hmacGetDigest . hmac key $ msg

genSignature :: (HashAlgorithm a) => BS.ByteString -> BS.ByteString -> Digest a
genSignature key body = signMsg key (convertToBase Base64 body)

getTimeStamp :: IO String
getTimeStamp = return . show =<< systemToUTCTime <$> getSystemTime 

putLogStr :: String -> IO ()
putLogStr str = getTimeStamp >>= \x -> putStrLn (x ++ ": " ++ str)

-- Simple utility to open a binary file - makes sure that parent directories are created if they don't exist
openFile :: FilePath -> IOMode -> Bool -> IO Handle
openFile fpath mode buffered = do
  let dir = takeDirectory fpath
  createDirectoryIfMissing True dir
  h <- openBinaryFile fpath mode
  h `hSetBuffering` (if not buffered then NoBuffering else BlockBuffering Nothing)
  return h

getPathFromHdl :: Handle -> Maybe FilePath
getPathFromHdl hdl = case hdl of
                      FileHandle fpath _ -> Just fpath
                      _ -> Nothing

compressLogH :: FilePath -> IO ()
compressLogH fpath = do
      fileExists <- doesFileExist fpath -- compress the log only if it exists
      case fileExists of
        True -> do
          let nfpath = fpath <.> ".zst" -- Add .zst extension to file path
          -- Compress log here, and remove uncompressed log after compression
          bracket
            (openFile fpath ReadMode True)
            hClose $ \inphdl -> do
              bracket
                (openFile nfpath WriteMode True)
                hClose $ \outhdl -> do
                      compressLogZstd 9 inphdl outhdl
                      hClose inphdl >> removeFile fpath
        False -> putLogStr ("Not compressing the log as file doesn't exist: " ++ fpath)

compressLog :: Maybe HdlInfo -> IO ()
compressLog handle = maybe (return ()) compressLogH (fmap fpath handle)

-- a function that switches from one filepath to another
-- Takes handle to old file path, closes it, and returns handle to new file path
-- Can throw async exception
switchFiles :: Maybe HdlInfo -> IOMode -> Int -> (Int -> FilePath) -> IO HdlInfo
switchFiles ohdl mode ctr getPath = do
  case ohdl of
    Just handle -> hClose . hdl $ handle
    Nothing -> return () -- first time when we use it, there is no old handle
  -- First check if the file with number ctr already exists - if it does, keep incrementing the counter until
  -- we find a filename that hasn't been created before. This lets us handle restart from multiple crashes by
  -- creating a new log instead of accidentally overwriting an existing log
  let loop num = do
            let fname = getPath num
            -- check for uncompressed as well as compressed log files
            exists <- return . or =<< mapM doesFileExist [fname, fname <.> ".zst"]
            -- Warning - might overflow since there is no upper bound on increment
            if exists then loop (num + 1) else (openFile (getPath num) mode False >>= \x -> return $ HdlInfo x (getPath num))
  loop ctr -- return handle to new file
{-# INLINABLE switchFiles #-}


-- Get date as integer as well as string - we use string to create directories etc. and integer to keep track of date rollover
getDate :: IO (Integer,String)
getDate  = do
  t <- systemToUTCTime <$> getSystemTime
  --t <- addUTCTime (nominalDay*(fromIntegral (sim::Int))) <$> systemToUTCTime <$> getSystemTime
  let datestr = formatTime defaultTimeLocale "%Y.%m.%d" t
      dayint = toModifiedJulianDay . utctDay $ t -- day today with day of 1858-11-17 as 0.
  return (dayint,datestr)

-- State to keep - date, current file number, flag to indicate initialization
data LogState = LogState {logdt:: Integer, logctr:: Int, logstart :: Bool } deriving (Show)
data LogType = Normal | Error deriving (Show)

data HdlInfo = HdlInfo { hdl :: Handle, fpath :: FilePath } deriving (Show)

data NoLogFileException = NormalLogException String | ErrorLogException String

instance Show NoLogFileException where
  show (NormalLogException e) = "NormalLogException: There was an issue when accessing normal log file. " ++ e
  show (ErrorLogException e) = "ErrorLogException: There was an issue when accessing normal log file. " ++ e

instance Exception NoLogFileException

-- We will execute this one in a separate thread and continously monitor for date change
logSwitcher :: Int -> (FilePath,FilePath) -> IORef (Maybe HdlInfo,Maybe HdlInfo) -> LogState -> MVar (Maybe HdlInfo,Maybe HdlInfo) -> IO ()
logSwitcher interval logbasedir hdlinfo st mvar = do
  let loop state = do
        unless (logstart state) $ threadDelay interval -- Dont delay first iteration
        (ndt,ndtstr) <- getDate
        if (logdt state /= ndt) || logstart state then
          do -- Either date rolled over to different day or first time
        -- newctr is not of much use as switchFiles function does the heavy lifting of figuring right number,
        -- but let us keep this for now - might need it in future
            let newctr = if logdt state /= ndt then 1 else 1 + logctr state -- In case of new date, start with 1
            bracketOnError (takeMVar mvar) (putMVar mvar) $ \(h1,h2) ->
              bracketOnError (switchFiles h1 WriteMode newctr (getLogPath Normal ndtstr)) (\x -> putMVar mvar (Nothing,Nothing) >> (hClose . hdl $ x)) $ \hdl1 ->
                bracketOnError (switchFiles h2 WriteMode newctr (getLogPath Error ndtstr)) (\x -> putMVar mvar (Nothing,Nothing) >> (hClose . hdl $ x)) $ \hdl2 -> do
                  putMVar mvar (Just hdl1,Just hdl2) 
                  writeIORef hdlinfo (Just hdl1,Just hdl2)
                  putLogStr $ "Log switching - normal and error logs: " ++ (show .fpath $ hdl1) ++ ", " ++ (show .fpath $ hdl2)
                  -- Old handles h1 and h2 are already closed by switchFiles by now - ok to compress now. We
                  -- will fork off the compression as background threads so as not to wait. If there is any
                  -- error, it needs to be handled by an external cleanup batch script, to keep it simple.
                  _ <- forkIO $ compressLog h1
                  _ <- forkIO $ compressLog h2
                  return ()
            loop LogState { logdt = ndt, logctr = newctr, logstart = False }
        else loop state
        where
          getLogPath :: LogType -> String -> Int -> FilePath
          getLogPath typ dt num = Data.List.foldl' (</>) "" [fst logbasedir,dt,snd logbasedir,map toLower (show typ) ++ show num ++ ".log"]
          {-# INLINABLE getLogPath #-}
  loop st -- loop forever until killed 


-- This function creates log writers that do log file management including rotation - async exceptions are handled
logWriters :: Int -> (FilePath,FilePath) -> IORef (Maybe HdlInfo,Maybe HdlInfo) -> MVar String -> IO (LogType ->  BS.ByteString -> IO())
logWriters interval logbasedir hdlinfo dieSignal = do
  (dt,_) <- getDate
  mvar <- newMVar (Nothing,Nothing)
  let initst = LogState { logdt = dt, logctr = 0, logstart = True}
      cleanUp msg = do
              hdls <- tryTakeMVar mvar -- mvar may not be filled in case of exception - so, don't block
              maybe (return ()) (\(h1,h2) -> mapM_ (maybe (return ()) (hClose . hdl)) [h1,h2]) hdls
              tryPutMVar mvar (Nothing,Nothing) >> putMVar dieSignal msg -- Make sure to put empty values in MVar
  _ <- forkFinally (logSwitcher interval logbasedir hdlinfo initst mvar) (either (cleanUp . show) (const . cleanUp $ "Done with processing messages - test mode")) -- must use forkFinally to send signal to parent thread via dieSignal mvar on exception - the parent thread can then terminate itself if need be
  return $ logMsg mvar
    where
      -- We get current log handle for respective log, and write to it - if for any reasons, no log handle
      -- is found, an exception is thrown which will kill the main thread. We can add logic to restart the
      -- the whole data capture process
      logMsg :: MVar (Maybe HdlInfo,Maybe HdlInfo) -> LogType ->  BS.ByteString -> IO()
      logMsg mvarHdls typ msg = do
        -- must do takeMVar while the log is being written to avoid handle being closed (due to log switch to a new log while the current log is being written to - we make the log switcher wait until the log handles are not in use)
        hlogs <- takeMVar mvarHdls
        -- In case of exception, mvarHdls will stay empty which is ok since we are not in a good state any more
        --, and hence, must kill this thread and restart the parent logger with new mvar
        case typ of
          Normal -> maybe (throw $ ErrorLogException "Normal log file couldnt be accessed for data save") (`BS.hPut` msg) (fmap hdl (fst hlogs))
          Error -> maybe (throw $ ErrorLogException "Error log file couldnt be accessed for data save") (`BS.hPut` msg) (fmap hdl (snd hlogs))
        putMVar mvarHdls hlogs
      {-# INLINABLE logMsg #-}

-- | Just a simple baseline logwriter function for performance debugging and comparison - not for production use!
logWritersTest :: Int -> (FilePath,FilePath) -> MVar String -> IO (LogType ->  BS.ByteString -> IO())
logWritersTest _ logbasedir _ = do
  hdl1 <- openFile (getLogPath Normal "test" 1) WriteMode False
  hdl2 <- openFile (getLogPath Error "test" 1) WriteMode False
  let fn ltyp msg = do
              case ltyp of 
                Normal -> BS.hPut hdl1 msg
                Error -> BS.hPut hdl2 msg
  return fn
  where
          getLogPath :: LogType -> String -> Int -> FilePath
          getLogPath typ dt num = Data.List.foldl' (</>) "" [fst logbasedir,dt,snd logbasedir,map toLower (show typ) ++ show num ++ ".log"]

  
{--
main = do
  dieSignal <- newEmptyMVar
  mvarLogHdls <- logSwitch 60000000 "test/test/abc" dieSignal
  print "acquired mvar"
  takeMVar dieSignal
--}
