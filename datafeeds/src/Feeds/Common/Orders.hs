{-# LANGUAGE OverloadedStrings #-}

module Feeds.Common.Orders
where

import Network.HTTP.Types.Header(HeaderName(..))
import Network.HTTP.Simple 
import Crypto.Hash (HashAlgorithm, Digest)
import Crypto.MAC.HMAC (hmac, hmacGetDigest)
import Data.ByteArray.Encoding (convertToBase, convertFromBase, Base (Base64))
import qualified Data.ByteString as BS (ByteString,append,empty)
import qualified Data.Text as T (Text,pack,append)
import qualified Data.Text.Encoding as T (encodeUtf8,decodeUtf8)
import qualified Data.Aeson as A (decode)
import Crypto.Hash.Algorithms(SHA256)
import Data.List (foldl')
import System.Posix.Time (epochTime)
import qualified Data.ByteString.Char8 as BSC (pack,unpack)
import Data.Either (fromRight)
import Data.Maybe (fromJust,isJust)
import qualified Data.Configurator.Types as C (Value,Config)
import qualified Data.Configurator as C (load, Worth(..), lookup)
import Feeds.Common.Types (Environ(..))
import Feeds.Gdax.Types (GdaxAPIKeys(..),GdaxAuthReq(..),GdaxAccountResponse)
import Control.Exception.Safe (try,IOException)

sandBoxURL :: String
sandBoxURL = "https://api-public.sandbox.pro.coinbase.com"

accountReqPath :: BS.ByteString
accountReqPath = "/accounts"
--import Data.Time.Clock(addUTCTime,nominalDay) -- used for testing date rollover by faking date changes

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

testAccountInfo :: GdaxAPIKeys -> GdaxAuthReq -> IO Request
testAccountInfo (GdaxAPIKeys secret pass key) (GdaxAuthReq method url body) = do
          initreq <- parseRequest (BSC.unpack method ++ " " ++ sandBoxURL ++ BSC.unpack url)
          -- TODO - build timestamp and signed message - leave the body blank as GET for account
          time <- BSC.pack . show <$> epochTime 
          let msg = foldl' BS.append BS.empty [time,method,url,body]
              --key = fromRight BS.empty (convertFromBase Base64 secret) :: BS.ByteString
              signedMsg =  convertToBase Base64 (signMsg secret msg :: Digest SHA256)
              req = foldl' (\r (h,v) -> addRequestHeader h v r) initreq [(hcbkey,key),(hcbpassphrase,pass),(hcbtimestamp,time),(hcbsign,signedMsg),("Content-Type","application/json"),("Accept-Encoding","gzip, deflate"), ("Accept","*/*"), ("User-Agent","restclient")] 
          return req


-- Function to load configuration from a config file
loadCfg :: FilePath -> Environ -> IO (Either T.Text GdaxAPIKeys)
loadCfg fpath env = do
  cfg <- try $ C.load [C.Required fpath] :: IO (Either IOException C.Config)
  let kprefix = case env of
       Sandbox -> "sandbox"
       _ ->  "live"
  case cfg of
    Left e -> return . Left . T.pack . show $ e
    Right cfgv -> do -- Look up all the required keys and make sure we got them all
      secret <- C.lookup cfgv (T.append kprefix ".secret")
      pass <- C.lookup cfgv (T.append kprefix ".pass")
      key <- C.lookup cfgv (T.append kprefix ".key")
      if all isJust [secret,pass,key] then
        (-- Make sure we can do base64 decoding of the key. Otherwise error out
         case convertFromBase Base64 (fromJust secret) of
           Left e ->  return . Left . T.pack $ e
           Right decodedSecret -> return . Right $ GdaxAPIKeys decodedSecret (fromJust pass) (fromJust key))
        else return . Left $ "Some of the API keys were not found"

test :: FilePath -> IO ()
test fpath = do
    apiKeys <- loadCfg fpath Sandbox
    case apiKeys of 
      Right keys -> do
        --request <- testAccountInfo keys (GdaxAuthReq "GET" orderReqPath BS.empty)
        request <- testAccountInfo keys (GdaxAuthReq "GET" accountReqPath BS.empty)
        response <- httpLBS request
        case getResponseStatusCode response of
          200 -> do
            let rspBody = A.decode (getResponseBody response) :: Maybe [GdaxAccountResponse]
            print rspBody
          _ -> print "Message was rejected"
      Left _ -> return ()

-- TODO: 
-- get timestamp
-- get method, e.g. POST - must be all upper-case
-- get request path
-- get json body - could be no body in case of GET request

-- build message with timestamp, method,requestpath, body
-- decode secret key with base64
-- create hmac with the key
-- sign the message with hmac
-- base64 encode the message

-- create custom headers for REST:
-- CB-ACCESS-KEY The api key as a string.
-- CB-ACCESS-SIGN The base64-encoded signature (see Signing a Message).
-- CB-ACCESS-TIMESTAMP A timestamp for your request.
-- CB-ACCESS-PASSPHRASE The passphrase you specified when creating the API key.
-- Add json body as content-type "application/json"

-- Create typeclass for message signing - create union types GDAX, Gemini and Bitfinex. Leave undefined for non-GDAX

{--
var timestamp = Date.now() / 1000;
var requestPath = '/orders';

var body = JSON.stringify({
    price: '1.0',
    size: '1.0',
    side: 'buy',
    product_id: 'BTC-USD'
});

var method = 'POST';

// create the prehash string by concatenating required parts
var what = timestamp + method + requestPath + body;

// decode the base64 secret
var key = Buffer(secret, 'base64');

// create a sha256 hmac with the secret
var hmac = crypto.createHmac('sha256', key);

// sign the require message with the hmac
// and finally base64 encode the result
return hmac.update(what).digest('base64');
--}
