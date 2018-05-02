{-# LANGUAGE OverloadedStrings #-}
module Feeds.Clients.Orderbook

where

import Data.ByteString.Lazy as BL hiding (foldl')
import Data.Maybe (fromJust,isJust)
import Data.Either (isRight,partitionEithers)
import Data.Text.Read (rational)
import Data.Text as T (Text)
import Feeds.Gdax.Types
import Data.Aeson as A (decode)
import Data.List (sortOn,sortBy,foldl')
import Data.Ord(Down(..),comparing)
import qualified Data.HashTable.IO as H
import qualified Data.Map.Strict as Map 
import Criterion.Main
import Streaming.Prelude as S (yield,uncons)
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

-- TODO: hashtable on time,seq,hmap - we update seq on upd, time on trade, hmap on upd or snap (new hmap)
-- Return Obook on snap or update
updateHTbl :: HashTable T.Text (Maybe T.Text) -> GdaxRsp -> IO ()
updateHTbl ht inp = do
  case inp of
    GdRTick t -> H.insert ht (_tick_product_id t) (_tick_time t) -- Set ticker time to last seen trade time
    GdRSnap s -> H.insert ht (_snp_product_id s) Nothing -- Reset ticker time to Nothing on snapshot
    GdRL2Up u -> return ()
    _         -> return ()

updObookH :: HashTable T.Text (Maybe T.Text) -> Stream (Of GdaxRsp) IO () -> Stream (Of Obook) IO ()
updObookH ht inpstr = do
  go inpstr
  where go inp = do
            r <- lift $ S.uncons inp
            case r of
              Nothing -> return ()
              Just (inp,rest) -> do
                -- First update the hashtable with last seen trade time for ticker
                lift $ updateHTbl ht inp
                -- TODO: Generate orderbook and yield -- change updateHtbl return to maybe Obook
                go rest
            
updObook :: Stream (Of GdaxRsp) IO () -> Stream (Of Obook) IO ()
updObook inpstr = do
  ht <-  lift (H.new :: IO (HashTable T.Text (Maybe T.Text)))
  updObookH ht inpstr

foo :: HashTable Float Float -> GdaxRsp -> Stream (Of [(Float,Float)]) IO ()
foo ht inp = do
  r <- liftIO $ do
    --ht <- H.new :: IO (HashTable Float Float)
    H.insert ht 1 1
    H.insert ht 2 2
    H.insert ht 3 3
    H.insert ht 4 4
    H.insert ht 5 5
    H.insert ht 6 6
    kvs <- H.toList ht
    print $ kvs
    let dropKeys = Prelude.map fst . Prelude.drop 5 . sortBy (comparing (Down . fst)) $ kvs -- use Down for ask
    _ <- mapM_ (H.delete ht) dropKeys
    H.toList ht
  S.yield r
    -- TODO - get toList of [k,v] - if greater than the size after every insertion, find maximum (ask) or minimum (bid) and delete it. Then, yield as streaming


-- Initialization: snapshot must exist before l2update when starting. Else error out, and ask for snapshot log - hint it is normally a log that starts with 1
-- 1. Update snapshot map with l2update. 
-- 2. Get the previous trade time and next trade time - set order book time to mid way
-- 3. Seq num lets us keep track of order book evolution given same time
-- 4. Reset seq num on date roll over

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

  -- TODO:
  -- need previous date (start with current date), previous seq num (start with 0), next trade time, previous trade time
  -- build a map of bids and asks per instrument - update the map on new entries - use hashtables
  -- filter on parsed values of bids and asks - take top n
  -- dig out Hashtables linear example
  -- Increment seq num, reset to 0 on date rollover vs previous date 
  return ()
  
