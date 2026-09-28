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
import "../interfaces/IVaultRegistry.sol";
import {
    IUSDCTreasuryCallerEligibility,
    IUSDCTreasuryYieldClaims,
    IYieldSourceBridgeRoute
} from "../interfaces/IUSDCTreasuryYieldClaims.sol";

interface IYieldSourceFundingPolicy {
    function allowlist() external view returns (address);
    function blocklist() external view returns (address);
}

interface IYieldSourceFundingOwner {
    function owner() external view returns (address);
}

interface IYieldSourceFundingLossReporter {
    function lossReporter() external view returns (address);
}

library AtRiskUSDStateModuleStorage {
    struct PendingWithdrawalWords {
        uint256 shares;
        uint256 assetSnapshot;
        uint256 requestTimestamp;
        uint256 word3;
        uint256 word4;
        uint256 word5;
        uint256 word6;
    }

    enum PendingWithdrawalLayoutKind {
        Empty,
        Current,
        CooldownFirst,
        Ambiguous
    }

    function loadPendingWithdrawalWords(address requester, uint256 mappingSlot)
        internal
        view
        returns (PendingWithdrawalWords memory words)
    {
        bytes32 base = pendingWithdrawalStorageBase(requester, mappingSlot);
        assembly {
            mstore(words, sload(base))
            mstore(add(words, 32), sload(add(base, 1)))
            mstore(add(words, 64), sload(add(base, 2)))
            mstore(add(words, 96), sload(add(base, 3)))
            mstore(add(words, 128), sload(add(base, 4)))
            mstore(add(words, 160), sload(add(base, 5)))
            mstore(add(words, 192), sload(add(base, 6)))
        }
    }

    function pendingWithdrawalLayoutKind(PendingWithdrawalWords memory words)
        internal
        pure
        returns (PendingWithdrawalLayoutKind)
    {
        if (
            words.shares == 0 && words.assetSnapshot == 0 && words.requestTimestamp == 0 && words.word3 == 0
                && words.word4 == 0 && words.word5 == 0 && words.word6 == 0
        ) return PendingWithdrawalLayoutKind.Empty;

        bool reservationsPaired = (words.word5 == 0) == (words.word6 == 0);
        if (words.word3 == 1 && reservationsPaired) {
            if (words.word4 == 1 && words.word5 == 0) return PendingWithdrawalLayoutKind.Ambiguous;
            return PendingWithdrawalLayoutKind.Current;
        }
        if (words.word4 == 1 && words.word3 != 1 && words.shares != 0 && words.word5 == 0 && words.word6 == 0) {
            return PendingWithdrawalLayoutKind.CooldownFirst;
        }
        return PendingWithdrawalLayoutKind.Ambiguous;
    }

    function pendingWithdrawalStorageBase(address requester, uint256 mappingSlot) internal pure returns (bytes32) {
        return keccak256(abi.encode(requester, mappingSlot));
    }
}

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

    error AmbiguousPendingWithdrawalLayout(address requester);
    error BlockedAddress(address account);
    error CustodianSettlementHookFailed(address custodian);
    error CustodianSettlementPending();
    error DirectCallForbidden();
    error ExpiredAutoRenewDisabledLockup();
    error ExchangeRateDecreased(uint256 beforeAssets, uint256 afterAssets);
    error LockupNotExpired(uint256 lockExpiry);
    error LossPending();
    error NoPendingWithdrawal();
    error PendingWithdrawalMigrationAlreadyConfirmed(address requester);
    error PendingWithdrawalMigrationRequired(address requester);
    error PendingWithdrawalShareRecoveryNotNeeded(address requester);
    error PendingWithdrawalShareRecoveryUnavailable(address requester, uint256 shares, uint256 escrowed);
    error UnsupportedPendingWithdrawalLayout(uint8 sourceLayout);
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
    error ZeroSupplyYield();
    error ExpiryHeapInvariant(uint256 expiry);
    error SlippageExceeded(uint256 amountOut, uint256 minAmountOut);
    error CooldownNotElapsed(uint256 unlockTime);
    error ZeroRedemptionOutput();
    error ZeroAddress();

    event ExchangeRateInvariantFailure(uint256 beforeAssets, uint256 afterAssets);
    event YieldAccrued(uint256 riskusdAmount);
    event LossAbsorbed(uint256 riskusdAmount);
    event PendingWithdrawalLayoutMigrated(address indexed requester, uint256 cooldownPeriod);
    event PendingWithdrawalSharesRecovered(address indexed requester, uint256 shares);
    event YieldSourceUpdated(address indexed oldSource, address indexed newSource);
    event StakingQueueUpdated(address indexed oldQueue, address indexed newQueue);
    event ForageGovernorSet(address indexed oldGovernor, address indexed newGovernor);
    event WithdrawalRequested(
        address indexed requester, uint256 atriskusdAmount, uint256 riskusdAmount, uint256 cooldownEnd
    );
    event WithdrawalExecuted(address indexed requester, uint256 riskusdAmount);
    event WithdrawalCancelled(address indexed requester, uint256 atriskusdAmount);
    event WorthlessSharesBurned(address indexed holder, uint256 shares);

    struct PendingWithdrawal {
        uint256 atriskusdAmount;
        uint256 riskusdAmount;
        uint256 requestTimestamp;
        bool active;
        uint256 cooldownPeriod;
        uint256 weeklyCapWindowStart;
        uint256 weeklyCapReservedAssets;
    }

    struct WithdrawalExecution {
        uint256 sharesToBurn;
        uint256 riskusdToTransfer;
        uint256 capWindowStart;
        uint256 capReservedAssets;
        bool hasReservation;
        bool staleReservedWindow;
        uint256 backingPerShareBefore;
    }

    struct WithdrawalCancellation {
        address beneficiary;
        uint256 shares;
        uint256 capWindowStart;
        uint256 capReservedAssets;
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
    uint256[29] private __gap;

    uint256 internal constant WEEKLY_WITHDRAWAL_WINDOW = 7 days;
    uint256 internal constant DEFAULT_WEEKLY_WITHDRAWAL_CAP_BPS = 500;
    uint256 internal constant RAY = 1e27;
    uint256 internal constant SHARE_SCALE = 1e6;

    address private immutable _SELF;

    constructor() {
        _SELF = address(this);
        _disableInitializers();
    }

    modifier onlyDelegateCall() {
        if (address(this) == _SELF) revert DirectCallForbidden();
        _;
    }

    function _authorizeUpgrade(address) internal view override onlyOwner {}

    function migratePendingWithdrawalLayout(address requester, uint8 sourceLayout) external onlyDelegateCall {
        if (requester == address(0)) revert ZeroAddress();
        PendingWithdrawalMigrationState migrationState = _pendingWithdrawalMigrationState[requester];
        if (
            migrationState == PendingWithdrawalMigrationState.SharesRecovering
                || migrationState == PendingWithdrawalMigrationState.Confirmed
        ) revert PendingWithdrawalMigrationAlreadyConfirmed(requester);

        uint256 mappingSlot;
        assembly {
            mappingSlot := _pendingWithdrawals.slot
        }
        AtRiskUSDStateModuleStorage.PendingWithdrawalWords memory words =
            AtRiskUSDStateModuleStorage.loadPendingWithdrawalWords(requester, mappingSlot);
        AtRiskUSDStateModuleStorage.PendingWithdrawalLayoutKind kind =
            AtRiskUSDStateModuleStorage.pendingWithdrawalLayoutKind(words);
        if (sourceLayout == uint8(PendingWithdrawalLayout.ShareOnlyRecovery)) {
            _recoverUnclassifiedPendingWithdrawalShares(requester, words, kind);
            return;
        }
        if (words.shares == 0) revert AmbiguousPendingWithdrawalLayout(requester);

        uint256 cooldown;
        if (sourceLayout == uint8(PendingWithdrawalLayout.CooldownFirst)) {
            if (words.word3 == 1 || words.word4 != 1 || words.word5 != 0 || words.word6 != 0) {
                revert AmbiguousPendingWithdrawalLayout(requester);
            }
            cooldown = words.word3;
            bytes32 base = AtRiskUSDStateModuleStorage.pendingWithdrawalStorageBase(requester, mappingSlot);
            assembly {
                sstore(add(base, 3), 1)
                sstore(add(base, 4), cooldown)
                sstore(add(base, 5), 0)
                sstore(add(base, 6), 0)
            }
        } else if (sourceLayout == uint8(PendingWithdrawalLayout.ActiveFirst)) {
            if (words.word3 != 1 || (words.word5 == 0) != (words.word6 == 0)) {
                revert AmbiguousPendingWithdrawalLayout(requester);
            }
            cooldown = words.word4;
        } else {
            revert UnsupportedPendingWithdrawalLayout(sourceLayout);
        }

        _pendingWithdrawalMigrationState[requester] = PendingWithdrawalMigrationState.Confirmed;
        emit PendingWithdrawalLayoutMigrated(requester, cooldown);
    }

    function setAutoRenewDisabled(address account, bool disabled) external onlyDelegateCall {
        _autoRenewDisabled[account] = disabled;
        _syncAutoRenewDisabledTracking(account);
    }

    function setLockExpiry(address depositor, uint256 newExpiry) external onlyDelegateCall {
        _lockExpiry[depositor] = newExpiry;
        _syncAutoRenewDisabledTracking(depositor);
    }

    function extendLockup(address receiver) external onlyDelegateCall {
        uint256 newExpiry = block.timestamp + _lockupPeriod;
        if (newExpiry > _lockExpiry[receiver]) {
            _lockExpiry[receiver] = newExpiry;
            _syncAutoRenewDisabledTracking(receiver);
        }
    }

    function applyPendingYieldSource() external onlyDelegateCall {
        address old = _yieldSource;
        _validateYieldSourceHandoff(old, _pendingYieldSource);
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
        uint256 supply = totalSupply();
        if (supply == 0) revert ZeroSupplyYield();
        uint256 assetsBefore = supply == 0 ? 0 : convertToAssets(supply);

        IERC20(asset()).safeTransferFrom(msg.sender, address(this), riskusdAmount);

        _legitimateAssets += riskusdAmount;
        _totalYieldAccrued += riskusdAmount;
        _notifyVaultRegistryAssetsChanged();

        uint256 assetsAfter = supply == 0 ? 0 : convertToAssets(supply);
        if (assetsAfter < assetsBefore) {
            emit ExchangeRateInvariantFailure(assetsBefore, assetsAfter);
            revert ExchangeRateDecreased(assetsBefore, assetsAfter);
        }

        emit YieldAccrued(riskusdAmount);
    }

    function deposit(uint256 assets, address receiver) public override onlyDelegateCall returns (uint256 shares) {
        uint256 backingPerShareBefore = _backingPerShareRay();
        shares = super.deposit(assets, receiver);
        _assertBackingPerShareNotDecreased(backingPerShareBefore);
    }

    function mint(uint256 shares, address receiver) public override onlyDelegateCall returns (uint256 assets) {
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
        uint256 backingPerShareBefore = _backingPerShareRay();
        shares = previewWithdraw(assets);
        _requireFundedPayout(assets);
        _requireNoFinalClaimBurn(shares);
        _ensureWeeklyWithdrawalCapacity(assets);
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
        uint256 backingPerShareBefore = _backingPerShareRay();
        assets = previewRedeem(shares);
        if (assets == 0) revert ZeroRedemptionOutput();
        _requireFundedPayout(assets);
        _requireNoFinalClaimBurn(shares);
        _ensureWeeklyWithdrawalCapacity(assets);
        assets = super.redeem(shares, receiver, owner_);
        _weeklyWithdrawalUsed += assets;
        _assertBackingPerShareNotDecreased(backingPerShareBefore);
    }

    function redeemForUpgrade(address depositor, uint256 shares) external onlyDelegateCall returns (uint256 assets) {
        uint256 backingPerShareBefore = _backingPerShareRay();
        assets = previewRedeem(shares);
        if (assets == 0) revert ZeroRedemptionOutput();
        _requireFundedPayout(assets);
        _requireNoFinalClaimBurn(shares);
        _enforceWeeklyWithdrawalCap(assets);
        _burn(depositor, shares);
        IERC20(asset()).safeTransfer(msg.sender, assets);
        emit Withdraw(msg.sender, msg.sender, depositor, assets, shares);
        _decreaseLegitimateAssets(assets);
        _assertBackingPerShareNotDecreased(backingPerShareBefore);
    }

    function redeemForReversion(address depositor, uint256 shares) external onlyDelegateCall returns (uint256 assets) {
        uint256 backingPerShareBefore = _backingPerShareRay();
        assets = previewRedeem(shares);
        if (assets == 0) revert ZeroRedemptionOutput();
        _requireFundedPayout(assets);
        _requireNoFinalClaimBurn(shares);
        _enforceWeeklyWithdrawalCap(assets);
        _burn(depositor, shares);
        IERC20(asset()).safeTransfer(msg.sender, assets);
        emit Withdraw(msg.sender, msg.sender, depositor, assets, shares);
        _decreaseLegitimateAssets(assets);
        _assertBackingPerShareNotDecreased(backingPerShareBefore);
    }

    function executeWithdrawal(uint256 minAmountOut) external onlyDelegateCall {
        _requirePendingWithdrawalLayoutReady(msg.sender);
        PendingWithdrawal storage pending = _pendingWithdrawals[msg.sender];
        if (!pending.active) revert NoPendingWithdrawal();
        _requireNoLossPending();
        uint256 cooldownEnd = pending.requestTimestamp + pending.cooldownPeriod;
        if (block.timestamp < cooldownEnd) revert CooldownNotElapsed(cooldownEnd);
        _requireNotBlocked(msg.sender);

        uint256 sharesToBurn = pending.atriskusdAmount;
        uint256 amountOut = previewRedeem(sharesToBurn);
        if (amountOut > pending.riskusdAmount) {
            sharesToBurn = _sharesWithinWithdrawalCap(pending.riskusdAmount, sharesToBurn);
            amountOut = previewRedeem(sharesToBurn);
            if (sharesToBurn == 0 || amountOut == 0) {
                revert NoPositiveWithdrawalSlice(pending.riskusdAmount);
            }
        }
        if (amountOut == 0) revert ZeroRedemptionOutput();
        _requireFundedPayout(amountOut);
        _requireNoFinalClaimBurn(sharesToBurn);
        if (amountOut < minAmountOut) revert SlippageExceeded(amountOut, minAmountOut);

        uint256 capWindowStart = pending.weeklyCapWindowStart;
        uint256 capReservedAssets = pending.weeklyCapReservedAssets;
        bool hasReservation = capWindowStart != 0 && capReservedAssets != 0;
        bool staleReservedWindow = hasReservation && _refreshPendingWithdrawalWindow(capWindowStart);
        if (!hasReservation || staleReservedWindow) {
            _enforceWeeklyWithdrawalCap(amountOut);
        } else if (capReservedAssets < amountOut) {
            _enforceWeeklyWithdrawalCap(amountOut - capReservedAssets);
        }

        WithdrawalExecution memory execution = WithdrawalExecution({
            sharesToBurn: sharesToBurn,
            riskusdToTransfer: amountOut,
            capWindowStart: capWindowStart,
            capReservedAssets: capReservedAssets,
            hasReservation: hasReservation,
            staleReservedWindow: staleReservedWindow,
            backingPerShareBefore: _backingPerShareRay()
        });
        _finishWithdrawal(execution);
    }

    function _validateYieldSourceHandoff(address current, address successor) private view {
        IUSDCTreasuryYieldClaims currentClaims = _readyYieldClaims(current);
        uint256 currentClaim = _readYieldClaim(currentClaims, current);
        if (currentClaim != 0) revert YieldSourceClaimOutstanding(current, currentClaim);
        IUSDCTreasuryYieldClaims successorClaims = _readyYieldClaims(successor);
        uint256 successorClaim = _readYieldClaim(successorClaims, successor);
        if (successorClaim != 0) revert YieldSourceClaimOutstanding(successor, successorClaim);
        (address currentVault, address currentRegistry) = _readYieldWiring(currentClaims, current);
        (address nextVault, address nextRegistry) = _readYieldWiring(successorClaims, successor);
        if (nextVault != currentVault || nextRegistry != currentRegistry) {
            revert YieldSourceWiringMismatch(successor);
        }
        address attestor = _readPnLAttestor(successorClaims, successor);
        IAllowlist callerAllowlist = _readTreasuryAllowlist(successor, attestor);
        _requireTreasuryCallerAllowed(callerAllowlist, successor, attestor);
        _requireYieldSourceReturnRoute(currentClaims, current, successorClaims, successor, callerAllowlist);
        _requireYieldSourceFundingEligibility(successor, nextVault, callerAllowlist);
    }

    function _requireTreasuryCallerAllowed(IAllowlist callerAllowlist, address source, address caller) private view {
        bool allowed;
        try callerAllowlist.isAllowed(caller) returns (bool value) {
            allowed = value;
        } catch {
            revert YieldSourceCallerNotEligible(source, caller);
        }
        if (!allowed) revert YieldSourceCallerNotEligible(source, caller);
    }

    function _readPnLAttestor(IUSDCTreasuryYieldClaims claims, address source)
        private
        view
        returns (address attestor)
    {
        try claims.pnlAttestor() returns (address value) {
            attestor = value;
        } catch {
            revert YieldSourceAttestorUnavailable(source, address(0));
        }
        if (attestor == address(0)) revert YieldSourceAttestorUnavailable(source, attestor);
    }

    function _readTreasuryAllowlist(address source, address attestor)
        private
        view
        returns (IAllowlist callerAllowlist)
    {
        address allowlistAddress;
        try IUSDCTreasuryCallerEligibility(source).allowlist() returns (address value) {
            allowlistAddress = value;
        } catch {
            revert YieldSourceCallerNotEligible(source, attestor);
        }
        if (allowlistAddress.code.length == 0) revert YieldSourceCallerNotEligible(source, attestor);
        callerAllowlist = IAllowlist(allowlistAddress);
    }

    function _requireYieldSourceReturnRoute(
        IUSDCTreasuryYieldClaims currentClaims,
        address current,
        IUSDCTreasuryYieldClaims successorClaims,
        address successor,
        IAllowlist callerAllowlist
    ) private view {
        address currentBridge = _readYieldSourceBridge(currentClaims, current);
        address successorBridge = _readYieldSourceBridge(successorClaims, successor);
        if (currentBridge != successorBridge) revert YieldSourceWiringMismatch(successor);
        _requireTreasuryCallerAllowed(callerAllowlist, successor, successorBridge);
        address treasury = _readBridgeTreasury(successor, currentBridge);
        if (treasury != successor) {
            revert YieldSourceBridgeRouteMismatch(successor, currentBridge, successor, treasury);
        }
        _requireFundingCallerUnblocked(currentBridge, successor, successor, true);
    }

    function _requireYieldSourceFundingEligibility(address source, address centralVault, IAllowlist treasuryAllowlist)
        private
        view
    {
        address treasuryOwner = _readYieldSourceOwner(source);
        _requireTreasuryCallerAllowed(treasuryAllowlist, source, treasuryOwner);
        _requireFundingCallerUnblocked(source, source, centralVault, true);
        _requireFundingCallerAllowed(centralVault, source, source);
        _requireYieldSourceLossReporter(source, centralVault);
        _requireFundingCallerUnblocked(centralVault, source, source, false);
        _requireFundingCallerAllowed(address(this), source, source);
        _requireFundingCallerUnblocked(address(this), source, source, false);
    }

    function _requireFundingCallerAllowed(address policy, address source, address caller) private view {
        address allowlistAddress;
        try IYieldSourceFundingPolicy(policy).allowlist() returns (address value) {
            allowlistAddress = value;
        } catch {
            revert YieldSourceCallerNotEligible(source, caller);
        }
        if (allowlistAddress.code.length == 0) revert YieldSourceCallerNotEligible(source, caller);
        _requireTreasuryCallerAllowed(IAllowlist(allowlistAddress), source, caller);
    }

    function _requireFundingCallerUnblocked(address policy, address source, address account, bool required)
        private
        view
    {
        address blocklist = _readYieldSourceBlocklist(policy, source, account, required);
        if (blocklist == address(0)) return;
        if (blocklist.code.length == 0) revert YieldSourceCallerNotEligible(source, account);
        bool blocked;
        try IBlocklist(blocklist).isBlocked(account) returns (bool value) {
            blocked = value;
        } catch {
            revert YieldSourceCallerNotEligible(source, account);
        }
        if (blocked) revert YieldSourceCallerNotEligible(source, account);
    }

    function _readYieldSourceBlocklist(address policy, address source, address account, bool required)
        private
        view
        returns (address blocklist)
    {
        try IYieldSourceFundingPolicy(policy).blocklist() returns (address value) {
            blocklist = value;
        } catch {
            revert YieldSourceCallerNotEligible(source, account);
        }
        if (required && blocklist == address(0)) revert YieldSourceCallerNotEligible(source, account);
    }

    function _readYieldSourceOwner(address source) private view returns (address treasuryOwner) {
        try IYieldSourceFundingOwner(source).owner() returns (address value) {
            treasuryOwner = value;
        } catch {
            revert YieldSourceCallerNotEligible(source, address(0));
        }
        if (treasuryOwner == address(0)) revert YieldSourceCallerNotEligible(source, treasuryOwner);
    }

    function _requireYieldSourceLossReporter(address source, address centralVault) private view {
        address reporter;
        try IYieldSourceFundingLossReporter(centralVault).lossReporter() returns (address value) {
            reporter = value;
        } catch {
            revert YieldSourceCallerNotEligible(source, address(0));
        }
        if (reporter != source) revert YieldSourceCallerNotEligible(source, reporter);
    }

    function _readYieldSourceBridge(IUSDCTreasuryYieldClaims claims, address source)
        private
        view
        returns (address bridge)
    {
        try claims.hlTradingBridge() returns (address value) {
            bridge = value;
        } catch {
            revert YieldSourceBridgeUnavailable(source, address(0));
        }
        if (bridge.code.length == 0) revert YieldSourceBridgeUnavailable(source, bridge);
    }

    function _readBridgeTreasury(address source, address bridge) private view returns (address treasury) {
        try IYieldSourceBridgeRoute(bridge).usdcTreasury() returns (address value) {
            treasury = value;
        } catch {
            revert YieldSourceBridgeUnavailable(source, bridge);
        }
    }

    function _readyYieldClaims(address source) private view returns (IUSDCTreasuryYieldClaims claims) {
        if (source.code.length == 0) revert YieldClaimsUnavailable(source);
        claims = IUSDCTreasuryYieldClaims(source);
        bool ready;
        try claims.yieldClaimsReady() returns (bool value) {
            ready = value;
        } catch {
            revert YieldClaimsUnavailable(source);
        }
        if (!ready) revert YieldClaimsNotReady(source);
    }

    function _readYieldClaim(IUSDCTreasuryYieldClaims claims, address source) private view returns (uint256 claim) {
        try claims.unfundedYieldClaim(address(this)) returns (uint256 value) {
            claim = value;
        } catch {
            revert YieldClaimsUnavailable(source);
        }
    }

    function _readYieldWiring(IUSDCTreasuryYieldClaims claims, address source)
        private
        view
        returns (address centralVault, address registry)
    {
        try claims.riskusdVault() returns (address value) {
            centralVault = value;
        } catch {
            revert YieldSourceWiringMismatch(source);
        }
        try claims.vaultRegistry() returns (address value) {
            registry = value;
        } catch {
            revert YieldSourceWiringMismatch(source);
        }
        if (centralVault.code.length == 0 || registry.code.length == 0) {
            revert YieldSourceWiringMismatch(source);
        }
    }

    function absorbLoss(uint256 riskusdAmount) external onlyDelegateCall {
        IERC20(asset()).safeTransfer(msg.sender, riskusdAmount);

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

    function requestWithdrawal(uint256 atriskusdAmount, uint256 riskusdAmount, uint256 backingPerShareBefore)
        external
        onlyDelegateCall
    {
        _enforceWeeklyWithdrawalCap(riskusdAmount);
        uint256 capWindowStart = _weeklyWithdrawalWindowStart;

        _pendingWithdrawals[msg.sender] = PendingWithdrawal({
            atriskusdAmount: atriskusdAmount,
            riskusdAmount: riskusdAmount,
            requestTimestamp: block.timestamp,
            active: true,
            cooldownPeriod: _cooldownPeriod,
            weeklyCapWindowStart: capWindowStart,
            weeklyCapReservedAssets: riskusdAmount
        });
        _pendingWithdrawalMigrationState[msg.sender] = PendingWithdrawalMigrationState.Confirmed;

        _transfer(msg.sender, address(this), atriskusdAmount);

        emit WithdrawalRequested(msg.sender, atriskusdAmount, riskusdAmount, block.timestamp + _cooldownPeriod);
        _assertBackingPerShareNotDecreased(backingPerShareBefore);
    }

    function finishWithdrawal(WithdrawalExecution calldata execution) external onlyDelegateCall {
        _finishWithdrawal(execution);
    }

    function _finishWithdrawal(WithdrawalExecution memory execution) private {
        PendingWithdrawal storage pending = _pendingWithdrawals[msg.sender];
        uint256 remainingShares = pending.atriskusdAmount - execution.sharesToBurn;
        uint256 remainingCap = pending.riskusdAmount - execution.riskusdToTransfer;
        if (remainingShares == 0) {
            delete _pendingWithdrawals[msg.sender];
            delete _pendingWithdrawalMigrationState[msg.sender];
            if (
                execution.hasReservation && !execution.staleReservedWindow
                    && execution.capReservedAssets > execution.riskusdToTransfer
            ) {
                _refundWeeklyWithdrawalCap(
                    execution.capWindowStart, execution.capReservedAssets - execution.riskusdToTransfer
                );
            }
        } else {
            pending.atriskusdAmount = remainingShares;
            pending.riskusdAmount = remainingCap;
            if (execution.staleReservedWindow || !execution.hasReservation) {
                pending.weeklyCapWindowStart = 0;
                pending.weeklyCapReservedAssets = 0;
            } else {
                uint256 reserved = execution.capReservedAssets;
                pending.weeklyCapReservedAssets =
                    reserved > execution.riskusdToTransfer ? reserved - execution.riskusdToTransfer : 0;
                if (pending.weeklyCapReservedAssets == 0) pending.weeklyCapWindowStart = 0;
            }
        }

        _burn(address(this), execution.sharesToBurn);
        _syncAutoRenewDisabledTracking(msg.sender);
        _decreaseLegitimateAssets(execution.riskusdToTransfer);
        _assertBackingPerShareNotDecreased(execution.backingPerShareBefore);
        IERC20(asset()).safeTransfer(msg.sender, execution.riskusdToTransfer);
        emit WithdrawalExecuted(msg.sender, execution.riskusdToTransfer);
    }

    function finishPendingWithdrawalCancellation(WithdrawalCancellation calldata cancellation)
        external
        onlyDelegateCall
    {
        delete _pendingWithdrawals[cancellation.beneficiary];
        delete _pendingWithdrawalMigrationState[cancellation.beneficiary];
        _refundWeeklyWithdrawalCap(cancellation.capWindowStart, cancellation.capReservedAssets);
        _transfer(address(this), cancellation.beneficiary, cancellation.shares);
        emit WithdrawalCancelled(cancellation.beneficiary, cancellation.shares);
    }

    function burnWorthlessShares(uint256 shares) external onlyDelegateCall {
        _burn(msg.sender, shares);
        emit WorthlessSharesBurned(msg.sender, shares);
    }

    function update(address from, address to, uint256 value) external onlyDelegateCall {
        _update(from, to, value);
    }

    function classifyPendingWithdrawalLayout(AtRiskUSDStateModuleStorage.PendingWithdrawalWords calldata words)
        external
        pure
        returns (AtRiskUSDStateModuleStorage.PendingWithdrawalLayoutKind)
    {
        return AtRiskUSDStateModuleStorage.pendingWithdrawalLayoutKind(words);
    }

    function syncAutoRenewDisabledTracking(address account) external onlyDelegateCall {
        _syncAutoRenewDisabledTracking(account);
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
        pure
        returns (AtRiskUSDStateModuleStorage.PendingWithdrawalLayoutKind)
    {
        return AtRiskUSDStateModuleStorage.pendingWithdrawalLayoutKind(words);
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

    function _sharesWithinWithdrawalCap(uint256 cap, uint256 shareLimit) private view returns (uint256 shares) {
        uint256 assets = totalAssets();
        if (cap >= assets) return shareLimit;
        uint256 numerator = totalSupply() + SHARE_SCALE;
        uint256 denominator = assets + 1;
        shares = Math.mulDiv(cap + 1, numerator, denominator, Math.Rounding.Ceil) - 1;
        if (shares > shareLimit) shares = shareLimit;
    }

    function _requireFundedPayout(uint256 requested) private view {
        uint256 available = _legitimateAssets;
        if (requested > available) revert InsufficientFundedAssets(requested, available);
    }

    function _requireNoFinalClaimBurn(uint256 shares) private view {
        if (shares != totalSupply()) return;
        uint256 claim = _unfundedYieldClaim();
        if (claim != 0) revert FinalClaimBurn(claim);
    }

    function _unfundedYieldClaim() private view returns (uint256 claim) {
        address source = _yieldSource;
        if (source.code.length == 0) revert YieldClaimsUnavailable(source);
        IUSDCTreasuryYieldClaims claims = _readyYieldClaims(source);
        try claims.unfundedYieldClaim(address(this)) returns (uint256 value) {
            claim = value;
        } catch {
            revert YieldClaimsUnavailable(source);
        }
    }

    function totalAssets() public view override returns (uint256) {
        uint256 claim = _unfundedYieldClaim();
        if (claim >= type(uint256).max - _legitimateAssets) {
            revert YieldAssetValueOverflow(_legitimateAssets, claim);
        }
        return _legitimateAssets + claim;
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

    function _refundWeeklyWithdrawalCap(uint256 windowStart, uint256 assets) private {
        if (assets == 0 || windowStart == 0 || _weeklyWithdrawalWindowStart != windowStart) return;
        uint256 used = _weeklyWithdrawalUsed;
        _weeklyWithdrawalUsed = assets >= used ? 0 : used - assets;
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

    function _autoRenewDisabledEffectiveBalance(address account) private view returns (uint256) {
        if (_pendingWithdrawalMigrationState[account] == PendingWithdrawalMigrationState.SharesRecovering) {
            return balanceOf(account);
        }
        _requirePendingWithdrawalLayoutReady(account);
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

    function _recoverUnclassifiedPendingWithdrawalShares(
        address requester,
        AtRiskUSDStateModuleStorage.PendingWithdrawalWords memory words,
        AtRiskUSDStateModuleStorage.PendingWithdrawalLayoutKind kind
    ) private {
        if (kind == AtRiskUSDStateModuleStorage.PendingWithdrawalLayoutKind.Empty) revert NoPendingWithdrawal();
        if (kind == AtRiskUSDStateModuleStorage.PendingWithdrawalLayoutKind.Current) {
            revert PendingWithdrawalShareRecoveryNotNeeded(requester);
        }
        if (words.shares == 0) revert AmbiguousPendingWithdrawalLayout(requester);

        if (_emergencyRecoveryWindowOpen()) {
            if (!_yieldSourceIsUnreachable()) revert YieldSourceReachable();
        } else {
            _requireNoLossPending();
        }
        uint256 escrowed = balanceOf(address(this));
        if (words.shares > escrowed) {
            revert PendingWithdrawalShareRecoveryUnavailable(requester, words.shares, escrowed);
        }

        _pendingWithdrawalMigrationState[requester] = PendingWithdrawalMigrationState.SharesRecovering;
        _transfer(address(this), requester, words.shares);
        bytes32 base = _pendingWithdrawalStorageBase(requester);
        assembly {
            sstore(base, 0)
            sstore(add(base, 1), 0)
            sstore(add(base, 2), 0)
            sstore(add(base, 3), 0)
            sstore(add(base, 4), 0)
            sstore(add(base, 5), 0)
            sstore(add(base, 6), 0)
        }
        delete _pendingWithdrawalMigrationState[requester];
        emit PendingWithdrawalSharesRecovered(requester, words.shares);
    }

    function _pendingWithdrawalStorageBase(address requester) private pure returns (bytes32 base) {
        uint256 mappingSlot;
        assembly {
            mappingSlot := _pendingWithdrawals.slot
        }
        return AtRiskUSDStateModuleStorage.pendingWithdrawalStorageBase(requester, mappingSlot);
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
        if (!ok || data.length < 32) return false;
        address custodian = abi.decode(data, (address));
        if (custodian == address(0) || custodian.code.length == 0) return false;
        (ok, data) = custodian.staticcall(abi.encodeWithSignature("tierShareActionsPaused()"));
        if (!ok || data.length < 32) revert CustodianSettlementHookFailed(custodian);
        return abi.decode(data, (bool));
    }

    function _hasExpiredAutoRenewDisabledAccount(address account) private view returns (bool) {
        uint256 expiry = _autoRenewDisabledTrackedExpiry[account];
        return _autoRenewDisabledTracked[account] && expiry != 0 && block.timestamp >= expiry;
    }

    function _requireNotBlocked(address account) private view {
        address blocklist_ = _blocklist;
        if (blocklist_ != address(0) && IBlocklist(blocklist_).isBlocked(account)) {
            revert BlockedAddress(account);
        }
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0) && value > 0) {
            if (from != _stakingQueue && from != address(this)) {
                if (block.timestamp < _lockExpiry[from]) revert LockupNotExpired(_lockExpiry[from]);
                if (to != address(this) && _hasExpiredAutoRenewDisabledAccount(from)) {
                    revert ExpiredAutoRenewDisabledLockup();
                }
            }
        }
        if (from != address(0)) _requireNotBlocked(from);
        if (to != address(0)) _requireNotBlocked(to);
        super._update(from, to, value);
        if (from != address(0)) _syncAutoRenewDisabledTracking(from);
        if (to != address(0) && to != from) _syncAutoRenewDisabledTracking(to);
    }
}
