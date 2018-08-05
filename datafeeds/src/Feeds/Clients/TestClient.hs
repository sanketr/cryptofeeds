{-# LANGUAGE OverloadedStrings #-}
module Feeds.Clients.TestClient where

import Network.WebSockets as WS
import Data.Store as B
import Data.ByteString.Lazy as LBS (toStrict)
import  Feeds.Gdax.Types.Feed (PubMdataMsg(..),Ticker(..),Obook(..))

client :: IO ()
client = runClient "localhost" 8001 "/ws1/marketdata" clientApp
  
clientApp :: ClientApp ()
clientApp conn = do
  let loop = do
          msg <- receiveData conn -- We get binary data (encoded using Store library) over the websocket. Decode it below
          case (B.decode . LBS.toStrict $ msg :: Either PeekException PubMdataMsg) of
            Left e -> putStrLn . show $ e
            Right a -> putStrLn . show $ a
          loop
  loop
