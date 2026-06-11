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

interface IRISKUSD is IERC20 {
    function mint(address to, uint256 amount) external;
    function burn(address from, uint256 amount) external;
}

interface IVaultRegistryWiringQuery {
    function riskusdVault() external view returns (address);
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

/// @title RISKUSDVault - Central USDC pool for RISKUSD deposits and redemptions
/// @notice Manages 1:1 USDC/RISKUSD deposits, redemptions with weekly cap,
///         custodian capital deployment, and loss operations.
contract RISKUSDVault is
    Initializable,
    Ownable2StepUpgradeable,
    PausableUpgradeable,
    ReentrancyGuard,
    UUPSUpgradeable,
    FinalizeDelayProfile
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

    /// @dev Reserved storage gap (39 - 32 appended slots - 1 rescue mapping - 1 blocklist = 5)
    uint256[5] private __gap;

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

    // --- Deposit / Redeem ---

    /// @notice OF-16-027: USDC is assumed to have no fee-on-transfer. Deposit mints RISKUSD
    /// 1:1 based on the requested amount, not measured receipt. If USDC ever adds transfer fees,
    /// the 1:1 invariant would break. Monitor USDC for fee-on-transfer changes.
    function deposit(uint256 usdcAmount) external whenNotPaused nonReentrant {
        if (usdcAmount == 0) revert ZeroAmount();
        // OF-13-056: Block fresh user deposits during loss-pending window.
        // Exempt _lossReporter for protocol-controlled loss/yield accounting that must remain live.
        if (_lossPendingActive() && msg.sender != _lossReporter) revert LossPending();
        _requireNotBlocked(msg.sender);
        uint256 backingAssetsBefore = solvencyBackingAssets();
        uint256 riskusdSupplyBefore = _riskusd.totalSupply();

        // Update state before external calls (CEI). Public deposits are throttled;
        // Protocol accounting uses the lossReporter role and must remain live.
        bool mintCapExempt = msg.sender == _lossReporter;
        if (!mintCapExempt) {
            _enforcePerBlockMintCap(usdcAmount);
            _enforceDailyMintCap(usdcAmount);
            _enforceWeeklyMintCap(usdcAmount);
        }
        _totalDeposited += usdcAmount;

        // Pull USDC from depositor
        _usdc.safeTransferFrom(msg.sender, address(this), usdcAmount);

        // Mint RISKUSD 1:1
        _riskusd.mint(msg.sender, usdcAmount);

        _assertBackingMarginNotDecreased(backingAssetsBefore, riskusdSupplyBefore);
        emit Deposited(msg.sender, usdcAmount);
        _assertSolvency();
    }

    function redeem(uint256 riskusdAmount) external whenNotPaused nonReentrant {
        if (riskusdAmount == 0) revert ZeroAmount();
        // OF-NEW-01 (12th audit): Block redemptions while loss is pending
        if (_lossPendingActive()) revert LossPending();
        _requireNotBlocked(msg.sender);
        uint256 backingAssetsBefore = solvencyBackingAssets();
        uint256 riskusdSupplyBefore = _riskusd.totalSupply();

        // Weekly cap enforcement — read totalSupply BEFORE burn
        _enforceWeeklyCap(riskusdAmount);
        _enforceDailyRedemptionCap(riskusdAmount);

        // Vault liquidity check
        uint256 balance = vaultUsdcBalance();
        if (balance < riskusdAmount) revert InsufficientVaultBalance();

        // Reserve ratio enforcement
        _enforceReserveRatio(riskusdAmount);

        // Update state before external calls (CEI)
        _totalRedeemed += riskusdAmount;
        _weeklyRedemptionUsed += riskusdAmount;
        _dailyRedemptionUsed += riskusdAmount;

        // Pull RISKUSD from redeemer and burn
        IERC20(address(_riskusd)).safeTransferFrom(msg.sender, address(this), riskusdAmount);
        _riskusd.burn(address(this), riskusdAmount);
        _reduceMintActiveSupply(riskusdAmount);

        // Send USDC 1:1
        _usdc.safeTransfer(msg.sender, riskusdAmount);

        _assertBackingMarginNotDecreased(backingAssetsBefore, riskusdSupplyBefore);
        emit Redeemed(msg.sender, riskusdAmount);
        _assertSolvency();
    }

    // --- Custodian Operations ---

    function deployCapital(uint256 usdcAmount) external whenNotPaused nonReentrant {
        if (msg.sender != _custodian) revert UnauthorizedCustodian();
        if (_custodian == address(0)) revert UnauthorizedCustodian();
        if (usdcAmount == 0) revert ZeroAmount();
        _requireNotBlocked(msg.sender);
        if (_lossPendingActive()) revert LossPending();

        // OF-002: Use safe helper for consistent underflow protection
        uint256 depositorUsdc = _safeDepositorUsdc();
        if (depositorUsdc == 0) revert DeploymentRatioExceeded();

        // Vault balance check
        uint256 balance = vaultUsdcBalance();
        if (balance < usdcAmount) revert InsufficientVaultBalance();

        // Deployment ratio enforcement
        uint256 maxDeployable = depositorUsdc * _maxDeploymentRatioBps / 10000;
        if (_totalDeployed + usdcAmount > maxDeployable) revert DeploymentRatioExceeded();
        _enforceDeploymentBuffer(usdcAmount);

        // Update state (CEI)
        _totalDeployed += usdcAmount;
        _deployedSinceLastAttestation += usdcAmount;

        // Transfer USDC to custodian
        _usdc.safeTransfer(_custodian, usdcAmount);

        emit CapitalDeployed(_custodian, usdcAmount, _totalDeployed);
        _assertSolvency();
    }

