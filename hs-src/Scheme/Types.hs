{--
 - husk scheme
 - Types
 -
 - This file contains top-level data type definitions and their associated functions, including:
 -  - Scheme data types
 -  - Scheme errors
 -
 - @author Justin Ethier
 -
 - -}
module Scheme.Types where
import Complex
import Control.Monad.Error
import Data.Array
import Data.IORef
import qualified Data.Map
import IO hiding (try)
import Ratio
import Text.ParserCombinators.Parsec hiding (spaces)

{-  Environment management -}

-- |A Scheme environment containing variable bindings of form @(namespaceName, variableName), variableValue@
data Env = Environment {parentEnv :: (Maybe Env), bindings :: (IORef [((String, String), IORef LispVal)])} -- lookup via: (namespace, variable)

-- |An empty environment
nullEnv :: IO Env
nullEnv = do nullBindings <- newIORef []
             return $ Environment Nothing nullBindings

-- Internal namespace for macros
macroNamespace :: [Char]
macroNamespace = "m"

-- Internal namespace for variables
varNamespace :: [Char]
varNamespace = "v"

-- |Types of errors that may occur when evaluating Scheme code
data LispError = NumArgs Integer [LispVal] -- ^Invalid number of function arguments
  | TypeMismatch String LispVal -- ^Type error
  | Parser ParseError -- ^Parsing error
  | BadSpecialForm String LispVal -- ^Invalid special (built-in) form
  | NotFunction String String
  | UnboundVar String String
  | DivideByZero -- ^Divide by Zero error
  | NotImplemented String
  | Default String -- ^Default error

-- |Create a textual description for a 'LispError'
showError :: LispError -> String
showError (NumArgs expected found) = "Expected " ++ show expected
                                  ++ " args; found values " ++ unwordsList found
showError (TypeMismatch expected found) = "Invalid type: expected " ++ expected
                                  ++ ", found " ++ show found
showError (Parser parseErr) = "Parse error at " ++ ": " ++ show parseErr
showError (BadSpecialForm message form) = message ++ ": " ++ show form
showError (NotFunction message func) = message ++ ": " ++ show func
showError (UnboundVar message varname) = message ++ ": " ++ varname
showError (DivideByZero) = "Division by zero"
showError (NotImplemented message) = "Not implemented: " ++ message
showError (Default message) = "Error: " ++ message

instance Show LispError where show = showError
instance Error LispError where
  noMsg = Default "An error has occurred"
  strMsg = Default

type ThrowsError = Either LispError

trapError :: -- forall (m :: * -> *) e.
            (MonadError e m, Show e) =>
             m String -> m String 
trapError action = catchError action (return . show)

extractValue :: ThrowsError a -> a
extractValue (Right val) = val
extractValue (Left _) = error "Unexpected error in extractValue; "

type IOThrowsError = ErrorT LispError IO

liftThrows :: ThrowsError a -> IOThrowsError a
liftThrows (Left err) = throwError err
liftThrows (Right val) = return val

runIOThrows :: IOThrowsError String -> IO String
runIOThrows action = runErrorT (trapError action) >>= return . extractValue

