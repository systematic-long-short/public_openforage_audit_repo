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
import "../interfaces/IVaultRegistry.sol";
import "../IForageGovernorPause.sol";
import "../FinalizeDelayProfile.sol";
import "../interfaces/IBlocklist.sol";
import "../interfaces/IAllowlist.sol";
import "../AllowlistGatedUpgradeable.sol";
import "../RISKUSDVault.sol";

/// @title RISKUSDVaultModule - delegatecall target for RISKUSDVault's admin, NAV, loss,
///        vault-registry and rescue cluster.
/// @notice Each moved function mirrors its selector and body; the vault's forwarder runs the
///         caller gate exactly once before delegating here, so no moved function repeats it.
/// @dev The module inherits the vault's bases and repeats its linear state declarations in the
///      same order, because a delegatecall reads and writes the vault's storage. It declares no
///      storage of its own. Direct calls are rejected so the module can never run standalone.
contract RISKUSDVaultModule is
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
    error DirectCallForbidden();

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
    bytes4 internal constant GET_ACTIVE_VAULTS_PAGE_SELECTOR =
        bytes4(keccak256("getActiveVaultsPage(uint256,uint256)"));

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

    address private immutable _SELF;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _SELF = address(this);
    }

    modifier onlyDelegateCall() {
        if (address(this) == _SELF) revert DirectCallForbidden();
        _;
    }

    /// @dev The module is delegated to, never proxied; its own upgrade entry point stays owner-gated.
    function _authorizeUpgrade(address) internal override onlyOwner {
        _pendingCustodian = address(0);
        _pendingLossReporter = address(0);
        _custodianProposedAt = 0;
        _lossReporterProposedAt = 0;
        _pendingVaultRegistry = address(0);
        _pendingVaultRegistryTimestamp = 0;
        _pendingForageGovernor = address(0);
        _pendingForageGovernorProposedAt = 0;
        _pendingManualAttestationReporter = address(0);
        _manualAttestationReporterProposedAt = 0;
    }

    // --- Moved Functions ---

    function deployCapital(uint256 usdcAmount) external onlyDelegateCall    {
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

    function recordCustodianNAV(uint256 nav) external onlyDelegateCall  {
        if (msg.sender != _custodian) revert UnauthorizedCustodian();
        if (_custodian == address(0)) revert UnauthorizedCustodian();
        _requireNotBlocked(msg.sender);

        _recordCustodianNAV(0, nav, 0, block.timestamp);
    }

    function recordCustodianNAV(uint256 vaultId, uint256 nav, uint256 lossNonce) external onlyDelegateCall  {
        if (msg.sender != _custodian) revert UnauthorizedCustodian();
        if (_custodian == address(0)) revert UnauthorizedCustodian();
        _requireNotBlocked(msg.sender);

        _recordCustodianNAV(vaultId, nav, lossNonce, block.timestamp);
    }

    function recordCustodianNAV(uint256 vaultId, uint256 nav, uint256 lossNonce, uint256 observedAt)
        external onlyDelegateCall
    {
        if (msg.sender != _custodian) revert UnauthorizedCustodian();
        if (_custodian == address(0)) revert UnauthorizedCustodian();
        _requireNotBlocked(msg.sender);
        if (observedAt == 0 || observedAt > block.timestamp) revert InvalidParameter();

        _recordCustodianNAV(vaultId, nav, lossNonce, observedAt);
    }

    function recordManualCustodianNAV(uint256 vaultId, uint256 nav, uint256 lossNonce) external onlyDelegateCall  {
        if (msg.sender != _manualAttestationReporter) revert UnauthorizedManualAttestationReporter();
        if (_manualAttestationReporter == address(0)) revert UnauthorizedManualAttestationReporter();
        _requireNotBlocked(msg.sender);

        (bool shouldRecord, uint256 normalizedNav) = _normalizeManualCustodianNAV(vaultId, nav, lossNonce);
        if (!shouldRecord) {
            emit ManualCustodianNAVDeferred(vaultId, nav, lossNonce, _custodian);
            return;
        }

        nav = normalizedNav;
        _recordCustodianNAV(vaultId, nav, lossNonce, block.timestamp);
    }

    function burnForLoss(uint256 vaultId, uint256 riskusdAmount) external onlyDelegateCall   {
        _burnForLoss(vaultId, riskusdAmount, 0);
    }

    function coverAndBurnForLoss(uint256 vaultId, uint256 riskusdAmount, uint256 coverUsdcAmount)
        external onlyDelegateCall
    {
        _burnForLoss(vaultId, riskusdAmount, coverUsdcAmount);
    }

    function replenish(uint256 usdcAmount) external onlyDelegateCall   {
        if (msg.sender != _lossReporter) revert UnauthorizedLossReporter();
        if (usdcAmount == 0) revert ZeroAmount();
        _requireNotBlocked(msg.sender);

        // Update state (CEI)
        _totalReplenished += usdcAmount;

        // Pull USDC from lossReporter
        _usdc.safeTransferFrom(msg.sender, address(this), usdcAmount);

        emit Replenished(usdcAmount);
    }

    function finalizeAttestedLoss(uint256 vaultId, uint256 lossNonce, uint256 amount) external onlyDelegateCall  {
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

    function initializeV2(address vaultRegistry_) external onlyDelegateCall    {
        if (vaultRegistry_ == address(0)) revert ZeroAddress();
        _requireVaultRegistryMatchesThisVault(vaultRegistry_);
        _requireVaultRegistryInterface(vaultRegistry_);
        _vaultRegistry = IVaultRegistry(vaultRegistry_);
        emit VaultRegistryUpdated(address(0), vaultRegistry_);
    }

    function proposeVaultRegistry(address newRegistry_) external onlyDelegateCall   {
        if (newRegistry_ == address(0)) revert ZeroAddress();
        _pendingVaultRegistry = newRegistry_;
        _pendingVaultRegistryTimestamp = uint48(block.timestamp);
        emit VaultRegistryProposed(address(_vaultRegistry), newRegistry_);
    }

    function finalizeVaultRegistry() external onlyDelegateCall   {
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

    function acceptVaultRegistry() external onlyDelegateCall  {
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

    function clearPendingVaultRegistry() external onlyDelegateCall   {
        _pendingVaultRegistry = address(0);
        _pendingVaultRegistryTimestamp = 0;
    }

    function setCustodian(address custodian_) external onlyDelegateCall   {
        if (custodian_ == address(0)) revert ZeroAddress();
        _pendingCustodian = custodian_;
        _custodianProposedAt = block.timestamp; // OF-002 (11th audit)
        emit CustodianSetByOwner(_custodian, custodian_);
    }

    function finalizeCustodian() external onlyDelegateCall   {
        if (_pendingCustodian == address(0)) revert ZeroAddress();
        if (block.timestamp < _custodianProposedAt + _finalizeDelay()) revert FinalizeDelayNotElapsed();
        if (block.timestamp > _custodianProposedAt + PROPOSAL_EXPIRY) revert ProposalExpired();
        address oldCustodian = _custodian;
        _custodian = _pendingCustodian;
        _pendingCustodian = address(0);
        _custodianProposedAt = 0;
        emit CustodianUpdated(oldCustodian, _custodian);
    }

    function setLossReporter(address lossReporter_) external onlyDelegateCall   {
        if (lossReporter_ == address(0)) revert ZeroAddress();
        _pendingLossReporter = lossReporter_;
        _lossReporterProposedAt = block.timestamp; // OF-002 (11th audit)
        emit LossReporterSetByOwner(_lossReporter, lossReporter_);
    }

    function finalizeLossReporter() external onlyDelegateCall   {
        if (_pendingLossReporter == address(0)) revert ZeroAddress();
        if (block.timestamp < _lossReporterProposedAt + _finalizeDelay()) revert FinalizeDelayNotElapsed();
        if (block.timestamp > _lossReporterProposedAt + PROPOSAL_EXPIRY) revert ProposalExpired();
        address oldReporter = _lossReporter;
        _lossReporter = _pendingLossReporter;
        _pendingLossReporter = address(0);
        _lossReporterProposedAt = 0;
        emit LossReporterUpdated(oldReporter, _lossReporter);
    }

    function proposeCustodian(address newCustodian_) external onlyDelegateCall   {
        if (newCustodian_ == address(0)) revert ZeroAddress();
        _pendingCustodian = newCustodian_;
        _custodianProposedAt = block.timestamp; // OF-002 (11th audit)
        emit CustodianProposed(_custodian, newCustodian_);
    }

    function acceptCustodian() external onlyDelegateCall  {
        if (msg.sender != _pendingCustodian) revert NotPendingCustodian();
        if (block.timestamp < _custodianProposedAt + _finalizeDelay()) revert FinalizeDelayNotElapsed();
        if (block.timestamp > _custodianProposedAt + PROPOSAL_EXPIRY) revert ProposalExpired();
        address oldCustodian = _custodian;
        _custodian = _pendingCustodian;
        _pendingCustodian = address(0);
        _custodianProposedAt = 0;
        emit CustodianUpdated(oldCustodian, _custodian);
    }

    function clearPendingCustodian() external onlyDelegateCall   {
        _pendingCustodian = address(0);
        _custodianProposedAt = 0;
    }

    function proposeLossReporter(address newLossReporter_) external onlyDelegateCall   {
        if (newLossReporter_ == address(0)) revert ZeroAddress();
        _pendingLossReporter = newLossReporter_;
        _lossReporterProposedAt = block.timestamp; // OF-002 (11th audit)
        emit LossReporterProposed(_lossReporter, newLossReporter_);
    }

    function acceptLossReporter() external onlyDelegateCall  {
        if (msg.sender != _pendingLossReporter) revert NotPendingLossReporter();
        if (block.timestamp < _lossReporterProposedAt + _finalizeDelay()) revert FinalizeDelayNotElapsed();
        if (block.timestamp > _lossReporterProposedAt + PROPOSAL_EXPIRY) revert ProposalExpired();
        address oldReporter = _lossReporter;
        _lossReporter = _pendingLossReporter;
        _pendingLossReporter = address(0);
        _lossReporterProposedAt = 0;
        emit LossReporterUpdated(oldReporter, _lossReporter);
    }

    function clearPendingLossReporter() external onlyDelegateCall   {
        _pendingLossReporter = address(0);
        _lossReporterProposedAt = 0;
    }

    function setMaxDeploymentRatioBps(uint256 bps_) external onlyDelegateCall   {
        if (bps_ > 10000) revert InvalidDeploymentRatio();

        uint256 oldRatio = _maxDeploymentRatioBps;
        _maxDeploymentRatioBps = bps_;

        emit MaxDeploymentRatioUpdated(oldRatio, bps_);
    }

    function setWeeklyRedemptionCapBps(uint256 bps_) external onlyDelegateCall   {
        if (bps_ == 0 || bps_ > 10000) revert InvalidParameter();

        uint256 oldBps = _weeklyRedemptionCapBps;
        _weeklyRedemptionCapBps = bps_;

        emit WeeklyRedemptionCapBpsUpdated(oldBps, bps_);
    }

    function setWeeklyMintCapBps(uint256 bps_) external onlyDelegateCall   {
        if (bps_ > 20000) revert InvalidParameter();

        uint256 oldBps = _weeklyMintCapBps;
        _weeklyMintCapBps = bps_;

        emit WeeklyMintCapBpsUpdated(oldBps, bps_);
    }

    function setDailyMintCapBps(uint256 bps_) external onlyDelegateCall   {
        if (bps_ > 10000) revert InvalidParameter();

        uint256 oldBps = _dailyMintCapBps;
        _dailyMintCapBps = bps_;

        emit DailyMintCapBpsUpdated(oldBps, bps_);
    }

    function setDailyRedemptionCapBps(uint256 bps_) external onlyDelegateCall   {
        if (bps_ > 10000) revert InvalidParameter();

        uint256 oldBps = _dailyRedemptionCapBps;
        _dailyRedemptionCapBps = bps_;

        emit DailyRedemptionCapBpsUpdated(oldBps, bps_);
    }

    function setManualAttestationReporter(address reporter_) external onlyDelegateCall   {
        if (reporter_ == address(0)) revert ZeroAddress();
        _pendingManualAttestationReporter = reporter_;
        _manualAttestationReporterProposedAt = block.timestamp;
        emit ManualAttestationReporterProposed(_manualAttestationReporter, reporter_);
    }

    function finalizeManualAttestationReporter() external onlyDelegateCall   {
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

    function acceptManualAttestationReporter() external onlyDelegateCall  {
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

    function clearPendingManualAttestationReporter() external onlyDelegateCall   {
        _pendingManualAttestationReporter = address(0);
        _manualAttestationReporterProposedAt = 0;
    }

    function setPerBlockMintCap(uint256 bps_, uint256 maxAmount_) external onlyDelegateCall   {
        if (bps_ == 0 || bps_ > 10000 || maxAmount_ == 0) revert InvalidParameter();

        uint256 oldBps = _perBlockMintCapBps;
        uint256 oldMax = _perBlockMintCapMax;
        _perBlockMintCapBps = bps_;
        _perBlockMintCapMax = maxAmount_;

        emit PerBlockMintCapUpdated(oldBps, bps_, oldMax, maxAmount_);
    }

    function setDeploymentBufferBps(uint256 bps_) external onlyDelegateCall   {
        if (bps_ > 10000) revert InvalidParameter();

        uint256 oldBps = _deploymentBufferBps;
        _deploymentBufferBps = bps_;

        emit DeploymentBufferBpsUpdated(oldBps, bps_);
    }

    function setSuspectedLossFreeze(bool frozen) external onlyDelegateCall  {
        if (msg.sender != owner() && msg.sender != _forageGovernor && !_isGuardianModule(msg.sender)) {
            revert UnauthorizedPauseControl(msg.sender);
        }
        if (!frozen && msg.sender != owner() && msg.sender != _forageGovernor) revert CapTighteningOnly();
        _suspectedLossFreeze = frozen;
        emit SuspectedLossFreezeSet(frozen);
    }

    function shrinkWeeklyRedemptionCapBps(uint256 bps_) external onlyDelegateCall   {
        if (bps_ == 0) revert InvalidParameter();
        if (bps_ > _weeklyRedemptionCapBps) revert CapTighteningOnly();

        uint256 oldBps = _weeklyRedemptionCapBps;
        _weeklyRedemptionCapBps = bps_;

        emit WeeklyRedemptionCapBpsUpdated(oldBps, bps_);
    }

    function shrinkWeeklyMintCapBps(uint256 bps_) external onlyDelegateCall   {
        if (bps_ > _weeklyMintCapBps) revert CapTighteningOnly();

        uint256 oldBps = _weeklyMintCapBps;
        _weeklyMintCapBps = bps_;

        emit WeeklyMintCapBpsUpdated(oldBps, bps_);
    }

    function shrinkDailyMintCapBps(uint256 bps_) external onlyDelegateCall   {
        if (bps_ > _dailyMintCapBps) revert CapTighteningOnly();

        uint256 oldBps = _dailyMintCapBps;
        _dailyMintCapBps = bps_;

        emit DailyMintCapBpsUpdated(oldBps, bps_);
    }

    function shrinkPerBlockMintCap(uint256 bps_, uint256 maxAmount_)
        external onlyDelegateCall
    {
        if (bps_ > _perBlockMintCapBps || maxAmount_ > _perBlockMintCapMax) {
            revert CapTighteningOnly();
        }

        uint256 oldBps = _perBlockMintCapBps;
        uint256 oldMax = _perBlockMintCapMax;
        _perBlockMintCapBps = bps_;
        _perBlockMintCapMax = maxAmount_;

        emit PerBlockMintCapUpdated(oldBps, bps_, oldMax, maxAmount_);
    }

    function tightenMaxDeploymentRatioBps(uint256 bps_) external onlyDelegateCall   {
        if (bps_ > _maxDeploymentRatioBps || bps_ > 10000) revert CapTighteningOnly();

        uint256 oldRatio = _maxDeploymentRatioBps;
        _maxDeploymentRatioBps = bps_;

        emit MaxDeploymentRatioUpdated(oldRatio, bps_);
    }

    function tightenDeploymentBufferBps(uint256 bps_) external onlyDelegateCall   {
        if (bps_ < _deploymentBufferBps || bps_ > 10000) revert CapTighteningOnly();

        uint256 oldBps = _deploymentBufferBps;
        _deploymentBufferBps = bps_;

        emit DeploymentBufferBpsUpdated(oldBps, bps_);
    }

    function setAttestationIntervalSeconds(uint256 interval_) external onlyDelegateCall   {
        if (interval_ < 1 hours || interval_ > 30 days) revert InvalidAttestationInterval();

        uint256 oldInterval = _attestationIntervalSeconds;
        _attestationIntervalSeconds = interval_;

        emit AttestationIntervalUpdated(oldInterval, interval_);
    }

    function setMinReserveRatioBps(uint256 bps_) external onlyDelegateCall   {
        if (bps_ > 10000) revert InvalidReserveRatio();

        uint256 oldRatio = _minReserveRatioBps;
        _minReserveRatioBps = bps_;

        emit MinReserveRatioUpdated(oldRatio, bps_);
    }

    function setForageGovernor(address newGovernor_) external onlyDelegateCall   {
        if (newGovernor_ == address(0)) revert ZeroAddress();
        _pendingForageGovernor = newGovernor_;
        _pendingForageGovernorProposedAt = block.timestamp;
        emit ForageGovernorProposed(_forageGovernor, newGovernor_);
    }

    function finalizeForageGovernor() external onlyDelegateCall   {
        if (_pendingForageGovernor == address(0)) revert NoPendingForageGovernor();
        if (block.timestamp < _pendingForageGovernorProposedAt + _finalizeDelay()) revert FinalizeDelayNotElapsed();
        if (block.timestamp > _pendingForageGovernorProposedAt + PROPOSAL_EXPIRY) revert ProposalExpired();
        address old = _forageGovernor;
        _forageGovernor = _pendingForageGovernor;
        _pendingForageGovernor = address(0);
        _pendingForageGovernorProposedAt = 0;
        emit ForageGovernorSet(old, _forageGovernor);
    }

    function clearPendingForageGovernor() external onlyDelegateCall   {
        _pendingForageGovernor = address(0);
        _pendingForageGovernorProposedAt = 0;
    }

    function setBlocklist(address blocklist_) external onlyDelegateCall   {
        if (blocklist_ == address(0)) revert ZeroAddress();
        _requireValidBlocklist(blocklist_);
        address oldBlocklist = _blocklist;
        _blocklist = blocklist_;
        emit BlocklistSet(oldBlocklist, blocklist_);
    }

    function setMinimumFirstDeposit(uint8 basis, uint256 amount) external onlyDelegateCall   {
        _minimumFirstDeposit[basis] = amount;
    }

    function pause() external onlyDelegateCall  {
        if (msg.sender != owner() && msg.sender != _forageGovernor && !_isGuardianModule(msg.sender)) {
            revert UnauthorizedPauseControl(msg.sender);
        }
        _pause();
    }

    function unpause() external onlyDelegateCall  {
        if (msg.sender != owner() && msg.sender != _forageGovernor && !_isGuardianModule(msg.sender)) {
            revert UnauthorizedPauseControl(msg.sender);
        }
        _unpause();
    }

    function proposeTokenRescue(address token, uint256 amount, address recipient) external onlyDelegateCall   {
        _stageRescue(token, recipient, amount, uint64(block.timestamp));
    }

    function executeTokenRescue(address token) external onlyDelegateCall    {
        _requireRescuableToken(token);
        PendingTokenRescue memory pending = _pendingTokenRescues[token];
        if (pending.readyAt == 0) revert InvalidState();
        if (block.timestamp < pending.readyAt) revert RescueDelayNotElapsed(pending.readyAt);
        _requireNotBlocked(pending.recipient);

        delete _pendingTokenRescues[token];
        _transferRescueToken(token, pending.amount, pending.recipient);
    }

    // --- Copied Helpers (shared with the vault or moved with the callers) ---

    function _recordCustodianNAV(uint256 vaultId, uint256 nav, uint256 lossNonce, uint256 observedAt) internal {
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
        _lastAttestationTimestamp = observedAt;
        _deployedSinceLastAttestation = 0;
        _returnedSinceLastAttestation = 0;
        if (_suspectedLossFreeze && nav >= _totalDeployed) {
            _suspectedLossFreeze = false;
            emit SuspectedLossFreezeSet(false);
        }

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
            emit CustodianNAVAttested(vaultId, nav, lossNonce, observedAt);
        }

        if (hadLossToResolve && !_lossPendingActive()) {
            _clearLossPendingAndNotifyRegistry();
        }

        emit CustodianNAVRecorded(nav, observedAt);
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
        // Mirror OF-I06 on the daily redemption basis: a burn inside the current daily window
        // must not leave the daily cap computed from stale (pre-burn) supply either.
        if (block.timestamp < _dailyRedemptionWindowStart + DAILY_WINDOW && _dailyRedemptionWindowStartSupply > 0) {
            _dailyRedemptionWindowStartSupply = _dailyRedemptionWindowStartSupply >= riskusdAmount
                ? _dailyRedemptionWindowStartSupply - riskusdAmount
                : 0;
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

    function _requireVaultRegistryMatchesThisVault(address vaultRegistry_) private view {
        (bool ok, bytes memory data) =
            vaultRegistry_.staticcall(abi.encodeWithSelector(IVaultRegistryWiringQuery.riskusdVault.selector));
        if (!ok || data.length < 32) revert RISKUSDVaultMismatch();
        if (abi.decode(data, (address)) == address(this)) return;

        (ok, data) =
            vaultRegistry_.staticcall(abi.encodeWithSelector(IVaultRegistryWiringQuery.pendingRISKUSDVault.selector));
        if (!ok || data.length < 32) revert RISKUSDVaultMismatch();
        if (abi.decode(data, (address)) != address(this)) revert RISKUSDVaultMismatch();
    }

    function _requireVaultRegistryInterface(address vaultRegistry_) private view {
        if (vaultRegistry_.code.length == 0) revert InvalidVaultRegistryInterface(vaultRegistry_);
        (bool ok, bytes memory data) =
            vaultRegistry_.staticcall(abi.encodeWithSelector(IVaultRegistry.getVaultsPage.selector, 0, 1));
        if (!ok || data.length < 96) revert InvalidVaultRegistryInterface(vaultRegistry_);
    }

    function _isGuardianModule(address caller) internal view returns (bool) {
        if (_forageGovernor == address(0) || _forageGovernor.code.length == 0) return false;
        try IForageGovernorPause(_forageGovernor).guardianModule() returns (address gm) {
            return caller == gm && gm != address(0);
        } catch {
            return false;
        }
    }

    function vaultUsdcBalance() internal view returns (uint256) {
        return IERC20(_usdc).balanceOf(address(this));
    }

    function adjustedCustodianNAV() internal view returns (uint256) {
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

    function _clearLossPendingAndNotifyRegistry() internal {
        if (_latestLossVaultId != 0) {
            if (_latestLossNonce > _settledLossNonce) {
                _settledLossNonce = _latestLossNonce;
            }
            _latestLossVaultId = 0;
            _latestLossAmount = 0;
        }
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

    function _pendingLossVaultIdForBinding() internal view returns (uint256) {
        if (_hasUnresolvedAttestedLoss()) return _latestLossVaultId;
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

    function _enforceDeploymentBuffer(uint256 additionalDeployment) internal view {
        if (_deploymentBufferBps == 0) return;
        if (address(_vaultRegistry) == address(0)) revert VaultRegistryRequired();

        uint256 activeTierAssets = _activeRegisteredTierAssets();
        uint256 maxTotalDeployment = activeTierAssets * (10000 - _deploymentBufferBps) / 10000;
        if (_totalDeployed + additionalDeployment > maxTotalDeployment) revert DeploymentBufferExceeded();
    }

    function _activeRegisteredTierAssets() internal view returns (uint256 assets) {
        (bool usedActivePagination, uint256 activeAssets) = _activeRegisteredTierAssetsFromActivePages();
        if (usedActivePagination) return activeAssets;

        return _activeRegisteredTierAssetsFromHistoricalPages();
    }

    function _activeRegisteredTierAssetsFromActivePages()
        internal
        view
        returns (bool usedActivePagination, uint256 assets)
    {
        uint256 offset = 0;
        uint256 pageLimit = DEPLOYMENT_BUFFER_SCAN_LIMIT;
        while (true) {
            (bool ok, bytes memory data) = address(_vaultRegistry)
                .staticcall(abi.encodeWithSelector(GET_ACTIVE_VAULTS_PAGE_SELECTOR, offset, pageLimit));
            if (!ok) return (false, 0);

            usedActivePagination = true;
            (uint256[] memory vaultIds, uint256 nextOffset, uint256 total) =
                abi.decode(data, (uint256[], uint256, uint256));
            if (vaultIds.length == 0) break;
            for (uint256 i; i < vaultIds.length;) {
                assets += _activeVaultTierAssets(vaultIds[i]);
                unchecked {
                    ++i;
                }
            }
            if (nextOffset >= total || nextOffset <= offset) break;
            offset = nextOffset;
        }
    }

    function _activeRegisteredTierAssetsFromHistoricalPages() internal view returns (uint256 assets) {
        uint256 offset = 0;
        uint256 pageLimit = DEPLOYMENT_BUFFER_SCAN_LIMIT;
        while (true) {
            try _vaultRegistry.getVaultsPage(offset, pageLimit) returns (
                uint256[] memory vaultIds, uint256 nextOffset, uint256 total
            ) {
                if (vaultIds.length == 0) break;
                for (uint256 i; i < vaultIds.length;) {
                    assets += _activeVaultTierAssets(vaultIds[i]);
                    unchecked {
                        ++i;
                    }
                }
                if (nextOffset >= total || nextOffset <= offset) break;
                offset = nextOffset;
            } catch {
                revert DeploymentBufferEnumerationFailed(address(_vaultRegistry));
            }
        }
    }

    function _activeVaultTierAssets(uint256 vaultId) internal view returns (uint256 assets) {
        VaultConfig memory vc = _vaultRegistry.getVault(vaultId);
        if (vc.status == VaultStatus.Active) {
            for (uint256 j; j < 4;) {
                address tierVault = vc.tierVaults[j];
                if (tierVault != address(0)) {
                    assets += IERC4626TotalAssets(tierVault).totalAssets();
                }
                unchecked {
                    ++j;
                }
            }
        }
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

    function _stageRescue(address token, address recipient, uint256 amount, uint64 proposedAt) internal {
        _requireRescuableToken(token);
        if (amount == 0) revert ZeroAmount();
        if (recipient == address(0)) revert ZeroAddress();
        _requireNotBlocked(recipient);

        uint256 readyAt = uint256(proposedAt) + TOKEN_RESCUE_DELAY;
        _pendingTokenRescues[token] = PendingTokenRescue({amount: amount, readyAt: readyAt, recipient: recipient});
        emit TokenRescueProposed(token, amount, recipient, readyAt);
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
