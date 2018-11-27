{-# LANGUAGE ForeignFunctionInterface, OverloadedStrings,ScopedTypeVariables,BangPatterns #-}
module Feeds.Clients.Internal
where

import qualified Data.ByteString.Streaming as SBS (fromHandle,toHandle,fromChunks,toChunks)
import qualified Data.ByteString.Internal as BS (ByteString(..))
import qualified Data.ByteString as BS (empty)
import qualified Data.ByteString.Lazy as LBS (ByteString,toStrict,fromStrict,append,empty)
import qualified Data.ByteString.Lazy.Char8 as LBSC (pack)
import Data.Maybe (isJust,fromJust)
import Streaming as S
import System.IO.ByteBuffer as BB (new,free,ByteBuffer) 
import Data.Store (Store)
import qualified Streaming.Prelude as S hiding (print,show)
import Data.IORef
import Control.Exception.Safe (bracket)
import Feeds.Common.Types (CompressedBlob(..))
import Feeds.Gdax.Types.MarketData (GdaxRsp)
import System.IO (stdin,stdout,Handle)
import qualified Data.Aeson as A (decode,encode)
import qualified Feeds.Gdax.Types.Feed as F (GdaxMessage(..))
import Data.Store.Streaming as B
import Codec.Compression.Zlib as Zl (compress,decompress)
import qualified Codec.Compression.Zstd.Streaming as Z

-- Compression streamer - uses Zstd compression
streamZstd :: (MonadIO m,Monad m) => IO Z.Result -> Stream (Of BS.ByteString) m () -> Stream (Of BS.ByteString) m ()
streamZstd pop inp = loop inp pop
  where
    loop bytes res = do
      bsinp <- liftIO res
      case bsinp of
        Z.Error who what -> error (who ++ ": " ++ what)
        Z.Done bs -> (lift . S.uncons $ bytes) >>= (maybe (S.yield bs) (\_ -> error "Compress/Decompress ended while input stream still had bytes"))
        Z.Produce bs npop -> S.yield bs >> loop bytes npop
        -- if we run out of input stream, call loop with empty stream, and compress function with empty ByteString
        -- to signal end - we should then be in Done state in next call to loop
        Z.Consume f -> (lift . S.uncons $ bytes) >>= (maybe (loop (return ()) (f BS.empty)) (\(bs,nbs) -> loop nbs (f bs)))

decompressZstd :: (MonadIO m,Monad m) => Stream (Of BS.ByteString) m () -> Stream (Of BS.ByteString) m ()
decompressZstd = streamZstd Z.decompress

compressZstd :: (MonadIO m,Monad m) => Int -> Stream (Of BS.ByteString) m () -> Stream (Of BS.ByteString) m ()
compressZstd level = streamZstd (Z.compress level)

compressLogZstd :: Int -> Handle -> Handle -> IO ()
compressLogZstd level inhdl outhdl = SBS.toHandle outhdl . SBS.fromChunks . compressZstd level .  SBS.toChunks . SBS.fromHandle $ inhdl

decompressLogZstd :: Handle -> Handle -> IO ()
decompressLogZstd inhdl outhdl = SBS.toHandle outhdl . SBS.fromChunks . decompressZstd .  SBS.toChunks . SBS.fromHandle $ inhdl


toSum :: Monad m 
      => Stream (Of (Either a b)) m r 
      -> Stream (Sum (Of a) (Of b)) m r
toSum = maps $ \(eitherBytes :> x) -> 
    case eitherBytes of
        Left bytes -> InL (bytes :> x)
        Right bytes -> InR (bytes :> x)

fromSum :: Monad m 
        => Stream (Sum (Of a) (Of b)) m r 
        -> Stream (Of (Either a b)) m r
fromSum = maps $ \eitherBytes ->
    case eitherBytes of
        InL (bytes :> x) -> Left bytes :> x
        InR (bytes :> x) -> Right bytes :> x

streamDecode :: Store a => ByteBuffer -> Stream (Of BS.ByteString) IO () -> Stream (Of a) IO ()
streamDecode bb inp = do
    ref <- lift $ newIORef inp 
    let popper = do
          r <- S.uncons =<< readIORef ref
          case r of
            Nothing -> return Nothing 
            Just (a,rest) -> writeIORef ref rest >> return (Just a)
    let go = do
          r <- lift $ decodeMessageBS bb $ popper
          --lift $ print "Decoding"
          case r of 
            Nothing -> return ()
            Just msg -> (S.yield . fromMessage $ msg) >> go
    go 

decompressMessage :: CompressedBlob -> BS.ByteString
decompressMessage (Compressed inp) = LBS.toStrict . Zl.decompress . LBS.fromStrict $ inp

compressMessage :: BS.ByteString -> CompressedBlob
compressMessage  = Compressed . LBS.toStrict . Zl.compress . LBS.fromStrict

-- Two-step decoding - first unwrap compressed blob, decompress, and then unwrap Gdax messages from the resulting bytes
-- Can't use yet with zstd compression because of some kind of bug in FFI which causes out-of-memory error. Will use with
-- zlib for now
streamDecodeCompressed :: (ByteBuffer,ByteBuffer) -> Stream (Of BS.ByteString) IO () -> Stream (Of GdaxRsp) IO ()
streamDecodeCompressed (bb1,bb2) = streamDecode bb1 . S.map decompressMessage . streamDecode bb2 

-- Function to decode binary encoded log - assumes it is uncompressed - reads input from stdin
decodeGdaxLogHv1 :: ByteBuffer -> Stream (Of GdaxRsp) IO ()
decodeGdaxLogHv1 bb = streamDecode bb . SBS.toChunks . SBS.fromHandle $ stdin

decodeGdaxLogH :: ByteBuffer -> Stream (Of F.GdaxMessage) IO ()
decodeGdaxLogH bb = streamDecode bb . SBS.toChunks . SBS.fromHandle $ stdin

-- TODO: Add a state machine for order book and trades
-- State machine: 
-- Initialization: snapshot must exist before l2update when starting. Else error out, and ask for snapshot log - hint it is normally a log that starts with 1
-- 1. Update snapshot map with l2update. 
-- 2. Get the previous trade time and next trade time - set order book time to mid way
-- 3. Seq num lets us keep track of order book evolution given same time
-- 4. Reset seq num on date roll over

-- Get trades from the log for now. Don't need other data
decodeGdaxLog :: IO ()
decodeGdaxLog = bracket
                  (BB.new Nothing)
                  BB.free
                  -- Convert to JSON format, add new line and redirect output to stdout
                  (SBS.toHandle stdout . SBS.fromChunks  . S.map (LBS.toStrict . LBS.append "\n" . getBytes ) . S.filter isTrade . decodeGdaxLogH)
            where
              isTrade msg = case msg of
                F.GdaxTicker _ -> True
                _              -> False

              getBytes msg = case msg of
                F.GdaxTicker tr -> LBSC.pack . show $ tr
                _               -> LBS.empty

decodeGdaxLogV1 :: IO ()
decodeGdaxLogV1 = bracket
                  (BB.new Nothing)
                  BB.free
                  (SBS.toHandle stdout . SBS.fromChunks  . S.map (LBS.toStrict . LBS.append "\n" . getBytes ) . S.filter isTrade . S.map fromJust . S.filter isJust . S.map ((A.decode:: LBS.ByteString -> Maybe F.GdaxMessage) . A.encode) . decodeGdaxLogHv1)
             where
              isTrade msg = case msg of
                F.GdaxTicker _ -> True
                _              -> False

              getBytes msg = case msg of
                F.GdaxTicker tr -> LBSC.pack . show $ tr
                _               -> LBS.empty


decodeGdaxCompressedLog :: IO ()
decodeGdaxCompressedLog = bracket
                            (BB.new Nothing)
                            BB.free
                            (\bb1 -> do
                                  bracket
                                    (BB.new Nothing)
                                    BB.free
                                    (\bb2 -> SBS.toHandle stdout . SBS.fromChunks  . S.map (LBS.toStrict . A.encode) . streamDecodeCompressed (bb1,bb2) . SBS.toChunks . SBS.fromHandle $ stdin))
                  
