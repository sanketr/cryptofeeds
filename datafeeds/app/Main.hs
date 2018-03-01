module Main where

import Feeds.Clients.Ws as C (client)

main :: IO ()
main = C.client