    function returnCapital(uint256 usdcAmount) external nonReentrant {
        if (msg.sender != _custodian) revert UnauthorizedCustodian();
        if (_custodian == address(0)) revert UnauthorizedCustodian();
        if (usdcAmount == 0) revert ZeroAmount();
        if (usdcAmount > _totalDeployed) revert ExcessiveReturn();
        _requireNotBlocked(msg.sender);

        // Update state (CEI)
        _totalDeployed -= usdcAmount;
        _returnedSinceLastAttestation += usdcAmount;

        // Pull USDC from custodian
        _usdc.safeTransferFrom(msg.sender, address(this), usdcAmount);

        emit CapitalReturned(_custodian, usdcAmount, _totalDeployed);
    }

    /// @notice Records the latest custodian NAV attestation for runtime solvency checks.
    /// @dev Called by the custodian bridge after validating the cross-chain attestation.
    function recordCustodianNAV(uint256 nav) external {
        if (msg.sender != _custodian) revert UnauthorizedCustodian();
        if (_custodian == address(0)) revert UnauthorizedCustodian();
        _requireNotBlocked(msg.sender);

        _recordCustodianNAV(0, nav, 0);
    }

    /// @notice Records the latest custodian NAV attestation and nonce for loss settlement.
    /// @dev The custodian bridge calls this after validating the off-chain NAV attestation.
    /// It does not mutate loss accounting or create a sticky lock; lossPending() is derived.
    function recordCustodianNAV(uint256 vaultId, uint256 nav, uint256 lossNonce) external {
        if (msg.sender != _custodian) revert UnauthorizedCustodian();
        if (_custodian == address(0)) revert UnauthorizedCustodian();
        _requireNotBlocked(msg.sender);

        _recordCustodianNAV(vaultId, nav, lossNonce);
    }

    /// @notice Governance-configured manual attestation path for emergency custodian fallback.
    /// @dev The reporter is set via two-stage owner/governance handoff. Manual attestations
    /// enter the same nonce-bound settlement path as custodian bridge attestations.
    function recordManualCustodianNAV(uint256 vaultId, uint256 nav, uint256 lossNonce) external {
        if (msg.sender != _manualAttestationReporter) revert UnauthorizedManualAttestationReporter();
        if (_manualAttestationReporter == address(0)) revert UnauthorizedManualAttestationReporter();
        _requireNotBlocked(msg.sender);

        (bool shouldRecord, uint256 normalizedNav) = _normalizeManualCustodianNAV(vaultId, nav, lossNonce);
        if (!shouldRecord) {
            emit ManualCustodianNAVDeferred(vaultId, nav, lossNonce, _custodian);
            return;
        }

        nav = normalizedNav;
        _recordCustodianNAV(vaultId, nav, lossNonce);
    }

    function _recordCustodianNAV(uint256 vaultId, uint256 nav, uint256 lossNonce) internal {
        if (lossNonce != 0 && lossNonce <= _settledLossNonce) revert StaleLossNonce();
        if (lossNonce != 0 && lossNonce <= _latestLossNonce) revert StaleLossNonce();
        if (lossNonce != 0 && vaultId == 0) revert InvalidVaultId();
        if (lossNonce != 0) {
            _requireActiveVault(vaultId);
            uint256 pendingVaultId = _pendingLossVaultIdForBinding();
            if (pendingVaultId != 0 && vaultId != pendingVaultId) revert VaultIdMismatch();
        }

        bool hadLossToResolve = _lossPending || _hasUnresolvedAttestedLoss() || _hasCurrentNAVShortfall();
        _lastAttestedNAV = nav;
        _lastAttestationTimestamp = block.timestamp;
        _deployedSinceLastAttestation = 0;
        _returnedSinceLastAttestation = 0;

        if (lossNonce != 0) {
            _latestLossNonce = lossNonce;
            if (nav < _totalDeployed) {
                _latestLossVaultId = vaultId;
                _latestLossAmount = _totalDeployed - nav;
            } else {
                _latestLossVaultId = 0;
                _latestLossAmount = 0;
                _settledLossNonce = lossNonce;
            }
            emit CustodianNAVAttested(vaultId, nav, lossNonce, block.timestamp);
        }

        if (hadLossToResolve && !_lossPendingActive()) {
            _clearLossPendingAndNotifyRegistry();
        }

        emit CustodianNAVRecorded(nav, block.timestamp);
    }

    // --- Loss Operations ---

    /// @notice OF-L12: burnForLoss intentionally operates during pause.
    /// Loss accounting must proceed regardless of pause state to maintain solvency invariants.
    /// The RISKUSD.burn() call is minter-only and bypasses pause per OF-M06.
    /// @dev Verifies target attested-loss nonce binding when a nonce-bound loss is open.
    function burnForLoss(uint256 vaultId, uint256 riskusdAmount) external nonReentrant {
        _burnForLoss(vaultId, riskusdAmount, 0);
    }

    function coverAndBurnForLoss(uint256 vaultId, uint256 riskusdAmount, uint256 coverUsdcAmount)
        external
        nonReentrant
    {
        _burnForLoss(vaultId, riskusdAmount, coverUsdcAmount);
    }

