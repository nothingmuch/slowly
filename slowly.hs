{-# OPTIONS_GHC -XScopedTypeVariables #-}

import System.IO (print)
import System.Environment (getArgs)
import Control.Concurrent
import Data.IORef
import Data.Time.Clock (getCurrentTime)

import Network (withSocketsDo)
import Network.URI
import Network.HTTP ()
import Network.Browser

import Network.Curl
import Network.Curl.Easy

import Data.Maybe (fromMaybe)
import Network.URI

import Slowly.Collector

main = withSocketsDo $ getArgs >>= fetchUrisCurl

fetchUrisCurl uris = runWorkers fetchUriCurl uris print

initHandlers handle = do
    -- this needs an event buffer because WriteFunction can't handle writes to Chans
    eventBuffer <- newIORef []
    -- instantiate a standard header parsing handler from Network.Curl
    -- (finalHeader, gatherHeader) <- newIncomingHeader
    setHandlers eventBuffer -- gatherHeader
    -- return (eventBuffer, finalHeader)
    return eventBuffer
    where
        setHandlers eventBuffer = do
            setHandler CurlWriteFunction  bodyHandler
            setHandler CurlHeaderFunction headerHandler
            where
                setHandler t = setopt handle . t . gatherOutput_
                -- defers an event with timing info. flushEvents will be used
                -- to send these events into the appropriate Chan later
                queueEvent event = do
                    time <- getCurrentTime
                    modifyIORef eventBuffer $ (:) (time, event)
                -- for the body we only care how much and how long it took, not
                -- about the actual body contents for now
                bodyHandler (_, bytes) = do
                    queueEvent $ "body output " ++ show bytes ++ " bytes"
                -- headerHandler wraps around the standard header accumilator
                -- with an event generation
                headerHandler cstr@(_, bytes) = do
                    queueEvent $ "header output " ++ show bytes ++ " bytes"
                    -- gatherHeader cstr

flushEvents chan ref = do
    events <- readIORef ref
    writeIORef ref []
    mapM_ (send chan) $ reverse events

-- run a GET request sending progress events to chan
runGetRequest chan curl url = do
    eventBuffer <- initHandlers curl
    setopt curl $ CurlURL url
    notify chan "sending request"
    rc <- perform curl -- FIXME check rc
    rspCode <- getResponseCode curl
    end <- getCurrentTime
    flushEvents chan eventBuffer
    -- (st,headers :: [(String, String)] ) <- finalHeader
    send chan (end, "got response " ++ show rspCode)

fetchUriCurl chan url = do
    curl <- initialize
    setopts curl [ CurlSSLVerifyPeer False -- don't attempt to validate the cert
                 , CurlSSLVerifyHost 1     -- more trusting (no actual cert validation)
                 , CurlNoSignal False      -- has to do with thread safety
                 ]
    requestLoop curl 0
    where requestLoop curl i = if (i > 10) then return () else do
            runGetRequest chan curl url
            threadDelay 10000
            requestLoop curl (i+1)


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
