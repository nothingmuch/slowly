module Slowly.Collector where

import Data.Maybe (fromMaybe)

import Control.Concurrent
import Control.Exception (finally)

import Data.Time.Clock (getCurrentTime)
import Data.Time.Format ()

import Data.Map (null, lookup, delete, fromList)

data Output a b = Exit a
                | Data a b
    deriving Show

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
                    tid  <- forkIO wrappedBody
                    return tid
                    where
                        wrappedBody = do
                            body chan arg `finally` finish
                        finish = do
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
                output $ Exit ( inputArg tid )
                if Data.Map.null remaining
                   then return ()
                   else loop remaining
                where remaining = delete tid workers
            handleMsg (tid, Just msg) = do
                output $ Data ( inputArg tid ) msg
                loop workers
            inputArg tid              = fromMaybe (error "zombie thread") $ Data.Map.lookup tid workers

-- sends a notification on the channel
notify chan x = do
    time <- getCurrentTime
    tid  <- myThreadId
    writeChan chan $ ( tid, Just ( time, x ) )

