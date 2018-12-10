{
{-# LANGUAGE CPP #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE QuasiQuotes #-}

module Tims.Parser
  ( parse
  ) where

import Control.Arrow ((>>>))
import Control.Monad.Except (throwError)
import Data.List.NonEmpty (NonEmpty(..), (<|))
import Data.Map.Strict (Map)
import Data.String.Here (i)
import Data.Text (Text)
import Data.Text.Prettyprint.Doc (pretty)
import Prelude
import Tims.Lexer.Types (Token, TokenPos, Failure(..))
import Tims.Parser.Types
import Tims.Processor (Processor, runProcessor)
import Tims.Processor.Types (AsciiChar(..), UpperChar(..), LowerChar(..), pattern LetIdent)
import qualified Data.Map.Strict as Map
import qualified Tims.Lexer.Types as Token
import qualified Tims.Processor.Types as Proc
}

%error { parseError }
%errorhandlertype explist
%monad { Processor }
%name parseCode
%tokentype { (Token, TokenPos) }

%token
  let       { (Token.Command LetIdent, _) }
  varIdent  { (Token.VarIdent $$, _)                         }
  ':'       { (Token.Colon, _)                               }
  typeIdent { (Token.TypeIdent $$, _)                        }
  '='       { (Token.Assign, _)                              }
  nat       { (Token.Literal (Token.Nat $$), _)              }
  int       { (Token.Literal (Token.Int $$), _)              }
  float     { (Token.Literal (Token.Float $$), _)            }
  string    { (Token.Literal (Token.String $$), _)           }
  '['       { (Token.ListBegin, _)                           }
  ']'       { (Token.ListEnd, _)                             }
  '{'       { (Token.DictBegin, _)                           }
  '}'       { (Token.DictEnd, _)                             }
  '('       { (Token.ParenBegin, _)                          }
  ')'       { (Token.ParenEnd, _)                            }
  ','       { (Token.Comma, _)                               }
  lineBreak { (Token.LineBreak, _)                           }

%%

Code :: { AST }
  : {- empty -}           { AST []       }
  | Syntax lineBreak Code { $1 `cons` $3 }

Syntax :: { Syntax }
  : let Lhs ':' typeIdent '=' Rhs { Let $2 (Just $4) $6 }
  | let Lhs '=' Rhs               { Let $2 Nothing $4   }

Lhs :: { Lhs }
  : varIdent         { LVar $1     }
  | '[' DestVars ']' { LDestuct $2 }

-- Destructive assignee variables
DestVars :: { NonEmpty Proc.VarIdent }
  : varIdent              { ($1 :| []) }
  | varIdent ',' DestVars { $1 <| $3   }

Rhs :: { Rhs }
  : varIdent { RVar $1 }
  | Literal  { RLit $1 }

Literal :: { Literal }
  : nat               { Nat $1    }
  | int               { Int $1    }
  | float             { Float $1  }
  | string            { String $1 }
  | '(' Literal ')'   { Parens $2 }
  | '[' ListInner ']' { List $2   }
  | '{' DictInner '}' { Dict $2   }

ListInner :: { [Literal] }
  : {- empty -}           { []      }
  | Literal ',' ListInner { $1 : $3 }

DictInner :: { Map Text Literal }
  : {- empty -}                      { Map.empty           }
  | string ':' Literal ',' DictInner { Map.insert $1 $3 $5 }

{
parse :: [(Token, TokenPos)] -> Either Failure AST
parse = runProcessor . parseCode

flattenMargins :: String -> String
flattenMargins = replace . unlines . filter (/= "") . map (dropWhile (== ' ')) . lines
  where
    replace [] = []
    replace ('\n' : xs) = ' ' : replace xs

parseError :: ([(Token, TokenPos)], [String]) -> Processor a
parseError (((got, pos):_), expected) =
  throwError . flip Failure pos $ flattenMargins [i|
    got a token `${show $ pretty got}`
    at ${show $ pretty pos},
    but ${expected} are expected at here.
  |]
parseError (_, _) =
  error $ flattenMargins [i|
    fatal error!
    Sorry, please report an issue :(
    <- parseError at ${(__FILE__ :: String)}:L${(__LINE__ :: Int)}
  |]

infixr 9 `cons`

cons :: Syntax -> AST -> AST
cons x (AST xs) = AST $ x : xs
}
