{-# LANGUAGE FlexibleContexts #-}

-- | Operations that update the mempool. They are internally divided in the pure
-- and impure sides of the operation.
module Ouroboros.Consensus.Mempool.Update (
    implAddTx
  , implRemoveTxs
  , implSyncWithLedger
  ) where

import           Control.Concurrent.Class.MonadMVar (MVar, withMVar)
import           Control.Exception (assert)
import           Control.Tracer
import           Data.Maybe (isJust, isNothing)
import qualified Data.Set as Set
import           Ouroboros.Consensus.HeaderValidation
import           Ouroboros.Consensus.Ledger.Abstract
import           Ouroboros.Consensus.Ledger.SupportsMempool
import           Ouroboros.Consensus.Mempool.API
import           Ouroboros.Consensus.Mempool.Capacity
import           Ouroboros.Consensus.Mempool.Impl.Common
import           Ouroboros.Consensus.Mempool.TxSeq (TxTicket (..))
import qualified Ouroboros.Consensus.Mempool.TxSeq as TxSeq
import           Ouroboros.Consensus.Util (whenJust)
import           Ouroboros.Consensus.Util.IOLike hiding (withMVar)

{-------------------------------------------------------------------------------
  Add transactions
-------------------------------------------------------------------------------}

-- | Add a single transaction to the mempool, blocking if there is no space.
--
implAddTx ::
     ( MonadSTM m
     , MonadMVar m
     , LedgerSupportsMempool blk
     , HasTxId (GenTx blk)
     )
  => StrictTVar m (InternalState blk)
     -- ^ The InternalState TVar.
  -> MVar m ()
      -- ^ The FIFO for remote peers
  -> MVar m ()
      -- ^ The FIFO for all remote peers and local clients
  -> LedgerConfig blk
     -- ^ The configuration of the ledger.
  -> (GenTx blk -> TxSizeInBytes)
     -- ^ The function to calculate the size of a
     -- transaction.
  -> Tracer m (TraceEventMempool blk)
  -> AddTxOnBehalfOf
     -- ^ Whether we're acting on behalf of a remote peer or a local client.
  -> GenTx blk
     -- ^ The transaction to add to the mempool.
  -> m (MempoolAddTxResult blk)
implAddTx istate remoteFifo allFifo cfg txSize trcr onbehalf tx =
    -- To ensure fair behaviour between threads that are trying to add
    -- transactions, we make them all queue in a fifo. Only the one at the head
    -- of the queue gets to actually wait for space to get freed up in the
    -- mempool. This avoids small transactions repeatedly squeezing in ahead of
    -- larger transactions.
    --
    -- The fifo behaviour is implemented using a simple MVar. And take this
    -- MVar lock on a transaction by transaction basis. So if several threads
    -- are each trying to add several transactions, then they'll interleave at
    -- transaction granularity, not batches of transactions.
    --
    -- To add back in a bit of deliberate unfairness, we want to prioritise
    -- transactions being added on behalf of local clients, over ones being
    -- added on behalf of remote peers. We do this by using a pair of mvar
    -- fifos: remote peers must wait on both mvars, while local clients only
    -- need to wait on the second.
    case onbehalf of
      AddTxForRemotePeer ->
        withMVar remoteFifo $ \() ->
        withMVar allFifo $ \() ->
          -- This action can also block. Holding the MVars means
          -- there is only a single such thread blocking at once.
          implAddTx'

      AddTxForLocalClient ->
        withMVar allFifo $ \() ->
          -- As above but skip the first MVar fifo so we will get
          -- service sooner if there's lots of other remote
          -- threads waiting.
          implAddTx'
  where
    implAddTx' = do
      (result, ev) <- atomically $ do
        outcome <- implTryAddTx istate cfg txSize
                                (whetherToIntervene onbehalf)
                                tx
        case outcome of
          TryAddTx _ result ev -> do return (result, ev)

          -- or block until space is available to fit the next transaction
          NoSpaceLeft          -> retry

      traceWith trcr ev
      return result

    whetherToIntervene :: AddTxOnBehalfOf -> WhetherToIntervene
    whetherToIntervene AddTxForRemotePeer  = DoNotIntervene
    whetherToIntervene AddTxForLocalClient = Intervene

-- | Result of trying to add a transaction to the mempool.
data TryAddTx blk =
    -- | No space is left in the mempool and no more transactions could be
    -- added.
    NoSpaceLeft
    -- | A transaction was processed.
  | TryAddTx
      (Maybe (InternalState blk))
      -- ^ If the transaction was accepted, the new state that can be written to
      -- the TVar.
      (MempoolAddTxResult blk)
      -- ^ The result of trying to add the transaction to the mempool.
      (TraceEventMempool blk)
      -- ^ The event emitted by the operation.

-- | Add a single transaction by interpreting a 'TryAddTx' from 'pureTryAddTx'.
--
-- This function returns whether the transaction was added or rejected, or if
-- the Mempool capacity is reached. See 'implAddTx' for a function that blocks
-- in case the Mempool capacity is reached.
--
-- Transactions are added one by one, updating the Mempool each time one was
-- added successfully.
--
-- See the necessary invariants on the Haddock for 'API.tryAddTxs'.
--
-- This function does not sync the Mempool contents with the ledger state in
-- case the latter changes, it relies on the background thread to do that.
--
-- INVARIANT: The code needs that read and writes on the state are coupled
-- together or inconsistencies will arise. To ensure that STM transactions are
-- short, each iteration of the helper function is a separate STM transaction.
implTryAddTx ::
     ( MonadSTM m
     , LedgerSupportsMempool blk
     , HasTxId (GenTx blk)
     )
  => StrictTVar m (InternalState blk)
     -- ^ The InternalState TVar.
  -> LedgerConfig blk
     -- ^ The configuration of the ledger.
  -> (GenTx blk -> TxSizeInBytes)
     -- ^ The function to calculate the size of a
     -- transaction.
  -> WhetherToIntervene
  -> GenTx blk
     -- ^ The transaction to add to the mempool.
  -> STM m (TryAddTx blk)
implTryAddTx istate cfg txSize wti tx = do
        is <- readTVar istate
        let outcome = pureTryAddTx cfg txSize wti tx is
        case outcome of
          TryAddTx (Just is') _ _ -> writeTVar istate is'
          _                       -> return ()
        return outcome

-- | Craft a 'TryAddTx' value containing the resulting state if applicable, the
-- tracing event and the result of adding this transaction. See the
-- documentation of 'implTryAddTx' for some more context.
--
-- It returns 'NoSpaceLeft' only when the current mempool size is bigger or
-- equal than then mempool capacity. Otherwise it will validate the transaction
-- and add it to the mempool if there is at least one byte free on the mempool.
pureTryAddTx ::
     ( LedgerSupportsMempool blk
     , HasTxId (GenTx blk)
     )
  => LedgerCfg (LedgerState blk)
     -- ^ The ledger configuration.
  -> (GenTx blk -> TxSizeInBytes)
     -- ^ The function to claculate the size of a transaction.
  -> WhetherToIntervene
  -> GenTx blk
     -- ^ The transaction to add to the mempool.
  -> InternalState blk
     -- ^ The current internal state of the mempool.
  -> TryAddTx blk
pureTryAddTx cfg txSize wti tx is
  | let curSize = msNumBytes  $ isMempoolSize is
  , curSize < getMempoolCapacityBytes (isCapacity is)
  = -- We add the transaction if there is at least one byte free left in the mempool.
  case eVtx of
      -- We only extended the ValidationResult with a single transaction
      -- ('tx'). So if it's not in 'vrInvalid', it must be in 'vrNewValid'.
      Right vtx ->
        assert (isJust (vrNewValid vr)) $
          TryAddTx
            (Just is')
            (MempoolTxAdded vtx)
            (TraceMempoolAddedTx
              vtx
              (isMempoolSize is)
              (isMempoolSize is')
            )
      Left err ->
        assert (isNothing (vrNewValid vr))  $
          assert (length (vrInvalid vr) == 1) $
            TryAddTx
              Nothing
              (MempoolTxRejected tx err)
              (TraceMempoolRejectedTx
               tx
               err
               (isMempoolSize is)
              )
  | otherwise
  = NoSpaceLeft
    where
      (eVtx, vr) = extendVRNew cfg txSize wti tx $ validationResultFromIS is
      is'        = internalStateFromVR vr

{-------------------------------------------------------------------------------
  Remove transactions
-------------------------------------------------------------------------------}

-- | A datatype containing the state resulting after removing the requested
-- transactions from the mempool and maybe a message to be traced while removing
-- them.
data RemoveTxs blk =
    WriteRemoveTxs (InternalState blk) (Maybe (TraceEventMempool blk))

-- | See 'Ouroboros.Consensus.Mempool.API.removeTxs'.
implRemoveTxs ::
     ( IOLike m
     , LedgerSupportsMempool blk
     , HasTxId (GenTx blk)
     , ValidateEnvelope blk
     )
  => MempoolEnv m blk
  -> [GenTxId blk]
  -> m ()
implRemoveTxs menv txs
  | null txs = pure ()
  | otherwise = do
    tr <- atomically $ do
        is <- readTVar istate
        ls <- getCurrentLedgerState ldgrInterface
        let WriteRemoveTxs is' t = pureRemoveTxs cfg co txs is ls
        writeTVar istate is'
        pure t
    whenJust tr (traceWith trcr)
  where
    MempoolEnv { mpEnvStateVar = istate
               , mpEnvLedger = ldgrInterface
               , mpEnvTracer = trcr
               , mpEnvLedgerCfg = cfg
               , mpEnvCapacityOverride = co
               } = menv

-- | Craft a 'RemoveTxs' that manually removes the given transactions from the
-- mempool, returning inside it an updated InternalState.
pureRemoveTxs ::
     ( LedgerSupportsMempool blk
     , HasTxId (GenTx blk)
     , ValidateEnvelope blk
     )
  => LedgerConfig blk
  -> MempoolCapacityBytesOverride
  -> [GenTxId blk]
  -> InternalState blk
  -> LedgerState blk
  -> RemoveTxs blk
pureRemoveTxs cfg capacityOverride txIds is lstate =
    -- Filtering is O(n), but this function will rarely be used, as it is an
    -- escape hatch when there's an inconsistency between the ledger and the
    -- mempool.
    let toRemove       = Set.fromList txIds
        txTickets'     = filter
                           (   (`notElem` toRemove)
                             . txId
                             . txForgetValidated
                             . txTicketTx
                           )
                           (TxSeq.toList (isTxs is))
        (slot, ticked) = tickLedgerState cfg (ForgeInUnknownSlot lstate)
        vr             = revalidateTxsFor
                           capacityOverride
                           cfg
                           slot
                           ticked
                           (isLastTicketNo is)
                           txTickets'
        is'            = internalStateFromVR vr
        needsTrace     = if null txIds
                         then
                           Nothing
                         else
                           Just $ TraceMempoolManuallyRemovedTxs
                             txIds
                             (map fst (vrInvalid vr))
                             (isMempoolSize is')
    in WriteRemoveTxs is' needsTrace

{-------------------------------------------------------------------------------
  Sync with ledger
-------------------------------------------------------------------------------}

-- | A datatype containing the new state produced by syncing with the Ledger, a
-- snapshot of that mempool state and, if needed, a tracing message.
data SyncWithLedger blk =
    NewSyncedState (InternalState blk)
                   (MempoolSnapshot blk)
                   (Maybe (TraceEventMempool blk))

-- | See 'Ouroboros.Consensus.Mempool.API.syncWithLedger'.
implSyncWithLedger ::
     (
       IOLike m
     , LedgerSupportsMempool blk
     , HasTxId (GenTx blk)
     , ValidateEnvelope blk
     )
  => MempoolEnv m blk
  -> m (MempoolSnapshot blk)
implSyncWithLedger menv = do
    (mTrace, mp) <- atomically $ do
      is <- readTVar istate
      ls <- getCurrentLedgerState ldgrInterface
      let NewSyncedState is' msp mTrace = pureSyncWithLedger is ls cfg co
      writeTVar istate is'
      return (mTrace, msp)
    whenJust mTrace (traceWith trcr)
    return mp
  where
    MempoolEnv { mpEnvStateVar = istate
               , mpEnvLedger = ldgrInterface
               , mpEnvTracer = trcr
               , mpEnvLedgerCfg = cfg
               , mpEnvCapacityOverride = co
               } = menv

-- | Create a 'SyncWithLedger' value representing the values that will need to
-- be stored for committing this synchronization with the Ledger.
--
-- See the documentation of 'runSyncWithLedger' for more context.
pureSyncWithLedger ::
     (LedgerSupportsMempool blk, HasTxId (GenTx blk), ValidateEnvelope blk)
  => InternalState blk
  -> LedgerState blk
  -> LedgerConfig blk
  -> MempoolCapacityBytesOverride
  -> SyncWithLedger blk
pureSyncWithLedger istate lstate lcfg capacityOverride =
    let vr          = validateStateFor
                        capacityOverride
                        lcfg
                        (ForgeInUnknownSlot lstate)
                        istate
        removed     = vrInvalid vr
        istate'     = internalStateFromVR vr
        mTrace      = if null removed
                      then
                        Nothing
                      else
                        Just $ TraceMempoolRemoveTxs removed (isMempoolSize istate')
        snapshot    = snapshotFromIS istate'
    in
      NewSyncedState istate' snapshot mTrace