    function _burnForLoss(uint256 vaultId, uint256 riskusdAmount, uint256 coverUsdcAmount) internal {
        if (msg.sender != _lossReporter) revert UnauthorizedLossReporter();
        uint256 totalLossAmount = riskusdAmount + coverUsdcAmount;
        if (totalLossAmount == 0) revert ZeroAmount();
        _requireNotBlocked(msg.sender);
        // Verify vault binding when a target attested-loss nonce is open.
        uint256 pendingVaultId = _pendingLossVaultIdForBinding();
        if (pendingVaultId != 0 && vaultId != pendingVaultId) revert VaultIdMismatch();

        // Update state (CEI)
        _totalBurnedForLoss += totalLossAmount;
        if (coverUsdcAmount > 0) _totalDeposited += coverUsdcAmount;

        // R-29 target flow: NAV attestations are authoritative, so fresh losses can burn
        // without a governance acknowledgement gate. If pre-target acknowledged loss state
        // exists, consume it only to avoid double-counting; otherwise decrement deployed capital now.
        uint256 ackReduction = totalLossAmount > _totalAcknowledgedLoss ? _totalAcknowledgedLoss : totalLossAmount;
        if (ackReduction > 0) {
            _totalAcknowledgedLoss -= ackReduction;
        }
        uint256 directLoss = totalLossAmount - ackReduction;
        if (directLoss > 0) {
            uint256 deployedReduction = directLoss > _totalDeployed ? _totalDeployed : directLoss;
            _totalDeployed -= deployedReduction;
            _totalLostCapital += deployedReduction;
        }

        // OF-001 (11th audit): Clear loss pending when all acknowledged loss is consumed
        if (_totalAcknowledgedLoss == 0 && _lossPending) {
            _clearLossPendingAndNotifyRegistry();
        }

        // OF-I06: Adjust _windowStartSupply if within current redemption window
        // to prevent the weekly cap from being based on stale (pre-burn) supply.
        if (block.timestamp < _weeklyRedemptionWindowStart + WEEKLY_WINDOW && _windowStartSupply > 0) {
            _windowStartSupply = _windowStartSupply >= riskusdAmount ? _windowStartSupply - riskusdAmount : 0;
        }
        // OF-014: Also adjust _lastActiveSupply to prevent next window inheriting pre-burn supply
        if (_lastActiveSupply > riskusdAmount) {
            _lastActiveSupply -= riskusdAmount;
        } else {
            _lastActiveSupply = 0;
        }
        _reduceMintActiveSupply(riskusdAmount);

        if (coverUsdcAmount > 0) {
            _usdc.safeTransferFrom(msg.sender, address(this), coverUsdcAmount);
            emit LossCoverDeposited(coverUsdcAmount);
        }

        if (riskusdAmount > 0) {
            // Burn from caller (the loss reporter holds the RISKUSD)
            _riskusd.burn(msg.sender, riskusdAmount);
            emit LossBurned(riskusdAmount);
        }
    }

    function replenish(uint256 usdcAmount) external nonReentrant {
        if (msg.sender != _lossReporter) revert UnauthorizedLossReporter();
        if (usdcAmount == 0) revert ZeroAmount();
        _requireNotBlocked(msg.sender);

        // Update state (CEI)
        _totalReplenished += usdcAmount;

        // Pull USDC from lossReporter
        _usdc.safeTransferFrom(msg.sender, address(this), usdcAmount);

        emit Replenished(usdcAmount);
    }

    /// @notice Finalizes an attested loss nonce after the loss reporter has fully absorbed it.
    /// @dev Called by the custodian bridge in the same transaction after reportLoss(). If this
    /// reverts, the entire cross-contract settlement reverts atomically.
    function finalizeAttestedLoss(uint256 vaultId, uint256 lossNonce, uint256 amount) external {
        if (msg.sender != _custodian) revert UnauthorizedCustodian();
        if (_custodian == address(0)) revert UnauthorizedCustodian();
        if (amount == 0) revert ZeroAmount();
        if (!_hasOpenAttestedLossNonce()) revert LossNotAcknowledged();
        if (lossNonce != _latestLossNonce) revert LossNonceMismatch();
        if (vaultId != _latestLossVaultId) revert VaultIdMismatch();
        if (amount != _latestLossAmount) revert LossAmountMismatch();

        _settledLossNonce = lossNonce;
        _latestLossAmount = 0;
        _lastLossResolutionBlock = block.number;
        _clearLossPendingAndNotifyRegistry();

        emit AttestedLossFinalized(vaultId, lossNonce, amount);
    }

    // --- Admin Setters ---

    // ── VaultRegistry Wiring (OF-15-004 + CODEX-001) ──

    /// @notice OF-15-004: Wire _vaultRegistry on deployed proxies. Called once after UUPS upgrade.
    /// @dev CODEX-R1: onlyOwner prevents front-running if upgrade and init are not atomic.
    function initializeV2(address vaultRegistry_) external onlyOwner reinitializer(2) {
        if (vaultRegistry_ == address(0)) revert ZeroAddress();
        _requireVaultRegistryMatchesThisVault(vaultRegistry_);
        _requireVaultRegistryInterface(vaultRegistry_);
        _vaultRegistry = IVaultRegistry(vaultRegistry_);
        emit VaultRegistryUpdated(address(0), vaultRegistry_);
    }

    /// @notice OF-15-004: Propose a new VaultRegistry address. Takes effect after FINALIZE_DELAY.
    function proposeVaultRegistry(address newRegistry_) external onlyOwner {
        if (newRegistry_ == address(0)) revert ZeroAddress();
        _pendingVaultRegistry = newRegistry_;
        _pendingVaultRegistryTimestamp = uint48(block.timestamp);
        emit VaultRegistryProposed(address(_vaultRegistry), newRegistry_);
    }

