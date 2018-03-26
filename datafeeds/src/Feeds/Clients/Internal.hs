{-# LANGUAGE ForeignFunctionInterface, OverloadedStrings,ScopedTypeVariables,BangPatterns #-}
module Feeds.Clients.Internal
where

import qualified Data.ByteString.Streaming as SBS (fromHandle,toHandle,fromChunks,toChunks)
import qualified Data.ByteString.Internal as BS (ByteString(..))
import qualified Data.ByteString.Lazy as LBS (toStrict,fromStrict)
import Streaming as S
import System.IO.ByteBuffer as BB (new,free,ByteBuffer) 
import Data.Store (Store)
import qualified Streaming.Prelude as S hiding (print,show)
import Data.IORef
import Control.Exception (bracket)
import Feeds.Gdax.Types (GdaxRsp,CompressedBlob(..))
import System.IO (stdin,stdout)
import qualified Data.Aeson as A (encode)

import Data.Store.Streaming as B
--import Codec.Compression.Zstd as Z
import Codec.Compression.Zlib as Z (decompress)

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
decompressMessage (Compressed inp) = LBS.toStrict . Z.decompress . LBS.fromStrict $ inp

-- Two-step decoding - first unwrap compressed blob, decompress, and then unwrap Gdax messages from the resulting bytes
-- Can't use yet with zstd compression because of some kind of bug in FFI which causes out-of-memory error. Will use with
-- zlib for now
streamDecodeCompressed :: (ByteBuffer,ByteBuffer) -> Stream (Of BS.ByteString) IO () -> Stream (Of GdaxRsp) IO ()
streamDecodeCompressed (bb1,bb2) = streamDecode bb1 . S.map decompressMessage . streamDecode bb2 

-- Function to decode binary encoded log - assumes it is uncompressed - reads input from stdin
decodeGdaxLogH :: ByteBuffer -> Stream (Of GdaxRsp) IO ()
decodeGdaxLogH bb = streamDecode bb . SBS.toChunks . SBS.fromHandle $ stdin

decodeGdaxLog :: IO ()
decodeGdaxLog = bracket
                  (BB.new Nothing)
                  BB.free
                  -- Convert to JSON format, and redirect output to stdout
                  (SBS.toHandle stdout . SBS.fromChunks  . S.map (LBS.toStrict . A.encode) . decodeGdaxLogH)

decodeGdaxCompressedLog :: IO ()
decodeGdaxCompressedLog = bracket
                            (BB.new Nothing)
                            BB.free
                            (\bb1 -> do
                                  bracket
                                    (BB.new Nothing)
                                    BB.free
                                    (\bb2 -> SBS.toHandle stdout . SBS.fromChunks  . S.map (LBS.toStrict . A.encode) . streamDecodeCompressed (bb1,bb2) . SBS.toChunks . SBS.fromHandle $ stdin))
                  
