module Network.Riak.Montage.Process where

import Control.Monad (void)
import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (newEmptyMVar, takeMVar, putMVar, MVar)
import Control.Concurrent.STM (atomically, newTVarIO)
import Control.Concurrent.STM.TVar (readTVar, writeTVar, TVar)
import Control.Concurrent.STM.TMVar (newEmptyTMVar, readTMVar, putTMVar, TMVar)
import Control.Exception (finally, try, throw, SomeException)
import Text.ProtocolBuffers.WireMessage (messageGet, messagePut)
import System.Timeout (timeout)
import Data.Time.Clock.POSIX (getPOSIXTime)
import Data.Maybe (fromJust)
import Data.Aeson ((.=), object)

import qualified Data.HashMap.Strict as HM
import Control.Applicative

import qualified Network.Riak.Types as RT
import Text.ProtocolBuffers.Basic (toUtf8, utf8)
import qualified Data.Text.Encoding as E
import Data.Foldable (toList)
import qualified Data.ListLike as LL

import qualified Network.Riak.Value as V
import qualified Network.Riak.Content as C

import Network.Riak.Montage.Proto.Montage.MontageEnvelope as ME
import Network.Riak.Montage.Proto.Montage.MontageWireMessages

import Network.StatsWeb (Stats)

import Network.Riak.Montage.Types
import Network.Riak.Montage.Backend
import Network.Riak.Montage.Commands
import Network.Riak.Montage.Util
import qualified Network.Riak.Montage.Proto.Montage.MontageGet as MG
import qualified Network.Riak.Montage.Proto.Montage.MontageGetMany as MGM
import qualified Network.Riak.Montage.Proto.Montage.MontageGetReference as MGR
import qualified Network.Riak.Montage.Proto.Montage.MontagePut as MP
import qualified Network.Riak.Montage.Proto.Montage.MontagePutMany as MPM
import qualified Network.Riak.Montage.Proto.Montage.MontageObject as MO
import qualified Network.Riak.Montage.Proto.Montage.MontageCommand as MC
import qualified Network.Riak.Montage.Proto.Montage.MontageCommandResponse as MCR
import qualified Network.Riak.Montage.Proto.Montage.MontageDelete as MD

-- maxRequests is maximum pending requests before errors are raised
maxRequests :: Int
maxRequests = 500

-- how many requests before printing stats?
statsEvery :: Int
statsEvery = 100

-- how long can a request run before railing?
requestTimeout :: Int
requestTimeout = 30 * 1000000 -- 30s

data ConcurrentState = ConcurrentState {
      concurrentCount :: TVar Int
    , tick            :: TVar Int
    , ts              :: TVar Double
    , pipeline        :: TVar (HM.HashMap (RT.Bucket, RT.Key) (TMVar (Either SomeException CommandResponse)))
    }

newEmptyConcurrentState :: IO ConcurrentState
newEmptyConcurrentState = ConcurrentState <$> newTVarIO 0 <*> newTVarIO 0 <*> newTVarIO 0 <*> newTVarIO HM.empty

-- TODO -- include subrequests as part of hash key?
pipelineGet :: (MontageRiakValue t) => ConcurrentState -> ChainCommand t -> IO CommandResponse -> IO CommandResponse
pipelineGet state (ChainGet buck key Nothing) actuallyRun = do
    opt <- eitherAnswerOrMandate
    mans <- case opt of
        Left tmv -> do
            mans <- try actuallyRun
            atomically $ do
                putTMVar tmv mans
                hash <- readTVar (pipeline state)
                let hash' = HM.delete hashkey hash
                writeTVar (pipeline state) hash'
            return mans
        Right tmv -> do
            logError $ "(key request for " ++ (show buck) ++ "/" ++ (show key) ++ " is pipelined)"
            atomically $ readTMVar tmv

    case mans of
        Left (e::SomeException) -> throw e
        Right ans -> return ans
  where
    eitherAnswerOrMandate = atomically $ do
        hash <- readTVar (pipeline state)
        case HM.lookup hashkey hash of
            Just tmv -> return $ Right tmv
            Nothing -> do
                newTmv <- newEmptyTMVar
                let hash' = HM.insert hashkey newTmv hash
                writeTVar (pipeline state) hash'
                return $ Left newTmv

    hashkey = (buck, key)