    /// @notice OF-15-004: Finalize the proposed VaultRegistry after FINALIZE_DELAY.
    function finalizeVaultRegistry() external onlyOwner {
        if (_pendingVaultRegistry == address(0)) revert NoPendingVaultRegistry();
        if (block.timestamp < uint256(_pendingVaultRegistryTimestamp) + _finalizeDelay()) {
            revert FinalizeDelayNotElapsed();
        }
        if (block.timestamp > uint256(_pendingVaultRegistryTimestamp) + PROPOSAL_EXPIRY) revert ProposalExpired();
        _requireVaultRegistryMatchesThisVault(_pendingVaultRegistry);
        _requireVaultRegistryInterface(_pendingVaultRegistry);

        address oldRegistry = address(_vaultRegistry);
        _vaultRegistry = IVaultRegistry(_pendingVaultRegistry);
        _pendingVaultRegistry = address(0);
        _pendingVaultRegistryTimestamp = 0;

        emit VaultRegistryUpdated(oldRegistry, address(_vaultRegistry));
    }

    /// @notice OF-15-004: Accept the pending VaultRegistry role. Only the pending registry can call.
    function acceptVaultRegistry() external {
        if (msg.sender != _pendingVaultRegistry) revert NotPendingVaultRegistry();
        if (block.timestamp < uint256(_pendingVaultRegistryTimestamp) + _finalizeDelay()) {
            revert FinalizeDelayNotElapsed();
        }
        if (block.timestamp > uint256(_pendingVaultRegistryTimestamp) + PROPOSAL_EXPIRY) revert ProposalExpired();
        _requireVaultRegistryMatchesThisVault(_pendingVaultRegistry);
        _requireVaultRegistryInterface(_pendingVaultRegistry);

        address oldRegistry = address(_vaultRegistry);
        _vaultRegistry = IVaultRegistry(_pendingVaultRegistry);
        _pendingVaultRegistry = address(0);
        _pendingVaultRegistryTimestamp = 0;

        emit VaultRegistryUpdated(oldRegistry, address(_vaultRegistry));
    }

    /// @notice OF-15-004: Clear a pending VaultRegistry proposal without finalizing.
    function clearPendingVaultRegistry() external onlyOwner {
        _pendingVaultRegistry = address(0);
        _pendingVaultRegistryTimestamp = 0;
    }

    function _requireVaultRegistryMatchesThisVault(address vaultRegistry_) private view {
        (bool ok, bytes memory data) =
            vaultRegistry_.staticcall(abi.encodeWithSelector(IVaultRegistryWiringQuery.riskusdVault.selector));
        if (!ok || data.length < 32) revert RISKUSDVaultMismatch();
        if (abi.decode(data, (address)) != address(this)) revert RISKUSDVaultMismatch();
    }

    function _requireVaultRegistryInterface(address vaultRegistry_) private view {
        if (vaultRegistry_.code.length == 0) revert InvalidVaultRegistryInterface(vaultRegistry_);
        (bool ok, bytes memory data) =
            vaultRegistry_.staticcall(abi.encodeWithSelector(IVaultRegistry.getAllVaults.selector));
        if (!ok || data.length < 64) revert InvalidVaultRegistryInterface(vaultRegistry_);
    }

    /// @notice OF-H02: setCustodian now only proposes — no instant effect.
    /// Use finalizeCustodian() or acceptCustodian() to complete the change.
    /// @dev OF-13-025/052: Emits CustodianSetByOwner (distinct from CustodianProposed via proposeCustodian).
    function setCustodian(address custodian_) external onlyOwner {
        if (custodian_ == address(0)) revert ZeroAddress();
        _pendingCustodian = custodian_;
        _custodianProposedAt = block.timestamp; // OF-002 (11th audit)
        emit CustodianSetByOwner(_custodian, custodian_);
    }

    /// @notice OF-H02: Owner-side finalization for custodian change (for contract recipients).
    function finalizeCustodian() external onlyOwner {
        if (_pendingCustodian == address(0)) revert ZeroAddress();
        if (block.timestamp < _custodianProposedAt + _finalizeDelay()) revert FinalizeDelayNotElapsed();
        if (block.timestamp > _custodianProposedAt + PROPOSAL_EXPIRY) revert ProposalExpired();
        address oldCustodian = _custodian;
        _custodian = _pendingCustodian;
        _pendingCustodian = address(0);
        _custodianProposedAt = 0;
        emit CustodianUpdated(oldCustodian, _custodian);
    }

    /// @notice OF-H02: setLossReporter now only proposes — no instant effect.
    /// Use finalizeLossReporter() or acceptLossReporter() to complete the change.
    /// @dev OF-13-025/052: Emits LossReporterSetByOwner (distinct from LossReporterProposed via proposeLossReporter).
    function setLossReporter(address lossReporter_) external onlyOwner {
        if (lossReporter_ == address(0)) revert ZeroAddress();
        _pendingLossReporter = lossReporter_;
        _lossReporterProposedAt = block.timestamp; // OF-002 (11th audit)
        emit LossReporterSetByOwner(_lossReporter, lossReporter_);
    }

    /// @notice OF-H02: Owner-side finalization for loss reporter change (for contract recipients).
    function finalizeLossReporter() external onlyOwner {
        if (_pendingLossReporter == address(0)) revert ZeroAddress();
        if (block.timestamp < _lossReporterProposedAt + _finalizeDelay()) revert FinalizeDelayNotElapsed();
        if (block.timestamp > _lossReporterProposedAt + PROPOSAL_EXPIRY) revert ProposalExpired();
        address oldReporter = _lossReporter;
        _lossReporter = _pendingLossReporter;
        _pendingLossReporter = address(0);
        _lossReporterProposedAt = 0;
        emit LossReporterUpdated(oldReporter, _lossReporter);
    }

