{-# LANGUAGE ForeignFunctionInterface, OverloadedStrings,ScopedTypeVariables,BangPatterns #-}
module Feeds.Clients.Internal

where

import qualified Data.ByteString.Streaming as SBS (fromHandle,toHandle,fromChunks,toChunks)
import qualified Data.ByteString as BS (ByteString)
import qualified Data.ByteString.Lazy as LBS (toStrict)
import Streaming as S
import System.IO.ByteBuffer as BB (new,free,ByteBuffer) 
import Data.Store (Store)
import Data.Store.Streaming (decodeMessageBS, fromMessage)
import qualified Streaming.Prelude as S hiding (print,show)
import Data.IORef
import Control.Exception (bracket)
import Feeds.Gdax.Types (GdaxRsp)
import System.IO (Handle,stdin,stdout)
import qualified Data.Aeson as A (encode)


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



-- S.mapM_ Prelude.print . Streaming.Prelude.take 3 . Streaming.Prelude.drop 5 . (streamDecode bb :: Stream (Of BS.ByteString) IO () -> Stream (Of GdaxRsp) IO ()) . SBS.toChunks . SBS.fromHandle $ hdl

-- Function to decode binary encoded log - assumes it is uncompressed - reads input from stdin
decodeGdaxLogH :: ByteBuffer -> Stream (Of GdaxRsp) IO ()
decodeGdaxLogH bb = streamDecode bb . SBS.toChunks . SBS.fromHandle $ stdin

decodeGdaxLog :: IO ()
decodeGdaxLog = bracket
                  (BB.new Nothing)
                  BB.free
                  -- Convert to JSON format, and redirect output to stdout
                  (SBS.toHandle stdout . SBS.fromChunks  . S.map (LBS.toStrict . A.encode) . decodeGdaxLogH)
                  
