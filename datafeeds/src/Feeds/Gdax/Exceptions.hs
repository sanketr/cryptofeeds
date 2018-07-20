module Feeds.Gdax.Exceptions where

import Control.Exception.Safe
import Data.Text (Text)

data MalformedGdaxResponse
    = MalformedGdaxResponse Text
    deriving (Show)

instance Exception MalformedGdaxResponse
