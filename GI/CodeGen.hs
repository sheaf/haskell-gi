module GI.CodeGen
    ( genConstant
    , genFunction
    , genPrelude
    , genModule
    ) where

#if !MIN_VERSION_base(4,8,0)
import Control.Applicative ((<$>))
#endif
import Control.Monad (forM, forM_, when, unless, filterM)
import Control.Monad.Writer (tell)
import Data.List (intercalate)
import Data.Tuple (swap)
import Data.Maybe (fromJust, fromMaybe)
import qualified Data.Map as M
import qualified Data.Set as S

import Foreign.Storable (sizeOf)
import Foreign.C (CUInt)

import GI.API
import GI.Callable (genCallable)
import GI.Constant (genConstant)
import GI.Code
import GI.GObject
import GI.Signal (genSignal, genCallback)
import GI.Struct (genStructFields, extractCallbacksInStruct, fixAPIStructs,
                  ignoreStruct)
import GI.SymbolNaming (upperName, ucFirst, classConstraint, noName)
import GI.Type
import GI.Internal.ArgInfo
import GI.Internal.FunctionInfo
import GI.Internal.TypeInfo

genFunction :: Name -> Function -> CodeGen ()
genFunction n (Function symbol callable flags) = do
  line $ "-- function " ++ symbol
  handleCGExc (\e -> line ("-- XXX Could not generate function " ++ symbol
                           ++ "\n-- Error was : " ++ describeCGError e))
              (genCallable n symbol callable (FunctionThrows `elem` flags))

genBoxedObject :: Name -> String -> CodeGen ()
genBoxedObject n typeInit = do
  name' <- upperName n

  group $ do
    line $ "foreign import ccall \"" ++ typeInit ++ "\" c_" ++
            typeInit ++ " :: "
    indent $ line "IO GType"
  group $ do
       line $ "instance BoxedObject " ++ name' ++ " where"
       indent $ line $ "boxedType _ = c_" ++ typeInit

genBoxedEnum :: Name -> String -> CodeGen ()
genBoxedEnum n typeInit = do
  name' <- upperName n

  group $ do
    line $ "foreign import ccall \"" ++ typeInit ++ "\" c_" ++
            typeInit ++ " :: "
    indent $ line "IO GType"
  group $ do
       line $ "instance BoxedEnum " ++ name' ++ " where"
       indent $ line $ "boxedEnumType _ = c_" ++ typeInit

