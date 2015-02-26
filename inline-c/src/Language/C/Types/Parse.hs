module Language.C.Types.Parse
  ( Identifier
  , TypeQual(..)
  , TypeSpec(..)
  , DeclarationSpec(..)
  , Declarator(..)
  , ArraySize
  , Declaration(..)

  , Parser
  , parseDeclaration
  , parseParams
  ) where

import           Control.Monad (msum, void)
import           Data.Functor ((<$>), (<$))
import           Control.Applicative ((<*>), (<|>))
import           Text.Trifecta
import qualified Data.HashSet as HashSet
import           Text.Parser.Token.Highlight

------------------------------------------------------------------------
-- Types

type Identifier = String

data TypeQual = Const
  deriving (Eq, Show)

data TypeSpec
  = Void
  | Char
  | Short
  | Int
  | Long
  | Float
  | Double
  | Signed
  | Unsigned
  | TypeName String
  deriving (Eq, Show)

data DeclarationSpec = DeclarationSpec [Either TypeQual TypeSpec]
  deriving (Eq, Show)

data Declarator
  = DeclaratorRoot String
  | Ptr [TypeQual] Declarator
  | Array (Maybe ArraySize) Declarator
  | Proto Declarator [Declaration]
  deriving (Eq, Show)

type ArraySize = Integer

data Declaration = Declaration DeclarationSpec Declarator
  deriving (Eq, Show)

------------------------------------------------------------------------
-- Parse

identStyle :: IdentifierStyle Parser
identStyle = IdentifierStyle
  { _styleName = "C identifier"
  , _styleStart = identLetter
  , _styleLetter = identLetter <|> digit
  , _styleReserved = HashSet.fromList
      [ "auto", "else", "long", "switch"
      , "break", "enum", "register", "typedef"
      , "case", "extern", "return", "union"
      , "char", "float", "short", "unsigned"
      , "const", "for", "signed", "void"
      , "continue", "goto", "sizeof", "volatile"
      , "default", "if", "static", "while"
      , "do", "int", "struct", "double"
      ]
  , _styleHighlight = Identifier
  , _styleReservedHighlight = ReservedIdentifier
  }
  where
    identLetter = oneOf $ ['a'..'z'] ++ ['A'..'Z'] ++ ['_']

parseTypeSpec :: Parser TypeSpec
parseTypeSpec = msum
  [ Void <$ reserve identStyle "void"
  , Char <$ reserve identStyle "char"
  , Short <$ reserve identStyle "short"
  , Int <$ reserve identStyle "int"
  , Long <$ reserve identStyle "long"
  , Float <$ reserve identStyle "float"
  , Double <$ reserve identStyle "double"
  , Signed <$ reserve identStyle "signed"
  , Unsigned <$ reserve identStyle "unsigned"
  , TypeName <$> ident identStyle
  ]

parseTypeQual :: Parser TypeQual
parseTypeQual = msum
  [ Const <$ reserve identStyle "const" ]

parseDeclarationSpec
  :: Parser (DeclarationSpec, Maybe (DeclarationSpec, Identifier))
parseDeclarationSpec = do
  let many1 p = (:) <$> p <*> many p
  qualOrSpecs <- many1 $ (Left <$> parseTypeQual) <|> (Right <$> parseTypeSpec)
  let mbLastId = case qualOrSpecs of
        [] -> Nothing
        _ -> case last qualOrSpecs of
          Right (TypeName s) -> Just (DeclarationSpec (init qualOrSpecs), s)
          _ -> Nothing
  return (DeclarationSpec qualOrSpecs, mbLastId)

-- Intermediate structure to parse damned declarations

data RawDeclarator
  = RawDeclarator [[TypeQual]] Declarator [RawDeclaratorTrailing]
  deriving (Show, Eq)

data RawDeclaratorTrailing
  = RawDeclaratorArray (Maybe ArraySize)
  | RawDeclaratorProto [Declaration]
  deriving (Show, Eq)

fromRawDecl :: RawDeclarator -> Declarator
fromRawDecl (RawDeclarator ptrs0 root trailings0) = goTrailing trailings0
  where
    goPtrs :: [[TypeQual]] -> Declarator
    goPtrs []             = root
    goPtrs (quals : ptrs) = Ptr quals $ goPtrs ptrs

    goTrailing :: [RawDeclaratorTrailing] -> Declarator
    goTrailing [] =
      goPtrs ptrs0
    goTrailing (trailing : trailings) = case trailing of
      RawDeclaratorArray mbSize -> Array mbSize $ goTrailing trailings
      RawDeclaratorProto decls -> Proto (goTrailing trailings) decls

parseRawDeclarator :: Parser RawDeclarator
parseRawDeclarator = do
  ptrs <- many pointer
  identOrDec <- root
  trailings <- many parseRawDeclaratorTrailing
  return $ case identOrDec of
    Left s ->
      RawDeclarator ptrs (DeclaratorRoot s) trailings
    Right (RawDeclarator ptrs' x trailings') ->
      RawDeclarator ptrs' (fromRawDecl (RawDeclarator ptrs x trailings)) trailings'
  where
    pointer :: Parser [TypeQual]
    pointer = do
      void $ symbolic '*'
      many parseTypeQual

    root :: Parser (Either Identifier RawDeclarator)
    root = msum
      [ Left <$> ident identStyle
      , Right <$> parens parseRawDeclarator
      ]

parseRawDeclaratorTrailing :: Parser RawDeclaratorTrailing
parseRawDeclaratorTrailing = msum
  [ do mbSize <- brackets $ (Just <$> integer) <|> return Nothing
       return $ RawDeclaratorArray mbSize
  , do RawDeclaratorProto <$> parens parseParams
  ]

parseDeclaration :: Parser Declaration
parseDeclaration = do
  (decSpec, mbLastIdDeclSpec) <- parseDeclarationSpec
  declaratorOrNoRootDeclarator <-
    (Left <$> parseRawDeclarator) <|> (Right <$> many parseRawDeclaratorTrailing)
  (decSpec', declarator) <-
    case (mbLastIdDeclSpec, declaratorOrNoRootDeclarator) of
      (_, Left rawDeclarator) ->
        return (decSpec, fromRawDecl rawDeclarator)
      (Just (decSpec', s), Right trailings) ->
        return (decSpec', fromRawDecl $ RawDeclarator [] (DeclaratorRoot s) trailings)
      (Nothing, Right _) ->
        fail "Malformed declaration"
  return $ Declaration decSpec' declarator

parseParams :: Parser [Declaration]
parseParams = sepBy parseDeclaration $ symbolic ','

------------------------------------------------------------------------
-- Proper declaration

-- data PDeclaration = PDeclaration Identifier Type

-- data Type
--   = TypeSpec TypeSpec
--   | Ptr [TypeQual] Type
--   | Array (Maybe ArraySize) Type
--   | Proto Type [Type]
