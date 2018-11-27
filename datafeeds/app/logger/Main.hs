module Main
where

import Feeds.Clients.Internal as C (decodeGdaxLog,decodeGdaxLogV1)

main :: IO ()
--main = decodeGdaxLog
main = decodeGdaxLogV1
