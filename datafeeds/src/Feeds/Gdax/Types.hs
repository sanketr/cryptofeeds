{-# LANGUAGE OverloadedStrings,ScopedTypeVariables,DeriveGeneric,TemplateHaskell,BangPatterns #-}

module Feeds.Gdax.Types
(
 Channels(..),
 ReqTyp(..),
 RspTyp(..),
 Request(..),
 RequestMsg(..),
 Heartbeat(..),
 Ticker(..),
 Snapshot(..),
 L2Update(..),
 GdaxRsp(..),
 CompressedBlob(..)
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

data ReqTyp = Subscribe | Unsubscribe deriving (Show, Generic,Typeable)
deriveJSON defaultOptions{constructorTagModifier = Prelude.map toLower,omitNothingFields = True} ''ReqTyp
instance Store ReqTyp

-- Response types - heartbeat, ticker, snapshot, l2update
data RspTyp = HeartbeatTyp | TickerTyp | SnapshotTyp | Level2Typ | L2UpdateTyp deriving (Show, Generic,Typeable)
deriveJSON defaultOptions{constructorTagModifier = (\x -> Prelude.take (-3 + (Prelude.length x)) (Prelude.map toLower x)),omitNothingFields = True} ''RspTyp
instance Store RspTyp

data Channels = Channels { _channel_name :: RspTyp, _channel_product_ids :: [T.Text]} deriving (Show,Generic,Typeable)
deriveJSON defaultOptions{fieldLabelModifier = Prelude.drop 9,constructorTagModifier = Prelude.map toLower,omitNothingFields = True} ''Channels
instance Store Channels

data RequestMsg = RequestMsg [Channels] deriving (Show, Generic,Typeable)
deriveJSON defaultOptions{constructorTagModifier = Prelude.map toLower,omitNothingFields = True} ''RequestMsg
instance Store RequestMsg

data Request = Request { _req_type :: ReqTyp, _req_channels :: RequestMsg } deriving (Show, Generic,Typeable)
deriveJSON defaultOptions{fieldLabelModifier = Prelude.drop 5,constructorTagModifier = Prelude.map toLower,omitNothingFields = True} ''Request
instance Store Request

data Heartbeat = Heartbeat { _hb_type :: RspTyp, _hb_sequence:: Int64, _hb_last_trade_id :: Int64, _hb_product_id :: T.Text, _hb_time :: T.Text } deriving (Show, Generic,Typeable)
deriveJSON defaultOptions{fieldLabelModifier = Prelude.drop 4,constructorTagModifier = Prelude.map toLower,omitNothingFields = True} ''Heartbeat 
instance Store Heartbeat

data Ticker = Ticker { _tick_type :: RspTyp, _tick_product_id :: T.Text, _tick_price :: T.Text, _tick_open_24h :: T.Text, _tick_volume_24h :: T.Text, _tick_low_24h :: T.Text, _tick_high_24h :: T.Text, _tick_volume_30d :: T.Text, _tick_best_bid :: T.Text, _tick_best_ask :: T.Text, _tick_side :: Maybe T.Text, _tick_time :: Maybe T.Text, _tick_trade_id :: Maybe Int64, _tick_last_size :: Maybe T.Text } deriving (Show, Generic,Typeable)
deriveJSON defaultOptions{fieldLabelModifier = Prelude.drop 6,constructorTagModifier = Prelude.map toLower,omitNothingFields = True} ''Ticker
instance Store Ticker

data Snapshot = Snapshot { _snp_type :: RspTyp, _snp_product_id :: T.Text, _snp_bids :: [(T.Text,T.Text)], _snp_asks :: [(T.Text,T.Text)]} deriving (Show, Generic,Typeable)
deriveJSON defaultOptions{fieldLabelModifier = Prelude.drop 5,constructorTagModifier = Prelude.map toLower,omitNothingFields = True} ''Snapshot 
instance Store Snapshot

data L2Update = L2Update { _l2upd_type :: RspTyp ,_l2upd_product_id :: T.Text, _l2upd_changes :: [(T.Text,T.Text,T.Text)]} deriving (Show, Generic,Typeable)
deriveJSON defaultOptions{fieldLabelModifier = Prelude.drop 7,constructorTagModifier = Prelude.map toLower,omitNothingFields = True} ''L2Update
instance Store L2Update

data GdaxRsp = GdRHb Heartbeat | GdRTick Ticker | GdRSnap Snapshot | GdRL2Up L2Update deriving (Show, Generic,Typeable)
deriveJSON defaultOptions{omitNothingFields = True, sumEncoding  = UntaggedValue} ''GdaxRsp
instance Store GdaxRsp

-- We use the data structure below to compress data, and use Store library to implement streaming
-- decompression - that way, we are not at the mercy of compression algorithm for solid streaming
-- implementation 
data CompressedBlob = Compressed !BS.ByteString deriving (Show,Generic,Typeable)
instance Store CompressedBlob
