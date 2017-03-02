{-# LANGUAGE RecordWildCards, BangPatterns, DeriveGeneric #-}
module GitmonClient where

import Data.Aeson
import Data.Aeson.Types
import Data.ByteString.Lazy (toStrict)
import Data.Text (pack, unpack, toLower)
import qualified Data.Yaml as Y
import GHC.Generics
import Git.Libgit2
import Network.Socket
import Network.Socket.ByteString (sendAll)
import Prelude
import Prologue hiding (toStrict)
import System.Clock
import System.Directory (getCurrentDirectory)
import System.Environment

data ProcIO = ProcIO {
    read_bytes :: Integer
  , write_bytes :: Integer
} deriving (Show, Generic)

instance FromJSON ProcIO


data ProcessData =
    ProcessUpdateData { gitDir :: String
                      , program :: String
                      , realIP :: Maybe String
                      , repoID :: Maybe String
                      , repoName :: Maybe String
                      , userID :: Maybe String
                      , via :: String }
  | ProcessScheduleData
  | ProcessFinishData { cpu :: Integer
                      , diskReadBytes :: Integer
                      , diskWriteBytes :: Integer
                      , resultCode :: Integer } deriving (Generic, Show)

instance ToJSON ProcessData where
  toJSON = genericToJSON defaultOptions { fieldLabelModifier = camelTo2 '_' }



data GitmonCommand = Update
                   | Finish
                   | Schedule deriving (Generic, Show)

instance ToJSON GitmonCommand where
  toJSON = genericToJSON defaultOptions { constructorTagModifier = unpack . toLower . pack }


data GitmonMsg = GitmonMsg { command :: GitmonCommand, processData :: ProcessData } deriving (Show)

instance ToJSON GitmonMsg where
  toJSON GitmonMsg{..} = object ["command" .= command, "data" .= processData]

gitmonSocketAddr :: String
gitmonSocketAddr = "/tmp/gitstats.sock"

procFileAddr :: String
procFileAddr = "/proc/self/io"

clock :: Clock
clock = Realtime

processJSON :: GitmonCommand -> ProcessData -> ByteString
processJSON command processData = (toStrict . encode $ GitmonMsg command processData) <> "\n"

type ProcInfo = Either Y.ParseException (Maybe ProcIO)

safeIO :: MonadIO m => IO () -> m ()
safeIO command = liftIO $ command `catch` noop

safeIOValue :: MonadIO m => IO a -> m (Maybe a)
safeIOValue command = liftIO $ (Just <$> command) `catch` noopValue

noop :: IOException -> IO ()
noop _ = pure ()

noopValue :: IOException -> IO (Maybe a)
noopValue _ = pure Nothing

reportGitmon :: String -> ReaderT LgRepo IO a -> ReaderT LgRepo IO a
reportGitmon program gitCommand = do
  maybeSoc <- safeIOValue $ socket AF_UNIX Stream defaultProtocol
  case maybeSoc of
    Nothing -> gitCommand
    Just soc -> do
      safeIO $ connect soc (SockAddrUnix gitmonSocketAddr)
      result <- reportGitmon' soc program gitCommand
      safeIO $ close soc
      pure result

reportGitmon' :: Socket -> String -> ReaderT LgRepo IO a -> ReaderT LgRepo IO a
reportGitmon' soc program gitCommand = do
  (gitDir, realIP, repoID, repoName, userID) <- liftIO loadEnvVars
  safeIO $ sendAll soc (processJSON Update (ProcessUpdateData gitDir program realIP repoID repoName userID "semantic-diff"))
  safeIO $ sendAll soc (processJSON Schedule ProcessScheduleData)
  (startTime, beforeProcIOContents) <- liftIO collectStats
  !result <- gitCommand
  (afterTime, afterProcIOContents) <- liftIO collectStats
  let (cpuTime, diskReadBytes', diskWriteBytes', resultCode') = procStats startTime afterTime beforeProcIOContents afterProcIOContents
  safeIO $ sendAll soc (processJSON Finish ProcessFinishData { cpu = cpuTime, diskReadBytes = diskReadBytes', diskWriteBytes = diskWriteBytes', resultCode = resultCode' })
  pure result

  where collectStats :: IO (TimeSpec, ProcInfo)
        collectStats = do
          time <- getTime clock
          procIOContents <- Y.decodeFileEither procFileAddr :: IO ProcInfo
          pure (time, procIOContents)

        procStats :: TimeSpec -> TimeSpec -> ProcInfo -> ProcInfo -> ( Integer, Integer, Integer, Integer )
        procStats beforeTime afterTime beforeProcIOContents afterProcIOContents = ( cpuTime, diskReadBytes, diskWriteBytes, resultCode )
          where
            cpuTime = toNanoSecs afterTime - toNanoSecs beforeTime
            beforeDiskReadBytes = either (const 0) (maybe 0 read_bytes) beforeProcIOContents
            afterDiskReadBytes = either (const 0) (maybe 0 read_bytes) afterProcIOContents
            beforeDiskWriteBytes = either (const 0) (maybe 0 write_bytes) beforeProcIOContents
            afterDiskWriteBytes = either (const 0) (maybe 0 write_bytes) afterProcIOContents
            diskReadBytes = afterDiskReadBytes - beforeDiskReadBytes
            diskWriteBytes = afterDiskWriteBytes - beforeDiskWriteBytes
            resultCode = 0

        loadEnvVars :: IO (String, Maybe String, Maybe String, Maybe String, Maybe String)
        loadEnvVars = do
          pwd <- getCurrentDirectory
          gitDir <- fromMaybe pwd <$> lookupEnv "GIT_DIR"
          realIP <- lookupEnv "GIT_SOCKSTAT_VAR_real_ip"
          repoID <- lookupEnv "GIT_SOCKSTAT_VAR_repo_id"
          repoName <- lookupEnv "GIT_SOCKSTAT_VAR_repo_name"
          userID <- lookupEnv "GIT_SOCKSTAT_VAR_user_id"
          pure (gitDir, realIP, repoID, repoName, userID)
