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
import "./interfaces/IVaultRegistry.sol";
import "./IForageGovernorPause.sol";
import "./FinalizeDelayProfile.sol";
import "./interfaces/IBlocklist.sol";
import "./interfaces/IAllowlist.sol";
import "./AllowlistGatedUpgradeable.sol";

interface IRISKUSD is IERC20 {
    function mint(address to, uint256 amount) external;
    function burn(address from, uint256 amount) external;
}

interface IVaultRegistryWiringQuery {
    function riskusdVault() external view returns (address);
    function pendingRISKUSDVault() external view returns (address);
}

interface IERC4626TotalAssets {
    function totalAssets() external view returns (uint256);
}

interface IManualCustodianNAVNormalizer {
    function normalizeManualCustodianNAV(uint256 vaultId, uint256 nav, uint256 lossNonce)
        external
        view
        returns (bool shouldRecord, uint256 normalizedNav);
}

library RISKUSDVaultRedemptionBufferStorage {
    struct Layout {
        uint256 weeklyWindowStart;
        uint256 weeklyMintAmount;
        uint256 dailyWindowStart;
        uint256 dailyMintAmount;
    }

    bytes32 private constant STORAGE_SLOT = keccak256(
        abi.encode(uint256(keccak256("openforage.storage.RISKUSDVaultRedemptionBuffer")) - 1)
    ) & ~bytes32(uint256(0xff));

    function layout() internal pure returns (Layout storage $) {
        bytes32 slot = STORAGE_SLOT;
        assembly ("memory-safe") {
            $.slot := slot
        }
    }
}

