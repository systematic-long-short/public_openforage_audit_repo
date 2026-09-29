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
import "./AllowlistGatedUpgradeable.sol";
import "./interfaces/IAllowlist.sol";
import "./interfaces/IVaultRegistry.sol";
import "./interfaces/IBlocklist.sol";
import "./interfaces/ISequencerUptimeFeed.sol";

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

/// @title StakingQueue -- Dual-lane FIFO staking queue for RISKUSD deposits
contract StakingQueue is
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

    struct QueueEntryProgress {
        uint256 remainingRiskusd;
        uint256 remainingMinimumShares;
        uint256 sharesMinted;
        uint256 deadlineCeiling;
        bool initialized;
    }

    struct ForageLockSnapshot {
        uint256 entryWeight;
        uint256 pendingEntryWeight;
        uint256 totalWeight;
        uint256 pendingWeight;
        uint256 entryRequirement;
        uint256 activeRequirements;
        uint256 liveBalance;
        uint256 availableBalance;
        uint256 activeBacking;
        uint256 backing;
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
    error ForageLockAccountingMismatch(address depositor, uint256 entryWeight, uint256 obligations, uint256 liveBalance);
    error ForageLockRequirementAccountingMismatch(
        address depositor, uint256 entryRequirement, uint256 activeRequirements
    );
    error ForageLockBalanceUnavailable(address forage, address depositor);
    error DepositOutputBelowMinimum(uint256 sharesMinted, uint256 minimumShares);
    error MinimumSharesUnreachable(uint256 minimumShares, uint256 maxPreviewShares);
    error PriorityLockUnavailable();
    error InvalidForagePriceScale(uint256 price);
    error UnauthorizedLockupProcessor(address caller);
    error SequencerUptimeFeedUnavailable(address feed);
    error SequencerDown();
    error SequencerGracePeriodNotOver(uint256 startedAt, uint256 gracePeriod);
    error ModuleUnavailable();
    error TierVaultUnavailable(uint8 tier, address vault);
    error TierVaultProbeFailed(uint8 tier, address vault, bytes4 selector);
    error VaultRegistryUnavailable(address registry);

    // -- Precomputed function selectors --
    bytes4 private constant _SEL_LOCKED_BALANCE = bytes4(keccak256("lockedBalance(address)"));
    bytes4 private constant _SEL_PREVIEW_DEPOSIT = bytes4(keccak256("previewDeposit(uint256)"));
    bytes4 private constant _SEL_LEGITIMATE_ASSETS = bytes4(keccak256("legitimateAssets()"));
    bytes4 private constant _SEL_TOTAL_SUPPLY = bytes4(keccak256("totalSupply()"));
    bytes4 private constant _SEL_TOTAL_ASSETS = bytes4(keccak256("totalAssets()"));
    bytes4 private constant _SEL_LOCKER_BALANCE = bytes4(keccak256("lockerBalance(address,address)"));
    bytes4 private constant _SEL_QUEUE_FORAGE_LOCK_ACTION =
        bytes4(keccak256("_queueForageLockAction(uint8,uint256,address,uint256,uint8)"));
    bytes4 private constant _SEL_LOCK = bytes4(keccak256("lock(address,uint256)"));
    bytes4 private constant _SEL_UNLOCK = bytes4(keccak256("unlock(address,uint256)"));
    uint8 private constant _FORAGE_LOCK_ADD = 0;
    uint8 private constant _FORAGE_LOCK_REVALIDATE = 1;
    uint8 private constant _FORAGE_LOCK_REDUCE = 2;
    uint8 private constant _FORAGE_LOCK_RELEASE = 3;

    enum PriceMode {
        FIXED_PRICE,
        ORACLE
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
    event QueueModuleSet(address indexed previous, address indexed next);

    // -- Constants --
    uint256 public constant PROPOSAL_EXPIRY = 30 days; // OF-15-005
    uint256 public constant QUEUE_ENTRY_TTL = 3 days;
    uint256 public constant MAX_FIXED_FORAGE_PRICE_USD = 1_000_000e6;
    uint256 public constant ARBITRUM_ONE_CHAIN_ID = 42_161;
    uint256 public constant SEQUENCER_UPTIME_GRACE_PERIOD = 1 hours;
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

    // -- Module delegation (ERC-7201 namespaced storage) --
    /// @custom:storage-location erc7201:openforage.storage.QueueModule
    struct QueueModuleStorage {
        address module;
    }

    bytes32 private constant QUEUE_MODULE_STORAGE_LOCATION =
        keccak256(abi.encode(uint256(keccak256("openforage.storage.QueueModule")) - 1)) & ~bytes32(uint256(0xff));

    function _getQueueModuleStorage() private pure returns (QueueModuleStorage storage $) {
        bytes32 slot = QUEUE_MODULE_STORAGE_LOCATION;
        assembly {
            $.slot := slot
        }
    }

    // -- Constructor (disable initializers on implementation) --
    constructor() {
        _disableInitializers();
    }

    modifier onlyDuringConstructionBeforeInitialization() {
        if (address(this).code.length != 0 || _getInitializedVersion() != 0) revert InvalidInitialization();
        _;
    }

    // -- Initializer --
    function initialize(
        address riskusd_,
        address forage_,
        address[4] calldata tierVaults_,
        address vaultRegistry_,
        address initialOwner_
    ) external onlyDuringConstructionBeforeInitialization initializer {
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
        _forageLockAccountingInitialized = true;
        _forageLockAggregateAccountingInitialized = true;
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

    modifier onlyQueueSelfDuringGuard() {
        if (msg.sender != address(this) || !_reentrancyGuardEntered()) revert InternalOnly();
        _;
    }

    modifier onlyFreshQueue() {
        _requireForageLockAccounting();
        _;
    }

    function _requireForageLockAccounting() internal view {
        if (!_forageLockAccountingInitialized || !_forageLockAggregateAccountingInitialized) {
            revert LegacyForageLockAccountingUnsupported();
        }
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

    // -- Module delegation --

    /// @notice Points the queue at the delegatecall module that runs the moved selector cluster.
    function setQueueModule(address module_) external onlyFreshQueue onlyOwner onlyAllowedCaller {
        if (module_.code.length == 0) revert ModuleUnavailable();
        QueueModuleStorage storage $ = _getQueueModuleStorage();
        address previous = $.module;
        $.module = module_;
        emit QueueModuleSet(previous, module_);
    }

    function queueModule() external view returns (address) {
        QueueModuleStorage storage $ = _getQueueModuleStorage();
        return $.module;
    }

    function _queueForageLockAction(
        uint8 action,
        uint256 queueId,
        address depositor,
        uint256 amount,
        uint8 admissionMode
    ) external onlyFreshQueue onlyQueueSelfDuringGuard onlyAllowedCaller returns (bool) {
        if (action == _FORAGE_LOCK_ADD) return _addForageLock(queueId, depositor, amount, admissionMode);
        if (action == _FORAGE_LOCK_REVALIDATE) return _revalidatePriorityForageLock(queueId, depositor, amount);
        if (action == _FORAGE_LOCK_REDUCE) {
            _reduceForageLock(queueId, depositor, amount);
            return true;
        }
        if (action == _FORAGE_LOCK_RELEASE) {
            _releaseForageLock(queueId, depositor);
            return true;
        }
        revert InvalidQueueEntry();
    }

    function _callForageToken(bytes4 selector, address depositor, uint256 amount) private returns (bool success) {
        (success,) = _forage.call(abi.encodeWithSelector(selector, depositor, amount));
    }

    function _addForageLock(uint256 queueId, address depositor, uint256 amount, uint8 admissionMode)
        private
        returns (bool)
    {
        if (amount == 0 || _forage.code.length == 0) return false;
        ForageLockSnapshot memory state = _forageLockSnapshot(queueId, depositor);
        if (
            state.entryWeight != 0 || state.pendingEntryWeight != 0
                || (state.totalWeight != 0 && state.liveBalance == 0)
        ) return false;
        uint256 addedWeight = _additionalForageLockWeight(amount, state);
        if (addedWeight == 0) return false;
        if (!_callForageToken(_SEL_LOCK, depositor, amount)) return false;
        _setForageLockWeight(queueId, depositor, addedWeight);
        _setForageLockRequirement(queueId, depositor, amount);
        _priorityEntryAdmissionMode[queueId] = admissionMode;
        return true;
    }

    function _revalidateForageLock(uint256 queueId, address depositor, uint256 requiredLock) private returns (bool) {
        if (requiredLock == 0 || _forage.code.length == 0) return false;
        ForageLockSnapshot memory state = _forageLockSnapshot(queueId, depositor);
        uint256 requiredTotal = state.activeRequirements - state.entryRequirement + requiredLock;
        if (state.availableBalance >= requiredTotal) {
            _setForageLockRequirement(queueId, depositor, requiredLock);
            return true;
        }
        if (state.activeBacking >= requiredLock) {
            _setForageLockRequirement(queueId, depositor, requiredLock);
            return true;
        }
        return false;
    }

    function _revalidatePriorityForageLock(uint256 queueId, address depositor, uint256 remainingRiskusd)
        private
        returns (bool)
    {
        uint256 requiredLock;
        if (_priorityEntryAdmissionMode[queueId] == uint8(PriceMode.FIXED_PRICE) + 1) {
            requiredLock = _forageLockRequirementPerEntry[queueId];
        } else if (_priorityEntryAdmissionMode[queueId] == uint8(PriceMode.ORACLE) + 1) {
            (bool sequencerReady, bytes4 reason) = _trySequencerUp();
            if (!sequencerReady) _revertActiveForagePriceReason(reason);
            uint256 price = _activeForagePriceUsd();
            uint256 multiplier = _priorityMultiplier;
            if (price == 0 || multiplier == 0) return false;
            requiredLock = Math.ceilDiv(remainingRiskusd * 1e18, price * multiplier);
            if (requiredLock < 1e15) requiredLock = 1e15;
        } else {
            revert LegacyForageLockAccountingUnsupported();
        }
        if (requiredLock == 0 || _forage.code.length == 0) revert PriorityLockUnavailable();
        return _revalidateForageLock(queueId, depositor, requiredLock);
    }

    function _reduceForageLock(uint256 queueId, address depositor, uint256 lockToKeep) private {
        ForageLockSnapshot memory state = _forageLockSnapshot(queueId, depositor);
        _setForageLockRequirement(queueId, depositor, lockToKeep);
        if (state.activeBacking == 0) {
            _setForageLockWeight(queueId, depositor, 0);
            return;
        }
        if (state.activeBacking <= lockToKeep) return;
        uint256 unlockAmount = state.activeBacking - lockToKeep;
        uint256 weightToKeep = _mulDivCeil(lockToKeep, state.totalWeight, state.liveBalance);
        bool unlockSuccess;
        if (state.pendingWeight == 0 || lockToKeep == 0) {
            unlockSuccess = _callForageToken(_SEL_UNLOCK, depositor, unlockAmount);
        }
        _setForageLockWeight(queueId, depositor, weightToKeep);
        if (!unlockSuccess) {
            _setForageLockPendingWeight(queueId, depositor, state.pendingEntryWeight + state.entryWeight - weightToKeep);
            emit ForageUnlockFailed(depositor, unlockAmount);
        }
    }

    /// @dev General path for any module selector the queue does not declare.
    fallback() external {
        _requireForageLockAccounting();
        _checkAllowedCaller();
        _delegateToModule();
        assembly {
            returndatacopy(0, 0, returndatasize())
            return(0, returndatasize())
        }
    }

    /// @dev Forwarder path: returns normally on success so modifier post-actions
    /// (ReentrancyGuard's exit) run; reverts with the module's data on failure.
    function _delegateToModule() internal {
        QueueModuleStorage storage $ = _getQueueModuleStorage();
        address module = $.module;
        if (module == address(0)) revert ModuleUnavailable();
        assembly {
            calldatacopy(0, 0, calldatasize())
            let result := delegatecall(gas(), module, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            if iszero(result) { revert(0, returndatasize()) }
        }
    }

    // -- State-changing functions --

    function joinQueue(uint256 riskusdAmount, uint8 tier)
        external
        onlyFreshQueue
        onlyAllowedCaller
        whenNotPaused
        nonReentrant
    {
        _delegateToModule();
    }

    function joinQueueWithBounds(uint256 riskusdAmount, uint8 tier, uint256 minimumShares, uint256 deadline)
        external
        onlyFreshQueue
        onlyAllowedCaller
        whenNotPaused
        nonReentrant
    {
        _delegateToModule();
    }

    function setQueueEntryBounds(uint256 queueId, uint256 minimumShares, uint256 deadline)
        external
        onlyFreshQueue
        onlyAllowedCaller
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
        if (_isExpired(entry)) revert InvalidQueueEntry();
        _requireNotBlocked(msg.sender);
        _delegateToModule();
    }

    function cancelQueue(uint256 queueId) external onlyFreshQueue onlyAllowedCaller nonReentrant {
        _delegateToModule();
    }

    function processQueue(uint8 tier, uint256 maxEntries)
        external
        onlyFreshQueue
        onlyAllowedCaller
        whenNotPaused
        nonReentrant
    {
        _delegateToModule();
    }

    function _queueProgress(uint256 queueId, QueueEntry storage entry)
        internal
        view
        returns (QueueEntryProgress memory progress)
    {
        progress = _queueEntryProgress[queueId];
        if (!progress.initialized && entry.depositor != address(0)) revert LegacyForageLockAccountingUnsupported();
    }

    function _remainingQueueRiskusd(uint256 queueId, QueueEntry storage entry) internal view returns (uint256) {
        QueueEntryProgress memory progress = _queueProgress(queueId, entry);
        return progress.remainingRiskusd;
    }

    function _clearQueueEntryProgress(uint256 queueId) internal {
        QueueEntryProgress storage progress = _queueEntryProgress[queueId];
        progress.remainingRiskusd = 0;
        progress.remainingMinimumShares = 0;
        progress.initialized = true;
    }

    function upgradeTier(uint8 fromTier, uint8 toTier, uint256 atriskusdAmount)
        external
        onlyFreshQueue
        onlyAllowedCaller
        whenNotPaused
        nonReentrant
    {
        if (atriskusdAmount == 0) revert ZeroAmount();
        if (fromTier >= 4 || toTier >= 4) revert InvalidTier();
        if (toTier <= fromTier) revert InvalidTierUpgrade();
        _delegateToModule();
    }

    /// @notice OF-G03: Batch size is implicitly controlled by the depositors array length.
    /// Callers should limit array size to avoid out-of-gas. Off-chain keepers split large
    /// batches into multiple transactions as needed.
    function processExpiredLockups(address[] calldata depositors, uint8 tier)
        external
        onlyFreshQueue
        onlyAllowedCaller
        whenNotPaused
        nonReentrant
    {
        _delegateToModule();
    }

    function setExpiredLockupProcessor(address processor, bool authorized)
        external
        onlyFreshQueue
        onlyAllowedCaller
        onlyOwner
    {
        _delegateToModule();
    }

    /// @dev Process one depositor's expired lockup. External so it can be called via try/catch.
    /// OF-010: The try/catch in processExpiredLockups() wraps this external call. If any
    /// individual lockup processing reverts (e.g., tier vault paused, insufficient liquidity),
    /// the failure is caught, an ExpiredLockupProcessingFailed event is emitted, and remaining
    /// depositors continue processing. This prevents one bad lockup from blocking the entire batch.
    function _processOneExpiredLockup(address depositor, uint8 tier, address tierVaultAddr, address vault0Addr)
        external
        onlyFreshQueue
        onlyAllowedCaller
    {
        _delegateToModule();
    }

    // -- Configuration --

    function setVaultId(uint256 vaultId_) external onlyFreshQueue onlyAllowedCaller onlyOwner {
        if (_vaultId != 0) revert VaultIdAlreadySet();
        // OF-017: Prevent setting vault ID to zero
        if (vaultId_ == 0) revert ZeroAmount();
        if (_blocklist == address(0)) revert BlocklistUnavailable(_blocklist);
        _vaultId = vaultId_;
        emit VaultIdSet(vaultId_);
    }

    /// @notice OF-L10-M02: Propose the fixed FORAGE/USD price for priority lane cost calculation.
    /// @dev The proposed price becomes active only after finalizeForagePriceUsd() and FINALIZE_DELAY.
    /// price_ == 0 disables priority lane. The primary defense against trivially cheap
    /// priority is the minimum forageToLock threshold (1e15) in joinQueue, not a price floor.
    /// OF-008/CHAIN-W37: Bounded to the 6-decimal USD scale used by oracle pricing.
    function setForagePriceUsd(uint256 price_) external onlyFreshQueue onlyAllowedCaller onlyOwner {
        _proposeForagePriceUsd(price_);
    }

    function proposeForagePriceUsd(uint256 price_) external onlyFreshQueue onlyAllowedCaller onlyOwner {
        _proposeForagePriceUsd(price_);
    }

    function finalizeForagePriceUsd() external onlyFreshQueue onlyAllowedCaller onlyOwner {
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

    function clearPendingForagePriceUsd() external onlyFreshQueue onlyAllowedCaller onlyOwner {
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

    function setForagePriceMode(PriceMode mode_) external onlyFreshQueue onlyAllowedCaller onlyOwner {
        _proposeForagePriceMode(mode_);
    }

    function proposeForagePriceMode(PriceMode mode_) external onlyFreshQueue onlyAllowedCaller onlyOwner {
        _proposeForagePriceMode(mode_);
    }

    function finalizeForagePriceMode() external onlyFreshQueue onlyAllowedCaller onlyOwner {
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

    function clearPendingForagePriceMode() external onlyFreshQueue onlyAllowedCaller onlyOwner {
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

    function setForagePriceOracle(address oracle_, uint256 maxStaleness_)
        external
        onlyFreshQueue
        onlyAllowedCaller
        onlyOwner
    {
        _proposeForagePriceOracle(oracle_, maxStaleness_);
    }

    function proposeForagePriceOracle(address oracle_, uint256 maxStaleness_)
        external
        onlyFreshQueue
        onlyAllowedCaller
        onlyOwner
    {
        _proposeForagePriceOracle(oracle_, maxStaleness_);
    }

    function finalizeForagePriceOracle() external onlyFreshQueue onlyAllowedCaller onlyOwner {
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

    function clearPendingForagePriceOracle() external onlyFreshQueue onlyAllowedCaller onlyOwner {
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
    function syncTierVaults() external onlyFreshQueue onlyAllowedCaller onlyOwner {
        _delegateToModule();
    }

    /// @notice OF-008: Bounded to 1e12 to prevent overflow in priority calculation.
    function setPriorityMultiplier(uint256 multiplier_) external onlyFreshQueue onlyAllowedCaller onlyOwner {
        if (multiplier_ > 1e12) revert ParameterTooLarge();
        uint256 old = _priorityMultiplier;
        _priorityMultiplier = multiplier_;
        emit PriorityMultiplierUpdated(old, multiplier_);
    }

    /// @notice R-9: Governance sets a per-tier deposit cap.
    /// @dev If proposedCap_ is below the current effective cap, it is applied immediately as a shrink.
    /// Widening no longer auto-ramps over time; owner/governance changes apply atomically.
    function proposeTierDepositCap(uint8 tier, uint256 proposedCap_)
        external
        onlyFreshQueue
        onlyAllowedCaller
        onlyOwner
    {
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
    function shrinkTierDepositCap(uint8 tier, uint256 newCap_)
        external
        onlyFreshQueue
        onlyAllowedCaller
        onlyTierCapShrinker
    {
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

    /// @notice OF-L07: Any Allowlist-eligible caller can compact the queue.
    /// @dev Compaction only reorganizes arrays and transfers no tokens.
    function compactQueue(uint8 tier, bool priority) external onlyFreshQueue onlyAllowedCaller nonReentrant {
        if (tier >= 4) revert InvalidTier();

        uint256[] storage lane = priority ? _tierPriorityQueue[tier] : _tierStandardQueue[tier];
        uint256 length = lane.length;

        if (length == 0) revert EmptyQueue();

        uint256 writeIdx;
        for (uint256 i; i < length;) {
            QueueEntry storage entry = _queueEntries[lane[i]];
            if (
                (priority ? entry.priority : !entry.priority) && !entry.processed && !entry.cancelled
                    && !_isExpired(entry)
            ) {
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
        if (!priority) removedCount += _compactDemotedStandardHeap(tier, PRIORITY_LOOKAHEAD_SCAN_LIMIT);

        if (priority) {
            _tierPriorityHead[tier] = 0;
        } else {
            _tierStandardHead[tier] = 0;
        }
        _tierStandardScanCursor[tier] = 0;
        _tierPriorityScanCursor[tier] = 0;

        emit QueueCompacted(tier, priority, removedCount);
    }

    /// @notice OF-L10: Admin can cancel a queue entry and return RISKUSD to a recipient
    /// @dev OF-M01/L03: nonReentrant added + CEI ordering fixed (state updates before external calls)
    function adminCancelQueue(uint256 entryId, address recipient)
        external
        onlyFreshQueue
        onlyAllowedCaller
        onlyOwner
        nonReentrant
    {
        if (recipient == address(0)) revert ZeroAddress();
        QueueEntry storage entry = _queueEntries[entryId];
        if (entry.processed || entry.cancelled) revert InvalidQueueEntry();
        uint256 amount = _remainingQueueRiskusd(entryId, entry);
        if (amount == 0) revert InvalidQueueEntry();
        _requireNotBlocked(recipient);

        address depositor = entry.depositor;
        _removeDemotedStandardEntry(entry.tier, entryId);
        entry.cancelled = true;
        _clearQueueEntryProgress(entryId);
        if (entry.priority) {
            _priorityRiskusdQueued[depositor] -= amount;
        }

        // OF-M01: Update state BEFORE external calls (CEI pattern)
        _totalQueuedRiskusd -= amount;

        _releaseForageLock(entryId, depositor);

        _riskusd.safeTransfer(recipient, amount);

        emit QueueEntryCancelled(entryId, depositor, recipient, amount);
    }

    /// @notice OF-16-020: Allow depositors to manually trigger their own reversion when
    /// processExpiredLockups fails. Tier 0 redeposit failures revert so the source lockup remains retryable.
    function selfRevert(uint8 tier) external onlyFreshQueue onlyAllowedCaller whenNotPaused nonReentrant {
        if (tier == 0 || tier >= 4) revert InvalidTier();
        _delegateToModule();
    }

    /// @notice Retry a processed or cancelled entry's failed FORAGE unlock.
    /// @dev Any Allowlist-eligible caller may retry; the unlock remains credited to the depositor.
    function retryForageUnlock(uint256 queueId) external onlyFreshQueue onlyAllowedCaller nonReentrant {
        _delegateToModule();
    }

    /// @notice OF-15-005: setForageGovernor now only proposes — no instant effect.
    /// Use finalizeForageGovernor() to complete the change after FINALIZE_DELAY.
    function setForageGovernor(address forageGovernor_) external onlyFreshQueue onlyAllowedCaller onlyOwner {
        if (forageGovernor_ == address(0)) revert ZeroAddress();
        _pendingForageGovernor = forageGovernor_;
        _pendingForageGovernorProposedAt = block.timestamp;
        emit ForageGovernorProposed(_forageGovernor, forageGovernor_);
    }

    /// @notice OF-15-005: Finalize the pending ForageGovernor after FINALIZE_DELAY.
    function finalizeForageGovernor() external onlyFreshQueue onlyAllowedCaller onlyOwner {
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
    function clearPendingForageGovernor() external onlyFreshQueue onlyAllowedCaller onlyOwner {
        _pendingForageGovernor = address(0);
        _pendingForageGovernorProposedAt = 0;
    }

    function setBlocklist(address blocklist_) external onlyFreshQueue onlyAllowedCaller onlyOwner {
        if (blocklist_ == address(0)) revert ZeroAddress();
        address oldBlocklist = _blocklist;
        _blocklist = blocklist_;
        emit BlocklistSet(oldBlocklist, blocklist_);
    }

    function setSequencerUptimeFeed(address feed_) external onlyFreshQueue onlyAllowedCaller onlyOwner {
        if (feed_ == address(0)) revert ZeroAddress();
        address oldFeed = _sequencerUptimeFeed;
        _sequencerUptimeFeed = feed_;
        emit SequencerUptimeFeedSet(oldFeed, feed_);
    }

    function setAllowlist(address allowlist_) external onlyFreshQueue onlyOwner {
        _transitionAllowlist(allowlist_);
    }

    function pause() external onlyFreshQueue onlyAllowedCaller onlyOwnerOrGovernor {
        _pause();
    }

    function unpause() external onlyFreshQueue onlyAllowedCaller onlyOwnerOrGovernor {
        _unpause();
    }

    function renounceOwnership() public override onlyFreshQueue onlyAllowedCaller onlyOwner {
        revert RenounceOwnershipDisabled();
    }

    function transferOwnership(address newOwner) public override onlyFreshQueue onlyAllowedCaller {
        super.transferOwnership(newOwner);
    }

    function acceptOwnership() public override onlyFreshQueue onlyAllowedCaller {
        super.acceptOwnership();
    }

    function upgradeToAndCall(address newImplementation, bytes memory data)
        public
        payable
        override
        onlyFreshQueue
        onlyAllowedCaller
    {
        super.upgradeToAndCall(newImplementation, data);
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

    function sequencerUptimeFeed() external view returns (address) {
        return _sequencerUptimeFeed;
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
        VaultConfig memory config = _currentVaultConfig();
        _validateQueueTierSlots(config);
        uint256 total;
        for (uint8 i; i < 4; ++i) {
            address tierVaultAddress = config.tierVaults[i];
            if (tierVaultAddress != address(0)) {
                total += _readTierVaultValue(tierVaultAddress, i, _SEL_LEGITIMATE_ASSETS);
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

    function queueEntryProgress(uint256 queueId)
        external
        view
        returns (
            uint256 remainingRiskusd,
            uint256 remainingMinimumShares,
            uint256 sharesMinted,
            uint256 deadlineCeiling
        )
    {
        QueueEntryProgress memory progress = _queueProgress(queueId, _queueEntries[queueId]);
        return (
            progress.remainingRiskusd, progress.remainingMinimumShares, progress.sharesMinted, progress.deadlineCeiling
        );
    }

    function nextQueueId() external view returns (uint256) {
        return _nextQueueId;
    }

    function _activeForagePriceUsd() internal view returns (uint256) {
        (bool success, uint256 price, bytes4 reason) = _tryActiveForagePriceUsd();
        if (success) return price;
        _revertActiveForagePriceReason(reason);
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

    function _revertActiveForagePriceReason(bytes4 reason) internal view {
        if (reason == StaleFORAGEPrice.selector) revert StaleFORAGEPrice();
        if (reason == OracleNotConfigured.selector) revert OracleNotConfigured();
        if (reason == SequencerUptimeFeedUnavailable.selector) {
            revert SequencerUptimeFeedUnavailable(_sequencerUptimeFeed);
        }
        if (reason == SequencerDown.selector) revert SequencerDown();
        if (reason == SequencerGracePeriodNotOver.selector) {
            revert SequencerGracePeriodNotOver(0, SEQUENCER_UPTIME_GRACE_PERIOD);
        }
        revert InvalidOraclePrice();
    }

    function _normalizeOraclePrice(uint256 price, uint8 decimals_) internal pure returns (uint256) {
        if (decimals_ == 6) return price;
        if (decimals_ > 6) return price / (10 ** (decimals_ - 6));
        uint256 scale = 10 ** (6 - decimals_);
        if (price > MAX_FIXED_FORAGE_PRICE_USD / scale) return 0;
        return price * scale;
    }

    function _validateTier(uint8 tier) internal pure {
        if (tier >= 4) revert InvalidTier();
    }

    function _tierStaked(uint8 tier) internal view returns (uint256) {
        VaultConfig memory config = _currentVaultConfig();
        _validateQueueTierSlots(config);
        address tierVaultAddress = config.tierVaults[tier];
        if (tierVaultAddress == address(0)) return 0;
        return _readTierVaultValue(tierVaultAddress, tier, _SEL_LEGITIMATE_ASSETS);
    }

    function _readLegitimateAssets(address vaultAddr) internal view returns (uint256) {
        if (vaultAddr.code.length == 0) revert CapacityProbeFailed(vaultAddr);
        (bool success, bytes memory data) = vaultAddr.staticcall(abi.encodeWithSelector(_SEL_LEGITIMATE_ASSETS));
        if (!success || data.length != 32) revert CapacityProbeFailed(vaultAddr);
        return abi.decode(data, (uint256));
    }

    function _isExpired(QueueEntry storage entry) internal view returns (bool) {
        return entry.deadline != 0 && block.timestamp > entry.deadline;
    }

    function _combinedBackingPerShareRay() internal view returns (uint256) {
        uint256 totalBackingAssets;
        uint256 totalShares;
        VaultConfig memory config = _currentVaultConfig();
        _validateQueueTierSlots(config);
        for (uint8 i; i < 4; ++i) {
            address tierVaultAddress = config.tierVaults[i];
            if (tierVaultAddress == address(0)) continue;
            totalBackingAssets += _readTierVaultValue(tierVaultAddress, i, _SEL_TOTAL_ASSETS) + 1;
            totalShares += _readTierVaultValue(tierVaultAddress, i, _SEL_TOTAL_SUPPLY) + AT_RISK_SHARE_SCALE;
        }
        if (totalShares == 0) return 0;
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
        VaultConfig memory config = _currentVaultConfig();
        _validateQueueTierSlots(config);
        for (uint8 i; i < 4; ++i) {
            address tierVaultAddress = config.tierVaults[i];
            if (tierVaultAddress != address(0)) {
                totalAssets += _readTierVaultValue(tierVaultAddress, i, _SEL_TOTAL_ASSETS);
            }
        }
    }

    function _combinedTotalSupply() internal view returns (uint256 totalShares) {
        VaultConfig memory config = _currentVaultConfig();
        _validateQueueTierSlots(config);
        for (uint8 i; i < 4; ++i) {
            address tierVaultAddress = config.tierVaults[i];
            if (tierVaultAddress != address(0)) {
                totalShares += _readTierVaultValue(tierVaultAddress, i, _SEL_TOTAL_SUPPLY);
            }
        }
    }

    function _currentVaultConfig() internal view returns (VaultConfig memory config) {
        if (_vaultId == 0) revert VaultIdNotSet();
        address registry = _vaultRegistry;
        if (registry.code.length == 0) revert VaultRegistryUnavailable(registry);
        config = VaultRegistry(registry).getVault(_vaultId);
        if (config.vaultId == 0) revert VaultIdNotSet();
    }

    function _validateQueueTierSlots(VaultConfig memory config) internal view {
        for (uint8 i; i < 4; ++i) {
            address tierVaultAddress = config.tierVaults[i];
            if (tierVaultAddress == address(0)) {
                if (config.status != VaultStatus.WindingDown) revert TierVaultUnavailable(i, tierVaultAddress);
            } else if (tierVaultAddress.code.length == 0) {
                revert TierVaultUnavailable(i, tierVaultAddress);
            }
        }
    }

    function _readTierVaultValue(address tierVaultAddress, uint8 tier, bytes4 selector)
        internal
        view
        returns (uint256 value)
    {
        if (tierVaultAddress.code.length == 0) revert TierVaultUnavailable(tier, tierVaultAddress);
        (bool success, bytes memory data) = tierVaultAddress.staticcall(abi.encodeWithSelector(selector));
        if (!success || data.length != 32) revert TierVaultProbeFailed(tier, tierVaultAddress, selector);
        value = abi.decode(data, (uint256));
    }

    function _availableTierDepositCapacity(uint8 tier) internal view returns (uint256) {
        uint256 vaultCap = combinedCapacity();
        return _availableTierDepositCapacityForCap(tier, vaultCap);
    }

    function _availableTierDepositCapacityForCap(uint8 tier, uint256 vaultCap) internal view returns (uint256) {
        VaultConfig memory config = _currentVaultConfig();
        if (config.tierVaults[tier] == address(0)) return 0;
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
        if (blocklist_ == address(0)) revert BlocklistUnavailable(blocklist_);
        return IBlocklist(blocklist_).isBlocked(account);
    }

    function _compactDemotedStandardHeap(uint8 tier, uint256 scanLimit) internal returns (uint256 removedCount) {
        uint256[] storage heap = _demotedStandardHeap[tier];
        uint256 index;
        uint256 scanned;
        while (index < heap.length && scanned < scanLimit) {
            uint256 queueId = heap[index];
            QueueEntry storage entry = _queueEntries[queueId];
            if (entry.processed || entry.cancelled || _isExpired(entry)) {
                _removeDemotedStandardEntry(tier, queueId);
                unchecked {
                    ++removedCount;
                    ++scanned;
                }
            } else {
                unchecked {
                    ++index;
                    ++scanned;
                }
            }
        }
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

    /// @notice View function for per-entry FORAGE lock tracking.
    /// @dev Returns the amount of FORAGE locked on ForageToken for a given queue entry.
    function forageLockedPerEntry(uint256 queueId) external view returns (uint256) {
        address depositor = _queueEntries[queueId].depositor;
        if (depositor == address(0)) return 0;
        return _forageLockSnapshot(queueId, depositor).backing;
    }

    function _forageLockerBalance(address depositor) private view returns (uint256 balance) {
        (bool success, bytes memory data) =
            _forage.staticcall(abi.encodeWithSelector(_SEL_LOCKER_BALANCE, depositor, address(this)));
        if (!success || data.length != 32) revert ForageLockBalanceUnavailable(_forage, depositor);
        balance = abi.decode(data, (uint256));
    }

    function _setForageLockWeight(uint256 queueId, address depositor, uint256 newWeight) private {
        uint256 oldWeight = _forageLockedPerEntry[queueId];
        uint256 totalWeight = _forageLockWeightByDepositor[depositor];
        uint256 pendingWeight = _forageLockPendingUnlockWeightByDepositor[depositor];
        if (pendingWeight > totalWeight || oldWeight > totalWeight - pendingWeight) {
            revert ForageLockAccountingMismatch(depositor, oldWeight, totalWeight, _forageLockerBalance(depositor));
        }
        if (newWeight >= oldWeight) totalWeight += newWeight - oldWeight;
        else totalWeight -= oldWeight - newWeight;
        _forageLockedPerEntry[queueId] = newWeight;
        _forageLockWeightByDepositor[depositor] = totalWeight;
    }

    function _setForageLockPendingWeight(uint256 queueId, address depositor, uint256 newWeight) private {
        uint256 oldWeight = _forageUnlockPendingWeightPerEntry[queueId];
        uint256 pendingWeight = _forageLockPendingUnlockWeightByDepositor[depositor];
        uint256 totalWeight = _forageLockWeightByDepositor[depositor];
        if (
            pendingWeight > totalWeight || oldWeight > pendingWeight
                || _forageLockedPerEntry[queueId] > totalWeight - pendingWeight
        ) {
            revert ForageLockAccountingMismatch(depositor, oldWeight, pendingWeight, _forageLockerBalance(depositor));
        }
        if (newWeight >= oldWeight) {
            uint256 addedWeight = newWeight - oldWeight;
            pendingWeight += addedWeight;
            totalWeight += addedWeight;
        } else {
            uint256 releasedWeight = oldWeight - newWeight;
            pendingWeight -= releasedWeight;
            totalWeight -= releasedWeight;
        }
        _forageUnlockPendingWeightPerEntry[queueId] = newWeight;
        _forageLockPendingUnlockWeightByDepositor[depositor] = pendingWeight;
        _forageLockWeightByDepositor[depositor] = totalWeight;
    }

    function _setForageLockRequirement(uint256 queueId, address depositor, uint256 newRequirement) private {
        uint256 oldRequirement = _forageLockRequirementPerEntry[queueId];
        uint256 activeRequirements = _forageLockActiveRequirementByDepositor[depositor];
        if (oldRequirement > activeRequirements) {
            revert ForageLockRequirementAccountingMismatch(depositor, oldRequirement, activeRequirements);
        }
        if (newRequirement >= oldRequirement) activeRequirements += newRequirement - oldRequirement;
        else activeRequirements -= oldRequirement - newRequirement;
        _forageLockRequirementPerEntry[queueId] = newRequirement;
        _forageLockActiveRequirementByDepositor[depositor] = activeRequirements;
    }

    function _forageLockSnapshot(uint256 queueId, address depositor)
        private
        view
        returns (ForageLockSnapshot memory state)
    {
        _requireForageLockAccounting();
        state.entryWeight = _forageLockedPerEntry[queueId];
        state.pendingEntryWeight = _forageUnlockPendingWeightPerEntry[queueId];
        state.totalWeight = _forageLockWeightByDepositor[depositor];
        state.pendingWeight = _forageLockPendingUnlockWeightByDepositor[depositor];
        state.entryRequirement = _forageLockRequirementPerEntry[queueId];
        state.activeRequirements = _forageLockActiveRequirementByDepositor[depositor];
        state.liveBalance = _forageLockerBalance(depositor);
        if (
            state.pendingWeight > state.totalWeight || state.entryWeight > state.totalWeight - state.pendingWeight
                || state.pendingEntryWeight > state.pendingWeight || state.liveBalance > state.totalWeight
                || (state.totalWeight == 0 && state.liveBalance != 0)
        ) {
            revert ForageLockAccountingMismatch(depositor, state.entryWeight, state.totalWeight, state.liveBalance);
        }
        if (state.entryRequirement > state.activeRequirements) {
            revert ForageLockRequirementAccountingMismatch(depositor, state.entryRequirement, state.activeRequirements);
        }
        if (state.totalWeight != 0) {
            state.availableBalance =
                Math.mulDiv(state.totalWeight - state.pendingWeight, state.liveBalance, state.totalWeight);
            state.activeBacking = Math.mulDiv(state.entryWeight, state.liveBalance, state.totalWeight);
            uint256 entryWeight = state.entryWeight + state.pendingEntryWeight;
            state.backing = Math.mulDiv(entryWeight, state.liveBalance, state.totalWeight);
        }
    }

    function _additionalForageLockWeight(uint256 amount, ForageLockSnapshot memory state)
        private
        pure
        returns (uint256 weight)
    {
        uint256 totalWeight = state.totalWeight;
        uint256 liveBalance = state.liveBalance;
        if (totalWeight == 0) return amount;
        if (liveBalance == 0) return 0;
        uint256 quotientHigh;
        assembly {
            let mm := mulmod(amount, totalWeight, not(0))
            let productLow := mul(amount, totalWeight)
            quotientHigh := sub(sub(mm, productLow), lt(mm, productLow))
        }
        if (quotientHigh >= liveBalance) return 0;
        uint256 remainder = mulmod(amount, totalWeight, liveBalance);
        weight = Math.mulDiv(amount, totalWeight, liveBalance);
        if (remainder != 0) {
            if (state.pendingWeight != 0 || weight == type(uint256).max) return 0;
            unchecked {
                ++weight;
            }
        }
        if (weight > type(uint256).max - totalWeight) return 0;
    }

    function _mulDivCeil(uint256 amount, uint256 numerator, uint256 denominator)
        private
        pure
        returns (uint256 result)
    {
        result = Math.mulDiv(amount, numerator, denominator);
        if (mulmod(amount, numerator, denominator) != 0) ++result;
    }

    function _releaseForageLock(uint256 queueId, address depositor) private {
        uint256 requirement = _forageLockRequirementPerEntry[queueId];
        _setForageLockRequirement(queueId, depositor, 0);
        uint256 weight = _forageLockedPerEntry[queueId];
        uint256 pendingWeight = _forageUnlockPendingWeightPerEntry[queueId];
        if (weight == 0 && pendingWeight == 0) {
            if (requirement != 0 && _forage.code.length == 0) {
                emit ForageUnlockFailed(depositor, requirement);
            }
            return;
        }
        if (_forage.code.length == 0) {
            _setForageLockWeight(queueId, depositor, 0);
            _setForageLockPendingWeight(queueId, depositor, pendingWeight + weight);
            emit ForageUnlockFailed(depositor, requirement);
            return;
        }
        ForageLockSnapshot memory state = _forageLockSnapshot(queueId, depositor);
        uint256 backing = state.backing;
        if (backing == 0) {
            _setForageLockWeight(queueId, depositor, 0);
            _setForageLockPendingWeight(queueId, depositor, 0);
            return;
        }
        bool unlockSuccess = _callForageToken(_SEL_UNLOCK, depositor, backing);
        if (unlockSuccess) {
            _setForageLockWeight(queueId, depositor, 0);
            _setForageLockPendingWeight(queueId, depositor, 0);
        } else {
            _setForageLockWeight(queueId, depositor, 0);
            _setForageLockPendingWeight(queueId, depositor, state.pendingEntryWeight + state.entryWeight);
            emit ForageUnlockFailed(depositor, backing);
        }
    }

    // -- UUPS --
    /// @dev OF-15-005: Auto-clear pending ForageGovernor on upgrade to prevent stale proposals.
    function _authorizeUpgrade(address) internal override onlyOwner {
        _requireForageLockAccounting();
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
