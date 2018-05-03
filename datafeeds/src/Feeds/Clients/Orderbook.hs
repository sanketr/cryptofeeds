{-# LANGUAGE OverloadedStrings #-}
module Feeds.Clients.Orderbook

where

import Data.ByteString.Lazy as BL hiding (foldl')
import Data.Maybe (fromJust,isJust)
import Data.Either (isRight,partitionEithers)
import Data.Text.Read (rational)
import Data.Text as T (Text,empty,null,take)
import Feeds.Gdax.Types
import Data.Aeson as A (decode)
import Data.List (sortOn,sortBy,foldl')
import Data.Ord(Down(..),comparing)
import qualified Data.HashTable.IO as H
import qualified Data.Map.Strict as Map 
import Criterion.Main
import Streaming.Prelude as S (mapMaybeM)
import Streaming as S (Stream,Of,lift)
import Control.Monad.IO.Class (liftIO)

type HashTable k v = H.LinearHashTable k v

updMap :: (Ord k, Eq a, Num a)=> (Map.Map k a -> [(k,a)]) -> Int -> Map.Map k a -> [(k,a)] -> Map.Map k a
updMap sortFn bnd obook vals = foldl' (\dict (k,_) -> Map.delete k dict) res delKeys
    where res = foldl' (\dict (k,v) -> if v /=0 then Map.insert k v dict else Map.delete k dict) obook vals
          kl = sortFn res
          delKeys = Prelude.drop bnd kl 
{-#INLINE updMap #-}

updMapAsk :: (Ord k, Eq a, Num a)=>  Int -> Map.Map k a -> [(k,a)] -> Map.Map k a
updMapAsk = updMap Map.toAscList

updMapBid ::  (Ord k, Eq a, Num a)=>  Int -> Map.Map k a -> [(k,a)] -> Map.Map k a
updMapBid = updMap Map.toDescList

--  Time (Text), Seq (Int), bidMap, askMap - it is keyed by ticker in a hashtable - we use this to 
-- build orderbook 
data OMap = OMap !T.Text !Int !(Map.Map Float Float) !(Map.Map Float Float) deriving Show

-- Function to determine if the current time has same date as previous time - if not equal, True
-- else False. This is used to reset orderbook sequence number
-- Time from GDAX is like this in UTC: "2018-04-26T09:53:27.357000Z"
resetSeq :: T.Text -> T.Text -> Int -> Int
resetSeq ptime ntime pseq = case (T.null ptime || (T.take 10 ptime) == (T.take 10 ntime)) of
  -- retain the sequence as long as previous time is empty or current date = previous date. Don't want to reset on first update after snapshot when new time is not empty but previous time is empty
  True -> pseq 
  False -> 0

-- | Order book generation |
-- Initialization: snapshot must exist before l2update when starting. TODO: Error out if no snapshot, and ask for snapshot log - provide hint it is normally a log that starts with 1
-- 1. Update snapshot map with l2update. 
-- 2. Get the current trade time - set order book time to current trade time
-- 3. Seq num lets us keep track of order book evolution given same time
-- 4. Reset seq num on date roll over
-- Return Obook on snap or l2 update
updateHTbl :: HashTable T.Text OMap -> Int -> GdaxRsp -> IO (Maybe Obook)
updateHTbl ht sz inp = do
  case inp of
    -- Trades - Update time in OMap if OMap exists
    GdRTick t -> do
          let ticker = _tick_product_id t
              ntm = maybe T.empty id (_tick_time t)
          omap <- H.lookup ht ticker
          -- Replace old time with new time in OMap - evaluates to Just if OMap exists, reset sequence on date rollover
          let nomap = fmap (\(OMap otm oseq bmap amap) -> OMap ntm (resetSeq otm ntm oseq) bmap amap) omap  
          -- Update the OMap for ticker if it exists
          maybe (return ()) (H.insert ht ticker) nomap
          return Nothing 

    -- Snapshot - Update time to Empty in OMap, update maps, output new obook
    GdRSnap s -> do
          let ticker = _snp_product_id s
              -- GDAX level 2 is of depth 50
              bids50 = getBids 50 . _snp_bids $ s
              asks50 = getAsks 50 . _snp_asks $ s
              bidMap = Map.fromList bids50
              askMap = Map.fromList asks50
          omap <- H.lookup ht ticker
          -- if OMap exists, only keep seq information
          let nomap = maybe (OMap "" 0 bidMap askMap) (\(OMap _ oseq _ _) -> OMap "" (1 + oseq) bidMap askMap) omap
          H.insert ht ticker nomap
          -- output order book with empty time
          (return . Just $ Obook { _obook_timestamp = "", _obook_ticker = ticker, _obook_seqnum = (\(OMap _ cseq _ _) -> cseq) nomap, _obook_bids = (Prelude.take sz bids50), _obook_asks = (Prelude.take sz asks50)})

    -- L2 updates - Update seq, askmap, bidmap in OMap, output new obook
    GdRL2Up u -> do
          let ticker = _l2upd_product_id u
              (updasks,updbids) = (\(x,y) -> (getNumPairs x,getNumPairs y)) $ foldl' (\(alist,blist) (x,y,z) -> if x == "sell" then (((y,z)):alist,blist) else if x == "buy" then (alist, ((y,z)): blist) else (alist,blist)) ([],[]) $ _l2upd_changes $ u
          -- get current OMap
          --  - do nothing if OMap doesn't exist which is not a valid state btw - snapshots must always precede l2 updates
          --  - if OMap exists, update seq, maps, output new obook
          omap <- H.lookup ht ticker
          maybe 
            (return Nothing)  
            (\(OMap otm oseq bmap amap) -> do
                                    let nbmap = updMapBid 50 bmap updbids
                                        namap = updMapAsk 50 amap updasks
                                        nseq = oseq + 1 
                                        nomap = OMap otm nseq nbmap namap
                                        nbids = Prelude.take sz . Map.toDescList $ nbmap
                                        nasks = Prelude.take sz . Map.toAscList $ namap
                                    H.insert ht ticker nomap
                                    return . Just $ Obook { _obook_timestamp = otm, _obook_ticker = ticker, _obook_seqnum = nseq, _obook_bids = nbids, _obook_asks = nasks}) 
            omap

    _         -> return Nothing

updObookH :: HashTable T.Text OMap -> Int -> Stream (Of GdaxRsp) IO () -> Stream (Of Obook) IO ()
updObookH ht sz inpstr = S.mapMaybeM (updateHTbl ht sz) inpstr
              
updObook :: Int -> Stream (Of GdaxRsp) IO () -> Stream (Of Obook) IO ()
updObook sz inpstr = do
  ht <-  lift H.new
  updObookH ht sz inpstr

-- Function to parse pair of floats from text, and filter only the values that are valid
getNumPairs :: [(T.Text,T.Text)] -> [(Float,Float)]
getNumPairs = Prelude.map (\(Right x,Right y) -> (fst x,fst y)) . Prelude.filter (\x -> (isRight . fst $ x) && (isRight . snd $ x)) . Prelude.map (\(x,y) -> (rational x,rational y))

getSides :: ((Float,Float) -> (Float,Float) ->  Ordering) -> Int ->  [(T.Text,T.Text)] -> [(Float,Float)]
getSides sortFn cnt = Prelude.take cnt . sortBy sortFn .  getNumPairs 
{-# INLINE getSides #-}

getBids ::  Int ->  [(T.Text,T.Text)] -> [(Float,Float)]
getBids = getSides  (comparing (Down . fst))

getAsks ::  Int ->  [(T.Text,T.Text)] -> [(Float,Float)]
getAsks = getSides  (comparing fst)

main = do
  json <- BL.readFile "../../testdata/snapshot.json"
  updjson <- BL.readFile "../../testdata/l2update.json"
  let snap = fromJust (A.decode json :: Maybe Snapshot)
      (updasks,updbids) = (\(x,y) -> (getNumPairs x,getNumPairs y)) $ foldl' (\(alist,blist) (x,y,z) -> if x == "sell" then (((y,z)):alist,blist) else if x == "buy" then (alist, ((y,z)): blist) else (alist,blist)) ([],[]) $ _l2upd_changes $ fromJust (A.decode updjson :: Maybe L2Update)
      bids5 = getBids 5 . _snp_bids $ snap
      asks5 = getAsks 5 . _snp_asks $ snap
      bidMap = Map.fromList bids5
      askMap = Map.fromList asks5
  {--
  defaultMain [
      bgroup "orderbook update" [ bench "Top 5" $ whnf (updMap 5 askMap) updasks]
    ]
  --}
  print asks5
  print bids5
  print updasks
  print updbids
  print $ Map.toAscList $ updMapAsk 5 askMap updasks
  print $ Map.toDescList $ updMapBid 5 bidMap updbids
  return ()
  