/// @title RISKUSDVault - Central USDC pool for RISKUSD deposits and redemptions
/// @notice Manages 1:1 USDC/RISKUSD deposits, redemptions with weekly cap,
///         custodian capital deployment, and loss operations.
contract RISKUSDVault is
    Initializable,
    Ownable2StepUpgradeable,
    PausableUpgradeable,
    ReentrancyGuard,
    UUPSUpgradeable,
    FinalizeDelayProfile,
    AllowlistGatedUpgradeable
{
    using SafeERC20 for IERC20;

    // Custom errors
    error ZeroAddress();
    error ZeroAmount();
    error UnauthorizedCustodian();
    error UnauthorizedLossReporter();
    error UnauthorizedPauseControl(address caller);
    error WeeklyRedemptionCapExceeded();
    error InsufficientVaultBalance();
    error ReserveRatioViolated();
    error DeploymentRatioExceeded();
    error ExcessiveReturn();
    error ExcessiveLossAcknowledgment();
    error InvalidDeploymentRatio();
    error InvalidParameter();
    error InvalidReserveRatio();
    error InvalidVaultId();
    error RenounceOwnershipDisabled();
    error LossNotAcknowledged();
    error NotPendingCustodian();
    error NotPendingLossReporter();
    error LossPending(); // OF-001 (11th audit)
    error NoAcknowledgedLoss(); // OF-NEW-02 (12th audit)
    error VaultWindingDown(); // OF-13-009 (13th audit)
    error FinalizeDelayNotElapsed(); // OF-002 (11th audit)
    error ProposalExpired(); // OF-002 (11th audit)
    error VaultNotActive(); // OF-14-001: vault status != Active
    error VaultIdMismatch(); // OF-14-001: burnForLoss vaultId != _lossPendingVaultId
    error NoPendingVaultRegistry(); // OF-15-004
    error NotPendingVaultRegistry(); // OF-15-004
    error NoPendingForageGovernor(); // OF-15-005
    error NoPendingManualAttestationReporter();
    error NotPendingManualAttestationReporter();
    error InvalidState(); // Pending setter/state transition guard
    error RISKUSDVaultMismatch();
    error WeeklyMintCapExceeded();
    error DailyMintCapExceeded();
    error DailyRedemptionCapExceeded();
    error PerBlockMintCapExceeded(uint256 provided, uint256 cap);
    error DeploymentBufferExceeded();
    error SolvencyInvariantViolated(uint256 backingAssets, uint256 riskusdSupply);
    error InvalidAttestationInterval();
    error VaultRegistryRequired();
    error UnauthorizedCapTightener(address caller);
    error CapTighteningOnly();
    error BackingMarginDecreased(
        uint256 backingAssetsBefore, uint256 riskusdSupplyBefore, uint256 backingAssetsAfter, uint256 riskusdSupplyAfter
    );
    error RescueDelayNotElapsed(uint256 readyAt);
    error BlockedAddress(address account);
    error UnauthorizedManualAttestationReporter();
    error StaleLossNonce();
    error LossNonceMismatch();
    error LossAmountMismatch();
    error InvalidBlocklist(address target);
    error InvalidVaultRegistryInterface(address target);
    error ManualAttestationNormalizationFailed(address custodian);
    error LossResolutionNotificationFailed(address registry);
    error DeploymentBufferEnumerationFailed(address target);
    error FirstDepositBelowMinimum(uint256 amount, uint256 minimum);
    error ModuleUnavailable();
    error CustodianLossWriteDownFailed(address custodian, uint256 amount);

    // Events
    event Deposited(address indexed depositor, uint256 usdcAmount);
    event Redeemed(address indexed redeemer, uint256 riskusdAmount);
    event CapitalDeployed(address indexed custodian, uint256 usdcAmount, uint256 totalDeployed);
    event CapitalReturned(address indexed custodian, uint256 usdcAmount, uint256 totalDeployed);
    event CustodianUpdated(address indexed oldCustodian, address indexed newCustodian);
    event MaxDeploymentRatioUpdated(uint256 oldRatio, uint256 newRatio);
    event WeeklyRedemptionCapBpsUpdated(uint256 oldBps, uint256 newBps);
    event MinReserveRatioUpdated(uint256 oldRatio, uint256 newRatio);
    event ForageGovernorSet(address indexed oldGovernor, address indexed newGovernor);
    event LossBurned(uint256 riskusdAmount);
    event Replenished(uint256 usdcAmount);
    event LossCoverDeposited(uint256 usdcAmount);
    event LossAcknowledged(uint256 amount);
    event LossReporterUpdated(address indexed oldReporter, address indexed newReporter);
    event CustodianProposed(address indexed currentCustodian, address indexed pendingCustodian);
    event CustodianSetByOwner(address indexed currentCustodian, address indexed pendingCustodian); // OF-13-025/052
    event LossReporterProposed(address indexed currentReporter, address indexed pendingReporter);
    event LossReporterSetByOwner(address indexed currentReporter, address indexed pendingReporter); // OF-13-025/052
    event AcknowledgedLossCancelled(uint256 amount); // OF-NEW-02 (12th audit)
    event VaultWindingDownSet(bool windingDown); // OF-13-009 (13th audit)
    event VaultRegistryProposed(address indexed current, address indexed pending); // OF-15-004
    event VaultRegistryUpdated(address indexed oldRegistry, address indexed newRegistry); // OF-15-004
    event ForageGovernorProposed(address indexed current, address indexed pending); // OF-15-005
    event LossPrepareCancelled(uint256 indexed vaultId); // OF-17-002
    event WeeklyMintCapBpsUpdated(uint256 oldBps, uint256 newBps);
    event DailyMintCapBpsUpdated(uint256 oldBps, uint256 newBps);
    event DailyRedemptionCapBpsUpdated(uint256 oldBps, uint256 newBps);
    event PerBlockMintCapUpdated(uint256 oldBps, uint256 newBps, uint256 oldMax, uint256 newMax);
    event DeploymentBufferBpsUpdated(uint256 oldBps, uint256 newBps);
    event AttestationIntervalUpdated(uint256 oldInterval, uint256 newInterval);
    event CustodianNAVRecorded(uint256 nav, uint256 timestamp);
    event CustodianNAVAttested(uint256 indexed vaultId, uint256 nav, uint256 indexed lossNonce, uint256 timestamp);
    event ManualCustodianNAVDeferred(
        uint256 indexed vaultId, uint256 nav, uint256 indexed lossNonce, address indexed custodian
    );
    event AttestedLossFinalized(uint256 indexed vaultId, uint256 indexed lossNonce, uint256 amount);
    event ManualAttestationReporterProposed(address indexed currentReporter, address indexed pendingReporter);
    event ManualAttestationReporterUpdated(address indexed oldReporter, address indexed newReporter);
    event SolvencyInvariantFailure(uint256 vaultUsdc, uint256 bookValue, uint256 adjustedNav, uint256 supply);
    event TokenRescueProposed(address indexed token, uint256 amount, address indexed recipient, uint256 readyAt);
    event TokenRescued(address indexed token, uint256 amount, address indexed recipient);
    event BlocklistSet(address indexed oldBlocklist, address indexed newBlocklist);
    event SuspectedLossFreezeSet(bool frozen);
    event VaultModuleSet(address indexed previous, address indexed next);

    struct PendingTokenRescue {
        uint256 amount;
        uint256 readyAt;
        address recipient;
    }

    // Constants
    uint256 public constant PROPOSAL_EXPIRY = 30 days; // OF-002 (11th audit)
    uint256 public constant WEEKLY_WINDOW = 7 days;
    uint256 public constant DAILY_WINDOW = 1 days;
    uint256 public constant TOKEN_RESCUE_DELAY = 1 days;
    uint256 internal constant DEPLOYMENT_BUFFER_SCAN_LIMIT = 64;
    bytes4 internal constant GET_ACTIVE_VAULTS_PAGE_SELECTOR = bytes4(keccak256("getActiveVaultsPage(uint256,uint256)"));

    // State — immutable post-initialization
    IERC20 internal _usdc;
    IRISKUSD internal _riskusd;

    // State — mutable
    address internal _custodian;
    address internal _lossReporter;
    address internal _forageGovernor;
    uint256 internal _maxDeploymentRatioBps;
    uint256 internal _weeklyRedemptionCapBps;
    uint256 internal _minReserveRatioBps;
    uint256 internal _weeklyRedemptionUsed;
    uint256 internal _weeklyRedemptionWindowStart;
    uint256 internal _totalDeposited;
    uint256 internal _totalRedeemed;
    uint256 internal _totalDeployed;
    uint256 internal _totalBurnedForLoss;
    uint256 internal _totalReplenished;
    uint256 internal _totalLostCapital;
    uint256 internal _windowStartSupply;
    uint256 internal _lastActiveSupply;
    /// @dev Preserved accounting slot for pre-target acknowledged loss state; target losses settle by nonce.
    uint256 internal _totalAcknowledgedLoss;

    /// @dev OF-H02: Pending addresses for two-step critical setter handoff
    address internal _pendingCustodian;
    address internal _pendingLossReporter;
    /// @dev OF-001 (11th audit): Packs with _pendingLossReporter (20 + 1 = 21 bytes, same slot)
    bool internal _lossPending;
    /// @dev OF-13-009 (13th audit): Packs with _pendingLossReporter + _lossPending (20 + 1 + 1 = 22 bytes, same slot)
    bool internal _vaultWindingDown;

    /// @dev OF-002 (11th audit): Proposal timestamps for finalize delay enforcement
    uint256 internal _custodianProposedAt;
    uint256 internal _lossReporterProposedAt;

    /// @dev VaultRegistry reference for status and wind-down cooldown notifications.
    /// Set at initialization/update time via governance-owned two-step flow.
    /// INVARIANT: Must point to the canonical VaultRegistry used by target treasury and custodian accounting.
    IVaultRegistry internal _vaultRegistry;
    /// @dev Preserved pending-loss vault binding for pre-target state; target losses use attested nonces.
    uint256 internal _lossPendingVaultId;

    /// @dev OF-15-004: Pending VaultRegistry address for two-step setter.
    /// Packed: address (20 bytes) + uint48 timestamp (6 bytes) = 26 bytes → 1 slot.
    address internal _pendingVaultRegistry;
    uint48 internal _pendingVaultRegistryTimestamp;

    /// @dev OF-15-005: Pending ForageGovernor for two-step setter
    address internal _pendingForageGovernor;
    uint256 internal _pendingForageGovernorProposedAt;

    /// @dev R-28: rolling 7-day mint growth cap. Default 2x start-window supply.
    uint256 internal _weeklyMintCapBps;
    uint256 internal _weeklyMintUsed;
    uint256 internal _weeklyMintWindowStart;
    uint256 internal _weeklyMintWindowStartSupply;
    uint256 internal _lastMintActiveSupply;
    uint256 internal _dailyMintCapBps;
    uint256 internal _dailyMintUsed;
    uint256 internal _dailyMintWindowStart;
    uint256 internal _dailyMintWindowStartSupply;
    uint256 internal _lastDailyMintActiveSupply;
    uint256 internal _dailyRedemptionCapBps;
    uint256 internal _dailyRedemptionUsed;
    uint256 internal _dailyRedemptionWindowStart;
    uint256 internal _dailyRedemptionWindowStartSupply;
    uint256 internal _perBlockMintCapBps;
    uint256 internal _perBlockMintCapMax;
    uint256 internal _mintUsedThisBlock;
    uint256 internal _mintUsedBlockNumber;

    /// @dev R-31: cross-vault deployment buffer across active registry vaults.
    uint256 internal _deploymentBufferBps;

    /// @dev R-20/R-34: custodian NAV used by the crown solvency invariant.
    uint256 internal _lastAttestedNAV;
    uint256 internal _lastAttestationTimestamp;
    uint256 internal _attestationIntervalSeconds;
    uint256 internal _deployedSinceLastAttestation;
    uint256 internal _returnedSinceLastAttestation;

    mapping(address => PendingTokenRescue) internal _pendingTokenRescues;
    address internal _blocklist;
    address internal _manualAttestationReporter;
    address internal _pendingManualAttestationReporter;
    uint256 internal _manualAttestationReporterProposedAt;
    uint256 internal _latestLossNonce;
    uint256 internal _settledLossNonce;
    uint256 internal _latestLossVaultId;
    uint256 internal _latestLossAmount;
    uint256 internal _lastLossResolutionBlock;
    bool internal _suspectedLossFreeze;

    /// @dev KYC-03: basis-keyed minimum first deposit and the per-wallet first-deposit flag (two appended slots).
    mapping(uint8 => uint256) private _minimumFirstDeposit;
    mapping(address => bool) private _depositedOnce;

    /// @dev Reserved storage gap (39 - 32 appended slots - 1 rescue mapping - 1 blocklist - 1 freeze slot - 2 KYC slots = 2)
    uint256[2] private __gap;

    // --- Module storage (ERC-7201) ---

    /// @custom:storage-location erc7201:openforage.storage.VaultModule
    struct VaultModuleStorage {
        address module;
    }

    bytes32 private constant VAULT_MODULE_STORAGE_LOCATION =
        keccak256(abi.encode(uint256(keccak256("openforage.storage.VaultModule")) - 1)) & ~bytes32(uint256(0xff));

    function _getVaultModuleStorage() private pure returns (VaultModuleStorage storage $) {
        bytes32 slot = VAULT_MODULE_STORAGE_LOCATION;
        assembly {
            $.slot := slot
        }
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address usdc_, address riskusd_, address initialOwner_) external initializer {
        _initializeCore(usdc_, riskusd_, initialOwner_);
    }

    /// @notice Fresh-deploy target initializer that sets the genesis custodian and loss reporter.
    /// @dev Subsequent custodian / loss-reporter changes still use the delayed two-step paths.
    function initializeTarget(
        address usdc_,
        address riskusd_,
        address initialOwner_,
        address initialCustodian_,
        address initialLossReporter_
    ) external initializer {
        if (initialCustodian_ == address(0) || initialLossReporter_ == address(0)) {
            revert ZeroAddress();
        }
        _initializeCore(usdc_, riskusd_, initialOwner_);
        _custodian = initialCustodian_;
        _lossReporter = initialLossReporter_;
        emit CustodianUpdated(address(0), initialCustodian_);
        emit LossReporterUpdated(address(0), initialLossReporter_);
    }

    function _initializeCore(address usdc_, address riskusd_, address initialOwner_) internal {
        if (usdc_ == address(0)) revert ZeroAddress();
        if (riskusd_ == address(0)) revert ZeroAddress();
        if (initialOwner_ == address(0)) revert ZeroAddress();

        __Ownable_init(initialOwner_);
        __Ownable2Step_init();
        __Pausable_init();

        _usdc = IERC20(usdc_);
        _riskusd = IRISKUSD(riskusd_);
        _weeklyRedemptionCapBps = 500; // R-31/F2: 5% launch default
        _maxDeploymentRatioBps = 9500; // R-31/F2: 95% launch default
        _weeklyMintCapBps = 20000; // R-28: max 2x start-window supply per 7 days
        _dailyMintCapBps = 2000; // Human review 2026-04-28: max 20% start-window supply per day
        _dailyRedemptionCapBps = 200; // Target default: max 2% start-window supply per day
        _perBlockMintCapBps = 2000; // Human review 2026-04-28: max 20% of supply per block
        _perBlockMintCapMax = 10_000_000e6; // R-8: absolute $10M cap
        _deploymentBufferBps = 500; // R-31/I-14: retain 5% across active tier vault assets
        _attestationIntervalSeconds = 1 days;
        _weeklyRedemptionWindowStart = block.timestamp;
        _weeklyMintWindowStart = block.timestamp;
        _dailyMintWindowStart = block.timestamp;
        _dailyRedemptionWindowStart = block.timestamp;
        // _minReserveRatioBps defaults to 0
        // _custodian and _lossReporter default to address(0) unless a genesis initializer sets them.
    }

    function deposit(uint256 usdcAmount) external onlyAllowedCaller whenNotPaused nonReentrant {
        if (usdcAmount == 0) revert ZeroAmount();
        _requirePublicAccountingRegistry();
        // OF-13-056: Block fresh user deposits during loss-pending window.
        // Exempt _lossReporter for protocol-controlled loss/yield accounting that must remain live.
        if (_lossPendingActive() && msg.sender != _lossReporter) revert LossPending();
        _requireNotBlocked(msg.sender);
        // KYC-03: a basis-2 wallet's first deposit must clear the configured minimum before any USDC moves.
        uint8 basis = IAllowlist(allowlist()).basisOf(msg.sender);
        if (basis == 2 && !_depositedOnce[msg.sender] && usdcAmount < _minimumFirstDeposit[2]) {
            revert FirstDepositBelowMinimum(usdcAmount, _minimumFirstDeposit[2]);
        }
        uint256 backingAssetsBefore = solvencyBackingAssets();
        uint256 riskusdSupplyBefore = _riskusd.totalSupply();

        // Update state before external calls (CEI). Public deposits are throttled;
        // Protocol accounting uses the lossReporter role and must remain live.
        bool mintCapExempt = msg.sender == _lossReporter;
        if (!mintCapExempt) {
            _enforcePerBlockMintCap(usdcAmount);
            _enforceDailyMintCap(usdcAmount);
            _enforceWeeklyMintCap(usdcAmount);
            _recordPublicRedemptionMint(usdcAmount);
        }
        _totalDeposited += usdcAmount;

        // Pull USDC from depositor
        _usdc.safeTransferFrom(msg.sender, address(this), usdcAmount);

        // Mint RISKUSD 1:1
        _riskusd.mint(msg.sender, usdcAmount);

        _assertBackingMarginNotDecreased(backingAssetsBefore, riskusdSupplyBefore);
        if (basis == 2) _depositedOnce[msg.sender] = true;
        emit Deposited(msg.sender, usdcAmount);
        _assertSolvency();
    }

    function redeem(uint256 riskusdAmount) external onlyAllowedCaller whenNotPaused nonReentrant {
        if (riskusdAmount == 0) revert ZeroAmount();
        _requirePublicAccountingRegistry();
        // OF-NEW-01 (12th audit): Block redemptions while loss is pending
        if (_lossPendingActive()) revert LossPending();
        _requireNotBlocked(msg.sender);
        uint256 backingAssetsBefore = solvencyBackingAssets();
        uint256 riskusdSupplyBefore = _riskusd.totalSupply();

        uint256 weeklyCapCharge = _consumeWeeklyRedemptionMint(riskusdAmount);
        uint256 dailyCapCharge = _consumeDailyRedemptionMint(riskusdAmount);
        _enforceWeeklyCap(weeklyCapCharge);
        _enforceDailyRedemptionCap(dailyCapCharge);

        // Vault liquidity check
        uint256 balance = vaultUsdcBalance();
        if (balance < riskusdAmount) revert InsufficientVaultBalance();

        // Reserve ratio enforcement
        _enforceReserveRatio(riskusdAmount);

        // Update state before external calls (CEI)
        _totalRedeemed += riskusdAmount;
        _weeklyRedemptionUsed += weeklyCapCharge;
        _dailyRedemptionUsed += dailyCapCharge;

        // Pull RISKUSD from redeemer and burn
        IERC20(address(_riskusd)).safeTransferFrom(msg.sender, address(this), riskusdAmount);
        _riskusd.burn(address(this), riskusdAmount);
        _reduceMintActiveSupply(riskusdAmount);
        if (_publicRedemptionNettingEnabled()) {
            uint256 supplyAfterRedeem = _riskusd.totalSupply();
            if (_lastActiveSupply == 0 || supplyAfterRedeem < _lastActiveSupply) {
                _lastActiveSupply = supplyAfterRedeem;
            }
        }

        // Send USDC 1:1
        _usdc.safeTransfer(msg.sender, riskusdAmount);

        _assertBackingMarginNotDecreased(backingAssetsBefore, riskusdSupplyBefore);
        emit Redeemed(msg.sender, riskusdAmount);
        _assertSolvency();
    }

    // --- Custodian Operations ---

    function deployCapital(uint256 usdcAmount) external onlyAllowedCaller whenNotPaused nonReentrant {
        _delegateToModule();
    }

    function returnCapital(uint256 usdcAmount) external onlyAllowedCaller nonReentrant {
        if (msg.sender != _custodian) revert UnauthorizedCustodian();
        if (_custodian == address(0)) revert UnauthorizedCustodian();
        _returnCapital(usdcAmount, true);
    }

    function returnCapitalWithNAVBasis(uint256 usdcAmount, bool navAlreadyReduced)
        external
        onlyAllowedCaller
        nonReentrant
    {
        if (msg.sender != _custodian) revert UnauthorizedCustodian();
        if (_custodian == address(0)) revert UnauthorizedCustodian();
        _returnCapital(usdcAmount, !navAlreadyReduced);
    }

    function _returnCapital(uint256 usdcAmount, bool countReturnedSinceLastAttestation) internal {
        if (usdcAmount == 0) revert ZeroAmount();
        if (usdcAmount > _totalDeployed) revert ExcessiveReturn();
        _requireNotBlocked(msg.sender);

        // Update state (CEI)
        _totalDeployed -= usdcAmount;
        if (countReturnedSinceLastAttestation) {
            _returnedSinceLastAttestation += usdcAmount;
        }

        // Pull USDC from custodian
        _usdc.safeTransferFrom(msg.sender, address(this), usdcAmount);

        emit CapitalReturned(_custodian, usdcAmount, _totalDeployed);
    }

    /// @notice Records the latest custodian NAV attestation for runtime solvency checks.
    /// @dev Called by the custodian bridge after validating the cross-chain attestation.
    function recordCustodianNAV(uint256 nav) external onlyAllowedCaller {
        _delegateToModule();
    }

    /// @notice Records the latest custodian NAV attestation and nonce for loss settlement.
    /// @dev The custodian bridge calls this after validating the off-chain NAV attestation.
    /// It does not mutate loss accounting or create a sticky lock; lossPending() is derived.
    function recordCustodianNAV(uint256 vaultId, uint256 nav, uint256 lossNonce) external onlyAllowedCaller {
        _delegateToModule();
    }

    /// @notice Records the latest custodian NAV attestation using the source observation timestamp.
    /// @dev Custodian bridges use this overload so freshness reflects data age, not submission age.
    function recordCustodianNAV(uint256 vaultId, uint256 nav, uint256 lossNonce, uint256 observedAt)
        external
        onlyAllowedCaller
    {
        _delegateToModule();
    }

    /// @notice Governance-configured manual attestation path for emergency custodian fallback.
    /// @dev The reporter is set via two-stage owner/governance handoff. Manual attestations
    /// enter the same nonce-bound settlement path as custodian bridge attestations.
    function recordManualCustodianNAV(uint256 vaultId, uint256 nav, uint256 lossNonce) external onlyAllowedCaller {
        _delegateToModule();
    }

    // --- Loss Operations ---

    /// @notice OF-L12: burnForLoss intentionally operates during pause.
    /// Loss accounting must proceed regardless of pause state to maintain solvency invariants.
    /// The RISKUSD.burn() call is minter-only and bypasses pause per OF-M06.
    /// @dev Verifies target attested-loss nonce binding when a nonce-bound loss is open.
    function burnForLoss(uint256 vaultId, uint256 riskusdAmount) external onlyAllowedCaller nonReentrant {
        _delegateToModule();
    }

    function coverAndBurnForLoss(uint256 vaultId, uint256 riskusdAmount, uint256 coverUsdcAmount)
        external
        onlyAllowedCaller
        nonReentrant
    {
        _delegateToModule();
    }

    function replenish(uint256 usdcAmount) external onlyAllowedCaller nonReentrant {
        _delegateToModule();
    }

    /// @notice Finalizes an attested loss nonce after the loss reporter has fully absorbed it.
    /// @dev Called by the custodian bridge in the same transaction after reportLoss(). If this
    /// reverts, the entire cross-contract settlement reverts atomically.
    function finalizeAttestedLoss(uint256 vaultId, uint256 lossNonce, uint256 amount) external onlyAllowedCaller {
        _delegateToModule();
    }

    // --- Admin Setters ---

    // ── VaultRegistry Wiring (OF-15-004 + CODEX-001) ──

    /// @notice OF-15-004: Wire _vaultRegistry on deployed proxies. Called once after UUPS upgrade.
    /// @dev CODEX-R1: onlyOwner prevents front-running if upgrade and init are not atomic.
    function initializeV2(address vaultRegistry_) external onlyAllowedCaller onlyOwner reinitializer(2) {
        _delegateToModule();
    }

    /// @notice OF-15-004: Propose a new VaultRegistry address. Takes effect after FINALIZE_DELAY.
    function proposeVaultRegistry(address newRegistry_) external onlyAllowedCaller onlyOwner {
        _delegateToModule();
    }

    /// @notice OF-15-004: Finalize the proposed VaultRegistry after FINALIZE_DELAY.
    function finalizeVaultRegistry() external onlyAllowedCaller onlyOwner {
        _delegateToModule();
    }

    /// @notice OF-15-004: Accept the pending VaultRegistry role. Only the pending registry can call.
    function acceptVaultRegistry() external onlyAllowedCaller {
        _delegateToModule();
    }

    /// @notice OF-15-004: Clear a pending VaultRegistry proposal without finalizing.
    function clearPendingVaultRegistry() external onlyAllowedCaller onlyOwner {
        _delegateToModule();
    }

    /// @notice OF-H02: setCustodian now only proposes — no instant effect.
    /// Use finalizeCustodian() or acceptCustodian() to complete the change.
    /// @dev OF-13-025/052: Emits CustodianSetByOwner (distinct from CustodianProposed via proposeCustodian).
    function setCustodian(address custodian_) external onlyAllowedCaller onlyOwner {
        _delegateToModule();
    }

    /// @notice OF-H02: Owner-side finalization for custodian change (for contract recipients).
    function finalizeCustodian() external onlyAllowedCaller onlyOwner {
        _delegateToModule();
    }

    /// @notice OF-H02: setLossReporter now only proposes — no instant effect.
    /// Use finalizeLossReporter() or acceptLossReporter() to complete the change.
    /// @dev OF-13-025/052: Emits LossReporterSetByOwner (distinct from LossReporterProposed via proposeLossReporter).
    function setLossReporter(address lossReporter_) external onlyAllowedCaller onlyOwner {
        _delegateToModule();
    }

    /// @notice OF-H02: Owner-side finalization for loss reporter change (for contract recipients).
    function finalizeLossReporter() external onlyAllowedCaller onlyOwner {
        _delegateToModule();
    }

    /// @notice OF-H02: Propose a new custodian (two-step handoff). Only owner can propose.
    function proposeCustodian(address newCustodian_) external onlyAllowedCaller onlyOwner {
        _delegateToModule();
    }

    /// @notice OF-H02: Accept the pending custodian role. Only the pending custodian can call.
    function acceptCustodian() external onlyAllowedCaller {
        _delegateToModule();
    }

    /// @notice OF-H02: View the pending custodian address.
    function pendingCustodian() external view returns (address) {
        return _pendingCustodian;
    }

    /// @notice OF-H02: Clear the pending custodian to prevent stale proposals surviving UUPS upgrades.
    function clearPendingCustodian() external onlyAllowedCaller onlyOwner {
        _delegateToModule();
    }

    /// @notice OF-H02: Propose a new loss reporter (two-step handoff). Only owner can propose.
    function proposeLossReporter(address newLossReporter_) external onlyAllowedCaller onlyOwner {
        _delegateToModule();
    }

    /// @notice OF-H02: Accept the pending loss reporter role. Only the pending loss reporter can call.
    function acceptLossReporter() external onlyAllowedCaller {
        _delegateToModule();
    }

    /// @notice OF-H02: View the pending loss reporter address.
    function pendingLossReporter() external view returns (address) {
        return _pendingLossReporter;
    }

    /// @notice OF-H02: Clear the pending loss reporter to prevent stale proposals surviving UUPS upgrades.
    function clearPendingLossReporter() external onlyAllowedCaller onlyOwner {
        _delegateToModule();
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

    modifier onlyEmergencyCapTightener() {
        if (msg.sender != owner() && msg.sender != _forageGovernor && !_isGuardianModule(msg.sender)) {
            revert UnauthorizedCapTightener(msg.sender);
        }
        _;
    }

    function setMaxDeploymentRatioBps(uint256 bps_) external onlyAllowedCaller onlyOwner {
        _delegateToModule();
    }

    function setWeeklyRedemptionCapBps(uint256 bps_) external onlyAllowedCaller onlyOwner {
        _delegateToModule();
    }

    function setWeeklyMintCapBps(uint256 bps_) external onlyAllowedCaller onlyOwner {
        _delegateToModule();
    }

    function setDailyMintCapBps(uint256 bps_) external onlyAllowedCaller onlyOwner {
        _delegateToModule();
    }

    function setDailyRedemptionCapBps(uint256 bps_) external onlyAllowedCaller onlyOwner {
        _delegateToModule();
    }

    function setManualAttestationReporter(address reporter_) external onlyAllowedCaller onlyOwner {
        _delegateToModule();
    }

    function finalizeManualAttestationReporter() external onlyAllowedCaller onlyOwner {
        _delegateToModule();
    }

    function acceptManualAttestationReporter() external onlyAllowedCaller {
        _delegateToModule();
    }

    function clearPendingManualAttestationReporter() external onlyAllowedCaller onlyOwner {
        _delegateToModule();
    }

    function setPerBlockMintCap(uint256 bps_, uint256 maxAmount_) external onlyAllowedCaller onlyOwner {
        _delegateToModule();
    }

    function setDeploymentBufferBps(uint256 bps_) external onlyAllowedCaller onlyOwner {
        _delegateToModule();
    }

    function setSuspectedLossFreeze(bool frozen) external onlyAllowedCaller {
        _delegateToModule();
    }

    /// @notice Emergency-only asymmetric cap control: guardians may shrink redemption flow immediately.
    /// @dev Widening still requires the owner/governance setter.
    function shrinkWeeklyRedemptionCapBps(uint256 bps_) external onlyAllowedCaller onlyEmergencyCapTightener {
        _delegateToModule();
    }

    /// @notice Emergency-only asymmetric cap control for public mint growth.
    /// @dev Allows zero so guardians can halt public deposits without blocking recovery-only accounting paths.
    function shrinkWeeklyMintCapBps(uint256 bps_) external onlyAllowedCaller onlyEmergencyCapTightener {
        _delegateToModule();
    }

    /// @notice Emergency-only asymmetric cap control for daily public mint growth.
    function shrinkDailyMintCapBps(uint256 bps_) external onlyAllowedCaller onlyEmergencyCapTightener {
        _delegateToModule();
    }

    /// @notice Emergency-only asymmetric cap control for same-block public minting.
    /// @dev Both dimensions must tighten. Zero in either dimension halts public minting.
    function shrinkPerBlockMintCap(uint256 bps_, uint256 maxAmount_)
        external
        onlyAllowedCaller
        onlyEmergencyCapTightener
    {
        _delegateToModule();
    }

    /// @notice Emergency-only asymmetric cap control for custodian deployment exposure.
    function tightenMaxDeploymentRatioBps(uint256 bps_) external onlyAllowedCaller onlyEmergencyCapTightener {
        _delegateToModule();
    }

    /// @notice Emergency-only asymmetric control that increases the retained deployment buffer.
    function tightenDeploymentBufferBps(uint256 bps_) external onlyAllowedCaller onlyEmergencyCapTightener {
        _delegateToModule();
    }

    function setAttestationIntervalSeconds(uint256 interval_) external onlyAllowedCaller onlyOwner {
        _delegateToModule();
    }

    function setMinReserveRatioBps(uint256 bps_) external onlyAllowedCaller onlyOwner {
        _delegateToModule();
    }

    /// @notice OF-15-005: setForageGovernor now only proposes — no instant effect.
    function setForageGovernor(address newGovernor_) external onlyAllowedCaller onlyOwner {
        _delegateToModule();
    }

    /// @notice OF-15-005: Finalize the proposed ForageGovernor after FINALIZE_DELAY.
    function finalizeForageGovernor() external onlyAllowedCaller onlyOwner {
        _delegateToModule();
    }

    function clearPendingForageGovernor() external onlyAllowedCaller onlyOwner {
        _delegateToModule();
    }

    function setBlocklist(address blocklist_) external onlyAllowedCaller onlyOwner {
        _delegateToModule();
    }

    /// @notice KYC-02: sets the caller allowlist. Ungated so the first wiring can land on a fresh proxy.
    function setAllowlist(address allowlist_) external onlyOwner {
        _setAllowlist(allowlist_);
    }

    /// @notice KYC-03: sets the minimum first deposit for a wallet basis (basis 2 is the on-chain floor).
    function setMinimumFirstDeposit(uint8 basis, uint256 amount) external onlyAllowedCaller onlyOwner {
        _delegateToModule();
    }

    /// @notice KYC-03: the minimum first deposit for a wallet basis.
    function minimumFirstDeposit(uint8 basis) external view returns (uint256) {
        return _minimumFirstDeposit[basis];
    }

    // OF-19-002: owner, governor, or guardian module can pause/unpause
    function pause() external onlyAllowedCaller {
        _delegateToModule();
    }

    function unpause() external onlyAllowedCaller {
        _delegateToModule();
    }

    // --- View Functions ---

    function usdc() external view returns (address) {
        return address(_usdc);
    }

    function riskusd() external view returns (address) {
        return address(_riskusd);
    }

    function blocklist() external view returns (address) {
        return _blocklist;
    }

    function custodian() external view returns (address) {
        return _custodian;
    }

    function lossReporter() external view returns (address) {
        return _lossReporter;
    }

    function forageGovernor() external view returns (address) {
        return _forageGovernor;
    }

    function vaultRegistry() external view returns (address) {
        return address(_vaultRegistry);
    }

    function minReserveRatioBps() external view returns (uint256) {
        return _minReserveRatioBps;
    }

    function maxDeploymentRatioBps() external view returns (uint256) {
        return _maxDeploymentRatioBps;
    }

    function weeklyRedemptionCapBps() external view returns (uint256) {
        return _weeklyRedemptionCapBps;
    }

    function weeklyRedemptionUsed() external view returns (uint256) {
        return _weeklyRedemptionUsed;
    }

    function weeklyRedemptionWindowStart() external view returns (uint256) {
        return _weeklyRedemptionWindowStart;
    }

    function weeklyMintCapBps() external view returns (uint256) {
        return _weeklyMintCapBps;
    }

    function dailyMintCapBps() external view returns (uint256) {
        return _dailyMintCapBps;
    }

    function dailyRedemptionCapBps() external view returns (uint256) {
        return _dailyRedemptionCapBps;
    }

    function weeklyMintUsed() external view returns (uint256) {
        return _weeklyMintUsed;
    }

    function weeklyMintWindowStart() external view returns (uint256) {
        return _weeklyMintWindowStart;
    }

    function dailyMintUsed() external view returns (uint256) {
        return _dailyMintUsed;
    }

    function dailyRedemptionUsed() external view returns (uint256) {
        if (block.timestamp >= _dailyRedemptionWindowStart + DAILY_WINDOW) return 0;
        return _dailyRedemptionUsed;
    }

    function dailyMintWindowStart() external view returns (uint256) {
        return _dailyMintWindowStart;
    }

    function dailyRedemptionWindowStart() external view returns (uint256) {
        return _dailyRedemptionWindowStart;
    }

    function perBlockMintCapBps() external view returns (uint256) {
        return _perBlockMintCapBps;
    }

    function perBlockMintCapMax() external view returns (uint256) {
        return _perBlockMintCapMax;
    }

    function mintUsedThisBlock() external view returns (uint256) {
        return block.number == _mintUsedBlockNumber ? _mintUsedThisBlock : 0;
    }

    function deploymentBufferBps() external view returns (uint256) {
        return _deploymentBufferBps;
    }

    function lastAttestedNAV() external view returns (uint256) {
        return _lastAttestedNAV;
    }

    function lastAttestationTimestamp() external view returns (uint256) {
        return _lastAttestationTimestamp;
    }

    function attestationIntervalSeconds() external view returns (uint256) {
        return _attestationIntervalSeconds;
    }

    function deployedSinceLastAttestation() external view returns (uint256) {
        return _deployedSinceLastAttestation;
    }

    function returnedSinceLastAttestation() external view returns (uint256) {
        return _returnedSinceLastAttestation;
    }

    function totalDeposited() external view returns (uint256) {
        return _totalDeposited;
    }

    function totalRedeemed() external view returns (uint256) {
        return _totalRedeemed;
    }

    function totalDeployed() external view returns (uint256) {
        return _totalDeployed;
    }

    function totalBurnedForLoss() external view returns (uint256) {
        return _totalBurnedForLoss;
    }

    function totalReplenished() external view returns (uint256) {
        return _totalReplenished;
    }

    function totalLostCapital() external view returns (uint256) {
        return _totalLostCapital;
    }

    /// @notice Returns the amount of acknowledged capital loss not yet consumed by burnForLoss().
    /// After burnForLoss() processes the corresponding loss, this value decreases.
    function totalAcknowledgedLoss() external view returns (uint256) {
        return _totalAcknowledgedLoss;
    }

    /// @notice OF-001 (11th audit): Whether a loss has been acknowledged but not yet burned.
    function lossPending() external view returns (bool) {
        return _lossPendingActive();
    }

    function suspectedLossFreeze() external view returns (bool) {
        return _suspectedLossFreeze;
    }

    /// @dev OF-14-001: Returns the vaultId of the pending loss, or 0 if no loss is pending.
    function lossPendingVaultId() external view returns (uint256) {
        if (_hasUnresolvedAttestedLoss()) return _latestLossVaultId;
        return _lossPendingVaultId;
    }

    function latestLossNonce() external view returns (uint256) {
        return _latestLossNonce;
    }

    function settledLossNonce() external view returns (uint256) {
        return _settledLossNonce;
    }

    function latestLossAmount() external view returns (uint256) {
        return _latestLossAmount;
    }

    function manualAttestationReporter() external view returns (address) {
        return _manualAttestationReporter;
    }

    /// @notice OF-13-009: Returns whether the vault is in winding-down mode.
    function vaultWindingDown() external view returns (bool) {
        return _vaultWindingDown;
    }

    function totalDepositorUsdc() external view returns (uint256) {
        // PHASE3-003: Subtract acknowledged losses to reflect actual depositor USDC
        // OF-002: Underflow protection for high-loss scenarios
        return _safeDepositorUsdc();
    }

    function vaultUsdcBalance() public view returns (uint256) {
        return IERC20(_usdc).balanceOf(address(this));
    }

    function reserveRatio() external view returns (uint256) {
        // OF-002: Underflow protection
        uint256 depositorUsdc = _safeDepositorUsdc();
        if (depositorUsdc == 0) return 10000;
        return vaultUsdcBalance() * 10000 / depositorUsdc;
    }

    function effectiveWeeklyRedemptionCap() public view returns (uint256) {
        uint256 effectiveSupply;
        if (block.timestamp >= _weeklyRedemptionWindowStart + WEEKLY_WINDOW) {
            // Window expired — would reset using last active supply (OF-L21)
            effectiveSupply = _lastActiveSupply > 0 ? _lastActiveSupply : _riskusd.totalSupply();
        } else if (_windowStartSupply == 0) {
            // No redemptions yet — use current supply
            effectiveSupply = _riskusd.totalSupply();
        } else {
            // Use only the window start supply — prevents cap inflation from mid-window deposits
            effectiveSupply = _windowStartSupply;
        }
        return effectiveSupply * _weeklyRedemptionCapBps / 10000;
    }

    function weeklyRedemptionRemaining() external view returns (uint256) {
        if (block.timestamp >= _weeklyRedemptionWindowStart + WEEKLY_WINDOW) {
            return effectiveWeeklyRedemptionCap();
        }
        uint256 cap = effectiveWeeklyRedemptionCap();
        if (_weeklyRedemptionUsed >= cap) return 0;
        return cap - _weeklyRedemptionUsed;
    }

    function effectiveDailyRedemptionCap() public view returns (uint256) {
        uint256 effectiveSupply;
        if (block.timestamp >= _dailyRedemptionWindowStart + DAILY_WINDOW) {
            effectiveSupply = _dailyRedemptionWindowStartSupply > _riskusd.totalSupply()
                ? _dailyRedemptionWindowStartSupply
                : _riskusd.totalSupply();
        } else if (_dailyRedemptionWindowStartSupply == 0) {
            effectiveSupply = _riskusd.totalSupply();
        } else {
            effectiveSupply = _dailyRedemptionWindowStartSupply;
        }
        return effectiveSupply * _dailyRedemptionCapBps / 10000;
    }

    function dailyRedemptionRemaining() external view returns (uint256) {
        if (block.timestamp >= _dailyRedemptionWindowStart + DAILY_WINDOW) {
            return effectiveDailyRedemptionCap();
        }
        uint256 cap = effectiveDailyRedemptionCap();
        if (_dailyRedemptionUsed >= cap) return 0;
        return cap - _dailyRedemptionUsed;
    }

    function availableForRedemption() external view returns (uint256) {
        return vaultUsdcBalance();
    }

    function effectiveWeeklyMintCap() public view returns (uint256) {
        if (_weeklyMintCapBps == 0) return 0;

        uint256 effectiveSupply;
        if (block.timestamp >= _weeklyMintWindowStart + WEEKLY_WINDOW) {
            uint256 currentSupply = _riskusd.totalSupply();
            effectiveSupply = _lastMintActiveSupply > currentSupply ? _lastMintActiveSupply : currentSupply;
        } else if (_weeklyMintWindowStartSupply == 0) {
            effectiveSupply = _weeklyMintUsed == 0 ? _riskusd.totalSupply() : 0;
        } else {
            effectiveSupply = _weeklyMintWindowStartSupply;
        }
        uint256 cap = effectiveSupply * _weeklyMintCapBps / 10000;
        return cap == 0 ? 10_000_000e6 : cap;
    }

    function weeklyMintRemaining() external view returns (uint256) {
        if (block.timestamp >= _weeklyMintWindowStart + WEEKLY_WINDOW) {
            return effectiveWeeklyMintCap();
        }
        uint256 cap = effectiveWeeklyMintCap();
        if (_weeklyMintUsed >= cap) return 0;
        return cap - _weeklyMintUsed;
    }

    function effectiveDailyMintCap() public view returns (uint256) {
        if (_dailyMintCapBps == 0) return 0;

        uint256 effectiveSupply;
        if (block.timestamp >= _dailyMintWindowStart + DAILY_WINDOW) {
            uint256 currentSupply = _riskusd.totalSupply();
            effectiveSupply = _lastDailyMintActiveSupply > currentSupply ? _lastDailyMintActiveSupply : currentSupply;
        } else if (_dailyMintWindowStartSupply == 0) {
            effectiveSupply = _dailyMintUsed == 0 ? _riskusd.totalSupply() : 0;
        } else {
            effectiveSupply = _dailyMintWindowStartSupply;
        }
        uint256 cap = effectiveSupply * _dailyMintCapBps / 10000;
        return cap == 0 ? 10_000_000e6 : cap;
    }

    function dailyMintRemaining() external view returns (uint256) {
        if (block.timestamp >= _dailyMintWindowStart + DAILY_WINDOW) {
            return effectiveDailyMintCap();
        }
        uint256 cap = effectiveDailyMintCap();
        if (_dailyMintUsed >= cap) return 0;
        return cap - _dailyMintUsed;
    }

    function adjustedCustodianNAV() public view returns (uint256) {
        if (_hasUnresolvedAttestedLoss()) {
            return _adjustedCustodianNAVNoStaleFallback();
        }
        if (
            _lastAttestationTimestamp == 0
                || block.timestamp > _lastAttestationTimestamp + (2 * _attestationIntervalSeconds)
        ) {
            return _totalDeployed;
        }

        return _adjustedCustodianNAVNoStaleFallback();
    }

    function _adjustedCustodianNAVNoStaleFallback() internal view returns (uint256) {
        uint256 nav = _lastAttestedNAV + _deployedSinceLastAttestation;
        if (_returnedSinceLastAttestation >= nav) return 0;
        return nav - _returnedSinceLastAttestation;
    }

    function solvencyBackingAssets() public view returns (uint256) {
        uint256 bookValue = _totalDeployed;
        uint256 adjustedNav = adjustedCustodianNAV();
        uint256 conservativeCustodianValue = adjustedNav < bookValue ? adjustedNav : bookValue;
        return vaultUsdcBalance() + conservativeCustodianValue;
    }

    // --- Internal ---

    function _lossPendingActive() internal view returns (bool) {
        return _suspectedLossFreeze || _lossPending || _hasUnresolvedAttestedLoss() || _custodianNAVUnavailableOrStale()
            || _hasCurrentNAVShortfall();
    }

    function _hasUnresolvedAttestedLoss() internal view returns (bool) {
        if (!_hasOpenAttestedLossNonce()) return false;
        return _adjustedCustodianNAVNoStaleFallback() < _totalDeployed;
    }

    function _hasCurrentNAVShortfall() internal view returns (bool) {
        if (_lastAttestationTimestamp == 0 || _totalDeployed == 0) return false;
        return _adjustedCustodianNAVNoStaleFallback() < _totalDeployed;
    }

    function _custodianNAVUnavailableOrStale() internal view returns (bool) {
        if (_totalDeployed == 0) return false;
        if (_lastAttestationTimestamp == 0) return true;
        return block.timestamp > _lastAttestationTimestamp + (2 * _attestationIntervalSeconds);
    }

    function _hasOpenAttestedLossNonce() internal view returns (bool) {
        return _latestLossNonce != 0 && _latestLossNonce > _settledLossNonce && _latestLossVaultId != 0;
    }

    /// @dev OF-002: Safe depositor USDC computation with underflow protection.
    /// Returns 0 when outflows exceed inflows (high-loss scenario) instead of panicking.
    /// OF-18-007: Include _totalReplenished in inflows so replenished capital is redeployable.
    function _safeDepositorUsdc() internal view returns (uint256) {
        uint256 inflows = _totalDeposited + _totalReplenished;
        uint256 outflows = _totalRedeemed + _totalBurnedForLoss + _totalAcknowledgedLoss;
        return inflows > outflows ? inflows - outflows : 0;
    }

    function _publicRedemptionNettingEnabled() internal view returns (bool) {
        return address(_vaultRegistry) != address(0);
    }

    function _requirePublicAccountingRegistry() internal view {
        address registry = address(_vaultRegistry);
        if (registry == address(0)) revert VaultRegistryRequired();
        if (registry.code.length == 0) revert InvalidVaultRegistryInterface(registry);

        (bool ok, bytes memory data) =
            registry.staticcall(abi.encodeWithSelector(IVaultRegistryWiringQuery.riskusdVault.selector));
        if (!ok || data.length < 32) revert RISKUSDVaultMismatch();
        if (!_registryAddressMatches(data, address(this))) {
            (ok, data) =
                registry.staticcall(abi.encodeWithSelector(IVaultRegistryWiringQuery.pendingRISKUSDVault.selector));
            if (!ok || !_registryAddressMatches(data, address(this))) revert RISKUSDVaultMismatch();
        }

        (ok, data) = registry.staticcall(abi.encodeWithSelector(IVaultRegistry.getVaultsPage.selector, 0, 1));
        if (!ok || data.length < 96) revert InvalidVaultRegistryInterface(registry);
    }

    function _registryAddressMatches(bytes memory data, address expected) private pure returns (bool) {
        if (data.length < 32) return false;
        uint256 returnedAddress;
        assembly ("memory-safe") {
            returnedAddress := mload(add(data, 0x20))
        }
        return returnedAddress <= type(uint160).max && address(uint160(returnedAddress)) == expected;
    }

    function _redemptionWindowStart(uint256 storedStart, uint256 window) internal view returns (uint256) {
        if (block.timestamp < storedStart + window) return storedStart;
        uint256 elapsed = (block.timestamp - storedStart) / window;
        return storedStart + elapsed * window;
    }

    function _recordPublicRedemptionMint(uint256 amount) internal {
        if (!_publicRedemptionNettingEnabled()) return;

        RISKUSDVaultRedemptionBufferStorage.Layout storage buffers = RISKUSDVaultRedemptionBufferStorage.layout();
        uint256 weeklyStart = _redemptionWindowStart(_weeklyRedemptionWindowStart, WEEKLY_WINDOW);
        if (buffers.weeklyWindowStart != weeklyStart) {
            buffers.weeklyWindowStart = weeklyStart;
            buffers.weeklyMintAmount = 0;
        }
        if (block.timestamp < _weeklyRedemptionWindowStart + WEEKLY_WINDOW) {
            uint256 weeklyOffset = _min(amount, _weeklyRedemptionUsed);
            _weeklyRedemptionUsed -= weeklyOffset;
            buffers.weeklyMintAmount += amount - weeklyOffset;
        } else {
            buffers.weeklyMintAmount += amount;
        }

        uint256 dailyStart = _redemptionWindowStart(_dailyRedemptionWindowStart, DAILY_WINDOW);
        if (buffers.dailyWindowStart != dailyStart) {
            buffers.dailyWindowStart = dailyStart;
            buffers.dailyMintAmount = 0;
        }
        if (block.timestamp < _dailyRedemptionWindowStart + DAILY_WINDOW) {
            uint256 dailyOffset = _min(amount, _dailyRedemptionUsed);
            _dailyRedemptionUsed -= dailyOffset;
            buffers.dailyMintAmount += amount - dailyOffset;
        } else {
            buffers.dailyMintAmount += amount;
        }
    }

    function _consumeWeeklyRedemptionMint(uint256 amount) internal returns (uint256) {
        if (!_publicRedemptionNettingEnabled()) return amount;

        RISKUSDVaultRedemptionBufferStorage.Layout storage buffers = RISKUSDVaultRedemptionBufferStorage.layout();
        uint256 weeklyStart = _redemptionWindowStart(_weeklyRedemptionWindowStart, WEEKLY_WINDOW);
        if (buffers.weeklyWindowStart != weeklyStart) {
            buffers.weeklyWindowStart = weeklyStart;
            buffers.weeklyMintAmount = 0;
        }
        uint256 offset = _min(amount, buffers.weeklyMintAmount);
        buffers.weeklyMintAmount -= offset;
        return amount - offset;
    }

    function _consumeDailyRedemptionMint(uint256 amount) internal returns (uint256) {
        if (!_publicRedemptionNettingEnabled()) return amount;

        RISKUSDVaultRedemptionBufferStorage.Layout storage buffers = RISKUSDVaultRedemptionBufferStorage.layout();
        uint256 dailyStart = _redemptionWindowStart(_dailyRedemptionWindowStart, DAILY_WINDOW);
        if (buffers.dailyWindowStart != dailyStart) {
            buffers.dailyWindowStart = dailyStart;
            buffers.dailyMintAmount = 0;
        }
        uint256 offset = _min(amount, buffers.dailyMintAmount);
        buffers.dailyMintAmount -= offset;
        return amount - offset;
    }

    function _consumeLossRedemptionMint(uint256 amount) internal {
        if (!_publicRedemptionNettingEnabled()) return;

        RISKUSDVaultRedemptionBufferStorage.Layout storage buffers = RISKUSDVaultRedemptionBufferStorage.layout();
        uint256 weeklyStart = _redemptionWindowStart(_weeklyRedemptionWindowStart, WEEKLY_WINDOW);
        if (buffers.weeklyWindowStart != weeklyStart) {
            buffers.weeklyWindowStart = weeklyStart;
            buffers.weeklyMintAmount = 0;
        }
        uint256 weeklyOffset = _min(amount, buffers.weeklyMintAmount);
        buffers.weeklyMintAmount -= weeklyOffset;

        uint256 dailyStart = _redemptionWindowStart(_dailyRedemptionWindowStart, DAILY_WINDOW);
        if (buffers.dailyWindowStart != dailyStart) {
            buffers.dailyWindowStart = dailyStart;
            buffers.dailyMintAmount = 0;
        }
        uint256 dailyOffset = _min(amount, buffers.dailyMintAmount);
        buffers.dailyMintAmount -= dailyOffset;
    }

    function _enforceWeeklyCap(uint256 riskusdAmount) internal {
        // Cache totalSupply to avoid redundant external calls (OF-056)
        uint256 cachedTotalSupply = _riskusd.totalSupply();

        // Lazy reset: if window has expired, reset used counter and advance window
        if (block.timestamp >= _weeklyRedemptionWindowStart + WEEKLY_WINDOW) {
            _weeklyRedemptionUsed = 0;
            // OF-M02: Advance by elapsed periods (handles multi-week gaps)
            uint256 elapsed = (block.timestamp - _weeklyRedemptionWindowStart) / WEEKLY_WINDOW;
            _weeklyRedemptionWindowStart += elapsed * WEEKLY_WINDOW;
            // OF-L21: Use last active-window supply to prevent cap inflation via temporary deposits
            _windowStartSupply = _lastActiveSupply > 0 ? _lastActiveSupply : cachedTotalSupply;
            // OF-007: Reset _lastActiveSupply for new window to prevent permanent cap ratchet-down
            _lastActiveSupply = cachedTotalSupply;
        } else if (_windowStartSupply == 0) {
            // First redemption ever — snapshot current supply
            _windowStartSupply = cachedTotalSupply;
        }

        // Use only _windowStartSupply — prevents cap inflation from mid-window deposits (OF-014)
        uint256 cap = _windowStartSupply * _weeklyRedemptionCapBps / 10000;
        if (_weeklyRedemptionUsed + riskusdAmount > cap) revert WeeklyRedemptionCapExceeded();

        // PHASE3-002: Min-track supply to prevent inflation via temporary large deposits
        _lastActiveSupply =
            (_lastActiveSupply > 0 && _lastActiveSupply < cachedTotalSupply) ? _lastActiveSupply : cachedTotalSupply;
    }

    function _enforceDailyRedemptionCap(uint256 riskusdAmount) internal {
        uint256 cachedTotalSupply = _riskusd.totalSupply();

        if (block.timestamp >= _dailyRedemptionWindowStart + DAILY_WINDOW) {
            _dailyRedemptionUsed = 0;
            uint256 elapsed = (block.timestamp - _dailyRedemptionWindowStart) / DAILY_WINDOW;
            _dailyRedemptionWindowStart += elapsed * DAILY_WINDOW;
            _dailyRedemptionWindowStartSupply = _dailyRedemptionWindowStartSupply > cachedTotalSupply
                ? _dailyRedemptionWindowStartSupply
                : cachedTotalSupply;
        } else if (_dailyRedemptionWindowStartSupply == 0) {
            _dailyRedemptionWindowStartSupply = cachedTotalSupply;
        }

        uint256 cap = _dailyRedemptionWindowStartSupply * _dailyRedemptionCapBps / 10000;
        if (_dailyRedemptionUsed + riskusdAmount > cap) revert DailyRedemptionCapExceeded();
    }

    function _enforcePerBlockMintCap(uint256 riskusdAmount) internal {
        if (block.number != _mintUsedBlockNumber) {
            _mintUsedBlockNumber = block.number;
            _mintUsedThisBlock = 0;
        }

        if (_perBlockMintCapBps == 0 || _perBlockMintCapMax == 0) {
            revert PerBlockMintCapExceeded(riskusdAmount, 0);
        }

        uint256 supply = _riskusd.totalSupply();
        uint256 supplyCap = supply * _perBlockMintCapBps / 10000;
        uint256 cap = supply == 0 ? _perBlockMintCapMax : supplyCap;
        if (cap > _perBlockMintCapMax) cap = _perBlockMintCapMax;
        if (cap == 0) cap = 1;
        uint256 remaining = cap > _mintUsedThisBlock ? cap - _mintUsedThisBlock : 0;
        if (riskusdAmount > remaining) revert PerBlockMintCapExceeded(riskusdAmount, remaining);
        _mintUsedThisBlock += riskusdAmount;
    }

    function _enforceWeeklyMintCap(uint256 riskusdAmount) internal {
        uint256 cachedTotalSupply = _riskusd.totalSupply();

        if (block.timestamp >= _weeklyMintWindowStart + WEEKLY_WINDOW) {
            _weeklyMintUsed = 0;
            uint256 elapsed = (block.timestamp - _weeklyMintWindowStart) / WEEKLY_WINDOW;
            _weeklyMintWindowStart += elapsed * WEEKLY_WINDOW;
            uint256 baseline = _lastMintActiveSupply > cachedTotalSupply ? _lastMintActiveSupply : cachedTotalSupply;
            _weeklyMintWindowStartSupply = baseline;
            _lastMintActiveSupply = cachedTotalSupply;
        } else if (_weeklyMintUsed == 0 && _weeklyMintWindowStartSupply == 0) {
            _weeklyMintWindowStartSupply = cachedTotalSupply;
        }

        if (_weeklyMintCapBps == 0) revert WeeklyMintCapExceeded();

        uint256 cap = _weeklyMintWindowStartSupply * _weeklyMintCapBps / 10000;
        if (cap == 0) {
            cap = 10_000_000e6;
        }
        if (_weeklyMintUsed + riskusdAmount > cap) revert WeeklyMintCapExceeded();
        _weeklyMintUsed += riskusdAmount;

        _lastMintActiveSupply = _lastMintActiveSupply > cachedTotalSupply ? _lastMintActiveSupply : cachedTotalSupply;
    }

    function _enforceDailyMintCap(uint256 riskusdAmount) internal {
        uint256 cachedTotalSupply = _riskusd.totalSupply();

        if (block.timestamp >= _dailyMintWindowStart + DAILY_WINDOW) {
            _dailyMintUsed = 0;
            uint256 elapsed = (block.timestamp - _dailyMintWindowStart) / DAILY_WINDOW;
            _dailyMintWindowStart += elapsed * DAILY_WINDOW;
            uint256 baseline =
                _lastDailyMintActiveSupply > cachedTotalSupply ? _lastDailyMintActiveSupply : cachedTotalSupply;
            _dailyMintWindowStartSupply = baseline;
            _lastDailyMintActiveSupply = cachedTotalSupply;
        } else if (_dailyMintUsed == 0 && _dailyMintWindowStartSupply == 0) {
            _dailyMintWindowStartSupply = cachedTotalSupply;
        }

        if (_dailyMintCapBps == 0) revert DailyMintCapExceeded();

        uint256 cap = _dailyMintWindowStartSupply * _dailyMintCapBps / 10000;
        if (cap == 0) {
            cap = 10_000_000e6;
        }
        if (_dailyMintUsed + riskusdAmount > cap) revert DailyMintCapExceeded();
        _dailyMintUsed += riskusdAmount;

        _lastDailyMintActiveSupply =
            _lastDailyMintActiveSupply > cachedTotalSupply ? _lastDailyMintActiveSupply : cachedTotalSupply;
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function _reduceMintActiveSupply(uint256 riskusdAmount) internal {
        if (block.timestamp < _weeklyMintWindowStart + WEEKLY_WINDOW) {
            _weeklyMintUsed = riskusdAmount >= _weeklyMintUsed ? 0 : _weeklyMintUsed - riskusdAmount;
        }
        if (block.timestamp < _dailyMintWindowStart + DAILY_WINDOW) {
            _dailyMintUsed = riskusdAmount >= _dailyMintUsed ? 0 : _dailyMintUsed - riskusdAmount;
        }
        if (block.number == _mintUsedBlockNumber) {
            _mintUsedThisBlock = riskusdAmount >= _mintUsedThisBlock ? 0 : _mintUsedThisBlock - riskusdAmount;
        }
    }

    function _assertBackingMarginNotDecreased(uint256 backingAssetsBefore, uint256 riskusdSupplyBefore) internal view {
        uint256 backingAssetsAfter = solvencyBackingAssets();
        uint256 riskusdSupplyAfter = _riskusd.totalSupply();
        if (_backingMarginDecreased(backingAssetsBefore, riskusdSupplyBefore, backingAssetsAfter, riskusdSupplyAfter)) {
            revert BackingMarginDecreased(
                backingAssetsBefore, riskusdSupplyBefore, backingAssetsAfter, riskusdSupplyAfter
            );
        }
    }

    function _backingMarginDecreased(
        uint256 backingAssetsBefore,
        uint256 riskusdSupplyBefore,
        uint256 backingAssetsAfter,
        uint256 riskusdSupplyAfter
    ) internal pure returns (bool) {
        if (backingAssetsBefore >= riskusdSupplyBefore) {
            uint256 surplusBefore = backingAssetsBefore - riskusdSupplyBefore;
            if (backingAssetsAfter < riskusdSupplyAfter) return true;
            return backingAssetsAfter - riskusdSupplyAfter < surplusBefore;
        }

        uint256 deficitBefore = riskusdSupplyBefore - backingAssetsBefore;
        if (backingAssetsAfter >= riskusdSupplyAfter) return false;
        return riskusdSupplyAfter - backingAssetsAfter > deficitBefore;
    }

    function _assertSolvency() internal {
        uint256 supply = _riskusd.totalSupply();
        uint256 bookValue = _totalDeployed;
        uint256 adjustedNav = adjustedCustodianNAV();
        uint256 conservativeCustodianValue = adjustedNav < bookValue ? adjustedNav : bookValue;
        uint256 vaultUsdc = vaultUsdcBalance();
        uint256 backingAssets = vaultUsdc + conservativeCustodianValue;
        if (backingAssets < supply) {
            emit SolvencyInvariantFailure(vaultUsdc, bookValue, adjustedNav, supply);
            revert SolvencyInvariantViolated(backingAssets, supply);
        }
    }

    function _enforceReserveRatio(uint256 redeemAmount) internal view {
        if (_minReserveRatioBps == 0) return;

        // OF-002: Use safe helper to prevent underflow in high-loss scenarios
        uint256 depositorUsdc = _safeDepositorUsdc();
        // OF-002: Full or excess redemption always allowed (prevents underflow on subtraction)
        if (redeemAmount >= depositorUsdc) return;

        uint256 newDepositorUsdc = depositorUsdc - redeemAmount;
        uint256 newVaultBalance = vaultUsdcBalance() - redeemAmount;
        // Check: newVaultBalance / newDepositorUsdc >= _minReserveRatioBps / 10000
        // Rearranged to avoid division: newVaultBalance * 10000 >= _minReserveRatioBps * newDepositorUsdc
        if (newVaultBalance * 10000 < _minReserveRatioBps * newDepositorUsdc) {
            revert ReserveRatioViolated();
        }
    }

    /// @notice Stage a stranded-token rescue for delayed execution.
    /// @dev The protected USDC/RISKUSD assets remain non-rescuable. The recipient is blocklist-checked
    /// at proposal and again at execution so a newly blocked recipient cannot receive delayed funds.
    function proposeTokenRescue(address token, uint256 amount, address recipient)
        external
        onlyAllowedCaller
        onlyOwner
    {
        _delegateToModule();
    }

    /// @notice Execute a staged stranded-token rescue after the one-day announcement delay.
    /// @dev Intentionally remains owner-only and blocklist-checked at execution time.
    function executeTokenRescue(address token) external onlyAllowedCaller onlyOwner nonReentrant {
        _delegateToModule();
    }

    // --- Ownership ---

    function renounceOwnership() public pure override {
        revert RenounceOwnershipDisabled();
    }

    // --- Allowlist Gate Overrides ---

    /// @notice KYC-02: the caller gate is the first check on UUPS upgrades and ownership handoff.
    function upgradeToAndCall(address newImplementation, bytes memory data) public payable override onlyAllowedCaller {
        super.upgradeToAndCall(newImplementation, data);
    }

    /// @notice KYC-02: two-step ownership proposals require an allowlisted caller.
    function transferOwnership(address newOwner) public override onlyAllowedCaller {
        super.transferOwnership(newOwner);
    }

    /// @notice KYC-02: two-step ownership acceptance requires an allowlisted caller.
    function acceptOwnership() public override onlyAllowedCaller {
        super.acceptOwnership();
    }

    // --- UUPS ---

    function _authorizeUpgrade(address) internal override onlyOwner {
        _pendingCustodian = address(0);
        _pendingLossReporter = address(0);
        // OF-002 (11th audit): Clear proposal timestamps on upgrade
        _custodianProposedAt = 0;
        _lossReporterProposedAt = 0;
        // OF-15-004: Clear pending VaultRegistry on upgrade
        _pendingVaultRegistry = address(0);
        _pendingVaultRegistryTimestamp = 0;
        // OF-15-005: Clear pending ForageGovernor on upgrade
        _pendingForageGovernor = address(0);
        _pendingForageGovernorProposedAt = 0;
        _pendingManualAttestationReporter = address(0);
        _manualAttestationReporterProposedAt = 0;
    }

    function _requireNotBlocked(address account) internal view {
        address blocklist_ = _blocklist;
        if (blocklist_ != address(0) && IBlocklist(blocklist_).isBlocked(account)) {
            revert BlockedAddress(account);
        }
    }

    // --- Module (delegatecall) ---

    /// @notice Sets the delegatecall target for the moved admin, NAV, loss, registry and rescue cluster.
    /// @dev Only the owner can wire the module; an unset module makes every moved selector revert ModuleUnavailable.
    function setVaultModule(address module_) external onlyOwner {
        if (module_.code.length == 0) revert ZeroAddress();
        VaultModuleStorage storage $ = _getVaultModuleStorage();
        address previous = $.module;
        $.module = module_;
        emit VaultModuleSet(previous, module_);
    }

    /// @notice The current delegatecall target for the moved cluster.
    function vaultModule() external view returns (address) {
        return _getVaultModuleStorage().module;
    }

    /// @notice Any selector the vault does not declare goes through the caller gate to the module.
    fallback() external {
        _checkAllowedCaller();
        _delegateToModule();
        assembly {
            returndatacopy(0, 0, returndatasize())
            return(0, returndatasize())
        }
    }

    /// @dev Delegates the call to the module: reverts with the module's returndata on failure and
    ///      falls through on success, so a forwarder's trailing modifier code (nonReentrant) runs.
    function _delegateToModule() internal {
        address module = _getVaultModuleStorage().module;
        if (module.code.length == 0) revert ModuleUnavailable();
        assembly {
            calldatacopy(0, 0, calldatasize())
            let result := delegatecall(gas(), module, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            if iszero(result) { revert(0, returndatasize()) }
        }
    }

    // --- Deposit / Redeem ---

    /// @notice OF-16-027: USDC is assumed to have no fee-on-transfer. Deposit mints RISKUSD
    /// 1:1 based on the requested amount, not measured receipt. If USDC ever adds transfer fees,
    /// the 1:1 invariant would break. Monitor USDC for fee-on-transfer changes.
}
