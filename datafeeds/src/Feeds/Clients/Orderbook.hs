{-# LANGUAGE OverloadedStrings #-}
module Feeds.Clients.Orderbook

where

import Data.ByteString.Lazy as BL
import Data.Maybe (fromJust,isJust)
import Data.Either (isRight,partitionEithers)
import Data.Text.Read (rational)
import Data.Text as T (Text)
import Feeds.Gdax.Types
import Data.Aeson as A (decode)
import Data.List (sortOn,sortBy)
import Data.Ord(Down(..),comparing)
import qualified Data.HashTable.IO as H

type HashTable k v = H.LinearHashTable k v

foo :: IO (HashTable Float Float)
foo = do
    ht <- H.new :: IO (HashTable Float Float)
    H.insert ht 1 1
    H.insert ht 2 2
    H.insert ht 3 3
    H.insert ht 4 4
    H.insert ht 5 5
    H.insert ht 6 6
    kvs <- H.toList ht
    print $ kvs
    let dropKeys = Prelude.map fst . Prelude.drop 5 . sortBy (comparing (Down . fst)) $ kvs -- use Down for ask
    mapM_ (H.delete ht) dropKeys
    return ht
    -- TODO - get toList of [k,v] - if greater than the size after every insertion, find maximum (ask) or minimum (bid) and delete it. Then, yield as streaming


-- Initialization: snapshot must exist before l2update when starting. Else error out, and ask for snapshot log - hint it is normally a log that starts with 1
-- 1. Update snapshot map with l2update. 
-- 2. Get the previous trade time and next trade time - set order book time to mid way
-- 3. Seq num lets us keep track of order book evolution given same time
-- 4. Reset seq num on date roll over

-- Function to parse pair of floats from text, and filter only the values that are valid
getNumPairs :: [(T.Text,T.Text)] -> [(Float,Float)]
getNumPairs = Prelude.map (\(Right x,Right y) -> (fst x,fst y)) . Prelude.filter (\x -> (isRight . fst $ x) && (isRight . snd $ x)) . Prelude.map (\(x,y) -> (rational x,rational y))

getSides :: ([(Float,Float)] -> [(Float,Float)]) -> Int ->  [(T.Text,T.Text)] -> [(Float,Float)]
getSides fn cnt = Prelude.take cnt . fn . sortOn fst .  getNumPairs 

main = do
  json <- BL.readFile "test.json"
  let snap = fromJust (A.decode json :: Maybe Snapshot)
      bids5 = getSides Prelude.reverse 5 . _snp_bids $ snap
      asks5 = getSides id 5 . _snp_asks $ snap
  print asks5
  print bids5
  -- TODO:
  -- need previous date (start with current date), previous seq num (start with 0), next trade time, previous trade time
  -- build a map of bids and asks per instrument - update the map on new entries - use hashtables
  -- filter on parsed values of bids and asks - take top n
  -- dig out Hashtables linear example
  -- Increment seq num, reset to 0 on date rollover vs previous date 
  return ()
  
