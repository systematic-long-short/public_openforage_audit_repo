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
import "./IForageGovernorPause.sol";
import "./VaultRegistry.sol";
import "./FinalizeDelayProfile.sol";
import "./interfaces/IVaultRegistry.sol";
import "./interfaces/IBlocklist.sol";

interface IForagePriceOracle {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

interface IGuardianModulePermissions {
    function PERMISSION_CAN_PAUSE() external view returns (uint256);
    function hasPermission(address account, uint256 permission) external view returns (bool);
}

interface IAtRiskBackingView {
    function totalAssets() external view returns (uint256);
    function totalSupply() external view returns (uint256);
}

/// @title StakingQueue -- Dual-lane FIFO staking queue for RISKUSD deposits
contract StakingQueue is
    Initializable,
    Ownable2StepUpgradeable,
    PausableUpgradeable,
    ReentrancyGuard,
    UUPSUpgradeable,
    FinalizeDelayProfile
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
    event QueueEntryBoundsUpdated(
        uint256 indexed queueId, address indexed depositor, uint256 minimumShares, uint256 deadline
    );
    event ForageUnlockFailed(address indexed depositor, uint256 amount);
    event TierVaultsSynced(address[4] newTierVaults); // OF-13-027
    event BlocklistSet(address indexed oldBlocklist, address indexed newBlocklist);

    // -- Constants --
    uint256 public constant PROPOSAL_EXPIRY = 30 days; // OF-15-005
    uint256 public constant MAX_FIXED_FORAGE_PRICE_USD = 1_000_000e6;
    uint256 internal constant RAY = 1e27;
    uint256 internal constant AT_RISK_SHARE_SCALE = 1e6;
    uint256 internal constant PRIORITY_LOOKAHEAD_SCAN_LIMIT = 64;

    // -- Storage --
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

    uint256[33] private __gap; // reserved for future upgrades

    // -- Constructor (disable initializers on implementation) --
    constructor() {
        _disableInitializers();
    }

    // -- Initializer --
    function initialize(
        address riskusd_,
        address forage_,
        address[4] calldata tierVaults_,
        address vaultRegistry_,
        address initialOwner_
    ) external initializer {
        if (riskusd_ == address(0)) revert ZeroAddress();
        if (forage_ == address(0)) revert ZeroAddress();
        if (vaultRegistry_ == address(0)) revert ZeroAddress();
        if (initialOwner_ == address(0)) revert ZeroAddress();
        for (uint256 i; i < 4;) {
            if (tierVaults_[i] == address(0)) revert ZeroAddress();
            unchecked {
                ++i;
            }
        }

        __Ownable_init(initialOwner_);
        __Pausable_init();

        _riskusd = IERC20(riskusd_);
        _forage = forage_;
        _vaultRegistry = vaultRegistry_;
        for (uint256 i; i < 4;) {
            _tierVaults[i] = tierVaults_[i];
            unchecked {
                ++i;
            }
        }

        _nextQueueId = 1;
    }

    // -- Modifiers --
    // OF-19-002: owner, governor, or guardian module
    modifier onlyOwnerOrGovernor() {
        if (msg.sender != owner() && msg.sender != _forageGovernor && !_isGuardianModule(msg.sender)) {
            revert OwnableUnauthorizedAccount(msg.sender);
        }
        _;
    }

    modifier onlyTierCapShrinker() {
        if (
            msg.sender != owner() && msg.sender != _forageGovernor && !_isGuardianModule(msg.sender)
                && !_isGuardianAccount(msg.sender)
        ) {
            revert OwnableUnauthorizedAccount(msg.sender);
        }
        _;
    }

    /// @dev OF-19-002: Check if caller is the GuardianModule via ForageGovernor query.
    function _isGuardianModule(address caller) internal view returns (bool) {
        if (_forageGovernor == address(0) || _forageGovernor.code.length == 0) return false;
        try IForageGovernorPause(_forageGovernor).guardianModule() returns (address gm) {
            return caller == gm && gm != address(0);
        } catch {
            return false;
        }
    }

    function _isGuardianAccount(address caller) internal view returns (bool) {
        if (_forageGovernor == address(0) || _forageGovernor.code.length == 0) return false;
        try IForageGovernorPause(_forageGovernor).guardianModule() returns (address gm) {
            if (gm == address(0) || gm.code.length == 0) return false;
            uint256 pausePermission = 1;
            try IGuardianModulePermissions(gm).PERMISSION_CAN_PAUSE() returns (uint256 permission) {
                pausePermission = permission;
            } catch {}
            try IGuardianModulePermissions(gm).hasPermission(caller, pausePermission) returns (bool allowed) {
                return allowed;
            } catch {
                return false;
            }
        } catch {
            return false;
        }
    }

    // -- State-changing functions --

    function joinQueue(uint256 riskusdAmount, uint8 tier) external whenNotPaused nonReentrant {
        _joinQueue(riskusdAmount, tier, 0, 0);
    }