    /// @notice OF-H02: Propose a new custodian (two-step handoff). Only owner can propose.
    function proposeCustodian(address newCustodian_) external onlyOwner {
        if (newCustodian_ == address(0)) revert ZeroAddress();
        _pendingCustodian = newCustodian_;
        _custodianProposedAt = block.timestamp; // OF-002 (11th audit)
        emit CustodianProposed(_custodian, newCustodian_);
    }

    /// @notice OF-H02: Accept the pending custodian role. Only the pending custodian can call.
    function acceptCustodian() external {
        if (msg.sender != _pendingCustodian) revert NotPendingCustodian();
        if (block.timestamp < _custodianProposedAt + _finalizeDelay()) revert FinalizeDelayNotElapsed();
        if (block.timestamp > _custodianProposedAt + PROPOSAL_EXPIRY) revert ProposalExpired();
        address oldCustodian = _custodian;
        _custodian = _pendingCustodian;
        _pendingCustodian = address(0);
        _custodianProposedAt = 0;
        emit CustodianUpdated(oldCustodian, _custodian);
    }

    /// @notice OF-H02: View the pending custodian address.
    function pendingCustodian() external view returns (address) {
        return _pendingCustodian;
    }

    /// @notice OF-H02: Clear the pending custodian to prevent stale proposals surviving UUPS upgrades.
    function clearPendingCustodian() external onlyOwner {
        _pendingCustodian = address(0);
        _custodianProposedAt = 0;
    }

    /// @notice OF-H02: Propose a new loss reporter (two-step handoff). Only owner can propose.
    function proposeLossReporter(address newLossReporter_) external onlyOwner {
        if (newLossReporter_ == address(0)) revert ZeroAddress();
        _pendingLossReporter = newLossReporter_;
        _lossReporterProposedAt = block.timestamp; // OF-002 (11th audit)
        emit LossReporterProposed(_lossReporter, newLossReporter_);
    }

    /// @notice OF-H02: Accept the pending loss reporter role. Only the pending loss reporter can call.
    function acceptLossReporter() external {
        if (msg.sender != _pendingLossReporter) revert NotPendingLossReporter();
        if (block.timestamp < _lossReporterProposedAt + _finalizeDelay()) revert FinalizeDelayNotElapsed();
        if (block.timestamp > _lossReporterProposedAt + PROPOSAL_EXPIRY) revert ProposalExpired();
        address oldReporter = _lossReporter;
        _lossReporter = _pendingLossReporter;
        _pendingLossReporter = address(0);
        _lossReporterProposedAt = 0;
        emit LossReporterUpdated(oldReporter, _lossReporter);
    }

    /// @notice OF-H02: View the pending loss reporter address.
    function pendingLossReporter() external view returns (address) {
        return _pendingLossReporter;
    }

    /// @notice OF-H02: Clear the pending loss reporter to prevent stale proposals surviving UUPS upgrades.
    function clearPendingLossReporter() external onlyOwner {
        _pendingLossReporter = address(0);
        _lossReporterProposedAt = 0;
    }

    modifier onlyEmergencyCapTightener() {
        if (msg.sender != owner() && msg.sender != _forageGovernor && !_isGuardianModule(msg.sender)) {
            revert UnauthorizedCapTightener(msg.sender);
        }
        _;
    }

    function setMaxDeploymentRatioBps(uint256 bps_) external onlyOwner {
        if (bps_ > 10000) revert InvalidDeploymentRatio();

        uint256 oldRatio = _maxDeploymentRatioBps;
        _maxDeploymentRatioBps = bps_;

        emit MaxDeploymentRatioUpdated(oldRatio, bps_);
    }

    function setWeeklyRedemptionCapBps(uint256 bps_) external onlyOwner {
        if (bps_ == 0 || bps_ > 10000) revert InvalidParameter();

        uint256 oldBps = _weeklyRedemptionCapBps;
        _weeklyRedemptionCapBps = bps_;

        emit WeeklyRedemptionCapBpsUpdated(oldBps, bps_);
    }

    function setWeeklyMintCapBps(uint256 bps_) external onlyOwner {
        if (bps_ > 20000) revert InvalidParameter();

        uint256 oldBps = _weeklyMintCapBps;
        _weeklyMintCapBps = bps_;

        emit WeeklyMintCapBpsUpdated(oldBps, bps_);
    }

    function setDailyMintCapBps(uint256 bps_) external onlyOwner {
        if (bps_ > 10000) revert InvalidParameter();

        uint256 oldBps = _dailyMintCapBps;
        _dailyMintCapBps = bps_;

        emit DailyMintCapBpsUpdated(oldBps, bps_);
    }

    function setDailyRedemptionCapBps(uint256 bps_) external onlyOwner {
        if (bps_ > 10000) revert InvalidParameter();

        uint256 oldBps = _dailyRedemptionCapBps;
        _dailyRedemptionCapBps = bps_;

        emit DailyRedemptionCapBpsUpdated(oldBps, bps_);
    }

    function setManualAttestationReporter(address reporter_) external onlyOwner {
        if (reporter_ == address(0)) revert ZeroAddress();
        _pendingManualAttestationReporter = reporter_;
        _manualAttestationReporterProposedAt = block.timestamp;
        emit ManualAttestationReporterProposed(_manualAttestationReporter, reporter_);
    }

    function finalizeManualAttestationReporter() external onlyOwner {
        if (_pendingManualAttestationReporter == address(0)) revert NoPendingManualAttestationReporter();
        if (block.timestamp < _manualAttestationReporterProposedAt + _finalizeDelay()) {
            revert FinalizeDelayNotElapsed();
        }
        if (block.timestamp > _manualAttestationReporterProposedAt + PROPOSAL_EXPIRY) revert ProposalExpired();
        address old = _manualAttestationReporter;
        _manualAttestationReporter = _pendingManualAttestationReporter;
        _pendingManualAttestationReporter = address(0);
        _manualAttestationReporterProposedAt = 0;
        emit ManualAttestationReporterUpdated(old, _manualAttestationReporter);
    }

