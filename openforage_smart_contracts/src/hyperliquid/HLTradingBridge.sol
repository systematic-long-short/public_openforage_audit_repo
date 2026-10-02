// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {AllowlistGatedUpgradeable} from "../AllowlistGatedUpgradeable.sol";
import {FinalizeDelayProfile} from "../FinalizeDelayProfile.sol";
import {IBlocklist} from "../interfaces/IBlocklist.sol";
import {ISequencerUptimeFeed} from "../interfaces/ISequencerUptimeFeed.sol";
import {IUSDCTreasuryLossSettlement} from "../interfaces/IUSDCTreasuryYieldClaims.sol";

interface IUSDCTreasuryReturnPort {
    function recordPrincipalReturnUSDC(uint256 amount) external;
    function returnPnLUSDC(uint256 vaultId, uint256 amount) external;
}

interface IRISKUSDVaultCustodyPort {
    function deployCapital(uint256 usdcAmount) external;
    function returnCapital(uint256 usdcAmount) external;
    function returnCapitalWithNAVBasis(uint256 usdcAmount, bool navAlreadyReduced) external;
}

interface IRISKUSDVaultNAVPort {
    function recordCustodianNAV(uint256 vaultId, uint256 nav, uint256 lossNonce) external;
    function recordCustodianNAV(uint256 vaultId, uint256 nav, uint256 lossNonce, uint256 observedAt) external;
    function attestationIntervalSeconds() external view returns (uint256);
    function latestLossNonce() external view returns (uint256);
    function settledLossNonce() external view returns (uint256);
    function lossPendingVaultId() external view returns (uint256);
    function latestLossAmount() external view returns (uint256);
    function lossPending() external view returns (bool);
}

interface IRISKUSDVaultManualNAVState {
    function lastAttestedNAV() external view returns (uint256);
    function lastAttestationTimestamp() external view returns (uint256);
    function totalDeployed() external view returns (uint256);
}

interface ICustodianRegistryAccountingPort {
    function HYPERLIQUID_CUSTODIAN_ID() external view returns (bytes32);
    function ROLE_EXECUTOR() external view returns (bytes32);
    function guardianModule() external view returns (address);
    function hasCustodianRole(bytes32 id, bytes32 role, address account) external view returns (bool);
    function recordDeployment(bytes32 id, uint256 amount) external;
    function recordReturnWithNAVBasis(bytes32 id, uint256 amount, bool navAlreadyReduced) external;
    function recordLoss(bytes32 id, uint256 amount) external returns (uint256 recordedAmount);
}

