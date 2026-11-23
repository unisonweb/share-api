module Main (main) where

import Data.Vector qualified as Vector
import Share.Postgres.Definitions.LocalReferences

main :: IO ()
main = do
  assertEqual
    "out-of-range lookup reports index and vector size"
    (Left $ MissingLocalReference "term id 1" "hash" 2 2)
    (lookupLocalReference "term id 1" "hash" 2 (Vector.fromList ["first", "second"]))
  assertEqual
    "gapped persisted indices are rejected"
    (Left $ NonContiguousLocalReference "term id 1" 1 2)
    (validateLocalReferenceMappings "term id 1" [(0, "first"), (2, "third")])
  assertEqual
    "valid component local references are preserved"
    (Right ["first", "second"])
    (validateParallelLocalReferenceMappings "term id 1" [0, 1] ["first", "second"])

assertEqual :: (Eq a, Show a) => String -> a -> a -> IO ()
assertEqual label expected actual
  | expected == actual = pure ()
  | otherwise = fail $ label <> ": expected " <> show expected <> ", got " <> show actual
