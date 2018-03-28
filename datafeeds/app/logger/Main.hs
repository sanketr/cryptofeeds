module Main

import Feeds.Clients.Internal as C (decodeGdaxLog,decodeGdaxCompressedLog)

main :: IO ()
main = decodeGdaxCompressedLog
