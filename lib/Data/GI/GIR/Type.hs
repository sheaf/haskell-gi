{-# LANGUAGE CPP #-}
{-# LANGUAGE RecordWildCards, PatternGuards #-}
-- | Parsing type information from GIR files.
module Data.GI.GIR.Type
    ( parseType
    , queryCType
    , parseCType
    , queryElementCType
    , parseOptionalType
    ) where

#include "HsBaseConfig.h"

import Data.Maybe (catMaybes)
#if !MIN_VERSION_base(4,11,0)
import Data.Monoid ((<>))
#endif
import Data.Text (Text)
import qualified Data.Text as T
import Foreign.Storable (sizeOf)
import Foreign.C (CShort, CUShort, CSize, CTime)
import System.Posix.Types

import Data.GI.GIR.BasicTypes (Type(..), BasicType(..))
import Data.GI.GIR.Parser

-- | Map the given type name to a `BasicType` (defined in
-- Data.GI.GIR.BasicTypes), if possible.
nameToBasicType :: Text -> Maybe BasicType
nameToBasicType "gpointer" = Just TPtr
nameToBasicType "gboolean" = Just TBoolean
nameToBasicType "gchar"    = Just TInt8
nameToBasicType "gint"     = Just TInt
nameToBasicType "guint"    = Just TUInt
nameToBasicType "glong"    = Just TLong
nameToBasicType "gulong"   = Just TULong
nameToBasicType "gint8"    = Just TInt8
nameToBasicType "guint8"   = Just TUInt8
nameToBasicType "gint16"   = Just TInt16
nameToBasicType "guint16"  = Just TUInt16
nameToBasicType "gint32"   = Just TInt32
nameToBasicType "guint32"  = Just TUInt32
nameToBasicType "gint64"   = Just TInt64
nameToBasicType "guint64"  = Just TUInt64
nameToBasicType "gfloat"   = Just TFloat
nameToBasicType "gdouble"  = Just TDouble
nameToBasicType "gunichar" = Just TUniChar
nameToBasicType "GType"    = Just TGType
nameToBasicType "utf8"     = Just TUTF8
nameToBasicType "filename" = Just TFileName
nameToBasicType "gintptr"  = Just TIntPtr
nameToBasicType "guintptr" = Just TUIntPtr
nameToBasicType "gshort"   =
  Just $ intToBasicType "short" (sizeOf (0 :: CShort)) True
nameToBasicType "gushort"  =
  Just $ intToBasicType "ushort" (sizeOf (0 :: CUShort)) False
#if defined(HTYPE_SSIZE_T)
nameToBasicType "gssize"   =
  Just $ intToBasicType "ssize" (sizeOf (0 :: CSsize)) True
#endif
nameToBasicType "gsize"    =
  Just $ intToBasicType "size" (sizeOf (0 :: CSize)) False
nameToBasicType n@"time_t" =
  Just $ intToBasicType n (sizeOf (0 :: CTime)) ((-1 :: CTime) < 0)
#if defined(HTYPE_OFF_T)
nameToBasicType n@"off_t"  =
  Just $ intToBasicType n (sizeOf (0 :: COff)) ((-1 :: COff) < 0)
#endif
#if defined(HTYPE_DEV_T)
nameToBasicType n@"dev_t"  =
  Just $ intToBasicType n (sizeOf (0 :: CDev)) ((-1 :: CDev) < 0)
#endif
#if defined(HTYPE_GID_T)
nameToBasicType n@"gid_t"  =
  Just $ intToBasicType n (sizeOf (0 :: CGid)) ((-1 :: CGid) < 0)
#endif
#if defined(HTYPE_PID_T)
nameToBasicType n@"pid_t"  =
  Just $ intToBasicType n (sizeOf (0 :: CPid)) ((-1 :: CPid) < 0)
#endif
#if defined(HTYPE_SOCKLEN_T)
nameToBasicType n@"socklen_t"  =
  Just $ intToBasicType n (sizeOf (0 :: CSocklen)) ((-1 :: CSocklen) < 0)
#endif
#if defined(HTYPE_UID_T)
nameToBasicType n@"uid_t"  =
  Just $ intToBasicType n (sizeOf (0 :: CUid)) ((-1 :: CUid) < 0)
#endif
nameToBasicType _          = Nothing

-- | Given the size and signedness of a C integer type, return a `BasicType`.
intToBasicType :: Text -> Int -> Bool -> BasicType
intToBasicType _ 2 True    = TInt16
intToBasicType _ 4 True    = TInt32
intToBasicType _ 8 True    = TInt64
intToBasicType _ 2 False   = TUInt16
intToBasicType _ 4 False   = TUInt32
intToBasicType _ 8 False   = TUInt64
intToBasicType name size _ =
  error $ "Unexpected " ++ show name ++ " length: " ++ show size

-- | The different array types.
parseArrayInfo :: Parser Type
parseArrayInfo = queryAttr "name" >>= \case
      Just "GLib.Array" -> TGArray <$> parseType
      Just "GLib.PtrArray" -> TPtrArray <$> parseType
      Just "GLib.ByteArray" -> return TByteArray
      Just other -> parseError $ "Unsupported array type: \"" <> other <> "\""
      Nothing -> parseCArrayType

-- | A C array
parseCArrayType :: Parser Type
parseCArrayType = do
  zeroTerminated <- queryAttr "zero-terminated" >>= \case
                    Just b -> parseBool b
                    Nothing -> return True
  length <- queryAttr "length" >>= \case
            Just l -> parseIntegral l
            Nothing -> return (-1)
  fixedSize <- queryAttr "fixed-size" >>= \case
               Just s -> parseIntegral s
               Nothing -> return (-1)
  elementType <- parseType
  return $ TCArray zeroTerminated fixedSize length elementType

-- | A hash table.
parseHashTable :: Parser Type
parseHashTable = parseTypeElements >>= \case
                 [] -> return $ TGHash (TBasicType TPtr) (TBasicType TPtr)
                 [Just key, Just value] -> return $ TGHash key value
                 other -> parseError $ "Unsupported hash type: "
                                       <> T.pack (show other)

-- | Parse a `GClosure` declaration.
parseClosure :: Parser Type
parseClosure = queryAttr "closure-type" >>= \case
                Just t -> (TGClosure . Just) <$> parseTypeName t
                Nothing -> return $ TGClosure Nothing

-- | For GLists and GSLists there is sometimes no information about
-- the type of the elements. In these cases we report them as
-- pointers.
parseListType :: Parser Type
parseListType = queryType >>= \case
                Just t -> return t
                Nothing -> return (TBasicType TPtr)

-- | A type which is not a BasicType or array.
parseFundamentalType :: Text -> Text -> Parser Type
parseFundamentalType "GLib" "List" = TGList <$> parseListType
parseFundamentalType "GLib" "SList" = TGSList <$> parseListType
parseFundamentalType "GLib" "HashTable" = parseHashTable
parseFundamentalType "GLib" "Error" = return TError
parseFundamentalType "GLib" "Variant" = return TVariant
parseFundamentalType "GObject" "ParamSpec" = return TParamSpec
parseFundamentalType "GObject" "Value" = return TGValue
parseFundamentalType "GObject" "Closure" = parseClosure
-- A TInterface type (basically, everything that is not of a known type).
parseFundamentalType ns n = resolveQualifiedTypeName (Name ns n)

-- | Parse a type given as a string.
parseTypeName :: Text -> Parser Type
parseTypeName typeName = case nameToBasicType typeName of
    Just b -> return (TBasicType b)
    Nothing -> case T.split ('.' ==) typeName of
                 [ns, n] -> parseFundamentalType ns n
                 [n] -> do
                   ns <- currentNamespace
                   parseFundamentalType ns n
                 _ -> parseError $ "Unsupported type form: \""
                                   <> typeName <> "\""

-- | Parse information on a "type" element. Returns either a `Type`,
-- or `Nothing` indicating that the name of the type in the
-- introspection data was "none" (associated with @void@ in C).
parseTypeInfo :: Parser (Maybe Type)
parseTypeInfo = do
  typeName <- getAttr "name"
  if typeName == "none"
  then return Nothing
  else Just <$> parseTypeName typeName

-- | Find the children giving the type of the given element.
parseTypeElements :: Parser [Maybe Type]
parseTypeElements = do
  types <- parseChildrenWithLocalName "type" parseTypeInfo
  arrays <- parseChildrenWithLocalName "array" parseArrayInfo
  return (types ++ map Just arrays)

-- | Find the C name for the current element.
queryCType :: Parser (Maybe Text)
queryCType = queryAttrWithNamespace CGIRNS "type"

-- | Parse the C type for the current node.
parseCType :: Parser Text
parseCType = getAttrWithNamespace CGIRNS "type"

-- | Find the children giving the C type for the element.
parseCTypeNameElements :: Parser [Text]
parseCTypeNameElements = do
  types <- parseChildrenWithLocalName "type" queryCType
  arrays <- parseChildrenWithLocalName "array" queryCType
  return (catMaybes (types ++ arrays))

-- | Try to find a type node, but do not error out if it is not
-- found. This _does_ give an error if more than one type node is
-- found, or if the type name is "none".
queryType :: Parser (Maybe Type)
queryType = parseTypeElements >>= \case
            [Just e] -> return (Just e)
            [] -> return Nothing
            [Nothing] -> parseError $ "Unexpected \"none\" type."
            _ -> parseError $ "Found more than one type for the element."

-- | Parse the type of a node (which will be described by a child node
-- named "type" or "array").
parseType :: Parser Type
parseType = parseTypeElements >>= \case
            [Just e] -> return e
            [] -> parseError $ "Did not find a type for the element."
            [Nothing] -> parseError $ "Unexpected \"none\" type."
            _ -> parseError $ "Found more than one type for the element."

-- | Like `parseType`, but allow for @none@, returned as `Nothing`.
parseOptionalType :: Parser (Maybe Type)
parseOptionalType =
    parseTypeElements >>= \case
           [e] -> return e
           [] -> parseError $ "Did not find a type for the element."
           _ -> parseError $ "Found more than one type for the element."

-- | Parse the C-type associated to the element, if found.
queryElementCType :: Parser (Maybe Text)
queryElementCType = parseCTypeNameElements >>= \case
             [ctype] -> return (Just ctype)
             [] -> return Nothing
             _ -> parseError $ "Found more than one type for the element."
