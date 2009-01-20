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

runWorkers body args = do
    chan <- newChan
    tids <- startWorkers chan
    waitWorkers chan tids
    where
        startWorkers chan = do
            tids <- mapM newWorker args
            return $ fromList tids
            where
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

notify chan x = do
    time <- getCurrentTime
    tid <- myThreadId
    writeChan chan ( tid, Just (time, x) )

-- boobies! with bling!
hotAction = (.)$(.) ioAction

bnotify = hotAction notify

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
