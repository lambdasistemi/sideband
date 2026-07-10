module Sideband.Daemon
    ( daemonRun
    , daemonStart
    , daemonStop
    , daemonStatus
    ) where

-- \|
-- Module      : Sideband.Daemon
-- Description : The hub — sole getUpdates poller, routes to inbox spools
-- Copyright   : (c) Paolo Veronelli, 2026
-- License     : MIT
--
-- Telegram allows exactly one @getUpdates@ consumer per bot token, so a
-- single daemon owns the inbound direction and every agent reads its
-- routed messages from the spool. Voice notes are transcribed through a
-- whisper-server before routing. Under systemd (see the flake's NixOS
-- module) run @tg daemon run@ in the foreground; @start@/@stop@ manage a
-- detached instance for machines without a service manager.

import Control.Concurrent (threadDelay)
import Control.Monad (forM_, void, when)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Sideband.Config (Config (..), requireChat)
import Sideband.Route
    ( Route (Broadcast, Dropped, ToTag)
    , RoutingTable (..)
    , routeIncoming
    )
import Sideband.Spool
    ( appendLog
    , daemonPid
    , deliver
    , knownTags
    , pidFile
    , readOffset
    , readSent
    , readTopicMap
    , writeOffset
    )
import Sideband.Telegram
    ( Bot (manager)
    , Incoming (..)
    , IncomingMsg (..)
    , downloadVoice
    , getUpdates
    , newBot
    , replyMessage
    , setMessageReaction
    , transcribe
    )
import System.Directory (createDirectoryIfMissing, removeFile)
import System.Exit (exitFailure)
import System.FilePath (takeDirectory, (</>))
import System.IO
    ( BufferMode (LineBuffering)
    , IOMode (AppendMode)
    , hSetBuffering
    , openFile
    , stdout
    )
import System.Posix.IO
    ( OpenMode (ReadOnly)
    , closeFd
    , defaultFileFlags
    , dupTo
    , handleToFd
    , openFd
    , stdError
    , stdInput
    , stdOutput
    )
import System.Posix.Process
    ( createSession
    , forkProcess
    , getProcessID
    )
import System.Posix.Signals (sigTERM, signalProcess)

