{-|

FCL interpreter and expression evaluation.

-}

{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# OPTIONS_GHC -fno-warn-incomplete-uni-patterns #-}

module Script.Eval (
  -- ** Evaluation monad
  EvalFail(..),
  runEvalM,
  execEvalM,

  -- ** Evaluation rules
  eval,
  evalLLit,
  evalLExpr,
  evalMethod,
  lookupMethod,
  insertTempVar,

  -- ** Evaluation state
  EvalState(..),
  initEvalState,
  scriptToContract,

  -- ** Evaluation context
  EvalCtx(..),
  initEvalCtx,
) where

import Protolude hiding (DivideByZero, Overflow, Underflow)

import Prelude (read)

import Script
import SafeInteger
import SafeString as SS
import Key (PrivateKey)
import Time (Timestamp, posixMicroSecsToDatetime)
import Ledger (World)
import Storage
import Contract (Contract)
import Derivation (addrContract')
import Account (publicKey, readKeys)
import Script.Init (initLocalStorageVars)
import Script.Prim (PrimOp(..))
import Script.Error as Error
import Script.Graph (GraphState(..), terminalLabel, initialLabel)
import Address (Address, rawAddr)
import Utils (panicImpossible)
import qualified Delta
import qualified Contract
import qualified Hash
import qualified Time
import qualified Key
import qualified Ledger
import qualified Script.Storage
import qualified Script.Prim as Prim
import qualified Homomorphic as Homo

import qualified Datetime as DT
import Datetime.Types (within, Interval(..), add, sub, subDeltas, scaleDelta)

import Data.Fixed (Fixed(..), showFixed)
import Data.Hashable
import Data.Serialize (Serialize)
import qualified Data.Map as Map
import qualified Data.Set as Set
import qualified Data.Aeson as A
import qualified Data.Serialize as S
import qualified Data.List as List

import Control.Monad.State
import Control.Monad.Catch
import qualified Control.Exception as E
import Data.Time.Clock.POSIX (getCurrentTime)
import Data.Time.Calendar (fromGregorianValid)

-------------------------------------------------------------------------------
-- Execution State
-------------------------------------------------------------------------------

-- | Evaluation context used during remote evaluation in a validating engine.
data EvalCtx = EvalCtx
  { currentBlock       :: Int64           -- ^ The latest block in the chain
  , currentValidator   :: Address         -- ^ Referencing an account
  , currentTransaction :: ByteString      -- ^ Current transaction hash
  , currentTimestamp   :: Time.Timestamp  -- ^ When the current method is being executed
  , currentCreated     :: Time.Timestamp  -- ^ When the contract was deployed
  , currentDeployer    :: Address         -- ^ Referencing an account
  , currentTxIssuer    :: Address         -- ^ Transaction sender
  , currentAddress     :: Address         -- ^ Address of current Contract
  , currentPrivKey     :: Key.PrivateKey  -- ^ Private key of Validating node
  , currentStorageKey  :: Homo.PubKey     -- ^ Public key for storage homomorphic encryption (RSA public key)
  } deriving (Generic, NFData)

type LocalStorages = Map Address Storage

data EvalState = EvalState
  { tempStorage      :: Storage          -- ^ Tmp variable env
  , globalStorage    :: Storage          -- ^ Global variable env
  , localStorageVars :: Set.Set Name     -- ^ Set of local var names
  , localStorage     :: LocalStorages    -- ^ Local Variable per counter party
  , graphState       :: GraphState       -- ^ Current state of contract
  , worldState       :: World            -- ^ Current world state
  , sideState        :: Maybe SideState  -- ^ Current state
  , sideLock         :: (Bool, Lock)     -- ^ Lock state
  , deltas           :: [Delta.Delta]
  } deriving (Generic, NFData)

data SideState = SideInit | SideStop
  deriving (Generic, NFData)

type Lock = Maybe (Time.Timestamp, Int64)

{- TopLevel:
 -
 - NodeData
 -   > latestBlock index
 -   > node account address
 -   > ledger state
 -   > private key
 -   > storage key
 -
 - Transaction
 -   > current transaction hash
 -   > origin address of transaction
 -
 - Contract
 -   > timestamp
 -   > address
 -}

-- *** Take NodeData as arugment and fill in proper EvalCtx fields
initEvalCtx
  :: Int64      -- ^ Current Block Index
  -> Timestamp  -- ^ Current Block Timestamp
  -> Address    -- ^ Address of Evaluating node
  -> ByteString -- ^ Current Transaction hash
  -> Address    -- ^ Issuer of transaction (tx origin field)
  -> PrivateKey -- ^ Node private key for signing
  -> Contract   -- ^ Contract to which method belongs
  -> IO EvalCtx
initEvalCtx blockIdx blockTs nodeAddr txHash txOrigin privKey c = do
  (pub,_) <- Homo.genRSAKeyPair Homo.rsaKeySize -- XXX: Actual key of validator
  return EvalCtx
    { currentBlock       = blockIdx
    , currentValidator   = nodeAddr
    , currentTransaction = txHash
    , currentTimestamp   = blockTs
    , currentCreated     = Contract.timestamp c
    , currentDeployer    = Contract.owner c
    , currentTxIssuer    = txOrigin
    , currentAddress     = Contract.address c
    , currentPrivKey     = privKey
    , currentStorageKey  = pub
    }

initEvalState :: Contract -> World -> EvalState
initEvalState c w = EvalState
  { tempStorage      = mempty
  , globalStorage    = Storage.unGlobalStorage (Contract.globalStorage c)
  , localStorage     = map Storage.unLocalStorage (Contract.localStorage c)
  , localStorageVars = Contract.localStorageVars c
  , graphState       = Contract.state c
  , sideState        = Nothing
  , sideLock         = (False, Nothing)
  , worldState       = w
  , deltas           = []
  }

-------------------------------------------------------------------------------
-- Interpreter Steps
-------------------------------------------------------------------------------

lookupGlobalVar :: Name -> EvalM (Maybe Value)
lookupGlobalVar (Name var) = do
  globalStore <- gets globalStorage
  return $ Map.lookup (Key $ encodeUtf8 var) globalStore


isLocalVar :: Name -> (EvalM Bool)
isLocalVar name = do
  vars <- gets localStorageVars
  return $ name `Set.member` vars

lookupTempVar :: Name -> EvalM (Maybe Value)
lookupTempVar (Name var) = do
  tmpStore <- gets tempStorage
  return $ Map.lookup (Key $ encodeUtf8 var) tmpStore

insertTempVar :: Name -> Value -> EvalM ()
insertTempVar (Name var) val = modify' $ \evalState ->
    evalState { tempStorage = insertVar (tempStorage evalState) }
  where
    insertVar = Map.insert (Key $ encodeUtf8 var) val

-- | Emit a delta updating  the state of a global reference.
updateGlobalVar :: Name -> Value -> EvalM ()
updateGlobalVar (Name var) val = modify' $ \evalState ->
    evalState { globalStorage = updateVar (globalStorage evalState) }
  where
    updateVar = Map.update (\_ -> Just val) (Key $ encodeUtf8 var)

-- | Updating a local variable only happens if the evaluating node is storing
-- a local storage for an account involved in the contract and method being evaluated
updateLocalVar :: Name -> Value -> EvalM ()
updateLocalVar (Name var) val = modify' $ \evalState ->
    evalState { localStorage = map updateLocalVar' (localStorage evalState) }
  where
    updateLocalVar' :: Storage -> Storage
    updateLocalVar' = Map.insert (Key $ toS var) val

setWorld :: World -> EvalM ()
setWorld w = modify' $ \evalState -> evalState { worldState = w }

-- | Halt if the execution is terminate state.
guardTerminate :: EvalM ()
guardTerminate = do
  s <- gets graphState
  case s of
    GraphTerminal -> throwError TerminalState
    _             -> pure ()

-- | Update the evaluate state.
updateState :: GraphState -> EvalM ()
updateState state = modify $ \s -> s { graphState = state }

-- | Get the evaluation state
getState :: EvalM GraphState
getState = gets graphState

-- | Get the evaluation context
getEvalCtx :: EvalM EvalCtx
getEvalCtx = ask

-- | Emit a delta
emitDelta :: Delta.Delta -> EvalM ()
emitDelta delta = modify' $ \s -> s { deltas = deltas s ++ [delta] }

-- | Lock main graph, switch to side graph
sideInit :: Int64 -> EvalM ()
sideInit timeout = do
  now <- currentTimestamp <$> getEvalCtx
  modify' $ \s -> s { sideState = Just SideInit, sideLock = (True, Just (now, now+timeout)) }

-- | Unlock side graph, switch to main graph
sideUnlock :: EvalM ()
sideUnlock = do
  modify' $ \s -> s { sideState = Nothing, sideLock = (False, Nothing) }

sideStop :: EvalM ()
sideStop = modify' $ \s -> s { sideState = Just SideStop }

-- | Lookup variable in scope
lookupVar :: Name -> EvalM (Maybe Value)
lookupVar var = do
  gVar <- lookupGlobalVar var
  case gVar of
    Nothing  -> lookupTempVar var
    Just val -> return $ Just val

-------------------------------------------------------------------------------
-- Interpreter Monad
-------------------------------------------------------------------------------

-- | EvalM monad
type EvalM = ReaderT EvalCtx (StateT EvalState (ExceptT Error.EvalFail IO))

-- | Run the evaluation monad.
execEvalM :: EvalCtx -> EvalState -> EvalM a -> IO (Either Error.EvalFail EvalState)
execEvalM evalCtx evalState = runExceptT . flip execStateT evalState . flip runReaderT evalCtx

-- | Run the evaluation monad.
runEvalM :: EvalCtx -> EvalState -> EvalM a -> IO (Either Error.EvalFail (a, EvalState))
runEvalM evalCtx evalState = runExceptT . flip runStateT evalState . flip runReaderT evalCtx

-------------------------------------------------------------------------------
-- Evaluation
-------------------------------------------------------------------------------

-- | Evaluator for expressions
evalLExpr :: LExpr -> EvalM Value
evalLExpr (Located _ e) = case e of

  ESeq a b        -> evalLExpr a >> evalLExpr b

  ERet a          -> evalLExpr a

  ELit llit       -> pure $ evalLLit llit

  EAssign lhs rhs -> do
    gVal <- lookupGlobalVar lhs
    case gVal of
      Nothing -> do
        isLhsLocal <- isLocalVar lhs
        if isLhsLocal
           then evalAssignLocal lhs rhs
           else do
             v <- evalLExpr rhs
             insertTempVar lhs v
      Just _  -> do
        res <- evalLExpr rhs
        updateGlobalVar lhs res
        emitDelta $ Delta.ModifyGlobal lhs res

    pure VVoid

      where
        evalAssignLocal :: Name -> LExpr -> EvalM ()
        evalAssignLocal lhs rhs = do
          case locVal rhs of

            -- RHS is a local variable: emit Replace delta
            EVar lvar -> do
              isRhsLocal <- isLocalVar $ locVal lvar
              if isRhsLocal
                then do
                  evalAndUpdateLocal lhs rhs
                  emitDelta $ Delta.ModifyLocal lhs $ Delta.Replace (locVal lvar)
                else panicImpossible $ Just "Assigning a local var to a non local var"

            -- RHS is a BinOp with a local var at the top level: emit Op delta
            EBinOp locOp x y -> do
              let op = locVal locOp
              case (locVal x, locVal y) of

                (EVar var1, EVar var2)
                  -- If var1 is LHS local var, eval y and emit delta
                  | locVal var1 == lhs -> do
                      evalAndUpdateLocal lhs rhs
                      yVal <- evalLExpr y
                      emitDelta $ Delta.ModifyLocal (locVal var1) $ Delta.Op op yVal

                  -- If var2 is LHS local var, eval x and emit delta
                  | locVal var2 == lhs -> do
                      evalAndUpdateLocal lhs rhs
                      xVal <- evalLExpr x
                      emitDelta $ Delta.ModifyLocal (locVal var2) $ Delta.Op op xVal

                  | otherwise -> panicImpossible $
                      Just "evalAssignLocal: var1 or var2 must be local variables"

                (EVar var, e) -> do
                  let varName = locVal var
                  if varName == lhs
                    then do -- IFF var x is the local var on LHS, eval y and emit delta
                      evalAndUpdateLocal lhs rhs
                      yVal <- evalLExpr y
                      emitDelta $ Delta.ModifyLocal varName $ Delta.Op op yVal
                    else panicImpossible $
                      Just "evalAssignLocal: var must be local variable"

                (e, EVar var) -> do
                  let varName = locVal var
                  if varName == lhs
                    then do -- IFF var y is the local var on LHS, eval x and emit delta
                      evalAndUpdateLocal lhs rhs
                      xVal <- evalLExpr x
                      emitDelta $ Delta.ModifyLocal varName $ Delta.Op op xVal
                    else panicImpossible $
                      Just "evalAssignLocal: var must be local variable"

                _ -> panicImpossible $ Just "Local var binops have to have a local var on either the lhs or rhs"

            _ -> panicImpossible $ Just "Local var binops have to have a local var on either the lhs or rhs"

        -- If local var exists in memory (issuer or counterparty interacting
        -- with contract) then update it's value in memory
        evalAndUpdateLocal :: Name -> LExpr -> EvalM ()
        evalAndUpdateLocal localVar e =
          flip catchError (const $ pure ()) $ do
            eVal <- evalLExpr e
            updateLocalVar localVar eVal

  EUnOp (Located _ op) a -> do
    valA <- evalLExpr a
    let unOpFail = panicInvalidUnOp op valA
    case valA of
      VBool a' -> return $
        case op of
          Script.Not -> VBool $ not a'
      _ -> panicImpossible $ Just "EUnOp"

  -- This logic handles the special cases of operating over homomorphic
  -- crypto-text.
  EBinOp (Located _ op) a b -> handleArithError $ do
    valA <- evalLExpr a
    valB <- evalLExpr b
    let binOpFail = panicInvalidBinOp op valA valB
    case (valA, valB) of
      (VCrypto a', VCrypto b') ->
        case op of
          Script.Add -> VCrypto <$> homoAdd a' b'
          Script.Sub -> VCrypto <$> homoSub a' b'
          _ -> binOpFail
      (VCrypto a', VInt b') ->
        case op of
          Script.Mul -> VCrypto <$> homoMul a' b'
          _ -> binOpFail
      (VInt a', VCrypto b') ->
        case op of
          Script.Mul -> VCrypto <$> homoMul b' a'
          _ -> binOpFail
      (VInt a', VInt b') ->
        case op of
          Script.Add -> pure $ VInt (a' + b')
          Script.Sub -> pure $ VInt (a' - b')
          Script.Div ->
            if b' == 0
              then throwError DivideByZero
              else pure $ VInt (a' `div` b')
          Script.Mul     -> pure $ VInt (a' * b')
          Script.Equal   -> pure $ VBool $ a' == b'
          Script.NEqual  -> pure $ VBool $ a' /= b'
          Script.LEqual  -> pure $ VBool $ a' <= b'
          Script.GEqual  -> pure $ VBool $ a' >= b'
          Script.Lesser  -> pure $ VBool $ a' < b'
          Script.Greater -> pure $ VBool $ a' > b'
          _ -> binOpFail
      (VFloat a', VFloat b') -> evalBinOpF op VFloat a' b'
      (VFixed a', VFixed b') ->
        case (a',b') of
          (Fixed1 x, Fixed1 y) -> evalBinOpF op (VFixed . Fixed1) x y
          (Fixed2 x, Fixed2 y) -> evalBinOpF op (VFixed . Fixed2) x y
          (Fixed3 x, Fixed3 y) -> evalBinOpF op (VFixed . Fixed3) x y
          (Fixed4 x, Fixed4 y) -> evalBinOpF op (VFixed . Fixed4) x y
          (Fixed5 x, Fixed5 y) -> evalBinOpF op (VFixed . Fixed5) x y
          (Fixed6 x, Fixed6 y) -> evalBinOpF op (VFixed . Fixed6) x y
          (_,_) -> binOpFail
      (VDateTime (DateTime dt), VTimeDelta (TimeDelta d)) ->
        case op of
          Script.Add -> pure $ VDateTime $ DateTime $ add dt d
          Script.Sub -> pure $ VDateTime $ DateTime $ sub dt d
          _ -> binOpFail
      (VTimeDelta (TimeDelta d), VDateTime (DateTime dt)) ->
        case op of
          Script.Add -> pure $ VDateTime $ DateTime $ add dt d
          Script.Sub -> pure $ VDateTime $ DateTime $ sub dt d
          _ -> binOpFail
      (VTimeDelta (TimeDelta d1), VTimeDelta (TimeDelta d2)) ->
        case op of
          Script.Add -> pure $ VTimeDelta $ TimeDelta $ d1 <> d2
          Script.Sub -> pure $ VTimeDelta $ TimeDelta $ subDeltas d1 d2
          _ -> binOpFail
      (VTimeDelta (TimeDelta d), VInt n) ->
        case op of
          Script.Mul ->
            case scaleDelta (fromIntegral n) d of
              Nothing -> binOpFail -- XXX More descriptive error
              Just newDelta -> pure $ VTimeDelta $ TimeDelta newDelta
          _ -> binOpFail
      (VBool a', VBool b') -> return $
        case op of
          Script.And -> VBool (a' && b')
          Script.Or  -> VBool (a' || b')
          Script.Equal -> VBool $ a' == b'
          Script.NEqual -> VBool $ a' /= b'
          _ -> binOpFail
      (VAccount a', VAccount b') -> return $
        case op of
          Script.Equal -> VBool $ a' == b'
          Script.NEqual -> VBool $ a' /= b'
          _ -> binOpFail
      (VAsset a', VAsset b') -> return $
        case op of
          Script.Equal -> VBool $ a' == b'
          Script.NEqual -> VBool $ a' /= b'
          _ -> binOpFail
      (VContract a', VContract b') -> return $
        case op of
          Script.Equal -> VBool $ a' == b'
          Script.NEqual -> VBool $ a' /= b'
          _ -> binOpFail
      (VDateTime a', VDateTime b') -> return $
        case op of
          Script.Equal -> VBool $ a' == b'
          Script.NEqual -> VBool $ a' /= b'
          Script.LEqual -> VBool $ a' <= b'
          Script.GEqual -> VBool $ a' >= b'
          Script.Lesser -> VBool $ a' < b'
          Script.Greater -> VBool $ a' > b'
          _ -> binOpFail
      (VMsg a', VMsg b') -> return $
        case op of
          Script.Equal -> VBool $ a' == b'
          Script.NEqual -> VBool $ a' /= b'
          Script.LEqual -> VBool $ a' <= b'
          Script.GEqual -> VBool $ a' >= b'
          Script.Lesser -> VBool $ a' < b'
          Script.Greater -> VBool $ a' > b'
          Script.Add -> VMsg $ a' <> b'
          _ -> binOpFail
      (v1, v2) -> panicImpossible $ Just $
        "evalLExpr EBinOp: (" <> show v1 <> ", " <> show v2 <> ")"

  EVar (Located _ var) -> do
    mVal <- lookupVar var
    case mVal of
      Nothing -> do
        isLocal <- isLocalVar var
        if isLocal
          then throwError $ LocalVarNotFound (unName var)
          else panicImpossible $ Just "evalLExpr: EVar"
      Just val -> return val

  ECall f args   -> do
    case Prim.lookupPrim f of
      Nothing -> throwError $ NoSuchMethod f
      Just prim -> evalPrim prim args

  EBefore dt e -> do
    now <- currentTimestamp <$> getEvalCtx
    let noLoc = Located NoLoc
    let nowDtLLit  = noLoc $ LDateTime $ DateTime $ posixMicroSecsToDatetime now
    let predicate = EBinOp (noLoc LEqual) dt (noLoc $ ELit nowDtLLit)
    evalLExpr $ noLoc $ EIf (noLoc predicate) e (noLoc ENoOp)

  EAfter dt e -> do
    now <- currentTimestamp <$> getEvalCtx
    let noLoc = Located NoLoc
    let nowDtLLit  = noLoc $ LDateTime $ DateTime $ posixMicroSecsToDatetime now
    let predicate = EBinOp (noLoc GEqual) dt (noLoc $ ELit nowDtLLit)
    evalLExpr $ noLoc $ EIf (noLoc predicate) e (noLoc ENoOp)

  EBetween startDte endDte e -> do
    now <- currentTimestamp <$> getEvalCtx
    let noLoc = Located NoLoc
    let nowDtLExpr = noLoc $ ELit $ noLoc $
          LDateTime $ DateTime $ posixMicroSecsToDatetime now
    VBool b <- evalPrim Between [nowDtLExpr, startDte, endDte]
    if b
      then evalLExpr e
      else noop

  EIf cond e1 e2 -> do
    VBool b <- evalLExpr cond
    if b
      then evalLExpr e1
      else evalLExpr e2

  ENoOp       -> noop

-- | Evaluate a binop and two Fractional Num args
evalBinOpF :: (Fractional a, Ord a) => BinOp -> (a -> Value) -> a -> a -> EvalM Value
evalBinOpF Script.Add constr a b = pure $ constr (a + b)
evalBinOpF Script.Sub constr a b = pure $ constr (a - b)
evalBinOpF Script.Mul constr a b = pure $ constr (a * b)
evalBinOpF Script.Div constr a b
  | b == 0 = throwError DivideByZero
  | otherwise = pure $ constr (a / b)
evalBinOpF Script.Equal constr a b = pure $ VBool (a == b)
evalBinOpF Script.NEqual constr a b = pure $ VBool (a /= b)
evalBinOpF Script.LEqual constr a b = pure $ VBool (a <= b)
evalBinOpF Script.GEqual constr a b = pure $ VBool (a >= b)
evalBinOpF Script.Lesser constr a b = pure $ VBool (a < b)
evalBinOpF Script.Greater constr a b = pure $ VBool (a > b)
evalBinOpF bop c a b = panicInvalidBinOp bop (c a) (c b)

handleArithError :: EvalM Value -> EvalM Value
handleArithError m = do
   res <- Control.Monad.Catch.try $! m
   case res of
    Left E.Overflow              -> throwError $ Overflow
    Left E.Underflow             -> throwError $ Underflow
    Left (e :: E.ArithException) -> throwError $ Impossible "Arithmetic exception"
    Right val                    -> pure val

evalPrim :: PrimOp -> [LExpr] -> EvalM Value
evalPrim ex args = case ex of
  Now            -> do
    currDatetime <- posixMicroSecsToDatetime . currentTimestamp <$> getEvalCtx
    pure $ VDateTime $ DateTime currDatetime
  Block          -> VInt . currentBlock <$> getEvalCtx
  Deployer       -> VAccount . currentDeployer <$> getEvalCtx
  Sender         -> VAccount . currentTxIssuer <$> getEvalCtx
  Created        -> VInt . currentCreated <$> getEvalCtx
  Address        -> VContract . currentAddress <$> getEvalCtx
  Validator      -> VAccount . currentValidator <$> getEvalCtx

  Fixed1ToFloat  -> do
    let [eFixed] = args
    VFixed (Fixed1 (F1 n)) <- evalLExpr eFixed
    pure $ VFloat $ read $ showFixed False n

  Fixed2ToFloat  -> do
    let [eFixed] = args
    VFixed (Fixed2 (F2 n)) <- evalLExpr eFixed
    pure $ VFloat $ read $ showFixed False n

  Fixed3ToFloat  -> do
    let [eFixed] = args
    VFixed (Fixed3 (F3 n)) <- evalLExpr eFixed
    pure $ VFloat $ read $ showFixed False n

  Fixed4ToFloat  -> do
    let [eFixed] = args
    VFixed (Fixed4 (F4 n)) <- evalLExpr eFixed
    pure $ VFloat $ read $ showFixed False n

  Fixed5ToFloat  -> do
    let [eFixed] = args
    VFixed (Fixed5 (F5 n)) <- evalLExpr eFixed
    pure $ VFloat $ read $ showFixed False n

  Fixed6ToFloat  -> do
    let [eFixed] = args
    VFixed (Fixed6 (F6 n)) <- evalLExpr eFixed
    pure $ VFloat $ read $ showFixed False n

  FloatToFixed1  -> evalFloatToFixed Prec1 args
  FloatToFixed2  -> evalFloatToFixed Prec2 args
  FloatToFixed3  -> evalFloatToFixed Prec3 args
  FloatToFixed4  -> evalFloatToFixed Prec4 args
  FloatToFixed5  -> evalFloatToFixed Prec5 args
  FloatToFixed6  -> evalFloatToFixed Prec6 args

  Terminate -> do
    let [Located l (LMsg msg)] = argLits (fmap unLoc args)
    emitDelta $ Delta.ModifyState GraphTerminal
    emitDelta $ Delta.Terminate $ SS.toBytes msg
    updateState GraphTerminal
    pure VVoid

  Transition     -> do
    let [Located l (LState label)] = argLits (fmap unLoc args)
    emitDelta $ Delta.ModifyState (GraphLabel label)
    updateState (GraphLabel label)
    pure VVoid

  CurrentState   -> do
    gst <- getState
    case gst of
      GraphTerminal    -> pure (VState terminalLabel)
      GraphInitial     -> pure (VState initialLabel)
      GraphLabel label -> pure (VState label)

  Sign           -> do
    let [msgExpr] = args
    (VMsg msg) <- evalLExpr msgExpr
    privKey <- currentPrivKey <$> getEvalCtx -- XXX               V gen Random value?
    sig <- liftIO $
      Key.getSignatureRS <$>
        Key.sign privKey (SS.toBytes msg)
    case bimap toSafeInteger toSafeInteger sig of
      (Right safeR, Right safeS) -> return $ VSig (safeR,safeS)
      otherwise -> throwError $
        HugeInteger "Signature values (r,s) too large."

  Sha256         -> do
    let [anyExpr] = args
    x <- evalLExpr anyExpr
    v <- hashValue x
    case SS.fromBytes (Hash.sha256 v) of
      Left err -> throwError $ HugeString $ show err
      Right msg -> return $ VMsg msg

  AccountExists  -> do
    let [varExpr] = args
    accAddr <- extractAddr <$> evalLExpr varExpr
    world <- gets worldState
    return $ VBool $ Ledger.accountExists accAddr world

  AssetExists    -> do
    let [varExpr] = args
    assetAddr <- extractAddr <$> evalLExpr varExpr
    world <- gets worldState
    return $ VBool $ Ledger.assetExists assetAddr world

  ContractExists -> do
    let [varExpr] = args
    contractAddr <- extractAddr <$> evalLExpr varExpr
    world <- gets worldState
    return $ VBool $ Ledger.contractExists contractAddr world

  -- From Account to Contract
  Prim.TransferTo  -> do
    let [assetExpr,holdingsExpr] = args

    senderAddr <- currentTxIssuer <$> getEvalCtx
    contractAddr <- currentAddress <$> getEvalCtx
    assetAddr <- getAssetAddr assetExpr
    (VInt holdings) <- evalLExpr holdingsExpr

    -- Modify the world (perform the transfer)
    world <- gets worldState
    case Ledger.transferAsset assetAddr senderAddr contractAddr holdings world of
      Left err -> throwError $ AssetIntegrity $ show err
      Right newWorld -> setWorld newWorld

    -- Emit the delta denoting the world state modification
    emitDelta $ Delta.ModifyAsset $
      Delta.TransferTo assetAddr holdings senderAddr contractAddr

    noop

  -- From Contract to Account
  Prim.TransferFrom  -> do
    let [assetExpr,holdingsExpr,accExpr] = args

    contractAddr <- currentAddress <$> getEvalCtx
    assetAddr <- getAssetAddr assetExpr
    accAddr <- getAccountAddr accExpr
    (VInt holdings) <- evalLExpr holdingsExpr

    -- Modify the world (perform the transfer)
    world <- gets worldState
    case Ledger.transferAsset assetAddr contractAddr accAddr holdings world of
      Left err -> throwError $ AssetIntegrity $ show err
      Right newWorld -> setWorld newWorld

    -- Emit the delta denoting the world state modification
    emitDelta $ Delta.ModifyAsset $
      Delta.TransferFrom assetAddr holdings accAddr contractAddr

    noop

  -- From Account to Account
  TransferHoldings -> do
    let [fromExpr,assetExpr,holdingsExpr,toExpr] = args

    assetAddr <- getAssetAddr assetExpr
    fromAddr <- getAccountAddr fromExpr
    toAddr <- getAccountAddr toExpr
    VInt holdings <- evalLExpr holdingsExpr

    -- Modify the world (perform the transfer)
    world <- gets worldState
    case Ledger.transferAsset assetAddr fromAddr toAddr holdings world of
      Left err -> throwError $ AssetIntegrity $ show err
      Right newWorld -> setWorld newWorld

    -- Emit the delta denoting the world state modification
    emitDelta $ Delta.ModifyAsset $
      Delta.TransferHoldings fromAddr assetAddr holdings toAddr

    noop

  Verify         -> do
    let [accExpr,sigExpr,msgExpr] = args
    accAddr <- extractAddr <$> evalLExpr accExpr
    (VSig safeSig) <- evalLExpr sigExpr
    (VMsg msg) <- evalLExpr sigExpr
    ledgerState <- gets worldState

    case Ledger.lookupAccount accAddr ledgerState of
      Left err -> throwError $ AccountIntegrity "No account with address"
      Right acc -> do
        let sig = bimap fromSafeInteger fromSafeInteger safeSig
        return $ VBool $
          Key.verify (publicKey acc) (Key.mkSignatureRS sig) $ SS.toBytes msg

  TxHash -> do
    hash <- currentTransaction <$> getEvalCtx
    case SS.fromBytes hash of
      Left err -> throwError $ HugeString $ show err
      Right msg -> pure $ VMsg msg

  ContractValue -> do
    let [contractExpr, msgExpr] = args
    contractAddr <- extractAddr <$> evalLExpr contractExpr
    world <- gets worldState
    case Ledger.lookupContract contractAddr world of
      Left err -> throwError $ ContractIntegrity $ show err
      Right contract -> do
        (VMsg msgSS) <- evalLExpr msgExpr
        let msgBS = SS.toBytes msgSS
        case Contract.lookupVarGlobalStorage msgBS contract of
          Nothing -> throwError $ ContractIntegrity $
            "Contract does not define a variable named " <> decodeUtf8 msgBS
          Just val -> pure val

  ContractValueExists -> do
    -- If ContractValue throws err, value doesn't exist
    flip catchError (const $ pure $ VBool False) $ do
      _ <- evalPrim ContractValue args
      pure $ VBool True

  ContractState -> do
    let [contractExpr] = args
    contractAddr <- extractAddr <$> evalLExpr contractExpr
    world <- gets worldState
    case Ledger.lookupContract contractAddr world of
      Left err -> throwError $ ContractIntegrity $ show err
      Right contract -> pure $ VState $
        case Contract.state contract of
          GraphInitial     -> Script.Graph.initialLabel
          GraphTerminal    -> Script.Graph.terminalLabel
          GraphLabel label -> label

  NovationInit -> do
    let [timeout] = args
    VInt timeout' <- evalLExpr timeout
    sideInit timeout'
    noop

  NovationStop -> do
    sideStop
    noop

  -- Datetime manipulation prim ops

  IsBusinessDayUK -> do
    let [dateTimeExpr] = args
    VDateTime (DateTime dt) <- evalLExpr dateTimeExpr
    return $ VBool $ DT.isBusiness DT.ukHolidays dt

  NextBusinessDayUK -> do
    let [dateTimeExpr] = args
    VDateTime (DateTime dt) <- evalLExpr dateTimeExpr
    return $ VDateTime $ DateTime $ DT.nextBusinessDay DT.ukHolidays dt

  IsBusinessDayNYSE -> do
    let [dateTimeExpr] = args
    VDateTime (DateTime dt) <- evalLExpr dateTimeExpr
    return $ VBool $ DT.isBusiness DT.nyseHolidays dt

  NextBusinessDayNYSE -> do
    let [dateTimeExpr] = args
    VDateTime (DateTime dt) <- evalLExpr dateTimeExpr
    return $ VDateTime $ DateTime $ DT.nextBusinessDay DT.nyseHolidays dt

  Between -> do
    let [dtExpr, startExpr, endExpr] = args
    VDateTime (DateTime dt) <- evalLExpr dtExpr
    VDateTime (DateTime start) <- evalLExpr startExpr
    VDateTime (DateTime end) <- evalLExpr endExpr
    return $ VBool $ within dt (Interval start end)

  Bound -> notImplemented -- XXX

getAccountAddr :: LExpr -> EvalM Address
getAccountAddr accExpr = do
  ledgerState <- gets worldState
  accAddr <- extractAddr <$> evalLExpr accExpr
  unless (Ledger.accountExists accAddr ledgerState) $
    throwError $ AccountIntegrity ("No account with address: " <> show accAddr)
  return accAddr

getAssetAddr :: LExpr -> EvalM Address
getAssetAddr assetExpr = do
  ledgerState <- gets worldState
  assetAddr <- extractAddr <$> evalLExpr assetExpr
  unless (Ledger.assetExists assetAddr ledgerState) $
    throwError $ AssetIntegrity ("No asset with address: " <> show assetAddr)
  return assetAddr

checkSideGraph :: Method -> EvalM ()
checkSideGraph meth = do
  (locked, ~(Just (lockStart, delta))) <- gets sideLock
  case locked of
    True  -> do
      now <- currentTimestamp <$> getEvalCtx
      -- lock timeout
      if now > (lockStart + delta)
        then sideUnlock
        else do
          -- subgraph check
          case methodTag meth of
            Subg _ -> pure () -- we're in subgraph
            Main _ -> throwError SubgraphLock
    False -> pure ()

-- | Check graph state is legal.
checkGraph :: Method -> EvalM ()
checkGraph meth = do
  st <- getState
  case methodTag meth of
    Subg _ -> panic "Impossible" -- XXX: fix me
    Main tag -> do
      when (st /= handleTag tag) $
        throwError $ InvalidState tag st
  where
    handleTag :: Label -> GraphState
    handleTag "initial" = GraphInitial
    handleTag "terminal" = GraphTerminal
    handleTag lab = GraphLabel lab

-- | Does not perform typechecking on args supplied, eval should only happen
-- after typecheck.
evalMethod :: Method -> [Value] -> EvalM Value
evalMethod meth @ (Method _ (Name nm) argTyps body) args
  | numArgs /= numArgsGiven = throwError $
      MethodArityError nm numArgs numArgsGiven
  | otherwise = do
      -- Sidegraph precondition check
      checkSideGraph meth
      checkGraph meth
      let argNms = map (\(Arg _ lname) -> locVal lname) argTyps
      forM_ (zip argNms args) $ uncurry $ insertTempVar
      evalLExpr body
  where
    numArgs = length argTyps
    numArgsGiven = length args

-- | Evaluation entry
eval :: Script -> Name -> [Value] -> EvalM Value
eval sc nm args = case lookupMethod sc nm of
  Just method -> do
    -- Check if we can procceed
    guardTerminate
    -- Evaluate the named method
    evalMethod method args

  Nothing     -> throwError (NoSuchMethod nm)

evalFloatToFixed :: PrecN -> [LExpr] -> EvalM Value
evalFloatToFixed prec args = do
  let [eFloat] = args
  VFloat float <- evalLExpr eFloat
  pure $ VFixed $ floatToFixed prec float

noop :: EvalM Value
noop = pure VVoid

extractAddr :: Value -> Address
extractAddr (VAddress addr) = addr
extractAddr (VAccount addr) = addr
extractAddr (VAsset addr) = addr
extractAddr (VContract addr) = addr
extractAddr _ = panicImpossible $ Just "extractAddr"

lookupMethod :: Script -> Name -> Maybe Method
lookupMethod (Script defs graph meths) nm = find (\x -> methodName x == nm) meths

floatToFixed :: PrecN -> Double -> FixedN
floatToFixed Prec1 = Fixed1 . F1 . MkFixed . round . (*) (10^1)
floatToFixed Prec2 = Fixed2 . F2 . MkFixed . round . (*) (10^2)
floatToFixed Prec3 = Fixed3 . F3 . MkFixed . round . (*) (10^3)
floatToFixed Prec4 = Fixed4 . F4 . MkFixed . round . (*) (10^4)
floatToFixed Prec5 = Fixed5 . F5 . MkFixed . round . (*) (10^5)
floatToFixed Prec6 = Fixed6 . F6 . MkFixed . round . (*) (10^6)

-------------------------------------------------------------------------------
-- Value Hashing
-------------------------------------------------------------------------------

{-# INLINE hashValue #-}
hashValue :: Value -> EvalM ByteString
hashValue = \case
  VMsg msg       -> pure $ SS.toBytes msg
  VInt n         -> pure (show n)
  VCrypto n      -> pure (show n)
  VFloat n       -> pure (show n)
  VFixed n       -> pure (show n)
  VBool n        -> pure (show n)
  VState n       -> pure (show n)
  VAddress a     -> pure (rawAddr a)
  VAccount a     -> pure (rawAddr a)
  VContract a    -> pure (rawAddr a)
  VAsset a       -> pure (rawAddr a)
  VVoid          -> pure ""
  VDateTime dt   -> pure $ S.encode dt
  VTimeDelta d   -> pure $ S.encode d
  VSig _         -> throwError $ Impossible "Cannot hash signature"
  VUndefined     -> throwError $ Impossible "Cannot hash undefined"

scriptToContract
  :: Timestamp    -- ^ Timestamp of creation
  -> Address      -- ^ Address of Contract Owner
  -> Script       -- ^ AST
  -> Contract
scriptToContract ts cOwner s =
  Contract.Contract
    { timestamp        = ts
    , script           = s
    , localStorage     = Map.empty
    , globalStorage    = gs
    , localStorageVars = initLocalStorageVars s
    , methods          = Script.methodNames s
    , state            = GraphInitial
    , owner            = cOwner
    , address          = cAddress
    }
  where
    gs = Script.Storage.initStorage s
    methodNames = Script.methodNames s
    cAddress = Derivation.addrContract' ts gs

-------------------------------------------------------------------------------
  -- Eval specific errors
-------------------------------------------------------------------------------

panicInvalidBinOp :: BinOp -> Value -> Value -> a
panicInvalidBinOp op x y = panicImpossible $ Just $
  "Operator " <> show op <> " cannot be used with " <> show x <> " and " <> show y

panicInvalidUnOp :: UnOp -> Value -> a
panicInvalidUnOp op x = panicImpossible $ Just $
  "Operator " <> show op <> " cannot be used with " <> show x

-------------------------------------------------------------------------------
-- Homomorphic Binary Ops
-------------------------------------------------------------------------------

homoOp
  :: (Homo.PubKey -> Homo.CipherText -> Homo.CipherText -> Homo.CipherText)
  -> SafeInteger
  -> SafeInteger
  -> EvalM SafeInteger
homoOp f a b = do
  let a' = Homo.CipherText $ fromSafeInteger a
  let b' = Homo.CipherText $ fromSafeInteger b
  pubKey <- currentStorageKey <$> getEvalCtx

  let ct = f pubKey a' b'
  convertToSafeInteger ct

-- | Homomorphic addition of two encrypted SafeIntegers
homoAdd :: SafeInteger -> SafeInteger -> EvalM SafeInteger
homoAdd = homoOp Homo.cipherAdd

-- | Homomorphic subtraction of two encrypted SafeIntegers
homoSub :: SafeInteger -> SafeInteger -> EvalM SafeInteger
homoSub = homoOp Homo.cipherSub

-- | Multiplies an ecrypted SafeInteger by an Int64 value
homoMul :: SafeInteger -> Int64 -> EvalM SafeInteger -- XXX is this safe? Probably not
homoMul a b = do
  let a' = Homo.CipherText $ fromSafeInteger a
  let b' = toInteger b
  pubKey <- currentStorageKey <$> getEvalCtx

  let ct = Homo.cipherMul pubKey a' b'
  convertToSafeInteger ct

convertToSafeInteger :: Homo.CipherText -> EvalM SafeInteger
convertToSafeInteger (Homo.CipherText c) = case toSafeInteger c of
  Left err -> throwError $ HomomorphicFail $ show err
  Right safeInt -> return safeInt
