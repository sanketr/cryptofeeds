module Main
where

import Feeds.Clients.Internal as C (decodeGdaxLog,decodeGdaxCompressedLog)

main :: IO ()
main = decodeGdaxCompressedLog
