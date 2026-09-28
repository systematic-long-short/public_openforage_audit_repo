// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
/// @dev OF-16-006: OZ 5.x ReentrancyGuard uses ERC-7201 namespaced storage — inherently upgrade-safe.
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./IForageGovernorPause.sol";
import "./FinalizeDelayProfile.sol";
import "./AllowlistGatedUpgradeable.sol";
import "./interfaces/IBlocklist.sol";
import "./interfaces/IAllowlist.sol";
import "./interfaces/IVaultRegistry.sol";
import "./interfaces/IUSDCTreasuryYieldClaims.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import {AtRiskUSDStateModule, AtRiskUSDStateModuleStorage} from "./modules/AtRiskUSDStateModule.sol";

/// @title atRISKUSD — Tier-specific ERC-4626 vault backed by RISKUSD
contract atRISKUSD is
    Initializable,
    ERC4626Upgradeable,
    Ownable2StepUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuard,
    FinalizeDelayProfile,
    AllowlistGatedUpgradeable
{
    using SafeERC20 for IERC20;

    AtRiskUSDStateModule private immutable _stateModule;

    // ============================================================
    // Errors
    // ============================================================
    error UnauthorizedStakingQueue();
    error UnauthorizedYieldSource();
    error PendingWithdrawalExists();
    error NoPendingWithdrawal();
    error CooldownNotElapsed(uint256 unlockTime);
    error CooldownEnabled();
    error LockupNotExpired(uint256 lockExpiry);
    error ZeroAmount();
    error ZeroAddress();
    error InvalidTier();
    error AutoRenewEnabled();
    error AutoRenewDisabled();
    error RenounceOwnershipDisabled();
    error SlippageExceeded(uint256 amountOut, uint256 minAmountOut); // OF-M11
    error NotPendingYieldSource();
    error NotPendingStakingQueue();
    error LossPending(); // OF-001 (11th audit)
    error CustodianSettlementPending();
    error FinalizeDelayNotElapsed(); // OF-002 (11th audit)
    error ProposalExpired(); // OF-002 (11th audit)
    error NoPendingForageGovernor(); // OF-15-005
    error YieldSourceUnreachable(); // OF-16-019
    error CannotOverrideDuringActiveLoss(); // OF-18-004
    error ExchangeRateDecreased(uint256 beforeAssets, uint256 afterAssets);
    error WeeklyWithdrawalCapExceeded(uint256 requested, uint256 remaining);
    error CapTighteningOnly();
    error BlockedAddress(address account);
    error ZeroAssetLegacySupply();
    error EmptyAbbreviation();
    error CustodianSettlementHookFailed(address custodian);
    error EmergencyOverrideValidationFailed(address yieldSource);
    error ZeroRedemptionOutput();
    error ExpiredAutoRenewDisabledLockup();
    error InsufficientAllowlistDuration(uint256 requiredUntil, uint256 allowedUntil);
    error AllowlistHorizonOverflow();
    error BeneficiaryNotAllowed(address account);
    error UnsupportedPendingWithdrawalLayout(uint8 sourceLayout);
    error AmbiguousPendingWithdrawalLayout(address requester);
    error PendingWithdrawalMigrationRequired(address requester);
    error PendingWithdrawalMigrationAlreadyConfirmed(address requester);
    error PendingWithdrawalShareRecoveryUnavailable(address requester, uint256 shares, uint256 escrowed);
    error PendingWithdrawalShareRecoveryNotNeeded(address requester);
    error EmergencyRecoveryWindowClosed();
    error YieldSourceReachable();
    error NotTotalLossState();
    error YieldClaimsUnavailable(address source);
    error YieldClaimsNotReady(address source);
    error YieldSourceClaimOutstanding(address source, uint256 claim);
    error YieldSourceWiringMismatch(address source);
    error YieldSourceAttestorUnavailable(address source, address attestor);
    error YieldSourceCallerNotEligible(address source, address caller);
    error YieldSourceBridgeUnavailable(address source, address bridge);
    error YieldSourceBridgeRouteMismatch(
        address source, address bridge, address expectedTreasury, address actualTreasury
    );
    error YieldAssetValueOverflow(uint256 funded, uint256 claim);
    error UnfundedZeroSupplyClaim(uint256 claim);
    error ZeroSupplyYield();
    error InsufficientFundedAssets(uint256 requested, uint256 available);
    error FinalClaimBurn(uint256 claim);
    error NoPositiveWithdrawalSlice(uint256 remainingCap);
    error ExpiryHeapInvariant(uint256 expiry);
    error ModuleReturnDataInvalid();
    error SafeERC20FailedOperation(address token);

    // ============================================================
    // Events
    // ============================================================
    event YieldAccrued(uint256 riskusdAmount);
    event LossAbsorbed(uint256 riskusdAmount);
    event WithdrawalRequested(
        address indexed requester, uint256 atriskusdAmount, uint256 riskusdAmount, uint256 cooldownEnd
    );
    event WithdrawalExecuted(address indexed requester, uint256 riskusdAmount);
    event WithdrawalCancelled(address indexed requester, uint256 atriskusdAmount);
    event LockupTransferred(address indexed from, address indexed to, uint256 lockExpiry);
    event YieldSourceUpdated(address indexed oldSource, address indexed newSource);
    event StakingQueueUpdated(address indexed oldQueue, address indexed newQueue);
    event ForageGovernorSet(address indexed oldGovernor, address indexed newGovernor);
    event CooldownPeriodUpdated(uint256 oldCooldown, uint256 newCooldown);
    event AutoRenewChanged(address indexed depositor, bool enabled);
    event LockupRenewed(address indexed depositor, uint256 newExpiry);
    event YieldSourceProposed(address indexed currentSource, address indexed pendingSource);
    event StakingQueueProposed(address indexed currentQueue, address indexed pendingQueue);
    event ForageGovernorProposed(address indexed current, address indexed pending); // OF-15-005
    event DeprecatedWithdrawalUsed(address indexed depositor, uint256 amount);
    event EmergencyLossPendingOverrideSet(bool override_); // OF-17-003
    event ExchangeRateInvariantFailure(uint256 beforeAssets, uint256 afterAssets);
    event WeeklyWithdrawalCapBpsUpdated(uint256 oldBps, uint256 newBps);
    event BlocklistSet(address indexed oldBlocklist, address indexed newBlocklist);
    event PendingWithdrawalLayoutMigrated(address indexed requester, uint256 cooldownPeriod);
    event PendingWithdrawalSharesRecovered(address indexed requester, uint256 shares);
    event EmergencyOverrideWindowOpened(uint64 expiresAt);
    event UnreachableWithdrawalRecovered(address indexed beneficiary, uint256 shares);
    event WorthlessSharesBurned(address indexed holder, uint256 shares);

    // ============================================================
    // Structs
    // ============================================================
    struct PendingWithdrawal {
        uint256 atriskusdAmount;
        uint256 riskusdAmount;
        uint256 requestTimestamp;
        bool active; // OF-001: moved before cooldownPeriod for storage packing
        uint256 cooldownPeriod; // OF-M03: snapshot at request time
        uint256 weeklyCapWindowStart;
        uint256 weeklyCapReservedAssets;
    }

    enum PendingWithdrawalLayout {
        ActiveFirst,
        CooldownFirst,
        ShareOnlyRecovery
    }

    enum PendingWithdrawalMigrationState {
        Unconfirmed,
        Confirmed,
        SharesRecovering
    }

    // ============================================================
    // State
    // ============================================================
    address private _yieldSource;
    address private _stakingQueue;
    address private _forageGovernor;
    uint8 private _tierId;
    uint256 private _lockupPeriod;
    uint256 private _cooldownPeriod;
    mapping(address => uint256) private _lockExpiry;
    mapping(address => PendingWithdrawal) private _pendingWithdrawals;
    uint256 private _totalYieldAccrued;
    uint256 private _totalLossAbsorbed;
    mapping(address => bool) private _autoRenewDisabled;
    uint256 private _legitimateAssets;
    /// @dev OF-H02: Pending addresses for two-step critical setter handoff
    address private _pendingYieldSource;
    address private _pendingStakingQueue;
    /// @dev OF-002 (11th audit): Proposal timestamps for finalize delay enforcement
    uint256 private _yieldSourceProposedAt;
    uint256 private _stakingQueueProposedAt;
    /// @dev OF-15-005: Pending ForageGovernor for two-step setter
    address internal _pendingForageGovernor;
    uint256 internal _pendingForageGovernorProposedAt;
    /// @dev OF-16-019: Emergency override when yield source is permanently unreachable.
    /// The flag only opens a bounded share-return recovery path; it never bypasses loss checks.
    bool private _emergencyLossPendingOverride;
    uint64 private _emergencyLossPendingOverrideUntil;
    uint256 private _weeklyWithdrawalCapBps;
    uint256 private _weeklyWithdrawalUsed;
    uint256 private _weeklyWithdrawalWindowStart;
    uint256 private _weeklyWithdrawalWindowStartAssets;
    address internal _blocklist;
    mapping(address => bool) private _autoRenewDisabledTracked;
    mapping(address => uint256) private _autoRenewDisabledTrackedExpiry;
    mapping(uint256 => uint256) private _autoRenewDisabledExpiryCounts;
    uint256[] private _autoRenewDisabledExpiryHeap;
    uint256 private _autoRenewDisabledTrackedCount;
    uint256 private _earliestAutoRenewDisabledExpiry;
    mapping(address => PendingWithdrawalMigrationState) private _pendingWithdrawalMigrationState;
    mapping(uint256 => uint256) private _autoRenewDisabledExpiryHeapIndexPlusOne;
    uint256[29] private __gap;

    // Constants
    uint256 public constant PROPOSAL_EXPIRY = 30 days; // OF-002 (11th audit)
    uint256 public constant WEEKLY_WITHDRAWAL_WINDOW = 7 days;
    uint256 public constant DEFAULT_WEEKLY_WITHDRAWAL_CAP_BPS = 500;
    uint64 internal constant EMERGENCY_RECOVERY_WINDOW = 7 days;
    uint256 internal constant RAY = 1e27;
    uint256 internal constant SHARE_SCALE = 1e6;

    // ============================================================
    // Constructor
    // ============================================================
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
        _stateModule = new AtRiskUSDStateModule();
    }

    // ============================================================
    // Initializer
    // ============================================================
    function initialize(
        address riskusd_,
        address yieldSource_,
        address stakingQueue_,
        uint256 lockupPeriod_,
        uint256 cooldownPeriod_,
        uint8 tierId_,
        string memory abbreviation_,
        address initialOwner_
    ) external initializer {
        if (riskusd_ == address(0)) revert ZeroAddress();
        // yieldSource_ and stakingQueue_ may be address(0) at deploy time (circular dependency);
        // owner calls setYieldSource() / setStakingQueue() after dependent contracts are deployed.
        if (initialOwner_ == address(0)) revert ZeroAddress();

        if (tierId_ >= 4) revert InvalidTier();

        __ERC4626_init(IERC20(riskusd_));
        _initializeMetadata(abbreviation_);
        __Ownable_init(initialOwner_);
        __Pausable_init();
        _yieldSource = yieldSource_;
        _stakingQueue = stakingQueue_;
        _lockupPeriod = lockupPeriod_;
        _cooldownPeriod = cooldownPeriod_;
        _tierId = tierId_;
        _weeklyWithdrawalCapBps = DEFAULT_WEEKLY_WITHDRAWAL_CAP_BPS;
        _weeklyWithdrawalWindowStart = block.timestamp;
    }

    // ============================================================
    // Core ERC-4626 Entry (StakingQueue-only)
    // ============================================================
    function deposit(uint256 assets, address receiver)
        public
        override
        onlyAllowedCaller
        whenNotPaused
        nonReentrant
        returns (uint256)
    {
        if (msg.sender != _stakingQueue) revert UnauthorizedStakingQueue();
        if (assets == 0) revert ZeroAmount();
        _requireNoLossPending(); // OF-13-056: Block fresh inflows during loss
        _requireNoUnfundedZeroSupplyClaim();
        _requireNoZeroAssetLegacySupply();
        _requireNotBlocked(msg.sender);
        _requireNotBlocked(receiver);
        _requireAllowedBeneficiary(receiver);
        _requirePendingWithdrawalLayoutReady(receiver);
        _extendLockup(receiver);
        return _delegateStateModuleUint(abi.encodeCall(AtRiskUSDStateModule.deposit, (assets, receiver)));
    }

    function mint(uint256 shares, address receiver)
        public
        override
        onlyAllowedCaller
        whenNotPaused
        nonReentrant
        returns (uint256)
    {
        if (msg.sender != _stakingQueue) revert UnauthorizedStakingQueue();
        if (shares == 0) revert ZeroAmount();
        _requireNoLossPending(); // OF-14-002: Block mint during lossPending (same as deposit)
        _requireNoUnfundedZeroSupplyClaim();
        _requireNoZeroAssetLegacySupply();
        _requireNotBlocked(msg.sender);
        _requireNotBlocked(receiver);
        _requireAllowedBeneficiary(receiver);
        _requirePendingWithdrawalLayoutReady(receiver);
        _extendLockup(receiver);
        return _delegateStateModuleUint(abi.encodeCall(AtRiskUSDStateModule.mint, (shares, receiver)));
    }

    // ============================================================
    // ERC-4626 Internal Overrides (legitimate asset tracking)
    // ============================================================
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        super._deposit(caller, receiver, assets, shares);
        _legitimateAssets += assets;
        _notifyVaultRegistryAssetsChanged();
    }

    function _withdraw(address caller, address receiver, address owner_, uint256 assets, uint256 shares)
        internal
        override
    {
        super._withdraw(caller, receiver, owner_, assets, shares);
        _decreaseLegitimateAssets(assets);
    }

    // ============================================================
    // ERC-4626 Withdraw/Redeem Override (cooldown gated)
    // ============================================================
    /// @dev OF-15-029: Added nonReentrant for defense-in-depth on withdrawal paths.
    function withdraw(uint256 assets, address receiver, address _owner)
        public
        override
        onlyAllowedCaller
        whenNotPaused
        nonReentrant
        returns (uint256)
    {
        if (assets == 0) revert ZeroAmount();
        if (block.timestamp < _lockExpiry[_owner]) revert LockupNotExpired(_lockExpiry[_owner]);
        if (_cooldownPeriod > 0) revert CooldownEnabled();
        _requireNoLossPending();
        _requireNotBlocked(msg.sender);
        _requireNotBlocked(receiver);
        _requireNotBlocked(_owner);
        _requireAllowedBeneficiary(receiver);
        _requireAllowedBeneficiary(_owner);
        _requirePendingWithdrawalLayoutReady(_owner);
        return _delegateStateModuleUint(abi.encodeCall(AtRiskUSDStateModule.withdraw, (assets, receiver, _owner)));
    }

    /// @dev OF-15-029: Added nonReentrant for defense-in-depth on withdrawal paths.
    function redeem(uint256 shares, address receiver, address _owner)
        public
        override
        onlyAllowedCaller
        whenNotPaused
        nonReentrant
        returns (uint256)
    {
        if (block.timestamp < _lockExpiry[_owner]) revert LockupNotExpired(_lockExpiry[_owner]);
        if (_cooldownPeriod > 0) revert CooldownEnabled();
        _requireNoLossPending();
        _requireNotBlocked(msg.sender);
        _requireNotBlocked(receiver);
        _requireNotBlocked(_owner);
        _requireAllowedBeneficiary(receiver);
        _requireAllowedBeneficiary(_owner);
        _requirePendingWithdrawalLayoutReady(_owner);
        return _delegateStateModuleUint(abi.encodeCall(AtRiskUSDStateModule.redeem, (shares, receiver, _owner)));
    }

    // ============================================================
    // ERC-4626 max* overrides (cooldown gated)
    // ============================================================
    function maxDeposit(address receiver) public view override returns (uint256) {
        if (
            paused() || msg.sender != _stakingQueue || receiver == address(0) || !_isAllowedAccount(msg.sender)
                || !_isAllowedAccount(receiver) || _isBlockedForView(msg.sender) || _isBlockedForView(receiver)
                || !_isLossClearForView() || _hasZeroAssetLegacySupply() || !_pendingWithdrawalLayoutReadyForView(receiver)
                || (totalSupply() == 0 && _unfundedYieldClaim() != 0)
        ) return 0;
        return super.maxDeposit(receiver);
    }

    function maxMint(address receiver) public view override returns (uint256) {
        if (
            paused() || msg.sender != _stakingQueue || receiver == address(0) || !_isAllowedAccount(msg.sender)
                || !_isAllowedAccount(receiver) || _isBlockedForView(msg.sender) || _isBlockedForView(receiver)
                || !_isLossClearForView() || _hasZeroAssetLegacySupply() || !_pendingWithdrawalLayoutReadyForView(receiver)
                || (totalSupply() == 0 && _unfundedYieldClaim() != 0)
        ) return 0;
        return super.maxMint(receiver);
    }

    function maxWithdraw(address owner_) public view override returns (uint256) {
        if (!_canWithdrawInView(owner_)) return 0;
        uint256 shares = _sharesRedeemableWithFunds(owner_);
        uint256 assets = previewRedeem(shares);
        uint256 capRemaining = weeklyWithdrawalRemaining();
        return assets < capRemaining ? assets : capRemaining;
    }

    function maxRedeem(address owner_) public view override returns (uint256) {
        if (!_canWithdrawInView(owner_)) return 0;
        uint256 shares = _sharesRedeemableWithFunds(owner_);
        uint256 capRemaining = weeklyWithdrawalRemaining();
        if (previewRedeem(shares) > capRemaining) shares = _sharesWithinAssetCap(capRemaining, shares);
        if (shares == 0 || previewRedeem(shares) == 0) return 0;
        return shares;
    }

    // ============================================================
    // Yield/Loss Controls (yieldSource-only)
    // ============================================================
    function accrueYield(uint256 riskusdAmount) external onlyAllowedCaller whenNotPaused nonReentrant {
        if (msg.sender != _yieldSource) revert UnauthorizedYieldSource();
        if (riskusdAmount == 0) revert ZeroAmount();
        if (totalSupply() == 0) revert ZeroSupplyYield();
        _requireNoZeroAssetLegacySupply();
        _requireNotBlocked(msg.sender);
        _delegateStateModule(abi.encodeCall(AtRiskUSDStateModule.accrueYield, (riskusdAmount)));
    }

    /// @dev OF-L22: Loss reporting must work even when paused. Auth-gated by _yieldSource.
    function absorbLoss(uint256 riskusdAmount) external onlyAllowedCaller nonReentrant {
        if (msg.sender != _yieldSource) revert UnauthorizedYieldSource();
        if (riskusdAmount == 0) revert ZeroAmount();
        _requireNotBlocked(msg.sender);

        // OF-007 (8th audit): Cap at min(totalAssets(), _legitimateAssets) to prevent
        // donation-inflated totalAssets from allowing over-absorption.
        uint256 cap = totalAssets();
        if (_legitimateAssets < cap) cap = _legitimateAssets;
        if (riskusdAmount > cap) {
            riskusdAmount = cap;
        }
        _delegateStateModule(abi.encodeCall(AtRiskUSDStateModule.absorbLoss, (riskusdAmount)));
    }

    // ============================================================
    // Cooldown Withdrawals
    // ============================================================
    function requestWithdrawal(uint256 atriskusdAmount) external onlyAllowedCaller whenNotPaused nonReentrant {
        _requirePendingWithdrawalLayoutReady(msg.sender);
        if (atriskusdAmount == 0) revert ZeroAmount();

        if (_lockupPeriod > 0 && block.timestamp < _lockExpiry[msg.sender]) {
            revert LockupNotExpired(_lockExpiry[msg.sender]);
        }

        if (_pendingWithdrawals[msg.sender].active) revert PendingWithdrawalExists();
        _requireNotBlocked(msg.sender);
        _requireWithdrawalApprovalDuration();
        _requireNoLossPending();

        uint256 backingPerShareBefore = _backingPerShareRay();
        uint256 riskusdAmount = convertToAssets(atriskusdAmount);
        if (riskusdAmount == 0) revert ZeroRedemptionOutput();
        _delegateStateModule(
            abi.encodeCall(
                AtRiskUSDStateModule.requestWithdrawal, (atriskusdAmount, riskusdAmount, backingPerShareBefore)
            )
        );
    }

    /// @param minAmountOut OF-M11: minimum RISKUSD payout, reverts if below. Pass 0 to accept any amount.
    /// @notice OF-L11: Intentional design — withdrawal/cancellation paths remain open during pause to allow depositor exit.
    function executeWithdrawal(uint256 minAmountOut) external onlyAllowedCaller nonReentrant {
        _delegateStateModule(abi.encodeCall(AtRiskUSDStateModule.executeWithdrawal, (minAmountOut)));
    }

    /// @notice Backward-compatible overload with no slippage protection.
    /// @custom:deprecated OF-L09: Use executeWithdrawal(uint256 minAmountOut) instead for slippage protection.
    /// This overload passes minAmountOut=0, accepting any payout amount — vulnerable to sandwich attacks.
    /// @notice OF-L11: Intentional design — withdrawal/cancellation paths remain open during pause to allow depositor exit.
    function executeWithdrawal() external onlyAllowedCaller nonReentrant {
        _requirePendingWithdrawalLayoutReady(msg.sender);
        emit DeprecatedWithdrawalUsed(msg.sender, _pendingWithdrawals[msg.sender].riskusdAmount);
        _delegateStateModule(abi.encodeCall(AtRiskUSDStateModule.executeWithdrawal, (0)));
    }

    /// @notice OF-L11: Intentional design — withdrawal/cancellation paths remain open during pause to allow depositor exit.
    /// @dev OF-NEW-11 (12th audit): Gated by lossPending to prevent cancel→re-deposit optionality during loss window.
    function cancelWithdrawal() external onlyAllowedCaller nonReentrant {
        _cancelPendingWithdrawal(msg.sender, true);
    }

    function recoverPendingWithdrawal() external onlyAllowedCaller nonReentrant {
        _requirePendingWithdrawalLayoutReady(msg.sender);
        if (!_emergencyRecoveryWindowOpen()) revert EmergencyRecoveryWindowClosed();
        if (!_yieldSourceIsUnreachable()) revert YieldSourceReachable();
        uint256 shares = _cancelPendingWithdrawal(msg.sender, false);
        emit UnreachableWithdrawalRecovered(msg.sender, shares);
    }

    function burnWorthlessShares(uint256 shares) external onlyAllowedCaller whenNotPaused nonReentrant {
        if (shares == 0) revert ZeroAmount();
        if (totalSupply() == 0 || totalAssets() != 0) revert NotTotalLossState();
        _requirePendingWithdrawalLayoutReady(msg.sender);
        if (_pendingWithdrawals[msg.sender].active) revert PendingWithdrawalExists();
        _requireNoLossPending();
        _requireNotBlocked(msg.sender);

        _delegateStateModule(abi.encodeCall(AtRiskUSDStateModule.burnWorthlessShares, (shares)));
        emit WorthlessSharesBurned(msg.sender, shares);
    }

    function _cancelPendingWithdrawal(address beneficiary, bool requireNoLoss) private returns (uint256 shares) {
        _requirePendingWithdrawalLayoutReady(beneficiary);
        PendingWithdrawal storage pw = _pendingWithdrawals[beneficiary];
        if (!pw.active) revert NoPendingWithdrawal();
        if (requireNoLoss) _requireNoLossPending();
        _requireNotBlocked(beneficiary);

        shares = pw.atriskusdAmount;
        AtRiskUSDStateModule.WithdrawalCancellation memory cancellation = AtRiskUSDStateModule.WithdrawalCancellation({
            beneficiary: beneficiary,
            shares: shares,
            capWindowStart: pw.weeklyCapWindowStart,
            capReservedAssets: pw.weeklyCapReservedAssets
        });
        _delegateStateModule(abi.encodeCall(AtRiskUSDStateModule.finishPendingWithdrawalCancellation, (cancellation)));
    }

    // ============================================================
    // Tier Upgrade / Reversion / Renewal (StakingQueue-only)
    // ============================================================
    function redeemForUpgrade(address depositor, uint256 shares)
        external
        onlyAllowedCaller
        whenNotPaused
        nonReentrant
        returns (uint256 assets)
    {
        if (msg.sender != _stakingQueue) revert UnauthorizedStakingQueue();
        if (shares == 0) revert ZeroAmount();
        // OF-008: Block upgrade if depositor has a pending withdrawal
        _requirePendingWithdrawalLayoutReady(depositor);
        if (_pendingWithdrawals[depositor].active) revert PendingWithdrawalExists();
        // OF-NEW-10 (12th audit): Block upgrade if lockup not expired
        if (_lockupPeriod > 0 && block.timestamp < _lockExpiry[depositor]) {
            revert LockupNotExpired(_lockExpiry[depositor]);
        }
        _requireNoLossPending(); // OF-13-004: Block tier transitions during loss
        _requireNotBlocked(msg.sender);
        _requireNotBlocked(depositor);
        _requireAllowedBeneficiary(depositor);

        assets = _delegateStateModuleUint(abi.encodeCall(AtRiskUSDStateModule.redeemForUpgrade, (depositor, shares)));
    }

    function redeemForReversion(address depositor, uint256 shares)
        external
        onlyAllowedCaller
        whenNotPaused
        nonReentrant
        returns (uint256 assets)
    {
        if (msg.sender != _stakingQueue) revert UnauthorizedStakingQueue();
        if (shares == 0) revert ZeroAmount();
        // OF-008: Block reversion if depositor has a pending withdrawal (sibling of redeemForUpgrade's guard)
        _requirePendingWithdrawalLayoutReady(depositor);
        if (_pendingWithdrawals[depositor].active) revert PendingWithdrawalExists();

        if (_lockupPeriod > 0 && block.timestamp < _lockExpiry[depositor]) {
            revert LockupNotExpired(_lockExpiry[depositor]);
        }

        if (!_autoRenewDisabled[depositor]) revert AutoRenewEnabled();
        _requireNoLossPending(); // OF-13-004: Block tier transitions during loss
        _requireNotBlocked(msg.sender);
        _requireNotBlocked(depositor);
        _requireAllowedBeneficiary(depositor);

        assets = _delegateStateModuleUint(abi.encodeCall(AtRiskUSDStateModule.redeemForReversion, (depositor, shares)));
    }

    function renewLockup(address depositor) external onlyAllowedCaller whenNotPaused nonReentrant returns (uint256) {
        if (msg.sender != _stakingQueue) revert UnauthorizedStakingQueue();

        if (_lockupPeriod > 0 && block.timestamp < _lockExpiry[depositor]) {
            revert LockupNotExpired(_lockExpiry[depositor]);
        }

        if (_autoRenewDisabled[depositor]) revert AutoRenewDisabled();

        uint256 newExpiry = block.timestamp + _lockupPeriod;
        _delegateStateModule(abi.encodeCall(AtRiskUSDStateModule.setLockExpiry, (depositor, newExpiry)));

        emit LockupRenewed(depositor, newExpiry);
        return newExpiry;
    }

    // ============================================================
    // Auto-Renewal
    // ============================================================
    function setAutoRenew(bool enabled) external onlyAllowedCaller {
        _delegateStateModule(abi.encodeCall(AtRiskUSDStateModule.setAutoRenewDisabled, (msg.sender, !enabled)));
        emit AutoRenewChanged(msg.sender, enabled);
    }

    // ============================================================
    // Configuration (owner-only)
    // ============================================================
    /// @notice OF-H02: setYieldSource now only proposes — no instant effect.
    /// Use finalizeYieldSource() or acceptYieldSource() to complete the change.
    function setYieldSource(address newYieldSource) external onlyAllowedCaller onlyOwner {
        if (newYieldSource == address(0)) revert ZeroAddress();
        _pendingYieldSource = newYieldSource;
        _yieldSourceProposedAt = block.timestamp; // OF-002 (11th audit)
        emit YieldSourceProposed(_yieldSource, newYieldSource);
    }

    /// @notice OF-H02: Owner-side finalization for yield source change (for contract recipients).
    function finalizeYieldSource() external onlyAllowedCaller onlyOwner {
        if (_pendingYieldSource == address(0)) revert ZeroAddress();
        if (block.timestamp < _yieldSourceProposedAt + _finalizeDelay()) revert FinalizeDelayNotElapsed();
        if (block.timestamp > _yieldSourceProposedAt + PROPOSAL_EXPIRY) revert ProposalExpired();
        _delegateStateModule(abi.encodeCall(AtRiskUSDStateModule.applyPendingYieldSource, ()));
    }

    /// @notice OF-H02: setStakingQueue now only proposes — no instant effect.
    /// Use finalizeStakingQueue() or acceptStakingQueue() to complete the change.
    function setStakingQueue(address newStakingQueue) external onlyAllowedCaller onlyOwner {
        if (newStakingQueue == address(0)) revert ZeroAddress();
        _pendingStakingQueue = newStakingQueue;
        _stakingQueueProposedAt = block.timestamp; // OF-002 (11th audit)
        emit StakingQueueProposed(_stakingQueue, newStakingQueue);
    }

    /// @notice OF-H02: Owner-side finalization for staking queue change (for contract recipients).
    function finalizeStakingQueue() external onlyAllowedCaller onlyOwner {
        if (_pendingStakingQueue == address(0)) revert ZeroAddress();
        if (block.timestamp < _stakingQueueProposedAt + _finalizeDelay()) revert FinalizeDelayNotElapsed();
        if (block.timestamp > _stakingQueueProposedAt + PROPOSAL_EXPIRY) revert ProposalExpired();
        _delegateStateModule(abi.encodeCall(AtRiskUSDStateModule.applyPendingStakingQueue, ()));
    }

    /// @notice OF-H02: Propose a new yield source (two-step handoff). Only owner can propose.
    function proposeYieldSource(address newYieldSource_) external onlyAllowedCaller onlyOwner {
        if (newYieldSource_ == address(0)) revert ZeroAddress();
        _pendingYieldSource = newYieldSource_;
        _yieldSourceProposedAt = block.timestamp; // OF-002 (11th audit)
        emit YieldSourceProposed(_yieldSource, newYieldSource_);
    }

    /// @notice OF-H02: Accept the pending yield source role. Only the pending yield source can call.
    function acceptYieldSource() external onlyAllowedCaller {
        if (msg.sender != _pendingYieldSource) revert NotPendingYieldSource();
        if (block.timestamp < _yieldSourceProposedAt + _finalizeDelay()) revert FinalizeDelayNotElapsed();
        if (block.timestamp > _yieldSourceProposedAt + PROPOSAL_EXPIRY) revert ProposalExpired();
        _delegateStateModule(abi.encodeCall(AtRiskUSDStateModule.applyPendingYieldSource, ()));
    }

    /// @notice OF-H02: View the pending yield source address.
    function pendingYieldSource() external view returns (address) {
        return _pendingYieldSource;
    }

    /// @notice OF-H02: Clear the pending yield source to prevent stale proposals surviving UUPS upgrades.
    function clearPendingYieldSource() external onlyAllowedCaller onlyOwner {
        _pendingYieldSource = address(0);
        _yieldSourceProposedAt = 0;
    }

    /// @notice OF-H02: Propose a new staking queue (two-step handoff). Only owner can propose.
    function proposeStakingQueue(address newStakingQueue_) external onlyAllowedCaller onlyOwner {
        if (newStakingQueue_ == address(0)) revert ZeroAddress();
        _pendingStakingQueue = newStakingQueue_;
        _stakingQueueProposedAt = block.timestamp; // OF-002 (11th audit)
        emit StakingQueueProposed(_stakingQueue, newStakingQueue_);
    }

    /// @notice OF-H02: Accept the pending staking queue role. Only the pending staking queue can call.
    function acceptStakingQueue() external onlyAllowedCaller {
        if (msg.sender != _pendingStakingQueue) revert NotPendingStakingQueue();
        if (block.timestamp < _stakingQueueProposedAt + _finalizeDelay()) revert FinalizeDelayNotElapsed();
        if (block.timestamp > _stakingQueueProposedAt + PROPOSAL_EXPIRY) revert ProposalExpired();
        _delegateStateModule(abi.encodeCall(AtRiskUSDStateModule.applyPendingStakingQueue, ()));
    }

    /// @notice OF-H02: View the pending staking queue address.
    function pendingStakingQueue() external view returns (address) {
        return _pendingStakingQueue;
    }

    /// @notice OF-H02: Clear the pending staking queue to prevent stale proposals surviving UUPS upgrades.
    function clearPendingStakingQueue() external onlyAllowedCaller onlyOwner {
        _pendingStakingQueue = address(0);
        _stakingQueueProposedAt = 0;
    }

    /// @notice OF-15-005: setForageGovernor now only proposes — no instant effect.
    function setForageGovernor(address newGovernor_) external onlyAllowedCaller onlyOwner {
        if (newGovernor_ == address(0)) revert ZeroAddress();
        _pendingForageGovernor = newGovernor_;
        _pendingForageGovernorProposedAt = block.timestamp;
        emit ForageGovernorProposed(_forageGovernor, newGovernor_);
    }

    /// @notice OF-15-005: Finalize the proposed ForageGovernor after FINALIZE_DELAY.
    function finalizeForageGovernor() external onlyAllowedCaller onlyOwner {
        if (_pendingForageGovernor == address(0)) revert NoPendingForageGovernor();
        if (block.timestamp < _pendingForageGovernorProposedAt + _finalizeDelay()) revert FinalizeDelayNotElapsed();
        if (block.timestamp > _pendingForageGovernorProposedAt + PROPOSAL_EXPIRY) revert ProposalExpired();
        _delegateStateModule(abi.encodeCall(AtRiskUSDStateModule.applyPendingForageGovernor, ()));
    }

    function clearPendingForageGovernor() external onlyAllowedCaller onlyOwner {
        _pendingForageGovernor = address(0);
        _pendingForageGovernorProposedAt = 0;
    }

    function setBlocklist(address blocklist_) external onlyAllowedCaller onlyOwner {
        if (blocklist_ == address(0)) revert ZeroAddress();
        address oldBlocklist = _blocklist;
        _blocklist = blocklist_;
        emit BlocklistSet(oldBlocklist, blocklist_);
    }

    function setCooldownPeriod(uint256 newCooldownPeriod) external onlyAllowedCaller onlyOwner {
        uint256 old = _cooldownPeriod;
        _cooldownPeriod = newCooldownPeriod;
        emit CooldownPeriodUpdated(old, newCooldownPeriod);
    }

    function setWeeklyWithdrawalCapBps(uint256 bps_) external onlyAllowedCaller onlyOwner {
        _setWeeklyWithdrawalCapBps(bps_);
    }

    function shrinkWeeklyWithdrawalCapBps(uint256 bps_) external onlyAllowedCaller {
        _requireEmergencyCapTightener();
        if (bps_ > _effectiveWeeklyWithdrawalCapBps()) revert CapTighteningOnly();
        _setWeeklyWithdrawalCapBps(bps_);
    }

    // ============================================================
    // Pause (owner, governor, or guardian module — OF-19-002)
    // ============================================================
    function pause() external onlyAllowedCaller {
        if (msg.sender != owner() && msg.sender != _forageGovernor && !_isGuardianModule(msg.sender)) {
            revert OwnableUnauthorizedAccount(msg.sender);
        }
        _pause();
    }

    function unpause() external onlyAllowedCaller {
        if (msg.sender != owner() && msg.sender != _forageGovernor && !_isGuardianModule(msg.sender)) {
            revert OwnableUnauthorizedAccount(msg.sender);
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

    // ============================================================
    // View Functions
    // ============================================================
    function legitimateAssets() external view returns (uint256) {
        return _legitimateAssets;
    }

    function tierId() external view returns (uint8) {
        return _tierId;
    }

    function lockupPeriod() external view returns (uint256) {
        return _lockupPeriod;
    }

    function cooldownPeriod() external view returns (uint256) {
        return _cooldownPeriod;
    }

    function yieldSource() external view returns (address) {
        return _yieldSource;
    }

    function stakingQueue() external view returns (address) {
        return _stakingQueue;
    }

    function forageGovernor() external view returns (address) {
        return _forageGovernor;
    }

    function blocklist() external view returns (address) {
        return _blocklist;
    }

    function weeklyWithdrawalCapBps() external view returns (uint256) {
        return _effectiveWeeklyWithdrawalCapBps();
    }

    function weeklyWithdrawalRemaining() public view returns (uint256) {
        (uint256 used, uint256 baseAssets) = _weeklyWithdrawalWindowView();
        uint256 cap = baseAssets * _effectiveWeeklyWithdrawalCapBps() / 10000;
        return used >= cap ? 0 : cap - used;
    }

    function lockExpiry(address account) external view returns (uint256) {
        return _lockExpiry[account];
    }

    function autoRenewEnabled(address depositor) external view returns (bool) {
        return !_autoRenewDisabled[depositor];
    }

    function hasExpiredAutoRenewDisabledLockup() external view returns (bool) {
        return _autoRenewDisabledTrackedCount != 0 && _earliestAutoRenewDisabledExpiry != 0
            && block.timestamp >= _earliestAutoRenewDisabledExpiry;
    }

    function isLockupExpired(address depositor) external view returns (bool) {
        if (_lockExpiry[depositor] == 0) return true; // No lockup set (includes Tier 0)
        return block.timestamp >= _lockExpiry[depositor];
    }

    function hasPendingWithdrawal(address depositor) external view returns (bool) {
        _requirePendingWithdrawalLayoutReady(depositor);
        return _pendingWithdrawals[depositor].active;
    }

    function lockupShares(address depositor) external view returns (uint256) {
        return balanceOf(depositor);
    }

    function pendingWithdrawal(address requester) external view returns (PendingWithdrawal memory) {
        _requirePendingWithdrawalLayoutReady(requester);
        return _pendingWithdrawals[requester];
    }

    function pendingWithdrawalAmount(address account)
        external
        view
        returns (uint256 riskusdAmount, uint256 atriskusdAmount)
    {
        _requirePendingWithdrawalLayoutReady(account);
        PendingWithdrawal storage pw = _pendingWithdrawals[account];
        return (pw.riskusdAmount, pw.atriskusdAmount);
    }

    function pendingWithdrawalCooldownEnd(address account) external view returns (uint256) {
        _requirePendingWithdrawalLayoutReady(account);
        PendingWithdrawal storage pw = _pendingWithdrawals[account];
        return pw.requestTimestamp + pw.cooldownPeriod;
    }

    function pendingWithdrawalActive(address account) external view returns (bool) {
        _requirePendingWithdrawalLayoutReady(account);
        return _pendingWithdrawals[account].active;
    }

    function pendingWithdrawalWeeklyCap(address account)
        external
        view
        returns (uint256 windowStart, uint256 reservedAssets)
    {
        _requirePendingWithdrawalLayoutReady(account);
        PendingWithdrawal storage pw = _pendingWithdrawals[account];
        return (pw.weeklyCapWindowStart, pw.weeklyCapReservedAssets);
    }

    function migratePendingWithdrawalLayout(address requester, PendingWithdrawalLayout sourceLayout)
        external
        onlyAllowedCaller
        onlyOwner
        nonReentrant
    {
        _delegateStateModule(
            abi.encodeCall(AtRiskUSDStateModule.migratePendingWithdrawalLayout, (requester, uint8(sourceLayout)))
        );
    }

    function totalYieldAccrued() external view returns (uint256) {
        return _totalYieldAccrued;
    }

    function totalLossAbsorbed() external view returns (uint256) {
        return _totalLossAbsorbed;
    }

    function _requirePendingWithdrawalLayoutReady(address requester) private view {
        PendingWithdrawalMigrationState migrationState = _pendingWithdrawalMigrationState[requester];
        if (migrationState == PendingWithdrawalMigrationState.SharesRecovering) {
            revert PendingWithdrawalMigrationAlreadyConfirmed(requester);
        }
        if (migrationState == PendingWithdrawalMigrationState.Confirmed) return;

        AtRiskUSDStateModuleStorage.PendingWithdrawalLayoutKind kind =
            _pendingWithdrawalLayoutKind(_loadPendingWithdrawalWords(requester));
        if (kind == AtRiskUSDStateModuleStorage.PendingWithdrawalLayoutKind.CooldownFirst) {
            revert PendingWithdrawalMigrationRequired(requester);
        }
        if (kind == AtRiskUSDStateModuleStorage.PendingWithdrawalLayoutKind.Ambiguous) {
            revert AmbiguousPendingWithdrawalLayout(requester);
        }
    }

    function _requireWithdrawalApprovalDuration() private view {
        IAllowlist registry = IAllowlist(allowlist());
        if (registry.isSystemAccount(msg.sender)) return;
        uint256 cooldown = _cooldownPeriod;
        if (cooldown > type(uint256).max - WEEKLY_WITHDRAWAL_WINDOW) revert AllowlistHorizonOverflow();
        uint256 horizon = cooldown + WEEKLY_WITHDRAWAL_WINDOW;
        if (block.timestamp > type(uint256).max - horizon) revert AllowlistHorizonOverflow();
        uint256 requiredUntil = block.timestamp + horizon;
        uint256 allowedUntil = registry.allowedUntil(msg.sender);
        if (allowedUntil < requiredUntil) revert InsufficientAllowlistDuration(requiredUntil, allowedUntil);
    }

    function _pendingWithdrawalLayoutReadyForView(address requester) private view returns (bool) {
        PendingWithdrawalMigrationState migrationState = _pendingWithdrawalMigrationState[requester];
        if (migrationState == PendingWithdrawalMigrationState.Confirmed) return true;
        if (migrationState == PendingWithdrawalMigrationState.SharesRecovering) return false;
        AtRiskUSDStateModuleStorage.PendingWithdrawalLayoutKind kind =
            _pendingWithdrawalLayoutKind(_loadPendingWithdrawalWords(requester));
        return kind == AtRiskUSDStateModuleStorage.PendingWithdrawalLayoutKind.Empty
            || kind == AtRiskUSDStateModuleStorage.PendingWithdrawalLayoutKind.Current;
    }

    function _loadPendingWithdrawalWords(address requester)
        private
        view
        returns (AtRiskUSDStateModuleStorage.PendingWithdrawalWords memory words)
    {
        uint256 mappingSlot;
        assembly {
            mappingSlot := _pendingWithdrawals.slot
        }
        return AtRiskUSDStateModuleStorage.loadPendingWithdrawalWords(requester, mappingSlot);
    }

    function _pendingWithdrawalLayoutKind(AtRiskUSDStateModuleStorage.PendingWithdrawalWords memory words)
        private
        view
        returns (AtRiskUSDStateModuleStorage.PendingWithdrawalLayoutKind)
    {
        return _stateModule.classifyPendingWithdrawalLayout(words);
    }

    // ============================================================
    // UUPS
    // ============================================================
    /// @notice Reinitializer for UUPS upgrade — seeds funded assets from the raw asset balance.
    /// @dev OF-17-001: Uses IERC20(asset()).balanceOf(address(this)) to seed only funded assets.
    function initializeV2() external onlyAllowedCaller reinitializer(2) onlyOwner {
        _legitimateAssets = IERC20(asset()).balanceOf(address(this));
        _notifyVaultRegistryAssetsChanged();
    }

    function initializeV3(string memory abbreviation_) external onlyAllowedCaller reinitializer(3) onlyOwner {
        _initializeMetadata(abbreviation_);
    }

    function _initializeMetadata(string memory abbreviation_) internal onlyInitializing {
        if (bytes(abbreviation_).length == 0) revert EmptyAbbreviation();
        string memory metadata = string.concat("atRISKUSD-", abbreviation_);
        __ERC20_init(metadata, metadata);
    }

    function _authorizeUpgrade(address) internal override onlyOwner {
        _pendingYieldSource = address(0);
        _pendingStakingQueue = address(0);
        // OF-002 (11th audit): Clear proposal timestamps on upgrade
        _yieldSourceProposedAt = 0;
        _stakingQueueProposedAt = 0;
        // OF-15-005: Clear pending ForageGovernor on upgrade
        _pendingForageGovernor = address(0);
        _pendingForageGovernorProposedAt = 0;
    }

    function renounceOwnership() public override onlyAllowedCaller onlyOwner {
        revert RenounceOwnershipDisabled();
    }

    /// @notice UUPS upgrade entry point, gated before the proxy and owner checks.
    function upgradeToAndCall(address newImplementation, bytes memory data) public payable override onlyAllowedCaller {
        super.upgradeToAndCall(newImplementation, data);
    }

    /// @notice Ownership handoff entry point, gated before the owner check.
    function transferOwnership(address newOwner) public override onlyAllowedCaller {
        super.transferOwnership(newOwner);
    }

    /// @notice Ownership acceptance entry point, gated before the pending-owner check.
    function acceptOwnership() public override onlyAllowedCaller {
        super.acceptOwnership();
    }

    function setAllowlist(address allowlist_) external {
        if (allowlist() == address(0)) {
            if (msg.sender != owner()) revert OwnableUnauthorizedAccount(msg.sender);
            if (allowlist_ == address(0) || allowlist_.code.length == 0) revert IAllowlist.AllowlistUnavailable();
            IAllowlist proposedAllowlist = IAllowlist(allowlist_);
            if (!proposedAllowlist.isAllowed(msg.sender)) revert IAllowlist.CallerNotAllowed(msg.sender);
            if (!proposedAllowlist.isSystemAccount(address(this))) {
                revert IAllowlist.CallerNotAllowed(address(this));
            }
            _setAllowlist(allowlist_);
            return;
        }
        _checkAllowedCaller();
        if (msg.sender != owner()) revert OwnableUnauthorizedAccount(msg.sender);
        _validateAllowlistTransition(allowlist_);
        _setAllowlist(allowlist_);
    }

    // ============================================================
    // Transfer Lock Semantics
    // ============================================================
    function _update(address from, address to, uint256 value) internal override {
        _delegateStateModule(abi.encodeCall(AtRiskUSDStateModule.update, (from, to, value)));
    }

    function approve(address spender, uint256 value) public override(ERC20Upgradeable, IERC20) returns (bool) {
        _requireNotBlocked(msg.sender);
        if (value != 0) {
            _requireNotBlocked(spender);
        }
        return super.approve(spender, value);
    }

    function transfer(address to, uint256 value) public override(ERC20Upgradeable, IERC20) returns (bool) {
        return super.transfer(to, value);
    }

    function transferFrom(address from, address to, uint256 value)
        public
        override(ERC20Upgradeable, IERC20)
        returns (bool)
    {
        _requireNotBlocked(msg.sender);
        return super.transferFrom(from, to, value);
    }

    // ============================================================
    // Internal Helpers
    // ============================================================
    /// @notice Reports funded assets plus recognized yield claims, excluding direct donations.
    function totalAssets() public view override returns (uint256) {
        uint256 claim = _unfundedYieldClaim();
        if (claim >= type(uint256).max - _legitimateAssets) {
            revert YieldAssetValueOverflow(_legitimateAssets, claim);
        }
        return _legitimateAssets + claim;
    }

    function _unfundedYieldClaim() private view returns (uint256 claim) {
        address source = _yieldSource;
        if (source.code.length == 0) revert YieldClaimsUnavailable(source);
        IUSDCTreasuryYieldClaims claims = IUSDCTreasuryYieldClaims(source);
        bool ready;
        try claims.yieldClaimsReady() returns (bool value) {
            ready = value;
        } catch {
            revert YieldClaimsUnavailable(source);
        }
        if (!ready) revert YieldClaimsNotReady(source);
        try claims.unfundedYieldClaim(address(this)) returns (uint256 value) {
            claim = value;
        } catch {
            revert YieldClaimsUnavailable(source);
        }
    }

    function _requireNoUnfundedZeroSupplyClaim() private view {
        if (totalSupply() != 0) return;
        uint256 claim = _unfundedYieldClaim();
        if (claim != 0) revert UnfundedZeroSupplyClaim(claim);
    }

    function _sharesWithinAssetCap(uint256 cap, uint256 shareLimit) private view returns (uint256 shares) {
        uint256 assets = totalAssets();
        if (cap >= assets) return shareLimit;
        uint256 numerator = totalSupply() + SHARE_SCALE;
        shares = Math.mulDiv(cap + 1, numerator, assets + 1, Math.Rounding.Ceil) - 1;
        if (shares > shareLimit) shares = shareLimit;
    }

    function _sharesRedeemableWithFunds(address owner_) private view returns (uint256 shares) {
        shares = _sharesWithdrawableInView(owner_);
        uint256 supply = totalSupply();
        if (supply == 0 || shares == 0) return 0;
        uint256 fundedLimit = _sharesWithinAssetCap(_legitimateAssets, supply);
        if (shares > fundedLimit) shares = fundedLimit;
        if (shares == supply && _unfundedYieldClaim() != 0) --shares;
    }

    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }

    /// @notice Opens a bounded, share-return-only recovery window for an unreachable yield source.
    function setEmergencyLossPendingOverride(bool override_) external onlyAllowedCaller onlyOwner {
        if (override_) {
            if (!_emergencyRecoverySourceUnavailable()) revert EmergencyOverrideValidationFailed(_yieldSource);
            uint256 expiresAt = block.timestamp + EMERGENCY_RECOVERY_WINDOW;
            if (expiresAt > type(uint64).max) revert EmergencyOverrideValidationFailed(_yieldSource);
            _emergencyLossPendingOverrideUntil = uint64(expiresAt);
            emit EmergencyOverrideWindowOpened(uint64(expiresAt));
        } else {
            _emergencyLossPendingOverrideUntil = 0;
        }
        _emergencyLossPendingOverride = override_;
        emit EmergencyLossPendingOverrideSet(override_);
    }

    function _emergencyRecoverySourceUnavailable() private view returns (bool) {
        (bool ok, bytes memory data) = _yieldSource.staticcall(abi.encodeWithSignature("riskusdVault()"));
        if (!ok || data.length < 32) return true;
        address vault = abi.decode(data, (address));
        (ok, data) = vault.staticcall(abi.encodeWithSignature("lossPending()"));
        if (!ok || data.length < 32) return true;
        uint256 lossPendingValue;
        assembly {
            lossPendingValue := mload(add(data, 32))
        }
        if (lossPendingValue > 1) return true;
        if (lossPendingValue == 1) revert CannotOverrideDuringActiveLoss();
        if (_custodianSettlementPending(vault)) revert CustodianSettlementPending();
        return false;
    }

    function _emergencyRecoveryWindowOpen() private view returns (bool) {
        uint64 expiresAt = _emergencyLossPendingOverrideUntil;
        return _emergencyLossPendingOverride && expiresAt != 0 && block.timestamp < expiresAt;
    }

    function _yieldSourceIsUnreachable() private view returns (bool) {
        (bool ok, bytes memory data) = _yieldSource.staticcall(abi.encodeWithSignature("riskusdVault()"));
        if (!ok || data.length < 32) return true;
        address vault = abi.decode(data, (address));
        (ok, data) = vault.staticcall(abi.encodeWithSignature("lossPending()"));
        if (!ok || data.length < 32) return true;
        uint256 lossPendingValue;
        assembly {
            lossPendingValue := mload(add(data, 32))
        }
        return lossPendingValue > 1;
    }

    /// @dev OF-NEW-05 (12th audit): Fail-closed lossPending check. Reverts if either
    /// staticcall fails (misconfigured yieldSource, no code) instead of silently proceeding.
    function _requireNoLossPending() private view {
        (bool ok1, bytes memory data1) = _yieldSource.staticcall(abi.encodeWithSignature("riskusdVault()"));
        require(ok1 && data1.length >= 32, "lossPending check: yieldSource unreachable");
        address vault = abi.decode(data1, (address));
        (bool ok2, bytes memory data2) = vault.staticcall(abi.encodeWithSignature("lossPending()"));
        require(ok2 && data2.length >= 32, "lossPending check: vault unreachable");
        if (abi.decode(data2, (bool))) {
            revert LossPending();
        }
        if (_custodianSettlementPending(vault)) {
            revert CustodianSettlementPending();
        }
    }

    function _custodianSettlementPending(address vault) private view returns (bool) {
        (bool ok, bytes memory data) = vault.staticcall(abi.encodeWithSignature("custodian()"));
        if (!ok || data.length < 32) return false;

        address custodian = abi.decode(data, (address));
        if (custodian == address(0) || custodian.code.length == 0) return false;

        (ok, data) = custodian.staticcall(abi.encodeWithSignature("tierShareActionsPaused()"));
        if (!ok || data.length < 32) revert CustodianSettlementHookFailed(custodian);

        return abi.decode(data, (bool));
    }

    function _requireNoZeroAssetLegacySupply() private view {
        if (_hasZeroAssetLegacySupply()) revert ZeroAssetLegacySupply();
    }

    function _hasZeroAssetLegacySupply() private view returns (bool) {
        return totalSupply() != 0 && totalAssets() == 0;
    }

    function _extendLockup(address receiver) private {
        _delegateStateModule(abi.encodeCall(AtRiskUSDStateModule.extendLockup, (receiver)));
    }

    function _delegateStateModule(bytes memory callData) private {
        address module = address(_stateModule);
        assembly {
            let success := delegatecall(gas(), module, add(callData, 32), mload(callData), 0, 0)
            if iszero(success) {
                let size := returndatasize()
                returndatacopy(0, 0, size)
                revert(0, size)
            }
        }
    }

    function _delegateStateModuleUint(bytes memory callData) private returns (uint256 result) {
        address module = address(_stateModule);
        (bool success, bytes memory data) = module.delegatecall(callData);
        if (!success) {
            assembly {
                revert(add(data, 32), mload(data))
            }
        }
        if (data.length != 32) revert ModuleReturnDataInvalid();
        result = abi.decode(data, (uint256));
    }

    function _syncAutoRenewDisabledTracking(address account) private {
        _delegateStateModule(abi.encodeCall(AtRiskUSDStateModule.syncAutoRenewDisabledTracking, (account)));
    }

    function _backingPerShareRay() private view returns (uint256) {
        return Math.mulDiv(totalAssets() + 1, RAY * SHARE_SCALE, totalSupply() + SHARE_SCALE);
    }

    function _assertBackingPerShareNotDecreased(uint256 beforeRay) private {
        if (totalSupply() == 0) return;
        uint256 afterRay = _backingPerShareRay();
        if (afterRay < beforeRay) {
            emit ExchangeRateInvariantFailure(beforeRay, afterRay);
            revert ExchangeRateDecreased(beforeRay, afterRay);
        }
    }

    function _decreaseLegitimateAssets(uint256 amount) private {
        uint256 current = _legitimateAssets;
        _legitimateAssets = current >= amount ? current - amount : 0;
        _notifyVaultRegistryAssetsChanged();
    }

    function _notifyVaultRegistryAssetsChanged() private {
        address source = _yieldSource;
        if (source.code.length == 0) revert YieldClaimsUnavailable(source);
        address registry;
        try IUSDCTreasuryYieldClaims(source).vaultRegistry() returns (address value) {
            registry = value;
        } catch {
            revert YieldSourceWiringMismatch(source);
        }
        if (registry.code.length == 0) revert YieldSourceWiringMismatch(source);
        IVaultRegistry(registry).onTierVaultAssetsChanged();
    }

    function _effectiveWeeklyWithdrawalCapBps() private view returns (uint256) {
        return _weeklyWithdrawalCapBps == 0 ? DEFAULT_WEEKLY_WITHDRAWAL_CAP_BPS : _weeklyWithdrawalCapBps;
    }

    function _setWeeklyWithdrawalCapBps(uint256 bps_) private {
        if (bps_ < 100 || bps_ > 10000) revert ZeroAmount();
        uint256 oldBps = _effectiveWeeklyWithdrawalCapBps();
        _weeklyWithdrawalCapBps = bps_;
        emit WeeklyWithdrawalCapBpsUpdated(oldBps, bps_);
    }

    function _requireEmergencyCapTightener() private view {
        if (msg.sender != owner() && msg.sender != _forageGovernor && !_isGuardianModule(msg.sender)) {
            revert OwnableUnauthorizedAccount(msg.sender);
        }
    }

    function _weeklyWithdrawalWindowView() private view returns (uint256 used, uint256 baseAssets) {
        uint256 start = _weeklyWithdrawalWindowStart;
        if (start == 0 || block.timestamp > start + WEEKLY_WITHDRAWAL_WINDOW) {
            return (0, totalAssets());
        }
        baseAssets = _weeklyWithdrawalWindowStartAssets;
        if (baseAssets == 0) baseAssets = totalAssets();
        return (_weeklyWithdrawalUsed, baseAssets);
    }

    function _enforceWeeklyWithdrawalCap(uint256 assets) private {
        _ensureWeeklyWithdrawalCapacity(assets);
        _weeklyWithdrawalUsed += assets;
    }

    function _ensureWeeklyWithdrawalCapacity(uint256 assets) private {
        _resetWeeklyWithdrawalWindowIfExpired();
        if (_weeklyWithdrawalWindowStartAssets == 0) {
            _weeklyWithdrawalWindowStartAssets = totalAssets();
        }

        uint256 used = _weeklyWithdrawalUsed;
        uint256 cap = _weeklyWithdrawalWindowStartAssets * _effectiveWeeklyWithdrawalCapBps() / 10000;
        uint256 remaining = used >= cap ? 0 : cap - used;
        if (assets > remaining) revert WeeklyWithdrawalCapExceeded(assets, remaining);
    }

    function _resetWeeklyWithdrawalWindowIfExpired() private {
        uint256 start = _weeklyWithdrawalWindowStart;
        if (start == 0 || block.timestamp > start + WEEKLY_WITHDRAWAL_WINDOW) {
            _weeklyWithdrawalWindowStart = block.timestamp;
            _weeklyWithdrawalUsed = 0;
            _weeklyWithdrawalWindowStartAssets = 0;
        }
    }

    function _refreshPendingWithdrawalWindow(uint256 reservedWindowStart) private returns (bool) {
        _resetWeeklyWithdrawalWindowIfExpired();
        return reservedWindowStart != _weeklyWithdrawalWindowStart;
    }

    function _requireAllowedBeneficiary(address account) private view {
        address registry = allowlist();
        if (registry == address(0)) revert IAllowlist.AllowlistUnavailable();
        try IAllowlist(registry).isAllowed(account) returns (bool allowed) {
            if (!allowed) revert BeneficiaryNotAllowed(account);
        } catch {
            revert IAllowlist.AllowlistUnavailable();
        }
    }

    function _isAllowedAccount(address account) private view returns (bool) {
        address registry = allowlist();
        if (registry == address(0) || account == address(0)) return false;
        (bool ok, bytes memory data) = registry.staticcall(abi.encodeCall(IAllowlist.isAllowed, (account)));
        if (!ok || data.length < 32) return false;
        uint256 allowed;
        assembly {
            allowed := mload(add(data, 32))
        }
        return allowed == 1;
    }

    function _isBlockedForView(address account) private view returns (bool) {
        address blocklist_ = _blocklist;
        if (blocklist_ == address(0)) return false;
        (bool ok, bytes memory data) = blocklist_.staticcall(abi.encodeCall(IBlocklist.isBlocked, (account)));
        if (!ok || data.length < 32) return true;
        uint256 blocked;
        assembly {
            blocked := mload(add(data, 32))
        }
        return blocked != 0;
    }

    function _isLossClearForView() private view returns (bool) {
        (bool ok, bytes memory data) = _yieldSource.staticcall(abi.encodeWithSignature("riskusdVault()"));
        if (!ok || data.length < 32) return false;
        uint256 rawVault;
        assembly {
            rawVault := mload(add(data, 32))
        }
        if (rawVault > type(uint160).max) return false;
        address vault = address(uint160(rawVault));
        if (vault.code.length == 0) return false;
        (ok, data) = vault.staticcall(abi.encodeWithSignature("lossPending()"));
        if (!ok || data.length < 32) return false;
        uint256 pending;
        assembly {
            pending := mload(add(data, 32))
        }
        if (pending != 0) return false;
        return _custodianSettlementClearForView(vault);
    }

    function _custodianSettlementClearForView(address vault) private view returns (bool) {
        (bool ok, bytes memory data) = vault.staticcall(abi.encodeWithSignature("custodian()"));
        if (!ok || data.length < 32) return true;
        uint256 rawCustodian;
        assembly {
            rawCustodian := mload(add(data, 32))
        }
        if (rawCustodian > type(uint160).max) return false;
        address custodian = address(uint160(rawCustodian));
        if (custodian == address(0) || custodian.code.length == 0) return true;
        (ok, data) = custodian.staticcall(abi.encodeWithSignature("tierShareActionsPaused()"));
        if (!ok || data.length < 32) return false;
        uint256 pausedState;
        assembly {
            pausedState := mload(add(data, 32))
        }
        return pausedState == 0;
    }

    function _canWithdrawInView(address owner_) private view returns (bool) {
        return owner_ != address(0) && _pendingWithdrawalLayoutReadyForView(owner_) && !paused() && _cooldownPeriod == 0
            && block.timestamp >= _lockExpiry[owner_] && _isAllowedAccount(msg.sender) && _isAllowedAccount(owner_)
            && !_isBlockedForView(msg.sender) && !_isBlockedForView(owner_) && _isLossClearForView()
            && !_hasZeroAssetLegacySupply();
    }

    function _sharesWithdrawableInView(address owner_) private view returns (uint256 shares) {
        shares = balanceOf(owner_);
        if (msg.sender != owner_) {
            uint256 approved = allowance(owner_, msg.sender);
            if (approved < shares) shares = approved;
        }
    }

    function _requireNotBlocked(address account) internal view {
        address blocklist_ = _blocklist;
        if (blocklist_ != address(0) && IBlocklist(blocklist_).isBlocked(account)) {
            revert BlockedAddress(account);
        }
    }
}
