{-# LANGUAGE DeriveDataTypeable         #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE TemplateHaskell            #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE ScopedTypeVariables        #-}

module Feeds.Gdax.Types.Private where

import           Data.Aeson
import           Data.Aeson.TH 
import           Data.Monoid
import           Data.Text                 (Text)
import qualified Data.Text                 as T
import           Data.Time
import           Data.Typeable
import           GHC.Generics
import           Feeds.Gdax.Types.Shared
import           Text.Read                 (readMaybe)
import           Data.Char (isSpace)
import           Data.Store

data Account
    = Account
        { _accountId        :: AccountId
        , _accountProfileId :: ProfileId
        , _accountCurrency  :: CurrencyId
        , _accountBalance   :: TextDouble
        , _accountAvailable :: TextDouble
        , _accountHold      :: TextDouble
        , _accountMargin    :: Maybe MarginAccount
        }
    deriving (Show, Typeable, Generic)
instance Store Account

data MarginAccount
    = MarginAccount
        { _maccountFundedAmount  :: TextDouble
        , _maccountDefaultAmount :: TextDouble
        }
    deriving (Show, Typeable, Generic)
instance Store MarginAccount

instance FromJSON Account where
    parseJSON = withObject "Account" $ \o -> do Account
        <$> o .: "id"
        <*> o .: "profile_id"
        <*> o .: "currency"
        <*> o .: "balance" 
        <*> o .: "available"
        <*> o .: "hold"
        <*> do enabled <- o .:? "margin_enabled"
               if enabled == (Just True)
                then (\a b -> Just $ MarginAccount a b)
                        <$> (o .: "funded_amount")
                        <*> (o .: "default_amount")
                else return Nothing

data EntryDetails
    = EntryDetails
        { _edetailsOrderId   :: Maybe OrderId
        , _edetailsTradeId   :: Maybe TradeId
        , _edetailsProductId :: Maybe ProductId
        }
    deriving (Show, Typeable, Generic)
deriveJSON defaultOptions{fieldLabelModifier = camelTo2 '_' . Prelude.drop 9,omitNothingFields = True} ''EntryDetails

data Entry
    = Entry
        { _entryId        :: EntryId
        , _entryType      :: EntryType
        , _entryCreatedAt :: UTCTime
        , _entryAmount    :: TextDouble
        , _entryBalance   :: TextDouble
        , _entryDetails   :: EntryDetails
        }
    deriving (Show, Typeable, Generic)
deriveJSON defaultOptions{fieldLabelModifier = camelTo2 '_' . Prelude.drop 6,omitNothingFields = True} ''Entry

data Hold
    = Hold
        { _holdId        :: HoldId
        , _holdAccountId :: Maybe AccountId
        , _holdCreatedAt :: UTCTime
        , _holdUpdatedAt :: Maybe UTCTime
        , _holdAmount    :: TextDouble
        , _holdReference :: HoldReference
        }
    deriving (Show, Typeable, Generic)

data HoldReference
    = HoldOrder OrderId
    | HoldTransfer TransferId
    deriving (Show, Typeable, Generic)

instance FromJSON Hold where
    parseJSON = withObject "Hold" $ \o -> Hold
        <$> o .: "id"
        <*> o .:? "account_id"
        <*> o .: "created_at"
        <*> o .:? "updated_at"
        <*> o .: "amount"
        <*> parseRef o
        where
            parseRef o = do
                t <- o .: "type"
                case t of
                    "order" -> HoldOrder <$> o .: "ref"
                    "transfer" -> HoldTransfer <$> o .: "ref"
                    _ -> fail $ T.unpack $ "'" <> t <> "' is not a valid type for hold orders."

data NewOrder
    = NewOrderLimit NewLimitOrder
    | NewOrderMarket NewMarketOrder
    | NewOrderStop NewStopOrder
    deriving (Show, Typeable, Generic)

instance ToJSON NewOrder where
    toJSON (NewOrderLimit o)  = toJSON o
    toJSON (NewOrderMarket o) = toJSON o
    toJSON (NewOrderStop o)   = toJSON o


data NewLimitOrder
    = NewLimitOrder
        { _nloClientOrderId       :: Maybe ClientOrderId
        , _nloSide                :: Side
        , _nloProductId           :: ProductId
        , _nloSelfTradePrevention :: SelfTradePolicy
        , _nloPrice               :: TextDouble
        , _nloSize                :: TextDouble
        , _nloTimeInForce         :: Maybe TimeInForce
        , _nloCancelAfter         :: Maybe CancelAfterPolicy
        , _nloPostOnly            :: Maybe Bool
        }
    deriving (Show, Typeable, Generic)

instance ToJSON NewLimitOrder where
    toJSON NewLimitOrder{..} = object .
        filter (\(_,x) -> Null /= x)
        $ [maybe ("",Null) (\x -> ("client_oid" .= x))  _nloClientOrderId
        ,"type" .= ("limit"::Text)
        , "side" .= _nloSide
        , "product_id" .= _nloProductId
        , "stp" .= _nloSelfTradePrevention
        , "price" .= _nloPrice
        , "size" .= _nloSize
        ,maybe ("",Null) (\x -> "time_in_force" .=  x) _nloTimeInForce
        ,maybe ("",Null) (\x -> "cancel_after" .= x) _nloCancelAfter
        -- by default, request will be to post in the order book (i.e., no market order) unless explicitly overridden
        ,maybe ("post_only",Bool True) (\x ->"post_only" .= x) _nloPostOnly]

data NewMarketOrder
    = NewMarketOrder
        { _nmoClientOrderId       :: Maybe ClientOrderId
        , _nmoSide                :: Side
        , _nmoProductId           :: ProductId
        , _nmoSelfTradePrevention :: SelfTradePolicy

        , _nmoMarketDesire        :: MarketDesire
        }
    deriving (Show, Typeable, Generic)

instance ToJSON NewMarketOrder where
    toJSON NewMarketOrder{..} = object $
        [ "client_oid" .= _nmoClientOrderId
        , "type" .= ("market"::Text)
        , "side" .= _nmoSide
        , "product_id" .= _nmoProductId
        , "stp" .= _nmoSelfTradePrevention
        ] <> case _nmoMarketDesire of
                (DesireSize s)  -> [ "size" .= s ]
                (DesireFunds f) -> [ "funds" .= f ]

data NewStopOrder
    = NewStopOrder
        { _nsoClientOrderId       :: Maybe ClientOrderId
        , _nsoSide                :: Side
        , _nsoProductId           :: ProductId
        , _nsoSelfTradePrevention :: SelfTradePolicy
        , _nsoPrice               :: TextDouble
        , _nsoMarketDesire        :: MarketDesire
        }
    deriving (Show, Typeable, Generic)

instance ToJSON NewStopOrder where
    toJSON NewStopOrder{..} = object $
        [ "client_oid" .= _nsoClientOrderId
        , "type" .= ("stop"::Text)
        , "side" .= _nsoSide
        , "product_id" .= _nsoProductId
        , "stp" .= _nsoSelfTradePrevention
        , "price" .= _nsoPrice
        ] <> case _nsoMarketDesire of
                (DesireSize s)  -> [ "size" .= s ]
                (DesireFunds f) -> [ "funds" .= f ]

data MarketDesire
    = DesireSize TextDouble -- ^ Desired amount in commodity (e.g. BTC)
    | DesireFunds TextDouble -- ^ Desired amount in quote currency (e.g. USD)
    deriving (Show, Typeable, Generic)

data TimeInForce
    = GoodTillCanceled
    | GoodTillTime
    | ImmediateOrCancel
    | FillOrKill
    deriving (Eq, Ord, Typeable, Generic)

instance Show TimeInForce where
    show GoodTillCanceled  = "GTC"
    show GoodTillTime      = "GTT"
    show ImmediateOrCancel = "IOC"
    show FillOrKill        = "FOK"

instance ToJSON TimeInForce where
    toJSON = String . T.pack . show

instance FromJSON TimeInForce where
    parseJSON = withText "TimeInForce" $ \t ->
        case t of
            "GTC" -> pure GoodTillCanceled
            "GTT" -> pure GoodTillTime
            "IOC" -> pure ImmediateOrCancel
            "FOK" -> pure FillOrKill
            _ -> fail $ T.unpack $ "'" <> t <> "' is not a valid time in force."

data SelfTradePolicy
    = DecreaseOrCancel
    | CancelOldest
    | CancelNewest
    | CancelBoth
    deriving (Eq, Ord, Typeable, Generic)

instance Show SelfTradePolicy where
    show DecreaseOrCancel = "dc"
    show CancelOldest     = "co"
    show CancelNewest     = "cn"
    show CancelBoth       = "cb"

instance ToJSON SelfTradePolicy where
    toJSON = String . T.pack . show

instance FromJSON SelfTradePolicy where
    parseJSON = withText "SelfTradePolicy" $ \t ->
        case t of
            "dc" -> pure DecreaseOrCancel
            "co" -> pure CancelOldest
            "cn" -> pure CancelNewest
            "cb" -> pure CancelBoth
            _ -> fail $ T.unpack $ "'" <> t <> "' is not a valid self trade policy."

data CancelAfterPolicy
    = CancelAfterMinutes Word
    | CancelAfterHours Word
    | CancelAfterDays Word
    deriving (Typeable, Generic)

instance Show CancelAfterPolicy where
    show (CancelAfterMinutes w) = show w <> " min"
    show (CancelAfterHours w)   = show w <> " hour"
    show (CancelAfterDays w)    = show w <> " day"

instance ToJSON CancelAfterPolicy where
    toJSON = String . T.pack . show

instance FromJSON CancelAfterPolicy where
    parseJSON = withText "CancelAfterPolicy" $ \t ->
        case T.split isSpace t of
            ([mv, mtag] :: [Text]) ->
                case readMaybe $ T.unpack mv of
                    Just v ->
                        case mtag of
                            "min" -> pure $ CancelAfterMinutes v
                            "hour" -> pure $ CancelAfterHours v
                            "day" -> pure $ CancelAfterDays v
                            _ -> fail $ T.unpack $ "'" <> mtag <> "' was not 'minutes', 'hours', or 'days'."
                    Nothing -> fail $ T.unpack $ "'" <> mv <> "' could not be parsed as a word."
            _ -> fail $ T.unpack $ "'" <> t <> "' did not match regex validation."


data NewOrderConfirmation
    = NewOrderConfirmation
        { _nocOrderId :: OrderId
        }
    deriving (Show, Typeable, Generic)

instance FromJSON NewOrderConfirmation where
    parseJSON = withObject "NewOrderConfirmation" $ \o -> NewOrderConfirmation
        <$> o .: "id"

data Order
    = Order
        { _orderId                  :: OrderId
        , _orderPrice               :: TextDouble
        , _orderSize                :: TextDouble
        , _orderProductId           :: ProductId
        , _orderSide                :: Side
        , _orderStp                 :: Maybe SelfTradePolicy
        , _orderType                :: OrderType
        , _orderTimeInForce         :: TimeInForce
        , _orderPostOnly            :: Bool
        , _orderCreatedAt           :: UTCTime
        , _orderFillFees            :: TextDouble
        , _orderFilledSize          :: TextDouble
        , _orderExecutedValue       :: TextDouble
        , _orderStatus              :: OrderStatus
        , _orderSettled             :: Bool
        , _orderRejectReason        :: Maybe Text
        }
    deriving (Show, Typeable, Generic)
deriveJSON defaultOptions{fieldLabelModifier = camelTo2 '_' . Prelude.drop 6,omitNothingFields = True} ''Order


data Fill
    = Fill
        { _fillTradeId   :: TradeId
        , _fillProductId :: ProductId
        , _fillPrice     :: TextDouble
        , _fillSize      :: TextDouble
        , _fillOrderId   :: OrderId
        , _fillCreatedAt :: UTCTime
        , _fillLiquidity :: Liquidity
        , _fillFee       :: TextDouble
        , _fillSettled   :: Bool
        , _fillSide      :: Side
        }
    deriving (Show, Typeable, Generic)
deriveJSON defaultOptions{fieldLabelModifier = camelTo2 '_' . Prelude.drop 5,omitNothingFields = True} ''Fill
