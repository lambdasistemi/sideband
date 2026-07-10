module Main (main) where

-- \|
-- Module      : Main
-- Description : The @tg@ command line
-- Copyright   : (c) Paolo Veronelli, 2026
-- License     : MIT

import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Options.Applicative
import Sideband.Commands
    ( cmdAsk
    , cmdClose
    , cmdInbox
    , cmdOff
    , cmdOn
    , cmdOpen
    , cmdSend
    , cmdSetup
    , cmdStatus
    )
import Sideband.Config (Config, loadConfig)
import Sideband.Daemon
    ( daemonRun
    , daemonStart
    , daemonStatus
    , daemonStop
    )

data Command
    = Send Bool [Text]
    | Ask Int [Text]
    | Inbox
    | Open
    | Close
    | Setup
    | On
    | Off
    | Status
    | Daemon DaemonCmd

data DaemonCmd = DRun | DStart | DStop | DStatus

main :: IO ()
main = run =<< execParser opts
  where
    opts =
        info
            (parser <**> helper)
            ( fullDesc
                <> progDesc
                    "Telegram side channel for unattended coding \
                    \agents: tagged notifications, blocking \
                    \questions, per-agent forum topics, one hub \
                    \daemon."
                <> header "tg — sideband"
            )

parser :: Parser Command
parser =
    hsubparser $
        command
            "send"
            ( info
                ( Send
                    <$> switch
                        ( long "md"
                            <> help "try Markdown, fall back to plain"
                        )
                    <*> textArgs "TEXT"
                )
                (progDesc "Send a notification")
            )
            <> command
                "ask"
                ( info
                    ( Ask
                        <$> option
                            auto
                            ( long "timeout"
                                <> metavar "SECONDS"
                                <> value 600
                                <> showDefault
                                <> help "seconds to wait for a reply"
                            )
                        <*> textArgs "TEXT"
                    )
                    ( progDesc
                        "Ask a question, print the reply; exit 42 \
                        \on timeout"
                    )
                )
            <> command
                "inbox"
                (info (pure Inbox) (progDesc "Print pending messages"))
            <> command
                "open"
                (info (pure Open) (progDesc "Open this tag's topic"))
            <> command
                "close"
                (info (pure Close) (progDesc "Close this tag's topic"))
            <> command
                "setup"
                (info (pure Setup) (progDesc "Capture the chat id"))
            <> command
                "on"
                ( info
                    (pure On)
                    (progDesc "Enable hook marker and open the topic")
                )
            <> command
                "off"
                ( info
                    (pure Off)
                    (progDesc "Disable hook marker and close the topic")
                )
            <> command
                "status"
                (info (pure Status) (progDesc "Show channel state"))
            <> command
                "daemon"
                ( info
                    (Daemon <$> daemonParser)
                    (progDesc "Manage the hub daemon")
                )
  where
    textArgs meta =
        many (strArgument (metavar meta <> help "message text"))
    daemonParser =
        hsubparser $
            command
                "run"
                (info (pure DRun) (progDesc "Run in the foreground"))
                <> command
                    "start"
                    (info (pure DStart) (progDesc "Start detached"))
                <> command
                    "stop"
                    (info (pure DStop) (progDesc "Stop the daemon"))
                <> command
                    "status"
                    (info (pure DStatus) (progDesc "Daemon liveness"))

run :: Command -> IO ()
run cmd = do
    cfg <- either fail pure =<< loadConfig
    dispatch cfg cmd

dispatch :: Config -> Command -> IO ()
dispatch cfg = \case
    Send md ws -> cmdSend cfg md =<< joined ws
    Ask seconds ws -> cmdAsk cfg seconds =<< joined ws
    Inbox -> cmdInbox cfg
    Open -> cmdOpen cfg
    Close -> cmdClose cfg
    Setup -> cmdSetup cfg
    On -> cmdOn cfg
    Off -> cmdOff cfg
    Status -> cmdStatus cfg
    Daemon DRun -> daemonRun cfg
    Daemon DStart -> daemonStart cfg
    Daemon DStop -> daemonStop cfg
    Daemon DStatus -> daemonStatus cfg
  where
    -- words as separate args, or stdin when none / "-"
    joined ws = case ws of
        [] -> TIO.getContents
        ["-"] -> TIO.getContents
        _ -> pure (T.unwords ws)
