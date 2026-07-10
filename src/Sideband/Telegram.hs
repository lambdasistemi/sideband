module Sideband.Telegram
    ( Bot (..)
    , newBot
    , Incoming (..)
    , IncomingMsg (..)
    , getUpdates
    , sendMessage
    , getMe
    , downloadVoice
    , createForumTopic
    , closeForumTopic
    , reopenForumTopic
    , transcribe
    ) where

-- \|
-- Module      : Sideband.Telegram
-- Description : Minimal Telegram Bot API client and whisper transcription
-- Copyright   : (c) Paolo Veronelli, 2026
-- License     : MIT
--
-- Just the endpoints sideband needs, over form-encoded POSTs. Responses
-- are decoded into a tolerant 'Incoming' shape: unknown update kinds
-- decode with 'message' set to 'Nothing' and are skipped upstream.

import Control.Applicative ((<|>))
import Data.Aeson
    ( FromJSON (parseJSON)
    , Value
    , eitherDecode
    , withObject
    , (.:)
    , (.:?)
    )
import Data.Aeson.Types (parseEither)
import Data.ByteString.Lazy qualified as BL
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Network.HTTP.Client
    ( Manager
    , Request (responseTimeout)
    , RequestBody (RequestBodyBS)
    , httpLbs
    , parseRequest
    , responseBody
    , responseTimeoutMicro
    , urlEncodedBody
    )
import Network.HTTP.Client.MultipartFormData
    ( formDataBody
    , partFileRequestBody
    )
import Network.HTTP.Client.TLS (newTlsManager)

-- | A connected bot: TLS manager plus token.
data Bot = Bot
    { manager :: Manager
    , token :: Text
    }

-- | Create the shared TLS manager for a bot token.
newBot :: Text -> IO Bot
newBot t = do
    m <- newTlsManager
    pure Bot{manager = m, token = t}

-- | One @getUpdates@ entry; non-message updates carry 'Nothing'.
data Incoming = Incoming
    { updateId :: Integer
    , message :: Maybe IncomingMsg
    }
    deriving (Show, Eq)

-- | The subset of a Telegram message sideband routes on.
data IncomingMsg = IncomingMsg
    { msgChat :: Integer
    , msgChatType :: Text
    , msgChatTitle :: Maybe Text
    , msgText :: Maybe Text
    , msgThread :: Maybe Integer
    , msgIsTopic :: Bool
    , msgReplyTo :: Maybe Integer
    , msgVoice :: Maybe Text
    -- ^ voice (or audio) @file_id@ when the message is a voice note
    }
    deriving (Show, Eq)

instance FromJSON Incoming where
    parseJSON = withObject "Incoming" $ \o -> do
        uid <- o .: "update_id"
        msg <- o .:? "message"
        m <- traverse parseMsg msg
        pure Incoming{updateId = uid, message = m}
      where
        parseMsg = withObject "Message" $ \o -> do
            chat <- o .: "chat"
            (cid, ctype, ctitle) <-
                withObject
                    "Chat"
                    ( \c ->
                        (,,)
                            <$> c .: "id"
                            <*> c .: "type"
                            <*> c .:? "title"
                    )
                    chat
            text <- o .:? "text"
            thread <- o .:? "message_thread_id"
            isTopic <- fromMaybe False <$> o .:? "is_topic_message"
            reply <- o .:? "reply_to_message"
            replyId <-
                traverse
                    (withObject "Reply" (.: "message_id"))
                    reply
            voice <- o .:? "voice"
            audio <- o .:? "audio"
            fileId <-
                traverse
                    (withObject "Voice" (.: "file_id"))
                    (voice <|> audio)
            pure
                IncomingMsg
                    { msgChat = cid
                    , msgChatType = ctype
                    , msgChatTitle = ctitle
                    , msgText = text
                    , msgThread = thread
                    , msgIsTopic = isTopic
                    , msgReplyTo = replyId
                    , msgVoice = fileId
                    }

-- | Form-encoded POST to a bot method, decoding @result@ on ok.
apiCall
    :: (FromJSON a)
    => Bot -> String -> [(Text, Text)] -> IO (Either String a)
apiCall Bot{manager, token} method params = do
    req0 <-
        parseRequest $
            "https://api.telegram.org/bot"
                <> T.unpack token
                <> "/"
                <> method
    let req =
            urlEncodedBody
                [(TE.encodeUtf8 k, TE.encodeUtf8 v) | (k, v) <- params]
                req0{responseTimeout = responseTimeoutMicro 90_000_000}
    resp <- httpLbs req manager
    pure $ decodeResult (responseBody resp)

