{-# LANGUAGE ExistentialQuantification #-}
module Feeds.Common.Broadcast(
 newBroadcast
 ,addListener
 ,delListener
 ,numListeners
 ,broadcast
 ,Broadcast
)
where

import Control.Concurrent.Async (mapConcurrently_)
import Control.Concurrent.MVar (MVar,readMVar,newMVar,modifyMVar_)
import Data.List (delete,elemIndex)

-- Eq constraint is needed to delete listeners from the list below
newtype Broadcast a = Broadcast { listeners :: MVar [a] }

addListener :: (Eq a) => Broadcast a -> a -> IO ()
addListener pub listener = modifyMVar_ (listeners pub) (\ll -> return $ maybe (listener:ll) (const ll) (elemIndex listener ll))
               
delListener :: (Eq a) => Broadcast a -> a -> IO ()
delListener pub listener = modifyMVar_ (listeners pub) (return . delete listener)
                
broadcast :: (b -> a -> IO ()) -> Broadcast a -> b -> IO ()
broadcast send pub msg = do
                ll <- readMVar (listeners pub)
                -- send message to each listener in parallel - broadcast will be canceled btw if any listener throws async exception
                mapConcurrently_ (send msg) ll

newBroadcast :: (Eq a) => IO (Broadcast a)
newBroadcast = Broadcast <$> newMVar [] 

numListeners :: (Eq a) => Broadcast a -> IO Int
numListeners pub = length <$> readMVar (listeners pub)



