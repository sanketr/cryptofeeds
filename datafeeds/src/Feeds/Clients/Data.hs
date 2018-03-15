{-# LANGUAGE OverloadedStrings,ScopedTypeVariables,BangPatterns #-}
module Feeds.Clients.Data
(
compress,
decompress,
eitherCompress,
toSum,
streamDecode
)
where

import qualified Data.ByteString as BS (ByteString,empty,length)
import System.IO.ByteBuffer (ByteBuffer)
import qualified System.IO.ByteBuffer as BB
import Data.Store.Streaming
import Data.Store (Store)
import Streaming.Prelude as S hiding (print,show)
import Data.IORef
import Streaming as S
import qualified Codec.Compression.Zstd.Streaming as Z
import Control.Exception (bracket)
import qualified Data.Aeson as A (ToJSON,encode)

-- Compression streamer - uses Zstd compression
streamZstd :: (MonadIO m,Monad m) => IO Z.Result -> Stream (Of BS.ByteString) m () -> Stream (Of BS.ByteString) m ()
streamZstd pop inp = loop inp pop
  where
    loop bytes res = do
      bs <- liftIO res
      case bs of
        Z.Error who what -> error (who ++ ": " ++ what)
        Z.Done bs -> (lift . S.uncons $ bytes) >>= (maybe (S.yield bs) (\_ -> error "Compress/Decompress ended while input stream still had bytes"))
        Z.Produce bs npop -> S.yield bs >> loop bytes npop
        -- if we run out of input stream, call loop with empty stream, and compress function with empty ByteString
        -- to signal end - we should then be in Done state in next call to loop
        Z.Consume f -> (lift . S.uncons $ bytes) >>= (maybe (loop (return ()) (f BS.empty)) (\(bs,nbs) -> loop nbs (f bs)))

decompress :: (MonadIO m,Monad m) => Stream (Of BS.ByteString) m () -> Stream (Of BS.ByteString) m ()
decompress = streamZstd Z.decompress

compress :: (MonadIO m,Monad m) => Int -> Stream (Of BS.ByteString) m () -> Stream (Of BS.ByteString) m ()
compress level = streamZstd (Z.compress level)

toSum :: Monad m 
      => Stream (Of (Either BS.ByteString BS.ByteString)) m r 
      -> Stream (Sum (Of BS.ByteString) (Of BS.ByteString)) m r
toSum = maps $ \(eitherBytes :> x) -> 
    case eitherBytes of
        Left bytes -> InL (bytes :> x)
        Right bytes -> InR (bytes :> x)

fromSum :: Monad m 
        => Stream (Sum (Of BS.ByteString) (Of BS.ByteString)) m r 
        -> Stream (Of (Either BS.ByteString BS.ByteString)) m r
fromSum = maps $ \eitherBytes ->
    case eitherBytes of
        InL (bytes :> x) -> Left bytes :> x
        InR (bytes :> x) -> Right bytes :> x

-- Function to operate on nested monad - no forall quantifier unlike hoist
transLift :: (Monad m, Monad (t m), MonadTrans t) => (m a -> m b) -> t m a -> t m b
transLift f tma = tma >>= lift . f . return

-- Function to compress both Either byte streams - doesn't work on inner stream yet - TODO: Fix
eitherCompress :: (MonadIO m,Monad m)
               => Int 
               -> Stream (Of (Either BS.ByteString BS.ByteString)) m () 
               -> Stream (Of (Either BS.ByteString BS.ByteString)) m ()
eitherCompress level =
     fromSum . unseparate . transLift (compress level) . compress level . separate . toSum


streamDecode :: forall a. (Store a) => ByteBuffer -> Stream (Of BS.ByteString) IO () -> Stream (Of a) IO ()
streamDecode bb inp = do
    ref <- lift $ newIORef inp 
    let popper = do
        r <- S.uncons =<< readIORef ref
        case r of
          Nothing -> return Nothing 
          Just (a,rest) -> writeIORef ref rest >> return (Just a)
    let go = do
          r <- lift $ decodeMessageBS bb $ popper
          lift $ print "Decoding"
          case r of 
            Nothing -> return ()
            Just msg -> (lift $ print "Message found") >> (S.yield . fromMessage $ msg) >> go
    go 
