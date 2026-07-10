module Sideband.ConfigSpec (spec) where

-- \|
-- Module      : Sideband.ConfigSpec
-- Description : Env-file parsing semantics
-- Copyright   : (c) Paolo Veronelli, 2026
-- License     : MIT

import Sideband.Config (lookupKey, parseEnvFile)
import Test.Hspec (Spec, describe, it, shouldBe)

spec :: Spec
spec = describe "parseEnvFile" $ do
    it "parses KEY=value lines" $ do
        parseEnvFile "A=1\nB=two"
            `shouldBe` [("A", "1"), ("B", "two")]
    it "ignores comments and blanks" $ do
        parseEnvFile "# comment\n\nA=1"
            `shouldBe` [("A", "1")]
    it "strips one level of double quotes" $ do
        parseEnvFile "A=\"quoted\"" `shouldBe` [("A", "quoted")]
    it "keeps equals signs inside values" $ do
        parseEnvFile "A=x=y" `shouldBe` [("A", "x=y")]
    it "last occurrence wins on lookup" $ do
        lookupKey (parseEnvFile "A=1\nA=2") "A"
            `shouldBe` Just "2"
    it "empty values count as missing" $ do
        lookupKey (parseEnvFile "A=") "A" `shouldBe` Nothing
