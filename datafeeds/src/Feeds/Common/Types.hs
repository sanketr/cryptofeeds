{-# LANGUAGE DeriveGeneric,TemplateHaskell #-}

module Feeds.Common.Types
(
 Exchange(..),
 CompressedBlob(..),
 Environ(..),
 LogState(..),
 LogType(..),
 HdlInfo(..),
 NoLogFileException(..),
 ExchCfg(..),
 RestMethod(..),
 Endpoint
)

where

import Data.Aeson.TH
import Data.Store
import GHC.Generics
import Data.Typeable
import Data.Text as T (Text)
import Data.Char (toLower)
import Data.Int (Int64)
import Data.ByteString as BS (ByteString)
import Control.Exception(Exception,throw)
import GHC.IO.Handle.Types (Handle(..))

-- We use the data structure below to compress data, and use Store library to implement streaming
-- decompression - that way, we are not at the mercy of compression algorithm for solid streaming
-- implementation 
data CompressedBlob = Compressed BS.ByteString deriving (Show,Generic,Typeable)
instance Store CompressedBlob

-- Exchange tagging for each exchange we will like to trade on - used for typeclasses that handle
-- exchange-specific processing
data Exchange = Gdax | Gemini | Bitfinex deriving  (Show,Generic,Typeable)
instance Store Exchange

data Environ = Live | Sandbox deriving (Show, Generic,Typeable)

-- State to keep - date, current file number, flag to indicate initialization
data LogState = LogState {logdt:: Integer, logctr:: Int, logstart :: Bool } deriving (Show)
data LogType = Normal | Error deriving (Show)

data HdlInfo = HdlInfo {hdl :: Handle, fpath :: FilePath} deriving (Show)

data NoLogFileException = NormalLogException String | ErrorLogException String

instance Show NoLogFileException where
  show (NormalLogException e) = "NormalLogException: There was an issue when accessing normal log file. " ++ e
  show (ErrorLogException e) = "ErrorLogException: There was an issue when accessing normal log file. " ++ e

instance Exception NoLogFileException

-- Exchange Config - Rest URL, WS URL, secret, pass, key
data ExchCfg = ExchCfg Endpoint Endpoint BS.ByteString BS.ByteString BS.ByteString deriving (Show, Generic,Typeable)

data RestMethod = POST | DELETE | GET deriving (Show, Generic, Typeable)

type Endpoint = String