-- | Foreground hub loop; the systemd unit runs exactly this.
daemonRun :: Config -> IO ()
daemonRun cfg = do
    hSetBuffering stdout LineBuffering
    existing <- daemonPid cfg
    case existing of
        Just pid -> do
            putStrLn $ "daemon already running (pid " <> show pid <> ")"
            exitFailure
        Nothing -> pure ()
    chat <- either fail pure (requireChat cfg)
    createDirectoryIfMissing True (stateDir cfg </> "tags")
    me <- getProcessID
    writeFile (pidFile cfg) (show me)
    bot <- newBot (botToken cfg)
    offset0 <- readOffset cfg
    putStrLn $
        "sideband daemon up: pid "
            <> show me
            <> ", state "
            <> stateDir cfg
    loop bot chat offset0
  where
    loop bot chat offset = do
        r <- getUpdates bot 50 offset
        case r of
            Left err -> do
                putStrLn $ "getUpdates error: " <> err
                threadDelay 10_000_000
                loop bot chat offset
            Right updates -> do
                offset' <- processBatch cfg bot chat updates offset
                when (offset' /= offset) $
                    forM_ offset' (writeOffset cfg)
                loop bot chat offset'

processBatch
    :: Config
    -> Bot
    -> Text
    -> [Incoming]
    -> Maybe Integer
    -> IO (Maybe Integer)
processBatch cfg bot chat updates offset0 = go offset0 updates
  where
    go offset [] = pure offset
    go _ (Incoming{updateId, message} : rest) = do
        let offset' = Just (updateId + 1)
        forM_ message $ \msg -> do
            mText <- textOf msg
            forM_ mText $ \text -> do
                table <- routingTable
                let route = routeIncoming table msg text
                dispatch route
                -- Read receipt: the Bot API has no seen-ticks, so react with
                -- the eyes emoji to every message we actually route. Best
                -- effort; a failed reaction must not drop the message.
                case route of
                    Dropped _ -> pure ()
                    _ ->
                        void $
                            setMessageReaction
                                bot
                                (T.pack (show (msgChat msg)))
                                (msgId msg)
                                "\128064"
        go offset' rest

    routingTable = do
        topics <- readTopicMap cfg
        sent <- readSent cfg
        tags <- knownTags cfg
        pure
            RoutingTable
                { rtChat = chat
                , rtGroup = groupId cfg
                , rtTopics = topics
                , rtSent = sent
                , rtTags = tags
                }

    -- every routed message goes to two surfaces: the append-only inbox.log
    -- (the watch surface — never consumed) and the spool (for ask/inbox).
    dispatch = \case
        ToTag tag text -> do
            appendLog cfg tag text
            deliver cfg tag text
            TIO.putStrLn $ "routed -> " <> tag
        Broadcast text -> do
            tags <- knownTags cfg
            if null tags
                then do
                    appendLog cfg "_unclaimed" text
                    deliver cfg "_unclaimed" text
                    putStrLn "no tags registered -> _unclaimed"
                else do
                    mapM_ (\t -> appendLog cfg t text >> deliver cfg t text) tags
                    putStrLn "broadcast -> all tags"
        Dropped reason -> TIO.putStrLn $ "dropped: " <> reason

    -- text, or the transcription of a voice note
    textOf IncomingMsg{msgText = Just t} = pure (Just t)
    textOf m@IncomingMsg{msgVoice = Just fileId} =
        case whisperUrl cfg of
            Nothing -> do
                putStrLn "voice note but WHISPER_URL unset — dropped"
                pure Nothing
            Just url -> do
                r <- downloadVoice bot fileId
                case r of
                    Left err -> do
                        putStrLn $ "voice download failed: " <> err
                        pure Nothing
                    Right audio -> do
                        t <- transcribe (manager bot) url audio
                        case t of
                            Left err -> do
                                putStrLn $
                                    "transcription failed: " <> err
                                pure Nothing
                            Right txt -> do
                                putStrLn "voice note transcribed"
                                -- Echo the transcription back under the
                                -- user's audio so they see what was heard
                                -- (Telegram can't replace the audio itself).
                                void $
                                    replyMessage
                                        bot
                                        (T.pack (show (msgChat m)))
                                        (msgThread m)
                                        (msgId m)
                                        ("\127908 " <> txt)
                                pure $ Just $ "\127908 " <> txt
    textOf _ = pure Nothing

-- | Detach a daemon (for machines without the systemd module).
daemonStart :: Config -> IO ()
daemonStart cfg = do
    existing <- daemonPid cfg
    case existing of
        Just pid ->
            putStrLn $ "already running (pid " <> show pid <> ")"
        Nothing -> do
            let logPath = stateDir cfg </> "daemon.log"
            createDirectoryIfMissing True (takeDirectory logPath)
            _ <- forkProcess $ do
                _ <- createSession
                devNull <-
                    openFd "/dev/null" ReadOnly defaultFileFlags
                _ <- dupTo devNull stdInput
                closeFd devNull
                logFd <-
                    handleToFd =<< openFile logPath AppendMode
                _ <- dupTo logFd stdOutput
                _ <- dupTo logFd stdError
                closeFd logFd
                daemonRun cfg
            threadDelay 1_000_000
            alive <- daemonPid cfg
            case alive of
                Just pid ->
                    putStrLn $
                        "daemon started (pid "
                            <> show pid
                            <> ", log "
                            <> logPath
                            <> ")"
                Nothing -> do
                    putStrLn $
                        "daemon failed to start — see " <> logPath
                    exitFailure

-- | Stop a detached daemon.
daemonStop :: Config -> IO ()
daemonStop cfg = do
    existing <- daemonPid cfg
    case existing of
        Nothing -> putStrLn "not running"
        Just pid -> do
            signalProcess sigTERM pid
            removeFile (pidFile cfg)
            putStrLn "daemon stopped"

-- | Report whether the hub is up.
daemonStatus :: Config -> IO ()
daemonStatus cfg = do
    existing <- daemonPid cfg
    case existing of
        Just pid ->
            putStrLn $ "daemon running (pid " <> show pid <> ")"
        Nothing -> putStrLn "daemon not running"
