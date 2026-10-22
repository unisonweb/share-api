module Share.Postgres.Definitions.LocalReferences
  ( LocalReferenceError (..),
    lookupLocalReference,
    validateLocalReferenceMappings,
    validateParallelLocalReferenceMappings,
  )
where

import Data.Int (Int32)
import Data.Text (Text)
import Data.Vector qualified as Vector

data LocalReferenceError
  = MissingLocalReference
      { context :: Text,
        referenceKind :: Text,
        index :: Integer,
        lookupSize :: Int
      }
  | NonContiguousLocalReference
      { context :: Text,
        expectedIndex :: Integer,
        actualIndex :: Integer
      }
  | MismatchedLocalReferenceMappings
      { context :: Text,
        indexCount :: Int,
        valueCount :: Int
      }
  deriving stock (Eq, Show)

lookupLocalReference :: (Integral i) => Text -> Text -> i -> Vector.Vector a -> Either LocalReferenceError a
lookupLocalReference context referenceKind localIndex values =
  case Vector.!? values index of
    Just value -> Right value
    Nothing -> Left MissingLocalReference {context, referenceKind, index = indexInteger, lookupSize = Vector.length values}
  where
    indexInteger = toInteger localIndex
    index = fromInteger indexInteger

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
      Left $
        MismatchedLocalReferenceMappings
          { context,
            indexCount = length indices,
            valueCount = length values
          }
  | otherwise = validateLocalReferenceMappings context (zip indices values)
