{-# OPTIONS_GHC -XScopedTypeVariables #-}

import Data.Data

import Data.UUID
import System.Random

import System.IO (print)
import System.Environment (getArgs)
import Control.Concurrent
import Data.IORef
import Data.Time.Clock.POSIX (getPOSIXTime)

import Network (withSocketsDo)
import Network.URI
import Network.HTTP ()
import Network.Browser

import Network.Curl
import Network.Curl.Easy
import Network.Curl.Opts

import Data.Maybe (fromMaybe)
import Network.URI

import Text.JSON
import Text.JSON.Generic

import Slowly.Collector

import Foreign.C.String

main = withSocketsDo $ getArgs >>= fetchUrisCurl

fetchUrisCurl uris = runWorkers fetchUriCurl uris $ outputJSON

outputJSON (Message thread x) = putStrLn $ encode x
outputJSON (Exit x) = return ()

dict = Just . JSObject . toJSObject

dictprepend Nothing y = dict y
dictprepend (Just (JSObject x)) y = dict $ y ++ fromJSObject x

initHandlers ident handle = do
    -- this needs an event buffer because WriteFunction can't handle writes to Chans
    eventBuffer <- newIORef []
    -- instantiate a standard header parsing handler from Network.Curl
    -- (finalHeader, gatherHeader) <- newIncomingHeader
    setHandlers eventBuffer -- gatherHeader
    -- return (eventBuffer, finalHeader)
    return eventBuffer
    where
        setHandlers eventBuffer = do
            header <- newIORef ""
            setHandler CurlWriteFunction  bodyHandler
            setHandler CurlHeaderFunction $ headerHandler header
            where
                setHandler t = setopt handle . t . gatherOutput_
                -- defers an event with timing info. flushEvents will be used
                -- to send these events into the appropriate Chan later
                queueEvent event = modifyIORef eventBuffer $ (:) event
                -- headerHandler wraps around the standard header accumilator
                -- with an event generation
                headerHandler header cstr@(_, bytes) = do
                    accum <- readIORef header
                    str <- peekCStringLen cstr
                    cat <- return $ accum ++ str
                    if accum == "" && cat != "" then do
                            e <- newEvent Event_http_response_start
                            queueEvent e{ resource = Just ident }
                    else case str of
                        "\r\n" -> do
                                accum <- readIORef header
                                e <- newEvent Event_http_response_headers_end
                                queueEvent $ addRawHeaders cat e{ resource = Just ident
                                            , meta     = dict [("length",toJSON $ length cat)]
                                            }
                        _ -> return ()
                    writeIORef header $ cat
                            -- gatherHeader cstr
                -- for the body we only care how much and how long it took, not
                -- about the actual body contents for now
                bodyHandler cstr@(_, bytes) = do
                    e <- newEvent Event_http_response_body_data
                    str <- peekCStringLen cstr
                    queueEvent $ addRawBody str e{ resource = Just ident
                                , meta     = dict [("length",toJSON bytes)]
                                }
                addRawBody = flip const
                addRawHeaders = flip const

newEvent event = do
    time <- getPOSIXTime
    return Event { time     = time
                 , event    = event
                 , resource = Nothing
                 , created  = Nothing
                 , meta     = Nothing
                 }

flushEvents chan ref f = do
    events <- readIORef ref
    writeIORef ref []
    mapM_ (send chan) $ map f $ reverse events

-- run a GET request sending progress events to chan
runGetRequest worker chan curl url = do
    uuid :: UUID <- randomIO
    ident <- return $ "request." ++ toString uuid
    eventBuffer <- initHandlers ident curl
    setopts curl [ CurlURL url
                 , CurlHttpVersion HttpVersion11
                 ]
    start <- newEvent Event_http_request_start
    send chan $ start{
        created = Just ident,
        resource = Just worker,
        meta = dict [("uri", toJSON url),("method", toJSON "GET"), ("version", toJSON "1.1")]
    }
    rc <- perform curl -- FIXME check rc
    rspCode <- getResponseCode curl
    end <- newEvent Event_http_response_end
    flushEvents chan eventBuffer $ addStatus rspCode
    send chan end{
        created = Nothing,
        resource = Just ident,
        meta = Nothing
    }


addMeta add e@Event{ meta = meta } = e{ meta = dictprepend meta add }

addRaw raw = addMeta [("raw",toJSON raw)]

addStatus code e@Event{event = Event_http_response_headers_end} = addMeta [("status", toJSON code)] e
addStatus code x = x

fetchUriCurl chan url = do
    uuid :: UUID <- randomIO
    ident <- return $ "worker." ++ toString uuid
    start <- newEvent $ EventCustom "tehslow.worker.start"
    send chan start{
        created = Just ident
    }
    curl <- initialize
    setopts curl [ CurlSSLVerifyPeer False -- don't attempt to validate the cert
                 , CurlSSLVerifyHost 1     -- more trusting (no actual cert validation)
                 , CurlNoSignal False      -- has to do with thread safety
                 ]
    requestLoop ident curl 200
    -- runGetRequest ident chan curl url
    where requestLoop ident curl 0 = return ()
          requestLoop ident curl i = do
            runGetRequest ident chan curl url
            -- threadDelay 10000
            requestLoop ident curl (i-1)


-- fetchUris uri_strings = do
--     runWorkers fetchUri uris print
--     where
--         uris  = map parse uri_strings
--         parse = fromMaybe (error "Nothing from url parse") . parseURI
--
-- -- this is the a sample "actor"
-- -- currently it fetches a single URI as fast as possible in an infinite loop
-- fetchUri chan uri = browse $ do
--     setOutHandler ( const $ return () )
--     fetchUri'
--     where
--         fetchUri' = do
--             bnotify chan "sending request"
--             request $ defaultGETRequest uri
--             bnotify chan $ "got response"
--             -- out (rspBody $ snd rsp)

-- boobies! with bling!
hotAction = (.)$(.) ioAction

-- sends a notification from a browser action
bnotify = hotAction notify
