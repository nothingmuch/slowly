
import System.IO (print)
import System.Environment (getArgs)

import Network (withSocketsDo)
import Network.URI
import Network.HTTP ()
import Network.Browser

import Data.Maybe (fromMaybe)
import Network.URI

import Slowly.Collector

main = withSocketsDo $ getArgs >>= fetchUris

fetchUris uri_strings = do
    runWorkers fetchUri uris print
    where
        uris  = map parse uri_strings
        parse = fromMaybe (error "Nothing from url parse") . parseURI

-- this is the a sample "actor"
-- currently it fetches a single URI as fast as possible in an infinite loop
fetchUri chan uri = browse $ do
    setOutHandler ( const $ return () )
    fetchUri'
    where
        fetchUri' = do
            bnotify chan "sending request"
            request $ defaultGETRequest uri
            bnotify chan $ "got response"
            -- out (rspBody $ snd rsp)

-- boobies! with bling!
hotAction = (.)$(.) ioAction

-- sends a notification from a browser action
bnotify = hotAction notify
