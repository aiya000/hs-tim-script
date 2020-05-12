{
{-# LANGUAGE CPP #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE QuasiQuotes #-}

-- |
-- Parses codes, commands, and expressions.
--
-- NOTICE:
-- This only parses syntaxes, doesn't check valid syntaxes strictly.
-- Please use Tim.Checker if you want.
--
-- e.g.
-- These are parsed successfully.
-- `let x: String = 10` (invalid assigning)
-- `1.0` (1.0 is not a command, commands are not allowed at top level)
module Tim.Parser
  ( parse
  ) where

import Control.Applicative ((<|>))
import Control.Arrow ((>>>))
import Control.Exception.Safe (displayException)
import Control.Monad.Except (throwError)
import Data.Char.Cases (DigitChar(..))
import Data.Function ((&))
import Data.List.NonEmpty (NonEmpty(..), (<|))
import Data.Map.Strict (Map)
import Data.String.Cases
import Data.String.Here (i)
import Data.Text (Text)
import Data.Text.Prettyprint.Doc (pretty)
import Prelude
import RIO.List
import Text.Megaparsec (runParser)
import Tim.Lexer.Types (Token, Register(..), Option(..), Scope(..))
import Tim.Megaparsec
import Tim.Parser.Types hiding (String)
import Tim.Processor
import qualified Data.List.NonEmpty as List
import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Map.Strict as Map
import qualified Data.String.Cases as String
import qualified Text.Megaparsec.Char as P
import qualified Text.Megaparsec.Char.Lexer as P
import qualified Tim.Lexer.Types as Token
import qualified Tim.Parser.Types as Parser
}

%error { parseError }
%errorhandlertype explist
%monad { Processor }
%name parseAST
%tokentype { (Token, TokenPos) }

%token
  ':'           { (Token.Colon, _)                                   }
  '='           { (Token.Assign, _)                                  }
  nat           { (Token.Literal (Token.Nat $$), _)                  }
  int           { (Token.Literal (Token.Int $$), _)                  }
  float         { (Token.Literal (Token.Float $$), _)                }
  stringLiteral { (Token.Literal (Token.String Token.SingleQ $$), _) }
  stringDouble  { (Token.Literal (Token.String Token.DoubleQ $$), _) }
  '['           { (Token.ListBegin, _)                               }
  ']'           { (Token.ListEnd, _)                                 }
  '{'           { (Token.DictBegin, _)                               }
  '}'           { (Token.DictEnd, _)                                 }
  '('           { (Token.ParenBegin, _)                              }
  ')'           { (Token.ParenEnd, _)                                }
  ','           { (Token.Comma, _)                                   }
  '.'           { (Token.Dot, _)                                     }
  "->"          { (Token.Arrow, _)                                   }
  '|'           { (Token.Bar, _)                                     }
  '#'           { (Token.Sharp, _)                                   }
  lineBreak     { (Token.LineBreak, _)                               }

  -- Important commands identifiers
  let         { (Token.Ident LetI, _)         }
  function    { (Token.Ident FunctionI, _)    }
  endfunction { (Token.Ident EndFunctionI, _) }

  -- variable identifiers
  varG       { (ScopedIdent G "", _) }
  varS       { (ScopedIdent S "", _) }
  varL       { (ScopedIdent L "", _) }
  varV       { (ScopedIdent V "", _) }
  varB       { (ScopedIdent B "", _) }
  varW       { (ScopedIdent W "", _) }
  varT       { (ScopedIdent T "", _) }
  -- varA (the identifier 'a:') is parsed by parseAScopeVar
  varScopedG { (ScopedIdent G $$, pos) }
  varScopedS { (ScopedIdent S $$, pos) }
  varScopedL { (ScopedIdent L $$, pos) }
  varScopedA { (ScopedIdent A $$, pos) }
  varScopedV { (ScopedIdent V $$, pos) }
  varScopedB { (ScopedIdent B $$, pos) }
  varScopedW { (ScopedIdent W $$, pos) }
  varScopedT { (ScopedIdent T $$, pos) }

  varRegUnnamed   { (RegisterIdent Unnamed, _)         }
  varRegSmallDel  { (RegisterIdent SmallDelete, _)     }
  varRegReadOnlyC { (RegisterIdent ReadOnlyColon, _)   }
  varRegReadonlyD { (RegisterIdent ReadOnlyDot, _)     }
  varRegReadOnlyP { (RegisterIdent ReadOnlyPercent, _) }
  varRegBuffer    { (RegisterIdent Buffer, _)          }
  varRegExpr      { (RegisterIdent Expression, _)      }
  varRegClipS     { (RegisterIdent ClipboardStar, _)   }
  varRegClipP     { (RegisterIdent ClipboardPlus, _)   }
  varRegBlackHole { (RegisterIdent BlackHole, _)       }
  varRegSeached   { (RegisterIdent Searched, _)        }
  varRegNum       { (RegisterIdent (Numeric $$), _)    } -- 1-9
  varRegAlpha     { (RegisterIdent (Alphabetic $$), _) } -- a-zA-Z

  varOption  { (OptionIdent $$, _)  }
  varLOption { (LOptionIdent $$, _) }
  varGOption { (GOptionIdent $$, _) }

  -- An another identifier, e.g.
  -- - An unscoped variable identifier
  -- - A type identifier
  ident { (Token.Ident (Token.unIdent -> $$), pos) }

%right '|'
%right "->"

%%

AST :: { AST }
  : Code { Code $1 }
  | Rhs  { Rhs $1  }

Code :: { Code }
  : {- empty -}           { []      }
  | Syntax                { [$1]    }
  | Syntax lineBreak Code { $1 : $3 }

Syntax :: { Syntax }
  : Let      { $1 }
  | Function { $1 }

Function :: { Syntax }
  : function FuncName '(' ')' endfunction { Function $2 [] Nothing [] [] }

FuncName :: { FuncName }
  : UnqualifiedName  { FuncNameUnqualified $1                 }
  | ScopedVar        { FuncNameScoped $1                      }
  | DictVar          { FuncNameDict $1                        }
  | FuncNameAutoload { FuncNameAutoload $ NonEmpty.reverse $1 }

FuncNameAutoload :: { List.NonEmpty Snake }
  : UnqualifiedName '#' UnqualifiedName  { $3 :| [$1] }
  | UnqualifiedName '#' FuncNameAutoload { $1 <| $3   }

Let :: { Syntax }
  : let Lhs ':' Type '=' Rhs { Let $2 (Just $4) $6 }
  | let Lhs '=' Rhs          { Let $2 Nothing $4   }

Lhs :: { Lhs }
  : Variable            { LhsVar $1        }
  | '[' DestructVar ']' { LhsDestuctVar $2 }

-- Destructive assignee variables
DestructVar :: { List.NonEmpty Variable }
  : Variable                 { ($1 :| []) }
  | Variable ',' DestructVar { $1 <| $3   }

Type :: { Type }
  : Type "->" Type { TypeArrow $1 $3 }
  | Type '|'  Type { TypeUnion $1 $3 }
  | Camel          { TypeCon $1      }
  | '(' Type ')'   { $2              }
  | TypeApp        { $1              }

-- lefty bias
TypeApp :: { Type }
  : Type Camel        { TypeApp $1 (TypeCon $2) }
  | Type '(' Type ')' { TypeApp $1 $3           }

Camel :: { Camel }
  : ident {% runParserInProcessor pos String.parseCamel $1 }

Variable :: { Variable }
  : VariableScoped      { $1 }
  | VariableDict        { $1 }
  | VariableRegister    { $1 }
  | VariableOption      { $1 }
  | VariableUnqualified { $1 }

VariableScoped :: { Variable }
  : ScopedVar { VariableScoped $1 }

ScopedVar :: { ScopedVar }
  : varG       { ScopeVarG ScopedNameEmpty                                                       }
  | varS       { ScopeVarS ScopedNameEmpty                                                       }
  | varL       { ScopeVarL ScopedNameEmpty                                                       }
  | varV       { ScopeVarV ScopedNameEmpty                                                       }
  | varB       { ScopeVarB ScopedNameEmpty                                                       }
  | varW       { ScopeVarW ScopedNameEmpty                                                       }
  | varT       { ScopeVarT ScopedNameEmpty                                                       }
  | varScopedG {% fmap (ScopeVarG . ScopedNameNonEmpty) $ runParserInProcessor pos parseSnake $1 }
  | varScopedS {% fmap (ScopeVarS . ScopedNameNonEmpty) $ runParserInProcessor pos parseSnake $1 }
  | varScopedL {% fmap (ScopeVarL . ScopedNameNonEmpty) $ runParserInProcessor pos parseSnake $1 }
  | varScopedV {% fmap (ScopeVarV . ScopedNameNonEmpty) $ runParserInProcessor pos parseSnake $1 }
  | varScopedB {% fmap (ScopeVarB . ScopedNameNonEmpty) $ runParserInProcessor pos parseSnake $1 }
  | varScopedW {% fmap (ScopeVarW . ScopedNameNonEmpty) $ runParserInProcessor pos parseSnake $1 }
  | varScopedT {% fmap (ScopeVarT . ScopedNameNonEmpty) $ runParserInProcessor pos parseSnake $1 }
  | varScopedA {% fmap ScopeVarA $ runParserInProcessor pos parseAScopeVar $1                    }

VariableDict :: { Variable }
  : DictVar { VariableDict $1 }

DictVar :: { DictVar }
  : DictSelf '[' Variable ']'    { DictVarIndexAccess $1 $3         }
  | DictSelf '.' UnqualifiedName { DictVarPropertyAccess $1 $3      }
  | DictVar '[' Variable ']'     { DictVarIndexAccessChain $1 $3    }
  | DictVar '.' UnqualifiedName  { DictVarPropertyAccessChain $1 $3 }

DictSelf :: { DictSelf }
  : UnqualifiedName { DictSelfUnqualified $1 }
  | ScopedVar       { DictSelfScoped $1      }

VariableRegister :: { Variable }
  : varRegUnnamed   { VariableRegister Unnamed         }
  | varRegSmallDel  { VariableRegister SmallDelete     }
  | varRegReadOnlyC { VariableRegister ReadOnlyColon   }
  | varRegReadonlyD { VariableRegister ReadOnlyDot     }
  | varRegReadOnlyP { VariableRegister ReadOnlyPercent }
  | varRegBuffer    { VariableRegister Buffer          }
  | varRegExpr      { VariableRegister Expression      }
  | varRegClipS     { VariableRegister ClipboardStar   }
  | varRegClipP     { VariableRegister ClipboardPlus   }
  | varRegBlackHole { VariableRegister BlackHole       }
  | varRegSeached   { VariableRegister Searched        }
  | varRegNum       { VariableRegister $ Numeric $1    }
  | varRegAlpha     { VariableRegister $ Alphabetic $1 }

VariableOption :: { Variable }
  : varLOption { VariableOption $ LocalScopedOption $1  }
  | varGOption { VariableOption $ GlobalScopedOption $1 }
  | varOption  { VariableOption $ UnscopedOption $1     }

VariableUnqualified :: { Variable }
  : UnqualifiedName { VariableUnqualified $1 }

UnqualifiedName :: { Snake }
  : ident {% runParserInProcessor pos parseSnake $1 }

Rhs :: { Rhs }
  : Variable    { RhsVar $1    }
  | Literal     { RhsLit $1    }
  | '(' Rhs ')' { RhsParens $2 }

Literal :: { Literal }
  : nat               { LiteralNat $1    }
  | int               { LiteralInt $1    }
  | float             { LiteralFloat $1  }
  | String            { LiteralString $1 }
  | '[' ListInner ']' { LiteralList $2   }
  | '{' DictInner '}' { LiteralDict $2   }

String :: { Parser.String }
  : stringLiteral { StringLiteral $1 }
  | stringDouble  { StringDouble $1  }

ListInner :: { [Literal] }
  : {- empty -}           { []      }
  | Literal               { [$1]    }
  | Literal ',' ListInner { $1 : $3 }

DictInner :: { Map Parser.String Literal }
  : {- empty -}                      { Map.empty           }
  | String ':' Literal               { Map.singleton $1 $3 }
  | String ':' Literal ',' DictInner { Map.insert $1 $3 $5 }

{
pattern ScopedIdent :: Scope -> String -> Token
pattern ScopedIdent s x = Token.Ident (Token.QualifiedIdent (Token.Scoped s x))

pattern RegisterIdent :: Register -> Token
pattern RegisterIdent r = Token.Ident (Token.QualifiedIdent (Token.Register r))

pattern OptionIdent :: LowerString -> Token
pattern OptionIdent x = Token.Ident (Token.QualifiedIdent (Token.Option (Token.UnscopedOption x)))

pattern LOptionIdent :: LowerString -> Token
pattern LOptionIdent x = Token.Ident (Token.QualifiedIdent (Token.Option (Token.LocalScopedOption x)))

pattern GOptionIdent :: LowerString -> Token
pattern GOptionIdent x = Token.Ident (Token.QualifiedIdent (Token.Option (Token.GlobalScopedOption x)))


pattern LetI :: Token.Ident
pattern LetI = Token.UnqualifiedIdent (String.NonEmpty 'l' "et")

pattern FunctionI :: Token.Ident
pattern FunctionI = Token.UnqualifiedIdent (String.NonEmpty 'f' "unction")

pattern EndFunctionI :: Token.Ident
pattern EndFunctionI = Token.UnqualifiedIdent (String.NonEmpty 'e' "ndfunction")


parse :: [(Token, TokenPos)] -> Either Failure AST
parse = runProcessor . parseAST

-- TODO: Show all [(Token, TokenPos)] if --verbose specified on cli.
parseError :: ([(Token, TokenPos)], [String]) -> Processor a
parseError ((got, pos) : _, expected) =
  throwError . flip Failure (OnAToken pos) $ flattenMargins [i|
    got a token `${show $ pretty got}`,
    but ${expected} are expected at here.
  |]
parseError ([], expected) =
  throwError $ Failure [i|got EOF, but ${makePluralForm expected} are expected at here.|] EOF
  where
    -- ["a", "b"]      -> "a or b"
    -- ["a", "b", "c"] -> "a, b, or c"
    makePluralForm [] = []
    makePluralForm [x] = x
    makePluralForm (x : y : words) =
      case uncons $ reverse words of
        Nothing ->  [i|${x} or ${y}|]
        Just (tail, reverse -> body) -> [i|${foldl comma "" body}, or ${tail}|]

    comma :: String -> String -> String
    comma x y = [i|${x}, ${y}|]

flattenMargins :: String -> String
flattenMargins = replace . unlines . filter (/= "") . map (dropWhile (== ' ')) . lines
  where
    replace [] = []
    replace ('\n' : xs) = ' ' : replace xs
    replace (x : xs) = x : replace xs

runParserInProcessor :: TokenPos -> CodeParsec a -> String -> Processor a
runParserInProcessor pos parser input =
  case runParser parser "time-script" input of
    Right x -> pure x
    Left  e -> throwError $ Failure (displayException e) (OnAToken pos)

parseAScopeVar :: CodeParsec AScopeName
parseAScopeVar =
    varAll <|>
    varNum <|>
    nonEmptyName <|>
    emptyName
  where
    varAll = AScopeNameVarAll <$ P.string "000"
    varNum = AScopeNameVarNum <$> P.decimal
    nonEmptyName = AScopeNameName . ScopedNameNonEmpty <$> parseSnake
    emptyName = AScopeNameName ScopedNameEmpty <$ P.string ""
}