decodeResult :: (FromJSON a) => BL.ByteString -> Either String a
decodeResult body = do
    envelope <- eitherDecode body
    flip parseEither envelope $ withObject "envelope" $ \o -> do
        ok <- o .: "ok"
        if ok
            then o .: "result"
            else do
                desc <-
                    fromMaybe "unknown error" <$> o .:? "description"
                fail $ T.unpack desc

-- | Long-poll for updates. @offset@ acknowledges everything before it.
getUpdates
    :: Bot -> Int -> Maybe Integer -> IO (Either String [Incoming])
getUpdates bot timeout offset =
    apiCall bot "getUpdates" $
        [("timeout", T.pack $ show timeout)]
            <> maybe [] (\o -> [("offset", T.pack $ show o)]) offset

{- | Send a message, returning its @message_id@ (used for reply
routing). @thread@ targets a forum topic; @parseMode@ is e.g.
@Markdown@.
-}
sendMessage
    :: Bot
    -> Text
    -- ^ chat id
    -> Maybe Integer
    -- ^ forum topic thread id
    -> Maybe Text
    -- ^ parse mode
    -> Text
    -- ^ text (caller enforces the 4096-char Telegram limit)
    -> IO (Either String Integer)
sendMessage bot chat thread parseMode text = do
    r <-
        apiCall bot "sendMessage" $
            [("chat_id", chat), ("text", text)]
                <> maybe
                    []
                    (\t -> [("message_thread_id", T.pack $ show t)])
                    thread
                <> maybe [] (\p -> [("parse_mode", p)]) parseMode
    pure $ r >>= parseEither (withObject "Message" (.: "message_id"))

-- | The bot's username, to greet the operator during setup.
getMe :: Bot -> IO (Either String Text)
getMe bot = do
    r <- apiCall bot "getMe" []
    pure $ r >>= parseEither (withObject "User" (.: "username"))

-- | Resolve a voice note's @file_id@ and download its bytes.
downloadVoice :: Bot -> Text -> IO (Either String BL.ByteString)
downloadVoice bot@Bot{manager, token} fileId = do
    r <- apiCall bot "getFile" [("file_id", fileId)]
    case r >>= parseEither (withObject "File" (.: "file_path")) of
        Left e -> pure $ Left e
        Right (fp :: Text) -> do
            req <-
                parseRequest $
                    "https://api.telegram.org/file/bot"
                        <> T.unpack token
                        <> "/"
                        <> T.unpack fp
            resp <- httpLbs req manager
            pure $ Right $ responseBody resp

-- | Create a named topic; returns its thread id.
createForumTopic :: Bot -> Text -> Text -> IO (Either String Integer)
createForumTopic bot chat name = do
    r <-
        apiCall
            bot
            "createForumTopic"
            [("chat_id", chat), ("name", name)]
    pure $
        r
            >>= parseEither
                (withObject "ForumTopic" (.: "message_thread_id"))

-- | Close a topic (kept and reopenable — ephemeral channel semantics).
closeForumTopic :: Bot -> Text -> Integer -> IO (Either String Value)
closeForumTopic bot chat thread =
    apiCall
        bot
        "closeForumTopic"
        [("chat_id", chat), ("message_thread_id", T.pack $ show thread)]

-- | Reopen a previously closed topic.
reopenForumTopic :: Bot -> Text -> Integer -> IO (Either String Value)
reopenForumTopic bot chat thread =
    apiCall
        bot
        "reopenForumTopic"
        [("chat_id", chat), ("message_thread_id", T.pack $ show thread)]

-- | POST audio bytes to a whisper-server @/transcribe@ endpoint.
transcribe
    :: Manager -> Text -> BL.ByteString -> IO (Either String Text)
transcribe mgr url audio = do
    req0 <- parseRequest $ T.unpack url
    req <-
        formDataBody
            [ partFileRequestBody "audio" "audio.oga" $
                RequestBodyBS (BL.toStrict audio)
            ]
            req0{responseTimeout = responseTimeoutMicro 120_000_000}
    resp <- httpLbs req mgr
    pure $ do
        envelope <- eitherDecode (responseBody resp)
        t <-
            parseEither
                (withObject "Transcription" (.: "text"))
                (envelope :: Value)
        if T.null (T.strip t)
            then Left "empty transcription"
            else Right (T.strip t)
