module Sideband.Spool
    ( inboxDir
    , registerTag
    , deliver
    , consumeInbox
    , waitReply
    , logPath
    , appendLog
    , ensureLog
    , logSize
    , readLogFrom
    , appendSent
    , readSent
    , readTopic
    , writeTopic
    , readTopicMap
    , knownTags
    , readOffset
    , writeOffset
    , pidFile
    , daemonPid
    , notifyMarker
    ) where

-- \|
-- Module      : Sideband.Spool
-- Description : File-based spool shared between daemon and commands
-- Copyright   : (c) Paolo Veronelli, 2026
-- License     : MIT
--
-- The daemon is the only Telegram poller; commands read their messages
-- from a per-tag inbox spool on disk. Layout under the state dir:
--
-- @
-- tags/\<tag\>/inbox/\<nanos\>.msg   routed messages, one file each
-- tags/\<tag\>/topic               forum topic thread id, when open
-- sent.idx                        message_id\\ttag registry (reply routing)
-- offset                          last acknowledged update id + 1
-- daemon.pid                      hub daemon pidfile
-- @

import Control.Concurrent (threadDelay)
import Control.Exception (try)
import Control.Monad (unless)
import Data.ByteString qualified as BS
import Data.List (sort)
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import Data.Time.Clock.POSIX (getPOSIXTime)
import Sideband.Config (Config (..))
import System.Directory
    ( createDirectoryIfMissing
    , doesDirectoryExist
    , doesFileExist
    , listDirectory
    , removeFile
    )
import System.FilePath (takeExtension, (</>))
import System.IO
    ( IOMode (ReadMode)
    , SeekMode (AbsoluteSeek)
    , hFileSize
    , hSeek
    , withFile
    )
import System.Posix.Signals (nullSignal, signalProcess)
import System.Posix.Types (CPid (..))
import Text.Read (readMaybe)

-- | A tag's inbox directory.
inboxDir :: Config -> Text -> FilePath
inboxDir cfg tag = tagDir cfg tag </> "inbox"

tagDir :: Config -> Text -> FilePath
tagDir Config{stateDir} tag = stateDir </> "tags" </> T.unpack tag

{- | The tag's append-only inbox log — the watch surface. Any tool can
@tail -f@ it; it is never truncated or consumed.
-}
logPath :: Config -> Text -> FilePath
logPath cfg tag = tagDir cfg tag </> "inbox.log"

{- | Append one message as a single line (newlines flattened to spaces so
@tail -f@ shows one line per message).
-}
appendLog :: Config -> Text -> Text -> IO ()
appendLog cfg tag text = do
    createDirectoryIfMissing True (tagDir cfg tag)
    let oneLine = T.map (\c -> if c == '\n' then ' ' else c) text
    TIO.appendFile (logPath cfg tag) (oneLine <> "\n")

-- | Ensure the tag's log file exists so a watcher can open it immediately.
ensureLog :: Config -> Text -> IO ()
ensureLog cfg tag = do
    createDirectoryIfMissing True (tagDir cfg tag)
    let p = logPath cfg tag
    exists <- doesFileExist p
    unless exists $ TIO.writeFile p ""

-- | Current byte length of the log (0 if absent).
logSize :: FilePath -> IO Integer
logSize path = do
    exists <- doesFileExist path
    if exists then withFile path ReadMode hFileSize else pure 0

-- | Read the log from a byte offset to the end, decoding leniently.
readLogFrom :: FilePath -> Integer -> IO Text
readLogFrom path off = withFile path ReadMode $ \h -> do
    hSeek h AbsoluteSeek off
    TE.decodeUtf8Lenient <$> BS.hGetContents h

-- | Make a tag visible to the hub (idempotent).
registerTag :: Config -> Text -> IO ()
registerTag cfg tag = createDirectoryIfMissing True (inboxDir cfg tag)

-- | Write one message into a tag's inbox, nanosecond-stamped.
deliver :: Config -> Text -> Text -> IO ()
deliver cfg tag text = do
    registerTag cfg tag
    nanos <- (round . (* 1e9) <$> getPOSIXTime) :: IO Integer
    TIO.writeFile (inboxDir cfg tag </> show nanos <> ".msg") text