    function joinQueueWithBounds(uint256 riskusdAmount, uint8 tier, uint256 minimumShares, uint256 deadline)
        external
        whenNotPaused
        nonReentrant
    {
        if (minimumShares == 0) revert ZeroAmount();
        if (deadline < block.timestamp) revert InvalidQueueEntry();
        _joinQueue(riskusdAmount, tier, minimumShares, deadline);
    }

    function setQueueEntryBounds(uint256 queueId, uint256 minimumShares, uint256 deadline)
        external
        whenNotPaused
        nonReentrant
    {
        if (minimumShares == 0) revert ZeroAmount();
        if (deadline < block.timestamp) revert InvalidQueueEntry();
        QueueEntry storage entry = _queueEntries[queueId];
        if (entry.depositor == address(0)) revert InvalidQueueEntry();
        if (msg.sender != entry.depositor) revert NotQueueEntryDepositor();
        if (entry.processed) revert QueueEntryAlreadyProcessed();
        if (entry.cancelled) revert QueueEntryAlreadyCancelled();
        if (entry.priority) revert InvalidQueueEntry();
        if (_isExpired(entry)) revert InvalidQueueEntry();
        _requireNotBlocked(msg.sender);

        entry.minimumShares = minimumShares;
        entry.deadline = deadline;
        _rewindStandardHeadToEntry(entry.tier, queueId);

        emit QueueEntryBoundsUpdated(queueId, msg.sender, minimumShares, deadline);
    }

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
                (bool priceReady, uint256 price,) = _tryActiveForagePriceUsd();
                if (priceReady && price > 0) {
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

    function cancelQueue(uint256 queueId) external nonReentrant {
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

    function processQueue(uint8 tier, uint256 maxEntries) external whenNotPaused nonReentrant {
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
                if (!isPriorityLane) break;
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

    function _rewindStandardHeadToEntry(uint8 tier, uint256 queueId) internal {
        uint256 currentHead = _tierStandardHead[tier];
        uint256[] storage lane = _tierStandardQueue[tier];
        uint256 length = lane.length;
        for (uint256 i; i < currentHead && i < length;) {
            if (lane[i] == queueId) {
                _tierStandardHead[tier] = i;
                return;
            }
            unchecked {
                ++i;
            }
        }
    }

    function upgradeTier(uint8 fromTier, uint8 toTier, uint256 atriskusdAmount) external whenNotPaused nonReentrant {
        if (atriskusdAmount == 0) revert ZeroAmount();
        if (fromTier >= 4 || toTier >= 4) revert InvalidTier();
        if (toTier <= fromTier) revert InvalidTierUpgrade();
        _requireNotBlocked(msg.sender);
        _syncTierVaultsFromRegistry();

        // OF-21-063: Auto-sync cached tier vaults from VaultRegistry
        if (_vaultId != 0) {
            VaultConfig memory config = VaultRegistry(_vaultRegistry).getVault(_vaultId);
            if (
                _tierVaults[fromTier] != config.tierVaults[fromTier] || _tierVaults[toTier] != config.tierVaults[toTier]
            ) {
                _storeTierVaults(config.tierVaults);
            }
        }

        address sourceVault = _tierVaults[fromTier];
        address destVault = _tierVaults[toTier];
        uint256 combinedBackingPerShareBefore = _combinedBackingPerShareRay();

        // OF-006: Redeem from source first to get the RISKUSD amount
        (bool successRedeem, bytes memory redeemData) =
            sourceVault.call(abi.encodeWithSelector(_SEL_REDEEM_UPGRADE, msg.sender, atriskusdAmount));
        if (!successRedeem) {
            assembly {
                revert(add(redeemData, 32), mload(redeemData))
            }
        }
        if (redeemData.length < 32) revert InvalidQueueEntry();
        uint256 riskusdAmount = abi.decode(redeemData, (uint256));

        // OF-006: Check capacity before depositing to destination tier
        // Note: after redeemForUpgrade, the source vault's assets are reduced,
        // so _availableCapacity() reflects the freed-up capacity.
        if (_vaultId != 0) {
            uint256 combinedAvailable = _availableCapacity();
            uint256 tierAvailable = _availableTierDepositCapacity(toTier);
            if (riskusdAmount > combinedAvailable) revert NoCapacityAvailable();
            if (riskusdAmount > tierAvailable) {
                revert TierDepositCapExceeded(toTier, riskusdAmount, tierAvailable);
            }
        }

        // OF-M10: use forceApprove instead of bare approve
        _riskusd.forceApprove(destVault, riskusdAmount);

        (bool successDeposit, bytes memory depositData) =
            destVault.call(abi.encodeWithSelector(_SEL_DEPOSIT, riskusdAmount, msg.sender));
        if (!successDeposit) {
            assembly {
                revert(add(depositData, 32), mload(depositData))
            }
        }
        if (depositData.length < 32) revert InvalidQueueEntry();
        uint256 newAtriskusdAmount = abi.decode(depositData, (uint256));
        if (newAtriskusdAmount == 0) revert ZeroAmount();

        // OF-M10: reset allowance
        _riskusd.forceApprove(destVault, 0);

        _assertCombinedBackingPerShareNotDecreased(combinedBackingPerShareBefore);
        emit TierUpgraded(msg.sender, fromTier, toTier, atriskusdAmount, riskusdAmount, newAtriskusdAmount);
    }

    /// @notice OF-G03: Batch size is implicitly controlled by the depositors array length.
    /// Callers should limit array size to avoid out-of-gas. Off-chain keepers split large
    /// batches into multiple transactions as needed.
    function processExpiredLockups(address[] calldata depositors, uint8 tier) external whenNotPaused nonReentrant {
        if (depositors.length == 0) revert ZeroAmount();
        if (tier == 0 || tier >= 4) revert InvalidTier();
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

    /// @dev Process one depositor's expired lockup. External so it can be called via try/catch.
    /// OF-010: The try/catch in processExpiredLockups() wraps this external call. If any
    /// individual lockup processing reverts (e.g., tier vault paused, insufficient liquidity),
    /// the failure is caught, an ExpiredLockupProcessingFailed event is emitted, and remaining
    /// depositors continue processing. This prevents one bad lockup from blocking the entire batch.
    function _processOneExpiredLockup(address depositor, uint8 tier, address tierVaultAddr, address vault0Addr)
        external
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

    // -- Configuration --

    function setVaultId(uint256 vaultId_) external onlyOwner {
        if (_vaultId != 0) revert VaultIdAlreadySet();
        // OF-017: Prevent setting vault ID to zero
        if (vaultId_ == 0) revert ZeroAmount();
        _vaultId = vaultId_;
        emit VaultIdSet(vaultId_);
    }

    /// @notice OF-L10-M02: Propose the fixed FORAGE/USD price for priority lane cost calculation.
    /// @dev The proposed price becomes active only after finalizeForagePriceUsd() and FINALIZE_DELAY.
    /// price_ == 0 disables priority lane. The primary defense against trivially cheap
    /// priority is the minimum forageToLock threshold (1e15) in joinQueue, not a price floor.
    /// OF-008/CHAIN-W37: Bounded to the 6-decimal USD scale used by oracle pricing.
    function setForagePriceUsd(uint256 price_) external onlyOwner {
        _proposeForagePriceUsd(price_);
    }

    function proposeForagePriceUsd(uint256 price_) external onlyOwner {
        _proposeForagePriceUsd(price_);
    }

    function finalizeForagePriceUsd() external onlyOwner {
        if (!_pendingForagePriceUsdExists) revert NoPendingForagePriceUsd();
        _validatePendingDelay(_pendingForagePriceUsdProposedAt);
        uint256 old = _foragePriceUsd;
        _foragePriceUsd = _pendingForagePriceUsd;
        _lastPriceUpdate = block.timestamp; // OF-13-012
        _pendingForagePriceUsd = 0;
        _pendingForagePriceUsdProposedAt = 0;
        _pendingForagePriceUsdExists = false;
        emit ForagePriceUsdUpdated(old, _foragePriceUsd);
    }

    function clearPendingForagePriceUsd() external onlyOwner {
        _pendingForagePriceUsd = 0;
        _pendingForagePriceUsdProposedAt = 0;
        _pendingForagePriceUsdExists = false;
    }

    function _proposeForagePriceUsd(uint256 price_) internal {
        if (price_ > MAX_FIXED_FORAGE_PRICE_USD) revert InvalidForagePriceScale(price_);
        _pendingForagePriceUsd = price_;
        _pendingForagePriceUsdProposedAt = block.timestamp;
        _pendingForagePriceUsdExists = true;
        emit ForagePriceUsdProposed(_foragePriceUsd, price_);
    }

    function setForagePriceMode(PriceMode mode_) external onlyOwner {
        _proposeForagePriceMode(mode_);
    }

    function proposeForagePriceMode(PriceMode mode_) external onlyOwner {
        _proposeForagePriceMode(mode_);
    }

    function finalizeForagePriceMode() external onlyOwner {
        if (!_pendingForagePriceModeExists) revert NoPendingForagePriceMode();
        _validatePendingDelay(_pendingForagePriceModeProposedAt);
        PriceMode mode_ = PriceMode(_pendingForagePriceMode);
        if (mode_ == PriceMode.ORACLE && _foragePriceOracle == address(0)) revert OracleNotConfigured();
        PriceMode oldMode = PriceMode(_priceMode);
        _priceMode = uint8(mode_);
        _pendingForagePriceMode = 0;
        _pendingForagePriceModeProposedAt = 0;
        _pendingForagePriceModeExists = false;
        emit ForagePriceModeUpdated(oldMode, mode_);
    }

    function clearPendingForagePriceMode() external onlyOwner {
        _pendingForagePriceMode = 0;
        _pendingForagePriceModeProposedAt = 0;
        _pendingForagePriceModeExists = false;
    }

    function _proposeForagePriceMode(PriceMode mode_) internal {
        if (mode_ == PriceMode.ORACLE && _foragePriceOracle == address(0)) revert OracleNotConfigured();
        _pendingForagePriceMode = uint8(mode_);
        _pendingForagePriceModeProposedAt = block.timestamp;
        _pendingForagePriceModeExists = true;
        emit ForagePriceModeProposed(PriceMode(_priceMode), mode_);
    }

    function setForagePriceOracle(address oracle_, uint256 maxStaleness_) external onlyOwner {
        _proposeForagePriceOracle(oracle_, maxStaleness_);
    }

    function proposeForagePriceOracle(address oracle_, uint256 maxStaleness_) external onlyOwner {
        _proposeForagePriceOracle(oracle_, maxStaleness_);
    }

    function finalizeForagePriceOracle() external onlyOwner {
        address oracle_ = _pendingForagePriceOracle;
        if (oracle_ == address(0)) revert NoPendingForagePriceOracle();
        _validatePendingDelay(_pendingForagePriceOracleProposedAt);
        uint8 decimals_ = _validateForagePriceOracle(oracle_, _pendingOraclePriceMaxStaleness);
        address oldOracle = _foragePriceOracle;
        uint256 oldMaxStaleness = _oraclePriceMaxStaleness;
        _foragePriceOracle = oracle_;
        _oraclePriceMaxStaleness = _pendingOraclePriceMaxStaleness;
        _foragePriceOracleDecimals = decimals_;
        _pendingForagePriceOracle = address(0);
        _pendingOraclePriceMaxStaleness = 0;
        _pendingForagePriceOracleDecimals = 0;
        _pendingForagePriceOracleProposedAt = 0;
        emit ForagePriceOracleUpdated(oldOracle, oracle_, oldMaxStaleness, _oraclePriceMaxStaleness, decimals_);
    }

    function clearPendingForagePriceOracle() external onlyOwner {
        _pendingForagePriceOracle = address(0);
        _pendingOraclePriceMaxStaleness = 0;
        _pendingForagePriceOracleDecimals = 0;
        _pendingForagePriceOracleProposedAt = 0;
    }

    function _proposeForagePriceOracle(address oracle_, uint256 maxStaleness_) internal {
        uint8 decimals_ = _validateForagePriceOracle(oracle_, maxStaleness_);
        _pendingForagePriceOracle = oracle_;
        _pendingOraclePriceMaxStaleness = maxStaleness_;
        _pendingForagePriceOracleDecimals = decimals_;
        _pendingForagePriceOracleProposedAt = block.timestamp;
        emit ForagePriceOracleProposed(_foragePriceOracle, oracle_, _oraclePriceMaxStaleness, maxStaleness_, decimals_);
    }

    function _validateForagePriceOracle(address oracle_, uint256 maxStaleness_)
        internal
        view
        returns (uint8 decimals_)
    {
        if (oracle_ == address(0)) revert ZeroAddress();
        if (maxStaleness_ == 0 || maxStaleness_ > 30 days) revert InvalidOracleStaleness();
        decimals_ = IForagePriceOracle(oracle_).decimals();
        if (decimals_ > 18) revert ParameterTooLarge();
    }

    function _validatePendingDelay(uint256 proposedAt) internal view {
        if (block.timestamp < proposedAt + _finalizeDelay()) revert FinalizeDelayNotElapsed();
        if (block.timestamp > proposedAt + PROPOSAL_EXPIRY) revert ProposalExpired();
    }

    /// @notice CODEX-002: Sync cached tier vault addresses from VaultRegistry.
    /// @dev Reads authoritative addresses from VaultRegistry to prevent routing divergence.
    /// Previously accepted arbitrary addresses (OF-13-027); now validates against registry.
    function syncTierVaults() external onlyOwner {
        if (_vaultId == 0) revert VaultIdNotSet();
        VaultConfig memory config = VaultRegistry(_vaultRegistry).getVault(_vaultId);
        address[4] memory newTierVaults;
        for (uint256 i; i < 4;) {
            if (config.tierVaults[i] == address(0)) revert ZeroAddress();
            _tierVaults[i] = config.tierVaults[i];
            newTierVaults[i] = config.tierVaults[i];
            unchecked {
                ++i;
            }
        }
        emit TierVaultsSynced(newTierVaults);
    }

    /// @notice OF-008: Bounded to 1e12 to prevent overflow in priority calculation.
    function setPriorityMultiplier(uint256 multiplier_) external onlyOwner {
        if (multiplier_ > 1e12) revert ParameterTooLarge();
        uint256 old = _priorityMultiplier;
        _priorityMultiplier = multiplier_;
        emit PriorityMultiplierUpdated(old, multiplier_);
    }

    /// @notice R-9: Governance sets a per-tier deposit cap.
    /// @dev If proposedCap_ is below the current effective cap, it is applied immediately as a shrink.
    /// Widening no longer auto-ramps over time; owner/governance changes apply atomically.
    function proposeTierDepositCap(uint8 tier, uint256 proposedCap_) external onlyOwner {
        _validateTier(tier);
        uint256 vaultCap = combinedCapacity();
        _requireTierCapWithinVaultCapacity(proposedCap_, vaultCap);

        uint256 effectiveCap = _effectiveTierDepositCapForCap(tier, vaultCap);
        TierDepositCap storage cap = _tierDepositCaps[tier];
        if (proposedCap_ <= effectiveCap) {
            cap.baseCap = proposedCap_;
            cap.proposedCap = proposedCap_;
            cap.proposedAt = block.timestamp;
            cap.configured = true;
            emit TierDepositCapShrunk(tier, effectiveCap, proposedCap_, msg.sender);
            return;
        }

        cap.baseCap = effectiveCap;
        cap.proposedCap = proposedCap_;
        cap.proposedAt = block.timestamp;
        cap.configured = true;
        emit TierDepositCapProposed(tier, effectiveCap, proposedCap_, block.timestamp);
    }

    /// @notice R-9: Guardian/governance shrink-only authority for emergency tier throttling.
    /// @dev Cannot widen; guardians may only reduce the current effective cap.
    function shrinkTierDepositCap(uint8 tier, uint256 newCap_) external onlyTierCapShrinker {
        _validateTier(tier);
        uint256 vaultCap = combinedCapacity();
        _requireTierCapWithinVaultCapacity(newCap_, vaultCap);
        uint256 effectiveCap = _effectiveTierDepositCapForCap(tier, vaultCap);
        if (newCap_ > effectiveCap) revert TierDepositCapWideningNotAllowed(tier, newCap_, effectiveCap);

        TierDepositCap storage cap = _tierDepositCaps[tier];
        cap.baseCap = newCap_;
        cap.proposedCap = newCap_;
        cap.proposedAt = block.timestamp;
        cap.configured = true;

        emit TierDepositCapShrunk(tier, effectiveCap, newCap_, msg.sender);
    }

    /// @notice OF-L07: Permissionless — compaction only reorganizes arrays, no token transfers.
    /// Anyone can call to prevent priority lane DoS via systematic join+cancel.
    function compactQueue(uint8 tier, bool priority) external {
        if (tier >= 4) revert InvalidTier();

        uint256[] storage lane = priority ? _tierPriorityQueue[tier] : _tierStandardQueue[tier];
        uint256 length = lane.length;

        if (length == 0) revert EmptyQueue();

        uint256 writeIdx;
        for (uint256 i; i < length;) {
            QueueEntry storage entry = _queueEntries[lane[i]];
            if (!entry.processed && !entry.cancelled && !_isExpired(entry)) {
                lane[writeIdx] = lane[i];
                unchecked {
                    ++writeIdx;
                }
            }
            unchecked {
                ++i;
            }
        }

        uint256 removedCount = length - writeIdx;
        for (uint256 i; i < removedCount;) {
            lane.pop();
            unchecked {
                ++i;
            }
        }

        if (priority) {
            _tierPriorityHead[tier] = 0;
        } else {
            _tierStandardHead[tier] = 0;
        }

        emit QueueCompacted(tier, priority, removedCount);
    }

    /// @notice OF-L10: Admin can cancel a queue entry and return RISKUSD to a recipient
    /// @dev OF-M01/L03: nonReentrant added + CEI ordering fixed (state updates before external calls)
    function adminCancelQueue(uint256 entryId, address recipient) external onlyOwner nonReentrant {
        if (recipient == address(0)) revert ZeroAddress();
        QueueEntry storage entry = _queueEntries[entryId];
        if (entry.processed || entry.cancelled || entry.riskusdAmount == 0) revert InvalidQueueEntry();
        _requireNotBlocked(recipient);

        uint256 amount = entry.riskusdAmount;
        address depositor = entry.depositor;
        entry.cancelled = true;
        if (entry.priority) {
            _priorityRiskusdQueued[depositor] -= amount;
        }

        // OF-M01: Update state BEFORE external calls (CEI pattern)
        _totalQueuedRiskusd -= amount;

        uint256 forageToUnlock = _forageLockedPerEntry[entryId];
        if (forageToUnlock > 0) {
            // OF-007 (11th audit): Only zero entry on success to allow retry
            (bool unlockSuccess,) = _forage.call(abi.encodeWithSelector(_SEL_UNLOCK, depositor, forageToUnlock));
            if (unlockSuccess) {
                _forageLockedPerEntry[entryId] = 0;
            } else {
                emit ForageUnlockFailed(depositor, forageToUnlock);
            }
        }

        _riskusd.safeTransfer(recipient, amount);

        emit QueueEntryCancelled(entryId, depositor, recipient, amount);
    }

    /// @notice OF-16-020: Allow depositors to manually trigger their own reversion when
    /// processExpiredLockups fails. Tier 0 redeposit failures revert so the source lockup remains retryable.
    function selfRevert(uint8 tier) external whenNotPaused nonReentrant {
        if (tier == 0 || tier >= 4) revert InvalidTier();
        _requireNotBlocked(msg.sender);
        _syncTierVaultsFromRegistry();
        address tierVaultAddr = _tierVaults[tier];
        address vault0Addr = _tierVaults[0];

        (bool hasLockup, bool isExpired, bool autoRenew, bool hasPendingWithdrawal, uint256 shares) =
            _getLockupInfo(tierVaultAddr, msg.sender);
        if (!hasLockup || !isExpired || hasPendingWithdrawal || autoRenew) revert InvalidQueueEntry();

        uint256 combinedAssetsBefore = _combinedTotalAssets();
        uint256 riskusdAmount;
        {
            (bool success, bytes memory data) =
                tierVaultAddr.call(abi.encodeWithSelector(_SEL_REDEEM_REVERSION, msg.sender, shares));
            if (!success) revert RedeemForReversionFailed();
            if (data.length < 32) revert InvalidQueueEntry();
            riskusdAmount = abi.decode(data, (uint256));
        }
        if (riskusdAmount == 0) revert ZeroAmount();

        // Try deposit into tier 0; if it fails, revert to keep the source lockup retryable.
        _riskusd.forceApprove(vault0Addr, riskusdAmount);
        (bool depositSuccess, bytes memory depositData) =
            vault0Addr.call(abi.encodeWithSelector(_SEL_DEPOSIT, riskusdAmount, msg.sender));
        _riskusd.forceApprove(vault0Addr, 0);

        if (!depositSuccess) {
            revert Tier0DepositFailed();
        } else {
            if (depositData.length < 32) revert InvalidQueueEntry();
            uint256 sharesMinted = abi.decode(depositData, (uint256));
            if (sharesMinted == 0) revert ZeroAmount();
        }

        _assertCombinedAssetsNotDecreased(combinedAssetsBefore);
        emit LockupReverted(msg.sender, tier, riskusdAmount);
    }

    /// @notice OF-007 (11th audit): Retry a failed FORAGE unlock for a processed/cancelled entry.
    /// Permissionless — anyone can call since it only benefits the depositor.
    function retryForageUnlock(uint256 queueId) external nonReentrant {
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

    /// @notice OF-15-005: setForageGovernor now only proposes — no instant effect.
    /// Use finalizeForageGovernor() to complete the change after FINALIZE_DELAY.
    function setForageGovernor(address forageGovernor_) external onlyOwner {
        if (forageGovernor_ == address(0)) revert ZeroAddress();
        _pendingForageGovernor = forageGovernor_;
        _pendingForageGovernorProposedAt = block.timestamp;
        emit ForageGovernorProposed(_forageGovernor, forageGovernor_);
    }

    /// @notice OF-15-005: Finalize the pending ForageGovernor after FINALIZE_DELAY.
    function finalizeForageGovernor() external onlyOwner {
        if (_pendingForageGovernor == address(0)) revert NoPendingForageGovernor();
        if (block.timestamp < _pendingForageGovernorProposedAt + _finalizeDelay()) revert FinalizeDelayNotElapsed();
        if (block.timestamp > _pendingForageGovernorProposedAt + PROPOSAL_EXPIRY) revert ProposalExpired();
        address oldGovernor = _forageGovernor;
        _forageGovernor = _pendingForageGovernor;
        _pendingForageGovernor = address(0);
        _pendingForageGovernorProposedAt = 0;
        emit ForageGovernorSet(oldGovernor, _forageGovernor);
    }

    /// @notice OF-15-005: Clear pending ForageGovernor to prevent stale proposals.
    function clearPendingForageGovernor() external onlyOwner {
        _pendingForageGovernor = address(0);
        _pendingForageGovernorProposedAt = 0;
    }

    function setBlocklist(address blocklist_) external onlyOwner {
        if (blocklist_ == address(0)) revert ZeroAddress();
        address oldBlocklist = _blocklist;
        _blocklist = blocklist_;
        emit BlocklistSet(oldBlocklist, blocklist_);
    }

    function pause() external onlyOwnerOrGovernor {
        _pause();
    }

    function unpause() external onlyOwnerOrGovernor {
        _unpause();
    }

    function renounceOwnership() public override onlyOwner {
        revert RenounceOwnershipDisabled();
    }

    // -- View functions --

    function riskusd() external view returns (address) {
        return address(_riskusd);
    }

    function forage() external view returns (address) {
        return _forage;
    }

    function forageGovernor() external view returns (address) {
        return _forageGovernor;
    }

    function blocklist() external view returns (address) {
        return _blocklist;
    }

    function tierVault(uint8 tier) external view returns (address) {
        return _tierVaults[tier];
    }

    function vaultRegistry() external view returns (address) {
        return _vaultRegistry;
    }

    function vaultId() external view returns (uint256) {
        return _vaultId;
    }

    function combinedCapacity() public view returns (uint256) {
        if (_vaultId == 0) return 0;
        VaultConfig memory config = VaultRegistry(_vaultRegistry).getVault(_vaultId);
        return config.capacityCap;
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

    function tierStaked(uint8 tier) public view returns (uint256) {
        _validateTier(tier);
        return _tierStaked(tier);
    }

    function availableCapacity() public view returns (uint256) {
        return _availableCapacity();
    }

    function _availableCapacity() internal view returns (uint256) {
        uint256 cap = combinedCapacity();
        return _availableCapacityForCap(cap);
    }

    function _availableCapacityForCap(uint256 cap) internal view returns (uint256) {
        uint256 staked = combinedStaked();
        if (staked >= cap) return 0;
        return cap - staked;
    }

    function effectiveTierDepositCap(uint8 tier) public view returns (uint256) {
        _validateTier(tier);
        uint256 vaultCap = combinedCapacity();
        return _effectiveTierDepositCapForCap(tier, vaultCap);
    }

    function tierDepositAvailableCapacity(uint8 tier) external view returns (uint256) {
        _validateTier(tier);
        return _availableTierDepositCapacity(tier);
    }

    function totalQueuedRiskusd() external view returns (uint256) {
        return _totalQueuedRiskusd;
    }

    function foragePriceUsd() external view returns (uint256) {
        return _foragePriceUsd;
    }

    function effectiveForagePriceUsd() external view returns (uint256) {
        return _activeForagePriceUsd();
    }

    function foragePriceMode() external view returns (PriceMode) {
        return PriceMode(_priceMode);
    }

    function foragePriceOracle() external view returns (address) {
        return _foragePriceOracle;
    }

    function oraclePriceMaxStaleness() external view returns (uint256) {
        return _oraclePriceMaxStaleness;
    }

    function pendingForagePriceUsd() external view returns (bool exists, uint256 price, uint256 proposedAt) {
        return (_pendingForagePriceUsdExists, _pendingForagePriceUsd, _pendingForagePriceUsdProposedAt);
    }

    function priorityMultiplier() external view returns (uint256) {
        return _priorityMultiplier;
    }

    function priorityRiskusdQueued(address depositor) external view returns (uint256) {
        return _priorityRiskusdQueued[depositor];
    }

    function priorityCapFor(address depositor) external view returns (uint256) {
        uint256 mult = _priorityMultiplier;
        if (mult == 0) return 0;
        uint256 price = _activeForagePriceUsd();
        if (price == 0) return 0;
        (bool success, bytes memory data) = _forage.staticcall(abi.encodeWithSelector(_SEL_LOCKED_BALANCE, depositor));
        if (success && data.length >= 32) {
            uint256 lockedBal = abi.decode(data, (uint256));
            return lockedBal * price * mult / 1e18;
        }
        return 0;
    }

    function tierPriorityQueueLength(uint8 tier) external view returns (uint256) {
        return _tierPriorityQueue[tier].length;
    }

    function tierStandardQueueLength(uint8 tier) external view returns (uint256) {
        return _tierStandardQueue[tier].length;
    }

    function tierPriorityHead(uint8 tier) external view returns (uint256) {
        return _tierPriorityHead[tier];
    }

    function tierStandardHead(uint8 tier) external view returns (uint256) {
        return _tierStandardHead[tier];
    }

    function getQueueEntry(uint256 queueId) external view returns (QueueEntry memory) {
        return _queueEntries[queueId];
    }

    function nextQueueId() external view returns (uint256) {
        return _nextQueueId;
    }

    function _activeForagePriceUsd() internal view returns (uint256) {
        (bool success, uint256 price, bytes4 reason) = _tryActiveForagePriceUsd();
        if (success) return price;
        if (reason == StaleFORAGEPrice.selector) revert StaleFORAGEPrice();
        if (reason == OracleNotConfigured.selector) revert OracleNotConfigured();
        revert InvalidOraclePrice();
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
        try IForagePriceOracle(oracle).latestRoundData() returns (
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

    function _normalizeOraclePrice(uint256 price, uint8 decimals_) internal pure returns (uint256) {
        if (decimals_ == 6) return price;
        if (decimals_ > 6) return price / (10 ** (decimals_ - 6));
        return price * (10 ** (6 - decimals_));
    }

    function _validateTier(uint8 tier) internal pure {
        if (tier >= 4) revert InvalidTier();
    }

    function _tierStaked(uint8 tier) internal view returns (uint256) {
        return _readLegitimateAssets(_tierVaults[tier]);
    }

    function _readLegitimateAssets(address vaultAddr) internal view returns (uint256) {
        (bool success, bytes memory data) = vaultAddr.staticcall(abi.encodeWithSelector(_SEL_LEGITIMATE_ASSETS));
        if (!success || data.length < 32) revert CapacityProbeFailed(vaultAddr);
        return abi.decode(data, (uint256));
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

    function _combinedBackingPerShareRay() internal view returns (uint256) {
        uint256 totalBackingAssets;
        uint256 totalShares;
        for (uint256 i; i < 4;) {
            IAtRiskBackingView backingView = IAtRiskBackingView(_tierVaults[i]);
            totalBackingAssets += backingView.totalAssets() + 1;
            totalShares += backingView.totalSupply() + AT_RISK_SHARE_SCALE;
            unchecked {
                ++i;
            }
        }
        return Math.mulDiv(totalBackingAssets, RAY * AT_RISK_SHARE_SCALE, totalShares);
    }

    function _assertCombinedBackingPerShareNotDecreased(uint256 beforeRay) internal view {
        if (_combinedTotalSupply() == 0) return;
        uint256 afterRay = _combinedBackingPerShareRay();
        if (afterRay < beforeRay) revert CombinedBackingPerShareDecreased(beforeRay, afterRay);
    }

    function _assertCombinedAssetsNotDecreased(uint256 beforeAssets) internal view {
        uint256 afterAssets = _combinedTotalAssets();
        if (afterAssets < beforeAssets) revert CombinedBackingAssetsDecreased(beforeAssets, afterAssets);
    }

    function _combinedTotalAssets() internal view returns (uint256 totalAssets) {
        for (uint256 i; i < 4;) {
            totalAssets += IAtRiskBackingView(_tierVaults[i]).totalAssets();
            unchecked {
                ++i;
            }
        }
    }

    function _combinedTotalSupply() internal view returns (uint256 totalShares) {
        for (uint256 i; i < 4;) {
            totalShares += IAtRiskBackingView(_tierVaults[i]).totalSupply();
            unchecked {
                ++i;
            }
        }
    }

    function _availableTierDepositCapacity(uint8 tier) internal view returns (uint256) {
        uint256 vaultCap = combinedCapacity();
        return _availableTierDepositCapacityForCap(tier, vaultCap);
    }

    function _availableTierDepositCapacityForCap(uint8 tier, uint256 vaultCap) internal view returns (uint256) {
        uint256 tierCap = _effectiveTierDepositCapForCap(tier, vaultCap);
        uint256 staked = _tierStaked(tier);
        if (staked >= tierCap) return 0;
        return tierCap - staked;
    }

    function _effectiveTierDepositCapForCap(uint8 tier, uint256 vaultCap) internal view returns (uint256) {
        TierDepositCap storage cap = _tierDepositCaps[tier];
        if (!cap.configured) return vaultCap;

        uint256 baseCap = _min(cap.baseCap, vaultCap);
        uint256 proposedCap = _min(cap.proposedCap, vaultCap);
        baseCap;
        return proposedCap;
    }

    function _requireTierCapWithinVaultCapacity(uint256 cap, uint256 vaultCap) internal pure {
        if (cap > vaultCap) revert TierDepositCapAboveVaultCapacity(cap, vaultCap);
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

    // -- Reinitializer --
    function reinitialize(uint256 multiplier_) external reinitializer(2) onlyOwner {
        _priorityMultiplier = multiplier_;
    }

    /// @notice V3 reinitializer for active FORAGE locking.
    /// @dev No state changes needed — _forageLockedPerEntry mapping defaults to zero for all keys.
    ///      Consumes reinitializer(3) slot.
    function reinitializeV3() external reinitializer(3) onlyOwner {
        // No-op: _forageLockedPerEntry mapping defaults to zero for all keys.
    }

    /// @notice View function for per-entry FORAGE lock tracking.
    /// @dev Returns the amount of FORAGE locked on ForageToken for a given queue entry.
    function forageLockedPerEntry(uint256 queueId) external view returns (uint256) {
        return _forageLockedPerEntry[queueId];
    }

    // -- UUPS --
    /// @dev OF-15-005: Auto-clear pending ForageGovernor on upgrade to prevent stale proposals.
    function _authorizeUpgrade(address) internal override onlyOwner {
        _pendingForageGovernor = address(0);
        _pendingForageGovernorProposedAt = 0;
        _pendingForagePriceUsd = 0;
        _pendingForagePriceUsdProposedAt = 0;
        _pendingForagePriceUsdExists = false;
        _pendingForagePriceMode = 0;
        _pendingForagePriceModeProposedAt = 0;
        _pendingForagePriceModeExists = false;
        _pendingForagePriceOracle = address(0);
        _pendingOraclePriceMaxStaleness = 0;
        _pendingForagePriceOracleDecimals = 0;
        _pendingForagePriceOracleProposedAt = 0;
    }
}