pipelineGet _ _ actuallyRun = actuallyRun

fromRight :: Either a b -> b
fromRight (Right x) = x
fromRight (Left _) = error "fromRight got Left!"

generateRequest :: (MontageRiakValue r) => MontageEnvelope -> ChainCommand r
generateRequest (MontageEnvelope MONTAGE_GET inp _) =
    ChainGet buck key Nothing
  where
    buck = MG.bucket obj
    key = MG.key obj
    obj = (fst . fromRight $ messageGet $ inp) :: MG.MontageGet

generateRequest (MontageEnvelope MONTAGE_GET_MANY inp _) =
    ChainGetMany gets Nothing Nothing
  where
    wrap = (fst . fromRight $ messageGet $ inp) :: MGM.MontageGetMany
    subs = MGM.gets wrap
    gets = toList $ fmap makeGet subs

    makeGet g = (buck, key)
        where
            buck = MG.bucket g
            key = MG.key g

generateRequest (MontageEnvelope MONTAGE_COMMAND inp _) =
    ChainCustom command arg
  where
    command = E.decodeUtf8 $ lTs $ utf8 $ MC.command obj
    arg = MC.argument obj
    obj = (fst . fromRight $ messageGet $ inp) :: MC.MontageCommand

generateRequest (MontageEnvelope MONTAGE_PUT inp _) =
    ChainPut vclock buck key dat Nothing
  where
    obj = MP.object wrap
    vclock = MO.vclock obj
    buck = MO.bucket obj
    key = MO.key obj
    dat = fromJust $ V.fromContent buck $ C.empty { C.value = MO.data' obj }
    wrap = (fst . fromRight $ messageGet $ inp) :: MP.MontagePut

generateRequest (MontageEnvelope MONTAGE_PUT_MANY inp _) =
    ChainPutMany puts Nothing
  where
    pb = fst $ fromRight $ messageGet inp
    puts = toList $ fmap makePut $ MPM.objects pb
    makePut g = (MO.vclock g, buck, MO.key g, dat)
      where
        buck = MO.bucket g
        dat = fromJust $ V.fromContent buck $ C.empty { C.value = MO.data' g }

generateRequest (MontageEnvelope MONTAGE_GET_REFERENCE inp _) =
    ChainReference buck key targets
  where
    buck = MGR.bucket wrap
    key = MGR.key wrap
    targets = LL.toList $ MGR.target_buckets wrap
    wrap = (fst . fromRight $ messageGet $ inp) :: MGR.MontageGetReference

generateRequest (MontageEnvelope MONTAGE_DELETE inp _) =
    ChainDelete buck key Nothing
  where
    buck = MD.bucket obj
    key = MD.key obj
    obj = (fst . fromRight $ messageGet $ inp) :: MD.MontageDelete

generateRequest (MontageEnvelope MONTAGE_GET_RESPONSE _ _) = error "MONTAGE_GET_RESPONSE is reserved for responses from montage"
generateRequest (MontageEnvelope MONTAGE_COMMAND_RESPONSE _ _) = error "MONTAGE_COMMAND_RESPONSE is reserved for responses from montage"
generateRequest (MontageEnvelope MONTAGE_PUT_RESPONSE _ _) = error "MONTAGE_PUT_RESPONSE is reserved for responses from montage"
generateRequest (MontageEnvelope MONTAGE_PUT_MANY_RESPONSE _ _) = error "MONTAGE_PUT_MANY_RESPONSE is reserved for responses from montage"
generateRequest (MontageEnvelope MONTAGE_ERROR _ _) = error "MONTAGE_ERROR is reserved for responses from montage"
generateRequest (MontageEnvelope MONTAGE_DELETE_RESPONSE _ _) = error "MONTAGE_DELETE_RESPONSE is reserved for responses from montage"
generateRequest (MontageEnvelope DEPRICATED_MONTAGE_SET_REFERENCE _ _) = error "DEPRICATED_MONTAGE_SET_REFERENCE is deprecated!"


processRequest :: (MontageRiakValue r) => ConcurrentState -> LogCallback -> PoolChooser -> ChainCommand r -> Stats -> IO CommandResponse
processRequest state logCB chooser' cmd stats = do
    mcount <- maybeIncrCount
    case mcount of
        Just count -> do
            logState count
            finally (runWithTimeout (processRequest' chooser' cmd stats)) decrCount
        Nothing -> do
            let errorText = "concurrency limit hit" :: String
            logCB "EXCEPTION" Nothing $ object ["error" .= errorText]
            error errorText
  where
    runWithTimeout actuallyRun = do
        mr <- timeout requestTimeout (pipelineGet state cmd actuallyRun)
        case mr of
            Just r -> do
                return r
            Nothing -> do
                error "montage request timeout!"

    maybeIncrCount = atomically $ do
        count <- readTVar (concurrentCount state)
        if (count < maxRequests)
        then (writeTVar (concurrentCount state) (count + 1) >> return (Just $ count + 1))
        else (return Nothing)

    decrCount = atomically $ do
        count <- readTVar (concurrentCount state)
        writeTVar (concurrentCount state) $ count - 1

    logState count = do
        now <- fmap realToFrac getPOSIXTime
        mlog <- atomically $ do
            tick' <- fmap (+1) $ readTVar (tick state)
            writeTVar (tick state) tick'
            if tick' `mod` statsEvery == 0
            then do
                last' <- readTVar (ts state)
                writeTVar (ts state) now
                return (Just last')
            else (return Nothing)
        case mlog of
            Just last' -> do
                let speed = (fromIntegral statsEvery) / (now - last') -- should never be /0
                logError ("{stats} concurrency=" ++ (show count)
                    ++ " rate=" ++ (show speed))
            Nothing -> return ()

processRequest' :: (MontageRiakValue r) => PoolChooser -> ChainCommand r -> Stats -> IO CommandResponse
processRequest' chooser' cmd stats = do
    let !step = exec cmd
    case step of
        IterationRiakCommand cmds callback -> do
            rs <- runBackendCommands chooser' stats cmds
            let !cmd' = callback rs
            processRequest' chooser' cmd' stats
        IterationResponse final -> return final
        ChainIterationIO ioCmd -> do
            cmd' <- ioCmd
            processRequest' chooser' cmd' stats

runBackendCommands :: (MontageRiakValue r) => PoolChooser -> Stats -> [RiakRequest r] -> IO [RiakResponse r]
runBackendCommands chooser' stats rs = do
    waits <- mapM (runBackendCommand chooser' stats) rs
    results <- mapM takeMVar waits
    return $ map parseResponse results
  where
    parseResponse :: (MontageRiakValue r) => Either SomeException (RiakResponse r) -> RiakResponse r
    parseResponse (Left e) = throw e
    parseResponse (Right res) = res

runBackendCommand' :: (MontageRiakValue r) => IO (RiakResponse r) -> IO (MVar (Either SomeException (RiakResponse r)))
runBackendCommand' f = do
    wait <- newEmptyMVar
    void $ forkIO $ try f >>= putMVar wait
    return wait

runBackendCommand :: (MontageRiakValue r) => PoolChooser -> Stats -> RiakRequest r -> IO (MVar (Either SomeException (RiakResponse r)))
runBackendCommand chooser' stats (RiakGet buck key) =
    runBackendCommand' $ doGet stats buck key chooser'

runBackendCommand chooser' _ (RiakPut mclock buck key value) =
    runBackendCommand' $ doPut buck key mclock value chooser'

runBackendCommand chooser' _ (RiakDelete buck key) =
    runBackendCommand' $ doDelete buck key chooser'

serializeResponse :: MontageEnvelope -> CommandResponse -> MontageEnvelope
serializeResponse env (ResponseProtobuf code proto) =
    env {mtype=code, msg=messagePut proto}
serializeResponse env (ResponseCustom s arg) =
    env {mtype=MONTAGE_COMMAND_RESPONSE,
         msg=messagePut (MCR.MontageCommandResponse (fromRight $ toUtf8 $ sTl $ E.encodeUtf8 s) arg)
    }
