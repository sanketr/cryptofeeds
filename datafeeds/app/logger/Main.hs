module Main where

import Feeds.Clients.Internal as C (decodeGdaxLog)

main :: IO ()
main = decodeGdaxLog
