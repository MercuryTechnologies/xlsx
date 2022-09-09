{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
{-# LANGUAGE DeriveGeneric #-}
module Codec.Xlsx.Types.Internal.CommentTable where

import Data.ByteString.Lazy (ByteString)
import qualified Data.ByteString.Lazy as LB
import qualified Data.ByteString.Lazy.Char8 as LBC8
import Data.List.Extra (nubOrd)
import Data.Map (Map)
import qualified Data.Map as M
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Text.Lazy (toStrict)
import qualified Data.Text.Lazy.Builder as B
import qualified Data.Text.Lazy.Builder.Int as B
import GHC.Generics (Generic)
import Safe
import Text.XML
import Text.XML.Cursor

import Codec.Xlsx.Parser.Internal
import Codec.Xlsx.Types.Comment
import Codec.Xlsx.Types.Common
import Codec.Xlsx.Writer.Internal

newtype CommentTable = CommentTable
    { _commentsTable :: Map CellRef Comment }
    deriving (Eq, Show, Generic)

tshow :: Show a => a -> Text
tshow = Text.pack . show

fromList :: [(CellRef, Comment)] -> CommentTable
fromList = CommentTable . M.fromList

toList :: CommentTable -> [(CellRef, Comment)]
toList = M.toList . _commentsTable

lookupComment :: CellRef -> CommentTable -> Maybe Comment
lookupComment ref = M.lookup ref . _commentsTable

instance ToDocument CommentTable where
  toDocument = documentFromElement "Sheet comments generated by xlsx"
             . toElement "comments"

instance ToElement CommentTable where
  toElement nm (CommentTable m) = Element
      { elementName       = nm
      , elementAttributes = M.empty
      , elementNodes      = [ NodeElement $ elementListSimple "authors" authorNodes
                            , NodeElement . elementListSimple "commentList" $ map commentToEl (M.toList m) ]
      }
    where
      commentToEl (ref, Comment{..}) = Element
          { elementName = "comment"
          , elementAttributes = M.fromList [ ("ref" .= ref)
                                           , ("authorId" .= lookupAuthor _commentAuthor)
                                           , ("visible" .= tshow _commentVisible)]
          , elementNodes      = [NodeElement $ toElement "text" _commentText]
          }
      lookupAuthor a = fromJustNote "author lookup" $ M.lookup a authorIds
      authorNames = nubOrd . map _commentAuthor $ M.elems m
      decimalToText :: Integer -> Text
      decimalToText = toStrict . B.toLazyText . B.decimal
      authorIds = M.fromList $ zip authorNames (map decimalToText [0..])
      authorNodes = map (elementContent "author") authorNames

instance FromCursor CommentTable where
  fromCursor cur = do
    let authorNames = cur $/ element (n_ "authors") &/ element (n_ "author") >=> contentOrEmpty
        authors = M.fromList $ zip [0..] authorNames
        items = cur $/ element (n_ "commentList") &/ element (n_ "comment") >=> parseComment authors
    return . CommentTable $ M.fromList items

parseComment :: Map Int Text -> Cursor -> [(CellRef, Comment)]
parseComment authors cur = do
    ref <- fromAttribute "ref" cur
    txt <- cur $/ element (n_ "text") >=> fromCursor
    authorId <- cur $| attribute "authorId" >=> decimal
    visible <- (read . Text.unpack :: Text -> Bool)
      <$> (fromAttribute "visible" cur :: [Text])
    let author = fromJustNote "authorId" $ M.lookup authorId authors
    return (ref, Comment txt author visible)

-- | helper to render comment baloons vml file,
-- currently uses fixed shape
renderShapes :: CommentTable -> ByteString
renderShapes (CommentTable m) = LB.concat
    [ "<xml xmlns:v=\"urn:schemas-microsoft-com:vml\" "
    , "xmlns:o=\"urn:schemas-microsoft-com:office:office\" "
    , "xmlns:x=\"urn:schemas-microsoft-com:office:excel\">"
    , commentShapeType
    , LB.concat commentShapes
    , "</xml>"
    ]
  where
    commentShapeType = LB.concat
        [ "<v:shapetype id=\"baloon\" coordsize=\"21600,21600\" o:spt=\"202\" "
        , "path=\"m,l,21600r21600,l21600,xe\">"
        , "<v:stroke joinstyle=\"miter\"></v:stroke>"
        , "<v:path gradientshapeok=\"t\" o:connecttype=\"rect\"></v:path>"
        , "</v:shapetype>"
        ]
    fromRef cr =
      fromJustNote ("Invalid comment ref: " <> show cr) $ fromSingleCellRef cr
    commentShapes = [ commentShape (fromRef ref) (_commentVisible cmnt)
                    | (ref, cmnt) <- M.toList m ]
    commentShape (r, c) v = LB.concat
        [ "<v:shape type=\"#baloon\" "
        , "style=\"position:absolute;width:auto" -- ;width:108pt;height:59.25pt"
        , if v then "" else ";visibility:hidden"
        , "\" fillcolor=\"#ffffe1\" o:insetmode=\"auto\">"
        , "<v:fill color2=\"#ffffe1\"></v:fill><v:shadow color=\"black\" obscured=\"t\"></v:shadow>"
        , "<v:path o:connecttype=\"none\"></v:path><v:textbox style=\"mso-direction-alt:auto\">"
        , "<div style=\"text-align:left\"></div></v:textbox>"
        , "<x:ClientData ObjectType=\"Note\">"
        , "<x:MoveWithCells></x:MoveWithCells><x:SizeWithCells></x:SizeWithCells>"
        , "<x:Anchor>4, 15, 0, 7, 6, 31, 5, 1</x:Anchor><x:AutoFill>False</x:AutoFill>"
        , "<x:Row>"
        , LBC8.pack $ show (r - 1)
        , "</x:Row>"
        , "<x:Column>"
        , LBC8.pack $ show (c - 1)
        , "</x:Column>"
        , "</x:ClientData>"
        , "</v:shape>"
        ]