/// @title HLTradingBridge
/// @notice Slim Arbitrum-side HyperLiquid custodian for the target stack.
contract HLTradingBridge is
    Initializable,
    Ownable2StepUpgradeable,
    PausableUpgradeable,
    ReentrancyGuard,
    UUPSUpgradeable,
    FinalizeDelayProfile,
    AllowlistGatedUpgradeable
{
    using SafeERC20 for IERC20;

    error ZeroAddress();
    error ZeroAmount();
    error InvalidBps();
    error UnauthorizedExecutor();
    error UnauthorizedKeeper();
    error UnauthorizedPause();
    error PerBlockDeployCapExceeded(uint256 provided, uint256 cap);
    error PerDayDeployCapExceeded(uint256 provided, uint256 cap);
    error ReturnPerCallCapExceeded(uint256 provided, uint256 cap);
    error ReturnPerDayCapExceeded(uint256 provided, uint256 cap);
    error NoPendingKeeper();
    error FinalizeDelayNotElapsed();
    error ProposalExpired();
    error StaleNAV();
    error ArrivalAmountMismatch();
    error RequestMismatch();
    error InvalidWithdrawalRecipient(address recipient);
    error WithdrawalIntentSourceMismatch(bytes32 provided, bytes32 expected);
    error WithdrawalIntentChainMismatch(uint64 provided, uint64 expected);
    error WithdrawalIntentAmountExceeded(uint256 provided, uint256 cap);
    error InsufficientReconciledLiquidity(uint256 requested, uint256 available);
    error WithdrawalIntentPending(bytes32 intentId);
    error DirectionFrozen();
    error BlockedAddress(address account);
    error BlocklistUnavailable(address blocklist);
    error RenounceOwnershipDisabled();
    error GuardianCannotLoosen();
    error UnauthorizedVault(address caller);
    error WithdrawalIntentNotExpired();
    error NonZeroPrincipal(uint256 principal);
    error SequencerUptimeFeedUnavailable(address feed);
    error SequencerDown();
    error SequencerGracePeriodNotOver(uint256 startedAt, uint256 gracePeriod);
    error ExcessiveLossWriteDown(uint256 amount, uint256 deployedPrincipal);
    error LossNonceMismatch(uint256 provided, uint256 expected);
    error NoPendingLoss();
    error LossSettlementIncomplete(uint256 lossNonce);
    error LossSettlementInProgress();
    error LossPending();
    error PrincipalReturnBlockedByUnresolvedLoss(uint256 lossNonce, uint256 vaultId);
    error ReconciledBalanceExceedsBalance(uint256 balance, uint256 reconciled);
    error InsufficientUnreconciledLiquidity(uint256 requested, uint256 available);
    error ReceiptIndexOverflow(uint256 unreconciled, uint256 totalCredited);
    error ReceiptIndexBelowBaseline(uint256 index, uint256 baseline);
    error WithdrawalCreditOutOfBounds(bytes32 intentId, uint256 credited, uint256 delta, uint256 amount);
    error WithdrawalIntentNotCancelled(bytes32 intentId);
    error CancelledWithdrawalIntentWhileAnotherIsOpen(bytes32 openIntentId);
    error WithdrawalIntentNonceExhausted();
    error WithdrawalIntentCollision(bytes32 intentId);
    error InvalidManualNAVObservation(uint256 observedAt, uint256 currentTimestamp);
    error VaultPrincipalMismatch(uint256 vaultPrincipal, uint256 bridgePrincipal);
    error PrincipalBookAnchorUnavailable();
    error ManualNAVObservationNotAfterPrincipalChange(uint256 observedAt, uint256 principalBookKnownSince);
    error GuardianRegistryUnavailable(address registry);
    error GuardianModuleResolutionFailed(address registry);
    error InvalidGuardianModule(address module);
    error FreshDeploymentRequired(uint64 observedVersion);

    uint256 public constant DAY_SECONDS = 1 days;
    uint256 public constant PROPOSAL_EXPIRY = 30 days;
    uint256 public constant ARBITRUM_ONE_CHAIN_ID = 42_161;
    uint256 public constant SEQUENCER_UPTIME_GRACE_PERIOD = 1 hours;
    uint16 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant DEFAULT_WITHDRAWAL_INTENT_TIMEOUT_SECONDS = 7 days;
    uint64 private constant FRESH_DEPLOYMENT_VERSION = 2;

    address public usdc;
    address public riskusdVault;
    address public usdcTreasury;
    address public custodianRegistry;
    address private _legacyGuardianModule;

    uint256 internal _deployedPrincipal;
    uint256 internal _pendingDeployPrincipal;
    uint256 internal _appliedNAV;
    uint256 internal _lastNAVBookValue;
    uint256 internal _lastNAVRawValue;
    uint256 internal _lastNAVObservedAt;

    uint256 internal _perBlockDeployCap;
    uint256 internal _perDayDeployCap;
    uint256 internal _deployUsedThisBlock;
    uint256 internal _deployUsedBlockNum;
    uint256 internal _deployUsedThisDay;
    uint256 internal _deployUsedDayStart;

    uint16 internal _returnPerCallCapBps;
    uint16 internal _returnPerDayCapBps;
    uint256 internal _returnUsedThisDay;
    uint256 internal _returnUsedDayStart;

    address internal _keeper;
    address internal _pendingKeeper;
    uint256 internal _pendingKeeperProposedAt;
    address internal _custodianExecutor;
    address internal _blocklist;
    bool internal _directionalFreeze;

    struct WithdrawalIntent {
        uint256 amount;
        address recipient;
        bytes32 sourceAccount;
        uint64 chainSelector;
        bool consumed;
        bool exists;
        uint256 inflowBaseline;
        uint256 createdAt;
        uint256 creditedAmount;
        bool cancelled;
    }

    struct RouteConfig {
        address coldAccount;
        bytes32 hyperliquidSourceAccount;
        uint64 withdrawalChainSelector;
        address sequencerUptimeFeed;
    }

    mapping(bytes32 => WithdrawalIntent) internal _withdrawalIntents;
    address public coldAccount;
    bytes32 public hyperliquidSourceAccount;
    uint64 public withdrawalChainSelector;
    uint256 internal _withdrawalIntentUsedThisDay;
    uint256 internal _withdrawalIntentUsedDayStart;
    uint256 internal _reconciledReturnLiquidity;
    bytes32 internal _openWithdrawalIntentId;
    address internal _sequencerUptimeFeed;
    uint256 internal _withdrawalIntentNonce;
    uint256 internal _totalCreditedReceipts;
    uint256 internal _principalBookKnownSince;
    bool private _lossSettlementInProgress;
    uint64 private _freshDeploymentVersion;
    uint256 internal _navIntervalStartAt;
    uint256 internal _navIntervalStartNAV;
    uint256 internal _positiveNAVDeltaUsed;
    uint256[42] private __gap;

    event DeployedToHyperLiquid(uint256 usdcE6, uint256 deployedPrincipal);
    event NAVPosted(uint256 indexed vaultId, uint256 bookValue, uint256 rawNav, uint256 appliedNav, uint256 observedAt);
    event PrincipalReturned(uint256 usdcE6, uint256 deployedPrincipal);
    event PnLReturned(uint256 indexed vaultId, uint256 usdcE6);
    event WithdrawalIntentRequested(
        bytes32 indexed intentId, uint256 amount, address indexed recipient, bytes32 sourceAccount, uint64 chainSelector
    );
    event WithdrawalArrivalReconciled(bytes32 indexed intentId, uint256 amount);
    event WithdrawalIntentCancelled(bytes32 indexed intentId);
    event DirectionalFreezeSet(bool frozen);
    event KeeperProposed(address indexed currentKeeper, address indexed pendingKeeper);
    event KeeperSet(address indexed oldKeeper, address indexed newKeeper);
    event PendingKeeperCancelled(address indexed pendingKeeper);
    event BlocklistSet(address indexed oldBlocklist, address indexed newBlocklist);
    event SequencerUptimeFeedSet(address indexed oldFeed, address indexed newFeed);
    event PerBlockDeployCapSet(uint256 oldCap, uint256 newCap);
    event PerDayDeployCapSet(uint256 oldCap, uint256 newCap);
    event ReturnCapitalCapsSet(uint16 oldPerCallBps, uint16 newPerCallBps, uint16 oldPerDayBps, uint16 newPerDayBps);
    event PrincipalLossWrittenDown(uint256 amount, uint256 deployedPrincipal, uint256 pendingDeployPrincipal);
    event LossReportFinalized(uint256 indexed vaultId, uint256 indexed lossNonce, uint256 originalLoss);
    event AttestedLossSettled(uint256 indexed vaultId, uint256 indexed lossNonce, uint256 amount);
    event ManualCustodianNAVAcknowledged(
        uint256 submittedRawNav, uint256 acceptedNav, uint256 bookValue, uint256 observedAt
    );

    constructor() {
        _disableInitializers();
    }

    modifier freshDeploymentOnly() {
        _requireFreshDeployment();
        _;
    }

    modifier onlyDuringConstructionBeforeInitialization() {
        if (address(this).code.length != 0 || _getInitializedVersion() != 0) revert InvalidInitialization();
        _;
    }

    function initialize(
        address usdc_,
        address riskusdVault_,
        address usdcTreasury_,
        address custodianRegistry_,
        address initialOwner_,
        address keeper_,
        address executor_,
        address guardianModule_,
        RouteConfig calldata route
    ) external onlyDuringConstructionBeforeInitialization initializer {
        if (
            usdc_ == address(0) || riskusdVault_ == address(0) || usdcTreasury_ == address(0)
                || custodianRegistry_ == address(0) || initialOwner_ == address(0) || keeper_ == address(0)
                || executor_ == address(0) || guardianModule_ == address(0) || route.coldAccount == address(0)
                || route.hyperliquidSourceAccount == bytes32(0) || route.withdrawalChainSelector == 0
                || route.sequencerUptimeFeed == address(0)
        ) revert ZeroAddress();

        __Ownable_init(initialOwner_);
        __Ownable2Step_init();
        __Pausable_init();

        usdc = usdc_;
        riskusdVault = riskusdVault_;
        usdcTreasury = usdcTreasury_;
        custodianRegistry = custodianRegistry_;
        coldAccount = route.coldAccount;
        hyperliquidSourceAccount = route.hyperliquidSourceAccount;
        withdrawalChainSelector = route.withdrawalChainSelector;
        _sequencerUptimeFeed = route.sequencerUptimeFeed;
        _keeper = keeper_;
        _custodianExecutor = executor_;
        _perBlockDeployCap = 1_000_000e6;
        _perDayDeployCap = 5_000_000e6;
        _deployUsedDayStart = block.timestamp;
        _returnPerCallCapBps = 1_000;
        _returnPerDayCapBps = 1_000;
        _returnUsedDayStart = block.timestamp;
        _withdrawalIntentUsedDayStart = block.timestamp;
        _freshDeploymentVersion = FRESH_DEPLOYMENT_VERSION;
        _updatePrincipalBookAnchor();
        emit SequencerUptimeFeedSet(address(0), route.sequencerUptimeFeed);
    }

    function deployToHyperLiquid(uint256 usdcE6)
        external
        freshDeploymentOnly
        onlyAllowedCaller
        whenNotPaused
        nonReentrant
    {
        _requireExecutor();
        if (_directionalFreeze) revert DirectionFrozen();
        if (usdcE6 == 0) revert ZeroAmount();
        _requireNotBlocked(msg.sender);
        _requireNotBlocked(coldAccount);
        _enforceDeployCaps(usdcE6);
        _recordCustodianDeployment(usdcE6);

        IERC20 token = IERC20(usdc);
        uint256 balanceBefore = token.balanceOf(address(this));
        IRISKUSDVaultCustodyPort(riskusdVault).deployCapital(usdcE6);
        if (token.balanceOf(address(this)) - balanceBefore != usdcE6) revert ArrivalAmountMismatch();
        token.safeTransfer(coldAccount, usdcE6);

        _deployedPrincipal += usdcE6;
        _pendingDeployPrincipal += usdcE6;
        _updatePrincipalBookAnchor();

        emit DeployedToHyperLiquid(usdcE6, _deployedPrincipal);
    }

    function postNAV(uint256 vaultId, uint256 bookValue, uint256 rawNav, uint256 observedAt)
        external
        freshDeploymentOnly
        onlyAllowedCaller
        whenNotPaused
        nonReentrant
    {
        _requireKeeper();
        _requireNotBlocked(msg.sender);
        _requireNoLossSettlementInProgress();
        uint256 principalBookKnownSince = _principalBookKnownSince;
        if (observedAt < _lastNAVObservedAt) revert StaleNAV();
        if (principalBookKnownSince == 0) revert PrincipalBookAnchorUnavailable();
        if (observedAt <= principalBookKnownSince || bookValue != _deployedPrincipal) {
            revert StaleNAV();
        }

        uint256 applied = _normalizeCustodianNAV(bookValue, rawNav, observedAt, _appliedNAV, true);
        uint256 vaultNav = applied;
        // Risk-reducing (loss-recording) posts are allowed through sequencer down/grace/unavailable
        // windows: recording a true loss only ever tightens consumer gates. Neutral and up posts
        // remain fully gated, failing closed while the feed cannot vouch for liveness.
        if (vaultNav >= _deployedPrincipal) {
            _requireNoUnresolvedLossNonce(true);
            _requireSequencerUp();
        }

        _recordNAVIntervalBudget(applied, observedAt);
        _lastNAVBookValue = bookValue;
        _lastNAVRawValue = rawNav;
        _lastNAVObservedAt = observedAt;
        _appliedNAV = applied;
        _clearPendingDeployPrincipalIfCovered(vaultNav, _deployedPrincipal);
        uint256 lossNonce = 0;
        if (vaultNav < _deployedPrincipal) {
            lossNonce = IRISKUSDVaultNAVPort(riskusdVault).latestLossNonce() + 1;
        }
        IRISKUSDVaultNAVPort(riskusdVault).recordCustodianNAV(vaultId, vaultNav, lossNonce, observedAt);

        emit NAVPosted(vaultId, bookValue, rawNav, applied, observedAt);
    }

    function _clearPendingDeployPrincipalIfCovered(uint256 acceptedNav, uint256 bridgePrincipal) private {
        if (_pendingDeployPrincipal != 0 && acceptedNav >= bridgePrincipal) {
            _pendingDeployPrincipal = 0;
        }
    }

    function returnPrincipalUSDC(uint256 amount) external freshDeploymentOnly onlyAllowedCaller nonReentrant {
        _requireExecutor();
        _returnPrincipalUSDC(amount, false);
    }

    function returnPrincipalUSDCWithNAVBasis(uint256 amount, bool navAlreadyReduced)
        external
        freshDeploymentOnly
        onlyAllowedCaller
        nonReentrant
    {
        _requireExecutor();
        _returnPrincipalUSDC(amount, navAlreadyReduced);
    }

    function returnZeroPrincipalUSDC(uint256 amount, bool navAlreadyReduced)
        external
        freshDeploymentOnly
        onlyAllowedCaller
        onlyOwner
        nonReentrant
    {
        if (_deployedPrincipal != 0) revert NonZeroPrincipal(_deployedPrincipal);
        _returnPrincipalUSDCWithoutCaps(amount, navAlreadyReduced);
    }

    function _returnPrincipalUSDC(uint256 amount, bool navAlreadyReduced) internal {
        if (amount == 0) revert ZeroAmount();
        _requireNotBlocked(msg.sender);
        _requireNotBlocked(address(this));
        _requireNotBlocked(riskusdVault);
        _enforceReturnCaps(amount);
        _returnPrincipalUSDCWithoutCaps(amount, navAlreadyReduced);
    }

    function _returnPrincipalUSDCWithoutCaps(uint256 amount, bool navAlreadyReduced) internal {
        if (amount == 0) revert ZeroAmount();
        _requireNoUnresolvedLossNonce(false);
        _requireNotBlocked(msg.sender);
        _requireNotBlocked(address(this));
        _requireNotBlocked(riskusdVault);
        uint256 principalBefore = _deployedPrincipal;
        if (amount >= _deployedPrincipal) {
            _deployedPrincipal = 0;
        } else {
            _deployedPrincipal -= amount;
        }
        if (_deployedPrincipal != principalBefore) _updatePrincipalBookAnchor();
        if (amount >= _pendingDeployPrincipal) {
            _pendingDeployPrincipal = 0;
        } else {
            _pendingDeployPrincipal -= amount;
        }

        IERC20 token = IERC20(usdc);
        _consumeReconciledLiquidity(token, amount);
        _recordCustodianReturn(amount, navAlreadyReduced);
        token.forceApprove(riskusdVault, amount);
        IRISKUSDVaultCustodyPort(riskusdVault).returnCapitalWithNAVBasis(amount, navAlreadyReduced);
        token.forceApprove(riskusdVault, 0);
        IUSDCTreasuryReturnPort(usdcTreasury).recordPrincipalReturnUSDC(amount);
        emit PrincipalReturned(amount, _deployedPrincipal);
    }

    function _requireNoUnresolvedLossNonce(bool coveringNAV) private view {
        IRISKUSDVaultNAVPort centralVault = IRISKUSDVaultNAVPort(riskusdVault);
        uint256 lossNonce = centralVault.latestLossNonce();
        uint256 settledNonce = centralVault.settledLossNonce();
        uint256 vaultId = centralVault.lossPendingVaultId();
        if (lossNonce != 0 && lossNonce > settledNonce && vaultId != 0) {
            if (coveringNAV) revert LossPending();
            revert PrincipalReturnBlockedByUnresolvedLoss(lossNonce, vaultId);
        }
    }

    function _requireNewerNAVObservation(uint256 observedAt) private view {
        if (
            observedAt <= _lastNAVObservedAt
                || observedAt <= IRISKUSDVaultManualNAVState(riskusdVault).lastAttestationTimestamp()
        ) revert InvalidManualNAVObservation(observedAt, block.timestamp);
    }

    function recordLossWriteDown(uint256 amount)
        external
        freshDeploymentOnly
        onlyAllowedCaller
        nonReentrant
        returns (uint256 writtenDown)
    {
        if (msg.sender != riskusdVault) revert UnauthorizedVault(msg.sender);
        if (amount == 0) revert ZeroAmount();
        uint256 principal = _deployedPrincipal;
        if (amount > principal) revert ExcessiveLossWriteDown(amount, principal);
        uint256 rebasedAppliedNAV = _normalizeAppliedNAVToCurrentBook(_lastNAVBookValue, _appliedNAV);

        _deployedPrincipal = principal - amount;
        _updatePrincipalBookAnchor();

        ICustodianRegistryAccountingPort registry = ICustodianRegistryAccountingPort(custodianRegistry);
        uint256 recordedAmount = registry.recordLoss(registry.HYPERLIQUID_CUSTODIAN_ID(), amount);
        if (recordedAmount != amount) revert ExcessiveLossWriteDown(amount, principal);

        _lastNAVBookValue = _deployedPrincipal;
        _appliedNAV = rebasedAppliedNAV;

        emit PrincipalLossWrittenDown(amount, _deployedPrincipal, _pendingDeployPrincipal);
        return amount;
    }

    function settleLoss(uint256 lossNonce) external freshDeploymentOnly onlyAllowedCaller whenNotPaused {
        _requireKeeper();
        _requireNotBlocked(msg.sender);
        IRISKUSDVaultNAVPort centralVault = IRISKUSDVaultNAVPort(riskusdVault);
        uint256 latestNonce = centralVault.latestLossNonce();
        if (lossNonce == 0 || lossNonce != latestNonce || lossNonce <= centralVault.settledLossNonce()) {
            revert LossNonceMismatch(lossNonce, latestNonce);
        }
        uint256 vaultId = centralVault.lossPendingVaultId();
        uint256 amount = centralVault.latestLossAmount();
        if (vaultId == 0 || amount == 0 || !centralVault.lossPending()) revert NoPendingLoss();

        bool finalizingReport = !_lossSettlementInProgress;
        _lossSettlementInProgress = true;
        (bool complete, uint256 originalLoss) = IUSDCTreasuryLossSettlement(usdcTreasury).settleLoss(vaultId, lossNonce);
        if (finalizingReport) emit LossReportFinalized(vaultId, lossNonce, originalLoss);
        if (!complete) return;
        if (centralVault.settledLossNonce() != lossNonce || centralVault.latestLossAmount() != 0) {
            revert LossSettlementIncomplete(lossNonce);
        }
        _lossSettlementInProgress = false;
        emit AttestedLossSettled(vaultId, lossNonce, originalLoss);
    }

    function returnPnLUSDC(uint256 vaultId, uint256 amount)
        external
        freshDeploymentOnly
        onlyAllowedCaller
        nonReentrant
    {
        _requireExecutor();
        if (amount == 0) revert ZeroAmount();
        _requireNotBlocked(msg.sender);
        _requireNotBlocked(address(this));
        _requireNotBlocked(usdcTreasury);
        _enforceReturnCaps(amount);

        IERC20 token = IERC20(usdc);
        _consumeReconciledLiquidity(token, amount);
        token.forceApprove(usdcTreasury, amount);
        IUSDCTreasuryReturnPort(usdcTreasury).returnPnLUSDC(vaultId, amount);
        token.forceApprove(usdcTreasury, 0);
        emit PnLReturned(vaultId, amount);
    }

    function returnZeroPrincipalPnLUSDC(uint256 vaultId, uint256 amount)
        external
        freshDeploymentOnly
        onlyAllowedCaller
        onlyOwner
        nonReentrant
    {
        if (_deployedPrincipal != 0) revert NonZeroPrincipal(_deployedPrincipal);
        if (amount == 0) revert ZeroAmount();
        _requireNotBlocked(msg.sender);
        _requireNotBlocked(address(this));
        _requireNotBlocked(usdcTreasury);

        IERC20 token = IERC20(usdc);
        _consumeReconciledLiquidity(token, amount);
        token.forceApprove(usdcTreasury, amount);
        IUSDCTreasuryReturnPort(usdcTreasury).returnPnLUSDC(vaultId, amount);
        token.forceApprove(usdcTreasury, 0);
        emit PnLReturned(vaultId, amount);
    }

    function requestWithdrawalIntent(uint256 amount, address recipient, bytes32 sourceAccount, uint64 chainSelector)
        external
        freshDeploymentOnly
        onlyAllowedCaller
        nonReentrant
        returns (bytes32 intentId)
    {
        _requireExecutor();
        return _requestWithdrawalIntent(amount, recipient, sourceAccount, chainSelector, true);
    }

    function requestZeroPrincipalWithdrawalIntent(
        uint256 amount,
        address recipient,
        bytes32 sourceAccount,
        uint64 chainSelector
    ) external freshDeploymentOnly onlyAllowedCaller onlyOwner nonReentrant returns (bytes32 intentId) {
        if (_deployedPrincipal != 0) revert NonZeroPrincipal(_deployedPrincipal);
        return _requestWithdrawalIntent(amount, recipient, sourceAccount, chainSelector, false);
    }

    function _requestWithdrawalIntent(
        uint256 amount,
        address recipient,
        bytes32 sourceAccount,
        uint64 chainSelector,
        bool enforceCaps
    ) internal returns (bytes32 intentId) {
        if (amount == 0) revert ZeroAmount();
        if (recipient == address(0)) revert ZeroAddress();
        _requireNotBlocked(msg.sender);
        _requireNotBlocked(recipient);
        if (recipient != address(this)) revert InvalidWithdrawalRecipient(recipient);
        if (sourceAccount != hyperliquidSourceAccount) {
            revert WithdrawalIntentSourceMismatch(sourceAccount, hyperliquidSourceAccount);
        }
        if (chainSelector != withdrawalChainSelector) {
            revert WithdrawalIntentChainMismatch(chainSelector, withdrawalChainSelector);
        }
        if (enforceCaps) _enforceWithdrawalIntentCaps(amount);

        bytes32 openIntentId = _openWithdrawalIntentId;
        if (openIntentId != bytes32(0)) revert WithdrawalIntentPending(openIntentId);
        uint256 nonce = _nextWithdrawalIntentNonce();
        intentId = keccak256(
            abi.encode(address(this), msg.sender, amount, recipient, sourceAccount, chainSelector, block.number, nonce)
        );
        if (intentId == bytes32(0) || _withdrawalIntents[intentId].exists) {
            revert WithdrawalIntentCollision(intentId);
        }
        uint256 inflowBaseline =
            _receiptIndex(_unreconciledBalance(IERC20(usdc).balanceOf(address(this))), _totalCreditedReceipts);
        _withdrawalIntents[intentId] = WithdrawalIntent({
            amount: amount,
            recipient: recipient,
            sourceAccount: sourceAccount,
            chainSelector: chainSelector,
            consumed: false,
            exists: true,
            inflowBaseline: inflowBaseline,
            createdAt: block.timestamp,
            creditedAmount: 0,
            cancelled: false
        });
        _openWithdrawalIntentId = intentId;

        emit WithdrawalIntentRequested(intentId, amount, recipient, sourceAccount, chainSelector);
    }

    function reconcileWithdrawalArrival(bytes32 intentId, uint256 arrivedAmount)
        external
        freshDeploymentOnly
        onlyAllowedCaller
        nonReentrant
    {
        _requireKeeper();
        _requireNotBlocked(msg.sender);
        if (intentId == bytes32(0)) {
            if (_openWithdrawalIntentId != bytes32(0) || _withdrawalIntents[intentId].exists) {
                revert RequestMismatch();
            }
            _creditUnassignedWithdrawalArrival(arrivedAmount);
            emit WithdrawalArrivalReconciled(intentId, arrivedAmount);
            return;
        }
        WithdrawalIntent storage intent = _withdrawalIntents[intentId];
        if (!intent.exists || intent.consumed || intent.cancelled) revert RequestMismatch();
        if (intentId != _openWithdrawalIntentId) revert RequestMismatch();
        _creditWithdrawalIntent(intentId, intent, arrivedAmount);
        if (intent.creditedAmount == intent.amount) {
            intent.consumed = true;
            _openWithdrawalIntentId = bytes32(0);
        }
        emit WithdrawalArrivalReconciled(intentId, arrivedAmount);
    }

    function reconcileCancelledWithdrawalArrival(bytes32 intentId, uint256 arrivedAmount)
        external
        freshDeploymentOnly
        onlyAllowedCaller
        nonReentrant
    {
        _requireKeeper();
        _requireNotBlocked(msg.sender);
        bytes32 openIntentId = _openWithdrawalIntentId;
        if (openIntentId != bytes32(0)) revert CancelledWithdrawalIntentWhileAnotherIsOpen(openIntentId);
        WithdrawalIntent storage intent = _withdrawalIntents[intentId];
        if (!intent.exists || !intent.cancelled || !intent.consumed) {
            revert WithdrawalIntentNotCancelled(intentId);
        }
        _creditWithdrawalIntent(intentId, intent, arrivedAmount);
        emit WithdrawalArrivalReconciled(intentId, arrivedAmount);
    }

    function cancelWithdrawalIntent(bytes32 intentId) external freshDeploymentOnly onlyAllowedCaller nonReentrant {
        if (msg.sender != owner() && msg.sender != _keeper) revert UnauthorizedKeeper();
        _requireNotBlocked(msg.sender);
        WithdrawalIntent storage intent = _withdrawalIntents[intentId];
        if (!intent.exists || intent.consumed) revert RequestMismatch();
        if (intentId != _openWithdrawalIntentId) revert RequestMismatch();
        uint256 createdAt = intent.createdAt;
        if (createdAt != 0 && block.timestamp < createdAt + withdrawalIntentTimeoutSeconds()) {
            revert WithdrawalIntentNotExpired();
        }
        intent.consumed = true;
        intent.cancelled = true;
        _openWithdrawalIntentId = bytes32(0);
        emit WithdrawalIntentCancelled(intentId);
    }

    function setDirectionalFreeze(bool frozen) external freshDeploymentOnly onlyAllowedCaller {
        address guardian = _requireGuardianModuleOrOwner();
        if (guardian != address(0) && !frozen) revert GuardianCannotLoosen();
        _setDirectionalFreeze(frozen);
    }

    function freezeAttestations() external freshDeploymentOnly onlyAllowedCaller {
        _requireGuardianModuleOrOwner();
        _setDirectionalFreeze(true);
    }

    function pause() external freshDeploymentOnly onlyAllowedCaller {
        _requireGuardianModuleOrOwner();
        _pause();
    }

    function unpause() external freshDeploymentOnly onlyAllowedCaller onlyOwner {
        _unpause();
    }

    function proposeKeeper(address newKeeper) external freshDeploymentOnly onlyAllowedCaller onlyOwner {
        if (newKeeper == address(0)) revert ZeroAddress();
        _pendingKeeper = newKeeper;
        _pendingKeeperProposedAt = block.timestamp;
        emit KeeperProposed(_keeper, newKeeper);
    }

    function finalizeKeeper() external freshDeploymentOnly onlyAllowedCaller onlyOwner {
        address newKeeper = _pendingKeeper;
        if (newKeeper == address(0)) revert NoPendingKeeper();
        if (block.timestamp < _pendingKeeperProposedAt + _finalizeDelay()) revert FinalizeDelayNotElapsed();
        if (block.timestamp > _pendingKeeperProposedAt + PROPOSAL_EXPIRY) revert ProposalExpired();

        address oldKeeper = _keeper;
        _keeper = newKeeper;
        _pendingKeeper = address(0);
        _pendingKeeperProposedAt = 0;
        emit KeeperSet(oldKeeper, newKeeper);
    }

    function cancelPendingKeeper() external freshDeploymentOnly onlyAllowedCaller onlyOwner {
        address pending = _pendingKeeper;
        if (pending == address(0)) revert NoPendingKeeper();
        _pendingKeeper = address(0);
        _pendingKeeperProposedAt = 0;
        emit PendingKeeperCancelled(pending);
    }

    function setBlocklist(address blocklist_) external freshDeploymentOnly onlyAllowedCaller onlyOwner {
        if (blocklist_ == address(0)) revert ZeroAddress();
        address old = _blocklist;
        _blocklist = blocklist_;
        emit BlocklistSet(old, blocklist_);
    }

    function setAllowlist(address allowlist_) external freshDeploymentOnly onlyOwner {
        _transitionAllowlist(allowlist_);
    }

    function setSequencerUptimeFeed(address feed_) external freshDeploymentOnly onlyAllowedCaller onlyOwner {
        if (feed_ == address(0)) revert ZeroAddress();
        address old = _sequencerUptimeFeed;
        _sequencerUptimeFeed = feed_;
        emit SequencerUptimeFeedSet(old, feed_);
    }

    function setPerBlockDeployCap(uint256 newCap) external freshDeploymentOnly onlyAllowedCaller onlyOwner {
        if (newCap == 0) revert ZeroAmount();
        _setPerBlockDeployCap(newCap);
    }

    function setPerDayDeployCap(uint256 newCap) external freshDeploymentOnly onlyAllowedCaller onlyOwner {
        if (newCap == 0) revert ZeroAmount();
        _setPerDayDeployCap(newCap);
    }

    function setReturnCapitalCaps(uint16 perCallBps, uint16 perDayBps)
        external
        freshDeploymentOnly
        onlyAllowedCaller
        onlyOwner
    {
        _validateReturnCapitalCaps(perCallBps, perDayBps);
        _setReturnCapitalCaps(perCallBps, perDayBps);
    }

    function shrinkPerBlockDeployCap(uint256 newCap) external freshDeploymentOnly onlyAllowedCaller {
        _requireGuardianModuleOrOwner();
        if (newCap == 0) revert ZeroAmount();
        if (newCap > _perBlockDeployCap) revert GuardianCannotLoosen();
        _setPerBlockDeployCap(newCap);
    }

    function shrinkPerDayDeployCap(uint256 newCap) external freshDeploymentOnly onlyAllowedCaller {
        _requireGuardianModuleOrOwner();
        if (newCap == 0) revert ZeroAmount();
        if (newCap > _perDayDeployCap) revert GuardianCannotLoosen();
        _setPerDayDeployCap(newCap);
    }

    function tightenReturnCapitalCaps(uint16 perCallBps, uint16 perDayBps)
        external
        freshDeploymentOnly
        onlyAllowedCaller
    {
        _requireGuardianModuleOrOwner();
        _validateReturnCapitalCaps(perCallBps, perDayBps);
        if (perCallBps > _returnPerCallCapBps || perDayBps > _returnPerDayCapBps) revert GuardianCannotLoosen();
        _setReturnCapitalCaps(perCallBps, perDayBps);
    }

    function _validateReturnCapitalCaps(uint16 perCallBps, uint16 perDayBps) internal pure {
        if (perCallBps == 0 || perDayBps == 0 || perCallBps > BPS_DENOMINATOR || perDayBps > BPS_DENOMINATOR) {
            revert InvalidBps();
        }
    }

    function _setDirectionalFreeze(bool frozen) internal {
        _directionalFreeze = frozen;
        emit DirectionalFreezeSet(frozen);
    }

    function _setPerBlockDeployCap(uint256 newCap) internal {
        uint256 old = _perBlockDeployCap;
        _perBlockDeployCap = newCap;
        emit PerBlockDeployCapSet(old, newCap);
    }

    function _setPerDayDeployCap(uint256 newCap) internal {
        uint256 old = _perDayDeployCap;
        _perDayDeployCap = newCap;
        emit PerDayDeployCapSet(old, newCap);
    }

    function _setReturnCapitalCaps(uint16 perCallBps, uint16 perDayBps) internal {
        uint16 oldPerCall = _returnPerCallCapBps;
        uint16 oldPerDay = _returnPerDayCapBps;
        _returnPerCallCapBps = perCallBps;
        _returnPerDayCapBps = perDayBps;
        emit ReturnCapitalCapsSet(oldPerCall, perCallBps, oldPerDay, perDayBps);
    }

    function _requireGuardianModuleOrOwner() internal view returns (address guardian) {
        if (msg.sender == owner()) return address(0);
        guardian = _liveGuardianModule();
        if (msg.sender != guardian) revert UnauthorizedPause();
    }

    function renounceOwnership() public view override freshDeploymentOnly onlyOwner {
        revert RenounceOwnershipDisabled();
    }

    function upgradeToAndCall(address newImplementation, bytes memory data)
        public
        payable
        override
        freshDeploymentOnly
        onlyAllowedCaller
    {
        super.upgradeToAndCall(newImplementation, data);
    }

    function transferOwnership(address newOwner) public override freshDeploymentOnly onlyAllowedCaller {
        super.transferOwnership(newOwner);
    }

    function acceptOwnership() public override freshDeploymentOnly onlyAllowedCaller {
        super.acceptOwnership();
    }

    function appliedNAV() external view returns (uint256) {
        return _appliedNAV;
    }

    function lastNAVBookValue() external view returns (uint256) {
        return _lastNAVBookValue;
    }

    function lastNAVRawValue() external view returns (uint256) {
        return _lastNAVRawValue;
    }

    function lastNAVObservedAt() external view returns (uint256) {
        return _lastNAVObservedAt;
    }

    function deployedPrincipal() external view returns (uint256) {
        return _deployedPrincipal;
    }

    function pendingDeployPrincipal() external view returns (uint256) {
        return _pendingDeployPrincipal;
    }

    function perBlockDeployCap() external view returns (uint256) {
        return _perBlockDeployCap;
    }

    function perDayDeployCap() external view returns (uint256) {
        return _perDayDeployCap;
    }

    function returnPerCallCapBps() public view returns (uint16) {
        return _returnPerCallCapBps;
    }

    function returnPerDayCapBps() public view returns (uint16) {
        return _returnPerDayCapBps;
    }

    function registryReturnPerCallCapBps() external view returns (uint16) {
        return _returnPerCallCapBps;
    }

    function registryReturnPerDayCapBps() external view returns (uint16) {
        return _returnPerDayCapBps;
    }

    function keeper() external view returns (address) {
        return _keeper;
    }

    function pendingKeeper() external view returns (address) {
        if (_pendingKeeperExpired()) return address(0);
        return _pendingKeeper;
    }

    function pendingKeeperProposedAt() external view returns (uint256) {
        if (_pendingKeeperExpired()) return 0;
        return _pendingKeeperProposedAt;
    }

    function custodianExecutor() external view returns (address) {
        return _custodianExecutor;
    }

    function blocklist() external view returns (address) {
        return _blocklist;
    }

    function sequencerUptimeFeed() external view returns (address) {
        return _sequencerUptimeFeed;
    }

    function directionalFreeze() external view returns (bool) {
        return _directionalFreeze;
    }

    function tierShareActionsPaused() external view returns (bool) {
        return _directionalFreeze;
    }

    function wiringChangeDelay() external view returns (uint256) {
        return _finalizeDelay();
    }

    function withdrawalIntentConsumed(bytes32 intentId) external view returns (bool) {
        return _withdrawalIntents[intentId].consumed;
    }

    function withdrawalIntentProgress(bytes32 intentId)
        external
        view
        returns (uint256 creditedAmount, bool cancelled)
    {
        WithdrawalIntent storage intent = _withdrawalIntents[intentId];
        return (intent.creditedAmount, intent.cancelled);
    }

    function openWithdrawalIntentId() external view returns (bytes32) {
        return _openWithdrawalIntentId;
    }

    function withdrawalIntentTimeoutSeconds() public pure returns (uint256) {
        return DEFAULT_WITHDRAWAL_INTENT_TIMEOUT_SECONDS;
    }

    function _pendingKeeperExpired() internal view returns (bool) {
        uint256 proposedAt = _pendingKeeperProposedAt;
        return _pendingKeeper != address(0) && proposedAt != 0 && block.timestamp > proposedAt + PROPOSAL_EXPIRY;
    }

    function withdrawalIntent(bytes32 intentId)
        external
        view
        returns (
            uint256 amount,
            address recipient,
            bytes32 sourceAccount,
            uint64 chainSelector,
            bool consumed,
            bool exists
        )
    {
        WithdrawalIntent storage intent = _withdrawalIntents[intentId];
        return (
            intent.amount, intent.recipient, intent.sourceAccount, intent.chainSelector, intent.consumed, intent.exists
        );
    }

    function reconciledReturnLiquidity() external view returns (uint256) {
        return _reconciledReturnLiquidity;
    }

    function guardianModule() external view returns (address) {
        return _liveGuardianModule();
    }

    function acknowledgeManualCustodianNAV(uint256 submittedRawNav)
        external
        freshDeploymentOnly
        onlyAllowedCaller
        nonReentrant
        returns (bool)
    {
        address vault = riskusdVault;
        if (msg.sender != vault || vault.code.length == 0) revert UnauthorizedVault(msg.sender);

        IRISKUSDVaultManualNAVState manualVault = IRISKUSDVaultManualNAVState(vault);
        uint256 acceptedNav = manualVault.lastAttestedNAV();
        uint256 observedAt = manualVault.lastAttestationTimestamp();
        uint256 vaultPrincipal = manualVault.totalDeployed();
        if (observedAt == 0 || observedAt > block.timestamp || block.timestamp - observedAt > DAY_SECONDS) {
            revert InvalidManualNAVObservation(observedAt, block.timestamp);
        }
        uint256 bridgePrincipal = _deployedPrincipal;
        if (vaultPrincipal != bridgePrincipal) revert VaultPrincipalMismatch(vaultPrincipal, bridgePrincipal);

        _recordNAVIntervalBudget(acceptedNav, observedAt);
        _lastNAVRawValue = submittedRawNav;
        _appliedNAV = acceptedNav;
        _lastNAVBookValue = bridgePrincipal;
        _lastNAVObservedAt = observedAt;
        _clearPendingDeployPrincipalIfCovered(acceptedNav, bridgePrincipal);
        emit ManualCustodianNAVAcknowledged(submittedRawNav, acceptedNav, bridgePrincipal, observedAt);
        return true;
    }

    function normalizeManualCustodianNAV(uint256, uint256 nav, uint256 lossNonce, uint256 observedAt)
        external
        view
        returns (bool, uint256)
    {
        if (msg.sender != riskusdVault) revert UnauthorizedVault(msg.sender);
        _requireNoLossSettlementInProgress();
        _requireNewerNAVObservation(observedAt);
        IRISKUSDVaultManualNAVState manualVault = IRISKUSDVaultManualNAVState(riskusdVault);
        uint256 knownSince = _principalBookKnownSince;
        if (knownSince == 0) revert PrincipalBookAnchorUnavailable();
        if (observedAt <= knownSince) revert ManualNAVObservationNotAfterPrincipalChange(observedAt, knownSince);
        uint256 principal = _deployedPrincipal;
        uint256 vaultPrincipal = manualVault.totalDeployed();
        if (vaultPrincipal != principal) revert VaultPrincipalMismatch(vaultPrincipal, principal);
        uint256 normalizedNav = _normalizeCustodianNAV(principal, nav, observedAt, _appliedNAV, false);
        bool shouldRecord = lossNonce != 0 || normalizedNav >= principal;
        return (shouldRecord, shouldRecord ? normalizedNav : 0);
    }

    function _updatePrincipalBookAnchor() private {
        _principalBookKnownSince = block.timestamp;
    }

    /// @notice Rebases the prior observation-book NAV into the current principal book.
    function _normalizeAppliedNAVToCurrentBook(uint256 bookValue, uint256 applied) internal view returns (uint256) {
        uint256 principal = _deployedPrincipal;
        uint256 normalized;
        if (principal >= bookValue) {
            normalized = applied + (principal - bookValue);
        } else {
            uint256 returnedAfterObservation = bookValue - principal;
            normalized = applied > returnedAfterObservation ? applied - returnedAfterObservation : 0;
        }
        return normalized;
    }

    function _normalizeCustodianNAV(
        uint256 bookValue,
        uint256 rawNav,
        uint256 observedAt,
        uint256 currentAppliedNAV,
        bool allowZeroBaseline
    ) internal view returns (uint256) {
        if (!allowZeroBaseline && (observedAt == 0 || bookValue == 0)) revert StaleNAV();
        if (block.timestamp > observedAt + DAY_SECONDS) revert StaleNAV();

        uint256 maxUp = bookValue + bookValue / 10;
        uint256 cappedNav = rawNav > maxUp ? maxUp : rawNav;
        uint256 previousNAV = _normalizeAppliedNAVToCurrentBook(_lastNAVBookValue, currentAppliedNAV);
        if (cappedNav > previousNAV) {
            (, uint256 intervalStartNAV, uint256 used) = _navInterval(observedAt, previousNAV);
            uint256 intervalBudget = intervalStartNAV / 10;
            uint256 remaining = intervalBudget > used ? intervalBudget - used : 0;
            if (cappedNav - previousNAV > remaining) cappedNav = previousNAV + remaining;
        }
        if (_directionalFreeze) {
            uint256 cappedNavCurrentBook = _normalizeAppliedNAVToCurrentBook(bookValue, cappedNav);
            if (cappedNavCurrentBook > previousNAV) revert DirectionFrozen();
        }
        return cappedNav;
    }

    function _navInterval(uint256 observedAt, uint256 previousNAV)
        private
        view
        returns (uint256 startAt, uint256 startNAV, uint256 used)
    {
        startAt = _navIntervalStartAt;
        startNAV = _navIntervalStartNAV;
        used = _positiveNAVDeltaUsed;
        uint256 interval = IRISKUSDVaultNAVPort(riskusdVault).attestationIntervalSeconds();
        if (interval == 0) revert StaleNAV();
        if (startAt == 0 || observedAt >= startAt + interval || (startNAV == 0 && previousNAV > 0 && used == 0)) {
            return (observedAt, previousNAV, 0);
        }
    }

    function _recordNAVIntervalBudget(uint256 nav, uint256 observedAt) private {
        uint256 previousNAV = _normalizeAppliedNAVToCurrentBook(_lastNAVBookValue, _appliedNAV);
        (uint256 startAt, uint256 startNAV, uint256 used) = _navInterval(observedAt, previousNAV);
        if (nav > previousNAV) used += nav - previousNAV;
        _navIntervalStartAt = startAt;
        _navIntervalStartNAV = startNAV;
        _positiveNAVDeltaUsed = used;
    }

    function _enforceDeployCaps(uint256 usdcE6) internal {
        if (block.number != _deployUsedBlockNum) {
            _deployUsedBlockNum = block.number;
            _deployUsedThisBlock = 0;
        }
        uint256 remainingBlock =
            _perBlockDeployCap > _deployUsedThisBlock ? _perBlockDeployCap - _deployUsedThisBlock : 0;
        if (usdcE6 > remainingBlock) revert PerBlockDeployCapExceeded(usdcE6, remainingBlock);
        _deployUsedThisBlock += usdcE6;

        if (block.timestamp >= _deployUsedDayStart + DAY_SECONDS) {
            _deployUsedDayStart = block.timestamp;
            _deployUsedThisDay = 0;
        }
        uint256 remainingDay = _perDayDeployCap > _deployUsedThisDay ? _perDayDeployCap - _deployUsedThisDay : 0;
        if (usdcE6 > remainingDay) revert PerDayDeployCapExceeded(usdcE6, remainingDay);
        _deployUsedThisDay += usdcE6;
    }

    function _recordCustodianDeployment(uint256 usdcE6) internal {
        ICustodianRegistryAccountingPort registry = ICustodianRegistryAccountingPort(custodianRegistry);
        registry.recordDeployment(registry.HYPERLIQUID_CUSTODIAN_ID(), usdcE6);
    }

    function _recordCustodianReturn(uint256 usdcE6, bool navAlreadyReduced) internal {
        ICustodianRegistryAccountingPort registry = ICustodianRegistryAccountingPort(custodianRegistry);
        bytes32 id = registry.HYPERLIQUID_CUSTODIAN_ID();
        registry.recordReturnWithNAVBasis(id, usdcE6, navAlreadyReduced);
    }

    function _enforceReturnCaps(uint256 amount) internal {
        uint256 principalBase = _deployedPrincipal;
        uint256 perCallCap = principalBase * _returnPerCallCapBps / BPS_DENOMINATOR;
        if (amount > perCallCap) revert ReturnPerCallCapExceeded(amount, perCallCap);

        if (block.timestamp >= _returnUsedDayStart + DAY_SECONDS) {
            _returnUsedDayStart = block.timestamp;
            _returnUsedThisDay = 0;
        }
        uint256 perDayCap = principalBase * _returnPerDayCapBps / BPS_DENOMINATOR;
        uint256 remainingDay = perDayCap > _returnUsedThisDay ? perDayCap - _returnUsedThisDay : 0;
        if (amount > remainingDay) revert ReturnPerDayCapExceeded(amount, remainingDay);
        _returnUsedThisDay += amount;
    }

    function _enforceWithdrawalIntentCaps(uint256 amount) internal {
        uint256 principalBase = _deployedPrincipal;
        uint256 perCallCap = principalBase * _returnPerCallCapBps / BPS_DENOMINATOR;
        if (amount > perCallCap) revert WithdrawalIntentAmountExceeded(amount, perCallCap);

        if (block.timestamp >= _withdrawalIntentUsedDayStart + DAY_SECONDS) {
            _withdrawalIntentUsedDayStart = block.timestamp;
            _withdrawalIntentUsedThisDay = 0;
        }
        uint256 perDayCap = principalBase * _returnPerDayCapBps / BPS_DENOMINATOR;
        uint256 remainingDay = perDayCap > _withdrawalIntentUsedThisDay ? perDayCap - _withdrawalIntentUsedThisDay : 0;
        if (amount > remainingDay) revert WithdrawalIntentAmountExceeded(amount, remainingDay);
        _withdrawalIntentUsedThisDay += amount;
    }

    function _consumeReconciledLiquidity(IERC20 token, uint256 amount) internal {
        uint256 available = _reconciledReturnLiquidity;
        if (amount > available) revert InsufficientReconciledLiquidity(amount, available);
        uint256 currentBalance = token.balanceOf(address(this));
        if (amount > currentBalance) revert InsufficientReconciledLiquidity(amount, currentBalance);
        _reconciledReturnLiquidity = available - amount;
    }

    function _unreconciledBalance(uint256 currentBalance) internal view returns (uint256) {
        uint256 reconciled = _reconciledReturnLiquidity;
        if (currentBalance < reconciled) revert ReconciledBalanceExceedsBalance(currentBalance, reconciled);
        return currentBalance - reconciled;
    }

    function _requireExecutor() internal view {
        ICustodianRegistryAccountingPort registry = ICustodianRegistryAccountingPort(custodianRegistry);
        if (!registry.hasCustodianRole(registry.HYPERLIQUID_CUSTODIAN_ID(), registry.ROLE_EXECUTOR(), msg.sender)) {
            revert UnauthorizedExecutor();
        }
    }

    function _requireKeeper() internal view {
        if (msg.sender != _keeper) revert UnauthorizedKeeper();
    }

    function _requireFreshDeployment() private view {
        uint64 observedVersion = _freshDeploymentVersion;
        if (observedVersion != FRESH_DEPLOYMENT_VERSION) revert FreshDeploymentRequired(observedVersion);
    }

    function _requireNoLossSettlementInProgress() private view {
        if (_lossSettlementInProgress) revert LossSettlementInProgress();
    }

    function _requireNotBlocked(address account) internal view {
        address blocklist_ = _blocklist;
        if (blocklist_ == address(0)) revert BlocklistUnavailable(blocklist_);
        try IBlocklist(blocklist_).isBlocked(account) returns (bool blocked) {
            if (blocked) revert BlockedAddress(account);
        } catch {
            revert BlocklistUnavailable(blocklist_);
        }
    }

    function _requireSequencerUp() internal view {
        address feed = _sequencerUptimeFeed;
        if (feed == address(0)) {
            if (block.chainid == ARBITRUM_ONE_CHAIN_ID) revert SequencerUptimeFeedUnavailable(feed);
            return;
        }

        try ISequencerUptimeFeed(feed).latestRoundData() returns (
            uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound
        ) {
            if (updatedAt == 0 || updatedAt > block.timestamp || answeredInRound < roundId) {
                revert SequencerUptimeFeedUnavailable(feed);
            }
            if (answer != 0) revert SequencerDown();
            if (
                startedAt == 0 || block.timestamp <= startedAt
                    || block.timestamp - startedAt <= SEQUENCER_UPTIME_GRACE_PERIOD
            ) {
                revert SequencerGracePeriodNotOver(startedAt, SEQUENCER_UPTIME_GRACE_PERIOD);
            }
        } catch (bytes memory reason) {
            if (reason.length >= 4) {
                bytes4 selector;
                assembly {
                    selector := mload(add(reason, 32))
                }
                if (
                    selector == SequencerUptimeFeedUnavailable.selector || selector == SequencerDown.selector
                        || selector == SequencerGracePeriodNotOver.selector
                ) {
                    assembly {
                        revert(add(reason, 32), mload(reason))
                    }
                }
            }
            revert SequencerUptimeFeedUnavailable(feed);
        }
    }

    function _liveGuardianModule() internal view returns (address) {
        address registry = custodianRegistry;
        if (registry.code.length == 0) revert GuardianRegistryUnavailable(registry);
        (bool ok, bytes memory data) =
            registry.staticcall(abi.encodeCall(ICustodianRegistryAccountingPort.guardianModule, ()));
        if (!ok || data.length != 32) revert GuardianModuleResolutionFailed(registry);
        uint256 moduleWord;
        assembly ("memory-safe") {
            moduleWord := mload(add(data, 32))
        }
        if (moduleWord > type(uint160).max) revert GuardianModuleResolutionFailed(registry);
        address module = address(uint160(moduleWord));
        if (module == address(0) || module.code.length == 0) revert InvalidGuardianModule(module);
        return module;
    }

    function _nextWithdrawalIntentNonce() internal returns (uint256 nonce) {
        uint256 current = _withdrawalIntentNonce;
        if (current == type(uint256).max) revert WithdrawalIntentNonceExhausted();
        nonce = current + 1;
        _withdrawalIntentNonce = nonce;
    }

    function _creditWithdrawalIntent(bytes32 intentId, WithdrawalIntent storage intent, uint256 delta) internal {
        uint256 amount = intent.amount;
        uint256 credited = intent.creditedAmount;
        if (credited > amount || delta == 0 || delta > amount - credited) {
            revert WithdrawalCreditOutOfBounds(intentId, credited, delta, amount);
        }

        uint256 unassigned = _unreconciledBalance(IERC20(usdc).balanceOf(address(this)));
        uint256 totalCredited = _totalCreditedReceipts;
        uint256 index = _receiptIndex(unassigned, totalCredited);
        uint256 baseline = intent.inflowBaseline;
        if (index < baseline) revert ReceiptIndexBelowBaseline(index, baseline);
        if (index - baseline < credited + delta) revert ArrivalAmountMismatch();
        if (unassigned < delta) revert InsufficientUnreconciledLiquidity(delta, unassigned);

        _reconciledReturnLiquidity += delta;
        _totalCreditedReceipts = totalCredited + delta;
        intent.creditedAmount = credited + delta;
    }

    function _creditUnassignedWithdrawalArrival(uint256 amount) internal {
        if (amount == 0) revert ZeroAmount();
        uint256 unassigned = _unreconciledBalance(IERC20(usdc).balanceOf(address(this)));
        if (amount > unassigned) revert InsufficientUnreconciledLiquidity(amount, unassigned);
        uint256 totalCredited = _totalCreditedReceipts;
        uint256 receiptIndex = _receiptIndex(unassigned, totalCredited);
        uint256 nextTotalCredited = receiptIndex - (unassigned - amount);
        _reconciledReturnLiquidity += amount;
        _totalCreditedReceipts = nextTotalCredited;
    }

    function _receiptIndex(uint256 unassigned, uint256 totalCredited) internal pure returns (uint256) {
        if (unassigned > type(uint256).max - totalCredited) {
            revert ReceiptIndexOverflow(unassigned, totalCredited);
        }
        return unassigned + totalCredited;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {
        _requireFreshDeployment();
        // Match the codebase's upgrade-wipes-pending-proposals norm (OF-L06).
        _pendingKeeper = address(0);
        _pendingKeeperProposedAt = 0;
    }
}