    function acceptManualAttestationReporter() external {
        if (msg.sender != _pendingManualAttestationReporter) revert NotPendingManualAttestationReporter();
        if (block.timestamp < _manualAttestationReporterProposedAt + _finalizeDelay()) {
            revert FinalizeDelayNotElapsed();
        }
        if (block.timestamp > _manualAttestationReporterProposedAt + PROPOSAL_EXPIRY) revert ProposalExpired();
        address old = _manualAttestationReporter;
        _manualAttestationReporter = _pendingManualAttestationReporter;
        _pendingManualAttestationReporter = address(0);
        _manualAttestationReporterProposedAt = 0;
        emit ManualAttestationReporterUpdated(old, _manualAttestationReporter);
    }

    function clearPendingManualAttestationReporter() external onlyOwner {
        _pendingManualAttestationReporter = address(0);
        _manualAttestationReporterProposedAt = 0;
    }

    function setPerBlockMintCap(uint256 bps_, uint256 maxAmount_) external onlyOwner {
        if (bps_ == 0 || bps_ > 10000 || maxAmount_ == 0) revert InvalidParameter();

        uint256 oldBps = _perBlockMintCapBps;
        uint256 oldMax = _perBlockMintCapMax;
        _perBlockMintCapBps = bps_;
        _perBlockMintCapMax = maxAmount_;

        emit PerBlockMintCapUpdated(oldBps, bps_, oldMax, maxAmount_);
    }

    function setDeploymentBufferBps(uint256 bps_) external onlyOwner {
        if (bps_ > 10000) revert InvalidParameter();

        uint256 oldBps = _deploymentBufferBps;
        _deploymentBufferBps = bps_;

        emit DeploymentBufferBpsUpdated(oldBps, bps_);
    }

    /// @notice Emergency-only asymmetric cap control: guardians may shrink redemption flow immediately.
    /// @dev Widening still requires the owner/governance setter.
    function shrinkWeeklyRedemptionCapBps(uint256 bps_) external onlyEmergencyCapTightener {
        if (bps_ == 0) revert InvalidParameter();
        if (bps_ > _weeklyRedemptionCapBps) revert CapTighteningOnly();

        uint256 oldBps = _weeklyRedemptionCapBps;
        _weeklyRedemptionCapBps = bps_;

        emit WeeklyRedemptionCapBpsUpdated(oldBps, bps_);
    }

    /// @notice Emergency-only asymmetric cap control for public mint growth.
    /// @dev Allows zero so guardians can halt public deposits without blocking recovery-only accounting paths.
    function shrinkWeeklyMintCapBps(uint256 bps_) external onlyEmergencyCapTightener {
        if (bps_ > _weeklyMintCapBps) revert CapTighteningOnly();

        uint256 oldBps = _weeklyMintCapBps;
        _weeklyMintCapBps = bps_;

        emit WeeklyMintCapBpsUpdated(oldBps, bps_);
    }

    /// @notice Emergency-only asymmetric cap control for daily public mint growth.
    function shrinkDailyMintCapBps(uint256 bps_) external onlyEmergencyCapTightener {
        if (bps_ > _dailyMintCapBps) revert CapTighteningOnly();

        uint256 oldBps = _dailyMintCapBps;
        _dailyMintCapBps = bps_;

        emit DailyMintCapBpsUpdated(oldBps, bps_);
    }

    /// @notice Emergency-only asymmetric cap control for same-block public minting.
    /// @dev Both dimensions must tighten. Zero in either dimension halts public minting.
    function shrinkPerBlockMintCap(uint256 bps_, uint256 maxAmount_) external onlyEmergencyCapTightener {
        if (bps_ > _perBlockMintCapBps || maxAmount_ > _perBlockMintCapMax) revert CapTighteningOnly();

        uint256 oldBps = _perBlockMintCapBps;
        uint256 oldMax = _perBlockMintCapMax;
        _perBlockMintCapBps = bps_;
        _perBlockMintCapMax = maxAmount_;

        emit PerBlockMintCapUpdated(oldBps, bps_, oldMax, maxAmount_);
    }

    /// @notice Emergency-only asymmetric cap control for custodian deployment exposure.
    function tightenMaxDeploymentRatioBps(uint256 bps_) external onlyEmergencyCapTightener {
        if (bps_ > _maxDeploymentRatioBps || bps_ > 10000) revert CapTighteningOnly();

        uint256 oldRatio = _maxDeploymentRatioBps;
        _maxDeploymentRatioBps = bps_;

        emit MaxDeploymentRatioUpdated(oldRatio, bps_);
    }

    /// @notice Emergency-only asymmetric control that increases the retained deployment buffer.
    function tightenDeploymentBufferBps(uint256 bps_) external onlyEmergencyCapTightener {
        if (bps_ < _deploymentBufferBps || bps_ > 10000) revert CapTighteningOnly();

        uint256 oldBps = _deploymentBufferBps;
        _deploymentBufferBps = bps_;

        emit DeploymentBufferBpsUpdated(oldBps, bps_);
    }

    function setAttestationIntervalSeconds(uint256 interval_) external onlyOwner {
        if (interval_ < 1 hours || interval_ > 30 days) revert InvalidAttestationInterval();

        uint256 oldInterval = _attestationIntervalSeconds;
        _attestationIntervalSeconds = interval_;

        emit AttestationIntervalUpdated(oldInterval, interval_);
    }

