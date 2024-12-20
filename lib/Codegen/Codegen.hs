{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE ImpredicativeTypes #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MonoLocalBinds #-}
{-# LANGUAGE RecursiveDo #-}
{-# LANGUAGE UndecidableInstances #-}

module Codegen.Codegen where

import qualified Ast.Types as AT
import qualified Codegen.Utils as U
import qualified Control.Monad as CM
import qualified Control.Monad.Except as E
import qualified Control.Monad.Fix as F
import qualified Control.Monad.State as S
import qualified Data.List as L
import qualified LLVM.AST as AST
import qualified LLVM.AST.Constant as C
import qualified LLVM.AST.IntegerPredicate as IP
import qualified LLVM.AST.Type as T
import qualified LLVM.IRBuilder.Instruction as I
import qualified LLVM.IRBuilder.Module as M
import qualified LLVM.IRBuilder.Monad as IRM

-- | Type alias for the code generation state.
type CodegenState = [(String, AST.Operand)]

-- | Monad constraints for code generation.
type MonadCodegen m =
  ( IRM.MonadIRBuilder m,
    M.MonadModuleBuilder m,
    F.MonadFix m,
    S.MonadState CodegenState m,
    E.MonadError CodegenError m
  )

-- | Error types for code generation.
data CodegenError
  = UnsupportedTopLevel AT.Expr
  | UnsupportedOperator AT.Operation
  | UnsupportedUnaryOperator AT.UnaryOperation
  | UnsupportedLiteral AT.Literal
  | UnsupportedType AT.Type
  | UnsupportedGlobalVar AT.Literal
  | UnsupportedLocalVar AT.Literal
  | UnsupportedDefinition AT.Expr
  | VariableNotFound String
  | UnsupportedFunctionCall String
  deriving (Show)

-- | Variable binding typeclass.
class (Monad m) => VarBinding m where
  getVar :: String -> m (Maybe AST.Operand)
  addVar :: String -> AST.Operand -> m ()

instance (MonadCodegen m, Monad m) => VarBinding m where
  getVar = S.gets . lookup
  addVar name operand = S.modify ((name, operand) :)

-- | Type conversion to LLVM IR.
class ToLLVM a where
  toLLVM :: a -> T.Type

instance ToLLVM AT.Type where
  toLLVM = \case
    AT.TInt width -> T.IntegerType (fromIntegral width)
    AT.TFloat -> T.FloatingPointType T.FloatFP
    AT.TDouble -> T.FloatingPointType T.DoubleFP
    AT.TChar -> T.IntegerType 8
    AT.TBoolean -> T.IntegerType 1
    AT.TVoid -> T.void
    AT.TPointer t -> T.ptr (toLLVM t)
    AT.TArray t (Just n) -> T.ArrayType (fromIntegral n) (toLLVM t)
    AT.TArray t Nothing -> T.ptr (toLLVM t)
    _ -> undefined

-- | Generate LLVM code for a program.
codegen :: AT.Program -> Either CodegenError AST.Module
codegen program =
  E.runExcept $
    M.buildModuleT (U.stringToByteString $ AT.sourceFile program) $
      IRM.runIRBuilderT IRM.emptyIRBuilder $
        S.evalStateT (mapM_ (generateGlobal . snd) (AT.globals program)) []

-- | Generate LLVM code for global expressions.
generateGlobal :: (MonadCodegen m) => AT.Expr -> m ()
generateGlobal expr = case expr of
  AT.Function {} -> CM.void $ generateFunction expr
  _ -> E.throwError $ UnsupportedTopLevel expr

-- | Generate LLVM code for an expression.
class ExprGen a where
  generateExpr :: (MonadCodegen m) => a -> m AST.Operand

instance ExprGen AT.Expr where
  generateExpr expr = case expr of
    AT.Lit {} -> generateLiteral expr
    AT.Var {} -> generateVar expr
    AT.Function {} -> generateFunction expr
    AT.Declaration {} -> generateDeclaration expr
    AT.If {} -> generateIf expr
    AT.Block {} -> generateBlock expr
    AT.Return {} -> generateReturn expr
    AT.Op {} -> generateBinaryOp expr
    AT.UnaryOp {} -> generateUnaryOp expr
    _ -> E.throwError $ UnsupportedDefinition expr

-- | Generate LLVM code for literals.
generateLiteral :: (MonadCodegen m) => AT.Expr -> m AST.Operand
generateLiteral (AT.Lit _ lit) = case lit of
  AT.LInt n -> pure . mkConstant $ C.Int 64 (fromIntegral n)
  AT.LChar c -> pure . mkConstant $ C.Int 8 (fromIntegral $ fromEnum c)
  AT.LBool b -> pure . mkConstant $ C.Int 1 (if b then 1 else 0)
  _ -> E.throwError $ UnsupportedLiteral lit
  where
    mkConstant = AST.ConstantOperand
generateLiteral expr =
  E.throwError $ UnsupportedDefinition expr

-- | Generate LLVM code for binary operations.
generateBinaryOp :: (MonadCodegen m) => AT.Expr -> m AST.Operand
generateBinaryOp (AT.Op _ op e1 e2) = do
  v1 <- generateExpr e1
  v2 <- generateExpr e2
  case findOperator op of
    Just f -> f v1 v2
    Nothing -> E.throwError $ UnsupportedOperator op
  where
    findOperator op' = L.find ((== op') . opMapping) binaryOperators >>= Just . opFunction
generateBinaryOp expr =
  E.throwError $ UnsupportedDefinition expr

-- | Binary operation data type.
data BinaryOp m = BinaryOp
  { opMapping :: AT.Operation,
    opFunction :: AST.Operand -> AST.Operand -> m AST.Operand
  }

-- | List of supported binary operators.
binaryOperators :: (MonadCodegen m) => [BinaryOp m]
binaryOperators =
  [ BinaryOp AT.Add I.add,
    BinaryOp AT.Sub I.sub,
    BinaryOp AT.Mul I.mul,
    BinaryOp AT.Div I.sdiv,
    BinaryOp AT.Mod I.srem
  ]
    ++ map mkComparisonOp comparisonOps
  where
    mkComparisonOp (op, pre) = BinaryOp op (I.icmp pre)
    comparisonOps =
      [ (AT.Lt, IP.SLT),
        (AT.Gt, IP.SGT),
        (AT.Lte, IP.SLE),
        (AT.Gte, IP.SGE),
        (AT.Eq, IP.EQ),
        (AT.Ne, IP.NE)
      ]

-- | Unary operation data type.
data UnaryOp m = UnaryOp
  { unaryMapping :: AT.UnaryOperation,
    unaryFunction :: AST.Operand -> IRM.IRBuilderT (M.ModuleBuilderT m) AST.Operand
  }

-- | List of supported unary operators.
unaryOperators :: (MonadCodegen m) => [UnaryOp m]
unaryOperators = undefined

-- | Generate LLVM code for unary operations.
generateUnaryOp :: (MonadCodegen m) => AT.Expr -> m AST.Operand
generateUnaryOp = undefined

-- | Generate LLVM code for variable references.
generateVar :: (MonadCodegen m) => AT.Expr -> m AST.Operand
generateVar (AT.Var _ name _) = do
  maybeVar <- getVar name
  case maybeVar of
    Just ptr -> I.load ptr 0
    Nothing -> E.throwError $ VariableNotFound name
generateVar expr =
  E.throwError $ UnsupportedDefinition expr

-- | Generate LLVM code for blocks.
generateBlock :: (MonadCodegen m) => AT.Expr -> m AST.Operand
generateBlock (AT.Block exprs) = do
  _ <- IRM.block `IRM.named` U.stringToByteString "block"
  last <$> traverse generateExpr exprs
generateBlock expr =
  E.throwError $ UnsupportedDefinition expr

-- | Generate LLVM code for `if` expressions.
generateIf :: (MonadCodegen m) => AT.Expr -> m AST.Operand
generateIf (AT.If _ cond then_ else_) = mdo
  condValue <- generateExpr cond
  test <- I.icmp IP.NE condValue (AST.ConstantOperand $ C.Int 1 0)
  I.condBr test thenBlock elseBlock

  thenBlock <- IRM.block `IRM.named` U.stringToByteString "then"
  thenValue <- generateExpr then_
  I.br mergeBB

  elseBlock <- IRM.block `IRM.named` U.stringToByteString "else"
  elseValue <- maybe (pure $ AST.ConstantOperand $ C.Undef T.void) generateExpr else_
  I.br mergeBB

  mergeBB <- IRM.block `IRM.named` U.stringToByteString "merge"
  I.phi [(thenValue, thenBlock), (elseValue, elseBlock)]
generateIf expr =
  E.throwError $ UnsupportedDefinition expr

-- | Generate LLVM code for function definitions.
generateFunction :: (MonadCodegen m) => AT.Expr -> m AST.Operand
generateFunction = \case
  AT.Function _ name (AT.TFunction ret params False) paramNames body -> do
    let funcName = AST.Name $ U.stringToByteString name
        paramTypes = zipWith mkParam params paramNames
    M.function funcName paramTypes (toLLVM ret) $ \ops -> do
      S.zipWithM_ addVar paramNames ops
      result <- generateExpr body
      I.ret result
  _ -> undefined
  where
    mkParam t n = (toLLVM t, M.ParameterName $ U.stringToByteString n)

-- | Generate LLVM code for declarations.
generateDeclaration :: (MonadCodegen m) => AT.Expr -> m AST.Operand
generateDeclaration (AT.Declaration _ name typ mInitExpr) = do
  let llvmType = toLLVM typ
  ptr <- I.alloca llvmType Nothing 0
  case mInitExpr of
    Just initExpr -> do
      initValue <- generateExpr initExpr
      I.store ptr 0 initValue
    Nothing -> pure ()
  addVar name ptr
  pure ptr
generateDeclaration expr =
  E.throwError $ UnsupportedDefinition expr

-- | Generate LLVM code for return statements.
generateReturn :: (MonadCodegen m) => AT.Expr -> m AST.Operand
generateReturn (AT.Return _ mExpr) = do
  case mExpr of
    Just expr -> do
      result <- generateExpr expr
      I.ret result
      pure result
    Nothing -> do
      I.retVoid
      pure $ AST.ConstantOperand $ C.Undef T.void
generateReturn expr =
  E.throwError $ UnsupportedDefinition expr
