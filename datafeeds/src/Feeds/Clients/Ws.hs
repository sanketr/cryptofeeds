{-# LANGUAGE OverloadedStrings #-}
module Feeds.Clients.Ws
(
 client
)
where

import Wuss -- Websocket secure client - small wrapper around websockets library

import Control.Concurrent (forkIO)
import Control.Monad (forever, unless, void)
import Data.Text (Text, pack)
import Network.WebSockets (ClientApp, receiveData, sendClose, sendTextData,sendBinaryData)
import Feeds.Gdax.Types (Heartbeat(..),GdaxRsp,RspMsg(..),ReqMsg(..),Request(..),Channels(..),ChannelMsg(..))
import Data.Aeson.Text as A (encodeToLazyText)

-- This is a websocket client to connect to GDAX websocket feed
client :: IO ()
client = runSecureClient "ws-feed.gdax.com" 443 "/" ws

ws :: ClientApp ()
ws connection = do
  putStrLn "Connected!"

  void . forkIO . forever $ do
    message <- receiveData connection
    print (message :: Text)

  -- Let us build a JSON request for heartbeat to ETH-EUR instrument
  let req1 = A.encodeToLazyText (Request {_req_type = Subscribe, _req_channels = [Channels (ChannelMsg {_channel_name = HeartbeatMsg, _channel_product_ids = ["ETH-EUR"]})]})
  -- Send heartbeat subscription message -
  sendTextData connection req1

  -- let us just loop forever on input from REPL so we never exit
  forever $ getLine
  -- Will never get here, but yeah, let us just keep this placeholder for now - will replace with some kind of clean shutdown mechanism later
  sendClose connection (pack "Bye!")