    function setMinReserveRatioBps(uint256 bps_) external onlyOwner {
        if (bps_ > 10000) revert InvalidReserveRatio();

        uint256 oldRatio = _minReserveRatioBps;
        _minReserveRatioBps = bps_;

        emit MinReserveRatioUpdated(oldRatio, bps_);
    }

    /// @notice OF-15-005: setForageGovernor now only proposes — no instant effect.
    function setForageGovernor(address newGovernor_) external onlyOwner {
        if (newGovernor_ == address(0)) revert ZeroAddress();
        _pendingForageGovernor = newGovernor_;
        _pendingForageGovernorProposedAt = block.timestamp;
        emit ForageGovernorProposed(_forageGovernor, newGovernor_);
    }

    /// @notice OF-15-005: Finalize the proposed ForageGovernor after FINALIZE_DELAY.
    function finalizeForageGovernor() external onlyOwner {
        if (_pendingForageGovernor == address(0)) revert NoPendingForageGovernor();
        if (block.timestamp < _pendingForageGovernorProposedAt + _finalizeDelay()) revert FinalizeDelayNotElapsed();
        if (block.timestamp > _pendingForageGovernorProposedAt + PROPOSAL_EXPIRY) revert ProposalExpired();
        address old = _forageGovernor;
        _forageGovernor = _pendingForageGovernor;
        _pendingForageGovernor = address(0);
        _pendingForageGovernorProposedAt = 0;
        emit ForageGovernorSet(old, _forageGovernor);
    }

    function clearPendingForageGovernor() external onlyOwner {
        _pendingForageGovernor = address(0);
        _pendingForageGovernorProposedAt = 0;
    }

    function setBlocklist(address blocklist_) external onlyOwner {
        if (blocklist_ == address(0)) revert ZeroAddress();
        _requireValidBlocklist(blocklist_);
        address oldBlocklist = _blocklist;
        _blocklist = blocklist_;
        emit BlocklistSet(oldBlocklist, blocklist_);
    }

    // OF-19-002: owner, governor, or guardian module can pause/unpause
    function pause() external {
        if (msg.sender != owner() && msg.sender != _forageGovernor && !_isGuardianModule(msg.sender)) {
            revert UnauthorizedPauseControl(msg.sender);
        }
        _pause();
    }