-- | Read and delete this tag's pending messages, oldest first.
consumeInbox :: Config -> Text -> IO [Text]
consumeInbox cfg tag = do
    let dir = inboxDir cfg tag
    exists <- doesDirectoryExist dir
    if not exists
        then pure []
        else do
            files <-
                sort . filter ((== ".msg") . takeExtension)
                    <$> listDirectory dir
            mapM
                ( \f -> do
                    t <- TIO.readFile (dir </> f)
                    removeFile (dir </> f)
                    pure t
                )
                files

{- | Block until a message lands in this tag's inbox or the deadline
passes; consumes and returns the first message only.
-}
waitReply :: Config -> Text -> Int -> IO (Maybe Text)
waitReply cfg tag seconds = do
    registerTag cfg tag
    go (max 1 (seconds * 2))
  where
    go 0 = pure Nothing
    go n = do
        msgs <- consumeInbox cfg tag
        case msgs of
            (m : rest) -> do
                -- put back anything beyond the first
                mapM_ (deliver cfg tag) rest
                pure (Just m)
            [] -> threadDelay 500_000 >> go (n - 1)

-- | Record a sent message id for reply routing.
appendSent :: Config -> Integer -> Text -> IO ()
appendSent Config{stateDir} msgId tag = do
    createDirectoryIfMissing True stateDir
    TIO.appendFile (stateDir </> "sent.idx") $
        T.pack (show msgId) <> "\t" <> tag <> "\n"

-- | The sent registry, message id → tag.
readSent :: Config -> IO [(Integer, Text)]
readSent Config{stateDir} = do
    let path = stateDir </> "sent.idx"
    exists <- doesFileExist path
    if not exists
        then pure []
        else mapMaybe parseLine . T.lines <$> TIO.readFile path
  where
    parseLine l = case T.splitOn "\t" l of
        [i, tag] -> (,tag) <$> readMaybe (T.unpack i)
        _ -> Nothing

-- | This tag's open forum topic, if any.
readTopic :: Config -> Text -> IO (Maybe Integer)
readTopic cfg tag = do
    let path = tagDir cfg tag </> "topic"
    exists <- doesFileExist path
    if not exists
        then pure Nothing
        else readMaybe . T.unpack . T.strip <$> TIO.readFile path

-- | Persist a tag's forum topic thread id.
writeTopic :: Config -> Text -> Integer -> IO ()
writeTopic cfg tag thread = do
    createDirectoryIfMissing True (tagDir cfg tag)
    TIO.writeFile (tagDir cfg tag </> "topic") $ T.pack $ show thread

-- | All open topics, thread id → tag (the daemon's routing input).
readTopicMap :: Config -> IO [(Integer, Text)]
readTopicMap cfg = do
    tags <- knownTags cfg
    mapMaybe pairUp
        <$> mapM (\t -> (,) <$> readTopic cfg t <*> pure t) tags
  where
    pairUp (mi, t) = (,t) <$> mi

-- | Every registered tag.
knownTags :: Config -> IO [Text]
knownTags Config{stateDir} = do
    let dir = stateDir </> "tags"
    exists <- doesDirectoryExist dir
    if not exists
        then pure []
        else map T.pack . sort <$> listDirectory dir

-- | Last acknowledged update offset, if the daemon ever ran.
readOffset :: Config -> IO (Maybe Integer)
readOffset Config{stateDir} = do
    let path = stateDir </> "offset"
    exists <- doesFileExist path
    if not exists
        then pure Nothing
        else readMaybe . T.unpack . T.strip <$> TIO.readFile path

-- | Persist the update offset after a processed batch.
writeOffset :: Config -> Integer -> IO ()
writeOffset Config{stateDir} off = do
    createDirectoryIfMissing True stateDir
    TIO.writeFile (stateDir </> "offset") $ T.pack $ show off

-- | Where the daemon records its pid.
pidFile :: Config -> FilePath
pidFile Config{stateDir} = stateDir </> "daemon.pid"

-- | The live daemon's pid, checked with a null signal.
daemonPid :: Config -> IO (Maybe CPid)
daemonPid cfg = do
    exists <- doesFileExist (pidFile cfg)
    if not exists
        then pure Nothing
        else do
            content <- TIO.readFile (pidFile cfg)
            case readMaybe (T.unpack $ T.strip content) of
                Nothing -> pure Nothing
                Just pid -> do
                    alive <-
                        try @IOError $
                            signalProcess nullSignal (CPid pid)
                    pure $ case alive of
                        Right () -> Just (CPid pid)
                        Left _ -> Nothing

-- | The per-repo opt-in marker for the notification hook.
notifyMarker :: FilePath -> FilePath
notifyMarker root = root </> ".tg-notify"
