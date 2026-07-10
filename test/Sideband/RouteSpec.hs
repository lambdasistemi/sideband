module Sideband.RouteSpec (spec) where

-- \|
-- Module      : Sideband.RouteSpec
-- Description : The routing decision matrix
-- Copyright   : (c) Paolo Veronelli, 2026
-- License     : MIT

import Sideband.Route
    ( Route (Broadcast, Dropped, ToTag)
    , RoutingTable (..)
    , routeIncoming
    , stripTagPrefix
    )
import Sideband.Telegram (IncomingMsg (..))
import Test.Hspec (Spec, describe, it, shouldBe)

table :: RoutingTable
table =
    RoutingTable
        { rtChat = "111"
        , rtGroup = Just "-100999"
        , rtTopics = [(5, "keri-e21"), (3, "assistant")]
        , rtSent = [(17, "keri-e21")]
        , rtTags = ["keri-e21", "assistant"]
        }

msg :: IncomingMsg
msg =
    IncomingMsg
        { msgId = 1
        , msgChat = 111
        , msgChatType = "private"
        , msgChatTitle = Nothing
        , msgText = Just "hello"
        , msgThread = Nothing
        , msgIsTopic = False
        , msgReplyTo = Nothing
        , msgVoice = Nothing
        }

spec :: Spec
spec = do
    describe "routeIncoming" $ do
        it "routes a topic message to the topic's tag" $ do
            let m =
                    msg
                        { msgChat = -100999
                        , msgThread = Just 5
                        , msgIsTopic = True
                        }
            routeIncoming table m "hello"
                `shouldBe` ToTag "keri-e21" "hello"
        it "drops messages in unknown topics" $ do
            let m =
                    msg
                        { msgChat = -100999
                        , msgThread = Just 42
                        , msgIsTopic = True
                        }
            routeIncoming table m "hello"
                `shouldBe` Dropped "message in unknown topic 42"
        it "broadcasts General (non-topic) group messages" $ do
            let m = msg{msgChat = -100999}
            routeIncoming table m "hello" `shouldBe` Broadcast "hello"
        it "ignores reply-thread ids outside forum topics" $ do
            -- replies in General carry a thread id but not
            -- is_topic_message; they must broadcast, not misroute
            let m = msg{msgChat = -100999, msgThread = Just 17}
            routeIncoming table m "hello" `shouldBe` Broadcast "hello"
        it "routes private replies via the sent registry" $ do
            let m = msg{msgReplyTo = Just 17}
            routeIncoming table m "yes"
                `shouldBe` ToTag "keri-e21" "yes"
        it "routes private tag prefixes and strips them" $ do
            routeIncoming table msg "assistant: do the thing"
                `shouldBe` ToTag "assistant" "do the thing"
        it "broadcasts unaddressed private messages" $ do
            routeIncoming table msg "It's confusing"
                `shouldBe` Broadcast "It's confusing"
        it "drops unknown chats" $ do
            let m = msg{msgChat = 42}
            routeIncoming table m "hi"
                `shouldBe` Dropped "message from unknown chat 42"

    describe "stripTagPrefix" $ do
        it "matches registered tags only" $ do
            stripTagPrefix ["a", "b"] "c: hello" `shouldBe` Nothing
        it "strips @-mentions too" $ do
            stripTagPrefix ["a"] "@a: hello"
                `shouldBe` Just ("a", "hello")
        it "leaves ordinary colon sentences alone" $ do
            stripTagPrefix
                ["keri-e21"]
                "note: the build is green"
                `shouldBe` Nothing