genEnumOrFlags :: Name -> Enumeration -> ExcCodeGen ()
genEnumOrFlags n@(Name ns name) (Enumeration fields eDomain maybeTypeInit storage) = do
  -- Conversion functions expect enums and flags to map to CUInt,
  -- which we assume to be of 32 bits. Fail early, instead of giving
  -- strange errors at runtime.
  when (sizeOf (0 :: CUInt) /= 4) $
       notImplementedError $ "Unsupported CUInt size: " ++ show (sizeOf (0 :: CUInt))
  when (storage /= TypeTagInt32 && storage /= TypeTagUint32) $
       notImplementedError $ "Storage of size /= 32 not supported : " ++ show storage

  name' <- upperName n
  fields' <- forM fields $ \(fieldName, value) -> do
      n <- upperName $ Name ns (name ++ "_" ++ fieldName)
      return (n, value)
  group $ do
    line $ "data " ++ name' ++ " = "
    indent $
      case fields' of
        ((fieldName, _value):fs) -> do
          line $ "  " ++ fieldName
          forM_ fs $ \(n, _) -> line $ "| " ++ n
          line $ "| Another" ++ name' ++ " Int"
          line "deriving (Show, Eq)"
        _ -> return ()
  group $ do
    line $ "instance Enum " ++ name' ++ " where"
    indent $ do
            forM_ fields' $ \(n, v) ->
                line $ "fromEnum " ++ n ++ " = " ++ show v
            line $ "fromEnum (Another" ++ name' ++ " k) = k"
    let valueNames = M.toList . M.fromListWith (curry snd) $ map swap fields'
    blank
    indent $ do
            forM_ valueNames $ \(v, n) ->
                line $ "toEnum " ++ show v ++ " = " ++ n
            line $ "toEnum k = Another" ++ name' ++ " k"
  maybe (return ()) (genErrorDomain name') eDomain
  maybe (return ()) (genBoxedEnum n) maybeTypeInit

genEnum :: Name -> Enumeration -> CodeGen ()
genEnum n@(Name _ name) enum = do
  line $ "-- Enum " ++ name

  handleCGExc (\e -> line $ "-- XXX Could not generate: " ++ describeCGError e)
              (genEnumOrFlags n enum)

-- Very similar to enums, but we also declare ourselves as members of
-- the IsGFlag typeclass.
genFlags :: Name -> Flags -> CodeGen ()
genFlags n@(Name _ name) (Flags enum) = do
  line $ "-- Flags " ++ name

  handleCGExc (\e -> line $ "-- XXX Could not generate: " ++ describeCGError e)
              (do
                genEnumOrFlags n enum

                name' <- upperName n
                group $ line $ "instance IsGFlag " ++ name')

genErrorDomain :: String -> String -> CodeGen ()
genErrorDomain name' domain = do
  group $ do
    line $ "instance GErrorClass " ++ name' ++ " where"
    indent $ line $
               "gerrorClassDomain _ = \"" ++ domain ++ "\""
  -- Generate type specific error handling (saves a bit of typing, and
  -- it's clearer to read).
  group $ do
    let catcher = "catch" ++ name'
    line $ catcher ++ " ::"
    indent $ do
            line   "IO a ->"
            line $ "(" ++ name' ++ " -> GErrorMessage -> IO a) ->"
            line   "IO a"
    line $ catcher ++ " = catchGErrorJustDomain"
  group $ do
    let handler = "handle" ++ name'
    line $ handler ++ " ::"
    indent $ do
            line $ "(" ++ name' ++ " -> GErrorMessage -> IO a) ->"
            line   "IO a ->"
            line   "IO a"
    line $ handler ++ " = handleGErrorJustDomain"

genStruct :: Name -> Struct -> CodeGen ()
genStruct n s = unless (ignoreStruct n s) $ do
      name' <- upperName n
      line $ "-- struct " ++ name'

      line $ "newtype " ++ name' ++ " = " ++ name' ++ " (ForeignPtr " ++ name' ++ ")"

      noName name'

      when (structIsBoxed s) $
           genBoxedObject n (fromJust $ structTypeInit s)

      -- Generate code for fields.
      genStructFields n s

      -- Methods
      forM_ (structMethods s) $ \(mn, f) ->
          do isFunction <- symbolFromFunction (fnSymbol f)
             unless isFunction $
                  handleCGExc
                  (\e -> line ("-- XXX Could not generate method "
                               ++ name' ++ "::" ++ name mn ++ "\n"
                               ++ "-- Error was : " ++ describeCGError e))
                  (genMethod n mn f)

genUnion :: Name -> Union -> CodeGen ()
genUnion n u = do
  name' <- upperName n

  line $ "-- union " ++ name' ++ " "

  line $ "newtype " ++ name' ++ " = " ++ name' ++ " (ForeignPtr " ++ name' ++ ")"

  noName name'

  when (unionIsBoxed u) $
    genBoxedObject n (fromJust $ unionTypeInit u)

  -- XXX Fields

  -- Methods
  forM_ (unionMethods u) $ \(mn, f) ->
      do isFunction <- symbolFromFunction (fnSymbol f)
         unless isFunction $
              handleCGExc
              (\e -> line ("-- XXX Could not generate method "
                           ++ name' ++ "::" ++ name mn ++ "\n"
                           ++ "-- Error was : " ++ describeCGError e))
              (genMethod n mn f)

-- Add the implicit object argument to methods of an object.  Since we
-- are prepending an argument we need to adjust the offset of the
-- length arguments of CArrays, and closure and destroyer offsets.
fixMethodArgs :: Name -> Callable -> Callable
fixMethodArgs cn c = c {  args = args' , returnType = returnType' }
    where
      returnType' = fixCArrayLength $ returnType c
      args' = objArg : map (fixDestroyers . fixClosures . fixLengthArg) (args c)

      fixLengthArg :: Arg -> Arg
      fixLengthArg arg = arg { argType = fixCArrayLength (argType arg)}

      fixCArrayLength :: Type -> Type
      fixCArrayLength (TCArray zt fixed length t) =
          if length > -1
          then TCArray zt fixed (length+1) t
          else TCArray zt fixed length t
      fixCArrayLength t = t

      fixDestroyers :: Arg -> Arg
      fixDestroyers arg = let destroy = argDestroy arg in
                          if destroy > -1
                          then arg {argDestroy = destroy + 1}
                          else arg

      fixClosures :: Arg -> Arg
      fixClosures arg = let closure = argClosure arg in
                        if closure > -1
                        then arg {argClosure = closure + 1}
                        else arg

      objArg = Arg {
                 argName = "_obj",
                 argType = TInterface (namespace cn) (name cn),
                 direction = DirectionIn,
                 mayBeNull = False,
                 argScope = ScopeTypeInvalid,
                 argClosure = -1,
                 argDestroy = -1,
                 transfer = TransferNothing }

-- For constructors we want to return the actual type of the object,
-- rather than a generic superclass (so Gtk.labelNew returns a
-- Gtk.Label, rather than a Gtk.Widget)
fixConstructorReturnType :: Bool -> Name -> Callable -> Callable
fixConstructorReturnType returnsGObject cn c = c { returnType = returnType' }
    where
      returnType' = if returnsGObject then
                        TInterface (namespace cn) (name cn)
                    else
                        returnType c

genMethod :: Name -> Name -> Function -> ExcCodeGen ()
genMethod cn mn (Function {
                    fnSymbol = sym,
                    fnCallable = c,
                    fnFlags = fs }) = do
    name' <- upperName cn
    returnsGObject <- isGObject (returnType c)
    line $ "-- method " ++ name' ++ "::" ++ name mn
    line $ "-- method flags : " ++ show fs
    let -- Mangle the name to namespace it to the class.
        mn' = mn { name = name cn ++ "_" ++ name mn }
    let c'  = if FunctionIsConstructor `elem` fs
              then fixConstructorReturnType returnsGObject cn c
              else c
        c'' = if FunctionIsMethod `elem` fs
              then fixMethodArgs cn c'
              else c'
    genCallable mn' sym c'' (FunctionThrows `elem` fs)

-- Type casting with type checking
genGObjectCasts :: Bool -> Name -> String -> [Name] -> CodeGen ()
genGObjectCasts isIU n cn_ parents = do
  name' <- upperName n
  qualifiedParents <- traverse upperName parents

  group $ do
    line $ "foreign import ccall \"" ++ cn_ ++ "\""
    indent $ line $ "c_" ++ cn_ ++ " :: IO GType"

  group $ do
    line $ "type instance ParentTypes " ++ name' ++ " = '[" ++
         intercalate ", " qualifiedParents ++ "]"

  group $ do
    line $ "instance GObject " ++ name' ++ " where"
    indent $ group $ do
            line $ "gobjectIsInitiallyUnowned _ = " ++ show isIU
            line $ "gobjectType _ = c_" ++ cn_

  let className = classConstraint name'
  group $ do
    line $ "class GObject o => " ++ className ++ " o"
    line $ "instance (GObject o, IsDescendantOf " ++ name' ++ " o) => "
             ++ className ++ " o"

  -- Safe downcasting.
  group $ do
    let safeCast = "to" ++ name'
    line $ safeCast ++ " :: " ++ className ++ " o => o -> IO " ++ name'
    line $ safeCast ++ " = unsafeCastTo " ++ name'

-- Wrap a given Object. We enforce that every Object that we wrap is a
-- GObject. This is the case for everything expect the ParamSpec* set
-- of objects, we deal with these separately. Notice that in the case
-- that a non-GObject Object is passed, it is simply ignored silently
-- by the handler in handleCGExc below.
genObject :: Name -> Object -> CodeGen ()
genObject n o = handleCGExc (\_ -> return ()) $ do
  name' <- upperName n

  line $ "-- object " ++ name' ++ " "

  let t = (\(Name ns' n') -> TInterface ns' n') n
  isGO <- isGObject t
  unless isGO $ notImplementedError $ "APIObject \"" ++ name' ++
           "\" does not descend from GObject, it will be ignored."

  line $ "newtype " ++ name' ++ " = " ++ name' ++ " (ForeignPtr " ++ name' ++ ")"

  noName name'

  -- Type safe casting
  isIU <- isInitiallyUnowned t
  -- Filter out interfaces inherited from the parent GObject. This is
  -- not strictly necessary, but reduces redundancy of the generated
  -- list of ancestor types.
  oIfs <- case objParent o of
            Nothing -> return (objInterfaces o)
            Just p -> do
              parentAPI <- findAPIByName p
              case parentAPI of
                APIObject po ->
                    return $ filter (`notElem` (objInterfaces po))
                               (objInterfaces o)
                _ -> error $ "Parent Object of " ++ name' ++ " not an Object!"
  -- And in case we do have a parent, that goes in the front, so it
  -- gets tried first when doing overloading resolution.
  let parents = maybe oIfs (: oIfs) (objParent o)
  genGObjectCasts isIU n (objTypeInit o) parents

  -- Methods
  forM_ (objMethods o) $ \(mn, f) ->
         handleCGExc
         (\e -> line ("-- XXX Could not generate method "
                      ++ name' ++ "::" ++ name mn ++ "\n"
                      ++ "-- Error was : " ++ describeCGError e))
         (genMethod n mn f)

  -- And finally signals
  forM_ (objSignals o) $ \s ->
      handleCGExc
      (\e -> line ("-- XXX Could not generate signal "
                   ++ name' ++ "::" ++ sigName s ++ "\n"
                   ++ "-- Error was : " ++ describeCGError e))
      (genSignal s n)

genInterface :: Name -> Interface -> CodeGen ()
genInterface n iface = do
  -- For each interface, we generate a class IFoo and a data structure
  -- Foo. We only really need a separate Foo so that we can return
  -- them from bound functions. In principle we might be able to do
  -- something more elegant with existential types.

  name' <- upperName n
  line $ "-- interface " ++ name' ++ " "
  line $ "newtype " ++ name' ++ " = " ++ name' ++ " (ForeignPtr " ++ name' ++ ")"

  noName name'

  isGO <- apiIsGObject n (APIInterface iface)
  if isGO
  then do
    let cn_ = fromMaybe (error "GObject derived interface without a type!") (ifTypeInit iface)
    isIU <- apiIsInitiallyUnowned n (APIInterface iface)
    gobjectInterfaces <- filterM nameIsGObject (ifPrerequisites iface)
    genGObjectCasts isIU n cn_ gobjectInterfaces
  else group $ do
    let cls = classConstraint name'
    line $ "class ForeignPtrNewtype a => " ++ cls ++ " a"
    line $ "instance IsDescendantOf " ++ name' ++ " o => " ++ cls ++ " o"
    line $ "type instance ParentTypes " ++ name' ++ " = '[]"

  -- Methods
  forM_ (ifMethods iface) $ \(mn, f) -> do
    isFunction <- symbolFromFunction (fnSymbol f)
    unless isFunction $
         handleCGExc
         (\e -> line ("-- XXX Could not generate method "
                      ++ name' ++ "::" ++ name mn ++ "\n"
                      ++ "-- Error was : " ++ describeCGError e))
         (genMethod n mn f)

  -- And finally signals
  forM_ (ifSignals iface) $ \s ->
      handleCGExc
      (\e -> line ("-- XXX Could not generate signal "
                   ++ name' ++ "::" ++ sigName s ++ "\n"
                   ++ "-- Error was : " ++ describeCGError e))
      (genSignal s n)

-- Some type libraries include spurious interface/struct methods,
-- where a method Mod.Foo::func also appears as an ordinary function
-- in the list of APIs. If we find a matching function, we don't
-- generate the method.
--
-- It may be more expedient to keep a map of symbol -> function.
symbolFromFunction :: String -> CodeGen Bool
symbolFromFunction sym = do
  apis <- getAPIs
  return $ any (hasSymbol sym . snd) $ M.toList apis
    where
      hasSymbol sym1 (APIFunction (Function { fnSymbol = sym2 })) = sym1 == sym2
      hasSymbol _ _ = False

genAPI :: Name -> API -> CodeGen ()
genAPI n (APIConst c) = genConstant n c
genAPI n (APIFunction f) = genFunction n f
genAPI n (APIEnum e) = genEnum n e
genAPI n (APIFlags f) = genFlags n f
genAPI n (APICallback c) = genCallback n c
genAPI n (APIStruct s) = genStruct n s
genAPI n (APIUnion u) = genUnion n u
genAPI n (APIObject o) = genObject n o
genAPI n (APIInterface i) = genInterface n i
genAPI _ (APIBoxed _) = return ()

genPrelude :: String -> String -> CodeGen ()
genPrelude name modulePrefix = do
    let mp = (modulePrefix ++)

    line "-- Generated code."
    blank
    line "{-# OPTIONS_GHC -fno-warn-unused-imports #-}"
    blank
    line "{-# LANGUAGE ForeignFunctionInterface, ConstraintKinds,"
    line "    TypeFamilies, MultiParamTypeClasses, KindSignatures,"
    line "    FlexibleInstances, UndecidableInstances, DataKinds,"
    line "    OverloadedStrings, NegativeLiterals, FlexibleContexts #-}"
    blank
    -- XXX: Generate export list.
    line $ "module " ++ mp name ++ " where"
    blank
    -- The Prelude functions often clash with variable names or
    -- functions defined in the bindings, so we only import the
    -- necessary minimum into our namespace.
    line "import Prelude ()"
    line "import GI.Utils.ShortPrelude"
    line "import Data.Char"
    line "import Data.Int"
    line "import Data.Word"
    line "import qualified Data.ByteString.Char8 as B"
    line "import Data.ByteString.Char8 (ByteString)"
    line "import qualified Data.Map as Map"
    line "import Foreign.C"
    line "import Foreign.Ptr"
    line "import Foreign.ForeignPtr.Safe"
    line "import Foreign.ForeignPtr.Unsafe (unsafeForeignPtrToPtr)"
    line "import Foreign.Storable (peek, poke, sizeOf)"
    line "import Control.Applicative ((<$>))"
    line "import Control.Exception (onException)"
    line "import qualified Data.Text as T"
    blank
    line "import GI.Utils.Attributes hiding (get, set)"
    line "import GI.Utils.BasicTypes"
    line "import GI.Utils.BasicConversions"
    line "import GI.Utils.Closure"
    line "import GI.Utils.GError"
    line "import GI.Utils.GHashTable"
    line "import GI.Utils.GParamSpec"
    line "import GI.Utils.GVariant"
    line "import GI.Utils.GValue"
    line "import GI.Utils.ManagedPtr"
    line "import GI.Utils.Overloading"
    line "import GI.Utils.Properties hiding (new)"
    line "import GI.Utils.Signals (SignalConnectMode(..), connectSignalFunPtr, SignalHandlerId)"
    line "import GI.Utils.Utils"
    blank

genModule :: String -> [(Name, API)] -> String -> CodeGen ()
genModule name apis modulePrefix = do
  let mp = (modulePrefix ++)
      name' = ucFirst name

  -- Any module depends on itself, load the information onto the state
  -- of the monad. This has to be done early, so symbolFromFunction
  -- above has access to it. It would probably be better to prune the
  -- duplicated method/functions in advance, and get rid of
  -- symbolFromFunction and this loadDependency altogether.
  loadDependency name

  -- Some API symbols are embedded into structures, extract these and
  -- inject them into the set of APIs loaded and being generated.
  let embeddedAPIs = concatMap extractCallbacksInStruct apis
  injectAPIs embeddedAPIs

  code <- recurse' $ mapM_ (uncurry genAPI) $
          -- We provide these ourselves
          filter (not . (== Name "GLib" "Array") . fst) $
          filter (not . (== Name "GLib" "Error") . fst) $
          filter (not . (== Name "GLib" "HashTable") . fst) $
          filter (not . (== Name "GLib" "List") . fst) $
          filter (not . (== Name "GLib" "SList") . fst) $
          filter (not . (== Name "GLib" "Variant") . fst) $
          filter (not . (== Name "GObject" "Value") . fst) $
          filter (not . (== Name "GObject" "Closure") . fst) $
          -- Some callback types are defined inside structs
          map fixAPIStructs $ (++ embeddedAPIs) apis

  genPrelude name' modulePrefix
  deps <- S.toList <$> getDeps
  forM_ deps $ \i -> when (i /= name) $ do
    line $ "import qualified " ++ mp (ucFirst i) ++ " as " ++ ucFirst i
    line $ "import qualified " ++ mp (ucFirst i) ++ "Attributes as "
             ++ ucFirst i ++ "A"
  blank

  tell code
