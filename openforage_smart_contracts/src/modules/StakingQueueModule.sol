// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "../IForageGovernorPause.sol";
import "../VaultRegistry.sol";
import "../AllowlistGatedUpgradeable.sol";
import "../interfaces/IAllowlist.sol";
import "../interfaces/IVaultRegistry.sol";
import "../interfaces/IBlocklist.sol";

interface IQueueModuleForagePriceView {
    function effectiveForagePriceUsd() external view returns (uint256);
}

interface IQueueTierYieldSource {
    function yieldSource() external view returns (address);
}

interface IQueueRecognitionWindow {
    function recognitionWindowOpen(uint256 vaultId) external view returns (bool);
}

interface IQueueModuleOwner {
    function owner() external view returns (address);
}

/// @title StakingQueueModuleStorage -- Storage mirror and shared helpers of the queue's delegatecall modules
/// @dev StakingQueueModule and StakingQueueLockupModule inherit this contract. It mirrors the queue's linear storage
///      declarations so a delegatecall reads and writes the queue's own slots; neither module adds storage.
abstract contract StakingQueueModuleStorage is AllowlistGatedUpgradeable {
    using SafeERC20 for IERC20;

    struct QueueEntry {
        address depositor;
        uint256 riskusdAmount;
        uint8 tier;
        uint256 entryTimestamp;
        bool processed;
        bool cancelled;
        bool priority;
        uint256 minimumShares;
        uint256 deadline;
    }

    struct QueueEntryProgress {
        uint256 remainingRiskusd;
        uint256 remainingMinimumShares;
        uint256 sharesMinted;
        uint256 deadlineCeiling;
        bool initialized;
    }

    struct QueueLaneResult {
        uint256 processedCount;
        uint256 nextHead;
        uint256 incompleteQueueId;
    }

    struct QueueLaneConfig {
        uint8 tier;
        uint256 budget;
        uint256 availCapacity;
        uint256 availTierCapacity;
        bool isPriorityLane;
    }

    struct StandardLaneScanState {
        uint256 cursor;
        uint256 snapshotEnd;
        uint256 scanned;
        uint256 scanLimit;
        bool snapshotComplete;
    }

    struct QueueProcessedData {
        uint256 queueId;
        address depositor;
        uint256 riskusdProcessed;
        uint8 tier;
    }

    struct SelfReversion {
        address vaultZero;
        uint256 riskusdAmount;
        uint256 combinedAssetsBefore;
    }

    struct TierDepositCap {
        uint256 baseCap;
        uint256 proposedCap;
        uint256 proposedAt;
        bool configured;
    }

    // -- Custom errors --
    error ZeroAddress();
    error ZeroAmount();
    error InvalidTier();
    error InvalidTierUpgrade();
    error NoCapacityAvailable();
    error InvalidQueueEntry();
    error NotQueueEntryDepositor();
    error QueueEntryAlreadyProcessed();
    error QueueEntryAlreadyCancelled();
    error VaultIdAlreadySet();
    error VaultIdNotSet();
    error VaultNotActive();
    error NotInitialized();
    error InternalOnly();
    error RenewLockupFailed();
    error RedeemForReversionFailed();
    error Tier0DepositFailed();
    error RenounceOwnershipDisabled();
    error EmptyQueue();
    error ParameterTooLarge();
    error StaleFORAGEPrice(); // OF-13-012
    error NoPendingForageGovernor(); // OF-15-005
    error FinalizeDelayNotElapsed(); // OF-15-005
    error ProposalExpired(); // OF-15-005
    error OracleNotConfigured();
    error InvalidOraclePrice();
    error InvalidOracleStaleness();
    error NoPendingForagePriceUsd();
    error NoPendingForagePriceMode();
    error NoPendingForagePriceOracle();
    error TierDepositCapAboveVaultCapacity(uint256 cap, uint256 vaultCapacity);
    error TierDepositCapWideningNotAllowed(uint8 tier, uint256 requested, uint256 effectiveCap);
    error TierDepositCapExceeded(uint8 tier, uint256 requested, uint256 available);
    error CombinedBackingPerShareDecreased(uint256 beforeRay, uint256 afterRay);
    error CombinedBackingAssetsDecreased(uint256 beforeAssets, uint256 afterAssets);
    error BlockedAddress(address account);
    error BlocklistUnavailable(address blocklist);
    error CapacityProbeFailed(address vault);
    error LegacyForageLockAccountingUnsupported();
    error DepositOutputBelowMinimum(uint256 sharesMinted, uint256 minimumShares);
    error MinimumSharesUnreachable(uint256 minimumShares, uint256 maxPreviewShares);
    error PriorityLockUnavailable();
    error InvalidForagePriceScale(uint256 price);
    error UnauthorizedLockupProcessor(address caller);
    error SequencerUptimeFeedUnavailable(address feed);
    error SequencerDown();
    error SequencerGracePeriodNotOver(uint256 startedAt, uint256 gracePeriod);
    error DirectCallForbidden();
    error TierVaultUnavailable(uint8 tier, address vault);
    error TierVaultProbeFailed(uint8 tier, address vault, bytes4 selector);
    error VaultRegistryUnavailable(address registry);
    error QueueEntryBelowMinimum(uint256 riskusdAmount, uint256 minimum);
    error RecognitionWindowOpen(uint256 vaultId);
    error TooManyOpenQueueEntries(address depositor, uint256 openEntries, uint256 maximum);

    // -- Precomputed function selectors --
    bytes4 internal constant _SEL_LOCKED_BALANCE = bytes4(keccak256("lockedBalance(address)"));
    bytes4 internal constant _SEL_DEPOSIT = bytes4(keccak256("deposit(uint256,address)"));
    bytes4 internal constant _SEL_PREVIEW_DEPOSIT = bytes4(keccak256("previewDeposit(uint256)"));
    bytes4 internal constant _SEL_REDEEM_UPGRADE = bytes4(keccak256("redeemForUpgrade(address,uint256)"));
    bytes4 internal constant _SEL_CATCH_UP = bytes4(keccak256("catchUpUnpaidProfitEpochs(address)"));
    bytes4 internal constant _SEL_RENEW_LOCKUP = bytes4(keccak256("renewLockup(address)"));
    bytes4 internal constant _SEL_REDEEM_REVERSION = bytes4(keccak256("redeemForReversion(address,uint256)"));
    bytes4 internal constant _SEL_LOCKUPS = bytes4(keccak256("lockups(address)"));
    bytes4 internal constant _SEL_IS_LOCKUP_EXPIRED = bytes4(keccak256("isLockupExpired(address)"));
    bytes4 internal constant _SEL_AUTO_RENEW = bytes4(keccak256("autoRenewEnabled(address)"));
    bytes4 internal constant _SEL_HAS_PENDING = bytes4(keccak256("hasPendingWithdrawal(address)"));
    bytes4 internal constant _SEL_LOCKUP_SHARES = bytes4(keccak256("lockupShares(address)"));
    bytes4 internal constant _SEL_LEGITIMATE_ASSETS = bytes4(keccak256("legitimateAssets()"));
    bytes4 internal constant _SEL_TOTAL_SUPPLY = bytes4(keccak256("totalSupply()"));
    bytes4 internal constant _SEL_TOTAL_ASSETS = bytes4(keccak256("totalAssets()"));
    bytes4 internal constant _SEL_QUEUE_FORAGE_LOCK_ACTION =
        bytes4(keccak256("_queueForageLockAction(uint8,uint256,address,uint256,uint8)"));

    enum PriceMode {
        FIXED_PRICE,
        ORACLE
    }

    enum QueueLaneStep {
        ADVANCE,
        TERMINAL,
        STOP
    }

    // -- Events --
    event QueueJoined(
        uint256 indexed queueId, address indexed depositor, uint256 riskusdAmount, uint8 tier, bool priority
    );
    event PriorityPriceUnavailable(uint256 indexed queueId, address indexed depositor, bytes4 reason);
    event QueueEntryDemoted(
        uint256 indexed queueId, address indexed depositor, uint256 remainingRiskusd, bytes4 reason
    );
    event QueueProcessed(uint256 indexed queueId, address indexed depositor, uint256 riskusdProcessed, uint8 tier);
    event QueueCancelled(uint256 indexed queueId, address indexed depositor, uint256 riskusdReturned);
    event TierUpgraded(
        address indexed depositor,
        uint8 fromTier,
        uint8 toTier,
        uint256 atriskusdAmount,
        uint256 riskusdAmount,
        uint256 newAtriskusdAmount
    );
    event LockupReverted(address indexed depositor, uint8 fromTier, uint256 riskusdAmount);
    event LockupRenewed(address indexed depositor, uint8 tier, uint256 newExpiry);
    event VaultIdSet(uint256 vaultId);
    event ForagePriceUsdUpdated(uint256 oldPrice, uint256 newPrice);
    event ForagePriceUsdProposed(uint256 currentPrice, uint256 pendingPrice);
    event ForagePriceModeUpdated(PriceMode oldMode, PriceMode newMode);
    event ForagePriceModeProposed(PriceMode currentMode, PriceMode pendingMode);
    event ForagePriceOracleUpdated(
        address indexed oldOracle,
        address indexed newOracle,
        uint256 oldMaxStaleness,
        uint256 newMaxStaleness,
        uint8 decimals
    );
    event ForagePriceOracleProposed(
        address indexed currentOracle,
        address indexed pendingOracle,
        uint256 currentMaxStaleness,
        uint256 pendingMaxStaleness,
        uint8 decimals
    );
    event PriorityMultiplierUpdated(uint256 oldMultiplier, uint256 newMultiplier);
    event ForageGovernorSet(address indexed oldGovernor, address indexed newGovernor);
    event ForageGovernorProposed(address indexed current, address indexed pending); // OF-15-005
    event TierDepositCapProposed(uint8 indexed tier, uint256 baseCap, uint256 proposedCap, uint256 proposedAt);
    event TierDepositCapShrunk(uint8 indexed tier, uint256 oldEffectiveCap, uint256 newCap, address indexed caller);
    event ExpiredLockupProcessingFailed(address indexed depositor, uint8 tier, bytes reason);
    event QueueCompacted(uint8 tier, bool priority, uint256 removedCount);
    event QueueEntryCancelled(
        uint256 indexed entryId, address indexed depositor, address indexed recipient, uint256 amount
    );
    event QueueEntrySkippedBlocked(uint256 indexed entryId, address indexed depositor);
    event QueueEntrySkippedLapsed(uint8 indexed lane, address indexed depositor);
    event QueueScanIncomplete(uint8 indexed tier, bool indexed priorityLane, uint256 nextQueueId);
    event QueueEntryBoundsUpdated(
        uint256 indexed queueId, address indexed depositor, uint256 minimumShares, uint256 deadline
    );
    event ForageUnlockFailed(address indexed depositor, uint256 amount);
    event TierVaultsSynced(address[4] newTierVaults); // OF-13-027
    event BlocklistSet(address indexed oldBlocklist, address indexed newBlocklist);
    event ExpiredLockupProcessorSet(address indexed processor, bool authorized);
    event SequencerUptimeFeedSet(address indexed oldFeed, address indexed newFeed);

    // -- Constants --
    uint256 public constant PROPOSAL_EXPIRY = 30 days; // OF-15-005
    uint256 public constant MAX_FIXED_FORAGE_PRICE_USD = 1_000_000e6;
    uint256 public constant ARBITRUM_ONE_CHAIN_ID = 42_161;
    uint256 public constant SEQUENCER_UPTIME_GRACE_PERIOD = 1 hours;
    uint256 internal constant QUEUE_ENTRY_TTL = 3 days;
    /// @dev A14-09 (DEC-octane-golive-2): 100 RISKUSD per entry and 8 open entries per depositor.
    uint256 internal constant MIN_QUEUE_ENTRY_RISKUSD = 100e6;
    uint256 internal constant MAX_OPEN_QUEUE_ENTRIES = 8;
    uint256 internal constant RAY = 1e27;
    uint256 internal constant AT_RISK_SHARE_SCALE = 1e6;
    uint256 internal constant PRIORITY_LOOKAHEAD_SCAN_LIMIT = 64;
    uint256 internal constant _PRICE_VIEW_GAS_LIMIT = 400_000;
    uint256 public constant CEILING_MAX_AGE = 30 days;

    // -- Storage (mirrors StakingQueue so delegatecall reads the queue's slots) --
    IERC20 internal _riskusd;
    address internal _forage;
    address[4] internal _tierVaults;
    address internal _vaultRegistry;
    uint256 internal _vaultId;
    address internal _forageGovernor;
    uint256 internal _nextQueueId;
    uint256 internal _totalQueuedRiskusd;
    uint256 internal _foragePriceUsd;

    mapping(uint256 => QueueEntry) internal _queueEntries;
    mapping(uint8 => uint256[]) internal _tierPriorityQueue;
    mapping(uint8 => uint256[]) internal _tierStandardQueue;
    mapping(uint8 => uint256) internal _tierPriorityHead;
    mapping(uint8 => uint256) internal _tierStandardHead;

    uint256 internal _priorityMultiplier;
    mapping(address => uint256) internal _priorityRiskusdQueued;

    mapping(uint256 => uint256) internal _forageLockedPerEntry;

    /// @dev OF-13-012: Timestamp of last FORAGE price update for staleness check
    uint256 internal _lastPriceUpdate;

    /// @dev OF-15-005: Pending ForageGovernor for two-step setter
    address internal _pendingForageGovernor;
    uint256 internal _pendingForageGovernorProposedAt;

    uint8 internal _priceMode;
    address internal _foragePriceOracle;
    uint8 internal _foragePriceOracleDecimals;
    uint256 internal _oraclePriceMaxStaleness;
    uint256 internal _pendingForagePriceUsd;
    uint256 internal _pendingForagePriceUsdProposedAt;
    bool internal _pendingForagePriceUsdExists;
    uint8 internal _pendingForagePriceMode;
    uint256 internal _pendingForagePriceModeProposedAt;
    bool internal _pendingForagePriceModeExists;
    address internal _pendingForagePriceOracle;
    uint256 internal _pendingOraclePriceMaxStaleness;
    uint8 internal _pendingForagePriceOracleDecimals;
    uint256 internal _pendingForagePriceOracleProposedAt;
    mapping(uint8 => TierDepositCap) internal _tierDepositCaps;
    address internal _blocklist;
    mapping(address => bool) internal _expiredLockupProcessors;
    address internal _sequencerUptimeFeed;
    mapping(uint256 => uint8) internal _priorityEntryAdmissionMode;
    mapping(uint256 => QueueEntryProgress) internal _queueEntryProgress;
    mapping(uint8 => uint256[]) internal _demotedStandardHeap;
    mapping(uint256 => uint256) internal _demotedStandardHeapIndexPlusOne;
    mapping(address => uint256) internal _forageLockWeightByDepositor;
    mapping(uint256 => uint256) internal _forageLockRequirementPerEntry;
    bool internal _forageLockAccountingInitialized;
    mapping(address => uint256) internal _forageLockActiveRequirementByDepositor;
    mapping(uint256 => uint256) internal _forageUnlockPendingWeightPerEntry;
    mapping(address => uint256) internal _forageLockPendingUnlockWeightByDepositor;
    bool internal _forageLockAggregateAccountingInitialized;
    mapping(uint8 => uint256) internal _tierStandardScanCursor;
    mapping(uint8 => uint256) internal _tierPriorityScanCursor;
    mapping(uint8 => uint256) internal _tierStandardScanSnapshotEnd;
    mapping(uint8 => uint256) internal _queueCompactionCursor;

    mapping(uint8 => uint256[]) internal _tierDeferredStandardQueue;
    mapping(uint8 => bool) internal _tierStandardDeferredRestoring;
    uint256[14] internal __gap; // reserved for future upgrades

    struct QueueModuleStorage {
        address module;
        bool priorityIndexInitialized;
        mapping(uint8 => uint256) priorityHead;
        mapping(uint8 => uint256) priorityTail;
        mapping(uint256 => uint256) priorityPrevious;
        mapping(uint256 => uint256) priorityNext;
        mapping(uint256 => bool) priorityActive;
        uint8 deferredFrontierVersion;
        mapping(address => uint256) openEntryCount;
    }

    bytes32 private constant QUEUE_MODULE_STORAGE_LOCATION =
        keccak256(abi.encode(uint256(keccak256("openforage.storage.QueueModule")) - 1)) & ~bytes32(uint256(0xff));

    function _getQueueModuleStorage() private pure returns (QueueModuleStorage storage $) {
        bytes32 slot = QUEUE_MODULE_STORAGE_LOCATION;
        assembly {
            $.slot := slot
        }
    }

    // -- Delegatecall guard --
    address internal immutable _SELF;

    constructor() {
        _SELF = address(this);
    }

    modifier onlyDelegateCall() {
        if (address(this) == _SELF) revert DirectCallForbidden();
        _requireForageLockAccounting();
        _;
    }

    // -- Helpers shared by the queue's modules --

    function _joinQueue(uint256 riskusdAmount, uint8 tier, uint256 minimumShares, uint256 deadline) internal {
        uint8 admissionMode = _priceMode;
        uint256 maxPreviewShares = _minimumDepositShares(_tierVaults[tier], riskusdAmount);
        if (minimumShares == 0) {
            if (maxPreviewShares == 0) revert MinimumSharesUnreachable(1, 0);
            minimumShares = 1;
            deadline = type(uint256).max;
        } else if (minimumShares > maxPreviewShares) {
            revert MinimumSharesUnreachable(minimumShares, maxPreviewShares);
        }

        _openQueueEntry(msg.sender, riskusdAmount);
        _riskusd.safeTransferFrom(msg.sender, address(this), riskusdAmount);

        uint256 queueId = _nextQueueId;
        if (queueId == type(uint256).max) revert InvalidQueueEntry();
        _nextQueueId = queueId + 1;
        uint256 deadlineCeiling = block.timestamp + QUEUE_ENTRY_TTL;
        uint256 storedDeadline = _deadlineWithinCeiling(deadline, deadlineCeiling);

        bool isPriority;
        {
            uint256 mult = _priorityMultiplier;
            if (mult > 0) {
                (bool priceReady, uint256 price, bytes4 priceReason) = _tryActiveForagePriceUsd();
                if (!priceReady) {
                    emit PriorityPriceUnavailable(queueId, msg.sender, priceReason);
                } else if (priceReady && price > 0) {
                    uint256 forageToLock = Math.ceilDiv(riskusdAmount * 1e18, price * mult);
                    // OF-L10-M02: Skip priority if computed lock amount is trivially small (< 0.001 FORAGE)
                    // OF-16-012: Skip if _forage has no code (EOA/self-destructed) — prevents false priority
                    if (forageToLock >= 1e15 && _forage.code.length > 0) {
                        isPriority = _callForageLockAction(0, queueId, msg.sender, forageToLock, admissionMode + 1);
                        if (!isPriority) {
                            emit PriorityPriceUnavailable(queueId, msg.sender, PriorityLockUnavailable.selector);
                        }
                    }
                }
            }
        }

        _queueEntries[queueId] = QueueEntry({
            depositor: msg.sender,
            riskusdAmount: riskusdAmount,
            tier: tier,
            entryTimestamp: block.timestamp,
            processed: false,
            cancelled: false,
            priority: isPriority,
            minimumShares: minimumShares,
            deadline: storedDeadline
        });
        _queueEntryProgress[queueId] = QueueEntryProgress({
            remainingRiskusd: riskusdAmount,
            remainingMinimumShares: minimumShares,
            sharesMinted: 0,
            deadlineCeiling: deadlineCeiling,
            initialized: true
        });

        if (isPriority) {
            _priorityRiskusdQueued[msg.sender] += riskusdAmount;
            _tierPriorityQueue[tier].push(queueId);
            _addLivePriorityEntry(tier, queueId);
        } else {
            _tierStandardQueue[tier].push(queueId);
        }

        _totalQueuedRiskusd += riskusdAmount;

        emit QueueJoined(queueId, msg.sender, riskusdAmount, tier, isPriority);
    }

    function _queueEntryProgressFor(uint256 queueId, QueueEntry storage entry)
        internal
        view
        returns (QueueEntryProgress memory progress)
    {
        progress = _queueEntryProgress[queueId];
        if (!progress.initialized && entry.depositor != address(0)) revert LegacyForageLockAccountingUnsupported();
    }

    function _remainingQueueRiskusd(uint256 queueId, QueueEntry storage entry) internal view returns (uint256) {
        QueueEntryProgress memory progress = _queueEntryProgressFor(queueId, entry);
        return progress.remainingRiskusd;
    }

    function _remainingMinimumShares(uint256 totalMinimumShares, uint256 sharesMinted)
        internal
        pure
        returns (uint256)
    {
        if (totalMinimumShares <= sharesMinted) return 0;
        return totalMinimumShares - sharesMinted;
    }

    function _deadlineWithinCeiling(uint256 deadline, uint256 deadlineCeiling) internal pure returns (uint256) {
        if (deadlineCeiling == 0) revert LegacyForageLockAccountingUnsupported();
        return deadline <= deadlineCeiling ? deadline : deadlineCeiling;
    }

    function _partialFillMinimumShares(
        uint8 tier,
        uint256 remainingRiskusd,
        uint256 remainingMinimumShares,
        uint256 fillAmount
    ) internal view returns (bool reachable, uint256 minimumFillShares) {
        uint256 remainingAfterFill = remainingRiskusd - fillAmount;
        uint256 maximumRemainingShares = _minimumDepositShares(_tierVaults[tier], remainingAfterFill);
        if (remainingMinimumShares > maximumRemainingShares) {
            minimumFillShares = remainingMinimumShares - maximumRemainingShares;
        }
        uint256 maximumFillShares = _minimumDepositShares(_tierVaults[tier], fillAmount);
        if (fillAmount != 0 && maximumFillShares == 0) return (false, minimumFillShares);
        return (minimumFillShares <= maximumFillShares, minimumFillShares);
    }

    function _recordQueueFill(uint256 queueId, QueueEntry storage entry, uint256 fillAmount, uint256 sharesMinted)
        internal
        returns (uint256 remainingAfterFill)
    {
        QueueEntryProgress memory progress = _queueEntryProgressFor(queueId, entry);
        remainingAfterFill = progress.remainingRiskusd - fillAmount;
        QueueEntryProgress storage storedProgress = _queueEntryProgress[queueId];
        storedProgress.remainingRiskusd = remainingAfterFill;
        storedProgress.remainingMinimumShares = _remainingMinimumShares(progress.remainingMinimumShares, sharesMinted);
        storedProgress.sharesMinted = progress.sharesMinted + sharesMinted;
        storedProgress.deadlineCeiling = progress.deadlineCeiling;
        storedProgress.initialized = true;
        _totalQueuedRiskusd -= fillAmount;
        if (entry.priority) _priorityRiskusdQueued[entry.depositor] -= fillAmount;
        if (remainingAfterFill == 0) {
            _removeLivePriorityEntry(entry.tier, queueId);
            entry.processed = true;
            _closeQueueEntry(entry.depositor);
        }
    }

    function _openQueueEntry(address depositor, uint256 riskusdAmount) internal {
        if (riskusdAmount < MIN_QUEUE_ENTRY_RISKUSD) {
            revert QueueEntryBelowMinimum(riskusdAmount, MIN_QUEUE_ENTRY_RISKUSD);
        }
        QueueModuleStorage storage $ = _getQueueModuleStorage();
        uint256 openEntries = $.openEntryCount[depositor];
        if (openEntries >= MAX_OPEN_QUEUE_ENTRIES) {
            revert TooManyOpenQueueEntries(depositor, openEntries, MAX_OPEN_QUEUE_ENTRIES);
        }
        $.openEntryCount[depositor] = openEntries + 1;
    }

    function _closeQueueEntry(address depositor) internal {
        QueueModuleStorage storage $ = _getQueueModuleStorage();
        uint256 openEntries = $.openEntryCount[depositor];
        if (openEntries != 0) $.openEntryCount[depositor] = openEntries - 1;
    }

    function _clearQueueEntryProgress(uint256 queueId) internal {
        QueueEntryProgress storage progress = _queueEntryProgress[queueId];
        progress.remainingRiskusd = 0;
        progress.remainingMinimumShares = 0;
        progress.initialized = true;
    }

    function _reducePriorityLock(
        uint256 queueId,
        QueueEntry storage entry,
        uint256 remainingBeforeFill,
        uint256 remainingAfterFill
    ) internal {
        uint256 recordedLock = _forageLockRequirementPerEntry[queueId];
        if (recordedLock == 0) return;
        if (remainingBeforeFill == 0) revert InvalidQueueEntry();
        uint256 lockToKeep = Math.mulDiv(recordedLock, remainingAfterFill, remainingBeforeFill);
        if (mulmod(recordedLock, remainingAfterFill, remainingBeforeFill) != 0) ++lockToKeep;
        if (remainingAfterFill != 0 && _priorityEntryAdmissionMode[queueId] == uint8(PriceMode.ORACLE) + 1) {
            uint256 minimumLock = recordedLock < 1e15 ? recordedLock : 1e15;
            if (lockToKeep < minimumLock) lockToKeep = minimumLock;
        }
        _callForageLockAction(2, queueId, entry.depositor, lockToKeep, 0);
    }

    function _processPriorityLane(uint256[] storage lane, uint256 head, QueueLaneConfig memory config)
        internal
        returns (QueueLaneResult memory result)
    {
        QueueModuleStorage storage queueState = _getQueueModuleStorage();
        uint256 queueId = queueState.priorityHead[config.tier];
        if (queueId == 0 && queueState.priorityTail[config.tier] != 0) revert InvalidQueueEntry();
        uint256 scanned;
        uint256 scanLimit = _processScanLimit(config.budget);
        while (queueId != 0 && scanned < scanLimit && result.processedCount < config.budget) {
            if (!queueState.priorityActive[queueId]) revert InvalidQueueEntry();
            uint256 nextQueueId = queueState.priorityNext[queueId];
            QueueLaneStep step = _processLaneEntry(queueId, false, config, result);
            if (step == QueueLaneStep.STOP || step == QueueLaneStep.ADVANCE) {
                result.incompleteQueueId = queueId;
                break;
            }
            if (queueState.priorityActive[queueId]) revert InvalidQueueEntry();
            queueId = nextQueueId;
            unchecked {
                ++scanned;
            }
        }
        if (result.incompleteQueueId == 0 && queueId != 0) result.incompleteQueueId = queueId;
        uint256 cursor = _tierPriorityScanCursor[config.tier];
        if (cursor < head) cursor = head;
        result.nextHead = _advancePriorityQueueHead(lane, cursor, scanLimit);
        _tierPriorityScanCursor[config.tier] = result.nextHead;
    }

    function _processStandardLane(QueueLaneConfig memory config) internal {
        QueueLaneResult memory result;
        StandardLaneScanState memory scan;
        scan.scanLimit = _processScanLimit(config.budget);
        if (_tierStandardDeferredRestoring[config.tier]) {
            _restoreDeferredStandardEntries(config.tier, scan.scanLimit);
            return;
        }
        scan.cursor = _tierStandardScanCursor[config.tier];
        scan.snapshotEnd = _tierStandardScanSnapshotEnd[config.tier];
        uint256[] storage standard = _tierStandardQueue[config.tier];
        if (scan.snapshotEnd == 0) {
            scan.snapshotEnd = _nextQueueId - 1;
            _tierStandardScanSnapshotEnd[config.tier] = scan.snapshotEnd;
            scan.cursor = _tierStandardHead[config.tier];
        } else if (scan.cursor < _tierStandardHead[config.tier]) {
            scan.cursor = _tierStandardHead[config.tier];
        }
        uint256[] storage demoted = _demotedStandardHeap[config.tier];
        uint256[] storage deferred = _tierDeferredStandardQueue[config.tier];
        while (scan.scanned < scan.scanLimit && result.processedCount < config.budget) {
            if (scan.cursor < standard.length && standard[scan.cursor] == 0) {
                unchecked {
                    ++scan.cursor;
                    ++scan.scanned;
                }
                continue;
            }
            uint256 standardQueueId;
            if (scan.cursor < standard.length) {
                standardQueueId = standard[scan.cursor];
                if (standardQueueId > scan.snapshotEnd) standardQueueId = 0;
            }
            uint256 demotedQueueId;
            if (demoted.length != 0) {
                demotedQueueId = demoted[0];
                if (demotedQueueId > scan.snapshotEnd) demotedQueueId = 0;
            }
            if (standardQueueId == 0 && demotedQueueId == 0) {
                scan.snapshotComplete = true;
                break;
            }
            unchecked {
                ++scan.scanned;
            }
            if (demotedQueueId != 0 && (standardQueueId == 0 || demotedQueueId < standardQueueId)) {
                QueueLaneStep step = _processDemotedStandardCandidate(config.tier, demotedQueueId, config, result);
                if (step == QueueLaneStep.ADVANCE) {
                    deferred.push(demotedQueueId);
                }
                if (step == QueueLaneStep.STOP) break;
            } else {
                if (_processLaneEntry(standardQueueId, false, config, result) == QueueLaneStep.STOP) break;
                unchecked {
                    ++scan.cursor;
                }
            }
        }
        _tierStandardScanCursor[config.tier] = scan.cursor;
        if (!scan.snapshotComplete) return;
        if (deferred.length == 0) {
            _tierStandardScanCursor[config.tier] = _tierStandardHead[config.tier];
            _tierStandardScanSnapshotEnd[config.tier] = 0;
            return;
        }
        _tierStandardDeferredRestoring[config.tier] = true;
        _restoreDeferredStandardEntries(config.tier, scan.scanLimit - scan.scanned);
    }

    function _processDemotedStandardCandidate(
        uint8 tier,
        uint256 queueId,
        QueueLaneConfig memory config,
        QueueLaneResult memory result
    ) internal returns (QueueLaneStep step) {
        step = _processLaneEntry(queueId, true, config, result);
        if (step == QueueLaneStep.ADVANCE) _removeDemotedStandardEntry(tier, queueId);
    }

    function _restoreDeferredStandardEntries(uint8 tier, uint256 workLimit) internal {
        uint256[] storage deferred = _tierDeferredStandardQueue[tier];
        uint256 restored;
        while (deferred.length != 0 && restored < workLimit) {
            uint256 queueId = deferred[deferred.length - 1];
            deferred.pop();
            QueueEntry storage entry = _queueEntries[queueId];
            if (
                entry.depositor != address(0) && !entry.processed && !entry.cancelled
                    && _demotedStandardHeapIndexPlusOne[queueId] == 0
            ) _insertDemotedStandardEntry(tier, queueId);
            unchecked {
                ++restored;
            }
        }
        if (deferred.length == 0) {
            _tierStandardDeferredRestoring[tier] = false;
            _tierStandardScanCursor[tier] = _tierStandardHead[tier];
            _tierStandardScanSnapshotEnd[tier] = 0;
        }
    }

    function _processLaneEntry(
        uint256 queueId,
        bool demoted,
        QueueLaneConfig memory config,
        QueueLaneResult memory result
    ) internal returns (QueueLaneStep) {
        QueueEntry storage entry = _queueEntries[queueId];
        if (
            queueId == 0 || entry.depositor == address(0) || (config.isPriorityLane && !entry.priority)
                || entry.processed || entry.cancelled
        ) {
            if (config.isPriorityLane) _removeLivePriorityEntry(config.tier, queueId);
            if (demoted) _removeDemotedStandardEntry(config.tier, queueId);
            return QueueLaneStep.TERMINAL;
        }
        if (_isExpired(entry)) {
            if (_isBlocked(entry.depositor)) {
                emit QueueEntrySkippedBlocked(queueId, entry.depositor);
                if (config.isPriorityLane) _removeLivePriorityEntry(entry.tier, queueId);
                if (demoted) _removeDemotedStandardEntry(config.tier, queueId);
                return QueueLaneStep.TERMINAL;
            }
            _cancelUnprocessableEntry(queueId, entry);
            return QueueLaneStep.TERMINAL;
        }
        if (_isBlocked(entry.depositor)) {
            emit QueueEntrySkippedBlocked(queueId, entry.depositor);
            if (config.isPriorityLane) {
                _demotePriorityEntry(queueId, entry, BlockedAddress.selector);
                return QueueLaneStep.TERMINAL;
            }
            return QueueLaneStep.ADVANCE;
        }
        if (!IAllowlist(allowlist()).isAllowed(entry.depositor)) {
            emit QueueEntrySkippedLapsed(config.isPriorityLane ? 1 : 0, entry.depositor);
            if (config.isPriorityLane) {
                _demotePriorityEntry(queueId, entry, IAllowlist.CallerNotAllowed.selector);
                return QueueLaneStep.TERMINAL;
            }
            return QueueLaneStep.ADVANCE;
        }
        if (!_hasDepositorBounds(entry)) return QueueLaneStep.STOP;
        uint256 remainingRiskusd = _remainingQueueRiskusd(queueId, entry);
        if (remainingRiskusd == 0) revert InvalidQueueEntry();
        if (
            !config.isPriorityLane
                && (remainingRiskusd > config.availCapacity || remainingRiskusd > config.availTierCapacity)
        ) return QueueLaneStep.ADVANCE;
        if (!_depositorMinimumSharesReachable(config.tier, queueId, entry)) {
            _cancelUnprocessableEntry(queueId, entry);
            return QueueLaneStep.TERMINAL;
        }
        if (config.isPriorityLane && !_callForageLockAction(1, queueId, entry.depositor, remainingRiskusd, 0)) {
            bytes4 reason = PriorityLockUnavailable.selector;
            emit PriorityPriceUnavailable(queueId, entry.depositor, reason);
            _demotePriorityEntry(queueId, entry, reason);
            return QueueLaneStep.TERMINAL;
        }
        return _processLaneFill(queueId, demoted, entry, config, result);
    }

    function _processLaneFill(
        uint256 queueId,
        bool demoted,
        QueueEntry storage entry,
        QueueLaneConfig memory config,
        QueueLaneResult memory result
    ) internal returns (QueueLaneStep) {
        QueueEntryProgress memory progress = _queueEntryProgressFor(queueId, entry);
        uint256 fillAmount = progress.remainingRiskusd;
        if (config.availCapacity < fillAmount) fillAmount = config.availCapacity;
        if (config.availTierCapacity < fillAmount) fillAmount = config.availTierCapacity;
        if (fillAmount == 0) return config.isPriorityLane ? QueueLaneStep.STOP : QueueLaneStep.ADVANCE;
        (bool minimumReachable, uint256 minimumFillShares) = _partialFillMinimumShares(
            config.tier, progress.remainingRiskusd, progress.remainingMinimumShares, fillAmount
        );
        if (!minimumReachable) {
            if (config.isPriorityLane) {
                _demotePriorityEntry(queueId, entry, DepositOutputBelowMinimum.selector);
                return QueueLaneStep.TERMINAL;
            }
            return QueueLaneStep.ADVANCE;
        }
        // A14-03: a depositor still behind on profit epochs after the bounded catch-up keeps its place; the
        // catch-up progress made here is kept instead of reverting the whole batch.
        if (!_catchUpDepositor(_tierVaults[config.tier], entry.depositor)) {
            return config.isPriorityLane ? QueueLaneStep.STOP : QueueLaneStep.ADVANCE;
        }
        uint256 sharesMinted = _depositQueuedRiskusd(config.tier, fillAmount, entry.depositor, minimumFillShares);
        uint256 remainingAfterFill = _recordQueueFill(queueId, entry, fillAmount, sharesMinted);
        if (config.isPriorityLane) _reducePriorityLock(queueId, entry, progress.remainingRiskusd, remainingAfterFill);
        unchecked {
            config.availCapacity -= fillAmount;
            config.availTierCapacity -= fillAmount;
            ++result.processedCount;
        }
        _emitQueueProcessed(QueueProcessedData(queueId, entry.depositor, fillAmount, config.tier));
        if (fillAmount < progress.remainingRiskusd) {
            return config.isPriorityLane ? QueueLaneStep.STOP : QueueLaneStep.ADVANCE;
        }
        if (demoted) _removeDemotedStandardEntry(config.tier, queueId);
        return QueueLaneStep.TERMINAL;
    }

    function _emitQueueProcessed(QueueProcessedData memory eventData) internal {
        emit QueueProcessed(eventData.queueId, eventData.depositor, eventData.riskusdProcessed, eventData.tier);
    }

    /// @dev OF-M04: Iteration cap prevents DoS via dead entry accumulation.
    function _advanceHead(uint256[] storage lane, uint256 head, uint256 maxScan)
        internal
        view
        returns (uint256 newHead)
    {
        uint256 length = lane.length;
        newHead = head;
        uint256 scanned;
        while (newHead < length && scanned < maxScan) {
            uint256 queueId = lane[newHead];
            QueueEntry storage entry = _queueEntries[queueId];
            if (queueId != 0 && !entry.processed && !entry.cancelled) {
                break;
            }
            unchecked {
                ++newHead;
                ++scanned;
            }
        }
    }

    function _advancePriorityQueueHead(uint256[] storage lane, uint256 cursor, uint256 maxScan)
        internal
        view
        returns (uint256 nextHead)
    {
        nextHead = cursor < lane.length ? cursor : lane.length;
        uint256 scanned;
        QueueModuleStorage storage queueState = _getQueueModuleStorage();
        while (nextHead < lane.length && scanned < maxScan) {
            uint256 queueId = lane[nextHead];
            if (queueId != 0 && queueState.priorityActive[queueId]) break;
            unchecked {
                ++nextHead;
                ++scanned;
            }
        }
    }

    function _processScanLimit(uint256 budget) internal pure returns (uint256) {
        uint256 lookahead = PRIORITY_LOOKAHEAD_SCAN_LIMIT;
        if (budget > type(uint256).max - lookahead) return type(uint256).max;
        return budget + lookahead;
    }

    function _cancelUnprocessableEntry(uint256 queueId, QueueEntry storage entry) internal {
        uint256 amount = _remainingQueueRiskusd(queueId, entry);
        _removeLivePriorityEntry(entry.tier, queueId);
        _removeDemotedStandardEntry(entry.tier, queueId);
        entry.cancelled = true;
        _closeQueueEntry(entry.depositor);
        _clearQueueEntryProgress(queueId);
        if (entry.priority) _priorityRiskusdQueued[entry.depositor] -= amount;
        _totalQueuedRiskusd -= amount;

        _releaseForageLock(queueId, entry.depositor);

        _riskusd.safeTransfer(entry.depositor, amount);
        emit QueueCancelled(queueId, entry.depositor, amount);
    }

    function _demotePriorityEntry(uint256 queueId, QueueEntry storage entry, bytes4 reason) internal {
        uint256 remainingRiskusd = _remainingQueueRiskusd(queueId, entry);
        if (!entry.priority || remainingRiskusd == 0) revert InvalidQueueEntry();
        _removeLivePriorityEntry(entry.tier, queueId);
        entry.priority = false;
        _priorityRiskusdQueued[entry.depositor] -= remainingRiskusd;
        _insertDemotedStandardEntry(entry.tier, queueId);
        emit QueueEntryDemoted(queueId, entry.depositor, remainingRiskusd, reason);
        _releaseForageLock(queueId, entry.depositor);
    }

    function _depositQueuedRiskusd(uint8 tier, uint256 riskusdAmount, address depositor, uint256 depositorMinimumShares)
        internal
        returns (uint256 sharesMinted)
    {
        address tierVaultAddr = _tierVaults[tier];
        uint256 minimumShares = _minimumDepositShares(tierVaultAddr, riskusdAmount);
        if (depositorMinimumShares > minimumShares) {
            minimumShares = depositorMinimumShares;
        }

        _requireRecognitionWindowClosed(tierVaultAddr);
        // OF-M10: use forceApprove instead of bare approve
        _riskusd.forceApprove(tierVaultAddr, riskusdAmount);

        (bool success, bytes memory returnData) =
            tierVaultAddr.call(abi.encodeWithSelector(_SEL_DEPOSIT, riskusdAmount, depositor));
        if (!success) {
            assembly {
                revert(add(returnData, 32), mload(returnData))
            }
        }
        if (returnData.length < 32) revert InvalidQueueEntry();
        sharesMinted = abi.decode(returnData, (uint256));
        if (sharesMinted == 0) revert ZeroAmount();
        if (sharesMinted < minimumShares) revert DepositOutputBelowMinimum(sharesMinted, minimumShares);

        // OF-M10: reset allowance
        _riskusd.forceApprove(tierVaultAddr, 0);
    }

    /// @dev A14-02: no tier takes new deposits while its vault's Treasury holds an unanswered profit attestation.
    function _requireRecognitionWindowClosed(address tierVault) internal view {
        address treasury = IQueueTierYieldSource(tierVault).yieldSource();
        if (IQueueRecognitionWindow(treasury).recognitionWindowOpen(_vaultId)) revert RecognitionWindowOpen(_vaultId);
    }

    /// @dev Up to five bounded catch-up calls; false only when every call answered and none reported caught up.
    function _catchUpDepositor(address tierVaultAddr, address depositor) internal returns (bool) {
        for (uint256 i; i < 5; ++i) {
            (bool ok, bytes memory data) = tierVaultAddr.call(abi.encodeWithSelector(_SEL_CATCH_UP, depositor));
            if (!ok || data.length != 32) return true;
            if (abi.decode(data, (uint256)) != 0) return true;
        }
        return false;
    }

    function _minimumDepositShares(address vaultAddr, uint256 riskusdAmount) internal view returns (uint256) {
        if (vaultAddr.code.length == 0) revert CapacityProbeFailed(vaultAddr);
        (bool previewOk, bytes memory previewData) =
            vaultAddr.staticcall(abi.encodeWithSelector(_SEL_PREVIEW_DEPOSIT, riskusdAmount));
        if (!previewOk || previewData.length != 32) revert CapacityProbeFailed(vaultAddr);
        return abi.decode(previewData, (uint256));
    }

    function _hasDepositorBounds(QueueEntry storage entry) internal view returns (bool) {
        return entry.minimumShares != 0 && entry.deadline != 0;
    }

    function _depositorMinimumSharesReachable(uint8 tier, uint256 queueId, QueueEntry storage entry)
        internal
        view
        returns (bool)
    {
        QueueEntryProgress memory progress = _queueEntryProgressFor(queueId, entry);
        return _minimumSharesReachable(tier, progress.remainingMinimumShares, progress.remainingRiskusd);
    }

    function _minimumSharesReachable(uint8 tier, uint256 minimumShares, uint256 riskusdAmount)
        internal
        view
        returns (bool)
    {
        return minimumShares == 0 || minimumShares <= _minimumDepositShares(_tierVaults[tier], riskusdAmount);
    }

    function _isExpired(QueueEntry storage entry) internal view returns (bool) {
        return entry.deadline != 0 && block.timestamp > entry.deadline;
    }

    function _requireForageLockAccounting() internal view {
        if (
            !_forageLockAccountingInitialized || !_forageLockAggregateAccountingInitialized
                || !_getQueueModuleStorage().priorityIndexInitialized
                || _getQueueModuleStorage().deferredFrontierVersion != 1
        ) {
            revert LegacyForageLockAccountingUnsupported();
        }
    }

    function _callForageLockAction(
        uint8 action,
        uint256 queueId,
        address depositor,
        uint256 amount,
        uint8 admissionMode
    ) internal returns (bool result) {
        (bool success, bytes memory data) = address(this).call(
            abi.encodeWithSelector(_SEL_QUEUE_FORAGE_LOCK_ACTION, action, queueId, depositor, amount, admissionMode)
        );
        if (!success) {
            assembly {
                revert(add(data, 32), mload(data))
            }
        }
        if (data.length != 32) revert InvalidQueueEntry();
        result = abi.decode(data, (bool));
    }

    function _releaseForageLock(uint256 queueId, address depositor) internal {
        _callForageLockAction(3, queueId, depositor, 0, 0);
    }

    function _getLockupInfo(address vaultAddr, uint8 tier, address depositor)
        internal
        view
        returns (bool hasLockup, bool isExpired, bool autoRenew, bool hasPendingWithdrawal, uint256 shares)
    {
        _requireLiveTierVault(vaultAddr, tier);
        (bool success, bytes memory data) = vaultAddr.staticcall(abi.encodeWithSelector(_SEL_LOCKUPS, depositor));
        if (success) {
            if (data.length != 160) revert TierVaultProbeFailed(tier, vaultAddr, _SEL_LOCKUPS);
            uint256 rawHasLockup;
            uint256 rawExpired;
            uint256 rawAutoRenew;
            uint256 rawPending;
            assembly {
                rawHasLockup := mload(add(data, 32))
                rawExpired := mload(add(data, 64))
                rawAutoRenew := mload(add(data, 96))
                rawPending := mload(add(data, 128))
                shares := mload(add(data, 160))
            }
            if (rawHasLockup > 1 || rawExpired > 1 || rawAutoRenew > 1 || rawPending > 1) {
                revert TierVaultProbeFailed(tier, vaultAddr, _SEL_LOCKUPS);
            }
            hasLockup = rawHasLockup == 1;
            isExpired = rawExpired == 1;
            autoRenew = rawAutoRenew == 1;
            hasPendingWithdrawal = rawPending == 1;
            return (hasLockup, isExpired, autoRenew, hasPendingWithdrawal, shares);
        }

        isExpired = _readTierVaultBool(vaultAddr, tier, depositor, _SEL_IS_LOCKUP_EXPIRED);
        autoRenew = _readTierVaultBool(vaultAddr, tier, depositor, _SEL_AUTO_RENEW);
        hasPendingWithdrawal = _readTierVaultBool(vaultAddr, tier, depositor, _SEL_HAS_PENDING);
        shares = _readTierVaultAccountValue(vaultAddr, tier, depositor, _SEL_LOCKUP_SHARES);

        // OF-022: Only consider depositor as having a lockup if they actually hold shares; OPEN-473: shares waiting
        // to withdraw count, so a position wholly in escrow is still renewed at expiry.
        hasLockup = hasPendingWithdrawal || (isExpired && shares > 0);
    }

    function _readTierVaultBool(address vaultAddr, uint8 tier, address account, bytes4 selector)
        internal
        view
        returns (bool value)
    {
        (bool success, bytes memory data) = vaultAddr.staticcall(abi.encodeWithSelector(selector, account));
        if (!success || data.length != 32) revert TierVaultProbeFailed(tier, vaultAddr, selector);
        uint256 raw;
        assembly {
            raw := mload(add(data, 32))
        }
        if (raw > 1) revert TierVaultProbeFailed(tier, vaultAddr, selector);
        return raw == 1;
    }

    function _readTierVaultAccountValue(address vaultAddr, uint8 tier, address account, bytes4 selector)
        internal
        view
        returns (uint256 value)
    {
        (bool success, bytes memory data) = vaultAddr.staticcall(abi.encodeWithSelector(selector, account));
        if (!success || data.length != 32) revert TierVaultProbeFailed(tier, vaultAddr, selector);
        value = abi.decode(data, (uint256));
    }

    function _requireAuthorizedExpiredLockupProcessor(address caller, address[] calldata depositors) internal view {
        if (caller == IQueueModuleOwner(address(this)).owner() || _expiredLockupProcessors[caller]) return;
        for (uint256 i; i < depositors.length;) {
            if (depositors[i] != caller) revert UnauthorizedLockupProcessor(caller);
            unchecked {
                ++i;
            }
        }
    }

    function _syncTierVaultsFromRegistry() internal returns (VaultConfig memory config) {
        if (_vaultId == 0) revert VaultIdNotSet();
        address registry = _vaultRegistry;
        if (registry.code.length == 0) revert VaultRegistryUnavailable(registry);
        config = VaultRegistry(registry).getVault(_vaultId);
        if (config.vaultId == 0) revert VaultIdNotSet();
        _preflightTierVaults(config);

        bool needsSync;
        for (uint256 i; i < 4;) {
            if (_tierVaults[i] != config.tierVaults[i]) {
                needsSync = true;
                break;
            }
            unchecked {
                ++i;
            }
        }

        if (needsSync) {
            _storeTierVaults(config.tierVaults);
            emit TierVaultsSynced(config.tierVaults);
        }
    }

    function _storeTierVaults(address[4] memory tierVaults) internal {
        for (uint256 i; i < 4;) {
            _tierVaults[i] = tierVaults[i];
            unchecked {
                ++i;
            }
        }
    }

    function _preflightTierVaults(VaultConfig memory config) internal view {
        for (uint8 i; i < 4; ++i) {
            address tierVault = config.tierVaults[i];
            if (tierVault == address(0)) {
                if (config.status != VaultStatus.WindingDown) revert TierVaultUnavailable(i, tierVault);
            } else {
                _requireLiveTierVault(tierVault, i);
            }
        }
    }

    function _requireLiveTierVault(address tierVault, uint8 tier) internal view {
        if (tierVault == address(0) || tierVault.code.length == 0) {
            revert TierVaultUnavailable(tier, tierVault);
        }
        _readTierVaultValue(tierVault, tier, _SEL_TOTAL_SUPPLY);
        _readTierVaultValue(tierVault, tier, _SEL_TOTAL_ASSETS);
        _readTierVaultValue(tierVault, tier, _SEL_LEGITIMATE_ASSETS);
    }

    function _readTierVaultValue(address tierVault, uint8 tier, bytes4 selector)
        internal
        view
        returns (uint256 value)
    {
        if (tierVault.code.length == 0) revert TierVaultUnavailable(tier, tierVault);
        (bool success, bytes memory data) = tierVault.staticcall(abi.encodeWithSelector(selector));
        if (!success || data.length != 32) revert TierVaultProbeFailed(tier, tierVault, selector);
        value = abi.decode(data, (uint256));
    }

    function _currentVaultConfig() internal view returns (VaultConfig memory config) {
        if (_vaultId == 0) revert VaultIdNotSet();
        address registry = _vaultRegistry;
        if (registry.code.length == 0) revert VaultRegistryUnavailable(registry);
        config = VaultRegistry(registry).getVault(_vaultId);
        if (config.vaultId == 0) revert VaultIdNotSet();
        _validateQueueTierSlots(config);
    }

    function _validateQueueTierSlots(VaultConfig memory config) internal view {
        for (uint8 i; i < 4; ++i) {
            address tierVault = config.tierVaults[i];
            if (tierVault == address(0)) {
                if (config.status != VaultStatus.WindingDown) revert TierVaultUnavailable(i, tierVault);
            } else if (tierVault.code.length == 0) {
                revert TierVaultUnavailable(i, tierVault);
            }
        }
    }

    function _tryActiveForagePriceUsd() internal view returns (bool success, uint256 price, bytes4 reason) {
        if (_priceMode == uint8(PriceMode.ORACLE) && _foragePriceUsd == 0) {
            return (false, 0, InvalidOraclePrice.selector);
        }
        try IQueueModuleForagePriceView(address(this)).effectiveForagePriceUsd{gas: _PRICE_VIEW_GAS_LIMIT}() returns (
            uint256 activePrice
        ) {
            if (_priceMode == uint8(PriceMode.ORACLE)) {
                if (_lastPriceUpdate == 0 || block.timestamp - _lastPriceUpdate > CEILING_MAX_AGE) {
                    return (false, 0, StaleFORAGEPrice.selector);
                }
                uint256 priceCeiling = _foragePriceUsd;
                if (activePrice > priceCeiling) activePrice = priceCeiling;
            }
            return (true, activePrice, bytes4(0));
        } catch (bytes memory failure) {
            bytes4 failureReason = InvalidOraclePrice.selector;
            if (failure.length >= 4) {
                assembly {
                    failureReason := mload(add(failure, 32))
                }
            }
            return (false, 0, failureReason);
        }
    }

    function _combinedTotalAssets() internal view returns (uint256 totalAssets) {
        VaultConfig memory config = _currentVaultConfig();
        for (uint8 i; i < 4; ++i) {
            address tierVault = config.tierVaults[i];
            if (tierVault != address(0)) totalAssets += _readTierVaultValue(tierVault, i, _SEL_TOTAL_ASSETS);
        }
    }

    function _assertCombinedAssetsNotDecreased(uint256 beforeAssets) internal view {
        uint256 afterAssets = _combinedTotalAssets();
        if (afterAssets < beforeAssets) revert CombinedBackingAssetsDecreased(beforeAssets, afterAssets);
    }

    function _readLegitimateAssets(address vaultAddr) internal view returns (uint256) {
        if (vaultAddr.code.length == 0) revert CapacityProbeFailed(vaultAddr);
        (bool success, bytes memory data) = vaultAddr.staticcall(abi.encodeWithSelector(_SEL_LEGITIMATE_ASSETS));
        if (!success || data.length != 32) revert CapacityProbeFailed(vaultAddr);
        return abi.decode(data, (uint256));
    }

    function _availableCapacityForCap(uint256 cap) internal view returns (uint256) {
        uint256 staked = combinedStaked();
        if (staked >= cap) return 0;
        return cap - staked;
    }

    function combinedStaked() public view returns (uint256) {
        VaultConfig memory config = _currentVaultConfig();
        uint256 total;
        for (uint8 i; i < 4; ++i) {
            address tierVault = config.tierVaults[i];
            if (tierVault != address(0)) total += _readTierVaultValue(tierVault, i, _SEL_LEGITIMATE_ASSETS);
        }
        return total;
    }

    function _availableTierDepositCapacityForCap(uint8 tier, uint256 vaultCap) internal view returns (uint256) {
        VaultConfig memory config = _currentVaultConfig();
        if (config.tierVaults[tier] == address(0)) return 0;
        uint256 tierCap = _effectiveTierDepositCapForCap(tier, vaultCap);
        uint256 staked = _tierStaked(tier);
        if (staked >= tierCap) return 0;
        return tierCap - staked;
    }

    function _tierStaked(uint8 tier) internal view returns (uint256) {
        VaultConfig memory config = _currentVaultConfig();
        address tierVault = config.tierVaults[tier];
        if (tierVault == address(0)) return 0;
        return _readTierVaultValue(tierVault, tier, _SEL_LEGITIMATE_ASSETS);
    }

    function _effectiveTierDepositCapForCap(uint8 tier, uint256 vaultCap) internal view returns (uint256) {
        TierDepositCap storage cap = _tierDepositCaps[tier];
        if (!cap.configured) return vaultCap;

        uint256 baseCap = _min(cap.baseCap, vaultCap);
        uint256 proposedCap = _min(cap.proposedCap, vaultCap);
        baseCap;
        return proposedCap;
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function _requireNotBlocked(address account) internal view {
        if (_isBlocked(account)) {
            revert BlockedAddress(account);
        }
    }

    function _isBlocked(address account) internal view returns (bool) {
        address blocklist_ = _blocklist;
        if (blocklist_ == address(0)) revert BlocklistUnavailable(blocklist_);
        return IBlocklist(blocklist_).isBlocked(account);
    }

    function _addLivePriorityEntry(uint8 tier, uint256 queueId) internal {
        QueueModuleStorage storage queueState = _getQueueModuleStorage();
        if (queueId == 0 || queueState.priorityActive[queueId]) revert InvalidQueueEntry();
        uint256 tail = queueState.priorityTail[tier];
        if (tail >= queueId) revert InvalidQueueEntry();
        if (tail == 0) {
            queueState.priorityHead[tier] = queueId;
        } else {
            queueState.priorityNext[tail] = queueId;
            queueState.priorityPrevious[queueId] = tail;
        }
        queueState.priorityActive[queueId] = true;
        queueState.priorityTail[tier] = queueId;
    }

    function _removeLivePriorityEntry(uint8 tier, uint256 queueId) internal {
        QueueModuleStorage storage queueState = _getQueueModuleStorage();
        if (!queueState.priorityActive[queueId]) return;
        uint256 previousId = queueState.priorityPrevious[queueId];
        uint256 nextId = queueState.priorityNext[queueId];
        if (previousId == 0) queueState.priorityHead[tier] = nextId;
        else queueState.priorityNext[previousId] = nextId;
        if (nextId == 0) queueState.priorityTail[tier] = previousId;
        else queueState.priorityPrevious[nextId] = previousId;
        delete queueState.priorityPrevious[queueId];
        delete queueState.priorityNext[queueId];
        delete queueState.priorityActive[queueId];
    }

    function _insertDemotedStandardEntry(uint8 tier, uint256 queueId) internal {
        if (_demotedStandardHeapIndexPlusOne[queueId] != 0) revert InvalidQueueEntry();
        uint256[] storage heap = _demotedStandardHeap[tier];
        uint256 index = heap.length;
        heap.push(queueId);
        _demotedStandardHeapIndexPlusOne[queueId] = index + 1;
        _siftUpDemotedStandardHeap(tier, index);
    }

    function _removeDemotedStandardEntry(uint8 tier, uint256 queueId) internal {
        uint256 indexPlusOne = _demotedStandardHeapIndexPlusOne[queueId];
        if (indexPlusOne == 0) return;
        uint256[] storage heap = _demotedStandardHeap[tier];
        uint256 index = indexPlusOne - 1;
        if (index >= heap.length || heap[index] != queueId) revert InvalidQueueEntry();
        uint256 lastIndex = heap.length - 1;
        if (index != lastIndex) {
            uint256 movedQueueId = heap[lastIndex];
            heap[index] = movedQueueId;
            _demotedStandardHeapIndexPlusOne[movedQueueId] = index + 1;
        }
        heap.pop();
        delete _demotedStandardHeapIndexPlusOne[queueId];
        if (index < heap.length) _repairDemotedStandardHeap(tier, index);
    }

    function _repairDemotedStandardHeap(uint8 tier, uint256 index) internal {
        uint256[] storage heap = _demotedStandardHeap[tier];
        if (index > 0 && heap[index] < heap[(index - 1) / 2]) {
            _siftUpDemotedStandardHeap(tier, index);
        } else {
            _siftDownDemotedStandardHeap(tier, index);
        }
    }

    function _siftUpDemotedStandardHeap(uint8 tier, uint256 index) internal {
        uint256[] storage heap = _demotedStandardHeap[tier];
        uint256 queueId = heap[index];
        while (index > 0) {
            uint256 parent = (index - 1) / 2;
            uint256 parentQueueId = heap[parent];
            if (parentQueueId <= queueId) break;
            heap[index] = parentQueueId;
            _demotedStandardHeapIndexPlusOne[parentQueueId] = index + 1;
            index = parent;
        }
        heap[index] = queueId;
        _demotedStandardHeapIndexPlusOne[queueId] = index + 1;
    }

    function _siftDownDemotedStandardHeap(uint8 tier, uint256 index) internal {
        uint256[] storage heap = _demotedStandardHeap[tier];
        uint256 queueId = heap[index];
        uint256 length = heap.length;
        while (index < length / 2) {
            uint256 left = index * 2 + 1;
            uint256 right = left + 1;
            uint256 child = right < length && heap[right] < heap[left] ? right : left;
            uint256 childQueueId = heap[child];
            if (queueId <= childQueueId) break;
            heap[index] = childQueueId;
            _demotedStandardHeapIndexPlusOne[childQueueId] = index + 1;
            index = child;
        }
        heap[index] = queueId;
        _demotedStandardHeapIndexPlusOne[queueId] = index + 1;
    }
}

/// @title StakingQueueModule -- Delegatecall-only queue core for StakingQueue
/// @dev Holds the queue's measured hot cluster: join, cancel and process. Selectors it does not declare (tier
///      upgrade, reversion, expired lockups, tier-vault sync and unlock retry) run in StakingQueueLockupModule by a
///      second delegatecall, still in the queue's storage. Every function runs only under delegatecall from
///      StakingQueue; a direct call reverts DirectCallForbidden().
contract StakingQueueModule is StakingQueueModuleStorage {
    using SafeERC20 for IERC20;

    error LockupModuleUnavailable(address module);

    address private immutable _LOCKUP_MODULE;

    constructor(address lockupModule_) {
        if (lockupModule_.code.length == 0) revert LockupModuleUnavailable(lockupModule_);
        _LOCKUP_MODULE = lockupModule_;
    }

    /// @notice The delegatecall module that runs the tier upgrade, reversion and expired-lockup cluster.
    function lockupModule() external view returns (address) {
        return _LOCKUP_MODULE;
    }

    // -- Moved state-changing functions (gate modifiers live on the queue's forwarders) --

    function joinQueue(uint256 riskusdAmount, uint8 tier) external onlyDelegateCall {
        _joinQueue(riskusdAmount, tier, 0, 0);
    }

    function joinQueueWithBounds(uint256 riskusdAmount, uint8 tier, uint256 minimumShares, uint256 deadline)
        external
        onlyDelegateCall
    {
        _joinQueue(riskusdAmount, tier, minimumShares, deadline);
    }

    function setQueueEntryBounds(uint256 queueId, uint256 minimumShares, uint256 deadline) external onlyDelegateCall {
        if (minimumShares == 0) revert ZeroAmount();
        if (deadline < block.timestamp) revert InvalidQueueEntry();
        QueueEntry storage entry = _queueEntries[queueId];
        if (entry.depositor == address(0)) revert InvalidQueueEntry();
        if (msg.sender != entry.depositor) revert NotQueueEntryDepositor();
        if (entry.processed) revert QueueEntryAlreadyProcessed();
        if (entry.cancelled) revert QueueEntryAlreadyCancelled();
        if (entry.priority && _hasDepositorBounds(entry)) revert InvalidQueueEntry();
        if (_isExpired(entry)) revert InvalidQueueEntry();
        QueueEntryProgress memory progress = _queueEntryProgressFor(queueId, entry);
        uint256 remainingMinimumShares = _remainingMinimumShares(minimumShares, progress.sharesMinted);
        uint256 maxPreviewShares = _minimumDepositShares(_tierVaults[entry.tier], progress.remainingRiskusd);
        if (remainingMinimumShares > maxPreviewShares) {
            revert MinimumSharesUnreachable(remainingMinimumShares, maxPreviewShares);
        }
        uint256 storedDeadline = _deadlineWithinCeiling(deadline, progress.deadlineCeiling);
        entry.minimumShares = minimumShares;
        entry.deadline = storedDeadline;
        QueueEntryProgress storage storedProgress = _queueEntryProgress[queueId];
        storedProgress.remainingRiskusd = progress.remainingRiskusd;
        storedProgress.remainingMinimumShares = remainingMinimumShares;
        storedProgress.sharesMinted = progress.sharesMinted;
        storedProgress.deadlineCeiling = progress.deadlineCeiling;
        storedProgress.initialized = true;
        emit QueueEntryBoundsUpdated(queueId, entry.depositor, minimumShares, storedDeadline);
    }

    function cancelQueue(uint256 queueId) external onlyDelegateCall {
        QueueEntry storage entry = _queueEntries[queueId];
        if (entry.depositor == address(0)) revert InvalidQueueEntry();
        if (msg.sender != entry.depositor) revert NotQueueEntryDepositor();
        if (entry.processed) revert QueueEntryAlreadyProcessed();
        if (entry.cancelled) revert QueueEntryAlreadyCancelled();
        _requireNotBlocked(msg.sender);

        uint256 amount = _remainingQueueRiskusd(queueId, entry);
        _removeDemotedStandardEntry(entry.tier, queueId);
        _removeLivePriorityEntry(entry.tier, queueId);
        entry.cancelled = true;
        _closeQueueEntry(entry.depositor);
        _clearQueueEntryProgress(queueId);
        if (entry.priority) {
            _priorityRiskusdQueued[msg.sender] -= amount;
        }
        _totalQueuedRiskusd -= amount;

        _releaseForageLock(queueId, entry.depositor);

        _riskusd.safeTransfer(msg.sender, amount);

        emit QueueCancelled(queueId, msg.sender, amount);
    }

    function adminCancelQueue(uint256 entryId, address recipient) external onlyDelegateCall {
        if (recipient == address(0)) revert ZeroAddress();
        QueueEntry storage entry = _queueEntries[entryId];
        if (entry.processed || entry.cancelled) revert InvalidQueueEntry();
        uint256 amount = _remainingQueueRiskusd(entryId, entry);
        if (amount == 0) revert InvalidQueueEntry();
        _requireNotBlocked(recipient);

        address depositor = entry.depositor;
        _removeLivePriorityEntry(entry.tier, entryId);
        _removeDemotedStandardEntry(entry.tier, entryId);
        entry.cancelled = true;
        _closeQueueEntry(depositor);
        _clearQueueEntryProgress(entryId);
        if (entry.priority) _priorityRiskusdQueued[depositor] -= amount;
        _totalQueuedRiskusd -= amount;
        _releaseForageLock(entryId, depositor);
        _riskusd.safeTransfer(recipient, amount);
        emit QueueEntryCancelled(entryId, depositor, recipient, amount);
    }

    function processQueue(uint8 tier, uint256 maxEntries) external onlyDelegateCall {
        if (tier >= 4) revert InvalidTier();
        if (maxEntries == 0) revert ZeroAmount();
        if (address(_riskusd) == address(0)) revert NotInitialized();
        VaultConfig memory config = _syncTierVaultsFromRegistry();
        if (config.status != VaultStatus.Active) revert VaultNotActive();

        uint256 avail = _availableCapacityForCap(config.capacityCap);
        uint256 tierAvail = _availableTierDepositCapacityForCap(tier, config.capacityCap);

        QueueLaneConfig memory priorityConfig = QueueLaneConfig(tier, maxEntries, avail, tierAvail, true);
        QueueLaneResult memory priorityResult =
            _processPriorityLane(_tierPriorityQueue[tier], _tierPriorityHead[tier], priorityConfig);
        uint256 processed = priorityResult.processedCount;
        _tierPriorityHead[tier] = priorityResult.nextHead;
        if (priorityResult.incompleteQueueId != 0) {
            emit QueueScanIncomplete(tier, true, priorityResult.incompleteQueueId);
        }

        avail = _availableCapacityForCap(config.capacityCap);
        tierAvail = _availableTierDepositCapacityForCap(tier, config.capacityCap);

        if (processed < maxEntries && priorityResult.incompleteQueueId == 0) {
            uint256 standardBudget = maxEntries - processed;
            QueueLaneConfig memory standardConfig = QueueLaneConfig(tier, standardBudget, avail, tierAvail, false);
            _tierStandardHead[tier] =
                _advanceHead(_tierStandardQueue[tier], _tierStandardHead[tier], _processScanLimit(standardBudget));
            _processStandardLane(standardConfig);
            _tierStandardHead[tier] =
                _advanceHead(_tierStandardQueue[tier], _tierStandardHead[tier], _processScanLimit(maxEntries));
        }
    }

    /// @dev Forwards a selector this module does not declare to the lockup module, keeping the queue's context.
    fallback() external {
        if (address(this) == _SELF) revert DirectCallForbidden();
        address module = _LOCKUP_MODULE;
        assembly {
            calldatacopy(0, 0, calldatasize())
            let result := delegatecall(gas(), module, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            if iszero(result) { revert(0, returndatasize()) }
            return(0, returndatasize())
        }
    }
}
