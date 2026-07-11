module Sideband.Commands
    ( cmdSend
    , cmdAsk
    , cmdInbox
    , cmdNext
    , cmdForward
    , cmdWatch
    , cmdOpen
    , cmdClose
    , cmdSetup
    , cmdOn
    , cmdOff
    , cmdStatus
    , timeoutExit
    ) where

-- \|
-- Module      : Sideband.Commands
-- Description : The agent-facing commands: send, ask, inbox, lifecycle
-- Copyright   : (c) Paolo Veronelli, 2026
-- License     : MIT
--
-- All commands are hub-mode only: the daemon owns @getUpdates@ and the
-- commands read routed replies from the spool. The one exception is
-- @setup@, which polls directly for the operator's first message and
-- therefore refuses to run while the daemon is up.

import Control.Concurrent (threadDelay)
import Control.Monad (unless, void, when)
import Data.ByteString qualified as BS
import Data.Maybe (fromMaybe, isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import Sideband.Config
    ( Config (..)
    , requireChat
    , setKey
    , tagName
    )
import Sideband.Daemon (daemonStatus)
import Sideband.Spool
    ( appendSent
    , consumeInbox
    , daemonPid
    , ensureLog
    , inboxDir
    , logPath
    , logSize
    , notifyMarker
    , readLogFrom
    , readTopic
    , registerTag
    , takeOneInbox
    , waitReply
    , writeTopic
    )
import Sideband.Telegram
    ( Bot
    , Incoming (..)
    , IncomingMsg (..)
    , closeForumTopic
    , createForumTopic
    , getMe
    , getUpdates
    , newBot
    , reopenForumTopic
    , sendMessage
    )
import System.Directory
    ( doesDirectoryExist
    , doesFileExist
    , getCurrentDirectory
    , listDirectory
    , removeFile
    )
import System.Exit (ExitCode (ExitFailure, ExitSuccess), exitWith)
import System.FilePath ((</>))
import System.IO
    ( BufferMode (LineBuffering)
    , hFlush
    , hPutStrLn
    , hSetBuffering
    , stderr
    , stdout
    )
import System.Process (readProcessWithExitCode)

-- | @tg ask@ exits with this code when the operator does not answer.
timeoutExit :: Int
timeoutExit = 42

-- | Resolve the send target: the tag's topic in the group, else chat.
sendTarget :: Config -> Text -> IO (Text, Maybe Integer, Bool)
sendTarget cfg tag = do
    chat <- either fail pure (requireChat cfg)
    case groupId cfg of
        Just g -> do
            topic <- readTopic cfg tag
            pure $ case topic of
                Just t -> (g, Just t, True)
                Nothing -> (chat, Nothing, False)
        Nothing -> pure (chat, Nothing, False)

{- | Send a tagged message; returns the Telegram message id. Inside the
tag's own topic the prefix is dropped as redundant.
-}
sendTagged :: Config -> Bot -> Maybe Text -> Text -> IO Integer
sendTagged cfg bot parseMode text0 = do
    tag <- tagName
    (chat, thread, inTopic) <- sendTarget cfg tag
    let clipped =
            if T.length text0 > 4000
                then T.take 4000 text0 <> "\n…[truncated]"
                else text0
        text =
            if inTopic then clipped else "[" <> tag <> "] " <> clipped
    r <- sendMessage bot chat thread parseMode text
    r' <- case (r, parseMode) of
        -- Markdown parse errors are common; retry plain
        (Left _, Just _) -> sendMessage bot chat thread Nothing text
        _ -> pure r
    msgId <- either fail pure r'
    appendSent cfg msgId tag
    pure msgId

-- | @tg send [--md] TEXT@.
cmdSend :: Config -> Bool -> Text -> IO ()
cmdSend cfg md text = do
    bot <- newBot (botToken cfg)
    _ <-
        sendTagged
            cfg
            bot
            (if md then Just "Markdown" else Nothing)
            text
    pure ()

{- | @tg ask [--timeout N] TEXT@ — send the question, block on the
spool for the routed reply, print it on stdout. Exit 'timeoutExit'
without an answer; the late reply still lands in the inbox.
-}
cmdAsk :: Config -> Int -> Text -> IO ()
cmdAsk cfg seconds question = do
    daemon <- daemonPid cfg
    unless (isJust daemon) $
        fail "the hub daemon is not running — 'tg daemon start'"
    tag <- tagName
    bot <- newBot (botToken cfg)
    pending <- consumeInbox cfg tag
    unless (null pending) $ do
        hPutStrLn stderr "tg: unread inbox before question:"
        mapM_ (TIO.hPutStrLn stderr) pending
    (_, _, inTopic) <- sendTarget cfg tag
    let hint =
            if inTopic
                then
                    "("
                        <> T.pack (show seconds)
                        <> "s or I proceed on my own judgment)"
                else
                    "(reply to THIS message; "
                        <> T.pack (show seconds)
                        <> "s or I proceed on my own judgment)"
    _ <-
        sendTagged cfg bot Nothing $ "\10067 " <> question <> "\n" <> hint
    reply <- waitReply cfg tag seconds
    case reply of
        Just text -> do
            _ <- sendTagged cfg bot Nothing "\10004 got it"
            TIO.putStrLn text
        Nothing -> do
            _ <-
                sendTagged cfg bot Nothing $
                    "\9203 no reply in "
                        <> T.pack (show seconds)
                        <> "s — proceeding on my own judgment"
            hPutStrLn stderr "tg: timeout waiting for reply"
            exitWith (ExitFailure timeoutExit)

-- | @tg inbox@ — print and consume this tag's routed messages.
cmdInbox :: Config -> IO ()
cmdInbox cfg = do
    tag <- tagName
    msgs <- consumeInbox cfg tag
    mapM_ TIO.putStrLn msgs

{- | @tg next@ — block until one message arrives for this tag, print it, and
exit. This is the receive primitive for a dedicated Telegram liaison agent: it
loops `msg=$(tg next)` so each incoming message becomes exactly one turn of the
liaison's reasoning (a real agent turn, not a background tail). It consumes the
message, so the next call returns the following one, in FIFO order. With
@--timeout N@ it exits 42 if nothing arrives within N seconds; by default it
blocks indefinitely.
-}
cmdNext :: Config -> Maybe Int -> IO ()
cmdNext cfg mTimeout = do
    tag <- tagName
    registerTag cfg tag
    go tag (fmap (* 2) mTimeout) -- ticks of 500ms
  where
    go tag ticks = do
        m <- takeOneInbox cfg tag
        case m of
            Just msg -> TIO.putStrLn msg
            Nothing -> case ticks of
                Just 0 -> exitWith (ExitFailure timeoutExit)
                _ -> do
                    threadDelay 500_000
                    go tag (fmap (subtract 1) ticks)

{- | @tg forward FILE@ — the upward channel of a Telegram liaison. Tail an
arbitrary append-only channel file (the epic owner appends its replies and
reports to it with @echo "…" >> FILE@) and send each complete new line to this
tag's topic. No pane capturing: the epic owner writes plain lines, this
forwards them. Line-buffered; a trailing partial line is held until its
newline arrives.
-}
cmdForward :: Config -> FilePath -> IO ()
cmdForward cfg path = do
    bot <- newBot (botToken cfg)
    unlessM (doesFileExist path) $ writeFile path ""
    start <- logSize path
    loop bot start
  where
    unlessM p act = p >>= \b -> unless b act
    loop bot off = do
        size <- logSize path
        off' <-
            if size > off
                then do
                    chunk <- readLogFrom path off
                    -- split at the LAST newline: everything before it is
                    -- complete lines; hold the trailing partial for next read
                    let (before, after) = T.breakOnEnd "\n" chunk
                        partialBytes =
                            fromIntegral (BS.length (TE.encodeUtf8 after))
                    mapM_
                        ( \l ->
                            unless (T.null (T.strip l)) $
                                void $
                                    sendTagged cfg bot Nothing l
                        )
                        (T.lines before)
                    pure (size - partialBytes)
                else pure off
        threadDelay 1_000_000
        loop bot off'

{- | @tg watch@ — tail this tag's append-only inbox log, printing each new
message as it is appended. Agent-independent: it is just a @tail -F@ of a
plain file, so any agent can equally use @tail -f@ on the log directly
(printed by 'logPath'). Because the log is append-only, reading never removes
anything — a slow, idle, or restarted agent never loses a message.
-}
cmdWatch :: Config -> IO ()
cmdWatch cfg = do
    -- line-buffer so each message flushes immediately even when stdout is a
    -- pipe/file (a Monitor or a background `tg watch > log`)
    hSetBuffering stdout LineBuffering
    tag <- tagName
    registerTag cfg tag
    let path = logPath cfg tag
    ensureLog cfg tag
    TIO.putStrLn $ "tg watch: tailing " <> T.pack path
    -- start at the current end, like `tail -F`
    start <- logSize path
    loop path start
  where
    loop path off = do
        size <- logSize path
        off' <-
            if size > off
                then do
                    chunk <- readLogFrom path off
                    TIO.putStr chunk
                    hFlush stdout
                    pure size
                else pure off
        threadDelay 1_000_000
        loop path off'

-- | @tg open@ — create (or reopen) this tag's forum topic.
cmdOpen :: Config -> IO ()
cmdOpen cfg = do
    g <-
        maybe
            (fail "AGENT_TELEGRAM_GROUP_ID missing — no forum group")
            pure
            (groupId cfg)
    tag <- tagName
    registerTag cfg tag
    bot <- newBot (botToken cfg)
    existing <- readTopic cfg tag
    case existing of
        Just thread -> do
            -- reopen is idempotent enough; already-open just errors
            _ <- reopenForumTopic bot g thread
            TIO.putStrLn $
                "topic for "
                    <> tag
                    <> " active (thread "
                    <> T.pack (show thread)
                    <> ")"
        Nothing -> do
            r <- createForumTopic bot g tag
            thread <- either fail pure r
            writeTopic cfg tag thread
            TIO.putStrLn $
                "topic '"
                    <> tag
                    <> "' created (thread "
                    <> T.pack (show thread)
                    <> ")"

-- | @tg close@ — close the topic; it stays reusable via @tg open@.
cmdClose :: Config -> IO ()
cmdClose cfg = do
    tag <- tagName
    existing <- readTopic cfg tag
    case (existing, groupId cfg) of
        (Nothing, _) -> TIO.putStrLn $ "no topic for " <> tag
        (_, Nothing) -> TIO.putStrLn "no forum group configured"
        (Just thread, Just g) -> do
            bot <- newBot (botToken cfg)
            _ <- closeForumTopic bot g thread
            TIO.putStrLn $
                "topic for "
                    <> tag
                    <> " closed (thread "
                    <> T.pack (show thread)
                    <> " kept for reuse)"

{- | @tg setup@ — one-shot: greet, wait for the operator's first
message, persist the chat id. Requires the daemon to be stopped since
it polls @getUpdates@ itself.
-}
cmdSetup :: Config -> IO ()
cmdSetup cfg = do
    daemon <- daemonPid cfg
    when (isJust daemon) $
        fail "stop the daemon first: tg daemon stop"
    bot <- newBot (botToken cfg)
    username <- either fail pure =<< getMe bot
    TIO.putStrLn $ "Bot: @" <> username
    putStrLn
        "Send it any message from your Telegram account now; \
        \waiting up to 120s..."
    go bot (6 :: Int) Nothing
  where
    go _ 0 _ =
        fail "no message received — send the bot a message and rerun"
    go bot n offset = do
        r <- getUpdates bot 20 offset
        case r of
            Left err -> fail err
            Right updates ->
                case firstChat updates of
                    Just (cid, off) -> do
                        -- ack the setup message
                        _ <- getUpdates bot 0 (Just off)
                        setKey
                            (envFile cfg)
                            "AGENT_TELEGRAM_CHAT_ID"
                            (T.pack $ show cid)
                        putStrLn $
                            "Captured chat id "
                                <> show cid
                                <> " into "
                                <> envFile cfg
                        _ <-
                            sendMessage
                                bot
                                (T.pack $ show cid)
                                Nothing
                                Nothing
                                "\9989 sideband configured"
                        pure ()
                    Nothing ->
                        go
                            bot
                            (n - 1)
                            (nextOffset updates offset)
    firstChat updates =
        case [ (msgChat m, updateId u + 1)
             | u <- updates
             , Just m <- [message u]
             , msgChatType m == "private"
             ] of
            [] -> Nothing
            (x : _) -> Just x
    nextOffset updates fallback =
        case updates of
            [] -> fallback
            us -> Just (updateId (last us) + 1)

-- | @tg on@ — arm the hook marker, register the tag, open the topic.
cmdOn :: Config -> IO ()
cmdOn cfg = do
    root <- repoRoot
    writeFile (notifyMarker root) ""
    gitExclude root
    tag <- tagName
    registerTag cfg tag
    TIO.putStrLn $
        "notifications enabled for "
            <> T.pack root
            <> " (tag: "
            <> tag
            <> ")"
    when (isJust (groupId cfg)) $ cmdOpen cfg

-- | @tg off@ — disarm the hook and close the topic.
cmdOff :: Config -> IO ()
cmdOff cfg = do
    root <- repoRoot
    let marker = notifyMarker root
    exists <- doesFileExist marker
    when exists $ removeFile marker
    TIO.putStrLn $ "notifications disabled for " <> T.pack root
    when (isJust (groupId cfg)) $ cmdClose cfg

-- | @tg status@ — one screen of config, daemon, and channel state.
cmdStatus :: Config -> IO ()
cmdStatus cfg = do
    tag <- tagName
    putStrLn $ "env file:  " <> envFile cfg
    putStrLn "token:     set"
    TIO.putStrLn $
        "chat id:   " <> fromMaybe "MISSING — run 'tg setup'" (chatId cfg)
    TIO.putStrLn $
        "group:     "
            <> fromMaybe "none (private chat mode)" (groupId cfg)
    TIO.putStrLn $ "tag:       " <> tag
    topic <- readTopic cfg tag
    putStrLn $ "topic:     " <> maybe "none" show topic
    daemonStatus cfg
    let dir = inboxDir cfg tag
    hasDir <- doesDirectoryExist dir
    n <- if hasDir then length <$> listDirectory dir else pure 0
    putStrLn $ "inbox:     " <> show n <> " pending"
    root <- repoRoot
    marker <- doesFileExist (notifyMarker root)
    putStrLn $
        "hook:      " <> if marker then "on (" <> root <> ")" else "off"

repoRoot :: IO FilePath
repoRoot = do
    (code, out, _) <-
        readProcessWithExitCode
            "git"
            ["rev-parse", "--show-toplevel"]
            ""
    case (code, lines out) of
        (ExitSuccess, top : _) -> pure top
        _ -> getCurrentDirectory

gitExclude :: FilePath -> IO ()
gitExclude root = do
    (code, out, _) <-
        readProcessWithExitCode
            "git"
            ["-C", root, "rev-parse", "--git-path", "info/exclude"]
            ""
    case (code, lines out) of
        (ExitSuccess, rel : _) -> do
            let absPath =
                    if take 1 rel == "/" then rel else root </> rel
            exists <- doesFileExist absPath
            content <-
                if exists then TIO.readFile absPath else pure ""
            unless (".tg-notify" `elem` T.lines content) $
                TIO.appendFile absPath ".tg-notify\n"
        _ -> pure ()
