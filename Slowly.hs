import Network.URI
import System.Environment (getArgs)
import Data.Maybe (fromMaybe)
import System.IO
import System.IO.Unsafe
import Network.HTTP
import Network.Browser
import Network (withSocketsDo)
import Control.Concurrent
import Control.Exception (finally)
import Data.Time.Clock
import Data.Time.Format
import Data.Set (Set, null, insert, delete, fromList)

main = withSocketsDo $ getArgs >>= fetchUris

fetchUris uri_strings = do
    runWorkers fetchUri uris
    where
        uris  = map parse uri_strings
        parse = fromMaybe (error "Nothing from url parse") . parseURI

-- this routine starts a bunch of workers and waits for them
-- all workers are given a channel to write events to
-- when the worker is done it writes a Nothing to the channel
-- when all workers have finished the routine exits
runWorkers body args = do
    chan <- newChan
    tids <- startWorkers chan
    waitWorkers chan tids
    where
        -- starts a bunch of workers giving them all this channel to write on
        startWorkers chan = do
            -- create one worker per arg
            tids <- mapM newWorker args
            -- and return the set of thread IDs created
            return $ fromList tids
            where
                -- given an arg forks a child and applies the body to the arg
                -- when the body action is finished Nothing is written to the
                -- channel to signal thread exit
                newWorker arg = do
                    tid  <- forkIO wrappedBody
                    return tid
                    where
                        wrappedBody = do
                            notify chan "started"
                            body chan arg `finally` finish chan
                        finish chan = do
                            tid <- myThreadId
                            writeChan chan (tid, Nothing)
        -- this function waits on all the workers
        -- when a notification for thread end arrives it removes that thread ID
        -- when no threads remain the function returns
        -- other notifications are currently simply printed
        waitWorkers chan workers = if Data.Set.null workers
            then return ()
            else do
                (tid, item) <- readChan chan
                case item of
                     Nothing -> finished tid >> waitWorkers chan ( delete tid workers )
                     Just x  -> output tid x >> waitWorkers chan workers
                where
                    finished tid        = diag tid "finished"
                    output   tid x      = diag tid $ show x
                    diag     tid output = putStrLn $ show tid ++ " output: " ++ output

-- sends a notification on the channel
notify chan x = do
    time <- getCurrentTime
    tid <- myThreadId
    writeChan chan ( tid, Just (time, x) )

-- boobies! with bling!
hotAction = (.)$(.) ioAction

-- sends a notification from a browser action
bnotify = hotAction notify

-- this is the a sample "actor"
-- currently it fetches a single URI as fast as possible in an infinite loop
fetchUri chan uri = browse $ do
    setOutHandler ( const $ return () )
    fetchUri'
    where
        fetchUri' = do
            bnotify chan "sending request"
            rsp <- request $ defaultGETRequest uri
            bnotify chan $ "got response"
            fetchUri'
            -- out (rspBody $ snd rsp)
