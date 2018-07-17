{-# LANGUAGE OverloadedStrings #-}

module Feeds.Common.Parsers where

import           Data.Aeson.Types
import           Data.Monoid
import           Data.Text           (Text)
import qualified Data.Text           as T
import           Text.Read

textMaybeRead ::  (Read a) =>  Maybe Value -> Parser (Maybe a)
textMaybeRead Nothing  = return Nothing
textMaybeRead (Just v) = Just <$> textRead v

textRead :: (Read a) => Value -> Parser a
textRead = withText "Text Read" $ \t ->
    case readMaybe (T.unpack t) of
        Just n  -> pure n
        Nothing -> fail "Could not read value from string."
