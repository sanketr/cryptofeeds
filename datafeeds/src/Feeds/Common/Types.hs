{-# LANGUAGE DeriveGeneric,TemplateHaskell #-}

module Feeds.Common.Types
(
 Exchange(..),
 CompressedBlob(..),
 Environ(..)
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

