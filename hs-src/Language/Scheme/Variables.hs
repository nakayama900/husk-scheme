{- |
Module      : Language.Scheme.Variables
Copyright   : Justin Ethier
Licence     : MIT (see LICENSE in the distribution)

Maintainer  : github.com/justinethier
Stability   : experimental
Portability : portable

This module contains code for working with Scheme variables,
and the environments that contain them.

-}

module Language.Scheme.Variables 
    (
    -- * Environments
      printEnv
    , copyEnv
    , extendEnv
    , findNamespacedEnv
    -- * Getters
    , getVar
    , getNamespacedVar 
    -- * Setters
    , defineVar
    , setVar
    , setNamespacedVar
    , defineNamespacedVar
    -- * Predicates
    , isBound
    , isRecBound
    , isNamespacedBound
    , isNamespacedRecBound 
    -- * Pointers
    , derefPtr
    , recDerefPtrs
    ) where
import Language.Scheme.Types
import Control.Monad.Error
import Data.Array
import Data.IORef
import qualified Data.Map
-- import Debug.Trace

-- |Return a value with a pointer dereferenced, if necessary
derefPtr :: LispVal -> IOThrowsError LispVal
-- TODO: try dereferencing again if a ptr is found??
derefPtr (Pointer p env) = getVar env p
derefPtr v = return v

-- |Recursively process the given data structure, dereferencing
--  any pointers found along the way
recDerefPtrs :: LispVal -> IOThrowsError LispVal
recDerefPtrs (List l) = do
    result <- mapM recDerefPtrs l
    return $ List result
recDerefPtrs (DottedList ls l) = do
    ds <- mapM recDerefPtrs ls
    d <- recDerefPtrs l
    return $ DottedList ds d
recDerefPtrs (Vector v) = do
    let vs = elems v
    ds <- mapM recDerefPtrs vs
    return $ Vector $ listArray (0, length vs - 1) ds

-- TODO: need to walk HashTable, anything else?
recDerefPtrs p = derefPtr p

-- |Determine if given lisp value is an "object" that
--  can be pointed to.
isObject :: LispVal -> Bool
isObject (List _) = True
isObject (DottedList _ _) = True
isObject (String _) = True
isObject (Vector _) = True
isObject (HashTable _) = True
isObject (Pointer _ _) = True
isObject _ = False

{- Experimental code:
-- From: http://rafaelbarreto.com/2011/08/21/comparing-objects-by-memory-location-in-haskell/
import Foreign
isMemoryEquivalent :: a -> a -> IO Bool
isMemoryEquivalent obj1 obj2 = do
  obj1Ptr <- newStablePtr obj1
  obj2Ptr <- newStablePtr obj2
  let result = obj1Ptr == obj2Ptr
  freeStablePtr obj1Ptr
  freeStablePtr obj2Ptr
  return result

-- Using above, search an env for a variable definition, but stop if the upperEnv is
-- reached before the variable
isNamespacedRecBoundWUpper :: Env -> Env -> String -> String -> IO Bool
isNamespacedRecBoundWUpper upperEnvRef envRef namespace var = do 
  areEnvsEqual <- liftIO $ isMemoryEquivalent upperEnvRef envRef
  if areEnvsEqual
     then return False
     else do
         found <- liftIO $ isNamespacedBound envRef namespace var
         if found
            then return True 
            else case parentEnv envRef of
                      (Just par) -> isNamespacedRecBoundWUpper upperEnvRef par namespace var
                      Nothing -> return False -- Var never found
-}

-- |Show the contents of an environment
printEnv :: Env         -- ^Environment
         -> IO String   -- ^Contents of the env as a string
printEnv env = do
  binds <- liftIO $ readIORef $ bindings env
  l <- mapM showVar $ Data.Map.toList binds 
  return $ unlines l
 where 
  showVar ((_, name), val) = do
    v <- liftIO $ readIORef val
    return $ name ++ ": " ++ show v

-- |Create a deep copy of an environment
copyEnv :: Env      -- ^ Source environment
        -> IO Env   -- ^ A copy of the source environment
copyEnv env = do
  ptrs <- liftIO $ readIORef $ pointers env
  ptrList <- newIORef ptrs

  binds <- liftIO $ readIORef $ bindings env
  bindingListT <- mapM addBinding $ Data.Map.toList binds 
  bindingList <- newIORef $ Data.Map.fromList bindingListT
  return $ Environment (parentEnv env) bindingList ptrList
 where addBinding ((namespace, name), val) = do 
         x <- liftIO $ readIORef val
         ref <- newIORef x
         return ((namespace, name), ref)

-- |Extend given environment by binding a series of values to a new environment.
extendEnv :: Env -- ^ Environment 
          -> [((String, String), LispVal)] -- ^ Extensions to the environment
          -> IO Env -- ^ Extended environment
