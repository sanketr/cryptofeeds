{-# LANGUAGE DeriveDataTypeable         #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE TemplateHaskell            #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE RecordWildCards            #-}

module Feeds.Gdax.Types.Feed where

import           Data.Aeson
import           Data.Aeson.TH
import           Data.Monoid
import           Data.Text                 (Text)
import qualified Data.Text                 as T
import qualified Data.Text.Encoding        as T (decodeUtf8,encodeUtf8)
import           Data.Time
import           Data.Typeable
import           Data.UUID
import           Data.Vector               hiding ((++),all)
import qualified Data.Vector.Generic       as V
import           GHC.Generics
import           Feeds.Common.Parsers
import           Feeds.Gdax.Types.Shared
import           Data.Store                (Store)
import           Data.Maybe                (isJust,fromJust)

data Channel
    = ChannelHeartbeat
    | ChannelTicker
    | ChannelLevel2
    | ChannelUser
    | ChannelMatches
    | ChannelFull
    deriving (Eq, Ord, Typeable, Generic)

instance Store Channel

instance Show Channel where
    show ChannelHeartbeat = "heartbeat"
    show ChannelTicker    = "ticker"
    show ChannelLevel2    = "level2"
    show ChannelUser      = "user"
    show ChannelMatches   = "matches"
    show ChannelFull      = "full"

instance ToJSON Channel where
    toJSON = String . T.pack . show

instance FromJSON Channel where
    parseJSON = withText "Channel" $ \t ->
        case t of
            "heartbeat" -> pure ChannelHeartbeat
            "ticker"    -> pure ChannelTicker
            "level2"    -> pure ChannelLevel2
            "user"      -> pure ChannelUser
            "matches"   -> pure ChannelMatches
            "full"      -> pure ChannelFull
            u -> fail $ T.unpack $ "Received from unsupported channel '" <> u <> "'."

data ChannelSubscription
    = ChannelSubscription
        { _csubChannel  :: Channel
        , _csubProducts :: Vector ProductId
        }
    deriving (Show, Typeable, Generic)

instance Store ChannelSubscription

instance ToJSON ChannelSubscription where
    toJSON c | V.null (_csubProducts c) = toJSON (_csubChannel c)
             | otherwise = object
                [ "name" .= _csubChannel c
                , "product_ids" .= _csubProducts c
                ]

instance FromJSON ChannelSubscription where
    parseJSON s@String{} = ChannelSubscription
        <$> parseJSON s
        <*> pure V.empty
    parseJSON (Object o) = ChannelSubscription
        <$> o .: "name"
        <*> o .: "product_ids"
    parseJSON _ = fail "Channel subscription was not a String or Object."

data Subscriptions
    = Subscriptions
        { _subProducts :: Vector ProductId
        , _subChannels :: Vector ChannelSubscription
        }
    deriving (Show, Typeable, Generic)

instance Store Subscriptions
instance FromJSON Subscriptions where
    parseJSON = withObjectOfType "Subscriptions" "subscriptions" $ \o -> Subscriptions
        <$> (nothingToEmptyVector <$> o .:? "products")
        <*> o .: "channels"

deriveToJSON defaultOptions{fieldLabelModifier = camelTo2 '_' . Prelude.drop 4,omitNothingFields = True} ''Subscriptions

data ReqTyp = Subscribe | Unsubscribe deriving (Show, Generic,Typeable)
deriveJSON defaultOptions{constructorTagModifier = camelTo2 '_',omitNothingFields = True} ''ReqTyp
instance Store ReqTyp

-- A.encode $ Request Subscribe (V.fromList [ChannelSubscription ChannelTicker (V.fromList ["BTC-USD"])]) Nothing
data Request = Request { _reqType :: ReqTyp, _reqChannels :: Vector ChannelSubscription, _reqAuth :: Maybe Auth } deriving (Show, Generic,Typeable)
instance Store Request

instance ToJSON Request where
  toJSON Request{..} =
    object $
      [ "type" .= _reqType
      , "channels" .= _reqChannels] ++
      (maybe [] (\x -> ["signature" .= (T.decodeUtf8 $ authSignature x)
                       ,"key" .= (T.decodeUtf8 $ authKey x)
                       ,"passphrase" .= (T.decodeUtf8 $ authPassphrase x)
                       ,"timestamp"  .=  (T.decodeUtf8 $ authTimestamp x)
                       ]) _reqAuth)

instance FromJSON Request where
  parseJSON = withObject "request" $ \o -> do 
        typ <- o .: "type"
        channels <- o .: "channels"
        sign <- o .:? "signature"
        key <- o .:? "key"
        pass <- o .:? "passphrase"
        time <- o .:? "timestamp"
        let enc = T.encodeUtf8 . fromJust
            auth = case all isJust [sign,key,pass,time] of
              True -> Just $ Auth (enc sign) (enc key) (enc pass) (enc time)
              False -> Nothing
        return $ Request typ channels auth     

data FeedError
    = FeedError
        { _errMessage  :: Text
        , _errOriginal :: Maybe Text
        , _errUserId   :: Maybe UserId
        }
    deriving (Show, Typeable, Generic)
instance Store FeedError

instance FromJSON FeedError where
    parseJSON = withObjectOfType "FeedError" "error" $ \o -> FeedError
        <$> o .: "message"
        <*> o .:? "original"
        <*> o .:? "user_id"

data Heartbeat
    = Heartbeat
        { _beatSequence    :: Sequence
        , _beatLastTradeId :: TradeId
        , _beatProductId   :: ProductId
        , _beatTime        :: UTCTime
        , _beatUserId      :: Maybe UserId
        }
    deriving (Show, Typeable, Generic)
instance Store Heartbeat

instance FromJSON Heartbeat where
    parseJSON = withObjectOfType "Heartbeat" "heartbeat" $ \o -> Heartbeat
        <$> o .: "sequence"
        <*> o .: "last_trade_id"
        <*> o .: "product_id"
        <*> o .: "time"
        <*> o .:? "user_id"

data Ticker
    = Ticker
        { _tickerTradeId       :: Maybe Sequence
        , _tickerProductId     :: ProductId
        , _tickerPrice         :: Double
        , _tickerOpen24Hours   :: Double
        , _tickerVolume24Hours :: Double
        , _tickerLow24Hours    :: Double
        , _tickerHigh24Hours   :: Double
        , _tickerVolume30Days  :: Double
        , _tickerBestBid       :: Double
        , _tickerBestAsk       :: Double
        , _tickerSide          :: Maybe Side
        , _tickerTime          :: Maybe UTCTime
        , _tickerLastSize      :: Maybe Double
        , _tickerUserId        :: Maybe UserId
        }
    deriving (Show, Typeable, Generic)
instance Store Ticker

instance FromJSON Ticker where
    parseJSON = withObjectOfType "Ticker" "ticker" $ \o -> Ticker
        <$> o .:? "trade_id"
        <*> o .: "product_id"
        <*> (o .: "price" >>= textRead)
        <*> (o .: "open_24h" >>= textRead)
        <*> (o .: "volume_24h" >>= textRead)
        <*> (o .: "low_24h" >>= textRead)
        <*> (o .: "high_24h" >>= textRead)
        <*> (o .: "volume_30d" >>= textRead)
        <*> (o .: "best_bid" >>= textRead)
        <*> (o .: "best_ask" >>= textRead)
        <*> o .:? "side"
        <*> o .:? "time"
        <*> (o .:? "last_size" >>= maybeTextRead)
        <*> o .:? "user_id"

data Snapshot
    = Snapshot
        { _l2snapProductId :: ProductId
        , _l2snapBids      :: Vector Level2Item
        , _l2snapAsks      :: Vector Level2Item
        , _l2snapUserId    :: Maybe UserId
        }
    deriving (Show, Typeable, Generic)
instance Store Snapshot

instance FromJSON Snapshot where
    parseJSON = withObjectOfType "Snapshot" "snapshot" $ \o -> Snapshot
        <$> o .: "product_id"
        <*> o .: "bids"
        <*> o .: "asks"
        <*> o .:? "user_id"

data Level2Item
    = Level2Item
        { _l2itemPrice :: {-# UNPACK #-} !Double
        , _l2itemSize  :: {-# UNPACK #-} !Double
        }
    deriving (Show, Eq, Typeable, Generic)
instance Store Level2Item

instance FromJSON Level2Item where
    parseJSON = withArray "Level2Item" $ \a -> Level2Item
        <$> (textRead (a V.! 0))
        <*> (textRead (a V.! 1))

data Level2Change
    = Level2Change
        { _l2bidSide  :: Side
        , _l2bidPrice :: {-# UNPACK #-} !Double
        , _l2bidSize  :: {-# UNPACK #-} !Double
        }
    deriving (Show, Typeable, Generic)
instance Store Level2Change

instance FromJSON Level2Change where
    parseJSON = withArray "Level2Change" $ \a -> Level2Change
        <$> parseJSON (a V.! 0)
        <*> (textRead (a V.! 1))
        <*> (textRead (a V.! 2))

data L2Update
    = L2Update
        { _l2updateProductId :: ProductId
        , _l2updateChanges   :: Vector Level2Change
        , _l2updateUserId    :: Maybe UserId
        }
    deriving (Show, Typeable, Generic)
instance Store L2Update

instance FromJSON L2Update where
    parseJSON = withObjectOfType "L2Update" "l2update" $ \o -> L2Update
        <$> o .: "product_id"
        <*> o .: "changes"
        <*> o .:? "user_id"

{--
taker_user_id: "5844eceecf7e803e259d0365",
user_id: "5844eceecf7e803e259d0365",
taker_profile_id: "765d1549-9660-4be2-97d4-fa2d65fa3352",
profile_id: "765d1549-9660-4be2-97d4-fa2d65fa3352"
--}

data Match
    = Match
        { _matchTradeId      :: TradeId
        , _matchUserId       :: Maybe UserId
        , _matchTakerUserId  :: Maybe UserId
        , _matchTakerProfileId :: Maybe ProfileId
        , _matchProfileId    :: Maybe ProfileId
        , _matchTime         :: Maybe UTCTime
        , _matchMakerOrderId :: UUID
        , _matchTakerOrderId :: UUID
        , _matchProductId    :: ProductId
        , _matchSequence     :: Sequence
        , _matchSide         :: Side
        , _matchSize         :: Double
        , _matchPrice        :: Double
        }
    deriving (Show, Typeable, Generic)
instance Store Match

instance FromJSON Match where
    parseJSON = withObject "Match" $ \o -> do
        t <- o .: "type"
        case t of
            "last_match" -> process o
            "match" -> process o
            _ -> fail $ T.unpack $ "Expected type 'subscribe' got '" <> t <> "'."
        where
            process o = Match
                <$> o .: "trade_id"
                <*> o .:? "user_id"
                <*> o .:? "taker_user_id"
                <*> o .:? "taker_profile_id"
                <*> o .:? "profile_id"
                <*> o .:? "time"
                <*> o .: "maker_order_id"
                <*> o .: "taker_order_id"
                <*> o .: "product_id"
                <*> o .: "sequence"
                <*> o .: "side"
                <*> (o .: "size" >>= textRead)
                <*> (o .: "price" >>= textRead)

-- Full Book Messages

data Received
    = ReceivedLimit
        { _receivedTime      :: UTCTime
        , _receivedUserId    :: Maybe UserId
        , _receivedProductId :: ProductId
        , _receivedSequence  :: Sequence
        , _receivedOrderId   :: OrderId
        , _receivedSize      :: Double
        , _receivedPrice     :: Double
        , _receivedSide      :: Side
        }
    | ReceivedMarket
        { _receivedTime      :: UTCTime
        , _receivedUserId    :: Maybe UserId
        , _receivedProductId :: ProductId
        , _receivedSequence  :: Sequence
        , _receivedOrderId   :: OrderId
        , _receivedFunds     :: Double
        , _receivedSide      :: Side
        }
    deriving (Show, Typeable, Generic)
instance Store Received

instance FromJSON Received where
    parseJSON = withObjectOfType "Received" "received" $ \o -> do
        t <- o .: "order_type"
        case t of
            OrderLimit -> ReceivedLimit
                <$> o .: "time"
                <*> o .:? "user_id"
                <*> o .: "product_id"
                <*> o .: "sequence"
                <*> o .: "order_id"
                <*> (o .: "size" >>= textRead)
                <*> (o .: "price" >>= textRead)
                <*> o .: "side"
            OrderMarket -> ReceivedMarket
                <$> o .: "time"
                <*> o .:? "user_id"
                <*> o .: "product_id"
                <*> o .: "sequence"
                <*> o .: "order_id"
                <*> (o .: "funds" >>= textRead)
                <*> o .: "side"

data Reason
    = ReasonFilled
    | ReasonCanceled
    deriving (Eq, Ord, Typeable, Generic)
instance Store Reason

instance Show Reason where
    show ReasonFilled   = "filled"
    show ReasonCanceled = "canceled"

instance FromJSON Reason where
    parseJSON = withText "Reason" $ \t ->
        case t of
            "filled"   -> pure ReasonFilled
            "canceled" -> pure ReasonCanceled
            _          -> fail $ T.unpack $ "'" <> t <> "' is not a valid reason."

data Open
    = Open
        { _openTime          :: UTCTime
        , _openProductId     :: ProductId
        , _openOrderId       :: OrderId
        , _openSequence      :: Sequence
        , _openPrice         :: Double
        , _openRemainingSize :: Double
        , _openSide          :: Side
        , _openUserId        :: Maybe UserId
        }
    deriving (Show, Typeable, Generic)
instance Store Open

instance FromJSON Open where
    parseJSON = withObjectOfType "Open" "open" $ \o -> Open
        <$> o .: "time"
        <*> o .: "product_id"
        <*> o .: "order_id"
        <*> o .: "sequence"
        <*> (o .: "price" >>= textRead)
        <*> (o .: "remaining_size" >>= textRead)
        <*> o .: "side"
        <*> o .:? "user_id"

data Done
    = Done
        { _doneTime          :: UTCTime
        , _doneProductId     :: ProductId
        , _doneSequence      :: Sequence
        , _donePrice         :: Maybe Double
        , _doneOrderId       :: OrderId
        , _doneReason        :: Reason
        , _doneSide          :: Side
        , _doneRemainingSize :: Double
        , _doneUserId        :: Maybe UserId
        }
    deriving (Show, Typeable, Generic)
instance Store Done

instance FromJSON Done where
    parseJSON = withObjectOfType "Done" "done" $ \o -> Done
        <$> o .: "time"
        <*> o .: "product_id"
        <*> o .: "sequence"
        <*> (o .:? "price" >>= maybeTextRead)
        <*> o .: "order_id"
        <*> o .: "reason"
        <*> o .: "side"
        <*> (o .: "remaining_size" >>= textRead)
        <*> o .:? "user_id"

-- Match implemented previously

data Change
    = ChangeSize
        { _changeTime      :: UTCTime
        , _changeSequence  :: Sequence
        , _changeOrderId   :: OrderId
        , _changeProductId :: ProductId
        , _changeNewSize   :: Double
        , _changeOldSize   :: Double
        , _changePrice     :: Double
        , _changeSide       :: Side
        , _changeUserId    :: Maybe UserId
        }
    | ChangeFunds
        { _changeTime      :: UTCTime
        , _changeSequence  :: Sequence
        , _changeOrderId   :: OrderId
        , _changeProductId :: ProductId
        , _changeNewFunds  :: Double
        , _changeOldFunds  :: Double
        , _changePrice     :: Double
        , _changeSide       :: Side
        , _changeUserId    :: Maybe UserId
        }
    deriving (Show, Typeable, Generic)
instance Store Change

instance FromJSON Change where
    parseJSON = withObjectOfType "Change" "change" $ \o -> do
        fund <- o .:? "new_funds"
        case (fund :: Maybe Double) of
            Nothing -> ChangeSize
                <$> o .: "time"
                <*> o .: "sequence"
                <*> o .: "order_id"
                <*> o .: "product_id"
                <*> o .: "new_size"
                <*> o .: "old_size"
                <*> o .: "price"
                <*> o .: "side"
                <*> o .:? "user_id"

            Just _ -> ChangeFunds
                <$> o .: "time"
                <*> o .: "sequence"
                <*> o .: "order_id"
                <*> o .: "product_id"
                <*> o .: "new_funds"
                <*> o .: "old_funds"
                <*> o .: "price"
                <*> o .: "side"
                <*> o .:? "user_id"

data MarginProfileUpdate
    = MarginProfileUpdate
        { _mpuProductId          :: ProductId
        , _mpuTime               :: UTCTime
        , _mpuUserId             :: UserId
        , _mpuProfileId          :: ProfileId
        , _mpuNonce              :: Int
        , _mpuPosition           :: Text
        , _mpuPositionSize       :: Double
        , _mpuPositionCompliment :: Double
        , _mpuPositionMaxSize    :: Double
        , _mpuCallSide           :: Side
        , _mpuCallPrice          :: Double
        , _mpuCallSize           :: Double
        , _mpuCallFunds          :: Double
        , _mpuCovered            :: Bool
        , _mpuNextExpireTime     :: UTCTime
        , _mpuBaseBalance        :: Double
        , _mpuBaseFunding        :: Double
        , _mpuQuoteBalance       :: Double
        , _mpuQuoteFunding       :: Double
        , _mpuPrivate            :: Bool
        }
    deriving (Show, Typeable, Generic)

instance FromJSON MarginProfileUpdate where
    parseJSON = withObjectOfType "MarginProfileUpdate" "margin_profile_update" $ \o -> MarginProfileUpdate
        <$> o .: "product_id"
        <*> o .: "timestamp"
        <*> o .: "user_id"
        <*> o .: "profile_id"
        <*> o .: "nonce"
        <*> o .: "position"
        <*> (o .: "position_size" >>= textRead)
        <*> (o .: "position_compliement" >>= textRead)
        <*> (o .: "position_max_size" >>= textRead)
        <*> o .: "call_side"
        <*> (o .: "call_price" >>= textRead)
        <*> (o .: "call_size" >>= textRead)
        <*> (o .: "call_funds" >>= textRead)
        <*> o .: "covered"
        <*> o .: "next_expire_time"
        <*> (o .: "base_balance" >>= textRead)
        <*> (o .: "base_funding" >>= textRead)
        <*> (o .: "quote_balance" >>= textRead)
        <*> (o .: "quote_funding" >>= textRead)
        <*> o .: "private"
instance Store MarginProfileUpdate

data Activate
    = Activate
        { _activateProductId    :: ProductId
        , _activateTime         :: UTCTime
        , _activateUserId       :: UserId
        , _activateProfileId    :: ProfileId
        , _activateOrderId      :: OrderId
        , _activateStopType     :: StopType
        , _activateSide         :: Side
        , _activateStopPrice    :: Double
        , _activateSize         :: Double
        , _activateFunds        :: Double
        , _activateTakerFeeRate :: Double
        , _activatePrivate      :: Bool
        }
    deriving (Show, Typeable, Generic)
instance Store Activate

instance FromJSON Activate where
    parseJSON = withObjectOfType "Activate" "activate" $ \o -> Activate
        <$> o .: "product_id"
        <*> o .: "time"
        <*> o .: "user_id"
        <*> o .: "profile_id"
        <*> o .: "order_id"
        <*> o .: "stop_type"
        <*> o .: "side"
        <*> (o .: "stop_price" >>= textRead)
        <*> (o .: "size" >>= textRead)
        <*> (o .: "funds" >>= textRead)
        <*> (o .: "taker_fee_rate" >>= textRead)
        <*> o .: "private"

-- Sum Type

data GdaxMessage
    = GdaxSubscriptions Subscriptions
    | GdaxHeartbeat Heartbeat
    | GdaxTicker Ticker
    | GdaxSnapshot Snapshot
    | GdaxL2Update L2Update
    | GdaxMatch Match
    | GdaxReceived Received
    | GdaxOpen Open
    | GdaxDone Done
    | GdaxChange Change
    | GdaxMarginProfileUpdate MarginProfileUpdate
    | GdaxActivate Activate
    | GdaxFeedError FeedError
    deriving (Show, Typeable, Generic)
instance Store GdaxMessage

instance FromJSON GdaxMessage where
    parseJSON = withObject "GdaxMessage" $ \o -> do
        t <- o .: "type"
        case t of
            "l2update" -> GdaxL2Update <$> parseJSON (Object o)
            "ticker" -> GdaxTicker <$> parseJSON (Object o)
            "heartbeat" -> GdaxHeartbeat <$> parseJSON (Object o)
            "last_match" -> GdaxMatch <$> parseJSON (Object o)
            "match" -> GdaxMatch <$> parseJSON (Object o)
            "received" -> GdaxReceived <$> parseJSON (Object o)
            "open" -> GdaxOpen <$> parseJSON (Object o)
            "done" -> GdaxDone <$> parseJSON (Object o)
            "change" -> GdaxChange <$> parseJSON (Object o)
            "margin_profile_update" -> GdaxMarginProfileUpdate <$> parseJSON (Object o)
            "activate" -> GdaxActivate <$> parseJSON (Object o)
            "error" -> GdaxFeedError <$> parseJSON (Object o)
            "subscriptions" -> GdaxSubscriptions <$> parseJSON (Object o)
            "snapshot" -> GdaxSnapshot <$> parseJSON (Object o)
            _ -> fail $ T.unpack $ "Message of unsupported type '" <> t <> "'."

-- Type to parse order book - order book is built from snapshots and updates - it doesn't have time which we will need to guess from trades for now. Need to add line time in UTC for order book capture
data ObookState = OUpd | OInit | OInvalid deriving (Show, Generic,Typeable)

data Obook = Obook { _obook_timestamp :: UTCTime, _obook_ticker :: ProductId, _obook_seqnum :: Sequence, _obook_bids :: [(Double,Double)], _obook_asks :: [(Double,Double)] } deriving  (Show, Generic,Typeable)
deriveJSON defaultOptions{fieldLabelModifier = Prelude.drop 7,constructorTagModifier = camelTo2 '_',omitNothingFields = True} ''Obook
instance Store Obook

-- This equality derivation is useful to determine if orderbook bids/asks have changed, and to publish order book
-- in case of change
instance Eq Obook where
  a == b = (_obook_ticker a == _obook_ticker b) && (_obook_bids a == _obook_bids b) &&(_obook_asks a == _obook_asks b)

-- Sum type for all the messages that we will use for market data subscribers
data PubMdataMsg = PubTicker Ticker | PubObook Obook deriving (Show,Generic,Typeable)
instance Store PubMdataMsg 
