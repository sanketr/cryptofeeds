module Main
where

import Feeds.Clients.Internal as C (decodeGdaxLog,migrateGdaxLog)

main :: IO ()
-- main = decodeGdaxLog
main = migrateGdaxLog
