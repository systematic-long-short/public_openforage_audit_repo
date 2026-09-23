// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
/// @dev OF-16-006: OZ 5.x ReentrancyGuard uses ERC-7201 namespaced storage — inherently upgrade-safe.
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "../IForageGovernorPause.sol";
import "../VaultRegistry.sol";
import "../FinalizeDelayProfile.sol";
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

interface IQueueModuleAtRiskBackingView {
    function totalAssets() external view returns (uint256);
    function totalSupply() external view returns (uint256);
}

/// @title StakingQueueModule -- Delegatecall-only queue core for StakingQueue
/// @dev Holds the queue's measured hot cluster: join, cancel, process, expired-lockup and retry.
///      Every function runs only under delegatecall from StakingQueue; a direct call reverts
///      DirectCallForbidden(). The module mirrors the queue's linear storage declarations so the
///      delegatecall reads and writes the queue's own slots.
contract StakingQueueModule is
    Initializable,
    Ownable2StepUpgradeable,
    PausableUpgradeable,
    ReentrancyGuard,
    UUPSUpgradeable,
    FinalizeDelayProfile,
    AllowlistGatedUpgradeable
{
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
    error CapacityProbeFailed(address vault);
    error DepositOutputBelowMinimum(uint256 sharesMinted, uint256 minimumShares);
    error InvalidForagePriceScale(uint256 price);
    error UnauthorizedLockupProcessor(address caller);
    error SequencerUptimeFeedUnavailable(address feed);
    error SequencerDown();
    error SequencerGracePeriodNotOver(uint256 startedAt, uint256 gracePeriod);
    error DirectCallForbidden();

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
    bytes4 private constant _SEL_LOCKER_BALANCE = bytes4(keccak256("lockerBalance(address,address)"));
    bytes4 private constant _SEL_LOCK = bytes4(keccak256("lock(address,uint256)"));
    bytes4 private constant _SEL_UNLOCK = bytes4(keccak256("unlock(address,uint256)"));

    enum PriceMode {
        FIXED_PRICE,
        ORACLE
    }

    // -- Events --
    event QueueJoined(
        uint256 indexed queueId, address indexed depositor, uint256 riskusdAmount, uint8 tier, bool priority
    );
    event PriorityPriceUnavailable(uint256 indexed queueId, address indexed depositor, bytes4 reason);
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

    uint256[31] private __gap; // reserved for future upgrades

    // -- Delegatecall guard --
    address private immutable _SELF;

    constructor() {
        _SELF = address(this);
    }

    modifier onlyDelegateCall() {
        if (address(this) == _SELF) revert DirectCallForbidden();
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

    function cancelQueue(uint256 queueId) external onlyDelegateCall {
        QueueEntry storage entry = _queueEntries[queueId];
        if (entry.depositor == address(0)) revert InvalidQueueEntry();
        if (msg.sender != entry.depositor) revert NotQueueEntryDepositor();
        if (entry.processed) revert QueueEntryAlreadyProcessed();
        if (entry.cancelled) revert QueueEntryAlreadyCancelled();
        _requireNotBlocked(msg.sender);

        entry.cancelled = true;
        // OF-21-029: Update state BEFORE external calls (CEI pattern, matches adminCancelQueue)
        uint256 amount = entry.riskusdAmount;
        if (entry.priority) {
            _priorityRiskusdQueued[msg.sender] -= amount;
        }
        _totalQueuedRiskusd -= amount;

        uint256 forageToUnlock = _forageLockedPerEntry[queueId];
        if (forageToUnlock > 0) {
            // OF-007 (11th audit): Only zero entry on success to allow retry
            (bool unlockSuccess,) = _forage.call(abi.encodeWithSelector(_SEL_UNLOCK, entry.depositor, forageToUnlock));
            if (unlockSuccess) {
                _forageLockedPerEntry[queueId] = 0;
            } else {
                emit ForageUnlockFailed(entry.depositor, forageToUnlock);
            }
        }

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

        uint256 processed =
            _processLane(_tierPriorityQueue[tier], _tierPriorityHead[tier], tier, maxEntries, avail, tierAvail, true);
        // OF-M04: Cap head advancement to prevent DoS via dead entry accumulation
        _tierPriorityHead[tier] = _advanceHead(_tierPriorityQueue[tier], _tierPriorityHead[tier], maxEntries);

        avail = _availableCapacityForCap(config.capacityCap);
        tierAvail = _availableTierDepositCapacityForCap(tier, config.capacityCap);

        if (processed < maxEntries && avail > 0 && tierAvail > 0) {
            uint256 standardBudget = maxEntries - processed;
            _tierStandardHead[tier] = _advanceHead(_tierStandardQueue[tier], _tierStandardHead[tier], standardBudget);
            _processLane(
                _tierStandardQueue[tier], _tierStandardHead[tier], tier, standardBudget, avail, tierAvail, false
            );
            _tierStandardHead[tier] = _advanceHead(_tierStandardQueue[tier], _tierStandardHead[tier], maxEntries);
        }
    }

    /// @notice OF-G03: Batch size is implicitly controlled by the depositors array length.
    /// Callers should limit array size to avoid out-of-gas. Off-chain keepers split large
    /// batches into multiple transactions as needed.
    function processExpiredLockups(address[] calldata depositors, uint8 tier) external onlyDelegateCall {
        if (depositors.length == 0) revert ZeroAmount();
        if (tier == 0 || tier >= 4) revert InvalidTier();
        _requireAuthorizedExpiredLockupProcessor(msg.sender, depositors);
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
            _getLockupInfo(tierVaultAddr, depositor);

        if (!hasLockup || !isExpired || hasPendingWithdrawal) return;

        if (autoRenew) {
            (bool success, bytes memory data) = tierVaultAddr.call(abi.encodeWithSelector(_SEL_RENEW_LOCKUP, depositor));
            if (!success) revert RenewLockupFailed();
            if (data.length < 32) revert InvalidQueueEntry();
            uint256 newExpiry = abi.decode(data, (uint256));

            emit LockupRenewed(depositor, tier, newExpiry);
        } else {
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

    /// @notice OF-007 (11th audit): Retry a failed FORAGE unlock for a processed/cancelled entry.
    /// Permissionless — anyone can call since it only benefits the depositor.
    function retryForageUnlock(uint256 queueId) external onlyDelegateCall {
        QueueEntry storage entry = _queueEntries[queueId];
        if (entry.depositor == address(0)) revert InvalidQueueEntry();
        if (!entry.processed && !entry.cancelled) revert InvalidQueueEntry();
        uint256 forageToUnlock = _forageLockedPerEntry[queueId];
        if (forageToUnlock != 0 && _priorityRiskusdQueued[entry.depositor] != 0) {
            revert InvalidQueueEntry();
        }
        if (forageToUnlock == 0) {
            if (_priorityRiskusdQueued[entry.depositor] != 0) revert ZeroAmount();
            (bool balanceKnown, uint256 actualLockerBalance) = _queueLockerBalance(entry.depositor);
            if (!balanceKnown || actualLockerBalance == 0) revert ZeroAmount();
            forageToUnlock = actualLockerBalance;
        } else {
            (bool balanceKnown, uint256 actualLockerBalance) = _queueLockerBalance(entry.depositor);
            if (balanceKnown && actualLockerBalance > 0 && actualLockerBalance < forageToUnlock) {
                forageToUnlock = actualLockerBalance;
            }
        }
        _requireNotBlocked(entry.depositor);

        (bool unlockSuccess,) = _forage.call(abi.encodeWithSelector(_SEL_UNLOCK, entry.depositor, forageToUnlock));
        if (unlockSuccess) {
            _forageLockedPerEntry[queueId] = 0;
        } else {
            emit ForageUnlockFailed(entry.depositor, forageToUnlock);
        }
    }

    // -- Helpers reached by the moved cluster --

    function _joinQueue(uint256 riskusdAmount, uint8 tier, uint256 minimumShares, uint256 deadline) internal {
        if (riskusdAmount == 0) revert ZeroAmount();
        if (tier >= 4) revert InvalidTier();
        if (_vaultId == 0) revert VaultIdNotSet();
        _requireNotBlocked(msg.sender);
        {
            VaultConfig memory config = VaultRegistry(_vaultRegistry).getVault(_vaultId);
            if (config.status != VaultStatus.Active) revert VaultNotActive();
        }
        if (minimumShares == 0) {
            minimumShares = _minimumDepositShares(_tierVaults[tier], riskusdAmount);
            if (minimumShares == 0) minimumShares = 1;
            deadline = type(uint256).max;
        }

        _riskusd.safeTransferFrom(msg.sender, address(this), riskusdAmount);

        uint256 queueId = _nextQueueId;
        unchecked {
            _nextQueueId = queueId + 1;
        }

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
                        (bool lockSuccess,) = _forage.call(abi.encodeWithSelector(_SEL_LOCK, msg.sender, forageToLock));
                        if (lockSuccess) {
                            isPriority = true;
                            _forageLockedPerEntry[queueId] = forageToLock;
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
            deadline: deadline
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

    function _processLane(
        uint256[] storage lane,
        uint256 head,
        uint8 tier,
        uint256 budget,
        uint256 availCapacity,
        uint256 availTierCapacity,
        bool isPriorityLane
    ) internal returns (uint256 processedCount) {
        /// @dev OF-M04: Cap total iterations (dead + live) to prevent DoS via dead entry accumulation.
        /// Without this, a long dead-entry prefix forces O(deadEntries) gas per processQueue call.
        uint256 scanLimit = _processScanLimit(budget, isPriorityLane);
        uint256 scanned;
        for (uint256 i = head; i < lane.length && processedCount < budget && scanned < scanLimit;) {
            QueueEntry storage entry = _queueEntries[lane[i]];

            if (entry.processed || entry.cancelled || _isExpired(entry)) {
                unchecked {
                    ++i;
                    ++scanned;
                }
                continue;
            }

            if (entry.riskusdAmount > availCapacity || entry.riskusdAmount > availTierCapacity) {
                unchecked {
                    ++i;
                    ++scanned;
                }
                continue;
            }
            if (!isPriorityLane && !_hasDepositorBounds(entry)) {
                break;
            }
            if (_isBlocked(entry.depositor)) {
                emit QueueEntrySkippedBlocked(lane[i], entry.depositor);
                unchecked {
                    ++i;
                    ++scanned;
                }
                continue;
            }
            if (!IAllowlist(allowlist()).isAllowed(entry.depositor)) {
                emit QueueEntrySkippedLapsed(isPriorityLane ? 1 : 0, entry.depositor);
                unchecked {
                    ++i;
                    ++scanned;
                }
                continue;
            }
            if (!_depositorMinimumSharesReachable(tier, entry)) {
                unchecked {
                    ++i;
                    ++scanned;
                }
                continue;
            }

            _depositQueuedRiskusd(tier, entry.riskusdAmount, entry.depositor, entry.minimumShares);

            entry.processed = true;
            if (isPriorityLane) {
                _priorityRiskusdQueued[entry.depositor] -= entry.riskusdAmount;
                uint256 qId = lane[i];
                uint256 forageToUnlock = _forageLockedPerEntry[qId];
                if (forageToUnlock > 0) {
                    // OF-007 (11th audit): Only zero entry on success to allow retry
                    (bool unlockSuccess,) =
                        _forage.call(abi.encodeWithSelector(_SEL_UNLOCK, entry.depositor, forageToUnlock));
                    if (unlockSuccess) {
                        _forageLockedPerEntry[qId] = 0;
                    } else {
                        emit ForageUnlockFailed(entry.depositor, forageToUnlock);
                    }
                }
            }
            _totalQueuedRiskusd -= entry.riskusdAmount;
            unchecked {
                availCapacity -= entry.riskusdAmount;
            }
            unchecked {
                availTierCapacity -= entry.riskusdAmount;
            }

            unchecked {
                ++processedCount;
            }

            emit QueueProcessed(lane[i], entry.depositor, entry.riskusdAmount, tier);
            unchecked {
                ++i;
                ++scanned;
            }
        }
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

    function _processScanLimit(uint256 budget, bool isPriorityLane) internal pure returns (uint256) {
        if (!isPriorityLane) return budget;
        uint256 lookahead = PRIORITY_LOOKAHEAD_SCAN_LIMIT;
        if (budget > type(uint256).max - lookahead) return type(uint256).max;
        return budget + lookahead;
    }

    function _depositQueuedRiskusd(uint8 tier, uint256 riskusdAmount, address depositor, uint256 depositorMinimumShares)
        internal
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
        uint256 sharesMinted = abi.decode(returnData, (uint256));
        if (sharesMinted == 0) revert ZeroAmount();
        if (sharesMinted < minimumShares) revert DepositOutputBelowMinimum(sharesMinted, minimumShares);

        // OF-M10: reset allowance
        _riskusd.forceApprove(tierVaultAddr, 0);
    }

    function _minimumDepositShares(address vaultAddr, uint256 riskusdAmount) internal view returns (uint256) {
        (bool previewOk, bytes memory previewData) =
            vaultAddr.staticcall(abi.encodeWithSelector(_SEL_PREVIEW_DEPOSIT, riskusdAmount));
        if (previewOk && previewData.length >= 32) return abi.decode(previewData, (uint256));

        uint256 assetsBefore = _readLegitimateAssets(vaultAddr);
        (bool success, bytes memory data) = vaultAddr.staticcall(abi.encodeWithSelector(_SEL_TOTAL_SUPPLY));
        if (!success || data.length < 32) return riskusdAmount;
        uint256 supplyBefore = abi.decode(data, (uint256));
        if (assetsBefore == 0 || supplyBefore == 0) return riskusdAmount;
        return Math.mulDiv(riskusdAmount, supplyBefore, assetsBefore);
    }

    function _hasDepositorBounds(QueueEntry storage entry) internal view returns (bool) {
        return entry.minimumShares != 0 && entry.deadline != 0;
    }

    function _depositorMinimumSharesReachable(uint8 tier, QueueEntry storage entry) internal view returns (bool) {
        return _minimumSharesReachable(tier, entry.minimumShares, entry.riskusdAmount);
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

    function _queueLockerBalance(address depositor) internal view returns (bool success, uint256 balance) {
        (bool ok, bytes memory data) =
            _forage.staticcall(abi.encodeWithSelector(_SEL_LOCKER_BALANCE, depositor, address(this)));
        if (!ok || data.length < 32) return (false, 0);
        return (true, abi.decode(data, (uint256)));
    }

    function _getLockupInfo(address vaultAddr, address depositor)
        internal
        view
        returns (bool hasLockup, bool isExpired, bool autoRenew, bool hasPendingWithdrawal, uint256 shares)
    {
        (bool success, bytes memory data) = vaultAddr.staticcall(abi.encodeWithSelector(_SEL_LOCKUPS, depositor));
        if (success && data.length >= 160) {
            (hasLockup, isExpired, autoRenew, hasPendingWithdrawal, shares) =
                abi.decode(data, (bool, bool, bool, bool, uint256));
            return (hasLockup, isExpired, autoRenew, hasPendingWithdrawal, shares);
        }

        (success, data) = vaultAddr.staticcall(abi.encodeWithSelector(_SEL_IS_LOCKUP_EXPIRED, depositor));
        if (success && data.length >= 32) {
            isExpired = abi.decode(data, (bool));
        }

        (success, data) = vaultAddr.staticcall(abi.encodeWithSelector(_SEL_AUTO_RENEW, depositor));
        if (success && data.length >= 32) {
            autoRenew = abi.decode(data, (bool));
        }

        (success, data) = vaultAddr.staticcall(abi.encodeWithSelector(_SEL_HAS_PENDING, depositor));
        if (success && data.length >= 32) {
            hasPendingWithdrawal = abi.decode(data, (bool));
        }

        (success, data) = vaultAddr.staticcall(abi.encodeWithSelector(_SEL_LOCKUP_SHARES, depositor));
        if (success && data.length >= 32) {
            shares = abi.decode(data, (uint256));
        }

        // OF-022: Only consider depositor as having a lockup if they actually hold shares
        hasLockup = (isExpired || hasPendingWithdrawal) && shares > 0;
    }

    function _requireAuthorizedExpiredLockupProcessor(address caller, address[] calldata depositors) internal view {
        if (caller == owner() || _expiredLockupProcessors[caller]) return;
        for (uint256 i; i < depositors.length;) {
            if (depositors[i] != caller) revert UnauthorizedLockupProcessor(caller);
            unchecked {
                ++i;
            }
        }
    }

    function _syncTierVaultsFromRegistry() internal returns (VaultConfig memory config) {
        if (_vaultId == 0) revert VaultIdNotSet();
        config = VaultRegistry(_vaultRegistry).getVault(_vaultId);

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
        return price * (10 ** (6 - decimals_));
    }

    function _combinedTotalAssets() internal view returns (uint256 totalAssets) {
        for (uint256 i; i < 4;) {
            totalAssets += IQueueModuleAtRiskBackingView(_tierVaults[i]).totalAssets();
            unchecked {
                ++i;
            }
        }
    }

    function _assertCombinedAssetsNotDecreased(uint256 beforeAssets) internal view {
        uint256 afterAssets = _combinedTotalAssets();
        if (afterAssets < beforeAssets) revert CombinedBackingAssetsDecreased(beforeAssets, afterAssets);
    }

    function _readLegitimateAssets(address vaultAddr) internal view returns (uint256) {
        (bool success, bytes memory data) = vaultAddr.staticcall(abi.encodeWithSelector(_SEL_LEGITIMATE_ASSETS));
        if (!success || data.length < 32) revert CapacityProbeFailed(vaultAddr);
        return abi.decode(data, (uint256));
    }

    function _availableCapacityForCap(uint256 cap) internal view returns (uint256) {
        uint256 staked = combinedStaked();
        if (staked >= cap) return 0;
        return cap - staked;
    }

    function combinedStaked() public view returns (uint256) {
        uint256 total;
        for (uint256 i; i < 4;) {
            total += _readLegitimateAssets(_tierVaults[i]);
            unchecked {
                ++i;
            }
        }
        return total;
    }

    function _availableTierDepositCapacityForCap(uint8 tier, uint256 vaultCap) internal view returns (uint256) {
        uint256 tierCap = _effectiveTierDepositCapForCap(tier, vaultCap);
        uint256 staked = _tierStaked(tier);
        if (staked >= tierCap) return 0;
        return tierCap - staked;
    }

    function _tierStaked(uint8 tier) internal view returns (uint256) {
        return _readLegitimateAssets(_tierVaults[tier]);
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
        return blocklist_ != address(0) && IBlocklist(blocklist_).isBlocked(account);
    }

    /// @dev The module is delegatecall-only; its own upgrade entrypoint stays owner-gated for defence in depth.
    function _authorizeUpgrade(address) internal override {}
}
