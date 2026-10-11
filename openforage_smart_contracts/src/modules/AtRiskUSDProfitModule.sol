// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "../interfaces/IAllowlist.sol";
import "../interfaces/IBlocklist.sol";
import {
    IUSDCTreasuryCallerEligibility,
    IUSDCTreasuryYieldClaims,
    IYieldSourceBridgeRoute
} from "../interfaces/IUSDCTreasuryYieldClaims.sol";

interface IAtRiskUSDProfitHost {
    function asset() external view returns (address);
    function balanceOf(address account) external view returns (uint256);
    function blocklist() external view returns (address);
    function pendingWithdrawalAmount(address account) external view returns (uint256, uint256);
    function totalSupply() external view returns (uint256);
    function yieldSource() external view returns (address);
}

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

contract AtRiskUSDProfitModule {
    using SafeERC20 for IERC20;

    error DirectCallForbidden();
    error FreshDeploymentRequired(uint64 observedVersion);
    error InvalidProfitModule();
    error BlockedAddress(address account);
    error NoFundedProfit();
    error ProfitIndexPrecisionExhausted(uint256 outstanding, uint256 scale);
    error ProfitClaimInvariant(uint256 expected, uint256 actual);
    error ProfitEpochCatchUpRequired(address account, uint64 nextEpoch, uint64 currentEpoch);
    error UnpaidProfitUnavailable(uint256 requested, uint256 outstanding);
    error YieldClaimsNotReady(address source);
    error YieldClaimsUnavailable(address source);
    error YieldSourceClaimOutstanding(address source, uint256 claim);
    error YieldSourceWiringMismatch(address source);
    error YieldSourceAttestorUnavailable(address source, address attestor);
    error YieldSourceCallerNotEligible(address source, address caller);
    error YieldSourceBridgeUnavailable(address source, address bridge);
    error YieldSourceBridgeRouteMismatch(
        address source, address bridge, address expectedTreasury, address actualTreasury
    );
    error ZeroAmount();
    error ZeroSupplyYield();

    event UnpaidProfitClaimed(address indexed holder, uint256 amount);
    event UnpaidProfitCatchUpProgress(address indexed account, uint64 nextEpoch, uint64 currentEpoch);
    event UnpaidProfitRecognized(uint256 amount, uint256 shares);
    event UnpaidProfitWrittenDown(uint256 amount, uint256 remaining);

    struct ProfitEntitlement {
        uint256 units;
        uint256 unitsIndex;
        uint256 fundedDebt;
        uint256 fundedDebtIndex;
        uint256 impairmentDebt;
        uint256 impairmentDebtIndex;
        uint256 activeFundedCheckpoint;
        uint256 activeImpairmentCheckpoint;
        uint256 face;
        uint256 funded;
        uint256 impaired;
        uint256 paid;
        uint256 faceCheckpoint;
        uint256 fundedCheckpoint;
        uint256 impairmentCheckpoint;
        uint64 activeEpoch;
        uint256 unitsRemainder;
        uint256 faceRemainder;
        uint256 activeFundedCheckpointShareRemainder;
        uint256 activeFundedCheckpointIndexRemainder;
        uint256 activeImpairmentCheckpointShareRemainder;
        uint256 activeImpairmentCheckpointIndexRemainder;
        uint256 fundedDebtIndexRemainder;
        uint256 impairmentDebtIndexRemainder;
        uint256 activeRemainderScale;
        uint256 fundedRemainderShare;
        uint256 fundedRemainderIndex;
        uint256 impairmentRemainderShare;
        uint256 impairmentRemainderIndex;
        uint256 totalRemainderScale;
    }

    struct ClosedProfitEpoch {
        uint256 unitsPerShare;
        uint256 fundedDebtPerShare;
        uint256 impairmentDebtPerShare;
        uint256 completedFundedPerShare;
        uint256 completedImpairedPerShare;
        bool finalized;
        uint256 indexScale;
        uint256 fundedDebtPerShareRemainder;
        uint256 impairmentDebtPerShareRemainder;
        uint256 facePerShare;
    }

    struct IndexedAmount {
        uint256 whole;
        uint256 shareRemainder;
        uint256 indexRemainder;
    }

    struct DebtIndex {
        uint256 whole;
        uint256 remainder;
    }

    struct AccountAccrual {
        IndexedAmount fundedDebt;
        IndexedAmount impairmentDebt;
    }

    struct IndexSnapshot {
        uint256 funding;
        uint256 impairment;
        uint256 scale;
    }

    struct PartialIndexPlan {
        uint256 indexScale;
        uint256 unitScale;
        uint256 multiplier;
        uint256 delta;
        uint256 mappedAmount;
        uint256 mappedRemaining;
    }

    struct ProfitStorage {
        uint64 version;
        uint64 epoch;
        uint256 completedFacePerShare;
        uint256 completedFundedPerShare;
        uint256 completedImpairedPerShare;
        uint256 activeUnits;
        uint256 activeUnitsPerShare;
        uint256 activeFundedDebtPerShare;
        uint256 activeImpairmentDebtPerShare;
        uint256 activeFacePerShare;
        uint256 activeFundingIndex;
        uint256 activeImpairmentIndex;
        uint256 unitScale;
        uint256 fundedReserve;
        uint256 unpaidTotal;
        mapping(uint64 => uint256) finalFundingIndex;
        mapping(uint64 => uint256) finalImpairmentIndex;
        mapping(address => ProfitEntitlement) entitlements;
        mapping(uint64 => ClosedProfitEpoch) closedEpochs;
        uint256 indexScale;
        uint256 activeFundedDebtPerShareRemainder;
        uint256 activeImpairmentDebtPerShareRemainder;
    }

    uint256 private constant PROFIT_SCALE = 1e27;
    uint64 private constant MAX_CLOSED_EPOCHS_PER_CALL = 8;
    bytes32 private immutable _SELF;
    bytes32 private immutable _PROFIT_STORAGE_SLOT;

    constructor() {
        _SELF = bytes32(uint256(uint160(address(this))));
        bytes32 namespace = keccak256(bytes("openforage.storage.atRISKUSD.profit"));
        _PROFIT_STORAGE_SLOT = bytes32(uint256(keccak256(abi.encode(uint256(namespace) - 1))) & ~uint256(0xff));
    }

    modifier onlyDelegateCall() {
        if (address(this) == address(uint160(uint256(_SELF)))) revert DirectCallForbidden();
        _requireReady();
        _;
    }

    function initialize() external {
        if (address(this) == address(uint160(uint256(_SELF)))) revert DirectCallForbidden();
        ProfitStorage storage state = _state();
        if (state.version != 0) revert InvalidProfitModule();
        state.version = 3;
        state.epoch = 1;
        state.unitScale = PROFIT_SCALE;
        state.indexScale = PROFIT_SCALE;
        state.activeFundedDebtPerShareRemainder = 0;
        state.activeImpairmentDebtPerShareRemainder = 0;
    }

    function validateYieldSourceHandoff(address current, address successor) external view onlyDelegateCall {
        _validateYieldSourceHandoff(current, successor);
    }

    function _validateYieldSourceHandoff(address current, address successor) private view {
        IUSDCTreasuryYieldClaims currentClaims = IUSDCTreasuryYieldClaims(current);
        address currentVault;
        address currentRegistry;
        if (current != address(0)) {
            currentClaims = _readyYieldClaims(current);
            uint256 currentClaim = _readYieldClaim(currentClaims, current);
            if (currentClaim != 0) revert YieldSourceClaimOutstanding(current, currentClaim);
            (currentVault, currentRegistry) = _readYieldWiring(currentClaims, current);
        }
        IUSDCTreasuryYieldClaims successorClaims = _readyYieldClaims(successor);
        uint256 successorClaim = _readYieldClaim(successorClaims, successor);
        if (successorClaim != 0) revert YieldSourceClaimOutstanding(successor, successorClaim);
        (address nextVault, address nextRegistry) = _readYieldWiring(successorClaims, successor);
        if (current != address(0) && (nextVault != currentVault || nextRegistry != currentRegistry)) {
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
        address currentBridge;
        if (current != address(0)) currentBridge = _readYieldSourceBridge(currentClaims, current);
        address successorBridge = _readYieldSourceBridge(successorClaims, successor);
        if (current != address(0) && currentBridge != successorBridge) revert YieldSourceWiringMismatch(successor);
        _requireTreasuryCallerAllowed(callerAllowlist, successor, successorBridge);
        address treasury = _readBridgeTreasury(successor, successorBridge);
        if (treasury != successor) {
            revert YieldSourceBridgeRouteMismatch(successor, successorBridge, successor, treasury);
        }
        _requireFundingCallerUnblocked(successorBridge, successor, successor, true);
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

    function recognizeUnpaidProfit(uint256 amount) external onlyDelegateCall {
        _requireYieldSource();
        if (amount == 0) revert ZeroAmount();
        ProfitStorage storage state = _state();
        uint256 currentOutstanding = _readOutstanding();
        if (currentOutstanding != state.unpaidTotal) {
            revert ProfitClaimInvariant(state.unpaidTotal, currentOutstanding);
        }
        uint256 supply = IAtRiskUSDProfitHost(address(this)).totalSupply();
        if (supply == 0) revert ZeroSupplyYield();
        uint256 indexScale = _activeIndexScale(state);
        uint256 units = Math.mulDiv(amount, indexScale, state.unitScale);
        if (units == 0) revert ProfitIndexPrecisionExhausted(state.unpaidTotal, state.unitScale);
        uint256 unitsPerShare = Math.mulDiv(units, PROFIT_SCALE, supply);
        state.activeUnits += units;
        state.activeUnitsPerShare += unitsPerShare;
        DebtIndex memory fundedDebt = _addDebtIndex(
            DebtIndex(state.activeFundedDebtPerShare, state.activeFundedDebtPerShareRemainder),
            unitsPerShare,
            state.activeFundingIndex,
            indexScale
        );
        DebtIndex memory impairmentDebt = _addDebtIndex(
            DebtIndex(state.activeImpairmentDebtPerShare, state.activeImpairmentDebtPerShareRemainder),
            unitsPerShare,
            state.activeImpairmentIndex,
            indexScale
        );
        state.activeFundedDebtPerShare = fundedDebt.whole;
        state.activeFundedDebtPerShareRemainder = fundedDebt.remainder;
        state.activeImpairmentDebtPerShare = impairmentDebt.whole;
        state.activeImpairmentDebtPerShareRemainder = impairmentDebt.remainder;
        state.activeFacePerShare += Math.mulDiv(amount, PROFIT_SCALE, supply);
        state.unpaidTotal += amount;
        emit UnpaidProfitRecognized(amount, supply);
    }

    function fundUnpaidProfit(uint256 amount) external onlyDelegateCall {
        _requireYieldSource();
        if (amount == 0) revert ZeroAmount();
        ProfitStorage storage state = _state();
        uint256 outstanding = _readOutstanding();
        if (outstanding != state.unpaidTotal) revert ProfitClaimInvariant(state.unpaidTotal, outstanding);
        if (amount > outstanding) revert UnpaidProfitUnavailable(amount, outstanding);
        uint256 scale = state.unitScale;
        if (state.activeUnits == 0) revert InvalidProfitModule();
        if (amount > type(uint256).max - state.fundedReserve) {
            revert ProfitClaimInvariant(type(uint256).max - amount, state.fundedReserve);
        }
        uint256 delta = _partialIndexDelta(state, amount, outstanding);
        scale = state.unitScale;
        if (delta == 0 || delta > scale) {
            revert ProfitIndexPrecisionExhausted(outstanding, scale);
        }
        state.activeFundingIndex += delta;
        state.unitScale = scale - delta == 0 ? 1 : scale - delta;
        state.fundedReserve += amount;
        state.unpaidTotal = outstanding - amount;
        if (state.unpaidTotal == 0) _closeEpoch(state);
    }

    function writeDownUnpaidProfit(uint256 amount) external onlyDelegateCall {
        _requireYieldSource();
        if (amount == 0) revert ZeroAmount();
        ProfitStorage storage state = _state();
        uint256 outstanding = _readOutstanding();
        if (outstanding != state.unpaidTotal) revert ProfitClaimInvariant(state.unpaidTotal, outstanding);
        if (amount > outstanding) revert UnpaidProfitUnavailable(amount, outstanding);
        uint256 scale = state.unitScale;
        if (state.activeUnits == 0) revert InvalidProfitModule();
        uint256 delta = _partialIndexDelta(state, amount, outstanding);
        scale = state.unitScale;
        if (delta == 0 || delta > scale) {
            revert ProfitIndexPrecisionExhausted(outstanding, scale);
        }
        state.activeImpairmentIndex += delta;
        state.unitScale = scale - delta == 0 ? 1 : scale - delta;
        state.unpaidTotal = outstanding - amount;
        emit UnpaidProfitWrittenDown(amount, state.unpaidTotal);
        if (state.unpaidTotal == 0) _closeEpoch(state);
    }

    function claimUnpaidProfit() external onlyDelegateCall returns (uint256 amount) {
        address holder = msg.sender;
        _requireNotBlocked(holder);
        ProfitStorage storage state = _state();
        ProfitEntitlement storage entitlement = state.entitlements[holder];
        _settle(state, entitlement, holder, false);
        uint256 remainingFace = _remainingFaceCeiling(entitlement);
        uint256 ceiling = remainingFace > entitlement.paid ? remainingFace - entitlement.paid : 0;
        uint256 available = entitlement.funded > entitlement.paid ? entitlement.funded - entitlement.paid : 0;
        amount = available < ceiling ? available : ceiling;
        if (amount > state.fundedReserve) amount = state.fundedReserve;
        if (amount == 0) revert NoFundedProfit();
        entitlement.paid += amount;
        state.fundedReserve -= amount;
        IERC20(IAtRiskUSDProfitHost(address(this)).asset()).safeTransfer(holder, amount);
        emit UnpaidProfitClaimed(holder, amount);
    }

    function update(address from, address to) external onlyDelegateCall {
        ProfitStorage storage state = _state();
        _settleAccount(state, from);
        if (to != from) _settleAccount(state, to);
    }

    function catchUpUnpaidProfitEpochs(address account) external onlyDelegateCall returns (bool caughtUp) {
        ProfitStorage storage state = _state();
        ProfitEntitlement storage entitlement = state.entitlements[account];
        caughtUp = _settle(state, entitlement, account, true);
        emit UnpaidProfitCatchUpProgress(account, entitlement.activeEpoch, state.epoch);
    }

    function _settleAccount(ProfitStorage storage state, address account) private {
        if (account == address(0)) return;
        ProfitEntitlement storage entitlement = state.entitlements[account];
        _settle(state, entitlement, account, false);
    }

    function _settle(
        ProfitStorage storage state,
        ProfitEntitlement storage entitlement,
        address account,
        bool allowPartial
    ) private returns (bool caughtUp) {
        if (entitlement.activeRemainderScale == 0) entitlement.activeRemainderScale = PROFIT_SCALE;
        if (entitlement.totalRemainderScale == 0) entitlement.totalRemainderScale = PROFIT_SCALE;
        uint256 shares;
        if (account != address(this)) {
            IAtRiskUSDProfitHost host = IAtRiskUSDProfitHost(address(this));
            shares = host.balanceOf(account);
            (, uint256 pendingShares) = host.pendingWithdrawalAmount(account);
            shares += pendingShares;
        }
        uint64 activeEpoch = entitlement.activeEpoch;
        if (activeEpoch != 0 && activeEpoch < state.epoch) {
            uint64 missedEpochs = state.epoch - activeEpoch;
            if (missedEpochs > MAX_CLOSED_EPOCHS_PER_CALL && !allowPartial) {
                revert ProfitEpochCatchUpRequired(account, activeEpoch, state.epoch);
            }
            uint64 epochsToSettle =
                missedEpochs > MAX_CLOSED_EPOCHS_PER_CALL ? MAX_CLOSED_EPOCHS_PER_CALL : missedEpochs;
            for (uint64 settled; settled < epochsToSettle; ++settled) {
                _settleClosedEpoch(state, entitlement, shares);
            }
            if (entitlement.activeEpoch < state.epoch) return false;
        }
        uint256 indexScale = _activeIndexScale(state);
        _rescaleActiveRemainders(entitlement, indexScale);
        if (shares != 0) {
            if (state.activeFacePerShare < entitlement.faceCheckpoint) {
                revert ProfitClaimInvariant(state.activeFacePerShare, entitlement.faceCheckpoint);
            }
            if (state.activeUnitsPerShare < entitlement.unitsIndex) {
                revert ProfitClaimInvariant(state.activeUnitsPerShare, entitlement.unitsIndex);
            }
            _accrueFace(entitlement, shares, state.activeFacePerShare - entitlement.faceCheckpoint);
            _accrueUnits(entitlement, shares, state.activeUnitsPerShare - entitlement.unitsIndex);
        }
        AccountAccrual memory accrual;
        accrual.fundedDebt = _debtDelta(
            shares,
            DebtIndex(state.activeFundedDebtPerShare, state.activeFundedDebtPerShareRemainder),
            DebtIndex(entitlement.fundedDebtIndex, entitlement.fundedDebtIndexRemainder),
            indexScale
        );
        accrual.impairmentDebt = _debtDelta(
            shares,
            DebtIndex(state.activeImpairmentDebtPerShare, state.activeImpairmentDebtPerShareRemainder),
            DebtIndex(entitlement.impairmentDebtIndex, entitlement.impairmentDebtIndexRemainder),
            indexScale
        );
        entitlement.fundedDebt += accrual.fundedDebt.whole;
        entitlement.impairmentDebt += accrual.impairmentDebt.whole;
        _accrueIndexedEntitlements(
            entitlement, accrual, IndexSnapshot(state.activeFundingIndex, state.activeImpairmentIndex, indexScale)
        );
        uint256 fundedIndex = state.completedFundedPerShare + _activeFundedPerShare(state);
        uint256 impairmentIndex = state.completedImpairedPerShare + _activeImpairedPerShare(state);
        entitlement.faceCheckpoint = state.activeFacePerShare;
        entitlement.fundedCheckpoint = fundedIndex;
        entitlement.impairmentCheckpoint = impairmentIndex;
        entitlement.unitsIndex = state.activeUnitsPerShare;
        entitlement.fundedDebtIndex = state.activeFundedDebtPerShare;
        entitlement.fundedDebtIndexRemainder = state.activeFundedDebtPerShareRemainder;
        entitlement.impairmentDebtIndex = state.activeImpairmentDebtPerShare;
        entitlement.impairmentDebtIndexRemainder = state.activeImpairmentDebtPerShareRemainder;
        entitlement.activeEpoch = state.epoch;
        return true;
    }

    function _accrueFace(ProfitEntitlement storage entitlement, uint256 shares, uint256 faceIndexDelta) private {
        uint256 face = Math.mulDiv(shares, faceIndexDelta, PROFIT_SCALE);
        uint256 remainder = mulmod(shares, faceIndexDelta, PROFIT_SCALE) + entitlement.faceRemainder;
        face += remainder / PROFIT_SCALE;
        entitlement.faceRemainder = remainder % PROFIT_SCALE;
        entitlement.face += face;
    }

    function _accrueUnits(ProfitEntitlement storage entitlement, uint256 shares, uint256 unitsIndexDelta) private {
        uint256 units = Math.mulDiv(shares, unitsIndexDelta, PROFIT_SCALE);
        uint256 remainder = mulmod(shares, unitsIndexDelta, PROFIT_SCALE) + entitlement.unitsRemainder;
        units += remainder / PROFIT_SCALE;
        entitlement.unitsRemainder = remainder % PROFIT_SCALE;
        entitlement.units += units;
    }

    function _rescaleActiveRemainders(ProfitEntitlement storage entitlement, uint256 scale) private {
        uint256 previousScale = entitlement.activeRemainderScale;
        if (previousScale == 0 || scale < previousScale || scale % previousScale != 0) {
            revert ProfitClaimInvariant(scale, previousScale);
        }
        if (scale != previousScale) {
            entitlement.activeFundedCheckpointIndexRemainder =
                _rescaleRemainder(entitlement.activeFundedCheckpointIndexRemainder, previousScale, scale);
            entitlement.activeImpairmentCheckpointIndexRemainder =
                _rescaleRemainder(entitlement.activeImpairmentCheckpointIndexRemainder, previousScale, scale);
            entitlement.fundedDebtIndexRemainder =
                _rescaleRemainder(entitlement.fundedDebtIndexRemainder, previousScale, scale);
            entitlement.impairmentDebtIndexRemainder =
                _rescaleRemainder(entitlement.impairmentDebtIndexRemainder, previousScale, scale);
        }
        entitlement.activeRemainderScale = scale;
    }

    function _rescaleRemainder(uint256 remainder, uint256 previousScale, uint256 nextScale)
        private
        pure
        returns (uint256)
    {
        if (remainder >= previousScale) revert ProfitClaimInvariant(previousScale, remainder);
        return remainder * (nextScale / previousScale);
    }

    function _settleClosedEpoch(ProfitStorage storage state, ProfitEntitlement storage entitlement, uint256 shares)
        private
    {
        uint64 epoch = entitlement.activeEpoch;
        ClosedProfitEpoch storage closed = state.closedEpochs[epoch];
        if (!closed.finalized) revert ProfitClaimInvariant(state.epoch, epoch);
        uint256 indexScale = closed.indexScale == 0 ? PROFIT_SCALE : closed.indexScale;
        _rescaleActiveRemainders(entitlement, indexScale);
        _accrueClosedEpochUnits(state, entitlement, closed, shares);
        _rebaseClosedEpoch(entitlement, closed, epoch + 1);
    }

    function _accrueClosedEpochUnits(
        ProfitStorage storage state,
        ProfitEntitlement storage entitlement,
        ClosedProfitEpoch storage closed,
        uint256 shares
    ) private {
        if (
            closed.facePerShare < entitlement.faceCheckpoint || closed.unitsPerShare < entitlement.unitsIndex
                || closed.fundedDebtPerShare < entitlement.fundedDebtIndex
                || closed.impairmentDebtPerShare < entitlement.impairmentDebtIndex
        ) revert ProfitClaimInvariant(closed.unitsPerShare, entitlement.unitsIndex);
        uint256 indexScale = closed.indexScale == 0 ? PROFIT_SCALE : closed.indexScale;
        _accrueFace(entitlement, shares, closed.facePerShare - entitlement.faceCheckpoint);
        _accrueUnits(entitlement, shares, closed.unitsPerShare - entitlement.unitsIndex);
        AccountAccrual memory accrual;
        accrual.fundedDebt = _debtDelta(
            shares,
            DebtIndex(closed.fundedDebtPerShare, closed.fundedDebtPerShareRemainder),
            DebtIndex(entitlement.fundedDebtIndex, entitlement.fundedDebtIndexRemainder),
            indexScale
        );
        accrual.impairmentDebt = _debtDelta(
            shares,
            DebtIndex(closed.impairmentDebtPerShare, closed.impairmentDebtPerShareRemainder),
            DebtIndex(entitlement.impairmentDebtIndex, entitlement.impairmentDebtIndexRemainder),
            indexScale
        );
        entitlement.fundedDebt += accrual.fundedDebt.whole;
        entitlement.impairmentDebt += accrual.impairmentDebt.whole;
        _accrueIndexedEntitlements(
            entitlement,
            accrual,
            IndexSnapshot(
                state.finalFundingIndex[entitlement.activeEpoch],
                state.finalImpairmentIndex[entitlement.activeEpoch],
                indexScale
            )
        );
        entitlement.faceCheckpoint = closed.facePerShare;
        entitlement.unitsIndex = closed.unitsPerShare;
        entitlement.fundedDebtIndex = closed.fundedDebtPerShare;
        entitlement.fundedDebtIndexRemainder = closed.fundedDebtPerShareRemainder;
        entitlement.impairmentDebtIndex = closed.impairmentDebtPerShare;
        entitlement.impairmentDebtIndexRemainder = closed.impairmentDebtPerShareRemainder;
    }

    function _accrueIndexedEntitlements(
        ProfitEntitlement storage entitlement,
        AccountAccrual memory accrual,
        IndexSnapshot memory index
    ) private {
        IndexedAmount memory funded =
            _indexedAmount(entitlement.units, entitlement.unitsRemainder, index.funding, index.scale);
        IndexedAmount memory previousFunded = IndexedAmount(
            entitlement.activeFundedCheckpoint,
            entitlement.activeFundedCheckpointShareRemainder,
            entitlement.activeFundedCheckpointIndexRemainder
        );
        IndexedAmount memory fundedDelta = _subtractIndexedAmounts(funded, previousFunded, index.scale);
        _addEntitlementAmount(
            entitlement, _subtractIndexedAmounts(fundedDelta, accrual.fundedDebt, index.scale), index.scale, true
        );
        entitlement.activeFundedCheckpoint = funded.whole;
        entitlement.activeFundedCheckpointShareRemainder = funded.shareRemainder;
        entitlement.activeFundedCheckpointIndexRemainder = funded.indexRemainder;
        IndexedAmount memory impaired =
            _indexedAmount(entitlement.units, entitlement.unitsRemainder, index.impairment, index.scale);
        IndexedAmount memory previousImpaired = IndexedAmount(
            entitlement.activeImpairmentCheckpoint,
            entitlement.activeImpairmentCheckpointShareRemainder,
            entitlement.activeImpairmentCheckpointIndexRemainder
        );
        IndexedAmount memory impairmentDelta = _subtractIndexedAmounts(impaired, previousImpaired, index.scale);
        _addEntitlementAmount(
            entitlement,
            _subtractIndexedAmounts(impairmentDelta, accrual.impairmentDebt, index.scale),
            index.scale,
            false
        );
        entitlement.activeImpairmentCheckpoint = impaired.whole;
        entitlement.activeImpairmentCheckpointShareRemainder = impaired.shareRemainder;
        entitlement.activeImpairmentCheckpointIndexRemainder = impaired.indexRemainder;
    }

    function _debtDelta(uint256 shares, DebtIndex memory current, DebtIndex memory previous, uint256 scale)
        private
        pure
        returns (IndexedAmount memory amount)
    {
        DebtIndex memory delta = _subtractDebtIndex(current, previous, scale);
        uint256 fractionalShare = Math.mulDiv(shares, delta.remainder, scale);
        amount.whole = Math.mulDiv(shares, delta.whole, PROFIT_SCALE) + fractionalShare / PROFIT_SCALE;
        amount.shareRemainder = mulmod(shares, delta.whole, PROFIT_SCALE) + fractionalShare % PROFIT_SCALE;
        amount.indexRemainder = mulmod(shares, delta.remainder, scale);
        return _normalizeIndexedAmount(amount, scale);
    }

    function _subtractDebtIndex(DebtIndex memory current, DebtIndex memory previous, uint256 scale)
        private
        pure
        returns (DebtIndex memory delta)
    {
        if (current.remainder >= scale || previous.remainder >= scale || current.whole < previous.whole) {
            revert ProfitClaimInvariant(current.whole, previous.whole);
        }
        if (current.remainder >= previous.remainder) {
            delta.whole = current.whole - previous.whole;
            delta.remainder = current.remainder - previous.remainder;
            return delta;
        }
        if (current.whole == previous.whole) revert ProfitClaimInvariant(current.whole, previous.whole);
        delta.whole = current.whole - previous.whole - 1;
        delta.remainder = scale - previous.remainder + current.remainder;
    }

    function _indexedAmount(uint256 units, uint256 unitsRemainder, uint256 index, uint256 scale)
        private
        pure
        returns (IndexedAmount memory amount)
    {
        if (unitsRemainder >= PROFIT_SCALE || index > scale) revert ProfitClaimInvariant(scale, index);
        amount.whole = Math.mulDiv(units, index, scale);
        uint256 unitIndexRemainder = mulmod(units, index, scale);
        amount.shareRemainder = Math.mulDiv(unitIndexRemainder, PROFIT_SCALE, scale);
        amount.indexRemainder = mulmod(unitIndexRemainder, PROFIT_SCALE, scale);
        uint256 fractionalUnits = Math.mulDiv(unitsRemainder, index, scale);
        uint256 fractionalIndexRemainder = mulmod(unitsRemainder, index, scale);
        amount.shareRemainder += fractionalUnits;
        uint256 fractionalCarry;
        (amount.indexRemainder, fractionalCarry) =
            _addIndexRemainders(amount.indexRemainder, fractionalIndexRemainder, scale);
        amount.shareRemainder += fractionalCarry;
        return _normalizeIndexedAmount(amount, scale);
    }

    function _addIndexRemainders(uint256 first, uint256 second, uint256 scale)
        private
        pure
        returns (uint256 remainder, uint256 carry)
    {
        if (first >= scale || second >= scale) revert ProfitClaimInvariant(scale, first);
        uint256 distance = scale - first;
        if (second >= distance) return (second - distance, 1);
        return (first + second, 0);
    }

    function _normalizeIndexedAmount(IndexedAmount memory amount, uint256 scale)
        private
        pure
        returns (IndexedAmount memory)
    {
        if (amount.indexRemainder >= scale) revert ProfitClaimInvariant(scale, amount.indexRemainder);
        amount.whole += amount.shareRemainder / PROFIT_SCALE;
        amount.shareRemainder %= PROFIT_SCALE;
        return amount;
    }

    function _subtractIndexedAmounts(IndexedAmount memory current, IndexedAmount memory previous, uint256 scale)
        private
        pure
        returns (IndexedAmount memory difference)
    {
        if (current.whole < previous.whole) revert ProfitClaimInvariant(current.whole, previous.whole);
        difference.whole = current.whole - previous.whole;
        uint256 share = current.shareRemainder;
        if (current.indexRemainder < previous.indexRemainder) {
            if (share == 0) {
                if (difference.whole == 0) revert ProfitClaimInvariant(current.whole, previous.whole);
                difference.whole -= 1;
                share = PROFIT_SCALE;
            }
            share -= 1;
            difference.indexRemainder = scale - (previous.indexRemainder - current.indexRemainder);
        } else {
            difference.indexRemainder = current.indexRemainder - previous.indexRemainder;
        }
        if (share < previous.shareRemainder) {
            if (difference.whole == 0) revert ProfitClaimInvariant(current.whole, previous.whole);
            difference.whole -= 1;
            share += PROFIT_SCALE;
        }
        difference.shareRemainder = share - previous.shareRemainder;
    }

    function _addEntitlementAmount(
        ProfitEntitlement storage entitlement,
        IndexedAmount memory amount,
        uint256 amountScale,
        bool funding
    ) private {
        uint256 previousScale = entitlement.totalRemainderScale;
        if (previousScale == 0) revert ProfitClaimInvariant(PROFIT_SCALE, previousScale);
        uint256 totalScale = previousScale > amountScale ? previousScale : amountScale;
        if (totalScale % previousScale != 0 || totalScale % amountScale != 0) {
            revert ProfitClaimInvariant(totalScale, amountScale);
        }
        if (totalScale != previousScale) {
            uint256 multiplier = totalScale / previousScale;
            entitlement.fundedRemainderIndex *= multiplier;
            entitlement.impairmentRemainderIndex *= multiplier;
        }
        uint256 indexRemainder = amount.indexRemainder * (totalScale / amountScale);
        uint256 previousIndexRemainder =
            funding ? entitlement.fundedRemainderIndex : entitlement.impairmentRemainderIndex;
        uint256 previousShareRemainder =
            funding ? entitlement.fundedRemainderShare : entitlement.impairmentRemainderShare;
        uint256 carry;
        (indexRemainder, carry) = _addIndexRemainders(previousIndexRemainder, indexRemainder, totalScale);
        uint256 shareRemainder = previousShareRemainder + amount.shareRemainder + carry;
        uint256 whole = amount.whole + shareRemainder / PROFIT_SCALE;
        shareRemainder %= PROFIT_SCALE;
        if (funding) {
            entitlement.funded += whole;
            entitlement.fundedRemainderShare = shareRemainder;
            entitlement.fundedRemainderIndex = indexRemainder;
        } else {
            entitlement.impaired += whole;
            entitlement.impairmentRemainderShare = shareRemainder;
            entitlement.impairmentRemainderIndex = indexRemainder;
        }
        entitlement.totalRemainderScale = totalScale;
    }

    function _remainingFaceCeiling(ProfitEntitlement storage entitlement) private view returns (uint256) {
        uint256 scale = entitlement.totalRemainderScale;
        if (scale == 0) revert ProfitClaimInvariant(PROFIT_SCALE, scale);
        IndexedAmount memory face = IndexedAmount(entitlement.face, entitlement.faceRemainder, 0);
        IndexedAmount memory impaired = IndexedAmount(
            entitlement.impaired, entitlement.impairmentRemainderShare, entitlement.impairmentRemainderIndex
        );
        if (_amountAtMost(face, impaired)) return 0;
        return _subtractIndexedAmounts(face, impaired, scale).whole;
    }

    function _amountAtMost(IndexedAmount memory first, IndexedAmount memory second) private pure returns (bool) {
        if (first.whole != second.whole) return first.whole < second.whole;
        if (first.shareRemainder != second.shareRemainder) return first.shareRemainder < second.shareRemainder;
        return first.indexRemainder <= second.indexRemainder;
    }

    function _rebaseClosedEpoch(
        ProfitEntitlement storage entitlement,
        ClosedProfitEpoch storage closed,
        uint64 nextEpoch
    ) private {
        entitlement.units = 0;
        entitlement.unitsRemainder = 0;
        entitlement.fundedDebt = 0;
        entitlement.impairmentDebt = 0;
        entitlement.activeFundedCheckpoint = 0;
        entitlement.activeImpairmentCheckpoint = 0;
        entitlement.activeFundedCheckpointShareRemainder = 0;
        entitlement.activeFundedCheckpointIndexRemainder = 0;
        entitlement.activeImpairmentCheckpointShareRemainder = 0;
        entitlement.activeImpairmentCheckpointIndexRemainder = 0;
        entitlement.fundedCheckpoint = closed.completedFundedPerShare;
        entitlement.impairmentCheckpoint = closed.completedImpairedPerShare;
        entitlement.faceCheckpoint = 0;
        entitlement.activeEpoch = nextEpoch;
        entitlement.unitsIndex = 0;
        entitlement.fundedDebtIndex = 0;
        entitlement.impairmentDebtIndex = 0;
        entitlement.fundedDebtIndexRemainder = 0;
        entitlement.impairmentDebtIndexRemainder = 0;
        entitlement.activeRemainderScale = PROFIT_SCALE;
    }

    function _activeFundedPerShare(ProfitStorage storage state) private view returns (uint256) {
        uint256 funded = Math.mulDiv(state.activeUnitsPerShare, state.activeFundingIndex, _activeIndexScale(state));
        return funded > state.activeFundedDebtPerShare ? funded - state.activeFundedDebtPerShare : 0;
    }

    function _activeImpairedPerShare(ProfitStorage storage state) private view returns (uint256) {
        uint256 impaired = Math.mulDiv(state.activeUnitsPerShare, state.activeImpairmentIndex, _activeIndexScale(state));
        return impaired > state.activeImpairmentDebtPerShare ? impaired - state.activeImpairmentDebtPerShare : 0;
    }

    function _closeEpoch(ProfitStorage storage state) private {
        uint64 epoch = state.epoch;
        state.finalFundingIndex[epoch] = state.activeFundingIndex;
        state.finalImpairmentIndex[epoch] = state.activeImpairmentIndex;
        state.completedFacePerShare += state.activeFacePerShare;
        state.completedFundedPerShare += _activeFundedPerShare(state);
        state.completedImpairedPerShare += _activeImpairedPerShare(state);
        ClosedProfitEpoch storage closed = state.closedEpochs[epoch];
        closed.unitsPerShare = state.activeUnitsPerShare;
        closed.fundedDebtPerShare = state.activeFundedDebtPerShare;
        closed.impairmentDebtPerShare = state.activeImpairmentDebtPerShare;
        closed.completedFundedPerShare = state.completedFundedPerShare;
        closed.completedImpairedPerShare = state.completedImpairedPerShare;
        closed.finalized = true;
        closed.indexScale = _activeIndexScale(state);
        closed.fundedDebtPerShareRemainder = state.activeFundedDebtPerShareRemainder;
        closed.impairmentDebtPerShareRemainder = state.activeImpairmentDebtPerShareRemainder;
        closed.facePerShare = state.activeFacePerShare;
        state.activeUnits = 0;
        state.activeUnitsPerShare = 0;
        state.activeFundedDebtPerShare = 0;
        state.activeImpairmentDebtPerShare = 0;
        state.activeFundedDebtPerShareRemainder = 0;
        state.activeImpairmentDebtPerShareRemainder = 0;
        state.activeFacePerShare = 0;
        state.activeFundingIndex = 0;
        state.activeImpairmentIndex = 0;
        state.unitScale = PROFIT_SCALE;
        state.indexScale = PROFIT_SCALE;
        state.epoch += 1;
    }

    function _activeIndexScale(ProfitStorage storage state) private view returns (uint256) {
        uint256 scale = state.indexScale;
        return scale == 0 ? PROFIT_SCALE : scale;
    }

    function _partialIndexDelta(ProfitStorage storage state, uint256 amount, uint256 outstanding)
        private
        returns (uint256)
    {
        PartialIndexPlan memory plan = _newPartialIndexPlan(state, outstanding);
        uint256 remaining = outstanding - amount;
        uint256 activeUnits = state.activeUnits;
        if (amount == outstanding) {
            plan.delta = plan.unitScale;
            plan.mappedRemaining = Math.mulDiv(activeUnits, plan.unitScale - plan.delta, plan.indexScale);
        } else {
            plan.delta = _partialDeltaAtScale(amount, activeUnits, plan, outstanding);
            while (!_partialIndexBoundMet(activeUnits, amount, remaining, plan, outstanding)) {
                _doublePartialIndexPlan(amount, activeUnits, plan, outstanding);
            }
        }
        if (plan.mappedRemaining > remaining) revert ProfitClaimInvariant(remaining, plan.mappedRemaining);
        _requirePartialIndexUpdateFits(state, plan, outstanding);
        _commitPartialIndexPlan(state, plan);
        return plan.delta;
    }

    function _newPartialIndexPlan(ProfitStorage storage state, uint256 outstanding)
        private
        view
        returns (PartialIndexPlan memory plan)
    {
        plan.indexScale = _activeIndexScale(state);
        plan.unitScale = state.unitScale;
        plan.multiplier = 1;
        if (state.activeUnits == 0 || plan.unitScale == 0 || plan.unitScale > plan.indexScale) {
            revert ProfitIndexPrecisionExhausted(outstanding, plan.unitScale);
        }
        uint256 mappedOutstanding = Math.mulDiv(state.activeUnits, plan.unitScale, plan.indexScale);
        if (mappedOutstanding > outstanding) revert ProfitClaimInvariant(outstanding, mappedOutstanding);
    }

    function _partialIndexBoundMet(
        uint256 activeUnits,
        uint256 amount,
        uint256 remaining,
        PartialIndexPlan memory plan,
        uint256 outstanding
    ) private pure returns (bool) {
        if (plan.delta >= plan.unitScale) revert ProfitIndexPrecisionExhausted(outstanding, plan.unitScale);
        plan.mappedAmount = Math.mulDiv(activeUnits, plan.delta, plan.indexScale);
        if (plan.mappedAmount > amount) revert ProfitClaimInvariant(amount, plan.mappedAmount);
        plan.mappedRemaining = Math.mulDiv(activeUnits, plan.unitScale - plan.delta, plan.indexScale);
        return plan.delta != 0 && amount - plan.mappedAmount <= 1 && plan.mappedRemaining <= remaining;
    }

    function _partialDeltaAtScale(
        uint256 amount,
        uint256 activeUnits,
        PartialIndexPlan memory plan,
        uint256 outstanding
    ) private pure returns (uint256) {
        if (activeUnits < plan.indexScale && amount > Math.mulDiv(type(uint256).max, activeUnits, plan.indexScale)) {
            revert ProfitIndexPrecisionExhausted(outstanding, plan.unitScale);
        }
        return Math.mulDiv(amount, plan.indexScale, activeUnits);
    }

    function _doublePartialIndexPlan(
        uint256 amount,
        uint256 activeUnits,
        PartialIndexPlan memory plan,
        uint256 outstanding
    ) private pure {
        uint256 maximum = type(uint256).max;
        if (plan.indexScale > maximum / 2 || plan.unitScale > maximum / 2 || plan.multiplier > maximum / 2) {
            revert ProfitIndexPrecisionExhausted(outstanding, plan.unitScale);
        }
        plan.indexScale *= 2;
        plan.unitScale *= 2;
        plan.multiplier *= 2;
        plan.delta = _partialDeltaAtScale(amount, activeUnits, plan, outstanding);
    }

    function _requirePartialIndexUpdateFits(
        ProfitStorage storage state,
        PartialIndexPlan memory plan,
        uint256 outstanding
    ) private view {
        uint256 maximum = type(uint256).max;
        uint256 multiplier = plan.multiplier;
        if (
            state.activeFundingIndex > maximum / multiplier || state.activeImpairmentIndex > maximum / multiplier
                || state.activeFundedDebtPerShareRemainder > maximum / multiplier
                || state.activeImpairmentDebtPerShareRemainder > maximum / multiplier
        ) revert ProfitIndexPrecisionExhausted(outstanding, plan.unitScale);
        if (
            state.activeFundingIndex * multiplier > maximum - plan.delta
                || state.activeImpairmentIndex * multiplier > maximum - plan.delta
        ) revert ProfitIndexPrecisionExhausted(outstanding, plan.unitScale);
    }

    function _commitPartialIndexPlan(ProfitStorage storage state, PartialIndexPlan memory plan) private {
        if (plan.multiplier == 1) return;
        state.indexScale = plan.indexScale;
        state.unitScale = plan.unitScale;
        state.activeFundingIndex *= plan.multiplier;
        state.activeImpairmentIndex *= plan.multiplier;
        state.activeFundedDebtPerShareRemainder *= plan.multiplier;
        state.activeImpairmentDebtPerShareRemainder *= plan.multiplier;
    }

    function _addDebtIndex(DebtIndex memory current, uint256 unitsPerShare, uint256 index, uint256 scale)
        private
        pure
        returns (DebtIndex memory next)
    {
        if (current.remainder >= scale || index > scale) revert ProfitClaimInvariant(scale, current.remainder);
        next.whole = current.whole + Math.mulDiv(unitsPerShare, index, scale);
        uint256 remainder = mulmod(unitsPerShare, index, scale);
        uint256 carry;
        (next.remainder, carry) = _addIndexRemainders(current.remainder, remainder, scale);
        next.whole += carry;
    }

    function _readOutstanding() private view returns (uint256) {
        address source = IAtRiskUSDProfitHost(address(this)).yieldSource();
        IUSDCTreasuryYieldClaims claims = IUSDCTreasuryYieldClaims(source);
        bool ready;
        try claims.yieldClaimsReady() returns (bool value) {
            ready = value;
        } catch {
            revert YieldClaimsUnavailable(source);
        }
        if (!ready) revert YieldClaimsNotReady(source);
        try claims.unfundedYieldClaim(address(this)) returns (uint256 amount) {
            return amount;
        } catch {
            revert YieldClaimsUnavailable(source);
        }
    }

    function _requireYieldSource() private view {
        if (msg.sender != IAtRiskUSDProfitHost(address(this)).yieldSource()) revert DirectCallForbidden();
    }

    function _requireNotBlocked(address account) private view {
        address blocklist_ = IAtRiskUSDProfitHost(address(this)).blocklist();
        if (blocklist_ != address(0) && IBlocklist(blocklist_).isBlocked(account)) revert BlockedAddress(account);
    }

    function _requireReady() private view {
        uint64 version = _state().version;
        if (version != 3) revert FreshDeploymentRequired(version);
    }

    function _state() private view returns (ProfitStorage storage state) {
        bytes32 slot = _PROFIT_STORAGE_SLOT;
        assembly {
            state.slot := slot
        }
    }
}
