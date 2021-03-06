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
import           Text.Read                 (readMaybe)
import           Data.Char (isSpace)
import           Data.Store
import           Data.HashMap.Strict       (HashMap)
import           Feeds.Gdax.Types.Shared
import           Feeds.Common.Parsers

data Account
    = Account
        { _accountId        :: AccountId
        , _accountProfileId :: ProfileId
        , _accountCurrency  :: CurrencyId
        , _accountBalance   :: Double
        , _accountAvailable :: Double
        , _accountHold      :: Double
        , _accountMargin    :: Maybe MarginAccount
        }
    deriving (Show, Typeable, Generic)
instance Store Account

data MarginAccount
    = MarginAccount
        { _maccountFundedAmount  :: Double
        , _maccountDefaultAmount :: Double
        }
    deriving (Show, Typeable, Generic)
instance Store MarginAccount

instance FromJSON Account where
    parseJSON = withObject "Account" $ \o -> do Account
        <$> o .: "id"
        <*> o .: "profile_id"
        <*> o .: "currency"
        <*> (o .: "balance"  >>= textRead) 
        <*> (o .: "available"  >>= textRead)
        <*> (o .: "hold"  >>= textRead)
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
        , _entryAmount    :: Double
        , _entryBalance   :: Double
        , _entryDetails   :: EntryDetails
        }
    deriving (Show, Typeable, Generic)

instance FromJSON Entry where
    parseJSON = withObject "Entry" $ \o -> Entry
        <$> o .: "id"
        <*> o .: "type"
        <*> o .: "created_at"
        <*> (o .: "amount" >>= textRead)
        <*> (o .: "balance" >>= textRead)
        <*> o .: "details"

data Hold
    = Hold
        { _holdId        :: HoldId
        , _holdAccountId :: Maybe AccountId
        , _holdCreatedAt :: UTCTime
        , _holdUpdatedAt :: Maybe UTCTime
        , _holdAmount    :: Double
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
        <*> (o .: "amount"   >>= textRead)
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
        , _nloPrice               :: Double
        , _nloSize                :: Double
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
        , _nsoPrice               :: Double
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
    = DesireSize Double -- ^ Desired amount in commodity (e.g. BTC)
    | DesireFunds Double -- ^ Desired amount in quote currency (e.g. USD)
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
        , _orderPrice               :: Double
        , _orderSize                :: Double
        , _orderProductId           :: ProductId
        , _orderSide                :: Side
        , _orderStp                 :: Maybe SelfTradePolicy
        , _orderType                :: OrderType
        , _orderTimeInForce         :: TimeInForce
        , _orderPostOnly            :: Bool
        , _orderCreatedAt           :: UTCTime
        , _orderFillFees            :: Double
        , _orderFilledSize          :: Double
        , _orderExecutedValue       :: Double
        , _orderStatus              :: OrderStatus
        , _orderSettled             :: Bool
        , _orderRejectReason        :: Maybe Text
        }
    deriving (Show, Typeable, Generic)

instance FromJSON Order where
    parseJSON = withObject "Order" $ \o -> Order
        <$> o .: "id"
        <*> (o .: "price" >>= textRead)
        <*> (o .: "size" >>= textRead)
        <*> o .: "product_id"
        <*> o .: "side"
        <*> o .:? "stp"
        <*> o .: "type"
        <*> o .: "time_in_force"
        <*> o .: "post_only"
        <*> o .: "created_at"
        <*> (o .: "fill_fees" >>= textRead)
        <*> (o .: "filled_size" >>= textRead)
        <*> (o .: "executed_value" >>= textRead)
        <*> o .: "status"
        <*> o .: "settled"
        <*> o .:? "reject_reason"

data Fill
    = Fill
        { _fillTradeId   :: TradeId
        , _fillProductId :: ProductId
        , _fillPrice     :: Double
        , _fillSize      :: Double
        , _fillOrderId   :: OrderId
        , _fillCreatedAt :: UTCTime
        , _fillLiquidity :: Liquidity
        , _fillFee       :: Double
        , _fillSettled   :: Bool
        , _fillSide      :: Side
        }
    deriving (Show, Typeable, Generic)

instance FromJSON Fill where
    parseJSON = withObject "Fill" $ \o -> Fill
        <$> o .: "trade_id"
        <*> o .: "product_id"
        <*> (o .: "price" >>= textRead)
        <*> (o .: "size" >>= textRead)
        <*> o .: "order_id"
        <*> o .: "created_at"
        <*> o .: "liquidity"
        <*> (o .: "fee" >>= textRead)
        <*> o .: "settled"
        <*> o .: "side"