extendEnv envRef abindings = do 
  bindinglistT <- (mapM addBinding abindings) -- >>= newIORef
  bindinglist <- newIORef $ Data.Map.fromList bindinglistT
  nullPointers <- newIORef $ Data.Map.fromList []
  return $ Environment (Just envRef) bindinglist nullPointers
 where addBinding ((namespace, name), val) = do ref <- newIORef val
                                                return ((namespace, name), ref)

-- |Recursively search environments to find one that contains the given variable.
findNamespacedEnv 
    :: Env      -- ^Environment to begin the search; 
                --  parent env's will be searched as well.
    -> String   -- ^Namespace
    -> String   -- ^Variable
    -> IO (Maybe Env) -- ^Environment, or Nothing if there was no match.
findNamespacedEnv envRef namespace var = do
  found <- liftIO $ isNamespacedBound envRef namespace var
  if found
     then return (Just envRef)
     else case parentEnv envRef of
               (Just par) -> findNamespacedEnv par namespace var
               Nothing -> return Nothing

-- |Determine if a variable is bound in the default namespace
isBound :: Env      -- ^ Environment
        -> String   -- ^ Variable
        -> IO Bool  -- ^ True if the variable is bound
isBound envRef var = isNamespacedBound envRef varNamespace var

-- |Determine if a variable is bound in the default namespace, 
--  in this environment or one of its parents.
isRecBound :: Env      -- ^ Environment
           -> String   -- ^ Variable
           -> IO Bool  -- ^ True if the variable is bound
isRecBound envRef var = isNamespacedRecBound envRef varNamespace var

-- |Determine if a variable is bound in a given namespace
isNamespacedBound 
    :: Env      -- ^ Environment
    -> String   -- ^ Namespace
    -> String   -- ^ Variable
    -> IO Bool  -- ^ True if the variable is bound
isNamespacedBound envRef namespace var = 
    (readIORef $ bindings envRef) >>= return . Data.Map.member (namespace, var)

-- |Determine if a variable is bound in a given namespace
--  or a parent of the given environment.
isNamespacedRecBound 
    :: Env      -- ^ Environment
    -> String   -- ^ Namespace
    -> String   -- ^ Variable
    -> IO Bool  -- ^ True if the variable is bound
isNamespacedRecBound envRef namespace var = do
  env <- findNamespacedEnv envRef namespace var
  case env of
    (Just e) -> isNamespacedBound e namespace var
    Nothing -> return False

-- |Retrieve the value of a variable defined in the default namespace
getVar :: Env       -- ^ Environment
       -> String    -- ^ Variable
       -> IOThrowsError LispVal -- ^ Contents of the variable
getVar envRef var = getNamespacedVar envRef varNamespace var

-- |Retrieve the value of a variable defined in a given namespace
getNamespacedVar :: Env     -- ^ Environment
                 -> String  -- ^ Namespace
                 -> String  -- ^ Variable
                 -> IOThrowsError LispVal -- ^ Contents of the variable
getNamespacedVar envRef
                 namespace
                 var = do binds <- liftIO $ readIORef $ bindings envRef
                          case Data.Map.lookup (namespace, var) binds of
                            (Just a) -> liftIO $ readIORef a
                            Nothing -> case parentEnv envRef of
                                         (Just par) -> getNamespacedVar par namespace var
                                         Nothing -> (throwError $ UnboundVar "Getting an unbound variable" var)


-- |Set a variable in the default namespace
setVar
    :: Env      -- ^ Environment
    -> String   -- ^ Variable
    -> LispVal  -- ^ Value
    -> IOThrowsError LispVal -- ^ Value
setVar envRef var value = setNamespacedVar envRef varNamespace var value

-- |Set a variable in a given namespace
setNamespacedVar 
    :: Env      -- ^ Environment 
    -> String   -- ^ Namespace
    -> String   -- ^ Variable
    -> LispVal  -- ^ Value
    -> IOThrowsError LispVal   -- ^ Value
setNamespacedVar envRef
                 namespace
                 var value = do 
  _ <- updatePointers envRef namespace var 
  _setNamespacedVar envRef namespace var value

-- |An internal function that does the actual setting of a 
--  variable, without all the extra code that keeps pointers
--  in sync.
_setNamespacedVar 
    :: Env      -- ^ Environment 
    -> String   -- ^ Namespace
    -> String   -- ^ Variable
    -> LispVal  -- ^ Value
    -> IOThrowsError LispVal   -- ^ Value
_setNamespacedVar envRef
                 namespace
                 var value = do 
  -- Set the variable to its new value
  env <- liftIO $ readIORef $ bindings envRef
  valueToStore <- getValueToStore namespace var envRef value
  case Data.Map.lookup (namespace, var) env of
    (Just a) -> do
      liftIO $ writeIORef a valueToStore
      return valueToStore
    Nothing -> case parentEnv envRef of
      (Just par) -> setNamespacedVar par namespace var valueToStore
      Nothing -> throwError $ UnboundVar "Setting an unbound variable: " var

