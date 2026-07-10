module Sideband.Route
    ( Route (..)
    , RoutingTable (..)
    , routeIncoming
    , stripTagPrefix
    ) where

-- \|
-- Module      : Sideband.Route
-- Description : Pure inbound routing decisions
-- Copyright   : (c) Paolo Veronelli, 2026
-- License     : MIT
--
-- Given the static routing table (configured chats, open topics, sent
-- message registry, known tags), decide which agent inbox an incoming
-- message belongs to. Pure so the whole decision matrix is unit-testable.
--
-- Routing precedence:
--
-- 1. Messages in a known forum topic go to that topic's tag; unknown
--    topics are dropped.
-- 2. Group messages outside any topic (General) broadcast to all tags.
-- 3. Private-chat replies to a registered sent message go to its tag.
-- 4. Private-chat @tag: text@ prefixes go to that tag, prefix stripped.
-- 5. Anything else broadcasts.
-- 6. Messages from unknown chats are dropped (and logged for discovery).

import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Sideband.Telegram (IncomingMsg (..))

-- | Where an inbound message should land.
data Route
    = -- | deliver this text to one tag's inbox
      ToTag Text Text
    | -- | deliver this text to every registered tag
      Broadcast Text
    | -- | ignore, with a reason for the daemon log
      Dropped Text
    deriving (Show, Eq)

-- | The state routing decisions are made against.
data RoutingTable = RoutingTable
    { rtChat :: Text
    -- ^ the operator's private chat id
    , rtGroup :: Maybe Text
    -- ^ the forum supergroup id, when configured
    , rtTopics :: [(Integer, Text)]
    -- ^ open topic thread id → tag
    , rtSent :: [(Integer, Text)]
    -- ^ sent message id → tag (reply routing)
    , rtTags :: [Text]
    -- ^ registered tags (prefix routing)
    }
    deriving (Show, Eq)

-- | Decide the route for one already-textualised message.
routeIncoming :: RoutingTable -> IncomingMsg -> Text -> Route
routeIncoming RoutingTable{..} IncomingMsg{..} text
    | chatIs rtGroup =
        case (msgIsTopic, msgThread) of
            (True, Just thread) ->
                case lookup thread rtTopics of
                    Just tag -> ToTag tag text
                    Nothing ->
                        Dropped $
                            "message in unknown topic "
                                <> T.pack (show thread)
            _ -> Broadcast text
    | T.pack (show msgChat) == rtChat =
        case replyTag of
            Just tag -> ToTag tag text
            Nothing -> case stripTagPrefix rtTags text of
                Just (tag, rest) -> ToTag tag rest
                Nothing -> Broadcast text
    | otherwise =
        Dropped $
            "message from unknown chat "
                <> T.pack (show msgChat)
  where
    chatIs (Just g) = T.pack (show msgChat) == g
    chatIs Nothing = False
    replyTag = msgReplyTo >>= (`lookup` rtSent)

{- | Recognise a leading @tag: rest@ (or @\@tag: rest@) addressed to a
registered tag. Unregistered prefixes are left untouched so ordinary
sentences with colons broadcast intact.
-}
stripTagPrefix :: [Text] -> Text -> Maybe (Text, Text)
stripTagPrefix tags text = do
    let bare = fromMaybe text (T.stripPrefix "@" text)
    (candidate, rest) <- pure $ T.breakOn ":" bare
    _ <- T.stripPrefix ":" rest
    let tag = T.strip candidate
    if tag `elem` tags
        then Just (tag, T.strip $ T.drop 1 rest)
        else Nothing