data Position
    = Position
        { _posStatus       :: PositionStatus
        , _posFunding      :: PositionFunding
        , _posAccounts     :: HashMap Text PositionAccount -- ^ Text should be CurrencyId, but it will have to be fixed later.
        , _posMarginCall   :: MarginCall
        , _posUserId       :: UserId
        , _posProfileId    :: ProfileId
        , _posPositionInfo :: PositionInfo
        , _posProductId    :: ProductId
        }
    deriving (Show, Typeable, Generic)

instance FromJSON Position where
    parseJSON = withObject "Position" $ \o -> Position
        <$> o .: "status"
        <*> o .: "funding"
        <*> o .: "accounts"
        <*> o .: "margin_call"
        <*> o .: "user_id"
        <*> o .: "profile_id"
        <*> o .: "position"
        <*> o .: "product_id"

data PositionFunding
    = PositionFunding
        { _posfunMaxFundingValue   :: Double
        , _posfunFundingValue      :: Double
        , _posfunOldestOutstanding :: OutstandingFunding
        }
    deriving (Show, Typeable, Generic)

instance FromJSON PositionFunding where
    parseJSON = withObject "PositionFunding" $ \o -> PositionFunding
        <$> o .: "max_funding_value"
        <*> o .: "funding_value"
        <*> o .: "oldest_outstanding"

data OutstandingFunding
    = OutstandingFunding
        { _ofunId        :: FundingId
        , _ofunOrderId   :: OrderId
        , _ofunCreatedAt :: UTCTime
        , _ofunCurrency  :: CurrencyId
        , _ofunAccountId :: AccountId
        , _ofunAmount    :: Double
        }
    deriving (Show, Typeable, Generic)

instance FromJSON OutstandingFunding where
    parseJSON = withObject "OutstandingFunding" $ \o -> OutstandingFunding
        <$> o .: "id"
        <*> o .: "order_id"
        <*> o .: "created_at"
        <*> o .: "currency"
        <*> o .: "account_id"
        <*> o .: "amount"

data PositionAccount
    = PositionAccount
        { _paccountId            :: AccountId
        , _paccountBalance       :: Double
        , _paccountHold          :: Double
        , _paccountFundedAmount  :: Double
        , _paccountDefaultAmount :: Double
        }
    deriving (Show, Typeable, Generic)

instance FromJSON PositionAccount where
    parseJSON = withObject "PositionAccount" $ \o -> PositionAccount
        <$> o .: "id"
        <*> o .: "balance"
        <*> o .: "hold"
        <*> o .: "funded_amount"
        <*> o .: "default_amount"

data MarginCall
    = MarginCall
        { _mcallActive :: Bool
        , _mcallPrice  :: Double
        , _mcallSide   :: Side
        , _mcallSize   :: Double
        , _mcallFunds  :: Double
        }
    deriving (Show, Typeable, Generic)

instance FromJSON MarginCall where
    parseJSON = withObject "MarginCall" $ \o -> MarginCall
        <$> o .: "active"
        <*> o .: "price"
        <*> o .: "side"
        <*> o .: "size"
        <*> o .: "funds"

data PositionInfo
    = PositionInfo
        { _pinfoType       :: PositionType
        , _pinfoSize       :: Double
        , _pinfoComplement :: Double
        , _pinfoMaxSize    :: Double
        }
    deriving (Show, Typeable, Generic)

instance FromJSON PositionInfo where
    parseJSON = withObject "PositionInfo" $ \o -> PositionInfo
        <$> o .: "type"
        <*> o .: "size"
        <*> o .: "complement"
        <*> o .: "max_size"

data Deposit
    = Deposit
        { _depositAmount        :: Double
        , _depositCurrency      :: CurrencyId
        , _depositPaymentMethod :: PaymentMethodId
        }
    deriving (Show, Typeable, Generic)

instance ToJSON Deposit where
    toJSON Deposit{..} = object
        [ "amount" .= _depositAmount
        , "currency" .= _depositCurrency
        , "payment_method_id" .= _depositPaymentMethod
        ]

data DepositReceipt
    = DepositReceipt
        { _dreceiptId       :: DepositId
        , _dreceiptAmount   :: Double
        , _dreceiptCurrency :: CurrencyId
        , _dreceiptPayoutAt :: UTCTime
        }
    deriving (Show, Typeable, Generic)

instance FromJSON DepositReceipt where
    parseJSON = withObject "DepositReceipt" $ \o -> DepositReceipt
        <$> o .: "id"
        <*> (o .: "amount" >>= textRead)
        <*> o .: "currency"
        <*> o .: "payout_at"