-- |Scheme data types
data LispVal = Atom String
          -- ^Symbol
	| List [LispVal]
          -- ^List
	| DottedList [LispVal] LispVal
          -- ^Pair
	| Vector (Array Int LispVal)
          -- ^Vector
	| HashTable (Data.Map.Map LispVal LispVal)
	-- ^Hash table. Map is technically the wrong structure to use for a hash table since it is based on a binary tree and hence operations tend to be O(log n) instead of O(1). However, according to <http://www.opensubscriber.com/message/haskell-cafe@haskell.org/10779624.html> Map has good performance characteristics compared to the alternatives. So it stays for the moment...
	| Number Integer
          -- ^Integer
	| Float Double -- TODO: rename this "Real" instead of "Float"...
          -- ^Floating point
	| Complex (Complex Double)
          -- ^Complex number
	| Rational Rational
          -- ^Rational number
 	| String String
          -- ^String
	| Char Char
          -- ^Character
	| Bool Bool
          -- ^Boolean
	| PrimitiveFunc ([LispVal] -> ThrowsError LispVal)
          -- ^
	| Func {params :: [String], 
 	        vararg :: (Maybe String),
	        body :: [LispVal], 
 	        closure :: Env,
                partialEval :: Bool -- TODO: Obsolete, this member should be removed
 	       }
          -- ^Function
	| IOFunc ([LispVal] -> IOThrowsError LispVal)
         -- ^
	| Port Handle
         -- ^I/O port
	| Continuation {closure :: Env,    -- Environment of the continuation
                        body :: [LispVal], -- Code in the body of the continuation
                        continuation :: LispVal    -- Code to resume after body of cont
                        , frameFunc :: (Maybe LispVal) -- TODO: obsolete, remove if higher-order works
--                        , frameRawArgs :: (Maybe [LispVal])
                        , frameEvaledArgs :: (Maybe [LispVal]) -- TODO: obsolete, remove if higher-order works
                        , continuationFunction :: (Maybe (Env -> LispVal -> LispVal -> IOThrowsError LispVal))
                        --
                        --TODO: frame information
                        --  for evaluating a function (prior to calling) need:
                        --   - function obj
                        --   - list of args
                        --
                        -- TODO: for TCO within a function, need:
                        --   - calling function name (or some unique ID, for lambda's)
                        --   - calling function arg values
                        --  may be able to have a single frame object take care of both
                        --  purposes. but before implementing this, do a bit more research
                        --  to verify the approach.
                        --
                        --
                        -- FUTURE: stack (for dynamic wind)
                       }
         -- ^Continuation
 	| Nil String
         -- ^Internal use only; do not use this type directly.

makeNullContinuation :: Env -> LispVal
makeNullContinuation env = Continuation env [] (Nil "") Nothing Nothing Nothing

makeCPS :: Env -> LispVal -> (Env -> LispVal -> LispVal -> IOThrowsError LispVal) -> LispVal
makeCPS env cont cps = Continuation env [] cont Nothing Nothing (Just cps)

instance Ord LispVal where
  compare (Bool a) (Bool b) = compare a b
  compare (Number a) (Number b) = compare a b
  compare (Rational a) (Rational b) = compare a b
  compare (Float a) (Float b) = compare a b
  compare (String a) (String b) = compare a b
  compare (Char a) (Char b) = compare a b
  compare (Atom a) (Atom b) = compare a b
--  compare (DottedList xs x) (DottedList xs x) = compare a b
-- Vector
-- HashTable
-- List
-- Func
-- Others?
  compare a b = compare (show a) (show b) -- Hack (??): sort alphabetically when types differ or have no handlers

-- |Compare two 'LispVal' instances
eqv :: [LispVal] -> ThrowsError LispVal
eqv [(Bool arg1), (Bool arg2)] = return $ Bool $ arg1 == arg2
eqv [(Number arg1), (Number arg2)] = return $ Bool $ arg1 == arg2
eqv [(Complex arg1), (Complex arg2)] = return $ Bool $ arg1 == arg2
eqv [(Rational arg1), (Rational arg2)] = return $ Bool $ arg1 == arg2
eqv [(Float arg1), (Float arg2)] = return $ Bool $ arg1 == arg2
eqv [(String arg1), (String arg2)] = return $ Bool $ arg1 == arg2
eqv [(Char arg1), (Char arg2)] = return $ Bool $ arg1 == arg2
eqv [(Atom arg1), (Atom arg2)] = return $ Bool $ arg1 == arg2
eqv [(DottedList xs x), (DottedList ys y)] = eqv [List $ xs ++ [x], List $ ys ++ [y]]
eqv [(Vector arg1), (Vector arg2)] = eqv [List $ (elems arg1), List $ (elems arg2)] 
eqv [(HashTable arg1), (HashTable arg2)] = 
  eqv [List $ (map (\(x, y) -> List [x, y]) $ Data.Map.toAscList arg1), 
       List $ (map (\(x, y) -> List [x, y]) $ Data.Map.toAscList arg2)] 
eqv [l1@(List _), l2@(List _)] = eqvList eqv [l1, l2]
eqv [_, _] = return $ Bool False
eqv badArgList = throwError $ NumArgs 2 badArgList

eqvList :: ([LispVal] -> ThrowsError LispVal) -> [LispVal] -> ThrowsError LispVal
eqvList eqvFunc [(List arg1), (List arg2)] = return $ Bool $ (length arg1 == length arg2) && 
                                                    (all eqvPair $ zip arg1 arg2)
    where eqvPair (x1, x2) = case eqvFunc [x1, x2] of
                               Left _ -> False
                               Right (Bool val) -> val
                               _ -> False -- OK?
eqvList _ _ = throwError $ Default "Unexpected error in eqvList"

eqVal :: LispVal -> LispVal -> Bool
eqVal a b = do
  let result = eqv [a, b]
  case result of
    Left _ -> False
    Right (Bool val) -> val
    _ -> False -- Is this OK?

instance Eq LispVal where
  x == y = eqVal x y

-- |Create a textual description of a 'LispVal'
showVal :: LispVal -> String
showVal (Nil _) = ""
showVal (String contents) = "\"" ++ contents ++ "\""
showVal (Char chr) = [chr]
showVal (Atom name) = name
showVal (Number contents) = show contents
showVal (Complex contents) = (show $ realPart contents) ++ "+" ++ (show $ imagPart contents) ++ "i"
showVal (Rational contents) = (show (numerator contents)) ++ "/" ++ (show (denominator contents))
showVal (Float contents) = show contents
showVal (Bool True) = "#t"
showVal (Bool False) = "#f"
showVal (Vector contents) = "#(" ++ (unwordsList $ Data.Array.elems contents) ++ ")"
showVal (HashTable _) = "<hash-table>"
showVal (List contents) = "(" ++ unwordsList contents ++ ")"
showVal (DottedList h t) = "(" ++ unwordsList h ++ " . " ++ showVal t ++ ")"
showVal (PrimitiveFunc _) = "<primitive>"
showVal (Continuation {closure = _, body = _}) = "<continuation>"
showVal (Func {params = args, vararg = varargs, body = _, closure = _}) = 
  "(lambda (" ++ unwords (map show args) ++
    (case varargs of
      Nothing -> ""
      Just arg -> " . " ++ arg) ++ ") ...)"
showVal (Port _) = "<IO port>"
showVal (IOFunc _) = "<IO primitive>"

unwordsList :: [LispVal] -> String
unwordsList = unwords . map showVal

-- |Allow conversion of lispval instances to strings
instance Show LispVal where show = showVal
