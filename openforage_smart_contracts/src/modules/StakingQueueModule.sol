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
import "../interfaces/ISequencerUptimeFeed.sol";

interface IQueueModuleForagePriceOracle {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

interface IQueueModuleOwner {
    function owner() external view returns (address);
}

/// @title StakingQueueModule -- Delegatecall-only queue core for StakingQueue
/// @dev Holds the queue's measured hot cluster: join, cancel, process, expired-lockup and retry.
///      Every function runs only under delegatecall from StakingQueue; a direct call reverts
///      DirectCallForbidden(). The module mirrors the queue's linear storage declarations so the
///      delegatecall reads and writes the queue's own slots.
contract StakingQueueModule is AllowlistGatedUpgradeable {
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

    // -- Precomputed function selectors --
    bytes4 private constant _SEL_LOCKED_BALANCE = bytes4(keccak256("lockedBalance(address)"));
    bytes4 private constant _SEL_DEPOSIT = bytes4(keccak256("deposit(uint256,address)"));
    bytes4 private constant _SEL_PREVIEW_DEPOSIT = bytes4(keccak256("previewDeposit(uint256)"));
    bytes4 private constant _SEL_REDEEM_UPGRADE = bytes4(keccak256("redeemForUpgrade(address,uint256)"));
    bytes4 private constant _SEL_RENEW_LOCKUP = bytes4(keccak256("renewLockup(address)"));
    bytes4 private constant _SEL_REDEEM_REVERSION = bytes4(keccak256("redeemForReversion(address,uint256)"));
    bytes4 private constant _SEL_LOCKUPS = bytes4(keccak256("lockups(address)"));
    bytes4 private constant _SEL_IS_LOCKUP_EXPIRED = bytes4(keccak256("isLockupExpired(address)"));
    bytes4 private constant _SEL_AUTO_RENEW = bytes4(keccak256("autoRenewEnabled(address)"));
    bytes4 private constant _SEL_HAS_PENDING = bytes4(keccak256("hasPendingWithdrawal(address)"));
    bytes4 private constant _SEL_LOCKUP_SHARES = bytes4(keccak256("lockupShares(address)"));
    bytes4 private constant _SEL_LEGITIMATE_ASSETS = bytes4(keccak256("legitimateAssets()"));
    bytes4 private constant _SEL_TOTAL_SUPPLY = bytes4(keccak256("totalSupply()"));
    bytes4 private constant _SEL_TOTAL_ASSETS = bytes4(keccak256("totalAssets()"));
    bytes4 private constant _SEL_QUEUE_FORAGE_LOCK_ACTION =
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
    uint256 internal constant RAY = 1e27;
    uint256 internal constant AT_RISK_SHARE_SCALE = 1e6;
    uint256 internal constant PRIORITY_LOOKAHEAD_SCAN_LIMIT = 64;

    // -- Storage (mirrors StakingQueue so delegatecall reads the queue's slots) --
    IERC20 private _riskusd;
    address private _forage;
    address[4] private _tierVaults;
    address private _vaultRegistry;
    uint256 private _vaultId;
    address private _forageGovernor;
    uint256 private _nextQueueId;
    uint256 private _totalQueuedRiskusd;
    uint256 private _foragePriceUsd;

    mapping(uint256 => QueueEntry) private _queueEntries;
    mapping(uint8 => uint256[]) private _tierPriorityQueue;
    mapping(uint8 => uint256[]) private _tierStandardQueue;
    mapping(uint8 => uint256) private _tierPriorityHead;
    mapping(uint8 => uint256) private _tierStandardHead;

    uint256 private _priorityMultiplier;
    mapping(address => uint256) private _priorityRiskusdQueued;

    mapping(uint256 => uint256) private _forageLockedPerEntry;

    /// @dev OF-13-012: Timestamp of last FORAGE price update for staleness check
    uint256 private _lastPriceUpdate;

    /// @dev OF-15-005: Pending ForageGovernor for two-step setter
    address internal _pendingForageGovernor;
    uint256 internal _pendingForageGovernorProposedAt;

    uint8 private _priceMode;
    address private _foragePriceOracle;
    uint8 private _foragePriceOracleDecimals;
    uint256 private _oraclePriceMaxStaleness;
    uint256 private _pendingForagePriceUsd;
    uint256 private _pendingForagePriceUsdProposedAt;
    bool private _pendingForagePriceUsdExists;
    uint8 private _pendingForagePriceMode;
    uint256 private _pendingForagePriceModeProposedAt;
    bool private _pendingForagePriceModeExists;
    address private _pendingForagePriceOracle;
    uint256 private _pendingOraclePriceMaxStaleness;
    uint8 private _pendingForagePriceOracleDecimals;
    uint256 private _pendingForagePriceOracleProposedAt;
    mapping(uint8 => TierDepositCap) private _tierDepositCaps;
    address internal _blocklist;
    mapping(address => bool) private _expiredLockupProcessors;
    address internal _sequencerUptimeFeed;
    mapping(uint256 => uint8) private _priorityEntryAdmissionMode;
    mapping(uint256 => QueueEntryProgress) private _queueEntryProgress;
    mapping(uint8 => uint256[]) private _demotedStandardHeap;
    mapping(uint256 => uint256) private _demotedStandardHeapIndexPlusOne;
    mapping(address => uint256) private _forageLockWeightByDepositor;
    mapping(uint256 => uint256) private _forageLockRequirementPerEntry;
    bool private _forageLockAccountingInitialized;
    mapping(address => uint256) private _forageLockActiveRequirementByDepositor;
    mapping(uint256 => uint256) private _forageUnlockPendingWeightPerEntry;
    mapping(address => uint256) private _forageLockPendingUnlockWeightByDepositor;
    bool private _forageLockAggregateAccountingInitialized;
    mapping(uint8 => uint256) private _tierStandardScanCursor;
    mapping(uint8 => uint256) private _tierPriorityScanCursor;

    uint256[18] private __gap; // reserved for future upgrades

    // -- Delegatecall guard --
    address private immutable _SELF;

    constructor() {
        _SELF = address(this);
    }

    modifier onlyDelegateCall() {
        if (address(this) == _SELF) revert DirectCallForbidden();
        _requireForageLockAccounting();
        _;
    }

    // -- Moved state-changing functions (gate modifiers live on the queue's forwarders) --

    function joinQueue(uint256 riskusdAmount, uint8 tier) external onlyDelegateCall {
        _joinQueue(riskusdAmount, tier, 0, 0);
    }

    function joinQueueWithBounds(uint256 riskusdAmount, uint8 tier, uint256 minimumShares, uint256 deadline)
        external
        onlyDelegateCall
    {
        if (minimumShares == 0) revert ZeroAmount();
        if (deadline < block.timestamp) revert InvalidQueueEntry();
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
        entry.cancelled = true;
        _clearQueueEntryProgress(queueId);
        if (entry.priority) {
            _priorityRiskusdQueued[msg.sender] -= amount;
        }
        _totalQueuedRiskusd -= amount;

        _releaseForageLock(queueId, entry.depositor);

        _riskusd.safeTransfer(msg.sender, amount);

        emit QueueCancelled(queueId, msg.sender, amount);
    }

    function processQueue(uint8 tier, uint256 maxEntries) external onlyDelegateCall {
        if (tier >= 4) revert InvalidTier();
        if (maxEntries == 0) revert ZeroAmount();
        if (address(_riskusd) == address(0)) revert NotInitialized();
        VaultConfig memory config = _syncTierVaultsFromRegistry();
        if (config.status != VaultStatus.Active) revert VaultNotActive();

        uint256 avail = _availableCapacityForCap(config.capacityCap);
        if (avail == 0) revert NoCapacityAvailable();
        uint256 tierAvail = _availableTierDepositCapacityForCap(tier, config.capacityCap);
        if (tierAvail == 0) revert NoCapacityAvailable();

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

        if (processed < maxEntries && avail > 0 && tierAvail > 0 && priorityResult.incompleteQueueId == 0) {
            uint256 standardBudget = maxEntries - processed;
            QueueLaneConfig memory standardConfig = QueueLaneConfig(tier, standardBudget, avail, tierAvail, false);
            _tierStandardHead[tier] = _advanceHead(_tierStandardQueue[tier], _tierStandardHead[tier], standardBudget);
            _processStandardLane(standardConfig);
            _tierStandardHead[tier] = _advanceHead(_tierStandardQueue[tier], _tierStandardHead[tier], maxEntries);
        }
    }

    function syncTierVaults() external onlyDelegateCall {
        VaultConfig memory config = _syncTierVaultsFromRegistry();
        emit TierVaultsSynced(config.tierVaults);
    }

    function upgradeTier(uint8 fromTier, uint8 toTier, uint256 atriskusdAmount) external onlyDelegateCall {
        if (atriskusdAmount == 0) revert ZeroAmount();
        if (fromTier >= 4 || toTier >= 4) revert InvalidTier();
        if (toTier <= fromTier) revert InvalidTierUpgrade();
        _requireNotBlocked(msg.sender);
        uint256 riskusdAmount;
        uint256 newShares;
        {
            VaultConfig memory config = _syncTierVaultsFromRegistry();
            if (config.status != VaultStatus.Active) revert VaultNotActive();
            address sourceVault = config.tierVaults[fromTier];
            address destVault = config.tierVaults[toTier];
            _requireLiveTierVault(sourceVault, fromTier);
            _requireLiveTierVault(destVault, toTier);
            uint256 combinedAssetsBefore = _combinedTotalAssets();
            (bool successRedeem, bytes memory redeemData) =
                sourceVault.call(abi.encodeWithSelector(_SEL_REDEEM_UPGRADE, msg.sender, atriskusdAmount));
            if (!successRedeem) {
                assembly {
                    revert(add(redeemData, 32), mload(redeemData))
                }
            }
            if (redeemData.length < 32) revert InvalidQueueEntry();
            riskusdAmount = abi.decode(redeemData, (uint256));
            if (riskusdAmount == 0) revert ZeroAmount();
            uint256 combinedAvailable = _availableCapacityForCap(config.capacityCap);
            uint256 tierAvailable = _availableTierDepositCapacityForCap(toTier, config.capacityCap);
            if (riskusdAmount > combinedAvailable) revert NoCapacityAvailable();
            if (riskusdAmount > tierAvailable) {
                revert TierDepositCapExceeded(toTier, riskusdAmount, tierAvailable);
            }
            _riskusd.forceApprove(destVault, riskusdAmount);
            (bool successDeposit, bytes memory depositData) =
                destVault.call(abi.encodeWithSelector(_SEL_DEPOSIT, riskusdAmount, msg.sender));
            if (!successDeposit) {
                assembly {
                    revert(add(depositData, 32), mload(depositData))
                }
            }
            if (depositData.length < 32) revert InvalidQueueEntry();
            newShares = abi.decode(depositData, (uint256));
            if (newShares == 0) revert ZeroAmount();
            _riskusd.forceApprove(destVault, 0);
            _assertCombinedAssetsNotDecreased(combinedAssetsBefore);
        }
        emit TierUpgraded(msg.sender, fromTier, toTier, atriskusdAmount, riskusdAmount, newShares);
    }

    function selfRevert(uint8 tier) external onlyDelegateCall {
        if (tier == 0 || tier >= 4) revert InvalidTier();
        _requireNotBlocked(msg.sender);
        SelfReversion memory state = _prepareSelfReversion(tier, msg.sender);
        _depositSelfReversion(msg.sender, state);
        emit LockupReverted(msg.sender, tier, state.riskusdAmount);
    }

    function _prepareSelfReversion(uint8 tier, address depositor) private returns (SelfReversion memory state) {
        VaultConfig memory config = _syncTierVaultsFromRegistry();
        address tierVault = config.tierVaults[tier];
        state.vaultZero = config.tierVaults[0];
        _requireLiveTierVault(state.vaultZero, 0);
        uint256 shares = _expiredLockupShares(tierVault, tier, depositor);
        state.combinedAssetsBefore = _combinedTotalAssets();
        state.riskusdAmount = _redeemForReversion(tierVault, depositor, shares);
        uint256 tierZeroCapacity = _availableTierDepositCapacityForCap(0, config.capacityCap);
        if (state.riskusdAmount > tierZeroCapacity) {
            revert TierDepositCapExceeded(0, state.riskusdAmount, tierZeroCapacity);
        }
    }

    function _expiredLockupShares(address tierVault, uint8 tier, address depositor) private view returns (uint256) {
        (bool hasLockup, bool isExpired, bool autoRenew, bool hasPendingWithdrawal, uint256 shares) =
            _getLockupInfo(tierVault, tier, depositor);
        if (!hasLockup || !isExpired || hasPendingWithdrawal || autoRenew) revert InvalidQueueEntry();
        return shares;
    }

    function _redeemForReversion(address tierVault, address depositor, uint256 shares)
        private
        returns (uint256 riskusdAmount)
    {
        (bool success, bytes memory data) =
            tierVault.call(abi.encodeWithSelector(_SEL_REDEEM_REVERSION, depositor, shares));
        if (!success) revert RedeemForReversionFailed();
        if (data.length < 32) revert InvalidQueueEntry();
        riskusdAmount = abi.decode(data, (uint256));
        if (riskusdAmount == 0) revert ZeroAmount();
    }

    function _depositSelfReversion(address depositor, SelfReversion memory state) private {
        _riskusd.forceApprove(state.vaultZero, state.riskusdAmount);
        (bool success, bytes memory data) =
            state.vaultZero.call(abi.encodeWithSelector(_SEL_DEPOSIT, state.riskusdAmount, depositor));
        _riskusd.forceApprove(state.vaultZero, 0);
        if (!success) revert Tier0DepositFailed();
        if (data.length < 32) revert InvalidQueueEntry();
        uint256 sharesMinted = abi.decode(data, (uint256));
        if (sharesMinted == 0) revert ZeroAmount();
        _assertCombinedAssetsNotDecreased(state.combinedAssetsBefore);
    }

    /// @notice OF-G03: Batch size is implicitly controlled by the depositors array length.
    /// Callers should limit array size to avoid out-of-gas. Off-chain keepers split large
    /// batches into multiple transactions as needed.
    function processExpiredLockups(address[] calldata depositors, uint8 tier) external onlyDelegateCall {
        if (depositors.length == 0) revert ZeroAmount();
        if (tier == 0 || tier >= 4) revert InvalidTier();
        _requireAuthorizedExpiredLockupProcessor(msg.sender, depositors);
        if (_blocklist == address(0)) revert BlocklistUnavailable(_blocklist);
        _syncTierVaultsFromRegistry();

        address tierVaultAddr = _tierVaults[tier];
        address vault0Addr = _tierVaults[0];

        for (uint256 i; i < depositors.length;) {
            try this._processOneExpiredLockup(depositors[i], tier, tierVaultAddr, vault0Addr) {}
            catch (bytes memory reason) {
                emit ExpiredLockupProcessingFailed(depositors[i], tier, reason);
            }
            unchecked {
                ++i;
            }
        }
    }

    function setExpiredLockupProcessor(address processor, bool authorized) external onlyDelegateCall {
        if (processor == address(0)) revert ZeroAddress();
        _expiredLockupProcessors[processor] = authorized;
        emit ExpiredLockupProcessorSet(processor, authorized);
    }

    /// @dev Process one depositor's expired lockup. External so it can be called via try/catch.
    /// OF-010: The try/catch in processExpiredLockups() wraps this external call. If any
    /// individual lockup processing reverts (e.g., tier vault paused, insufficient liquidity),
    /// the failure is caught, an ExpiredLockupProcessingFailed event is emitted, and remaining
    /// depositors continue processing. This prevents one bad lockup from blocking the entire batch.
    function _processOneExpiredLockup(address depositor, uint8 tier, address tierVaultAddr, address vault0Addr)
        external
        onlyDelegateCall
    {
        if (msg.sender != address(this)) revert InternalOnly();
        _requireNotBlocked(depositor);

        (bool hasLockup, bool isExpired, bool autoRenew, bool hasPendingWithdrawal, uint256 shares) =
            _getLockupInfo(tierVaultAddr, tier, depositor);

        if (!hasLockup || !isExpired || hasPendingWithdrawal) return;

        if (autoRenew) {
            (bool success, bytes memory data) = tierVaultAddr.call(abi.encodeWithSelector(_SEL_RENEW_LOCKUP, depositor));
            if (!success) revert RenewLockupFailed();
            if (data.length < 32) revert InvalidQueueEntry();
            uint256 newExpiry = abi.decode(data, (uint256));

            emit LockupRenewed(depositor, tier, newExpiry);
        } else {
            _requireLiveTierVault(vault0Addr, 0);
            uint256 combinedAssetsBefore = _combinedTotalAssets();
            uint256 riskusdAmount;
            {
                (bool success, bytes memory data) =
                    tierVaultAddr.call(abi.encodeWithSelector(_SEL_REDEEM_REVERSION, depositor, shares));
                if (!success) revert RedeemForReversionFailed();
                if (data.length < 32) revert InvalidQueueEntry();
                riskusdAmount = abi.decode(data, (uint256));
            }
            if (riskusdAmount == 0) revert ZeroAmount();

            // OF-M10: use forceApprove instead of bare approve
            _riskusd.forceApprove(vault0Addr, riskusdAmount);

            {
                (bool success, bytes memory data) =
                    vault0Addr.call(abi.encodeWithSelector(_SEL_DEPOSIT, riskusdAmount, depositor));
                if (!success) revert Tier0DepositFailed();
                if (data.length < 32) revert InvalidQueueEntry();
                uint256 sharesMinted = abi.decode(data, (uint256));
                if (sharesMinted == 0) revert ZeroAmount();
            }

            // OF-M10: reset allowance
            _riskusd.forceApprove(vault0Addr, 0);

            _assertCombinedAssetsNotDecreased(combinedAssetsBefore);
            emit LockupReverted(depositor, tier, riskusdAmount);
        }
    }

    /// @notice Retry a processed or cancelled entry's failed FORAGE unlock.
    /// @dev Any Allowlist-eligible caller may retry; the unlock remains credited to the depositor.
    function retryForageUnlock(uint256 queueId) external onlyDelegateCall {
        QueueEntry storage entry = _queueEntries[queueId];
        if (entry.depositor == address(0)) revert InvalidQueueEntry();
        uint256 forageToUnlock = _forageLockedPerEntry[queueId];
        uint256 pendingWeight = _forageUnlockPendingWeightPerEntry[queueId];
        uint256 requirement = _forageLockRequirementPerEntry[queueId];
        bool demoted = !entry.priority && !entry.processed && !entry.cancelled
            && (forageToUnlock != 0 || pendingWeight != 0 || requirement != 0);
        if (!entry.processed && !entry.cancelled && !demoted) revert InvalidQueueEntry();
        if (forageToUnlock == 0 && pendingWeight == 0 && requirement == 0) revert ZeroAmount();
        if (!demoted && _priorityRiskusdQueued[entry.depositor] != 0) revert InvalidQueueEntry();
        _requireNotBlocked(entry.depositor);
        _releaseForageLock(queueId, entry.depositor);
    }

    // -- Helpers reached by the moved cluster --

    function _joinQueue(uint256 riskusdAmount, uint8 tier, uint256 minimumShares, uint256 deadline) internal {
        if (riskusdAmount == 0) revert ZeroAmount();
        if (tier >= 4) revert InvalidTier();
        if (_vaultId == 0) revert VaultIdNotSet();
        _requireNotBlocked(msg.sender);
        uint8 admissionMode = _priceMode;
        {
            VaultConfig memory config = VaultRegistry(_vaultRegistry).getVault(_vaultId);
            if (config.status != VaultStatus.Active) revert VaultNotActive();
        }
        uint256 maxPreviewShares = _minimumDepositShares(_tierVaults[tier], riskusdAmount);
        if (minimumShares == 0) {
            if (maxPreviewShares == 0) revert MinimumSharesUnreachable(1, 0);
            minimumShares = 1;
            deadline = type(uint256).max;
        } else if (minimumShares > maxPreviewShares) {
            revert MinimumSharesUnreachable(minimumShares, maxPreviewShares);
        }

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
                if (_isSequencerFailure(priceReason)) {
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
        if (remainingAfterFill == 0) entry.processed = true;
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
        _callForageLockAction(2, queueId, entry.depositor, lockToKeep, 0);
    }

    function _processPriorityLane(uint256[] storage lane, uint256 head, QueueLaneConfig memory config)
        private
        returns (QueueLaneResult memory result)
    {
        uint256 first = head < lane.length ? head : lane.length;
        uint256 i = _tierPriorityScanCursor[config.tier];
        if (i < first || i >= lane.length) i = first;
        uint256 startCursor = i;
        result.nextHead = first;
        uint256 scanned;
        uint256 scanLimit = _processScanLimit(config.budget);
        while (i < lane.length && scanned < scanLimit && result.processedCount < config.budget) {
            uint256 queueId = lane[i];
            QueueLaneStep step = _processLaneEntry(queueId, false, config, result);
            if (step == QueueLaneStep.STOP) {
                result.incompleteQueueId = queueId;
                i = result.nextHead;
                break;
            }
            if (i == result.nextHead && step == QueueLaneStep.TERMINAL) result.nextHead = i + 1;
            unchecked {
                ++i;
                ++scanned;
            }
        }
        if (i < lane.length) {
            _tierPriorityScanCursor[config.tier] = i;
            if (result.incompleteQueueId == 0) result.incompleteQueueId = lane[i];
        } else {
            _tierPriorityScanCursor[config.tier] = result.nextHead;
            if (result.nextHead < startCursor && result.incompleteQueueId == 0) {
                result.incompleteQueueId = lane[result.nextHead];
                _tierPriorityScanCursor[config.tier] = result.nextHead;
            }
        }
    }

    function _processStandardLane(QueueLaneConfig memory config) private {
        QueueLaneResult memory result;
        uint256 nextId = _nextQueueId;
        uint256 lastId = nextId - 1;
        uint256 cursor = _tierStandardScanCursor[config.tier];
        if (cursor == 0 || cursor >= lastId) {
            uint256 firstId = _firstStandardCandidateId(config.tier);
            if (firstId == 0) return;
            cursor = firstId - 1;
        }
        uint256 scanned;
        while (cursor < lastId && scanned < config.budget) {
            uint256 queueId = cursor + 1;
            QueueEntry storage entry = _queueEntries[queueId];
            unchecked {
                ++scanned;
            }
            if (entry.depositor == address(0) || entry.tier != config.tier || entry.priority) {
                cursor = queueId;
                continue;
            }
            bool demoted = _demotedStandardHeapIndexPlusOne[queueId] != 0;
            if (_processLaneEntry(queueId, demoted, config, result) == QueueLaneStep.STOP) {
                result.incompleteQueueId = queueId;
                cursor = 0;
                break;
            }
            cursor = queueId;
        }
        _tierStandardScanCursor[config.tier] = cursor >= lastId ? 0 : cursor;
    }

    function _firstStandardCandidateId(uint8 tier) private view returns (uint256 firstId) {
        uint256 head = _tierStandardHead[tier];
        uint256[] storage standard = _tierStandardQueue[tier];
        if (head < standard.length) firstId = standard[head];
        uint256[] storage demoted = _demotedStandardHeap[tier];
        if (demoted.length != 0 && (firstId == 0 || demoted[0] < firstId)) firstId = demoted[0];
    }

    function _processLaneEntry(
        uint256 queueId,
        bool demoted,
        QueueLaneConfig memory config,
        QueueLaneResult memory result
    ) internal returns (QueueLaneStep) {
        QueueEntry storage entry = _queueEntries[queueId];
        if ((config.isPriorityLane && !entry.priority) || entry.processed || entry.cancelled || _isExpired(entry)) {
            if (demoted) _removeDemotedStandardEntry(config.tier, queueId);
            return QueueLaneStep.TERMINAL;
        }
        if (_isBlocked(entry.depositor)) {
            emit QueueEntrySkippedBlocked(queueId, entry.depositor);
            return QueueLaneStep.ADVANCE;
        }
        if (!IAllowlist(allowlist()).isAllowed(entry.depositor)) {
            emit QueueEntrySkippedLapsed(config.isPriorityLane ? 1 : 0, entry.depositor);
            return QueueLaneStep.ADVANCE;
        }
        if (!_hasDepositorBounds(entry)) return QueueLaneStep.STOP;
        uint256 remainingRiskusd = _remainingQueueRiskusd(queueId, entry);
        if (remainingRiskusd == 0) revert InvalidQueueEntry();
        if (
            !config.isPriorityLane
                && (remainingRiskusd > config.availCapacity || remainingRiskusd > config.availTierCapacity)
        ) return QueueLaneStep.STOP;
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
        if (fillAmount == 0) return QueueLaneStep.STOP;
        (bool minimumReachable, uint256 minimumFillShares) = _partialFillMinimumShares(
            config.tier, progress.remainingRiskusd, progress.remainingMinimumShares, fillAmount
        );
        if (!minimumReachable) return QueueLaneStep.STOP;
        uint256 sharesMinted = _depositQueuedRiskusd(config.tier, fillAmount, entry.depositor, minimumFillShares);
        uint256 remainingAfterFill = _recordQueueFill(queueId, entry, fillAmount, sharesMinted);
        if (config.isPriorityLane) _reducePriorityLock(queueId, entry, progress.remainingRiskusd, remainingAfterFill);
        unchecked {
            config.availCapacity -= fillAmount;
            config.availTierCapacity -= fillAmount;
            ++result.processedCount;
        }
        _emitQueueProcessed(QueueProcessedData(queueId, entry.depositor, fillAmount, config.tier));
        if (fillAmount < progress.remainingRiskusd) return QueueLaneStep.STOP;
        if (demoted) _removeDemotedStandardEntry(config.tier, queueId);
        return QueueLaneStep.TERMINAL;
    }

    function _emitQueueProcessed(QueueProcessedData memory eventData) private {
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
            QueueEntry storage entry = _queueEntries[lane[newHead]];
            if (!entry.processed && !entry.cancelled && !_isExpired(entry)) {
                break;
            }
            unchecked {
                ++newHead;
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
        _removeDemotedStandardEntry(entry.tier, queueId);
        entry.cancelled = true;
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
        entry.priority = false;
        _priorityRiskusdQueued[entry.depositor] -= remainingRiskusd;
        _insertDemotedStandardEntry(entry.tier, queueId);
        _tierStandardScanCursor[entry.tier] = 0;
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
        if (!_forageLockAccountingInitialized || !_forageLockAggregateAccountingInitialized) {
            revert LegacyForageLockAccountingUnsupported();
        }
    }

    function _callForageLockAction(
        uint8 action,
        uint256 queueId,
        address depositor,
        uint256 amount,
        uint8 admissionMode
    ) private returns (bool result) {
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

    function _releaseForageLock(uint256 queueId, address depositor) private {
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

        // OF-022: Only consider depositor as having a lockup if they actually hold shares
        hasLockup = (isExpired || hasPendingWithdrawal) && shares > 0;
    }

    function _readTierVaultBool(address vaultAddr, uint8 tier, address account, bytes4 selector)
        private
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
        private
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
        if (_priceMode == uint8(PriceMode.FIXED_PRICE)) {
            if (_foragePriceUsd > 0 && _lastPriceUpdate > 0 && block.timestamp - _lastPriceUpdate > 7 days) {
                return (false, 0, StaleFORAGEPrice.selector);
            }
            return (true, _foragePriceUsd, bytes4(0));
        }

        address oracle = _foragePriceOracle;
        if (oracle == address(0)) return (false, 0, OracleNotConfigured.selector);
        (bool sequencerOk, bytes4 sequencerReason) = _trySequencerUp();
        if (!sequencerOk) return (false, 0, sequencerReason);
        try IQueueModuleForagePriceOracle(oracle).latestRoundData() returns (
            uint80 roundId, int256 answer, uint256, uint256 updatedAt, uint80 answeredInRound
        ) {
            if (answer <= 0 || updatedAt == 0 || updatedAt > block.timestamp || answeredInRound < roundId) {
                return (false, 0, InvalidOraclePrice.selector);
            }
            if (block.timestamp - updatedAt > _oraclePriceMaxStaleness) {
                return (false, 0, StaleFORAGEPrice.selector);
            }

            uint256 normalized = _normalizeOraclePrice(uint256(answer), _foragePriceOracleDecimals);
            if (normalized == 0 || normalized > MAX_FIXED_FORAGE_PRICE_USD) {
                return (false, 0, InvalidOraclePrice.selector);
            }
            return (true, normalized, bytes4(0));
        } catch {
            return (false, 0, InvalidOraclePrice.selector);
        }
    }

    function _trySequencerUp() internal view returns (bool success, bytes4 reason) {
        address feed = _sequencerUptimeFeed;
        if (feed == address(0)) {
            if (block.chainid == ARBITRUM_ONE_CHAIN_ID) {
                return (false, SequencerUptimeFeedUnavailable.selector);
            }
            return (true, bytes4(0));
        }

        try ISequencerUptimeFeed(feed).latestRoundData() returns (
            uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound
        ) {
            if (updatedAt == 0 || updatedAt > block.timestamp || answeredInRound < roundId) {
                return (false, SequencerUptimeFeedUnavailable.selector);
            }
            if (answer != 0) return (false, SequencerDown.selector);
            if (
                startedAt == 0 || block.timestamp <= startedAt
                    || block.timestamp - startedAt <= SEQUENCER_UPTIME_GRACE_PERIOD
            ) {
                return (false, SequencerGracePeriodNotOver.selector);
            }
            return (true, bytes4(0));
        } catch {
            return (false, SequencerUptimeFeedUnavailable.selector);
        }
    }

    function _isSequencerFailure(bytes4 reason) internal pure returns (bool) {
        return reason == SequencerUptimeFeedUnavailable.selector || reason == SequencerDown.selector
            || reason == SequencerGracePeriodNotOver.selector;
    }

    function _normalizeOraclePrice(uint256 price, uint8 decimals_) internal pure returns (uint256) {
        if (decimals_ == 6) return price;
        if (decimals_ > 6) return price / (10 ** (decimals_ - 6));
        uint256 scale = 10 ** (6 - decimals_);
        if (price > MAX_FIXED_FORAGE_PRICE_USD / scale) return 0;
        return price * scale;
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
