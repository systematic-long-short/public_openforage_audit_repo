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
    function latestLossNonce() external view returns (uint256);
    function settledLossNonce() external view returns (uint256);
    function lossPendingVaultId() external view returns (uint256);
    function latestLossAmount() external view returns (uint256);
    function lossPending() external view returns (bool);
}

interface IUSDCTreasuryLossSettlement {
    function settleLoss(uint256 vaultId, uint256 lossNonce) external;
}

interface ICustodianRegistryAccountingPort {
    function HYPERLIQUID_CUSTODIAN_ID() external view returns (bytes32);
    function ROLE_EXECUTOR() external view returns (bytes32);
    function guardianModule() external view returns (address);
    function hasCustodianRole(bytes32 id, bytes32 role, address account) external view returns (bool);
    function paused() external view returns (bool);
    function recordDeployment(bytes32 id, uint256 amount) external;
    function recordReturn(bytes32 id, uint256 amount) external;
    function recordEmergencyReturn(bytes32 id, uint256 amount) external;
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
    error IncompatibleLegacyLayout();
    error ExcessiveLossWriteDown(uint256 amount, uint256 deployedPrincipal);
    error LossNonceMismatch(uint256 provided, uint256 expected);
    error NoPendingLoss();
    error LossSettlementIncomplete(uint256 lossNonce);

    uint256 public constant DAY_SECONDS = 1 days;
    uint256 public constant PROPOSAL_EXPIRY = 30 days;
    uint256 public constant ARBITRUM_ONE_CHAIN_ID = 42_161;
    uint256 public constant SEQUENCER_UPTIME_GRACE_PERIOD = 1 hours;
    uint16 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant DEFAULT_WITHDRAWAL_INTENT_TIMEOUT_SECONDS = 7 days;

    address public usdc;
    address public riskusdVault;
    address public usdcTreasury;
    address public custodianRegistry;
    address public guardianModule;

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
        uint256 balanceCheckpoint;
        uint256 createdAt;
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
    uint256[49] private __gap;

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
    event AttestedLossSettled(uint256 indexed vaultId, uint256 indexed lossNonce, uint256 amount);

    constructor() {
        _disableInitializers();
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
    ) external initializer {
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
        guardianModule = guardianModule_;
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
        emit SequencerUptimeFeedSet(address(0), route.sequencerUptimeFeed);
    }

    /// @notice Initializes the appended sequencer feed for an exact compatible legacy proxy.
    /// @dev The typed route guards reject proxies initialized under the shifted storage layout. The exact slot-word
    ///      check rejects any origin that already used the newly appended slot.
    function initializeSequencerUptimeFeed(address sequencerUptimeFeed_)
        external
        onlyAllowedCaller
        onlyOwner
        reinitializer(2)
    {
        if (sequencerUptimeFeed_ == address(0)) revert ZeroAddress();

        uint256 sequencerFeedSlotWord;
        assembly ("memory-safe") {
            sequencerFeedSlotWord := sload(_sequencerUptimeFeed.slot)
        }
        if (sequencerFeedSlotWord != 0) revert IncompatibleLegacyLayout();
        if (coldAccount == address(0) || hyperliquidSourceAccount == bytes32(0) || withdrawalChainSelector == 0) {
            revert IncompatibleLegacyLayout();
        }

        _sequencerUptimeFeed = sequencerUptimeFeed_;
        emit SequencerUptimeFeedSet(address(0), sequencerUptimeFeed_);
    }

    function deployToHyperLiquid(uint256 usdcE6) external onlyAllowedCaller whenNotPaused nonReentrant {
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

        emit DeployedToHyperLiquid(usdcE6, _deployedPrincipal);
    }

