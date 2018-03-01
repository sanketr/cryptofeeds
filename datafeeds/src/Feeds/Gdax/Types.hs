{-# LANGUAGE OverloadedStrings,ScopedTypeVariables,DeriveGeneric, TemplateHaskell #-}

module Feeds.Gdax.Types
(
 Channels(..),
 ReqMsg(..),
 RspMsg(..),
 ChannelMsg(..),
 Request(..),
 Heartbeat(..),
 Ticker(..),
 Snapshot(..),
 L2Update(..),
 GdaxRsp(..)
)

where

import Data.Aeson.TH
import GHC.Generics
import Data.Typeable
import Data.Text as T (Text,unpack)
import Data.Char (toLower)
import Data.Int (Int64)
import Data.Vector as V (Vector)
import Data.ByteString.Lazy as LBS (ByteString)
import Control.Exception (Exception)

data ReqMsg = Subscribe | Unsubscribe deriving (Show, Generic,Typeable)
deriveJSON defaultOptions{constructorTagModifier = Prelude.map toLower,omitNothingFields = True} ''ReqMsg

-- Response types - heartbeat, ticker, snapshot, l2update
data RspMsg = HeartbeatMsg | TickerMsg | SnapshotMsg | L2updateMsg deriving (Show, Generic,Typeable)
deriveJSON defaultOptions{constructorTagModifier = (\x -> Prelude.take (-3 + (Prelude.length x)) (Prelude.map toLower x)),omitNothingFields = True} ''RspMsg

data ChannelMsg = ChannelMsg { _channel_name :: RspMsg, _channel_product_ids :: [T.Text]} deriving (Show,Generic,Typeable)
deriveJSON defaultOptions{fieldLabelModifier = Prelude.drop 9,constructorTagModifier = Prelude.map toLower,omitNothingFields = True} ''ChannelMsg

data Channels = Channels ChannelMsg deriving (Show,Generic,Typeable)
deriveJSON defaultOptions{constructorTagModifier = Prelude.map toLower,omitNothingFields = True} ''Channels

data Request = Request { _req_type :: ReqMsg, _req_channels :: [Channels] } deriving (Show, Generic,Typeable)
deriveJSON defaultOptions{fieldLabelModifier = Prelude.drop 5,constructorTagModifier = Prelude.map toLower,omitNothingFields = True} ''Request

data Heartbeat = Heartbeat { _hb_type :: RspMsg, _hb_sequence:: Int64, _hb_last_trade_id :: Int64, _hb_product_id :: T.Text, _hb_time :: T.Text } deriving (Show, Generic,Typeable)
deriveJSON defaultOptions{fieldLabelModifier = Prelude.drop 4,constructorTagModifier = Prelude.map toLower,omitNothingFields = True} ''Heartbeat 

data Ticker = Ticker { _tick_type :: RspMsg, _tick_product_id :: T.Text, _tick_price :: T.Text, _tick_open_24h :: T.Text, _tick_volume_24h :: T.Text, _tick_low_24h :: T.Text, _tick_high_24h :: T.Text, _tick_volume_30d :: T.Text, _tick_best_bid :: T.Text, _tick_best_ask :: T.Text, _tick_side :: T.Text, _tick_time :: T.Text, _tick_trade_id :: Int64, _tick_last_size :: T.Text } deriving (Show, Generic,Typeable)
deriveJSON defaultOptions{fieldLabelModifier = Prelude.drop 6,constructorTagModifier = Prelude.map toLower,omitNothingFields = True} ''Ticker

data Snapshot = Snapshot { _snp_type :: RspMsg, _snp_product_id :: T.Text, _snp_bids :: [(T.Text,T.Text)], _snp_asks :: [(T.Text,T.Text)]} deriving (Show, Generic,Typeable)
deriveJSON defaultOptions{fieldLabelModifier = Prelude.drop 5,constructorTagModifier = Prelude.map toLower,omitNothingFields = True} ''Snapshot 

data L2Update = L2Update { _l2upd_type :: RspMsg ,_l2upd_product_id :: T.Text, _l2upd_changes :: [(T.Text,T.Text,T.Text)]} deriving (Show, Generic,Typeable)
deriveJSON defaultOptions{fieldLabelModifier = Prelude.drop 7,constructorTagModifier = Prelude.map toLower,omitNothingFields = True} ''L2Update

data GdaxRsp = GdRHb Heartbeat | GdRTick Ticker | GdRSnap Snapshot | GdRL2Up L2Update deriving (Show, Generic,Typeable)
deriveJSON defaultOptions{omitNothingFields = True, sumEncoding  = UntaggedValue} ''GdaxRsp
