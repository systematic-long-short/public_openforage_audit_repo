// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "../AllowlistGatedUpgradeable.sol";
import "../FinalizeDelayProfile.sol";
import "../interfaces/IAllowlist.sol";
import "../interfaces/IBlocklist.sol";
import "../interfaces/IRISKUSDSettlement.sol";
import "../interfaces/IVaultRegistry.sol";
import {AtRiskUSDProfitModule} from "./AtRiskUSDProfitModule.sol";
import {AtRiskUSDWeeklyExitModule} from "./AtRiskUSDWeeklyExitModule.sol";
import {IUSDCTreasuryYieldClaims} from "../interfaces/IUSDCTreasuryYieldClaims.sol";

contract AtRiskUSDStateModule is
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

    error AutoRenewEnabled();
    error BlockedAddress(address account);
    error CustodianSettlementHookFailed(address custodian);
    error CustodianGetterUnavailable(address vault);
    error CustodianSettlementPending();
    error DirectCallForbidden();
    error ProfitModuleUnavailable(address module);
    error ExpiredAutoRenewDisabledLockup();
    error ExchangeRateDecreased(uint256 beforeAssets, uint256 afterAssets);
    error LockupNotExpired(uint256 lockExpiry);
    error LossPending();
    error MalformedLossPendingReturn(address vault, uint256 value);
    error NoPendingWithdrawal();
    error FreshDeploymentRequired(uint64 observedVersion);
    error WeeklyWithdrawalCapExceeded(uint256 requested, uint256 remaining);
    error YieldSourceReachable();
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
    error InsufficientFundedAssets(uint256 requested, uint256 available);
    error FinalClaimBurn(uint256 claim);
    error NoPositiveWithdrawalSlice(uint256 remainingCap);
    error NotTotalLossState();
    error ZeroSupplyYield();
    error ExpiryHeapInvariant(uint256 expiry);
    error SlippageExceeded(uint256 amountOut, uint256 minAmountOut);
    error CooldownNotElapsed(uint256 unlockTime);
    error CooldownEnabled();
    error ZeroRedemptionOutput();
    error ZeroAddress();
    error InsufficientAllowlistDuration(uint256 requiredUntil, uint256 allowedUntil);
    error AllowlistHorizonOverflow();
    error BeneficiaryNotAllowed(address account);
    error PendingWithdrawalExists();
    error UnauthorizedStakingQueue();
    error UnauthorizedYieldSource();
    error SafeERC20FailedOperation(address token);
    error UnfundedZeroSupplyClaim(uint256 claim);
    error ZeroAmount();
    error ZeroAssetLegacySupply();
    error EmergencyRecoveryWindowClosed();
    error WeeklyExitWindowOpen(uint256 closesAt);
    error WeeklyExitSettlementRequired(uint256 closesAt);
    error WeeklyExitAccountingInvariant(uint256 expected, uint256 actual);
    error WeeklyExitArithmeticOverflow();
    error NoWeeklyExitAllocation();

    event ExchangeRateInvariantFailure(uint256 beforeAssets, uint256 afterAssets);
    event YieldAccrued(uint256 riskusdAmount);
    event LossAbsorbed(uint256 riskusdAmount);
    event YieldSourceUpdated(address indexed oldSource, address indexed newSource);
    event StakingQueueUpdated(address indexed oldQueue, address indexed newQueue);
    event ForageGovernorSet(address indexed oldGovernor, address indexed newGovernor);
    event WithdrawalRequested(
        address indexed requester, uint256 atriskusdAmount, uint256 riskusdAmount, uint256 cooldownEnd
    );
    event WithdrawalExecuted(address indexed requester, uint256 riskusdAmount);
    event WithdrawalCancelled(address indexed requester, uint256 atriskusdAmount);
    event LockupTransferred(address indexed from, address indexed to, uint256 lockExpiry);
    event WorthlessSharesBurned(address indexed holder, uint256 shares);
    event UnreachableWithdrawalRecovered(address indexed beneficiary, uint256 shares);
    event WeeklyExitSettled(uint256 indexed windowStart, uint256 demandShares, uint256 roomShares);
    event WeeklyExitSharesReleased(address indexed holder, uint256 shares);

    struct PendingWithdrawal {
        uint256 atriskusdAmount;
        uint256 riskusdAmount;
        uint256 requestTimestamp;
        bool active;
        uint256 cooldownPeriod;
        uint256 weeklyCapWindowStart;
        uint256 weeklyCapReservedAssets;
    }

    struct WeeklyExitCohort {
        uint256 demandShares;
        uint256 roomShares;
        uint256 fractionRay;
        uint256 activeRequests;
        bool settled;
    }

    struct WithdrawalExecution {
        uint256 sharesToBurn;
        uint256 riskusdToTransfer;
        uint256 backingPerShareBefore;
    }

    struct WithdrawalCancellation {
        address beneficiary;
        uint256 shares;
    }

    enum PendingWithdrawalMigrationState {
        Unconfirmed,
        Confirmed,
        SharesRecovering
    }

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
    address private _pendingYieldSource;
    address private _pendingStakingQueue;
    uint256 private _yieldSourceProposedAt;
    uint256 private _stakingQueueProposedAt;
    address internal _pendingForageGovernor;
    uint256 internal _pendingForageGovernorProposedAt;
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
    uint64 private _freshDeploymentVersion;
    uint64 private _profitEntitlementVersion;
    uint256 private _weeklyExitDemandScaled;
    uint256 private _weeklyExitAllocatedScaled;
    uint256 private _weeklyExitRoomCarryScaled;
    uint256 private _weeklyExitSurvivalIndex;
    uint256 private _weeklyExitGeneration;
    mapping(address => uint256) private _weeklyExitRequestBasis;
    mapping(address => uint256) private _weeklyExitRequestStartIndex;
    mapping(address => uint256) private _weeklyExitRequestGeneration;
    mapping(address => uint256) private _weeklyExitClaimedScaled;
    uint256 private _weeklyExitOpenRequests;
    mapping(uint256 => WeeklyExitCohort) private _weeklyExitCohorts;
    uint256[17] private __gap;

    uint256 internal constant WEEKLY_WITHDRAWAL_WINDOW = 7 days;
    uint256 internal constant DEFAULT_WEEKLY_WITHDRAWAL_CAP_BPS = 500;
    uint256 internal constant RAY = 1e27;
    uint256 internal constant SHARE_SCALE = 1e6;
    uint64 private constant FRESH_DEPLOYMENT_VERSION = 5;
    uint64 private constant PROFIT_ENTITLEMENT_VERSION = 3;

    address private immutable _SELF;
    AtRiskUSDProfitModule private immutable _PROFIT_MODULE;

    constructor(address profitModule_) {
        if (profitModule_ == address(0) || profitModule_.code.length == 0) {
            revert ProfitModuleUnavailable(profitModule_);
        }
        _SELF = address(this);
        _PROFIT_MODULE = AtRiskUSDProfitModule(profitModule_);
        _disableInitializers();
    }

    modifier onlyDelegateCall() {
        if (address(this) == _SELF) revert DirectCallForbidden();
        _requireFreshDeployment();
        _;
    }

    function _requireFreshDeployment() private view {
        uint64 version = _freshDeploymentVersion;
        if (version != FRESH_DEPLOYMENT_VERSION || _profitEntitlementVersion != PROFIT_ENTITLEMENT_VERSION) {
            revert FreshDeploymentRequired(version);
        }
    }

    function _authorizeUpgrade(address) internal view override onlyOwner {
        _requireFreshDeployment();
    }

    function setAutoRenewDisabled(address account, bool disabled) external onlyDelegateCall {
        _autoRenewDisabled[account] = disabled;
        _syncAutoRenewDisabledTracking(account);
    }

    function setLockExpiry(address depositor, uint256 newExpiry) external onlyDelegateCall {
        _lockExpiry[depositor] = newExpiry;
        _syncAutoRenewDisabledTracking(depositor);
    }

    function applyPendingYieldSource() external onlyDelegateCall {
        address old = _yieldSource;
        _delegateProfitModule(
            abi.encodeCall(AtRiskUSDProfitModule.validateYieldSourceHandoff, (old, _pendingYieldSource))
        );
        _yieldSource = _pendingYieldSource;
        _pendingYieldSource = address(0);
        _yieldSourceProposedAt = 0;
        _emergencyLossPendingOverride = false;
        _emergencyLossPendingOverrideUntil = 0;
        emit YieldSourceUpdated(old, _yieldSource);
    }

    function applyPendingStakingQueue() external onlyDelegateCall {
        address old = _stakingQueue;
        _stakingQueue = _pendingStakingQueue;
        _pendingStakingQueue = address(0);
        _stakingQueueProposedAt = 0;
        emit StakingQueueUpdated(old, _stakingQueue);
    }

    function applyPendingForageGovernor() external onlyDelegateCall {
        address old = _forageGovernor;
        _forageGovernor = _pendingForageGovernor;
        _pendingForageGovernor = address(0);
        _pendingForageGovernorProposedAt = 0;
        emit ForageGovernorSet(old, _forageGovernor);
    }

    function accrueYield(uint256 riskusdAmount) external onlyDelegateCall {
        if (msg.sender != _yieldSource) revert UnauthorizedYieldSource();
        if (riskusdAmount == 0) revert ZeroAmount();
        _requireNotBlocked(msg.sender);
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), riskusdAmount);
        _totalYieldAccrued += riskusdAmount;
        _delegateProfitModule(abi.encodeCall(AtRiskUSDProfitModule.fundUnpaidProfit, (riskusdAmount)));

        emit YieldAccrued(riskusdAmount);
    }

    function deposit(uint256 assets, address receiver) public override onlyDelegateCall returns (uint256 shares) {
        if (msg.sender != _stakingQueue) revert UnauthorizedStakingQueue();
        if (assets == 0) revert ZeroAmount();
        _requireNoLossPending();
        _requireNotBlocked(msg.sender);
        _requireNotBlocked(receiver);
        _requireAllowedBeneficiary(receiver);
        _extendLockup(receiver);
        uint256 backingPerShareBefore = _backingPerShareRay();
        shares = super.deposit(assets, receiver);
        _assertBackingPerShareNotDecreased(backingPerShareBefore);
    }

    function mint(uint256 shares, address receiver) public override onlyDelegateCall returns (uint256 assets) {
        if (msg.sender != _stakingQueue) revert UnauthorizedStakingQueue();
        if (shares == 0) revert ZeroAmount();
        _requireNoLossPending();
        _requireNotBlocked(msg.sender);
        _requireNotBlocked(receiver);
        _requireAllowedBeneficiary(receiver);
        _extendLockup(receiver);
        uint256 backingPerShareBefore = _backingPerShareRay();
        assets = super.mint(shares, receiver);
        _assertBackingPerShareNotDecreased(backingPerShareBefore);
    }

    function withdraw(uint256 assets, address receiver, address owner_)
        public
        override
        onlyDelegateCall
        returns (uint256 shares)
    {
        if (assets == 0) revert ZeroAmount();
        if (block.timestamp < _lockExpiry[owner_]) revert LockupNotExpired(_lockExpiry[owner_]);
        if (_cooldownPeriod > 0) revert CooldownEnabled();
        _requireNoLossPending();
        _requireNotBlocked(msg.sender);
        _requireNotBlocked(receiver);
        _requireNotBlocked(owner_);
        if (receiver != owner_ || owner_ != msg.sender) {
            _requireAllowedBeneficiary(receiver);
            _requireAllowedBeneficiary(owner_);
        }
        uint256 backingPerShareBefore = _backingPerShareRay();
        _requireFundedPayout(assets);
        _ensureDirectWeeklyWithdrawalCapacity(assets);
        shares = super.withdraw(assets, receiver, owner_);
        _weeklyWithdrawalUsed += assets;
        _assertBackingPerShareNotDecreased(backingPerShareBefore);
    }

    function redeem(uint256 shares, address receiver, address owner_)
        public
        override
        onlyDelegateCall
        returns (uint256 assets)
    {
        if (block.timestamp < _lockExpiry[owner_]) revert LockupNotExpired(_lockExpiry[owner_]);
        if (_cooldownPeriod > 0) revert CooldownEnabled();
        _requireNoLossPending();
        _requireNotBlocked(msg.sender);
        _requireNotBlocked(receiver);
        _requireNotBlocked(owner_);
        if (receiver != owner_ || owner_ != msg.sender) {
            _requireAllowedBeneficiary(receiver);
            _requireAllowedBeneficiary(owner_);
        }
        uint256 backingPerShareBefore = _backingPerShareRay();
        assets = previewRedeem(shares);
        if (assets == 0) revert ZeroRedemptionOutput();
        _requireFundedPayout(assets);
        _ensureDirectWeeklyWithdrawalCapacity(assets);
        assets = super.redeem(shares, receiver, owner_);
        _weeklyWithdrawalUsed += assets;
        _assertBackingPerShareNotDecreased(backingPerShareBefore);
    }

    function redeemForUpgrade(address depositor, uint256 shares) external onlyDelegateCall returns (uint256 assets) {
        if (msg.sender != _stakingQueue) revert UnauthorizedStakingQueue();
        if (shares == 0) revert ZeroAmount();
        _requireNoPendingWithdrawal(depositor);
        if (_lockupPeriod > 0 && block.timestamp < _lockExpiry[depositor]) {
            revert LockupNotExpired(_lockExpiry[depositor]);
        }
        _requireNoLossPending();
        _requireNotBlocked(msg.sender);
        _requireNotBlocked(depositor);
        _requireAllowedBeneficiary(depositor);
        uint256 backingPerShareBefore = _backingPerShareRay();
        assets = previewRedeem(shares);
        if (assets == 0) revert ZeroRedemptionOutput();
        _requireFundedPayout(assets);
        _burn(depositor, shares);
        IERC20(asset()).safeTransfer(msg.sender, assets);
        emit Withdraw(msg.sender, msg.sender, depositor, assets, shares);
        _decreaseLegitimateAssets(assets);
        _assertBackingPerShareNotDecreased(backingPerShareBefore);
    }

    function redeemForReversion(address depositor, uint256 shares) external onlyDelegateCall returns (uint256 assets) {
        if (msg.sender != _stakingQueue) revert UnauthorizedStakingQueue();
        if (shares == 0) revert ZeroAmount();
        if (_lockupPeriod > 0 && block.timestamp < _lockExpiry[depositor]) {
            revert LockupNotExpired(_lockExpiry[depositor]);
        }
        if (!_autoRenewDisabled[depositor]) revert AutoRenewEnabled();
        _requireNoLossPending();
        _requireNotBlocked(msg.sender);
        _requireNotBlocked(depositor);
        _requireAllowedBeneficiary(depositor);
        uint256 backingPerShareBefore = _backingPerShareRay();
        assets = previewRedeem(shares);
        if (assets == 0) revert ZeroRedemptionOutput();
        _requireFundedPayout(assets);
        _burn(depositor, shares);
        IERC20(asset()).safeTransfer(msg.sender, assets);
        emit Withdraw(msg.sender, msg.sender, depositor, assets, shares);
        _decreaseLegitimateAssets(assets);
        _assertBackingPerShareNotDecreased(backingPerShareBefore);
    }

    function executeWithdrawal(uint256 minAmountOut) external onlyDelegateCall {
        PendingWithdrawal storage pending = _pendingWithdrawals[msg.sender];
        if (!pending.active) revert NoPendingWithdrawal();
        _requireNoLossPending();
        uint256 cooldownEnd = pending.requestTimestamp + pending.cooldownPeriod;
        if (block.timestamp < cooldownEnd) revert CooldownNotElapsed(cooldownEnd);
        _requireNotBlocked(msg.sender);

        uint256 cohortStart = pending.weeklyCapWindowStart;
        uint256 closesAt = _weeklyExitWindowEnd(cohortStart);
        if (block.timestamp < closesAt) revert WeeklyExitWindowOpen(closesAt);
        uint256 currentStart = _weeklyWithdrawalWindowStart;
        if (currentStart < cohortStart) revert WeeklyExitSettlementRequired(_weeklyExitWindowEnd(currentStart));
        if (currentStart == cohortStart) _settleWeeklyExitWindow();

        WeeklyExitCohort storage cohort = _weeklyExitCohorts[cohortStart];
        if (!cohort.settled) revert WeeklyExitSettlementRequired(closesAt);
        uint256 entitlement =
            AtRiskUSDWeeklyExitModule.entitlement(pending.atriskusdAmount, cohort.roomShares, cohort.demandShares);
        uint256 sharesToBurn;
        uint256 amountOut;
        if (entitlement != 0) {
            (sharesToBurn, amountOut) = _fundedWithdrawalSlice(pending, entitlement, _legitimateAssets);
            if (amountOut == 0) sharesToBurn = 0;
        }
        if (amountOut < minAmountOut) revert SlippageExceeded(amountOut, minAmountOut);

        WithdrawalExecution memory execution = WithdrawalExecution({
            sharesToBurn: sharesToBurn,
            riskusdToTransfer: amountOut,
            backingPerShareBefore: _backingPerShareRay()
        });
        _finishWithdrawal(execution);
    }

    function settleWeeklyExit() external onlyDelegateCall {
        _requireNoLossPending();
        _requireNotBlocked(msg.sender);
        _settleWeeklyExitWindow();
    }

    function absorbLoss(uint256 riskusdAmount) external onlyDelegateCall {
        if (msg.sender != _yieldSource) revert UnauthorizedYieldSource();
        if (riskusdAmount == 0) revert ZeroAmount();
        _requireNotBlocked(msg.sender);
        uint256 cap = totalAssets();
        if (_legitimateAssets < cap) cap = _legitimateAssets;
        if (riskusdAmount > cap) riskusdAmount = cap;
        _transferLossAssets(msg.sender, riskusdAmount);

        _decreaseLegitimateAssets(riskusdAmount);
        if (
            block.timestamp < _weeklyWithdrawalWindowStart + WEEKLY_WITHDRAWAL_WINDOW
                && _weeklyWithdrawalWindowStartAssets > 0
        ) {
            _weeklyWithdrawalWindowStartAssets = _weeklyWithdrawalWindowStartAssets >= riskusdAmount
                ? _weeklyWithdrawalWindowStartAssets - riskusdAmount
                : 0;
        }
        _totalLossAbsorbed += riskusdAmount;

        emit LossAbsorbed(riskusdAmount);
    }

    function _transferLossAssets(address recipient, uint256 amount) private {
        address riskusd = asset();
        bool tokenPaused;
        try IRISKUSDSettlement(riskusd).paused() returns (bool value) {
            tokenPaused = value;
        } catch {
            revert SafeERC20FailedOperation(riskusd);
        }
        if (!tokenPaused) {
            IERC20(riskusd).safeTransfer(recipient, amount);
            return;
        }
        if (!IRISKUSDSettlement(riskusd).transferLossSettlement(recipient, amount)) {
            revert SafeERC20FailedOperation(riskusd);
        }
    }

    function requestWithdrawal(uint256 atriskusdAmount) external onlyDelegateCall {
        if (atriskusdAmount == 0) revert ZeroAmount();
        _requireWeeklyExitWindowCurrent();
        if (_lockupPeriod > 0 && block.timestamp < _lockExpiry[msg.sender]) {
            revert LockupNotExpired(_lockExpiry[msg.sender]);
        }
        _requireNoPendingWithdrawal(msg.sender);
        _requireNotBlocked(msg.sender);
        _requireWithdrawalApprovalDuration();
        _requireNoLossPending();
        if (_cooldownPeriod > type(uint256).max - block.timestamp) revert WeeklyExitArithmeticOverflow();
        uint256 cooldownEnd = block.timestamp + _cooldownPeriod;
        uint256 cohortStart = _weeklyCohortStart(cooldownEnd);
        uint256 backingPerShareBefore = _backingPerShareRay();
        if (_weeklyWithdrawalWindowStartAssets == 0) _weeklyWithdrawalWindowStartAssets = totalAssets();
        uint256 riskusdAmount = convertToAssets(atriskusdAmount);
        if (riskusdAmount == 0) revert ZeroRedemptionOutput();

        _checkpointProfitAccount(msg.sender);
        _transfer(msg.sender, address(this), atriskusdAmount);
        _pendingWithdrawals[msg.sender] = PendingWithdrawal({
            atriskusdAmount: atriskusdAmount,
            riskusdAmount: riskusdAmount,
            requestTimestamp: block.timestamp,
            active: true,
            cooldownPeriod: _cooldownPeriod,
            weeklyCapWindowStart: cohortStart,
            weeklyCapReservedAssets: 0
        });
        _recordWeeklyExitRequest(cohortStart, atriskusdAmount);
        _syncAutoRenewDisabledTracking(msg.sender);

        emit WithdrawalRequested(msg.sender, atriskusdAmount, riskusdAmount, cooldownEnd);
        _assertBackingPerShareNotDecreased(backingPerShareBefore);
    }

    function _finishWithdrawal(WithdrawalExecution memory execution) private {
        _checkpointProfitAccount(msg.sender);
        PendingWithdrawal storage pending = _pendingWithdrawals[msg.sender];
        uint256 requestedShares = pending.atriskusdAmount;
        uint256 remainingShares = requestedShares - execution.sharesToBurn;
        _clearWeeklyExitRequest(pending.weeklyCapWindowStart, requestedShares);
        delete _pendingWithdrawals[msg.sender];
        _burn(address(this), execution.sharesToBurn);
        if (remainingShares != 0) {
            _updateWithLossCheck(address(this), msg.sender, remainingShares, true);
        }
        _syncAutoRenewDisabledTracking(msg.sender);
        if (execution.riskusdToTransfer != 0) _decreaseLegitimateAssets(execution.riskusdToTransfer);
        _assertBackingPerShareNotDecreased(execution.backingPerShareBefore);
        if (execution.riskusdToTransfer != 0) {
            IERC20(asset()).safeTransfer(msg.sender, execution.riskusdToTransfer);
            emit WithdrawalExecuted(msg.sender, execution.riskusdToTransfer);
        }
        if (remainingShares != 0) emit WeeklyExitSharesReleased(msg.sender, remainingShares);
    }

    function cancelWithdrawal() external onlyDelegateCall {
        PendingWithdrawal storage pending = _pendingWithdrawals[msg.sender];
        if (!pending.active) revert NoPendingWithdrawal();
        _requireNoLossPending();
        _requireNotBlocked(msg.sender);
        WithdrawalCancellation memory cancellation =
            WithdrawalCancellation({beneficiary: msg.sender, shares: pending.atriskusdAmount});
        _finishPendingWithdrawalCancellation(cancellation, true);
    }

    function recoverPendingWithdrawal() external onlyDelegateCall returns (uint256 shares) {
        if (!_emergencyRecoveryWindowOpen()) revert EmergencyRecoveryWindowClosed();
        if (!_yieldSourceIsUnreachable()) revert YieldSourceReachable();
        PendingWithdrawal storage pending = _pendingWithdrawals[msg.sender];
        if (!pending.active) revert NoPendingWithdrawal();
        _requireNotBlocked(msg.sender);
        shares = pending.atriskusdAmount;
        WithdrawalCancellation memory cancellation = WithdrawalCancellation({beneficiary: msg.sender, shares: shares});
        _finishPendingWithdrawalCancellation(cancellation, false);
        emit UnreachableWithdrawalRecovered(msg.sender, shares);
    }

    function _finishPendingWithdrawalCancellation(WithdrawalCancellation memory cancellation, bool checkLossPending)
        private
    {
        _checkpointProfitAccount(cancellation.beneficiary);
        uint256 cohortStart = _pendingWithdrawals[cancellation.beneficiary].weeklyCapWindowStart;
        _clearWeeklyExitRequest(cohortStart, cancellation.shares);
        delete _pendingWithdrawals[cancellation.beneficiary];
        _updateWithLossCheck(address(this), cancellation.beneficiary, cancellation.shares, checkLossPending);
        emit WithdrawalCancelled(cancellation.beneficiary, cancellation.shares);
    }

    function burnWorthlessShares(uint256 shares) external onlyDelegateCall {
        if (shares == 0) revert ZeroAmount();
        if (totalSupply() == 0 || totalAssets() != 0) revert NotTotalLossState();
        _requireNoPendingWithdrawal(msg.sender);
        _requireNoLossPending();
        _requireNotBlocked(msg.sender);
        _burn(msg.sender, shares);
        emit WorthlessSharesBurned(msg.sender, shares);
    }

    function update(address from, address to, uint256 value) external onlyDelegateCall {
        _update(from, to, value);
    }

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

    function _fundedWithdrawalSlice(PendingWithdrawal storage pending, uint256 shareLimit, uint256 payoutCap)
        private
        view
        returns (uint256 shares, uint256 amountOut)
    {
        shares = pending.atriskusdAmount;
        if (shares > shareLimit) shares = shareLimit;
        amountOut = previewRedeem(shares);
        if (amountOut > payoutCap) revert NoPositiveWithdrawalSlice(payoutCap);
    }

    function _requireNoPendingWithdrawal(address requester) private view {
        if (_pendingWithdrawals[requester].active) revert PendingWithdrawalExists();
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

    function _extendLockup(address receiver) private {
        uint256 newExpiry = block.timestamp + _lockupPeriod;
        if (newExpiry > _lockExpiry[receiver]) {
            _lockExpiry[receiver] = newExpiry;
            _syncAutoRenewDisabledTracking(receiver);
        }
    }

    function _requireFundedPayout(uint256 requested) private view {
        uint256 available = _legitimateAssets;
        if (requested > available) revert InsufficientFundedAssets(requested, available);
    }

    function totalAssets() public view override returns (uint256) {
        return _legitimateAssets;
    }

    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
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

    function _ensureWeeklyWithdrawalCapacity(uint256 assets) private {
        _requireWeeklyExitWindowCurrent();
        if (_weeklyWithdrawalWindowStartAssets == 0) {
            _weeklyWithdrawalWindowStartAssets = totalAssets();
        }
        uint256 remaining = _weeklyWithdrawalCapacityView();
        if (assets > remaining) revert WeeklyWithdrawalCapExceeded(assets, remaining);
    }

    function _ensureDirectWeeklyWithdrawalCapacity(uint256 assets) private {
        _ensureWeeklyWithdrawalCapacity(0);
        uint256 room = _weeklyWithdrawalCapacityView();
        uint256 directRoom = _directWeeklyWithdrawalRoom(room);
        if (assets > directRoom) revert WeeklyWithdrawalCapExceeded(assets, directRoom);
    }

    function _directWeeklyWithdrawalRoom(uint256 weeklyRoom) private view returns (uint256) {
        WeeklyExitCohort storage cohort = _weeklyExitCohorts[_weeklyWithdrawalWindowStart];
        uint256 queuedReserve = cohort.demandShares == 0 ? 0 : previewRedeem(cohort.demandShares);
        return AtRiskUSDWeeklyExitModule.directRoom(weeklyRoom, queuedReserve);
    }

    function _requireWeeklyExitWindowCurrent() private view {
        if (_weeklyExitWindowExpired()) {
            revert WeeklyExitSettlementRequired(_weeklyWithdrawalWindowStart + WEEKLY_WITHDRAWAL_WINDOW);
        }
    }

    function _weeklyExitWindowExpired() private view returns (bool) {
        return _weeklyWithdrawalWindowStart != 0
            && block.timestamp >= _weeklyWithdrawalWindowStart + WEEKLY_WITHDRAWAL_WINDOW;
    }

    function _weeklyWithdrawalCapacityView() private view returns (uint256) {
        if (_weeklyWithdrawalWindowStart == 0 || _weeklyExitWindowExpired()) return 0;
        uint256 basis = _weeklyWithdrawalWindowStartAssets;
        if (basis == 0) basis = totalAssets();
        uint256 cap = Math.mulDiv(basis, _effectiveWeeklyWithdrawalCapBps(), 10000);
        uint256 used = _weeklyWithdrawalUsed;
        return used >= cap ? 0 : cap - used;
    }

    function _settleWeeklyExitWindow() private {
        uint256 start = _weeklyWithdrawalWindowStart;
        uint256 closesAt = _weeklyExitWindowEnd(start);
        if (start == 0 || block.timestamp < closesAt) revert WeeklyExitWindowOpen(closesAt);
        WeeklyExitCohort storage cohort = _weeklyExitCohorts[start];
        if (cohort.settled) revert WeeklyExitAccountingInvariant(0, 1);
        uint256 demand = cohort.demandShares;
        uint256 roomShares;
        if ((cohort.activeRequests == 0) != (demand == 0)) {
            revert WeeklyExitAccountingInvariant(cohort.activeRequests, demand);
        }
        if (cohort.activeRequests != 0) {
            uint256 roomAssets = _weeklyWithdrawalRoomAtClose();
            roomShares = roomAssets == 0 || totalAssets() == 0 ? 0 : _sharesWithinAssetCap(roomAssets, demand);
            cohort.roomShares = roomShares;
            cohort.settled = true;
        }
        _advanceWeeklyExitWindow(start);
        emit WeeklyExitSettled(start, demand, roomShares);
    }

    function _weeklyWithdrawalRoomAtClose() private view returns (uint256) {
        uint256 basis = _weeklyWithdrawalWindowStartAssets;
        if (basis == 0) basis = totalAssets();
        uint256 cap = Math.mulDiv(basis, _effectiveWeeklyWithdrawalCapBps(), 10000);
        uint256 used = _weeklyWithdrawalUsed;
        return used >= cap ? 0 : cap - used;
    }

    function _weeklyExitWindowEnd(uint256 start) private pure returns (uint256) {
        if (start == 0 || start > type(uint256).max - WEEKLY_WITHDRAWAL_WINDOW) {
            revert WeeklyExitArithmeticOverflow();
        }
        return start + WEEKLY_WITHDRAWAL_WINDOW;
    }

    function _weeklyCohortStart(uint256 maturity) private view returns (uint256) {
        uint256 start = _weeklyWithdrawalWindowStart;
        if (maturity < start) revert WeeklyExitArithmeticOverflow();
        return start + (maturity - start) / WEEKLY_WITHDRAWAL_WINDOW * WEEKLY_WITHDRAWAL_WINDOW;
    }

    function _advanceWeeklyExitWindow(uint256 start) private {
        _weeklyWithdrawalWindowStart = _weeklyExitWindowEnd(start);
        _weeklyWithdrawalUsed = 0;
        _weeklyWithdrawalWindowStartAssets = 0;
    }

    function _sharesWithinAssetCap(uint256 cap, uint256 shareLimit) private view returns (uint256 shares) {
        uint256 assets = totalAssets();
        if (cap == 0 || assets == 0 || shareLimit == 0) return 0;
        if (cap >= assets) return shareLimit;
        uint256 supply = totalSupply();
        if (assets == type(uint256).max || supply > type(uint256).max - SHARE_SCALE) {
            revert WeeklyExitArithmeticOverflow();
        }
        shares = Math.mulDiv(cap + 1, supply + SHARE_SCALE, assets + 1, Math.Rounding.Ceil) - 1;
        if (shares > shareLimit) shares = shareLimit;
    }

    function _recordWeeklyExitRequest(uint256 cohortStart, uint256 shares) private {
        WeeklyExitCohort storage cohort = _weeklyExitCohorts[cohortStart];
        if (cohort.settled) revert WeeklyExitAccountingInvariant(0, 1);
        cohort.demandShares = _checkedWeeklyExitAdd(cohort.demandShares, shares);
        if (cohort.activeRequests == type(uint256).max) revert WeeklyExitArithmeticOverflow();
        cohort.activeRequests += 1;
    }

    function _clearWeeklyExitRequest(uint256 cohortStart, uint256 shares) private {
        WeeklyExitCohort storage cohort = _weeklyExitCohorts[cohortStart];
        uint256 active = cohort.activeRequests;
        if (active == 0) revert WeeklyExitAccountingInvariant(1, 0);
        if (!cohort.settled && block.timestamp < _weeklyExitWindowEnd(cohortStart)) {
            uint256 demand = cohort.demandShares;
            if (shares > demand) revert WeeklyExitAccountingInvariant(demand, shares);
            cohort.demandShares = demand - shares;
        }
        cohort.activeRequests = active - 1;
        if (active == 1) delete _weeklyExitCohorts[cohortStart];
    }

    function _checkedWeeklyExitAdd(uint256 current, uint256 amount) private pure returns (uint256) {
        if (amount > type(uint256).max - current) revert WeeklyExitArithmeticOverflow();
        return current + amount;
    }

    function _autoRenewDisabledEffectiveBalance(address account) private view returns (uint256) {
        PendingWithdrawal storage pending = _pendingWithdrawals[account];
        uint256 pendingShares = pending.active ? pending.atriskusdAmount : 0;
        return balanceOf(account) + pendingShares;
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
            if (oldExpiry != 0) _decrementAutoRenewDisabledExpiry(oldExpiry);
            _autoRenewDisabledTrackedExpiry[account] = expiry;
            _incrementAutoRenewDisabledExpiry(expiry);
        }
        _refreshEarliestAutoRenewDisabledExpiry();
    }

    function _untrackAutoRenewDisabled(address account) private {
        if (!_autoRenewDisabledTracked[account]) return;
        _autoRenewDisabledTracked[account] = false;
        uint256 oldExpiry = _autoRenewDisabledTrackedExpiry[account];
        _autoRenewDisabledTrackedExpiry[account] = 0;
        if (oldExpiry == 0) revert ExpiryHeapInvariant(oldExpiry);
        _decrementAutoRenewDisabledExpiry(oldExpiry);
        uint256 count = _autoRenewDisabledTrackedCount;
        if (count == 0) revert ExpiryHeapInvariant(oldExpiry);
        _autoRenewDisabledTrackedCount = count - 1;
        _refreshEarliestAutoRenewDisabledExpiry();
    }

    function _incrementAutoRenewDisabledExpiry(uint256 expiry) private {
        uint256 count = _autoRenewDisabledExpiryCounts[expiry];
        if (count == 0) {
            _autoRenewDisabledExpiryCounts[expiry] = 1;
            _insertAutoRenewDisabledExpiry(expiry);
            return;
        }
        _autoRenewDisabledExpiryCounts[expiry] = count + 1;
    }

    function _decrementAutoRenewDisabledExpiry(uint256 expiry) private {
        uint256 count = _autoRenewDisabledExpiryCounts[expiry];
        if (count == 0) revert ExpiryHeapInvariant(expiry);
        if (count == 1) {
            _autoRenewDisabledExpiryCounts[expiry] = 0;
            _removeAutoRenewDisabledExpiry(expiry);
            return;
        }
        _autoRenewDisabledExpiryCounts[expiry] = count - 1;
    }

    function _insertAutoRenewDisabledExpiry(uint256 expiry) private {
        if (_autoRenewDisabledExpiryHeapIndexPlusOne[expiry] != 0) revert ExpiryHeapInvariant(expiry);
        _autoRenewDisabledExpiryHeap.push(expiry);
        uint256 index = _autoRenewDisabledExpiryHeap.length - 1;
        while (index != 0) {
            uint256 parent = (index - 1) / 2;
            if (_autoRenewDisabledExpiryHeap[parent] <= expiry) break;
            uint256 moved = _autoRenewDisabledExpiryHeap[parent];
            _autoRenewDisabledExpiryHeap[index] = moved;
            _autoRenewDisabledExpiryHeapIndexPlusOne[moved] = index + 1;
            index = parent;
        }
        _autoRenewDisabledExpiryHeap[index] = expiry;
        _autoRenewDisabledExpiryHeapIndexPlusOne[expiry] = index + 1;
        _refreshEarliestAutoRenewDisabledExpiry();
    }

    function _removeAutoRenewDisabledExpiry(uint256 expiry) private {
        uint256 length = _autoRenewDisabledExpiryHeap.length;
        uint256 indexPlusOne = _autoRenewDisabledExpiryHeapIndexPlusOne[expiry];
        if (indexPlusOne == 0 || indexPlusOne > length) revert ExpiryHeapInvariant(expiry);
        uint256 index = indexPlusOne - 1;
        if (_autoRenewDisabledExpiryHeap[index] != expiry) revert ExpiryHeapInvariant(expiry);
        delete _autoRenewDisabledExpiryHeapIndexPlusOne[expiry];
        uint256 lastIndex = length - 1;
        if (index == lastIndex) {
            _autoRenewDisabledExpiryHeap.pop();
            _refreshEarliestAutoRenewDisabledExpiry();
            return;
        }
        uint256 tail = _autoRenewDisabledExpiryHeap[lastIndex];
        if (_autoRenewDisabledExpiryHeapIndexPlusOne[tail] != length) revert ExpiryHeapInvariant(tail);
        _autoRenewDisabledExpiryHeap.pop();
        if (index != 0 && _autoRenewDisabledExpiryHeap[(index - 1) / 2] > tail) {
            while (index != 0) {
                uint256 parent = (index - 1) / 2;
                uint256 moved = _autoRenewDisabledExpiryHeap[parent];
                if (moved <= tail) break;
                _autoRenewDisabledExpiryHeap[index] = moved;
                _autoRenewDisabledExpiryHeapIndexPlusOne[moved] = index + 1;
                index = parent;
            }
        } else {
            uint256 newLength = _autoRenewDisabledExpiryHeap.length;
            while (index < newLength / 2) {
                uint256 child = index * 2 + 1;
                uint256 right = child + 1;
                if (right < newLength && _autoRenewDisabledExpiryHeap[right] < _autoRenewDisabledExpiryHeap[child]) {
                    child = right;
                }
                uint256 moved = _autoRenewDisabledExpiryHeap[child];
                if (moved >= tail) break;
                _autoRenewDisabledExpiryHeap[index] = moved;
                _autoRenewDisabledExpiryHeapIndexPlusOne[moved] = index + 1;
                index = child;
            }
        }
        _autoRenewDisabledExpiryHeap[index] = tail;
        _autoRenewDisabledExpiryHeapIndexPlusOne[tail] = index + 1;
        _refreshEarliestAutoRenewDisabledExpiry();
    }

    function _refreshEarliestAutoRenewDisabledExpiry() private {
        uint256 length = _autoRenewDisabledExpiryHeap.length;
        if (length == 0) {
            _earliestAutoRenewDisabledExpiry = 0;
            return;
        }
        uint256 earliest = _autoRenewDisabledExpiryHeap[0];
        if (_autoRenewDisabledExpiryHeapIndexPlusOne[earliest] != 1 || _autoRenewDisabledExpiryCounts[earliest] == 0) {
            revert ExpiryHeapInvariant(earliest);
        }
        _earliestAutoRenewDisabledExpiry = earliest;
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
        if (lossPendingValue > 1) revert MalformedLossPendingReturn(vault, lossPendingValue);
        return false;
    }

    function _requireNoLossPending() private view {
        (bool ok1, bytes memory data1) = _yieldSource.staticcall(abi.encodeWithSignature("riskusdVault()"));
        require(ok1 && data1.length >= 32, "lossPending check: yieldSource unreachable");
        address vault = abi.decode(data1, (address));
        (bool ok2, bytes memory data2) = vault.staticcall(abi.encodeWithSignature("lossPending()"));
        require(ok2 && data2.length >= 32, "lossPending check: vault unreachable");
        if (abi.decode(data2, (bool))) revert LossPending();
        if (_custodianSettlementPending(vault)) revert CustodianSettlementPending();
    }

    function _custodianSettlementPending(address vault) private view returns (bool) {
        (bool ok, bytes memory data) = vault.staticcall(abi.encodeWithSignature("custodian()"));
        if (!ok || data.length < 32) revert CustodianGetterUnavailable(vault);
        uint256 rawCustodian;
        assembly {
            rawCustodian := mload(add(data, 32))
        }
        if (rawCustodian > type(uint160).max) revert CustodianGetterUnavailable(vault);
        address custodian = address(uint160(rawCustodian));
        if (custodian == address(0) || custodian.code.length == 0) return false;
        (ok, data) = custodian.staticcall(abi.encodeWithSignature("tierShareActionsPaused()"));
        if (!ok || data.length < 32) revert CustodianSettlementHookFailed(custodian);
        return abi.decode(data, (bool));
    }

    function _requireNotBlocked(address account) private view {
        address blocklist_ = _blocklist;
        if (blocklist_ != address(0) && IBlocklist(blocklist_).isBlocked(account)) {
            revert BlockedAddress(account);
        }
    }

    function _update(address from, address to, uint256 value) internal override {
        _updateWithLossCheck(from, to, value, true);
    }

    function _updateWithLossCheck(address from, address to, uint256 value, bool checkLossPending) private {
        if (from != address(0) && to != address(0) && value > 0) {
            if (checkLossPending) _requireNoLossPending();
            if (from != _stakingQueue && from != address(this)) {
                uint256 lockExpiry = _lockExpiry[from];
                if (block.timestamp < lockExpiry) revert LockupNotExpired(lockExpiry);
                if (
                    _lockupPeriod > 0 && to != address(this) && _autoRenewDisabled[from]
                        && block.timestamp >= lockExpiry
                ) {
                    revert ExpiredAutoRenewDisabledLockup();
                }
            }
        }
        if (from != address(0)) _requireNotBlocked(from);
        if (to != address(0)) _requireNotBlocked(to);
        _delegateProfitModule(abi.encodeCall(AtRiskUSDProfitModule.update, (from, to)));
        super._update(from, to, value);
        if (
            value != 0 && from != address(0) && from != address(this) && to != address(0) && to != address(this)
                && from != to
        ) {
            uint256 senderExpiry = _lockExpiry[from];
            if (senderExpiry > _lockExpiry[to]) {
                _lockExpiry[to] = senderExpiry;
                emit LockupTransferred(from, to, senderExpiry);
            }
        }
        if (from != address(0)) _syncAutoRenewDisabledTracking(from);
        if (to != address(0) && to != from) _syncAutoRenewDisabledTracking(to);
    }

    function _checkpointProfitAccount(address account) private {
        _delegateProfitModule(abi.encodeCall(AtRiskUSDProfitModule.update, (account, account)));
    }

    function _delegateProfitModule(bytes memory callData) private {
        (bool success, bytes memory data) = address(_PROFIT_MODULE).delegatecall(callData);
        if (!success) {
            assembly {
                revert(add(data, 32), mload(data))
            }
        }
    }

    function _delegateProfitModuleUint(bytes memory callData) private returns (uint256 result) {
        (bool success, bytes memory data) = address(_PROFIT_MODULE).delegatecall(callData);
        if (!success) {
            assembly {
                revert(add(data, 32), mload(data))
            }
        }
        if (data.length != 32) revert DirectCallForbidden();
        result = abi.decode(data, (uint256));
    }

    function approve(address spender, uint256 value)
        public
        override(ERC20Upgradeable, IERC20)
        onlyDelegateCall
        returns (bool)
    {
        return super.approve(spender, value);
    }

    function transfer(address to, uint256 value)
        public
        override(ERC20Upgradeable, IERC20)
        onlyDelegateCall
        returns (bool)
    {
        return super.transfer(to, value);
    }

    function transferFrom(address from, address to, uint256 value)
        public
        override(ERC20Upgradeable, IERC20)
        onlyDelegateCall
        returns (bool)
    {
        return super.transferFrom(from, to, value);
    }
}
