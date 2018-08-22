{-# LANGUAGE OverloadedStrings,DeriveGeneric #-}

module Feeds.Gdax.Core
(
GdaxAuthReq(..),
liveURL,
sandboxURL,
liveWsURL,
sandboxWsURL,
signedGdaxReq,
genWsAuthMsg,
loadCfg,
ExchCfg(..),
listAccounts,
getAccount,
getAccountHistory,
getAccountHolds,
placeOrder,
placeLimitOrder,
placeMarketOrder,
placeStopOrder,
cancelOrder,
cancelAllOrders,
getOrder,
listOrders,
listFills
)
where

import Network.HTTP.Types.Header(HeaderName)
import Network.HTTP.Simple 
import Network.HTTP.Client (RequestBody(..),setQueryString,Request(..))
import Crypto.Hash (HashAlgorithm, Digest)
import Crypto.MAC.HMAC (hmac, hmacGetDigest)
import Data.ByteArray.Encoding (convertToBase, convertFromBase, Base (Base64))
import qualified Data.ByteString as BS (ByteString,append,concat,empty)
import qualified Data.ByteString.Lazy as LBS (ByteString,toStrict)
import qualified Data.Text as T (Text,pack,append)
import qualified Data.Vector as V (Vector)
import qualified Data.Text.Encoding as T (encodeUtf8,decodeUtf8)
import qualified Data.Aeson as A (decode,encode,FromJSON)
import Crypto.Hash.Algorithms(SHA256)
import Data.List (foldl')
import Data.Set  (Set)
import qualified Data.Set as Set
import Data.Monoid ((<>))
import System.Posix.Time (epochTime)
import qualified Data.ByteString.Char8 as BSC (pack,unpack)
import Data.Maybe (fromJust,isJust)
import qualified Data.Configurator.Types as C (Config)
import qualified Data.Configurator as C (load, Worth(..), lookup)
import Feeds.Common.Types (Environ(..))
import Feeds.Gdax.Types.Private
import Feeds.Gdax.Types.Shared
import Feeds.Common.Types (ExchCfg(..),RestMethod(..),Endpoint)
import qualified Feeds.Gdax.Types.Feed as F (Request(..))
import Control.Exception.Safe (try,IOException,MonadThrow)
import GHC.Generics
import Data.Typeable
import Data.UUID(toASCIIBytes)

-- Gdax Auth Req Method Type (all upper case), URL, Json Body
data GdaxAuthReq = GdaxAuthReq RestMethod BS.ByteString BS.ByteString deriving (Show, Generic,Typeable)

liveURL :: Endpoint
liveURL = "https://api.pro.coinbase.com"

sandboxURL :: Endpoint
sandboxURL = "https://api-public.sandbox.pro.coinbase.com"

liveWsURL :: Endpoint
liveWsURL = "ws-feed.pro.coinbase.com"

sandboxWsURL :: Endpoint
sandboxWsURL = "ws-feed-public.sandbox.pro.coinbase.com"

signMsg :: (HashAlgorithm a) => BS.ByteString -> BS.ByteString -> Digest a
signMsg key = hmacGetDigest . hmac key

-- GDAX specific headers for authentication
hcbkey :: HeaderName
hcbkey = "CB-ACCESS-KEY"

hcbsign :: HeaderName
hcbsign = "CB-ACCESS-SIGN"

hcbtimestamp :: HeaderName
hcbtimestamp = "CB-ACCESS-TIMESTAMP"

hcbpassphrase :: HeaderName
hcbpassphrase = "CB-ACCESS-PASSPHRASE"
-- End GDAX headers

-- Function to generation authentication information for Gdax given keys and request
genAuthMsg :: ExchCfg -> GdaxAuthReq -> IO Auth
genAuthMsg (ExchCfg _ _ secret pass key) (GdaxAuthReq rmethod relurl body) = do
          time <- BSC.pack . show <$> epochTime 
          let msg = foldl' BS.append BS.empty [time,BSC.pack . show $ rmethod,relurl,body]
              signedMsg =  convertToBase Base64 (signMsg secret msg :: Digest SHA256)
          return $ Auth signedMsg key pass time

genWsAuthMsg :: ExchCfg -> F.Request -> IO LBS.ByteString
genWsAuthMsg cfg req = do
          auth <- genAuthMsg cfg (GdaxAuthReq GET "/users/self/verify" BS.empty) -- From Gdax documentation for websocket request authentication - sign GET request to "/users/self" with no body
          -- Add authentication to request and create JSON bytes - this will be sent to websocket for authenticated request
          return . A.encode $ req { F._reqAuth = Just auth}

genRestAuthMsg :: ExchCfg -> GdaxAuthReq -> [(BS.ByteString, Maybe BS.ByteString)] -> IO Request
genRestAuthMsg cfg req params = do
          let resturl = (\(ExchCfg x _ _ _ _) -> x) cfg
              (rmethod,relurl,body) = (\(GdaxAuthReq x y z) -> (x,y,z)) req
          -- Set URI encoding if query params set, use it for signing the new relative URL
          initreq <- setQueryString params <$> parseRequest (show rmethod ++ " " ++ resturl ++ BSC.unpack relurl)
          -- Sign the generated HTTP request
          auth <- genAuthMsg cfg (GdaxAuthReq rmethod (BS.append (path initreq) (queryString initreq)) body)
          -- Add headers to the request - take care to specify url-encoding instead of json-encoding if params set
          let nreq = foldl' (\r (h,v) -> addRequestHeader h v r) initreq [(hcbkey,authKey auth),(hcbpassphrase,authPassphrase auth),(hcbtimestamp,authTimestamp auth),(hcbsign,authSignature auth),("Content-Type",if null params then "application/json" else "application/x-www-form-urlencoded"),("Accept-Encoding","gzip, deflate"), ("Accept","*/*"), ("User-Agent","restclient")] 
          return (setRequestBody (RequestBodyBS body) nreq)

-- Function to load configuration from a config file
loadCfg :: FilePath -> Environ -> IO (Either T.Text ExchCfg)
loadCfg fpath env = do
  cfg <- try $ C.load [C.Required fpath] :: IO (Either IOException C.Config)
  let (kprefix,resturl,wsurl) = case env of
       Sandbox -> ("sandbox",sandboxURL,sandboxWsURL)
       _ ->  ("live",liveURL,liveWsURL)
  case cfg of
    Left e -> return . Left . T.pack . show $ e
    Right cfgv -> do -- Look up all the required keys for respective env from the config file and make sure we got them all
      secret <- C.lookup cfgv (T.append kprefix ".secret")
      pass <- C.lookup cfgv (T.append kprefix ".pass")
      key <- C.lookup cfgv (T.append kprefix ".key")
      if all isJust [secret,pass,key] then
        (-- Make sure we can do base64 decoding of the encoded secret. Otherwise error out
        case convertFromBase Base64 (fromJust secret) of
          Left e ->  return . Left . T.pack $ e
          Right decodedSecret -> return . Right $ ExchCfg resturl wsurl decodedSecret (fromJust pass) (fromJust key))
        else return . Left $ "Some of the API keys were not found"

decodeResult :: (MonadThrow m, A.FromJSON a) => Response LBS.ByteString -> m (Either (Int,T.Text) a)
decodeResult res = let rbody = getResponseBody res in
    case A.decode rbody of
        Nothing  -> return . Left  $ (getResponseStatusCode res,T.decodeUtf8 . LBS.toStrict $ rbody)
        Just val -> return . Right $ val
{-# INLINE decodeResult #-}

-- Return signature is: Either (HTTP Status Code, Message) Data
signedGdaxReq ::  A.FromJSON a => ExchCfg -> GdaxAuthReq -> [(BS.ByteString, Maybe BS.ByteString)] -> IO (Either (Int,T.Text) a)
signedGdaxReq cfg req params = do
                  authReq <- genRestAuthMsg cfg req params
                  response <- httpLBS authReq
                  decodeResult response

listAccounts :: ExchCfg -> IO (Either (Int,T.Text) (V.Vector Account))
listAccounts cfg =  signedGdaxReq cfg (GdaxAuthReq GET "/accounts" BS.empty) []

getAccount :: ExchCfg -> AccountId -> IO (Either (Int,T.Text) Account)
getAccount cfg aid = signedGdaxReq cfg (GdaxAuthReq GET (BS.append "/accounts/"  (toASCIIBytes . unAccountId $ aid)) BS.empty) []

-- get numEntries latest entries through paginated querying by setting limit to numEntries and asking for first page (https://docs.gdax.com/?python#pagination)
getAccountHistory :: ExchCfg -> AccountId -> Int -> IO (Either (Int,T.Text) (V.Vector Entry))
getAccountHistory cfg aid numEntries =  signedGdaxReq cfg (GdaxAuthReq GET (BS.concat ["/accounts/",toASCIIBytes . unAccountId $ aid,"/ledger"]) BS.empty) [("before", Just "2"),("limit", Just . BSC.pack . show $ numEntries)]

getAccountHolds :: ExchCfg -> AccountId -> IO (Either (Int,T.Text) (V.Vector Hold))
getAccountHolds cfg aid = signedGdaxReq cfg (GdaxAuthReq GET (BS.concat ["/accounts/",toASCIIBytes . unAccountId $ aid,"/holds"]) BS.empty) []

placeOrder :: ExchCfg -> NewOrder -> IO (Either (Int,T.Text) Order)
placeOrder cfg no = signedGdaxReq cfg (GdaxAuthReq POST "/orders" (LBS.toStrict . A.encode $ no)) []

placeLimitOrder :: ExchCfg -> NewLimitOrder -> IO (Either (Int,T.Text)  Order)
placeLimitOrder cfg no = signedGdaxReq cfg (GdaxAuthReq POST "/orders" (LBS.toStrict . A.encode $ no)) []

placeMarketOrder :: ExchCfg -> NewMarketOrder -> IO (Either (Int,T.Text)  Order)
placeMarketOrder cfg no = signedGdaxReq cfg (GdaxAuthReq POST "/orders" (LBS.toStrict . A.encode $ no)) []

placeStopOrder ::  ExchCfg -> NewStopOrder -> IO (Either (Int,T.Text)  Order)
placeStopOrder cfg no = signedGdaxReq cfg (GdaxAuthReq POST "/orders" (LBS.toStrict . A.encode $ no)) []

-- Should return (404,"{\"message\":\"order not found\"}") in case the order is already done/canceled
cancelOrder :: ExchCfg -> OrderId -> IO (Either (Int,T.Text) (V.Vector OrderId))
cancelOrder cfg oid = signedGdaxReq cfg (GdaxAuthReq DELETE (BS.append "/orders/" (toASCIIBytes . unOrderId $ oid)) BS.empty) []

-- Should return empty vector when no orders to cancel
cancelAllOrders :: ExchCfg -> ProductId -> IO (Either (Int,T.Text) (V.Vector OrderId))
cancelAllOrders cfg pid =  signedGdaxReq cfg (GdaxAuthReq DELETE "/orders" BS.empty) [("product_id",Just . T.encodeUtf8 . unProductId $ pid)]

getOrder :: ExchCfg -> OrderId -> IO (Either (Int,T.Text) Order)
getOrder cfg oid = signedGdaxReq cfg (GdaxAuthReq GET (BS.append "/orders/"  (toASCIIBytes . unOrderId $ oid)) BS.empty) []

listOrders :: ExchCfg -> Set ProductId -> Set OrderStatus -> IO (Either (Int,T.Text) (V.Vector Order))
listOrders cfg pids oss = signedGdaxReq cfg (GdaxAuthReq GET "/orders" BS.empty) params
    where
        params = fmap (\p -> ("product_id", Just . T.encodeUtf8 . unProductId $ p)) (Set.toList pids)
            <> fmap (\s -> ("status", Just . BSC.pack .  show $ s)) (Set.toList oss)

listFills ::  ExchCfg -> Set OrderId -> Set ProductId -> IO (Either (Int,T.Text) (V.Vector Fill))
listFills cfg oids pids = signedGdaxReq cfg (GdaxAuthReq GET "/fills" BS.empty) params
    where
        params = fmap (\p -> ("product_id", Just . T.encodeUtf8 . unProductId $ p)) (Set.toList pids)
            <> fmap (\o -> ("order_id", Just . BSC.pack . show $ o)) (Set.toList oids)

{-- Not allowed anymore by GDAX - 403 forbidden status code
getPosition :: ExchCfg -> IO (Either (Int,T.Text) Position)
getPosition cfg = signedGdaxReq cfg (GdaxAuthReq GET "/position" BS.empty) []
--}
