{-|

Transaction and block validation rules.

This module contains the business logic for validating two data structures with
respect to the chain rules and world state: Blocks and Transactions.

Both Blocks and Transaction have properties necessary to validate, but the crux
of validation is with respect to Transaction Headers. Transaction headers
contain all the data relevant to updating the world state and thus will require
the most validation logic when validating against the current world state.

-}

{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE TupleSections #-}

module Validate (

  ApplyCtx(..),

  -- ** Block Validation
  validateBlock,
  verifyBlock,
  verifyAndValidateBlock,

  -- ** Transaction Validation
  validateTransactionOrigin,
  validateTransactions,
  verifyTransaction,

  -- ** Apply Block to World
  applyBlock,
  applyTransactions,

) where

import Protolude hiding (throwError)

import Control.Monad.State

import Data.DList (DList)
import qualified Data.DList as DL
import qualified Data.Map as Map

import Address (Address)
import Asset (Asset, createAsset)
import Block (Block(..))
import Contract (Contract)
import Delta (Delta(..))
import Ledger (World)
import Transaction (Transaction(..))
import SafeString (toBytes)

import qualified Key
import qualified Time
import qualified Asset
import qualified Block
import qualified Delta
import qualified Ledger
import qualified Account
import qualified Address
import qualified Storage
import qualified Contract
import qualified Transaction as Tx

import qualified Script
import qualified Script.Eval as Eval
import qualified Script.Init
import qualified Script.Typecheck as TC

import qualified Consensus.Authority.Types as CAT

-- | Verifies a block by verifying and validating all transactions
verifyAndValidateBlock :: ApplyCtx -> World -> Block -> IO (Either Block.InvalidBlock ())
verifyAndValidateBlock applyCtx world block = do
  let blockVerf = verifyBlock world block
  blockValid <- validateBlock applyCtx world block
  pure $ blockVerf >> blockValid

-------------------------------------------------------------------------------
-- Block Validation w/ Respect to World State
-------------------------------------------------------------------------------

-- | Validate a block w/ Respect to World state
validateBlock :: ApplyCtx -> World -> Block -> IO (Either Block.InvalidBlock ())
validateBlock ctx world block = do
  (_,invalidTxs,_) <- applyBlock ctx world block
  case head invalidTxs of
    Nothing  -> pure $ Right ()
    Just err -> pure $ Left $ Block.InvalidBlockTx err

-------------------------------------------------------------------------------
-- Transaction Validation w/ Respect to World State
-------------------------------------------------------------------------------

{-

* Timestamp is within threshold and valid
* Signature is valid
* TxHeader is valid with respect to world state
* Issuer address exists & is valid

-}
-- | Validate a transaction based on world state
validateTransactionOrigin :: World -> Transaction -> Either Tx.InvalidTransaction ()
validateTransactionOrigin world tx@Transaction{..} =
    case Tx.header tx of
      -- CreateAccount Tx could be self-signed so no need to lookup account
      Tx.TxAccount (Tx.CreateAccount pubKey _ _) -> Right ()
      -- If not self-signed CreateAccount Tx, transaction is invalid
      otherwise -> case Ledger.lookupAccount origin world of
        Left _ -> Left $ mkInvalidTx $ Tx.NoSuchOriginAccount origin
        Right _ -> Right ()
  where
    mkInvalidTx = Tx.InvalidTransaction tx

-- | Validate a sequence of transactions with accumulating world state
validateTransactions
  :: ApplyCtx
  -> World
  -> [Transaction]
  -> IO (Either [Tx.InvalidTransaction] ())
validateTransactions ctx world txs = do
  (_,invalidTxErrs,_) <- applyTransactions ctx world txs
  case invalidTxErrs of
    []   -> pure $ Right ()
    errs -> pure $ Left errs

-------------------------------------------------------------------------------
-- Block & Transaction Verification (Signatures)
-------------------------------------------------------------------------------

-- | Verify block signatures & hash
verifyBlock :: World -> Block -> Either Block.InvalidBlock ()
verifyBlock world block =
  let genAddr = Block.origin (Block.header block) in
  case Ledger.lookupAccount genAddr world of
    Left err -> Left $ Block.InvalidBlockOrigin genAddr
    Right acc ->
      forM_ (Block.signatures block) $ \(Block.BlockSignature signature signerAddr) -> do
        let blockHash = Block.hashBlock block
        case Ledger.lookupAccount signerAddr world of
          Left _ -> Left $ Block.InvalidBlockSigner signerAddr
          Right acc -> do
            let accPubKey = Account.publicKey acc
            let blockTxs  = Block.transactions block
            verifyBlock' accPubKey signature blockHash blockTxs
  where
    verifyBlock' pubKey sig blockHash txs
      | Key.verify pubKey sig blockHash =
          first Block.InvalidBlockTx $
            mapM_ (verifyTransaction world) txs
      | otherwise = Left $ Block.InvalidBlockSignature $
          Block.InvalidBlockSig $ Key.InvalidSignature sig blockHash

-- | Verify a transaction signature & hash
verifyTransaction :: World -> Transaction -> Either Tx.InvalidTransaction ()
verifyTransaction world tx@Transaction{..} = do
  let mkInvalidTx = Tx.InvalidTransaction tx
  case header of
    Tx.TxAccount (Tx.CreateAccount pub _ _) ->
        case Key.tryDecodePub pub of
          Left _ -> Left $ mkInvalidTx Tx.InvalidPubKey
          Right pub' ->
            first (mkInvalidTx . Tx.InvalidTxField . Tx.InvalidTxSignature) $
              Tx.verifyTransaction pub' tx
    otherwise ->
      case Ledger.lookupAccount origin world of
        Left _ -> Left $ mkInvalidTx $ Tx.NoSuchOriginAccount origin
        Right acc ->
          first (mkInvalidTx . Tx.InvalidTxField . Tx.InvalidTxSignature) $
            Tx.verifyTransaction (Account.publicKey acc) tx

-------------------------------------------------------------------------------
-- Apply Block Transactions to World State
-------------------------------------------------------------------------------

-- | This datatype hosts values necessary for evaluating the TxAsset Call
-- transaction and applying it to the world state
data ApplyCtx = ApplyCtx
  { applyCurrBlock      :: Block
  , applyNodeAddress    :: Address
  , applyNodePrivKey    :: Key.PrivateKey
  } deriving (Generic, NFData)

-- | The state that is being modified during transaction application
data ApplyState e = ApplyState
  { accumWorld  :: World
  , accumErrs   :: DList e
  , accumDeltas :: Map Address [Delta]  -- ^ Map of Contract Addrs -> Deltas
  }

-- | The Monad used for functions accessing ApplyCtx env and ApplyState state
type ApplyM e = ReaderT ApplyCtx (StateT (ApplyState e) IO)

initApplyState :: World -> ApplyState e
initApplyState world = ApplyState
  { accumWorld  = world
  , accumErrs   = mempty
  , accumDeltas = mempty
  }

execApplyM
  :: ApplyCtx     -- ^ Initial environment values
  -> ApplyState e -- ^ Initial state to modify
  -> ApplyM e a   -- ^ Computation
  -> IO (World, [e], Map Address [Delta])
execApplyM r s m = f <$> execStateT (runReaderT m r) s
  where
    f :: ApplyState e -> (World, [e], Map Address [Delta])
    f (ApplyState w e' d) = (w,e,d)
      where
        e = e' `DL.apply` []

-- | Set the world state
putWorld :: World -> ApplyM e ()
putWorld w = modify $ \applyState ->
  applyState { accumWorld = w }

-- | Add an error to ApplyState
throwError :: e -> ApplyM e ()
throwError e = modify $ \applyState ->
  let accumErrs' = accumErrs applyState in
  applyState { accumErrs = accumErrs' `DL.append` DL.fromList [e] }

-- | Add a list of Deltas to ApplyState
appendDeltas :: Address -> [Delta] -> ApplyM e ()
appendDeltas addr ds = modify $ \applyState ->
  let accumDeltas' = accumDeltas applyState in
  applyState {
    accumDeltas =
      Map.insertWith (flip (++)) addr ds accumDeltas'
  }

-------------------------------------------------------------------------------

-- | Applies the transactions in a block to the world state
applyBlock
  :: ApplyCtx
  -> World
  -> Block.Block
  -> IO (World, [Tx.InvalidTransaction], Map Address [Delta])
applyBlock applyCtx initWorld =
  applyTransactions applyCtx initWorld . Block.transactions

applyTransactions
  :: ApplyCtx
  -> World
  -> [Tx.Transaction]
  -> IO (World, [Tx.InvalidTransaction], Map Address [Delta])
applyTransactions ctx world =
    execApplyM ctx initState . mapM applyTransaction
  where
    initState = initApplyState world

-- | Validates a transaction and then applies it to the world state
applyTransaction :: Transaction -> ApplyM Tx.InvalidTransaction ()
applyTransaction tx = do
  world <- gets accumWorld
  -- Validate and attempt to apply block
  let validTxOrigin = validateTransactionOrigin world tx
  -- If validation or application fails, accum error
  case validTxOrigin of
    Left err       -> throwError err
    Right newWorld -> applyTxHeader tx

-------------------------------------------------------------------------------

-- | Applies the contents of the TxHeader to the world state
applyTxHeader
  :: Transaction
  -> ApplyM Tx.InvalidTransaction ()
applyTxHeader tx@Transaction{..} =
    case header of

      -- Accounts
      Tx.TxAccount txAccount ->
        applyTxAccount tx txAccount

      -- Transactions
      Tx.TxAsset txAsset ->
        applyTxAsset tx txAsset (Tx.origin tx) (Tx.to tx) (Tx.timestamp tx)

      -- Contracts
      Tx.TxContract txContract ->
        applyTxContract tx txContract

-- | Applies TxAsset headers to world state
applyTxAsset
  :: Transaction
  -> Tx.TxAsset
  -> Address
  -> Maybe Address
  -> Time.Timestamp
  -> ApplyM Tx.InvalidTransaction ()
applyTxAsset tx txAsset origin mTo ts = do

  world <- gets accumWorld

  case txAsset of

    Tx.CreateAsset name supply mRef type_ -> do
      let asset = createAsset (toBytes name) origin supply mRef type_ ts
      case mTo of
        Nothing -> throwTxAsset $ Tx.MissingAssetAddress
        Just to -> do
          case Ledger.addAsset to asset world of
            Left err -> throwError $
              mkInvalidTx tx (Tx.InvalidTxAsset (Tx.AssetError err))
            Right newworld -> putWorld newworld

    Tx.Transfer assetAddr toAddr amnt -> do
      let eLedger = Ledger.transferAsset assetAddr origin toAddr amnt world
      case eLedger of
        Left err -> throwError $
          mkInvalidTx tx (Tx.InvalidTxAsset (Tx.AssetError err))
        Right newWorld -> putWorld newWorld

    Tx.Bind _ _ _ -> pure ()

  where
    throwTxAsset = throwError . mkInvalidTx tx . Tx.InvalidTxAsset

-- | Applies TxAccount headers to world state
applyTxAccount
  :: Transaction
  -> Tx.TxAccount
  -> ApplyM Tx.InvalidTransaction ()
applyTxAccount tx txAccount = do

  world <- gets accumWorld

  case txAccount of

    Tx.CreateAccount pub tz md ->
      case Key.tryDecodePub pub of
        Left err -> throwError $ mkInvalidTx tx $
          Tx.InvalidTxAccount $ Tx.InvalidPubKeyByteString err
        Right pub' -> do
          let newAccount = Account.createAccount pub' tz md
          let eWorld = first Tx.AccountError $
                Ledger.addAccount newAccount world
          case eWorld of
            Left err -> throwError $ mkInvalidTx tx $ Tx.InvalidTxAccount err
            Right newWorld -> putWorld newWorld

    Tx.RevokeAccount accAddr ->
      case Ledger.lookupAccount accAddr world of
        Left err -> throwError $ mkInvalidTx tx $
          Tx.InvalidTxAccount $ Tx.AccountError err
        Right acc -> do
          currBlock <- asks applyCurrBlock
          let validatorSet' = Block.getValidatorSet currBlock
          let accAddr = Account.address acc
          -- If account is validator account, do not allow revocation
          if accAddr `CAT.isValidatorAddr` validatorSet'
            then throwError $ mkInvalidTx tx $
              Tx.InvalidTxAccount $ Tx.RevokeValidatorError accAddr
            else do
              let eWorld = first Tx.AccountError $ Ledger.removeAccount acc world
              case eWorld of
                Left err -> throwError $ mkInvalidTx tx $ Tx.InvalidTxAccount err
                Right newWorld -> putWorld newWorld

-- | Applies TxContract headers to world state
applyTxContract
  :: Transaction   -- ^ For error throwing InvalidTransaction
  -> Tx.TxContract
  -> ApplyM Tx.InvalidTransaction ()
applyTxContract tx txContract = do

  let ts = Tx.timestamp tx
  let issuer = Tx.origin tx

  case txContract of

    Tx.CreateContract addr scriptSS -> do
      let scriptText = decodeUtf8 $ SafeString.toBytes scriptSS
          eContract = Script.Init.createContract issuer addr ts scriptText
      case eContract of
        Left err -> throwTxContract $ Tx.InvalidContract err
        Right contract -> do
          world <- gets accumWorld
          let eContract = Ledger.addContract addr contract world
          case eContract of
            Left err -> throwTxContract $ Tx.ContractError err
            Right newWorld -> putWorld newWorld

    Tx.Call contractAddr methodNmBS args -> do
      world <- gets accumWorld
      case Ledger.lookupContract contractAddr world of
        Left err -> throwTxContract $ Tx.ContractError err
        Right contract -> do
          let eCallInputs = processCallInputs contract methodNmBS args
          case eCallInputs of
            Left err -> throwTxContract err
            Right method -> applyCall contract method args

    -- XXX Implement SyncLocal
    Tx.SyncLocal _ _ -> return ()
  where
    processCallInputs
      :: Contract.Contract
      -> ByteString
      -> [Script.Value]
      -> Either Tx.InvalidTxContract Script.Method
    processCallInputs c methodNmBS args = do
      let methodNm = decodeUtf8 methodNmBS
      let methods = Script.scriptMethods $ Contract.script c
      let getMethodNm = Script.unName . Script.methodName
      case find ((==) methodNm . getMethodNm) methods of
        Nothing -> Left $ Tx.MethodDoesNotExist methodNm
        Just method -> do
          -- Typecheck method w/ supplied args
          first Tx.InvalidCallArgType $
            TC.tcMethod method args
          return method

    applyCall
      :: Contract.Contract -- Contract from which to exec method
      -> Script.Method     -- Method to eval
      -> [Script.Value]    -- Method args
      -> ApplyM Tx.InvalidTransaction ()
    applyCall contract method argVals = do

      -- Setup evalCtx and evalState
      applyCtx <- ask
      world <- gets accumWorld
      evalCtx <- liftIO $ initEvalCtxTxCall applyCtx contract tx
      let evalState = Eval.initEvalState contract world

      -- Evaluate the method call
      evalRes <- liftIO $
        Eval.execEvalM evalCtx evalState $
          Eval.evalMethod method argVals
      case evalRes of
        Left err -> throwTxContract $ Tx.EvalFail err
        Right resEvalState -> do

          -- Append deltas to ApplyState
          let deltas = Eval.deltas resEvalState
          appendDeltas (Contract.address contract) deltas

          -- Update world state based on results from evalMethod
          let newWorld = updateWorld contract resEvalState
          putWorld newWorld

    -- Update the contract based on results from applyDeltas
    updateContract :: Eval.EvalState -> Contract -> Contract
    updateContract evalState contract =
      let gstore = Eval.globalStorage evalState
          lstore = Eval.localStorage evalState
          ts     = Contract.timestamp contract
      in contract
        { Contract.globalStorage = Storage.GlobalStorage gstore
        , Contract.localStorage  = map Storage.LocalStorage lstore
        , Contract.state         = Eval.graphState evalState
        }

    -- Update the contract in the new world state resulting from Deltas
    updateWorld :: Contract -> Eval.EvalState -> World
    updateWorld c es =
      let newContract = updateContract es c in
      Ledger.updateContract (Contract.address c) newContract $ Eval.worldState es

    -- Error helpers
    throwTxContract = throwError . mkInvalidTx tx . Tx.InvalidTxContract
    throwTxAsset = throwError . mkInvalidTx tx . Tx.InvalidTxAsset

-- | Intializes an evaluation context from values available
-- to the TxContract Call transaction in `applyTxContract` case
initEvalCtxTxCall
  :: ApplyCtx
  -> Contract
  -> Transaction
  -> IO Eval.EvalCtx
initEvalCtxTxCall ApplyCtx{..} c tx =
  Eval.initEvalCtx
    (fromIntegral $ Block.index applyCurrBlock)
    (Block.timestamp $ Block.header applyCurrBlock)
    applyNodeAddress
    (Tx.hashTransaction tx)
    (Tx.origin tx)
    applyNodePrivKey
    c

-- | Helper to construct InvalidTransactions from InvalidTxHeaders
mkInvalidTx :: Transaction -> Tx.InvalidTxHeader -> Tx.InvalidTransaction
mkInvalidTx tx = Tx.InvalidTransaction tx . Tx.InvalidTxHeader
