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
import "./interfaces/IBlocklist.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

/// @title atRISKUSD — Tier-specific ERC-4626 vault backed by RISKUSD
contract atRISKUSD is
    Initializable,
    ERC4626Upgradeable,
    Ownable2StepUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuard,
    FinalizeDelayProfile
{
    using SafeERC20 for IERC20;

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
    /// When true, _requireNoLossPending() is bypassed, allowing deposits/withdrawals.
    bool private _emergencyLossPendingOverride;
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
    uint256[31] private __gap;

    // Constants
    uint256 public constant PROPOSAL_EXPIRY = 30 days; // OF-002 (11th audit)
    uint256 public constant WEEKLY_WITHDRAWAL_WINDOW = 7 days;
    uint256 public constant DEFAULT_WEEKLY_WITHDRAWAL_CAP_BPS = 500;
    uint256 internal constant RAY = 1e27;
    uint256 internal constant SHARE_SCALE = 1e6;

    // ============================================================
    // Constructor
    // ============================================================
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
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
    function deposit(uint256 assets, address receiver) public override whenNotPaused nonReentrant returns (uint256) {
        if (msg.sender != _stakingQueue) revert UnauthorizedStakingQueue();
        if (assets == 0) revert ZeroAmount();
        _requireNoLossPending(); // OF-13-056: Block fresh inflows during loss
        _requireNoZeroAssetLegacySupply();
        _requireNotBlocked(msg.sender);
        _requireNotBlocked(receiver);
        uint256 backingPerShareBefore = _backingPerShareRay();
        _extendLockup(receiver);

        uint256 shares = super.deposit(assets, receiver);
        _assertBackingPerShareNotDecreased(backingPerShareBefore);
        return shares;
    }

    function mint(uint256 shares, address receiver) public override whenNotPaused nonReentrant returns (uint256) {
        if (msg.sender != _stakingQueue) revert UnauthorizedStakingQueue();
        if (shares == 0) revert ZeroAmount();
        _requireNoLossPending(); // OF-14-002: Block mint during lossPending (same as deposit)
        _requireNoZeroAssetLegacySupply();
        _requireNotBlocked(msg.sender);
        _requireNotBlocked(receiver);
        uint256 backingPerShareBefore = _backingPerShareRay();
        _extendLockup(receiver);

        uint256 assets = super.mint(shares, receiver);
        _assertBackingPerShareNotDecreased(backingPerShareBefore);
        return assets;
    }

    // ============================================================
    // ERC-4626 Internal Overrides (legitimate asset tracking)
    // ============================================================
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        super._deposit(caller, receiver, assets, shares);
        _legitimateAssets += assets;
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
        uint256 backingPerShareBefore = _backingPerShareRay();
        _enforceWeeklyWithdrawalCap(assets);
        uint256 shares = super.withdraw(assets, receiver, _owner);
        _assertBackingPerShareNotDecreased(backingPerShareBefore);
        return shares;
    }

    /// @dev OF-15-029: Added nonReentrant for defense-in-depth on withdrawal paths.
    function redeem(uint256 shares, address receiver, address _owner)
        public
        override
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
        uint256 backingPerShareBefore = _backingPerShareRay();
        uint256 assets = previewRedeem(shares);
        if (assets == 0) revert ZeroRedemptionOutput();
        _enforceWeeklyWithdrawalCap(assets);
        assets = super.redeem(shares, receiver, _owner);
        _assertBackingPerShareNotDecreased(backingPerShareBefore);
        return assets;
    }

    // ============================================================
    // ERC-4626 max* overrides (cooldown gated)
    // ============================================================
    function maxDeposit(address receiver) public view override returns (uint256) {
        if (paused()) return 0;
        return super.maxDeposit(receiver);
    }

    function maxMint(address receiver) public view override returns (uint256) {
        if (paused()) return 0;
        return super.maxMint(receiver);
    }

    /// @dev OF-L01: ERC-4626 spec requires maxWithdraw returns 0 when withdrawal is not possible.
    /// Both cooldown-enabled and lockup-not-expired conditions block withdrawal.
    function maxWithdraw(address owner_) public view override returns (uint256) {
        if (_cooldownPeriod > 0) return 0;
        if (block.timestamp < _lockExpiry[owner_]) return 0;
        return super.maxWithdraw(owner_);
    }

    /// @dev OF-L01: ERC-4626 spec requires maxRedeem returns 0 when redemption is not possible.
    /// Both cooldown-enabled and lockup-not-expired conditions block redemption.
    function maxRedeem(address owner_) public view override returns (uint256) {
        if (_cooldownPeriod > 0) return 0;
        if (block.timestamp < _lockExpiry[owner_]) return 0;
        return super.maxRedeem(owner_);
    }

    // ============================================================
    // Yield/Loss Controls (yieldSource-only)
    // ============================================================
    function accrueYield(uint256 riskusdAmount) external whenNotPaused nonReentrant {
        if (msg.sender != _yieldSource) revert UnauthorizedYieldSource();
        if (riskusdAmount == 0) revert ZeroAmount();
        _requireNoZeroAssetLegacySupply();
        _requireNotBlocked(msg.sender);

        uint256 supply = totalSupply();
        uint256 assetsBefore = supply == 0 ? 0 : convertToAssets(supply);

        // Transfer RISKUSD from yieldSource to vault
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), riskusdAmount);

        _legitimateAssets += riskusdAmount;
        _totalYieldAccrued += riskusdAmount;

        uint256 assetsAfter = supply == 0 ? 0 : convertToAssets(supply);
        if (assetsAfter < assetsBefore) {
            emit ExchangeRateInvariantFailure(assetsBefore, assetsAfter);
            revert ExchangeRateDecreased(assetsBefore, assetsAfter);
        }

        emit YieldAccrued(riskusdAmount);
    }

    /// @dev OF-L22: Loss reporting must work even when paused. Auth-gated by _yieldSource.
    function absorbLoss(uint256 riskusdAmount) external nonReentrant {
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

        // Transfer RISKUSD from vault to yieldSource
        IERC20(asset()).safeTransfer(msg.sender, riskusdAmount);

        _decreaseLegitimateAssets(riskusdAmount);
        _totalLossAbsorbed += riskusdAmount;

        emit LossAbsorbed(riskusdAmount);
    }

    // ============================================================
    // Cooldown Withdrawals
    // ============================================================
    function requestWithdrawal(uint256 atriskusdAmount) external whenNotPaused nonReentrant {
        if (atriskusdAmount == 0) revert ZeroAmount();

        if (_lockupPeriod > 0 && block.timestamp < _lockExpiry[msg.sender]) {
            revert LockupNotExpired(_lockExpiry[msg.sender]);
        }

        if (_pendingWithdrawals[msg.sender].active) revert PendingWithdrawalExists();
        _requireNotBlocked(msg.sender);

        uint256 backingPerShareBefore = _backingPerShareRay();
        uint256 riskusdAmount = convertToAssets(atriskusdAmount);
        if (riskusdAmount == 0) revert ZeroRedemptionOutput();

        // Store pending withdrawal — OF-M03: snapshot cooldown at request time
        _pendingWithdrawals[msg.sender] = PendingWithdrawal({
            atriskusdAmount: atriskusdAmount,
            riskusdAmount: riskusdAmount,
            requestTimestamp: block.timestamp,
            active: true,
            cooldownPeriod: _cooldownPeriod,
            weeklyCapWindowStart: 0,
            weeklyCapReservedAssets: 0
        });

        // Transfer shares from user to contract (locks them)
        _transfer(msg.sender, address(this), atriskusdAmount);

        emit WithdrawalRequested(msg.sender, atriskusdAmount, riskusdAmount, block.timestamp + _cooldownPeriod);
        _assertBackingPerShareNotDecreased(backingPerShareBefore);
    }

    /// @param minAmountOut OF-M11: minimum RISKUSD payout, reverts if below. Pass 0 to accept any amount.
    /// @notice OF-L11: Intentional design — withdrawal/cancellation paths remain open during pause to allow depositor exit.
    function executeWithdrawal(uint256 minAmountOut) external nonReentrant {
        _executeWithdrawal(minAmountOut);
    }

    /// @notice Backward-compatible overload with no slippage protection.
    /// @custom:deprecated OF-L09: Use executeWithdrawal(uint256 minAmountOut) instead for slippage protection.
    /// This overload passes minAmountOut=0, accepting any payout amount — vulnerable to sandwich attacks.
    /// @notice OF-L11: Intentional design — withdrawal/cancellation paths remain open during pause to allow depositor exit.
    function executeWithdrawal() external nonReentrant {
        emit DeprecatedWithdrawalUsed(msg.sender, _pendingWithdrawals[msg.sender].riskusdAmount);
        _executeWithdrawal(0);
    }

    function _executeWithdrawal(uint256 minAmountOut) private {
        PendingWithdrawal storage pw = _pendingWithdrawals[msg.sender];
        if (!pw.active) revert NoPendingWithdrawal();

        // OF-001 (11th audit) + OF-NEW-05 (12th audit): Block withdrawal when loss is pending
        _requireNoLossPending();

        // Check cooldown elapsed — OF-M03: use stored cooldown, not current
        uint256 cooldownEnd = pw.requestTimestamp + pw.cooldownPeriod;
        if (block.timestamp < cooldownEnd) revert CooldownNotElapsed(cooldownEnd);
        _requireNotBlocked(msg.sender);

        uint256 sharesToBurn = pw.atriskusdAmount;
        uint256 currentValue = convertToAssets(pw.atriskusdAmount);
        uint256 riskusdToTransfer = currentValue < pw.riskusdAmount ? currentValue : pw.riskusdAmount;
        uint256 capWindowStart = pw.weeklyCapWindowStart;
        uint256 capReservedAssets = pw.weeklyCapReservedAssets;
        bool hasLegacyReservation = capWindowStart != 0 && capReservedAssets != 0;
        bool staleReservedWindow = false;
        if (riskusdToTransfer == 0) revert ZeroRedemptionOutput();
        if (hasLegacyReservation) {
            staleReservedWindow = _refreshPendingWithdrawalWindow(capWindowStart);
            if (staleReservedWindow) {
                _enforceWeeklyWithdrawalCap(riskusdToTransfer);
            }
        } else {
            _enforceWeeklyWithdrawalCap(riskusdToTransfer);
        }

        // OF-M11: slippage protection
        if (riskusdToTransfer < minAmountOut) revert SlippageExceeded(riskusdToTransfer, minAmountOut);

        uint256 backingPerShareBefore = _backingPerShareRay();
        delete _pendingWithdrawals[msg.sender];
        if (hasLegacyReservation && !staleReservedWindow && capReservedAssets > riskusdToTransfer) {
            _refundWeeklyWithdrawalCap(capWindowStart, capReservedAssets - riskusdToTransfer);
        }

        // Burn the locked shares from contract
        _burn(address(this), sharesToBurn);
        _syncAutoRenewDisabledTracking(msg.sender);

        // OF-16-025: State update before external call for strict CEI ordering
        // OF-009 (11th audit): Decrement by transfer amount, not full share value.
        // The excess (currentValue - riskusdToTransfer) from yield during cooldown stays
        // in the vault as legitimate assets backing other depositors' shares.
        _decreaseLegitimateAssets(riskusdToTransfer);

        _assertBackingPerShareNotDecreased(backingPerShareBefore);
        IERC20(asset()).safeTransfer(msg.sender, riskusdToTransfer);

        emit WithdrawalExecuted(msg.sender, riskusdToTransfer);
    }

    /// @notice OF-L11: Intentional design — withdrawal/cancellation paths remain open during pause to allow depositor exit.
    /// @dev OF-NEW-11 (12th audit): Gated by lossPending to prevent cancel→re-deposit optionality during loss window.
    function cancelWithdrawal() external nonReentrant {
        PendingWithdrawal storage pw = _pendingWithdrawals[msg.sender];
        if (!pw.active) revert NoPendingWithdrawal();
        // OF-NEW-11 (12th audit): Block cancellation while loss is pending
        _requireNoLossPending();
        _requireNotBlocked(msg.sender);

        uint256 sharesToReturn = pw.atriskusdAmount;
        uint256 capWindowStart = pw.weeklyCapWindowStart;
        uint256 capReservedAssets = pw.weeklyCapReservedAssets;

        delete _pendingWithdrawals[msg.sender];
        _refundWeeklyWithdrawalCap(capWindowStart, capReservedAssets);

        _transfer(address(this), msg.sender, sharesToReturn);

        emit WithdrawalCancelled(msg.sender, sharesToReturn);
    }

    // ============================================================
    // Tier Upgrade / Reversion / Renewal (StakingQueue-only)
    // ============================================================
    function redeemForUpgrade(address depositor, uint256 shares)
        external
        whenNotPaused
        nonReentrant
        returns (uint256 assets)
    {
        if (msg.sender != _stakingQueue) revert UnauthorizedStakingQueue();
        if (shares == 0) revert ZeroAmount();
        // OF-008: Block upgrade if depositor has a pending withdrawal
        if (_pendingWithdrawals[depositor].active) revert PendingWithdrawalExists();
        // OF-NEW-10 (12th audit): Block upgrade if lockup not expired
        if (_lockupPeriod > 0 && block.timestamp < _lockExpiry[depositor]) {
            revert LockupNotExpired(_lockExpiry[depositor]);
        }
        _requireNoLossPending(); // OF-13-004: Block tier transitions during loss
        _requireNotBlocked(msg.sender);
        _requireNotBlocked(depositor);

        uint256 backingPerShareBefore = _backingPerShareRay();
        assets = previewRedeem(shares);
        if (assets == 0) revert ZeroRedemptionOutput();
        _enforceWeeklyWithdrawalCap(assets);

        _burn(depositor, shares);

        IERC20(asset()).safeTransfer(msg.sender, assets);
        emit Withdraw(msg.sender, msg.sender, depositor, assets, shares);

        _decreaseLegitimateAssets(assets);
        _assertBackingPerShareNotDecreased(backingPerShareBefore);
    }

    function redeemForReversion(address depositor, uint256 shares)
        external
        whenNotPaused
        nonReentrant
        returns (uint256 assets)
    {
        if (msg.sender != _stakingQueue) revert UnauthorizedStakingQueue();
        if (shares == 0) revert ZeroAmount();

        if (_lockupPeriod > 0 && block.timestamp < _lockExpiry[depositor]) {
            revert LockupNotExpired(_lockExpiry[depositor]);
        }

        if (!_autoRenewDisabled[depositor]) revert AutoRenewEnabled();
        _requireNoLossPending(); // OF-13-004: Block tier transitions during loss
        _requireNotBlocked(msg.sender);
        _requireNotBlocked(depositor);

        uint256 backingPerShareBefore = _backingPerShareRay();
        assets = previewRedeem(shares);
        if (assets == 0) revert ZeroRedemptionOutput();
        _enforceWeeklyWithdrawalCap(assets);

        _burn(depositor, shares);

        IERC20(asset()).safeTransfer(msg.sender, assets);
        emit Withdraw(msg.sender, msg.sender, depositor, assets, shares);

        _decreaseLegitimateAssets(assets);
        _assertBackingPerShareNotDecreased(backingPerShareBefore);
    }

    function renewLockup(address depositor) external whenNotPaused nonReentrant returns (uint256) {
        if (msg.sender != _stakingQueue) revert UnauthorizedStakingQueue();

        if (_lockupPeriod > 0 && block.timestamp < _lockExpiry[depositor]) {
            revert LockupNotExpired(_lockExpiry[depositor]);
        }

        if (_autoRenewDisabled[depositor]) revert AutoRenewDisabled();

        _lockExpiry[depositor] = block.timestamp + _lockupPeriod;
        _syncAutoRenewDisabledTracking(depositor);

        emit LockupRenewed(depositor, _lockExpiry[depositor]);
        return _lockExpiry[depositor];
    }

    // ============================================================
    // Auto-Renewal
    // ============================================================
    function setAutoRenew(bool enabled) external {
        _autoRenewDisabled[msg.sender] = !enabled;
        _syncAutoRenewDisabledTracking(msg.sender);
        emit AutoRenewChanged(msg.sender, enabled);
    }

    // ============================================================
    // Configuration (owner-only)
    // ============================================================
    /// @notice OF-H02: setYieldSource now only proposes — no instant effect.
    /// Use finalizeYieldSource() or acceptYieldSource() to complete the change.
    function setYieldSource(address newYieldSource) external onlyOwner {
        if (newYieldSource == address(0)) revert ZeroAddress();
        _pendingYieldSource = newYieldSource;
        _yieldSourceProposedAt = block.timestamp; // OF-002 (11th audit)
        emit YieldSourceProposed(_yieldSource, newYieldSource);
    }

    /// @notice OF-H02: Owner-side finalization for yield source change (for contract recipients).
    function finalizeYieldSource() external onlyOwner {
        if (_pendingYieldSource == address(0)) revert ZeroAddress();
        if (block.timestamp < _yieldSourceProposedAt + _finalizeDelay()) revert FinalizeDelayNotElapsed();
        if (block.timestamp > _yieldSourceProposedAt + PROPOSAL_EXPIRY) revert ProposalExpired();
        address old = _yieldSource;
        _yieldSource = _pendingYieldSource;
        _pendingYieldSource = address(0);
        _yieldSourceProposedAt = 0;
        _emergencyLossPendingOverride = false; // OF-21-018: clear override on yield source change
        emit YieldSourceUpdated(old, _yieldSource);
    }

    /// @notice OF-H02: setStakingQueue now only proposes — no instant effect.
    /// Use finalizeStakingQueue() or acceptStakingQueue() to complete the change.
    function setStakingQueue(address newStakingQueue) external onlyOwner {
        if (newStakingQueue == address(0)) revert ZeroAddress();
        _pendingStakingQueue = newStakingQueue;
        _stakingQueueProposedAt = block.timestamp; // OF-002 (11th audit)
        emit StakingQueueProposed(_stakingQueue, newStakingQueue);
    }

    /// @notice OF-H02: Owner-side finalization for staking queue change (for contract recipients).
    function finalizeStakingQueue() external onlyOwner {
        if (_pendingStakingQueue == address(0)) revert ZeroAddress();
        if (block.timestamp < _stakingQueueProposedAt + _finalizeDelay()) revert FinalizeDelayNotElapsed();
        if (block.timestamp > _stakingQueueProposedAt + PROPOSAL_EXPIRY) revert ProposalExpired();
        address old = _stakingQueue;
        _stakingQueue = _pendingStakingQueue;
        _pendingStakingQueue = address(0);
        _stakingQueueProposedAt = 0;
        emit StakingQueueUpdated(old, _stakingQueue);
    }

    /// @notice OF-H02: Propose a new yield source (two-step handoff). Only owner can propose.
    function proposeYieldSource(address newYieldSource_) external onlyOwner {
        if (newYieldSource_ == address(0)) revert ZeroAddress();
        _pendingYieldSource = newYieldSource_;
        _yieldSourceProposedAt = block.timestamp; // OF-002 (11th audit)
        emit YieldSourceProposed(_yieldSource, newYieldSource_);
    }

    /// @notice OF-H02: Accept the pending yield source role. Only the pending yield source can call.
    function acceptYieldSource() external {
        if (msg.sender != _pendingYieldSource) revert NotPendingYieldSource();
        if (block.timestamp < _yieldSourceProposedAt + _finalizeDelay()) revert FinalizeDelayNotElapsed();
        if (block.timestamp > _yieldSourceProposedAt + PROPOSAL_EXPIRY) revert ProposalExpired();
        address old = _yieldSource;
        _yieldSource = _pendingYieldSource;
        _pendingYieldSource = address(0);
        _yieldSourceProposedAt = 0;
        _emergencyLossPendingOverride = false; // OF-21-018: clear override on yield source change
        emit YieldSourceUpdated(old, _yieldSource);
    }

    /// @notice OF-H02: View the pending yield source address.
    function pendingYieldSource() external view returns (address) {
        return _pendingYieldSource;
    }

    /// @notice OF-H02: Clear the pending yield source to prevent stale proposals surviving UUPS upgrades.
    function clearPendingYieldSource() external onlyOwner {
        _pendingYieldSource = address(0);
        _yieldSourceProposedAt = 0;
    }

    /// @notice OF-H02: Propose a new staking queue (two-step handoff). Only owner can propose.
    function proposeStakingQueue(address newStakingQueue_) external onlyOwner {
        if (newStakingQueue_ == address(0)) revert ZeroAddress();
        _pendingStakingQueue = newStakingQueue_;
        _stakingQueueProposedAt = block.timestamp; // OF-002 (11th audit)
        emit StakingQueueProposed(_stakingQueue, newStakingQueue_);
    }

    /// @notice OF-H02: Accept the pending staking queue role. Only the pending staking queue can call.
    function acceptStakingQueue() external {
        if (msg.sender != _pendingStakingQueue) revert NotPendingStakingQueue();
        if (block.timestamp < _stakingQueueProposedAt + _finalizeDelay()) revert FinalizeDelayNotElapsed();
        if (block.timestamp > _stakingQueueProposedAt + PROPOSAL_EXPIRY) revert ProposalExpired();
        address old = _stakingQueue;
        _stakingQueue = _pendingStakingQueue;
        _pendingStakingQueue = address(0);
        _stakingQueueProposedAt = 0;
        emit StakingQueueUpdated(old, _stakingQueue);
    }

    /// @notice OF-H02: View the pending staking queue address.
    function pendingStakingQueue() external view returns (address) {
        return _pendingStakingQueue;
    }

    /// @notice OF-H02: Clear the pending staking queue to prevent stale proposals surviving UUPS upgrades.
    function clearPendingStakingQueue() external onlyOwner {
        _pendingStakingQueue = address(0);
        _stakingQueueProposedAt = 0;
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
        address oldBlocklist = _blocklist;
        _blocklist = blocklist_;
        emit BlocklistSet(oldBlocklist, blocklist_);
    }

    function setCooldownPeriod(uint256 newCooldownPeriod) external onlyOwner {
        uint256 old = _cooldownPeriod;
        _cooldownPeriod = newCooldownPeriod;
        emit CooldownPeriodUpdated(old, newCooldownPeriod);
    }

    function setWeeklyWithdrawalCapBps(uint256 bps_) external onlyOwner {
        _setWeeklyWithdrawalCapBps(bps_);
    }

    function shrinkWeeklyWithdrawalCapBps(uint256 bps_) external {
        _requireEmergencyCapTightener();
        if (bps_ > _effectiveWeeklyWithdrawalCapBps()) revert CapTighteningOnly();
        _setWeeklyWithdrawalCapBps(bps_);
    }

    // ============================================================
    // Pause (owner, governor, or guardian module — OF-19-002)
    // ============================================================
    function pause() external {
        if (msg.sender != owner() && msg.sender != _forageGovernor && !_isGuardianModule(msg.sender)) {
            revert OwnableUnauthorizedAccount(msg.sender);
        }
        _pause();
    }

    function unpause() external {
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
        return _pendingWithdrawals[depositor].active;
    }

    function lockupShares(address depositor) external view returns (uint256) {
        return balanceOf(depositor);
    }

    function pendingWithdrawal(address requester) external view returns (PendingWithdrawal memory) {
        return _pendingWithdrawals[requester];
    }

    function pendingWithdrawalAmount(address account)
        external
        view
        returns (uint256 riskusdAmount, uint256 atriskusdAmount)
    {
        PendingWithdrawal storage pw = _pendingWithdrawals[account];
        return (pw.riskusdAmount, pw.atriskusdAmount);
    }

    function pendingWithdrawalCooldownEnd(address account) external view returns (uint256) {
        PendingWithdrawal storage pw = _pendingWithdrawals[account];
        return pw.requestTimestamp + pw.cooldownPeriod;
    }

    function pendingWithdrawalActive(address account) external view returns (bool) {
        return _pendingWithdrawals[account].active;
    }

    function pendingWithdrawalWeeklyCap(address account)
        external
        view
        returns (uint256 windowStart, uint256 reservedAssets)
    {
        PendingWithdrawal storage pw = _pendingWithdrawals[account];
        return (pw.weeklyCapWindowStart, pw.weeklyCapReservedAssets);
    }

    function totalYieldAccrued() external view returns (uint256) {
        return _totalYieldAccrued;
    }

    function totalLossAbsorbed() external view returns (uint256) {
        return _totalLossAbsorbed;
    }

    // ============================================================
    // UUPS
    // ============================================================
    /// @notice Reinitializer for UUPS upgrade — seeds _legitimateAssets from raw asset balance.
    /// @dev OF-17-001: Uses IERC20(asset()).balanceOf(address(this)) instead of totalAssets()
    /// to break the circular dependency introduced by OF-16-007 (totalAssets returns _legitimateAssets).
    function initializeV2() external reinitializer(2) onlyOwner {
        _legitimateAssets = IERC20(asset()).balanceOf(address(this));
    }

    function initializeV3(string memory abbreviation_) external reinitializer(3) onlyOwner {
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

    function renounceOwnership() public override onlyOwner {
        revert RenounceOwnershipDisabled();
    }

    // ============================================================
    // Transfer Lock Semantics
    // ============================================================
    function _update(address from, address to, uint256 value) internal override {
        // Block transfers while sender is locked (except mint/burn and self-transfers for cooldown)
        if (from != address(0) && to != address(0) && value > 0) {
            // Allow StakingQueue and contract itself (cooldown operations)
            if (from != _stakingQueue && from != address(this)) {
                if (block.timestamp < _lockExpiry[from]) {
                    revert LockupNotExpired(_lockExpiry[from]);
                }
                if (to != address(this) && _hasExpiredAutoRenewDisabledAccount(from)) {
                    revert ExpiredAutoRenewDisabledLockup();
                }
            }
        }
        if (from != address(0)) {
            _requireNotBlocked(from);
        }
        if (to != address(0)) {
            _requireNotBlocked(to);
        }

        super._update(from, to, value);

        // OF-16-024: StakingQueue lockup propagation removed — _lockExpiry[_stakingQueue] is always 0
        // because StakingQueue never has its own lockup set. Actual lockup is set in deposit() at
        // line 170 BEFORE super.deposit() triggers _update. The propagation was dead code.
        if (from != address(0)) {
            _syncAutoRenewDisabledTracking(from);
        }
        if (to != address(0) && to != from) {
            _syncAutoRenewDisabledTracking(to);
        }
    }

    function approve(address spender, uint256 value) public override(ERC20Upgradeable, IERC20) returns (bool) {
        _requireNotBlocked(msg.sender);
        if (value != 0) {
            _requireNotBlocked(spender);
        }
        return super.approve(spender, value);
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
    /// @notice OF-16-007: Override totalAssets() to return _legitimateAssets instead of raw balance.
    /// Prevents donation amplification — direct RISKUSD transfers to the vault cannot inflate
    /// the share price visible through convertToAssets/convertToShares.
    function totalAssets() public view override returns (uint256) {
        return _legitimateAssets;
    }

    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }

    /// @notice OF-16-019: Emergency override for permanently unreachable yield source.
    /// Only callable by owner. When set, _requireNoLossPending() is bypassed.
    /// OF-18-004: Cannot enable during active loss to prevent stale-price withdrawals.
    function setEmergencyLossPendingOverride(bool override_) external onlyOwner {
        if (override_) {
            // OF-18-004: Block override activation during active loss
            (bool ok, bytes memory data) = _yieldSource.staticcall(abi.encodeWithSignature("riskusdVault()"));
            if (!ok || data.length < 32) revert EmergencyOverrideValidationFailed(_yieldSource);
            address vault = abi.decode(data, (address));
            (bool ok2, bytes memory data2) = vault.staticcall(abi.encodeWithSignature("lossPending()"));
            if (!ok2 || data2.length < 32) revert EmergencyOverrideValidationFailed(_yieldSource);
            if (abi.decode(data2, (bool))) {
                revert CannotOverrideDuringActiveLoss();
            }
            if (_custodianSettlementPending(vault)) revert CustodianSettlementPending();
        }
        _emergencyLossPendingOverride = override_;
        emit EmergencyLossPendingOverrideSet(override_);
    }

    /// @dev OF-NEW-05 (12th audit): Fail-closed lossPending check. Reverts if either
    /// staticcall fails (misconfigured yieldSource, no code) instead of silently proceeding.
    /// OF-16-019: Bypassed when _emergencyLossPendingOverride is set by owner.
    function _requireNoLossPending() private view {
        if (_emergencyLossPendingOverride) return;
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
        if (totalSupply() != 0 && totalAssets() == 0) revert ZeroAssetLegacySupply();
    }

    function _extendLockup(address receiver) private {
        uint256 newExpiry = block.timestamp + _lockupPeriod;
        if (newExpiry > _lockExpiry[receiver]) {
            _lockExpiry[receiver] = newExpiry;
            _syncAutoRenewDisabledTracking(receiver);
        }
    }

    function _syncAutoRenewDisabledTracking(address account) private {
        uint256 expiry = _lockExpiry[account];
        uint256 effectiveBalance = _autoRenewDisabledEffectiveBalance(account);
        bool trackedExpired = _autoRenewDisabledTracked[account] && expiry != 0 && block.timestamp >= expiry;
        if (
            _lockupPeriod == 0 || (!_autoRenewDisabled[account] && !trackedExpired) || expiry == 0
                || effectiveBalance == 0
        ) {
            _untrackAutoRenewDisabled(account);
            return;
        }

        if (!_autoRenewDisabledTracked[account]) {
            _autoRenewDisabledTracked[account] = true;
            _autoRenewDisabledTrackedCount += 1;
        }
        if (_autoRenewDisabledTrackedExpiry[account] != expiry) {
            uint256 oldExpiry = _autoRenewDisabledTrackedExpiry[account];
            if (oldExpiry != 0) {
                _autoRenewDisabledExpiryCounts[oldExpiry] -= 1;
            }
            _autoRenewDisabledTrackedExpiry[account] = expiry;
            _autoRenewDisabledExpiryCounts[expiry] += 1;
            _pushAutoRenewDisabledExpiry(account, expiry);
        }
        _pruneAutoRenewDisabledExpiryHeap();
    }

    function _autoRenewDisabledEffectiveBalance(address account) private view returns (uint256) {
        PendingWithdrawal storage pending = _pendingWithdrawals[account];
        uint256 pendingShares = pending.active ? pending.atriskusdAmount : 0;
        return balanceOf(account) + pendingShares;
    }

    function _hasExpiredAutoRenewDisabledAccount(address account) private view returns (bool) {
        uint256 expiry = _autoRenewDisabledTrackedExpiry[account];
        return _autoRenewDisabledTracked[account] && expiry != 0 && block.timestamp >= expiry;
    }

    function _untrackAutoRenewDisabled(address account) private {
        if (!_autoRenewDisabledTracked[account]) return;
        _autoRenewDisabledTracked[account] = false;
        uint256 oldExpiry = _autoRenewDisabledTrackedExpiry[account];
        _autoRenewDisabledTrackedExpiry[account] = 0;
        if (oldExpiry != 0) {
            _autoRenewDisabledExpiryCounts[oldExpiry] -= 1;
        }
        uint256 count = _autoRenewDisabledTrackedCount;
        _autoRenewDisabledTrackedCount = count == 0 ? 0 : count - 1;
        if (_autoRenewDisabledTrackedCount == 0) {
            _earliestAutoRenewDisabledExpiry = 0;
            delete _autoRenewDisabledExpiryHeap;
            return;
        }
        _pruneAutoRenewDisabledExpiryHeap();
    }

    function _pushAutoRenewDisabledExpiry(address, uint256 expiry) private {
        _autoRenewDisabledExpiryHeap.push(expiry);
        uint256 index = _autoRenewDisabledExpiryHeap.length - 1;
        while (index != 0) {
            uint256 parent = (index - 1) / 2;
            if (_autoRenewDisabledExpiryHeap[parent] <= expiry) break;
            _autoRenewDisabledExpiryHeap[index] = _autoRenewDisabledExpiryHeap[parent];
            index = parent;
        }
        _autoRenewDisabledExpiryHeap[index] = expiry;
    }

    function _pruneAutoRenewDisabledExpiryHeap() private {
        while (_autoRenewDisabledExpiryHeap.length != 0) {
            uint256 root = _autoRenewDisabledExpiryHeap[0];
            if (_autoRenewDisabledExpiryCounts[root] != 0) {
                _earliestAutoRenewDisabledExpiry = root;
                return;
            }
            _popAutoRenewDisabledExpiryHeap();
        }
        _earliestAutoRenewDisabledExpiry = 0;
    }

    function _popAutoRenewDisabledExpiryHeap() private {
        uint256 length = _autoRenewDisabledExpiryHeap.length;
        if (length == 1) {
            _autoRenewDisabledExpiryHeap.pop();
            return;
        }

        uint256 tail = _autoRenewDisabledExpiryHeap[length - 1];
        _autoRenewDisabledExpiryHeap.pop();
        uint256 index = 0;
        uint256 child = 1;
        while (child < length - 1) {
            uint256 right = child + 1;
            if (right < length - 1 && _autoRenewDisabledExpiryHeap[right] < _autoRenewDisabledExpiryHeap[child]) {
                child = right;
            }
            if (_autoRenewDisabledExpiryHeap[child] >= tail) break;
            _autoRenewDisabledExpiryHeap[index] = _autoRenewDisabledExpiryHeap[child];
            index = child;
            child = index * 2 + 1;
        }
        _autoRenewDisabledExpiryHeap[index] = tail;
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
        _resetWeeklyWithdrawalWindowIfExpired();
        if (_weeklyWithdrawalWindowStartAssets == 0) {
            _weeklyWithdrawalWindowStartAssets = totalAssets();
        }

        uint256 used = _weeklyWithdrawalUsed;
        uint256 cap = _weeklyWithdrawalWindowStartAssets * _effectiveWeeklyWithdrawalCapBps() / 10000;
        uint256 remaining = used >= cap ? 0 : cap - used;
        if (assets > remaining) revert WeeklyWithdrawalCapExceeded(assets, remaining);
        _weeklyWithdrawalUsed = used + assets;
    }

    function _refundWeeklyWithdrawalCap(uint256 windowStart, uint256 assets) private {
        if (assets == 0 || windowStart == 0 || _weeklyWithdrawalWindowStart != windowStart) return;
        uint256 used = _weeklyWithdrawalUsed;
        _weeklyWithdrawalUsed = assets >= used ? 0 : used - assets;
    }

    function _refreshPendingWithdrawalWindow(uint256 reservedWindowStart) private returns (bool) {
        _resetWeeklyWithdrawalWindowIfExpired();
        return reservedWindowStart != _weeklyWithdrawalWindowStart;
    }

    function _resetWeeklyWithdrawalWindowIfExpired() private {
        uint256 start = _weeklyWithdrawalWindowStart;
        if (start == 0 || block.timestamp > start + WEEKLY_WITHDRAWAL_WINDOW) {
            _weeklyWithdrawalWindowStart = block.timestamp;
            _weeklyWithdrawalUsed = 0;
            _weeklyWithdrawalWindowStartAssets = 0;
        }
    }

    function _requireNotBlocked(address account) internal view {
        address blocklist_ = _blocklist;
        if (blocklist_ != address(0) && IBlocklist(blocklist_).isBlocked(account)) {
            revert BlockedAddress(account);
        }
    }
}
