module Share.Postgres.Definitions.LocalReferences
  ( LocalReferenceError (..),
    lookupLocalReference,
    validateLocalReferenceMappings,
    validateParallelLocalReferenceMappings,
  )
where

import Data.Int (Int32)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Vector qualified as Vector

data LocalReferenceError
  = MissingLocalReference Text Text Integer Int
  | NonContiguousLocalReference Text Integer Integer
  | MismatchedLocalReferenceMappings Text Int Int
  deriving stock (Eq)

instance Show LocalReferenceError where
  show = \case
    MissingLocalReference context referenceKind localIndex vectorSize ->
      "Missing local "
        <> Text.unpack referenceKind
        <> " reference at index "
        <> show localIndex
        <> " while resolving "
        <> Text.unpack context
        <> " (lookup vector size "
        <> show vectorSize
        <> ")"
    NonContiguousLocalReference context expectedIndex actualIndex ->
      "Non-contiguous local reference indices for "
        <> Text.unpack context
        <> ": expected "
        <> show expectedIndex
        <> ", got "
        <> show actualIndex
    MismatchedLocalReferenceMappings context indices values ->
      "Mismatched local reference index/value counts for "
        <> Text.unpack context
        <> ": "
        <> show indices
        <> " indices, "
        <> show values
        <> " values"

lookupLocalReference :: (Integral i) => Text -> Text -> i -> Vector.Vector a -> Either LocalReferenceError a
lookupLocalReference context referenceKind localIndex values =
  if indexInteger < 0 || indexInteger > toInteger (maxBound :: Int)
    then missing
    else case (Vector.!?) values (fromInteger indexInteger) of
      Just value -> Right value
      Nothing -> missing
  where
    indexInteger = toInteger localIndex
    missing = Left $ MissingLocalReference context referenceKind indexInteger (Vector.length values)

validateLocalReferenceMappings :: Text -> [(Int32, a)] -> Either LocalReferenceError [a]
validateLocalReferenceMappings context = go 0
  where
    go _ [] = Right []
    go expected ((actual, value) : rest)
      | toInteger actual == expected = (value :) <$> go (expected + 1) rest
      | otherwise = Left $ NonContiguousLocalReference context expected (toInteger actual)

validateParallelLocalReferenceMappings :: Text -> [Int32] -> [a] -> Either LocalReferenceError [a]
validateParallelLocalReferenceMappings context indices values
  | length indices /= length values =
      Left $ MismatchedLocalReferenceMappings context (length indices) (length values)
  | otherwise = validateLocalReferenceMappings context (zip indices values)
