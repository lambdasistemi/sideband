module Sideband.Config
    ( Config (..)
    , loadConfig
    , requireChat
    , parseEnvFile
    , lookupKey
    , setKey
    , tagName
    ) where

-- \|
-- Module      : Sideband.Config
-- Description : Env-file configuration and agent tag resolution
-- Copyright   : (c) Paolo Veronelli, 2026
-- License     : MIT
--
-- Configuration comes from a shell-style env file (default
-- @$XDG_CONFIG_HOME/sideband/env@, overridable with @TG_AGENT_ENV@) so the
-- same file can be shared with other tools. Spool state lives under
-- @$XDG_STATE_HOME/sideband@ (overridable with @TG_STATE@).

import Data.Maybe (fromMaybe, mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import System.Directory
    ( XdgDirectory (XdgConfig, XdgState)
    , createDirectoryIfMissing
    , doesFileExist
    , getCurrentDirectory
    , getXdgDirectory
    )
import System.Environment (lookupEnv)
import System.Exit (ExitCode (ExitSuccess))
import System.FilePath (takeDirectory, takeFileName, (</>))
import System.Process (readProcessWithExitCode)

-- | Everything the commands need to talk to Telegram and the spool.
data Config = Config
    { envFile :: FilePath
    -- ^ where credentials live; 'setKey' writes back here
    , botToken :: Text
    -- ^ @AGENT_TELEGRAM_BOT_TOKEN@
    , chatId :: Maybe Text
    -- ^ @AGENT_TELEGRAM_CHAT_ID@, absent before first @tg setup@
    , groupId :: Maybe Text
    -- ^ @AGENT_TELEGRAM_GROUP_ID@, the forum supergroup for topics
    , whisperUrl :: Maybe Text
    -- ^ @WHISPER_URL@, HTTP transcription endpoint for voice notes
    , stateDir :: FilePath
    -- ^ spool root (tags, offset, sent index, daemon pidfile)
    }
    deriving (Show, Eq)

{- | Load configuration from the env file.

Fails with an instructive message when the file or the bot token is
missing, since nothing works without a token.
-}
loadConfig :: IO (Either String Config)
loadConfig = do
    envOverride <- lookupEnv "TG_AGENT_ENV"
    defaultEnvFile <- getXdgDirectory XdgConfig ("sideband" </> "env")
    let envPath = fromMaybe defaultEnvFile envOverride
    stateOverride <- lookupEnv "TG_STATE"
    defaultState <- getXdgDirectory XdgState "sideband"
    let statePath = fromMaybe defaultState stateOverride
    exists <- doesFileExist envPath
    if not exists
        then
            pure $
                Left $
                    "env file not found: "
                        <> envPath
                        <> " — create it with AGENT_TELEGRAM_BOT_TOKEN=<token>"
                        <> " (from @BotFather)"
        else do
            kvs <- parseEnvFile <$> TIO.readFile envPath
            pure $ case lookupKey kvs "AGENT_TELEGRAM_BOT_TOKEN" of
                Nothing ->
                    Left $
                        "AGENT_TELEGRAM_BOT_TOKEN missing in "
                            <> envPath
                Just tok ->
                    Right
                        Config
                            { envFile = envPath
                            , botToken = tok
                            , chatId =
                                lookupKey kvs "AGENT_TELEGRAM_CHAT_ID"
                            , groupId =
                                lookupKey kvs "AGENT_TELEGRAM_GROUP_ID"
                            , whisperUrl = lookupKey kvs "WHISPER_URL"
                            , stateDir = statePath
                            }

-- | Commands that need a recipient fail early without a chat id.
requireChat :: Config -> Either String Text
requireChat Config{chatId, envFile} =
    case chatId of
        Just c -> Right c
        Nothing ->
            Left $
                "AGENT_TELEGRAM_CHAT_ID missing in "
                    <> envFile
                    <> " — run 'tg setup'"

{- | Parse a shell-style env file into key-value pairs.

Keeps only @KEY=value@ lines, ignores comments and blanks, strips one
level of surrounding double quotes from values.
-}
parseEnvFile :: Text -> [(Text, Text)]
parseEnvFile = mapMaybe parseLine . T.lines
  where
    parseLine line
        | T.null stripped || "#" `T.isPrefixOf` stripped = Nothing
        | (k, rest) <- T.breakOn "=" stripped
        , not (T.null rest)
        , not (T.null k) =
            Just (k, unquote $ T.drop 1 rest)
        | otherwise = Nothing
      where
        stripped = T.strip line
    unquote v =
        fromMaybe v $
            T.stripPrefix "\"" =<< T.stripSuffix "\"" v

-- | Last occurrence wins, matching shell semantics; empty is missing.
lookupKey :: [(Text, Text)] -> Text -> Maybe Text
lookupKey kvs k =
    case [v | (k', v) <- kvs, k' == k, not (T.null v)] of
        [] -> Nothing
        vs -> Just (last vs)

-- | Replace-or-append a key in the env file (used by @tg setup@).
setKey :: FilePath -> Text -> Text -> IO ()
setKey path k v = do
    createDirectoryIfMissing True (takeDirectory path)
    exists <- doesFileExist path
    content <- if exists then TIO.readFile path else pure ""
    let keep =
            filter (not . ((k <> "=") `T.isPrefixOf`)) $
                T.lines content
    TIO.writeFile path $ T.unlines $ keep <> [k <> "=" <> v]

{- | The agent's identity on the channel.

@TG_TAG@ wins; otherwise the basename of the git toplevel (or the
current directory outside a repo), so each worktree is its own agent.
-}
tagName :: IO Text
tagName = do
    override <- lookupEnv "TG_TAG"
    case override of
        Just t | not (null t) -> pure $ T.pack t
        _ -> do
            (code, out, _) <-
                readProcessWithExitCode
                    "git"
                    ["rev-parse", "--show-toplevel"]
                    ""
            root <- case (code, lines out) of
                (ExitSuccess, top : _) -> pure top
                _ -> getCurrentDirectory
            pure $ T.pack $ takeFileName root