-- |This helper function is used to keep pointers in sync when
--  a variable is re-binded to a different value.
updatePointers :: Env -> String -> String -> IOThrowsError LispVal
updatePointers envRef namespace var = do
  ptrs <- liftIO $ readIORef $ pointers envRef
  case Data.Map.lookup (namespace, var) ptrs of
    (Just valIORef) -> do
      val <- liftIO $ readIORef valIORef
      case val of 
  -- TODO:
  -- If var has any pointers, then
  -- need to assign the first pointer to the old value of x, 
  -- and the rest need to be updated to point to that first var
        (Pointer pVar pEnv : ps) -> do
          existingValue <- getNamespacedVar envRef namespace var
          _setNamespacedVar pEnv namespace pVar existingValue
          -- TODO: if existingValue is an object, each ps should point to p
          --       else they should just be set to existingValue
-- TODO:        _ -> ??
    Nothing -> return $ Nil ""

-- |Bind a variable in the default namespace
defineVar
    :: Env      -- ^ Environment
    -> String   -- ^ Variable
    -> LispVal  -- ^ Value
    -> IOThrowsError LispVal -- ^ Value
defineVar envRef var value = defineNamespacedVar envRef varNamespace var value

-- |Bind a variable in the given namespace
defineNamespacedVar
    :: Env      -- ^ Environment 
    -> String   -- ^ Namespace
    -> String   -- ^ Variable
    -> LispVal  -- ^ Value
    -> IOThrowsError LispVal   -- ^ Value
defineNamespacedVar envRef
                    namespace
                    var value = do
  alreadyDefined <- liftIO $ isNamespacedBound envRef namespace var
  if alreadyDefined
    then setNamespacedVar envRef namespace var value >> return value
    else do
  --
  -- TODO: 
  -- Edge case: don't change anything if (define) is to existing pointer
  --  (IE, it does not really change anything)


      -- If we are assigning to a pointer, we need a reverse lookup to 
      -- note that the pointer "value" points to "var"
      -- 
      -- So run through this logic to figure out what exactly to store,
      -- both for bindings and for rev-lookup pointers
      valueToStore <- getValueToStore namespace var envRef value
      liftIO $ do
        -- Write new value binding
        valueRef <- newIORef valueToStore
        env <- readIORef $ bindings envRef
        writeIORef (bindings envRef) (Data.Map.insert (namespace, var) valueRef env)
        return valueToStore

-- |An internal helper function to get the value to save to an env
--  based on the value passed to the define/set function. Normally this
--  is straightforward, but there is book-keeping involved if a
--  pointer is passed, depending on if the pointer resolves to an object.
getValueToStore :: String -> String -> Env -> LispVal -> IOThrowsError LispVal
getValueToStore namespace var env (Pointer p pEnv) = do
  addReversePointer namespace p pEnv namespace var env
getValueToStore _ _ _ value = return value

-- |Accept input for a pointer (ptrVar) and a variable that the pointer is going
--  to be assigned to. If that variable is an object then we setup a reverse lookup
--  for future book-keeping. Otherwise, we just look it up and return it directly, 
--  no booking-keeping required.
addReversePointer :: String -> String -> Env -> String -> String -> Env -> IOThrowsError LispVal
addReversePointer namespace var envRef ptrNamespace ptrVar ptrEnvRef = do
   env <- liftIO $ readIORef $ bindings envRef
   case Data.Map.lookup (namespace, var) env of
     (Just a) -> do
       v <- liftIO $ readIORef a
       if isObject v
          then do
            -- Store a reverse pointer for book keeping
            ptrs <- liftIO $ readIORef $ pointers envRef
            
            -- Lookup ptr for var
            case Data.Map.lookup (namespace, var) ptrs of
               -- Append another reverse ptr to this var
-- TODO: should make sure ptr is not already there, before adding it again
              (Just valueRef) -> liftIO $ do
                value <- readIORef valueRef
                writeIORef valueRef (value ++ [Pointer ptrVar ptrEnvRef])
                return $ Pointer var envRef 

              -- No mapping, add the first reverse pointer
              Nothing -> liftIO $ do
                valueRef <- newIORef [Pointer ptrVar ptrEnvRef]
                writeIORef (pointers envRef) (Data.Map.insert (namespace, var) valueRef ptrs)
                return $ Pointer var envRef -- Return non-reverse ptr to caller
          else return v -- Not an object, return value directly
     Nothing -> case parentEnv envRef of
       (Just par) -> addReversePointer namespace var par ptrNamespace ptrVar ptrEnvRef
       Nothing -> throwError $ UnboundVar "Getting an unbound variable: " var
