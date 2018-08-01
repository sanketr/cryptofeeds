{-# LANGUAGE OverloadedStrings,DeriveGeneric #-}

module Feeds.Gdax.Core
(
GdaxAuthReq(..),
liveURL,
sandboxURL,
liveWsURL,
sandboxWsURL,
signMsg,
loadCfg
)
where

import Network.HTTP.Types.Header(HeaderName(..))
import Network.HTTP.Simple 
import Network.HTTP.Client (RequestBody(..))
import Crypto.Hash (HashAlgorithm, Digest)
import Crypto.MAC.HMAC (hmac, hmacGetDigest)
import Data.ByteArray.Encoding (convertToBase, convertFromBase, Base (Base64))
import qualified Data.ByteString as BS (ByteString,append,empty)
import qualified Data.ByteString.Lazy as LBS (ByteString,toStrict,fromStrict)
import qualified Data.Text as T (Text,pack,append)
import qualified Data.Text.Encoding as T (encodeUtf8,decodeUtf8)
import qualified Data.Aeson as A (decode,eitherDecode',encode,FromJSON)
import Crypto.Hash.Algorithms(SHA256)
import Data.List (foldl')
import System.Posix.Time (epochTime)
import qualified Data.ByteString.Char8 as BSC (pack,unpack)
import Data.Either (fromRight)
import Data.Maybe (fromJust,isJust)
import qualified Data.Configurator.Types as C (Value,Config)
import qualified Data.Configurator as C (load, Worth(..), lookup)
import Feeds.Common.Types (Environ(..))
import Feeds.Gdax.Types.Private
import Feeds.Gdax.Types.Shared
import Feeds.Common.Types (ExchCfg(..),RestMethod(..),Endpoint)
import qualified Feeds.Gdax.Types.Feed as F (Request(..),ReqTyp(..),ChannelSubscription(..),Channel(..))
import Control.Exception.Safe (try,IOException,MonadThrow,throwM)
import Feeds.Gdax.Exceptions
import GHC.Generics
import Data.Typeable

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


accountReqPath :: BS.ByteString
accountReqPath = "/accounts"

orderReqPath :: BS.ByteString
orderReqPath = "/orders"

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
genAuthMsg (ExchCfg _ _ secret pass key) (GdaxAuthReq method relurl body) = do
          time <- BSC.pack . show <$> epochTime 
          let msg = foldl' BS.append BS.empty [time,BSC.pack . show $ method,relurl,body]
              signedMsg =  convertToBase Base64 (signMsg secret msg :: Digest SHA256)
          return $ Auth signedMsg key pass time

genWsAuthMsg :: ExchCfg -> F.Request -> IO LBS.ByteString
genWsAuthMsg cfg req = do
          auth <- genAuthMsg cfg (GdaxAuthReq GET "/users/self/verify" BS.empty) -- From Gdax documentation for websocket request authentication - sign GET request to "/users/self" with no body
          -- Add authentication to request and create JSON bytes - this will be sent to websocket for authenticated request
          return . A.encode $ req { F._reqAuth = Just auth}

genRestAuthMsg :: ExchCfg -> GdaxAuthReq -> IO Request
genRestAuthMsg cfg req = do
          let resturl = (\(ExchCfg x _ _ _ _) -> x) cfg
              (method,relurl,body) = (\(GdaxAuthReq x y z) -> (x,y,z)) req
          initreq <- parseRequest (show method ++ " " ++ resturl ++ BSC.unpack relurl)
          auth <- genAuthMsg cfg req
          let req = foldl' (\r (h,v) -> addRequestHeader h v r) initreq [(hcbkey,authKey auth),(hcbpassphrase,authPassphrase auth),(hcbtimestamp,authTimestamp auth),(hcbsign,authSignature auth),("Content-Type","application/json"),("Accept-Encoding","gzip, deflate"), ("Accept","*/*"), ("User-Agent","restclient")] 
          return (setRequestBody (RequestBodyBS body) req)


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

decodeResult :: (MonadThrow m, A.FromJSON a) => Response LBS.ByteString -> m a
decodeResult res =
    case A.eitherDecode' (getResponseBody res) of
        Left err  -> throwM $ MalformedGdaxResponse (T.pack err)
        Right val -> return val
{-# INLINE decodeResult #-}

test :: FilePath -> IO ()
test fpath = do
    gdaxCfg <- loadCfg fpath Sandbox -- load sandbox configuration
    case gdaxCfg of 
      Right cfg -> do
        --request <- genRestAuthMsg cfg (GdaxAuthReq GET orderReqPath BS.empty)
        -- | This is how to build the json body for new limit order
        let limitOrder = NewLimitOrder Nothing Buy "LTC-USD" DecreaseOrCancel "83.09" "0.015" Nothing Nothing Nothing
            limitOrderJson = LBS.toStrict . A.encode $ limitOrder
        limitReq <- genRestAuthMsg cfg (GdaxAuthReq POST orderReqPath limitOrderJson)
        -- request <- genRestAuthMsg cfg (GdaxAuthReq GET accountReqPath BS.empty) -- this one gets the account information
        -- TODO: use withResponse for request processing (exception safe)
        response <- httpLBS limitReq
        case getResponseStatusCode response of
          200 -> do
            {--
            let rspBody = A.decode (getResponseBody response) :: Maybe [Account]
            print rspBody
            --}
            print (getResponseBody response)
          u -> print response >> (print $ "Message was rejected with status code " ++ show u)
      Left e -> print e

