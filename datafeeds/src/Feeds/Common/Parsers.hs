{-# LANGUAGE OverloadedStrings #-}

module Feeds.Common.Parsers where

import           Data.Aeson.Types
import           Data.Monoid
import           Data.Text           (Text)
import qualified Data.Text           as T
import           Text.Read
import           Data.Vector         as V

maybeTextRead ::  (Read a) =>  Maybe Value -> Parser (Maybe a)
maybeTextRead Nothing  = return Nothing
maybeTextRead (Just v) = Just <$> textRead v

textRead :: (Read a) => Value -> Parser a
textRead = withText "Text Read" $ \t ->
    case readMaybe (T.unpack t) of
        Just n  -> pure n
        Nothing -> fail "Could not read value from string."

withObjectOfType :: String -> Text -> (Object -> Parser a) -> Value -> Parser a
withObjectOfType name typname fn = withObject name $ \o -> do
    t <- o .: "type"
    if t == typname
        then fn o
        else fail $ T.unpack $ "Expected type 'subscribe' got '" <> t <> "'."

nothingToEmptyVector :: Maybe (Vector a) -> Vector a
nothingToEmptyVector (Just v) = v
nothingToEmptyVector Nothing  = V.empty
