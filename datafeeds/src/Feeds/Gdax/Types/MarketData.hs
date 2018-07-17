{-# LANGUAGE OverloadedStrings,ScopedTypeVariables,DeriveGeneric,TemplateHaskell,BangPatterns #-}

module Feeds.Gdax.Types.MarketData
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
 Obook(..),
 GdaxAPIKeys (..),
 GdaxAuthReq(..)
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
import Feeds.Common.Parsers

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

data Request = Request { _req_user_id :: Maybe T.Text, _req_type :: ReqTyp, _req_channels :: RequestMsg } deriving (Show, Generic,Typeable)
deriveJSON defaultOptions{fieldLabelModifier = Prelude.drop 5,constructorTagModifier = Prelude.map toLower,omitNothingFields = True} ''Request
instance Store Request

data Heartbeat = Heartbeat { _hb_user_id :: Maybe T.Text, _hb_type :: RspTyp, _hb_sequence:: Int64, _hb_last_trade_id :: Int64, _hb_product_id :: T.Text, _hb_time :: T.Text } deriving (Show, Generic,Typeable)
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

-- Type to parse order book - order book is built from snapshots and updates - it doesn't have time which we will need to guess from trades for now. Need to add line time in UTC for order book capture
data ObookState = OUpd L2Update | OInit Snapshot deriving (Show, Generic,Typeable)

data Obook = Obook { _obook_timestamp :: T.Text, _obook_ticker :: T.Text, _obook_seqnum :: Int, _obook_bids :: [(Float,Float)], _obook_asks :: [(Float,Float)] } deriving  (Show, Generic,Typeable)
deriveJSON defaultOptions{fieldLabelModifier = Prelude.drop 7,constructorTagModifier = Prelude.map toLower,omitNothingFields = True} ''Obook
instance Store Obook

-- This equality derivation is useful to determine if orderbook bids/asks have changed, and to publish order book
-- in case of change
instance Eq Obook where
  a == b = (_obook_ticker a == _obook_ticker b) && (_obook_bids a == _obook_bids b) &&(_obook_asks a == _obook_asks b)


data GdaxRsp = GdRHb Heartbeat | GdRTick Ticker | GdRSnap Snapshot | GdRL2Up L2Update deriving (Show, Generic,Typeable)
deriveJSON defaultOptions{omitNothingFields = True, sumEncoding  = UntaggedValue} ''GdaxRsp
instance Store GdaxRsp

-- ApiKey - secret, pass, key
data GdaxAPIKeys = GdaxAPIKeys BS.ByteString BS.ByteString BS.ByteString deriving (Show, Generic,Typeable)

-- Gdax Auth Req Method Type (all upper case), URL, Json Body
data GdaxAuthReq = GdaxAuthReq BS.ByteString BS.ByteString BS.ByteString deriving (Show, Generic,Typeable)