    function postNAV(uint256 vaultId, uint256 bookValue, uint256 rawNav, uint256 observedAt)
        external
        onlyAllowedCaller
        whenNotPaused
        nonReentrant
    {
        _requireKeeper();
        _requireNotBlocked(msg.sender);

        uint256 applied = _normalizeCustodianNAV(bookValue, rawNav, observedAt, _appliedNAV, true);
        uint256 vaultNav = _normalizeAppliedNAVToCurrentBook(bookValue, applied);
        // Risk-reducing (loss-recording) posts are allowed through sequencer down/grace/unavailable
        // windows: recording a true loss only ever tightens consumer gates. Neutral and up posts
        // remain fully gated, failing closed while the feed cannot vouch for liveness.
        if (vaultNav >= _deployedPrincipal) {
            _requireSequencerUp();
        }

        _lastNAVBookValue = bookValue;
        _lastNAVRawValue = rawNav;
        _lastNAVObservedAt = observedAt;
        _appliedNAV = applied;
        if (_pendingDeployPrincipal != 0 && vaultNav >= _deployedPrincipal) {
            _pendingDeployPrincipal = 0;
        }
        uint256 lossNonce = 0;
        if (vaultNav < _deployedPrincipal) {
            lossNonce = IRISKUSDVaultNAVPort(riskusdVault).latestLossNonce() + 1;
        }
        IRISKUSDVaultNAVPort(riskusdVault).recordCustodianNAV(vaultId, vaultNav, lossNonce, observedAt);

        emit NAVPosted(vaultId, bookValue, rawNav, applied, observedAt);
    }

    function returnPrincipalUSDC(uint256 amount) external onlyAllowedCaller nonReentrant {
        _requireExecutor();
        _returnPrincipalUSDC(amount, false);
    }

    function returnPrincipalUSDCWithNAVBasis(uint256 amount, bool navAlreadyReduced)
        external
        onlyAllowedCaller
        nonReentrant
    {
        _requireExecutor();
        _returnPrincipalUSDC(amount, navAlreadyReduced);
    }

    function returnZeroPrincipalUSDC(uint256 amount, bool navAlreadyReduced)
        external
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
        _requireNotBlocked(msg.sender);
        _requireNotBlocked(address(this));
        _requireNotBlocked(riskusdVault);
        if (amount >= _deployedPrincipal) {
            _deployedPrincipal = 0;
        } else {
            _deployedPrincipal -= amount;
        }
        if (amount >= _pendingDeployPrincipal) {
            _pendingDeployPrincipal = 0;
        } else {
            _pendingDeployPrincipal -= amount;
        }

