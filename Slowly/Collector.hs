{-# LANGUAGE DeriveDataTypeable #-}

module Slowly.Collector where

import Data.Data
import Data.Typeable

import Data.Maybe (fromMaybe, catMaybes)

import Control.Concurrent
import Control.Exception (finally)

import Data.Time (NominalDiffTime)
import Data.Time.Clock.POSIX (getPOSIXTime)

import Data.Map (null, lookup, delete, fromList)

import Text.JSON
import Text.JSON.Generic

data EventType = Event_http_request_start
               | Event_http_request_headers_end
               | Event_http_request_body_data
               | Event_http_response_start
               | Event_http_response_headers_end
               | Event_http_response_body_data
               | Event_http_response_end
               | EventCustom String
    deriving (Eq,Ord, Show)

data Output a b = Exit a
                | Message a b
    deriving (Eq, Show, Typeable, Data)

data Datum
    = Event { time      :: NominalDiffTime
            , event     :: EventType
            , resource  :: Maybe String
            , created   :: Maybe String
            , meta      :: Maybe JSValue
            }
   | Sample { time      :: NominalDiffTime
            , sample    :: String
            , resource  :: Maybe String
            , meta      :: Maybe JSValue
            }
    deriving (Eq, Show)

instance JSON Datum where
    readJSON x = Error "unsupported"
    showJSON x = JSObject $ toJSObject $ catMaybes fields
        where
            fields = [ typeJSON
                     , timeJSON
                     , resourceJSON
                     , createdJSON
                     , dataJSON
                     ]
            typeJSON = case x of
                Event{}  -> Just $ ("event", eventJSON x )
                Sample{} -> Just $ ("sample", toJSON $ sample x)
            timeJSON = Just $ ("time", toJSON $ ( realToFrac $ time x :: Double ) )
            resourceJSON = fmap (\ident -> ("resource", toJSON ident)) $ resource x
            createdJSON = case x of
                Event{} -> fmap (\ident -> ("created", toJSON ident)) $ created x
                Sample{} -> Nothing
            dataJSON = fmap (\d -> ("data", d)) $ meta x
            eventJSON = toJSON . eventString . event
            eventString (EventCustom name) = name
            eventString num = map (\x -> if x == '_' then '.' else x) $ drop 6 $ show num

    showJSONs x = toJSON "blah"
    readJSONs x = Error "unsupported"



-- TODO
-- either use Reader or create a Collector monad that encapsulates 'chan' and
-- provides 'notify' functionality. This will decouple the collector body from
-- Control.Concurrent

-- this routine starts a bunch of workers and waits for them
-- all workers are given a channel to write events to
-- when the worker is done it writes a Nothing to the channel
-- when all workers have finished the routine exits
runWorkers _    []   _      = return ()
runWorkers body args output = do
    chan <- newChan
    tids <- startWorkers chan
    waitWorkers chan tids
    where
        -- starts a bunch of workers giving them all this channel to write on
        startWorkers chan = do
            -- create one worker per arg
            tids <- mapM newWorker args
            -- and return the set of thread IDs created
            return $ fromList $ zip tids args
            where
                -- given an arg forks a child and applies the body to the arg
                -- when the body action is finished Nothing is written to the
                -- channel to signal thread exit
                newWorker arg = do
                    tid  <- forkIO wrapped
                    return tid
                    where
                        wrapped = run `finally` finish
                        run     = body chan arg
                        finish  = do
                            tid <- myThreadId
                            writeChan chan $ ( tid, Nothing )
        -- this function waits on all the workers
        -- when a notification for thread end arrives it removes that thread ID
        -- when no threads remain the function returns
        -- other notifications are currently simply printed
        waitWorkers chan workers = readChan chan >>= handleMsg
            where
            loop                      = waitWorkers chan
            handleMsg (tid, Nothing)  = do
                output $ Exit $ inputArg tid
                if Data.Map.null remaining
                   then return ()
                   else loop remaining
                where remaining = delete tid workers
            handleMsg (tid, Just msg) = do
                output $ Message ( inputArg tid ) msg
                loop workers
            inputArg tid              = fromMaybe (error "zombie thread") $ Data.Map.lookup tid workers

-- NominalDiffTime has no Data instace =(
timestamp :: IO Double
timestamp = getPOSIXTime >>= return . realToFrac

-- sends a notification on the channel
notify chan x = do
    time <- getPOSIXTime
    send chan Event {
        time = time,
        event = EventCustom "foo",
        created = Nothing,
        resource = Nothing,
        meta = x
    }

send chan x = do
    tid  <- myThreadId
    writeChan chan $ ( tid, Just x )

