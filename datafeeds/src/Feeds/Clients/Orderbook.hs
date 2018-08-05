module Feeds.Clients.Orderbook

where

--import Feeds.Gdax.Types.MarketData
import Feeds.Gdax.Types.Feed (GdaxMessage(..),Obook(..),Snapshot(..),L2Update(..),Ticker(..),Level2Item(..),Level2Change(..))
import Feeds.Gdax.Types.Shared (ProductId,Sequence(..),Side(..))
import Data.List (sortBy,foldl')
import Data.Ord(Down(..),comparing)
import qualified Data.HashTable.IO as H
import qualified Data.Map.Strict as Map 
import qualified Data.Vector as V (toList,map)
-- import Criterion.Main
import Streaming.Prelude as S (mapMaybeM)
import Streaming as S (Stream,Of,lift)
import Data.Time (UTCTime(..),Day(..))
import Data.Int (Int64)

type HashTable k v = H.LinearHashTable k v

-- | Function to keep an ascending/descending balanced tree map of bids/asks - sortFn specifies sorting order
--   and bnd sets bounds on map size (i.e., depth of bids/asks)
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

-- | Orderbook snapshot for a ticker: Time (Text), Seq (Int), bidMap, askMap - it is referenced by ticker 
-- in a parent hashtable - we use this to keep track of orderbook changes for any ticker
data OData = OData !UTCTime !Int64 !(Map.Map Double Double) !(Map.Map Double Double) deriving Show

-- Function to determine if the current time has same date as previous time - if not equal, True
-- else False. This is used to reset orderbook sequence number
-- Time from GDAX is like this in UTC: "2018-04-26T09:53:27.357000Z"
resetSeq :: UTCTime -> UTCTime -> Int64 -> Int64
  -- retain the sequence as long as previous time is empty or current date = previous date. Don't want to reset on first update after snapshot when new time is not empty but previous time is empty
resetSeq ptime ntime pseq = if ptime == missingTime || utctDay ptime == utctDay ntime then pseq else 0

-- Function to get orderbook given size bounds on order book, ticker name, and book data
getOBook :: Int -> ProductId -> OData -> Obook
getOBook sz ticker (OData ctm cseq cbmap camap) =  Obook { _obook_timestamp = ctm, _obook_ticker = ticker, _obook_seqnum = Sequence cseq , _obook_bids = Prelude.take sz . Map.toDescList $ cbmap, _obook_asks = Prelude.take sz . Map.toAscList $ camap } 

-- We use 2000.01.01 as the missing time in order book - borrowed from kdb convention of 2000.01.01 as stand-in for 0 date in trading
missingTime :: UTCTime
missingTime = UTCTime (ModifiedJulianDay 51544) 0

isSell :: Side -> Bool
isSell Sell = True
isSell Buy = False
-- | Order book generation |
-- Initialization: snapshot must exist before l2update when starting. TODO: Error out if no snapshot, and ask for snapshot log - provide hint it is normally a log that starts with 1
-- 1. Update snapshot map with l2update. 
-- 2. Get the current trade time - set order book time to current trade time
-- 3. Seq num lets us keep track of order book evolution given same time
-- 4. Reset seq num on date roll over
-- Return Obook on snap or l2 update
updateHTbl :: HashTable ProductId OData -> Int -> GdaxMessage -> IO (Maybe Obook)
updateHTbl ht sz inp = 
  case inp of
    -- Trades - Update time in OData if OData exists
    GdaxTicker tick -> do
          let ticker = _tickerProductId tick
              tradeTime = _tickerTime tick
          -- in case a ticker has stats-only update, it is not a trade, and time will be missing. Update only on trade
          maybe (return Nothing)
            (\ntm -> do
              odata <- H.lookup ht ticker
              -- If odata exists, add trade time, reset sequence on date rollover
              let nodata = fmap (\(OData otm oseq bmap amap) -> OData ntm (resetSeq otm ntm oseq) bmap amap) odata  
              -- Do nothing if order map doesn't exist
              maybe (return ()) (H.insert ht ticker) nodata
              return Nothing)
            tradeTime

    -- Snapshot - Update time to Empty in OData, update maps, output new obook
    GdaxSnapshot snap -> do
          let ticker = _l2snapProductId snap
              -- GDAX level 2 is of depth 50
              bidMap = Map.fromList . getBids 50 . V.toList . V.map (\x -> (_l2itemPrice x,_l2itemSize x)) . _l2snapBids $ snap
              askMap = Map.fromList . getAsks 50 . V.toList . V.map (\x -> (_l2itemPrice x,_l2itemSize x)) . _l2snapAsks $ snap
          odata <- H.lookup ht ticker
          -- if OData exists, only keep seq information
          let nodata = maybe (OData missingTime 0 bidMap askMap) (\(OData _ oseq _ _) -> OData missingTime (1 + oseq) bidMap askMap) odata
              nobook = getOBook sz ticker nodata -- get new order book
          H.insert ht ticker nodata
          -- output order book
          return . Just $ nobook

    -- L2 updates - Update seq, askmap, bidmap in OData, output new obook
    GdaxL2Update upd -> do
          let ticker = _l2updateProductId upd
              (updasks,updbids) = foldl' (\(alist,blist) (x,y,z) -> if isSell x then ((y,z):alist,blist) else (alist, (y,z): blist)) ([],[]) $ V.toList . V.map (\x -> (_l2bidSide x,_l2bidPrice x,_l2bidSize x)) . _l2updateChanges $ upd
          -- get current OData
          --  - do nothing if OData doesn't exist which is not a valid state btw - snapshots must always precede l2 updates
          --  - if OData exists, update seq, maps, output new obook if changed
          odata <- H.lookup ht ticker
          maybe 
            -- Do nothing if order map doesn't exist
            (return Nothing)  
            -- If order map exists, update bids/asks and seq
            (\(OData otm oseq bmap amap) -> do
                                    let nbmap = updMapBid 50 bmap updbids
                                        namap = updMapAsk 50 amap updasks
                                        nodata = OData otm (oseq + 1) nbmap namap -- new odata
                                        oobook = getOBook sz ticker (OData otm oseq bmap amap) -- old order book
                                        nobook = getOBook sz ticker nodata -- new order book
                                    H.insert ht ticker nodata
                                    -- Publish order book only if changed - some updates don't
                                    -- change L2
                                    return (if oobook == nobook then Nothing else Just nobook)) 
            odata

    _         -> return Nothing

updObookH :: HashTable ProductId OData -> Int -> Stream (Of GdaxMessage) IO () -> Stream (Of Obook) IO ()
updObookH ht sz = S.mapMaybeM (updateHTbl ht sz)
             
-- | Function to take Gdax data and generate Order book data. sz arg sets order book depth 
updObook :: Int -> Stream (Of GdaxMessage) IO () -> Stream (Of Obook) IO ()
updObook sz inpstr = do
  ht <-  lift H.new
  updObookH ht sz inpstr

getSides :: ((Double,Double) -> (Double,Double) ->  Ordering) -> Int ->  [(Double,Double)] -> [(Double,Double)]
getSides sortFn cnt = Prelude.take cnt . sortBy sortFn
{-# INLINE getSides #-}

getBids ::  Int ->  [(Double,Double)] -> [(Double,Double)]
getBids = getSides  (comparing (Down . fst))

getAsks ::  Int ->  [(Double,Double)] -> [(Double,Double)]
getAsks = getSides  (comparing fst)

{--
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
--}
  