        IERC20 token = IERC20(usdc);
        _consumeReconciledLiquidity(token, amount);
        _recordCustodianReturn(amount);
        token.forceApprove(riskusdVault, amount);
        IRISKUSDVaultCustodyPort(riskusdVault).returnCapitalWithNAVBasis(amount, navAlreadyReduced);
        token.forceApprove(riskusdVault, 0);
        IUSDCTreasuryReturnPort(usdcTreasury).recordPrincipalReturnUSDC(amount);
        emit PrincipalReturned(amount, _deployedPrincipal);
    }

    function recordLossWriteDown(uint256 amount)
        external
        onlyAllowedCaller
        nonReentrant
        returns (uint256 writtenDown)
    {
        if (msg.sender != riskusdVault) revert UnauthorizedVault(msg.sender);
        if (amount == 0) revert ZeroAmount();
        uint256 principal = _deployedPrincipal;
        if (amount > principal) revert ExcessiveLossWriteDown(amount, principal);

        _deployedPrincipal = principal - amount;

        ICustodianRegistryAccountingPort registry = ICustodianRegistryAccountingPort(custodianRegistry);
        uint256 recordedAmount = registry.recordLoss(registry.HYPERLIQUID_CUSTODIAN_ID(), amount);
        if (recordedAmount != amount) revert ExcessiveLossWriteDown(amount, principal);

        emit PrincipalLossWrittenDown(amount, _deployedPrincipal, _pendingDeployPrincipal);
        return amount;
    }

    function settleLoss(uint256 lossNonce) external onlyAllowedCaller whenNotPaused {
        IRISKUSDVaultNAVPort centralVault = IRISKUSDVaultNAVPort(riskusdVault);
        uint256 latestNonce = centralVault.latestLossNonce();
        if (lossNonce == 0 || lossNonce != latestNonce || lossNonce <= centralVault.settledLossNonce()) {
            revert LossNonceMismatch(lossNonce, latestNonce);
        }
        uint256 vaultId = centralVault.lossPendingVaultId();
        uint256 amount = centralVault.latestLossAmount();
        if (vaultId == 0 || amount == 0 || !centralVault.lossPending()) revert NoPendingLoss();

        IUSDCTreasuryLossSettlement(usdcTreasury).settleLoss(vaultId, lossNonce);
        if (
            centralVault.settledLossNonce() != lossNonce || centralVault.latestLossAmount() != 0
                || centralVault.lossPending()
        ) revert LossSettlementIncomplete(lossNonce);
        emit AttestedLossSettled(vaultId, lossNonce, amount);
    }

    function returnPnLUSDC(uint256 vaultId, uint256 amount) external onlyAllowedCaller nonReentrant {
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
    ) external onlyAllowedCaller onlyOwner nonReentrant returns (bytes32 intentId) {
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

        intentId = keccak256(
            abi.encode(address(this), msg.sender, amount, recipient, sourceAccount, chainSelector, block.number)
        );
        bytes32 openIntentId = _openWithdrawalIntentId;
        if (openIntentId != bytes32(0)) revert WithdrawalIntentPending(openIntentId);
        uint256 balanceCheckpoint = _unreconciledBalance(IERC20(usdc).balanceOf(address(this)));
        _withdrawalIntents[intentId] = WithdrawalIntent({
            amount: amount,
            recipient: recipient,
            sourceAccount: sourceAccount,
            chainSelector: chainSelector,
            consumed: false,
            exists: true,
            balanceCheckpoint: balanceCheckpoint,
            createdAt: block.timestamp
        });
        _openWithdrawalIntentId = intentId;

        emit WithdrawalIntentRequested(intentId, amount, recipient, sourceAccount, chainSelector);
    }

    function reconcileWithdrawalArrival(bytes32 intentId, uint256 arrivedAmount)
        external
        onlyAllowedCaller
        nonReentrant
    {
        _requireKeeper();
        _requireNotBlocked(msg.sender);
        WithdrawalIntent storage intent = _withdrawalIntents[intentId];
        if (!intent.exists || intent.consumed) revert RequestMismatch();
        if (intentId != _openWithdrawalIntentId) revert RequestMismatch();
        if (arrivedAmount != intent.amount) revert ArrivalAmountMismatch();

        uint256 currentBalance = IERC20(usdc).balanceOf(address(this));
        uint256 unreconciledBalance = _unreconciledBalance(currentBalance);
        if (unreconciledBalance < intent.balanceCheckpoint + arrivedAmount) revert ArrivalAmountMismatch();

        _reconciledReturnLiquidity += arrivedAmount;
        intent.consumed = true;
        if (intentId == _openWithdrawalIntentId) {
            _openWithdrawalIntentId = bytes32(0);
        }
        emit WithdrawalArrivalReconciled(intentId, arrivedAmount);
    }

    function cancelWithdrawalIntent(bytes32 intentId) external onlyAllowedCaller nonReentrant {
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
        _openWithdrawalIntentId = bytes32(0);
        emit WithdrawalIntentCancelled(intentId);
    }

    function setDirectionalFreeze(bool frozen) external onlyAllowedCaller {
        _requireGuardianModuleOrOwner();
        if (msg.sender == _liveGuardianModule() && !frozen) revert GuardianCannotLoosen();
        _setDirectionalFreeze(frozen);
    }

    function freezeAttestations() external onlyAllowedCaller {
        _requireGuardianModuleOrOwner();
        _setDirectionalFreeze(true);
    }

    function pause() external onlyAllowedCaller {
        if (msg.sender != _liveGuardianModule() && msg.sender != owner()) revert UnauthorizedPause();
        _pause();
    }

    function unpause() external onlyAllowedCaller onlyOwner {
        _unpause();
    }

    function proposeKeeper(address newKeeper) external onlyAllowedCaller onlyOwner {
        if (newKeeper == address(0)) revert ZeroAddress();
        _pendingKeeper = newKeeper;
        _pendingKeeperProposedAt = block.timestamp;
        emit KeeperProposed(_keeper, newKeeper);
    }

    function finalizeKeeper() external onlyAllowedCaller onlyOwner {
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

    function cancelPendingKeeper() external onlyAllowedCaller onlyOwner {
        address pending = _pendingKeeper;
        if (pending == address(0)) revert NoPendingKeeper();
        _pendingKeeper = address(0);
        _pendingKeeperProposedAt = 0;
        emit PendingKeeperCancelled(pending);
    }

    function setBlocklist(address blocklist_) external onlyAllowedCaller onlyOwner {
        if (blocklist_ == address(0)) revert ZeroAddress();
        address old = _blocklist;
        _blocklist = blocklist_;
        emit BlocklistSet(old, blocklist_);
    }

    function setAllowlist(address allowlist_) external onlyOwner {
        _setAllowlist(allowlist_);
    }

    function setSequencerUptimeFeed(address feed_) external onlyAllowedCaller onlyOwner {
        if (feed_ == address(0)) revert ZeroAddress();
        // Same typed-route guards as initializeSequencerUptimeFeed: a proxy initialized under the
        // shifted legacy layout reads zero here and must not have a feed silently bound to it.
        if (coldAccount == address(0) || hyperliquidSourceAccount == bytes32(0) || withdrawalChainSelector == 0) {
            revert IncompatibleLegacyLayout();
        }
        address old = _sequencerUptimeFeed;
        _sequencerUptimeFeed = feed_;
        emit SequencerUptimeFeedSet(old, feed_);
    }

    function setPerBlockDeployCap(uint256 newCap) external onlyAllowedCaller onlyOwner {
        if (newCap == 0) revert ZeroAmount();
        _setPerBlockDeployCap(newCap);
    }

    function setPerDayDeployCap(uint256 newCap) external onlyAllowedCaller onlyOwner {
        if (newCap == 0) revert ZeroAmount();
        _setPerDayDeployCap(newCap);
    }

    function setReturnCapitalCaps(uint16 perCallBps, uint16 perDayBps) external onlyAllowedCaller onlyOwner {
        _validateReturnCapitalCaps(perCallBps, perDayBps);
        _setReturnCapitalCaps(perCallBps, perDayBps);
    }

    function shrinkPerBlockDeployCap(uint256 newCap) external onlyAllowedCaller {
        _requireGuardianModuleOrOwner();
        if (newCap == 0) revert ZeroAmount();
        if (newCap > _perBlockDeployCap) revert GuardianCannotLoosen();
        _setPerBlockDeployCap(newCap);
    }

    function shrinkPerDayDeployCap(uint256 newCap) external onlyAllowedCaller {
        _requireGuardianModuleOrOwner();
        if (newCap == 0) revert ZeroAmount();
        if (newCap > _perDayDeployCap) revert GuardianCannotLoosen();
        _setPerDayDeployCap(newCap);
    }

    function tightenReturnCapitalCaps(uint16 perCallBps, uint16 perDayBps) external onlyAllowedCaller {
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

    function _requireGuardianModuleOrOwner() internal view {
        if (msg.sender != _liveGuardianModule() && msg.sender != owner()) revert UnauthorizedPause();
    }

    function renounceOwnership() public view override onlyOwner {
        revert RenounceOwnershipDisabled();
    }

    function upgradeToAndCall(address newImplementation, bytes memory data) public payable override onlyAllowedCaller {
        super.upgradeToAndCall(newImplementation, data);
    }

    function transferOwnership(address newOwner) public override onlyAllowedCaller {
        super.transferOwnership(newOwner);
    }

    function acceptOwnership() public override onlyAllowedCaller {
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

    function normalizeManualCustodianNAV(uint256, uint256 nav, uint256 lossNonce)
        external
        view
        returns (bool, uint256)
    {
        if (msg.sender != riskusdVault) revert UnauthorizedVault(msg.sender);
        if (lossNonce != 0) {
            if (_directionalFreeze) {
                uint256 manualObservationNav = _normalizeCurrentBookNAVToObservationBook(_lastNAVBookValue, nav);
                if (manualObservationNav > _appliedNAV) revert DirectionFrozen();
            }
            return (true, nav);
        }

        uint256 observedAt = _lastNAVObservedAt;
        uint256 bookValue = _lastNAVBookValue;

        uint256 observationBookNav = _normalizeCurrentBookNAVToObservationBook(bookValue, nav);
        uint256 normalizedObs = _normalizeCustodianNAV(bookValue, observationBookNav, observedAt, _appliedNAV, false);
        uint256 normalizedNav = _normalizeAppliedNAVToCurrentBook(bookValue, normalizedObs);
        if (normalizedNav < _deployedPrincipal) return (false, 0);

        return (true, normalizedNav);
    }

    /// @notice Rebases a normalized observation-book NAV into current-book units: `applied` is
    /// denominated in the keeper observation book (`bookValue`), and the return is denominated in
    /// the current deployment book (`_deployedPrincipal`). Exact inverse of
    /// `_normalizeCurrentBookNAVToObservationBook`: one normalization home, no forked unit math.
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

    /// @notice Inverts a current-book NAV into observation-book units: `nav` is denominated in the
    /// current deployment book (`_deployedPrincipal`), and the return is denominated in the keeper
    /// observation book (`bookValue`). Exact mirror of `_normalizeAppliedNAVToCurrentBook`, so
    /// manual current-book reports are capped and freeze-checked in the same units as keeper posts.
    function _normalizeCurrentBookNAVToObservationBook(uint256 bookValue, uint256 nav)
        internal
        view
        returns (uint256)
    {
        uint256 principal = _deployedPrincipal;
        uint256 normalized;
        if (principal >= bookValue) {
            uint256 deployedAfterObservation = principal - bookValue;
            normalized = nav > deployedAfterObservation ? nav - deployedAfterObservation : 0;
        } else {
            normalized = nav + (bookValue - principal);
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

        uint256 maxUp = bookValue + (bookValue * 1_000 / BPS_DENOMINATOR);
        uint256 cappedNav = rawNav > maxUp ? maxUp : rawNav;
        if (_directionalFreeze) {
            uint256 frozenComparison = _normalizeAppliedNAVToCurrentBook(_lastNAVBookValue, currentAppliedNAV);
            uint256 cappedNavCurrentBook = _normalizeAppliedNAVToCurrentBook(bookValue, cappedNav);
            if (cappedNavCurrentBook > frozenComparison) revert DirectionFrozen();
        }
        return cappedNav;
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

    function _recordCustodianReturn(uint256 usdcE6) internal {
        ICustodianRegistryAccountingPort registry = ICustodianRegistryAccountingPort(custodianRegistry);
        bytes32 id = registry.HYPERLIQUID_CUSTODIAN_ID();
        if (registry.paused()) {
            registry.recordEmergencyReturn(id, usdcE6);
        } else {
            registry.recordReturn(id, usdcE6);
        }
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
        return currentBalance > reconciled ? currentBalance - reconciled : 0;
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
        address liveGuardianModule = ICustodianRegistryAccountingPort(custodianRegistry).guardianModule();
        if (liveGuardianModule == address(0)) revert UnauthorizedPause();
        return liveGuardianModule;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {
        // Match the codebase's upgrade-wipes-pending-proposals norm (OF-L06).
        _pendingKeeper = address(0);
        _pendingKeeperProposedAt = 0;
    }
}
