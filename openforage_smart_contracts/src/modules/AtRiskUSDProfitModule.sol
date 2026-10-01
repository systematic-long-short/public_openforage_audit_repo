// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "../interfaces/IBlocklist.sol";
import "../interfaces/IUSDCTreasuryYieldClaims.sol";

interface IAtRiskUSDProfitHost {
    function asset() external view returns (address);
    function balanceOf(address account) external view returns (uint256);
    function blocklist() external view returns (address);
    function pendingWithdrawalAmount(address account) external view returns (uint256, uint256);
    function totalSupply() external view returns (uint256);
    function yieldSource() external view returns (address);
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
    }

    struct ClosedProfitEpoch {
        uint256 unitsPerShare;
        uint256 fundedDebtPerShare;
        uint256 impairmentDebtPerShare;
        uint256 completedFundedPerShare;
        uint256 completedImpairedPerShare;
        bool finalized;
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
        state.version = 2;
        state.epoch = 1;
        state.unitScale = PROFIT_SCALE;
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
        uint256 units = Math.mulDiv(amount, PROFIT_SCALE, state.unitScale);
        if (units == 0) revert ProfitIndexPrecisionExhausted(state.unpaidTotal, state.unitScale);
        uint256 unitsPerShare = Math.mulDiv(units, PROFIT_SCALE, supply);
        state.activeUnits += units;
        state.activeUnitsPerShare += unitsPerShare;
        state.activeFundedDebtPerShare += Math.mulDiv(unitsPerShare, state.activeFundingIndex, PROFIT_SCALE);
        state.activeImpairmentDebtPerShare += Math.mulDiv(unitsPerShare, state.activeImpairmentIndex, PROFIT_SCALE);
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
        uint256 delta = amount == outstanding ? scale : Math.mulDiv(amount, PROFIT_SCALE, state.activeUnits);
        if (delta == 0 || delta > scale || (scale == 1 && amount < outstanding)) {
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
        uint256 delta = amount == outstanding ? scale : Math.mulDiv(amount, PROFIT_SCALE, state.activeUnits);
        if (delta == 0 || delta > scale || (scale == 1 && amount < outstanding)) {
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
        uint256 remainingFace = entitlement.face > entitlement.impaired ? entitlement.face - entitlement.impaired : 0;
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
        if (shares == 0 && entitlement.activeEpoch == state.epoch && entitlement.units != 0) {
            _accrueActiveEntitlements(state, entitlement, 0, 0);
        }
        uint256 faceIndex = state.completedFacePerShare + state.activeFacePerShare;
        uint256 fundedIndex = state.completedFundedPerShare + _activeFundedPerShare(state);
        uint256 impairmentIndex = state.completedImpairedPerShare + _activeImpairedPerShare(state);
        if (shares != 0) {
            entitlement.face += Math.mulDiv(shares, faceIndex - entitlement.faceCheckpoint, PROFIT_SCALE);
            entitlement.units += Math.mulDiv(shares, state.activeUnitsPerShare - entitlement.unitsIndex, PROFIT_SCALE);
            uint256 newFundedDebt =
                Math.mulDiv(shares, state.activeFundedDebtPerShare - entitlement.fundedDebtIndex, PROFIT_SCALE);
            uint256 newImpairmentDebt =
                Math.mulDiv(shares, state.activeImpairmentDebtPerShare - entitlement.impairmentDebtIndex, PROFIT_SCALE);
            entitlement.fundedDebt += newFundedDebt;
            entitlement.impairmentDebt += newImpairmentDebt;
            _accrueActiveEntitlements(state, entitlement, newFundedDebt, newImpairmentDebt);
        }
        entitlement.faceCheckpoint = faceIndex;
        entitlement.fundedCheckpoint = fundedIndex;
        entitlement.impairmentCheckpoint = impairmentIndex;
        entitlement.unitsIndex = state.activeUnitsPerShare;
        entitlement.fundedDebtIndex = state.activeFundedDebtPerShare;
        entitlement.impairmentDebtIndex = state.activeImpairmentDebtPerShare;
        entitlement.activeEpoch = state.epoch;
        return true;
    }

    function _accrueActiveEntitlements(
        ProfitStorage storage state,
        ProfitEntitlement storage entitlement,
        uint256 newFundedDebt,
        uint256 newImpairmentDebt
    ) private {
        uint256 funded = Math.mulDiv(entitlement.units, state.activeFundingIndex, PROFIT_SCALE);
        if (funded > entitlement.activeFundedCheckpoint) {
            uint256 increment = funded - entitlement.activeFundedCheckpoint;
            if (increment > newFundedDebt) entitlement.funded += increment - newFundedDebt;
        }
        entitlement.activeFundedCheckpoint = funded;
        uint256 impaired = Math.mulDiv(entitlement.units, state.activeImpairmentIndex, PROFIT_SCALE);
        if (impaired > entitlement.activeImpairmentCheckpoint) {
            uint256 increment = impaired - entitlement.activeImpairmentCheckpoint;
            if (increment > newImpairmentDebt) entitlement.impaired += increment - newImpairmentDebt;
        }
        entitlement.activeImpairmentCheckpoint = impaired;
    }

    function _settleClosedEpoch(ProfitStorage storage state, ProfitEntitlement storage entitlement, uint256 shares)
        private
    {
        uint64 epoch = entitlement.activeEpoch;
        ClosedProfitEpoch storage closed = state.closedEpochs[epoch];
        if (!closed.finalized) revert ProfitClaimInvariant(state.epoch, epoch);
        _accrueClosedEpochUnits(state, entitlement, closed, shares);
        _rebaseClosedEpoch(entitlement, closed, epoch + 1);
    }

    function _accrueClosedEpochUnits(
        ProfitStorage storage state,
        ProfitEntitlement storage entitlement,
        ClosedProfitEpoch storage closed,
        uint256 shares
    ) private {
        uint256 unitsIndex = entitlement.unitsIndex;
        uint256 fundedDebtIndex = entitlement.fundedDebtIndex;
        uint256 impairmentDebtIndex = entitlement.impairmentDebtIndex;
        if (
            closed.unitsPerShare < unitsIndex || closed.fundedDebtPerShare < fundedDebtIndex
                || closed.impairmentDebtPerShare < impairmentDebtIndex
        ) revert ProfitClaimInvariant(closed.unitsPerShare, unitsIndex);
        entitlement.units += Math.mulDiv(shares, closed.unitsPerShare - unitsIndex, PROFIT_SCALE);
        uint256 fundedDebt = Math.mulDiv(shares, closed.fundedDebtPerShare - fundedDebtIndex, PROFIT_SCALE);
        uint256 impairmentDebt = Math.mulDiv(shares, closed.impairmentDebtPerShare - impairmentDebtIndex, PROFIT_SCALE);
        _accrueClosedFunding(state, entitlement, fundedDebt);
        _accrueClosedImpairment(state, entitlement, impairmentDebt);
    }

    function _accrueClosedFunding(ProfitStorage storage state, ProfitEntitlement storage entitlement, uint256 newDebt)
        private
    {
        uint256 funded = Math.mulDiv(entitlement.units, state.finalFundingIndex[entitlement.activeEpoch], PROFIT_SCALE);
        if (funded <= entitlement.activeFundedCheckpoint) return;
        uint256 increment = funded - entitlement.activeFundedCheckpoint;
        if (increment > newDebt) entitlement.funded += increment - newDebt;
    }

    function _accrueClosedImpairment(
        ProfitStorage storage state,
        ProfitEntitlement storage entitlement,
        uint256 newDebt
    ) private {
        uint256 impaired =
            Math.mulDiv(entitlement.units, state.finalImpairmentIndex[entitlement.activeEpoch], PROFIT_SCALE);
        if (impaired <= entitlement.activeImpairmentCheckpoint) return;
        uint256 increment = impaired - entitlement.activeImpairmentCheckpoint;
        if (increment > newDebt) entitlement.impaired += increment - newDebt;
    }

    function _rebaseClosedEpoch(
        ProfitEntitlement storage entitlement,
        ClosedProfitEpoch storage closed,
        uint64 nextEpoch
    ) private {
        entitlement.units = 0;
        entitlement.fundedDebt = 0;
        entitlement.impairmentDebt = 0;
        entitlement.activeFundedCheckpoint = 0;
        entitlement.activeImpairmentCheckpoint = 0;
        entitlement.fundedCheckpoint = closed.completedFundedPerShare;
        entitlement.impairmentCheckpoint = closed.completedImpairedPerShare;
        entitlement.activeEpoch = nextEpoch;
        entitlement.unitsIndex = 0;
        entitlement.fundedDebtIndex = 0;
        entitlement.impairmentDebtIndex = 0;
    }

    function _activeFundedPerShare(ProfitStorage storage state) private view returns (uint256) {
        uint256 funded = Math.mulDiv(state.activeUnitsPerShare, state.activeFundingIndex, PROFIT_SCALE);
        return funded > state.activeFundedDebtPerShare ? funded - state.activeFundedDebtPerShare : 0;
    }

    function _activeImpairedPerShare(ProfitStorage storage state) private view returns (uint256) {
        uint256 impaired = Math.mulDiv(state.activeUnitsPerShare, state.activeImpairmentIndex, PROFIT_SCALE);
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
        state.activeUnits = 0;
        state.activeUnitsPerShare = 0;
        state.activeFundedDebtPerShare = 0;
        state.activeImpairmentDebtPerShare = 0;
        state.activeFacePerShare = 0;
        state.activeFundingIndex = 0;
        state.activeImpairmentIndex = 0;
        state.unitScale = PROFIT_SCALE;
        state.epoch += 1;
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
        if (version != 2) revert FreshDeploymentRequired(version);
    }

    function _state() private view returns (ProfitStorage storage state) {
        bytes32 slot = _PROFIT_STORAGE_SLOT;
        assembly {
            state.slot := slot
        }
    }
}