    function unpause() external {
        if (msg.sender != owner() && msg.sender != _forageGovernor && !_isGuardianModule(msg.sender)) {
            revert UnauthorizedPauseControl(msg.sender);
        }
        _unpause();
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
            effectiveSupply = _lastMintActiveSupply > 0 ? _min(_lastMintActiveSupply, currentSupply) : currentSupply;
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
            effectiveSupply =
                _lastDailyMintActiveSupply > 0 ? _min(_lastDailyMintActiveSupply, currentSupply) : currentSupply;
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

    function _clearLossPendingAndNotifyRegistry() internal {
        _lossPendingVaultId = 0; // OF-14-001: clear vault binding
        _lossPending = false;
        _lastLossResolutionBlock = block.number;
        // OF-16-002/OF-19-003: Notify VaultRegistry for wind-down cooldown tracking.
        if (address(_vaultRegistry) != address(0)) {
            try _vaultRegistry.notifyLossResolved() {}
            catch {
                revert LossResolutionNotificationFailed(address(_vaultRegistry));
            }
        }
    }

    function _lossPendingActive() internal view returns (bool) {
        return
            _lossPending || _hasUnresolvedAttestedLoss() || _custodianNAVUnavailableOrStale()
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

    function _pendingLossVaultIdForBinding() internal view returns (uint256) {
        if (_hasOpenAttestedLossNonce()) return _latestLossVaultId;
        return _lossPendingVaultId;
    }

    function _requireActiveVault(uint256 vaultId) internal view {
        if (address(_vaultRegistry) != address(0)) {
            VaultConfig memory vc = _vaultRegistry.getVault(vaultId);
            if (vc.status != VaultStatus.Active) revert VaultNotActive();
        }
    }

    function _normalizeManualCustodianNAV(uint256 vaultId, uint256 nav, uint256 lossNonce)
        internal
        view
        returns (bool shouldRecord, uint256 normalizedNav)
    {
        address custodian_ = _custodian;
        if (custodian_.code.length == 0) revert ManualAttestationNormalizationFailed(custodian_);

        (bool ok, bytes memory data) = custodian_.staticcall(
            abi.encodeCall(IManualCustodianNAVNormalizer.normalizeManualCustodianNAV, (vaultId, nav, lossNonce))
        );
        if (!ok || data.length < 64) revert ManualAttestationNormalizationFailed(custodian_);

        return abi.decode(data, (bool, uint256));
    }

    /// @dev OF-002: Safe depositor USDC computation with underflow protection.
    /// Returns 0 when outflows exceed inflows (high-loss scenario) instead of panicking.
    /// OF-18-007: Include _totalReplenished in inflows so replenished capital is redeployable.
    function _safeDepositorUsdc() internal view returns (uint256) {
        uint256 inflows = _totalDeposited + _totalReplenished;
        uint256 outflows = _totalRedeemed + _totalBurnedForLoss + _totalAcknowledgedLoss;
        return inflows > outflows ? inflows - outflows : 0;
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
            _weeklyMintWindowStartSupply =
                _lastMintActiveSupply > 0 ? _min(_lastMintActiveSupply, cachedTotalSupply) : cachedTotalSupply;
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

        _lastMintActiveSupply = (_lastMintActiveSupply > 0 && _lastMintActiveSupply < cachedTotalSupply)
            ? _lastMintActiveSupply
            : cachedTotalSupply;
    }

    function _enforceDailyMintCap(uint256 riskusdAmount) internal {
        uint256 cachedTotalSupply = _riskusd.totalSupply();

        if (block.timestamp >= _dailyMintWindowStart + DAILY_WINDOW) {
            _dailyMintUsed = 0;
            uint256 elapsed = (block.timestamp - _dailyMintWindowStart) / DAILY_WINDOW;
            _dailyMintWindowStart += elapsed * DAILY_WINDOW;
            _dailyMintWindowStartSupply = _lastDailyMintActiveSupply > 0
                ? _min(_lastDailyMintActiveSupply, cachedTotalSupply)
                : cachedTotalSupply;
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

        _lastDailyMintActiveSupply = (_lastDailyMintActiveSupply > 0 && _lastDailyMintActiveSupply < cachedTotalSupply)
            ? _lastDailyMintActiveSupply
            : cachedTotalSupply;
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
        _weeklyMintWindowStartSupply =
            _weeklyMintWindowStartSupply > riskusdAmount ? _weeklyMintWindowStartSupply - riskusdAmount : 0;
        _lastMintActiveSupply = _lastMintActiveSupply > riskusdAmount ? _lastMintActiveSupply - riskusdAmount : 0;
        _dailyMintWindowStartSupply =
            _dailyMintWindowStartSupply > riskusdAmount ? _dailyMintWindowStartSupply - riskusdAmount : 0;
        _lastDailyMintActiveSupply =
            _lastDailyMintActiveSupply > riskusdAmount ? _lastDailyMintActiveSupply - riskusdAmount : 0;
    }

    function _enforceDeploymentBuffer(uint256 additionalDeployment) internal view {
        if (_deploymentBufferBps == 0) return;
        if (address(_vaultRegistry) == address(0)) revert VaultRegistryRequired();

        uint256 activeTierAssets = _activeRegisteredTierAssets();
        uint256 maxTotalDeployment = activeTierAssets * (10000 - _deploymentBufferBps) / 10000;
        if (_totalDeployed + additionalDeployment > maxTotalDeployment) revert DeploymentBufferExceeded();
    }

    function _activeRegisteredTierAssets() internal view returns (uint256 assets) {
        uint256[] memory vaultIds = _vaultRegistry.getAllVaults();
        uint256 limit = vaultIds.length < DEPLOYMENT_BUFFER_SCAN_LIMIT ? vaultIds.length : DEPLOYMENT_BUFFER_SCAN_LIMIT;
        for (uint256 i; i < limit;) {
            try _vaultRegistry.getVault(vaultIds[i]) returns (VaultConfig memory vc) {
                if (vc.status == VaultStatus.Active) {
                    for (uint256 j; j < 4;) {
                        address tierVault = vc.tierVaults[j];
                        if (tierVault != address(0)) {
                            try IERC4626TotalAssets(tierVault).totalAssets() returns (uint256 tierAssets) {
                                assets += tierAssets;
                            } catch {}
                        }
                        unchecked {
                            ++j;
                        }
                    }
                }
            } catch {}
            unchecked {
                ++i;
            }
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
    function proposeTokenRescue(address token, uint256 amount, address recipient) external onlyOwner {
        _stageRescue(token, recipient, amount, uint64(block.timestamp));
    }

    function _stageRescue(address token, address recipient, uint256 amount, uint64 proposedAt) internal {
        _requireRescuableToken(token);
        if (amount == 0) revert ZeroAmount();
        if (recipient == address(0)) revert ZeroAddress();
        _requireNotBlocked(recipient);

        uint256 readyAt = uint256(proposedAt) + TOKEN_RESCUE_DELAY;
        _pendingTokenRescues[token] = PendingTokenRescue({amount: amount, readyAt: readyAt, recipient: recipient});
        emit TokenRescueProposed(token, amount, recipient, readyAt);
    }

    /// @notice Execute a staged stranded-token rescue after the one-day announcement delay.
    /// @dev Intentionally remains owner-only and blocklist-checked at execution time.
    function executeTokenRescue(address token) external onlyOwner nonReentrant {
        _requireRescuableToken(token);
        PendingTokenRescue memory pending = _pendingTokenRescues[token];
        if (pending.readyAt == 0) revert InvalidState();
        if (block.timestamp < pending.readyAt) revert RescueDelayNotElapsed(pending.readyAt);
        _requireNotBlocked(pending.recipient);

        delete _pendingTokenRescues[token];
        _transferRescueToken(token, pending.amount, pending.recipient);
    }

    // --- Ownership ---

    function renounceOwnership() public pure override {
        revert RenounceOwnershipDisabled();
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

    function _requireRescuableToken(address token) internal view {
        if (token == address(0)) revert ZeroAddress();
        if (token == address(_usdc)) revert InvalidParameter();
        if (token == address(_riskusd)) revert InvalidParameter();
    }

    function _transferRescueToken(address token, uint256 amount, address recipient) internal {
        _requireNotBlocked(recipient);
        IERC20(token).safeTransfer(recipient, amount);
        emit TokenRescued(token, amount, recipient);
    }

    function _requireNotBlocked(address account) internal view {
        address blocklist_ = _blocklist;
        if (blocklist_ != address(0) && IBlocklist(blocklist_).isBlocked(account)) {
            revert BlockedAddress(account);
        }
    }

    function _requireValidBlocklist(address blocklist_) internal view {
        if (blocklist_.code.length == 0) revert InvalidBlocklist(blocklist_);
        (bool ok, bytes memory data) =
            blocklist_.staticcall(abi.encodeWithSelector(IBlocklist.isBlocked.selector, address(0)));
        if (!ok || data.length < 32) revert InvalidBlocklist(blocklist_);
    }
}
