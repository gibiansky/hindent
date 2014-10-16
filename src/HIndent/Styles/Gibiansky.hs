{-# LANGUAGE FlexibleContexts, OverloadedStrings, RecordWildCards, RankNTypes #-}

module HIndent.Styles.Gibiansky (gibiansky) where

import Data.Foldable
import Control.Applicative((<$>))
import Control.Monad (unless, when, replicateM_)
import Control.Monad.State (gets, get, put)
import Debug.Trace

import HIndent.Pretty
import HIndent.Types

import Language.Haskell.Exts.Annotated.Syntax
import Language.Haskell.Exts.SrcLoc
import Prelude hiding (exp, all, mapM_, and, maximum)

-- | Empty state.
data State = State

-- | The printer style.
gibiansky :: Style
gibiansky =
  Style { styleName = "gibiansky"
        , styleAuthor = "Andrew Gibiansky"
        , styleDescription = "Andrew Gibiansky's style"
        , styleInitialState = State
        , styleExtenders = [ Extender imp
                           , Extender context
                           , Extender derivings
                           , Extender typ
                           , Extender exprs
                           , Extender rhss
                           , Extender decls
                           , Extender condecls
                           , Extender guardedAlts
                           ]
        , styleDefConfig =
           defaultConfig { configMaxColumns = maxColumns
                         , configIndentSpaces = indentSpaces
                         , configClearEmptyLines =  True
                         }
        }

-- | Number of spaces to indent by.
indentSpaces :: Integral a => a
indentSpaces = 2

-- | Printer to indent one level.
indentOnce :: Printer ()
indentOnce = replicateM_ indentSpaces $ write " "

-- | Max number of columns per line.
maxColumns :: Integral a => a
maxColumns = 100

attemptSingleLine :: Printer a -> Printer a -> Printer a
attemptSingleLine single multiple = do
  -- Try printing on one line.
  prevState <- get
  result <- single

  --  If it doesn't fit, reprint on multiple lines.
  col <- getColumn
  if col > maxColumns
    then do
      put prevState
      multiple
    else 
      return result

--------------------------------------------------------------------------------
-- Extenders

type Extend f = forall t. t -> f NodeInfo -> Printer ()


-- | Format import statements.
imp :: Extend ImportDecl
imp _ ImportDecl{..} = do
  write "import "
  write $ if importQualified
          then "qualified "
          else "          "
  pretty importModule

  forM_ importAs $ \name -> do
    write " as "
    pretty name

  forM_ importSpecs $ \speclist -> do
    write " "
    pretty speclist

-- | Format contexts with spaces and commas between class constraints.
context :: Extend Context
context _ (CxTuple _ asserts) =
  parens $ inter (comma >> space) $ map pretty asserts
context _ ctx = prettyNoExt ctx

-- | Format deriving clauses with spaces and commas between class constraints.
derivings :: Extend Deriving
derivings _ (Deriving _ instHeads) = do
  write "deriving "
  go instHeads

  where
    go insts | length insts == 1
             = pretty $ head insts
             | otherwise
             = parens $ inter (comma >> space) $ map pretty insts

-- | Format function type declarations.
typ :: Extend Type

-- For contexts, check whether the context and all following function types
-- are on the same line. If they are, print them on the same line; otherwise
-- print the context and each argument to the function on separate lines.
typ _ (TyForall _ _ (Just ctx) rest) =
  if all (sameLine ctx) $ collectTypes rest
  then do
    pretty ctx
    write " => "
    pretty rest
  else do
    col <- getColumn
    pretty ctx
    column (col - 3) $ do
      newline
      write  "=> "
      indented 3 $ pretty rest

typ _ ty@(TyFun _ from to) =
  -- If the function argument types are on the same line,
  -- put the entire function type on the same line.
  if all (sameLine from) $ collectTypes ty
  then do
    pretty from
    write " -> "
    pretty to
  -- If the function argument types are on different lines,
  -- write one argument type per line.
  else do
    col <- getColumn
    pretty from
    column (col - 3) $ do
      newline
      write "-> "
      indented 3 $ pretty to
typ _ t = prettyNoExt t

sameLine :: (Annotated ast, Annotated ast') => ast NodeInfo -> ast' NodeInfo -> Bool
sameLine x y = line x == line y
  where
    line :: Annotated ast => ast NodeInfo -> Int 
    line = startLine . nodeInfoSpan . ann

collectTypes :: Type l -> [Type l]
collectTypes (TyFun _ from to) = from : collectTypes to
collectTypes ty = [ty]

exprs :: Extend Exp
exprs _ exp@Let{} = letExpr exp
exprs _ exp@App{} = appExpr exp
exprs _ exp@Do{} = doExpr exp
exprs _ exp@List{} = listExpr exp
exprs _ exp@(InfixApp _ _ (QVarOp _ (UnQual _ (Symbol _ "$"))) _) = dollarExpr exp
exprs _ exp@(InfixApp _ _ (QVarOp _ (UnQual _ (Symbol _ "<*>"))) _) = applicativeExpr exp
exprs _ exp@Lambda{} = lambdaExpr exp
exprs _ exp@Case{} = caseExpr exp
exprs _ exp = prettyNoExt exp

letExpr :: Exp NodeInfo -> Printer ()
letExpr (Let _ binds result) = do
  cols <- depend (write "let ") $ do
    col <- getColumn
    pretty binds
    return $ col - 4
  column cols $ do
    newline
    write "in "
    pretty result
letExpr _ = error "Not a let"

appExpr :: Exp NodeInfo -> Printer ()
appExpr (App _ f x) = spaced [pretty f, pretty x]
appExpr _ = error "Not an app"

doExpr :: Exp NodeInfo -> Printer ()
doExpr (Do _ stmts) = do
  write "do"
  newline
  indented 2 $ lined (map pretty stmts)
doExpr _ = error "Not a do"

listExpr :: Exp NodeInfo -> Printer ()
listExpr (List _ els) = attemptSingleLine (singleLineList els) (multiLineList els)
listExpr _ = error "Not a list"

singleLineList :: [Exp NodeInfo] -> Printer ()
singleLineList exprs = do
  write "["
  inter (write ", ") $ map pretty exprs
  write "]"

multiLineList :: [Exp NodeInfo] -> Printer ()
multiLineList [] = write "[]"
multiLineList (first:exprs) = do
  col <- getColumn
  column col $ do
    write "[ "
    pretty first
    forM_ exprs $ \el -> do
      newline
      write ", "
      pretty el
    newline
    write "]"

dollarExpr :: Exp NodeInfo -> Printer ()
dollarExpr (InfixApp _ left op right) = do
  pretty left
  write " "
  pretty op
  if needsNewline right
    then do
      newline
      depend indentOnce $ pretty right
    else do
      write " "
      pretty right
  where
    needsNewline Case{} = True
    needsNewline _ = False
dollarExpr _ = error "Not an application"

applicativeExpr :: Exp NodeInfo -> Printer ()
applicativeExpr exp@InfixApp{} =
  case applicativeArgs of
    Just (first:second:rest) ->
      attemptSingleLine (singleLine first second rest) (multiLine first second rest)
    _ -> prettyNoExt exp
  where
    singleLine :: Exp NodeInfo -> Exp NodeInfo -> [Exp NodeInfo] -> Printer ()
    singleLine first second rest = spaced
      [ pretty first
      , write "<$>"
      , pretty second
      , write "<*>"
      , inter (write " <*> ") $ map pretty rest
      ]

    multiLine :: Exp NodeInfo -> Exp NodeInfo -> [Exp NodeInfo] -> Printer ()
    multiLine first second rest = do
      pretty first
      depend (write " ") $ do
        write "<$> "
        pretty second
        forM_ rest $ \val -> do
          newline
          write "<*> "
          pretty val

    applicativeArgs :: Maybe [Exp NodeInfo]
    applicativeArgs = collectApplicativeExps exp

    collectApplicativeExps :: Exp NodeInfo -> Maybe [Exp NodeInfo]
    collectApplicativeExps (InfixApp _ left op right)
      | isFmap op = return [left, right]
      | isAp op = do
          start <- collectApplicativeExps left
          return $ start ++ [right]
      | otherwise = Nothing
    collectApplicativeExps x = return [x]

    isFmap :: QOp NodeInfo -> Bool
    isFmap (QVarOp _ (UnQual _ (Symbol _ "<$>"))) = True
    isFmap _ = False

    isAp :: QOp NodeInfo -> Bool
    isAp (QVarOp _ (UnQual _ (Symbol _ "<*>"))) = True
    isAp _ = False
applicativeExpr _ = error "Not an application"

lambdaExpr :: Exp NodeInfo -> Printer ()
lambdaExpr (Lambda _ pats exp) = do
  write "\\"
  spaced $ map pretty pats
  write " ->"
  attemptSingleLine (write " " >> pretty exp) $ do
    newline
    indentOnce
    pretty exp
lambdaExpr _ = error "Not a lambda"

caseExpr :: Exp NodeInfo -> Printer ()
caseExpr (Case _ exp alts) = do
  allSingle <- and <$> mapM isSingle alts

  depend (write "case ") $ do
    pretty exp
    write " of"
  newline
  
  indented indentSpaces $
    if allSingle
    then do
      maxPatLen <- maximum <$> mapM (patternLen . altPattern) alts
      lined $ map (prettyCase maxPatLen) alts
    else lined $ map pretty alts
  where
    isSingle :: Alt NodeInfo -> Printer Bool
    isSingle alt = fst <$> sandbox (do
      line <- gets psLine
      pretty alt
      line' <- gets psLine
      return $ line == line')

    altPattern :: Alt l -> Pat l
    altPattern (Alt _ p _ _) = p

    patternLen :: Pat NodeInfo -> Printer Int
    patternLen pat = fromIntegral <$> fst <$> sandbox (do
      col <- getColumn
      pretty pat
      col' <- getColumn
      return $ col' - col)

    prettyCase :: Int -> Alt NodeInfo -> Printer ()
    prettyCase patlen (Alt _ p galts mbinds) = do
      -- Padded pattern
      col <- getColumn
      pretty p
      col' <- getColumn
      replicateM_ (patlen - fromIntegral (col' - col)) space

      pretty galts

      --  Optional where clause!
      forM_ mbinds $ \binds -> do
        newline
        indented indentSpaces $ depend (write "where ") (pretty binds)


caseExpr _ = error "Not a case"

rhss :: Extend Rhs
rhss _ (UnGuardedRhs _ exp) = do
  write " = "
  pretty exp
rhss _ rhs = prettyNoExt rhs

decls :: Extend Decl
decls _ (DataDecl _ dataOrNew Nothing declHead constructors mayDeriving) = do
  pretty dataOrNew
  write " "
  pretty declHead
  case constructors of
    []  -> return ()
    [x] -> do
      write " = "
      pretty x
    (x:xs) ->
      depend (write " ") $ do
        write "= "
        pretty x
        forM_ xs $ \constructor -> do
          newline
          write "| "
          pretty constructor

  forM_ mayDeriving $ \deriv -> do
    newline
    indented indentSpaces $ pretty deriv

decls _ (PatBind _ pat Nothing rhs mbinds) = funBody [pat] rhs mbinds
decls _ (FunBind _ matches) = 
  forM_ matches $ \match -> do

    (name, pat, rhs, mbinds) <- 
      case match of
        Match _ name pat rhs mbinds -> return (name, pat, rhs, mbinds)
        InfixMatch _ left name pat rhs mbinds -> do
          pretty left
          write " "
          return (name, pat, rhs, mbinds)

    pretty name
    write " "
    funBody pat rhs mbinds
decls _ decl = prettyNoExt decl

funBody :: [Pat NodeInfo] -> Rhs NodeInfo -> Maybe (Binds NodeInfo) -> Printer ()
funBody pat rhs mbinds = do
  spaced $ map pretty pat
  pretty rhs

  -- Process the binding group, if it exists.
  forM_ mbinds $ \binds -> do
    newline
    -- Add an extra newline after do blocks.
    when (isDoBlock rhs) newline
    indented indentSpaces $ do
      write "where"
      newline
      indented indentSpaces $ writeWhereBinds binds

writeWhereBinds :: Binds NodeInfo -> Printer ()
writeWhereBinds (BDecls _ binds@(first:rest)) = do
  pretty first
  forM_ (zip binds rest) $ \(prev, cur) -> do
    let prevLine = srcSpanEndLine . srcInfoSpan . nodeInfoSpan . ann $ prev
        curLine = startLine . nodeInfoSpan . ann $ cur
        emptyLines = curLine - prevLine
    replicateM_ (traceShowId emptyLines) newline
    pretty cur
writeWhereBinds binds = prettyNoExt binds

isDoBlock :: Rhs l -> Bool
isDoBlock (UnGuardedRhs _ Do{}) = True
isDoBlock _ = False

condecls :: Extend ConDecl
condecls _ (ConDecl _ name bangty) =
  depend (pretty name) $
    forM_ bangty $ \ty -> space >> pretty ty
condecls _ (RecDecl _ name fields) =
  depend (pretty name >> space) $ do
    write "{ "
    case fields of
      []         -> return ()
      [x]        -> do
        pretty x
        eol <- gets psEolComment
        unless eol space

      first:rest -> do
        pretty first
        newline
        forM_ rest $ \field -> do
          comma
          space
          pretty field
          newline
    write "}"
condecls _ other = prettyNoExt other

guardedAlts :: Extend GuardedAlts
guardedAlts _ (UnGuardedAlt _ exp) = do
  write " -> "
  pretty exp
guardedAlts _ alt = prettyNoExt alt
