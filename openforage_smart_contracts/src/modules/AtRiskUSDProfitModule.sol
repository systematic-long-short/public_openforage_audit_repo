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
    error UnpaidProfitUnavailable(uint256 requested, uint256 outstanding);
    error YieldClaimsNotReady(address source);
    error YieldClaimsUnavailable(address source);
    error ZeroAmount();
    error ZeroSupplyYield();

    event UnpaidProfitClaimed(address indexed holder, uint256 amount);
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
    }

    uint256 private constant PROFIT_SCALE = 1e27;
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
        state.version = 1;
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
        _settle(state, entitlement, holder);
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

    function _settleAccount(ProfitStorage storage state, address account) private {
        if (account == address(0)) return;
        ProfitEntitlement storage entitlement = state.entitlements[account];
        _settle(state, entitlement, account);
    }

    function _settle(ProfitStorage storage state, ProfitEntitlement storage entitlement, address account) private {
        uint256 shares;
        if (account != address(this)) {
            IAtRiskUSDProfitHost host = IAtRiskUSDProfitHost(address(this));
            shares = host.balanceOf(account);
            (, uint256 pendingShares) = host.pendingWithdrawalAmount(account);
            shares += pendingShares;
        }
        if (entitlement.units != 0 && entitlement.activeEpoch < state.epoch) {
            if (shares == 0) {
                uint256 finalFunding = state.finalFundingIndex[entitlement.activeEpoch];
                uint256 finalImpairment = state.finalImpairmentIndex[entitlement.activeEpoch];
                uint256 funded = Math.mulDiv(entitlement.units, finalFunding, PROFIT_SCALE);
                uint256 impaired = Math.mulDiv(entitlement.units, finalImpairment, PROFIT_SCALE);
                if (funded > entitlement.activeFundedCheckpoint) {
                    entitlement.funded += funded - entitlement.activeFundedCheckpoint;
                }
                if (impaired > entitlement.activeImpairmentCheckpoint) {
                    entitlement.impaired += impaired - entitlement.activeImpairmentCheckpoint;
                }
            }
            entitlement.units = 0;
            entitlement.fundedDebt = 0;
            entitlement.impairmentDebt = 0;
            entitlement.activeFundedCheckpoint = 0;
            entitlement.activeImpairmentCheckpoint = 0;
            entitlement.activeEpoch = state.epoch;
            if (shares == 0) {
                entitlement.unitsIndex = state.activeUnitsPerShare;
                entitlement.fundedDebtIndex = state.activeFundedDebtPerShare;
                entitlement.impairmentDebtIndex = state.activeImpairmentDebtPerShare;
            } else {
                entitlement.unitsIndex = 0;
                entitlement.fundedDebtIndex = 0;
                entitlement.impairmentDebtIndex = 0;
            }
        }
        if (shares == 0 && entitlement.activeEpoch == state.epoch && entitlement.units != 0) {
            uint256 funded = Math.mulDiv(entitlement.units, state.activeFundingIndex, PROFIT_SCALE);
            uint256 impaired = Math.mulDiv(entitlement.units, state.activeImpairmentIndex, PROFIT_SCALE);
            if (funded > entitlement.activeFundedCheckpoint) {
                entitlement.funded += funded - entitlement.activeFundedCheckpoint;
            }
            if (impaired > entitlement.activeImpairmentCheckpoint) {
                entitlement.impaired += impaired - entitlement.activeImpairmentCheckpoint;
            }
            entitlement.activeFundedCheckpoint = funded;
            entitlement.activeImpairmentCheckpoint = impaired;
        }
        uint256 faceIndex = state.completedFacePerShare + state.activeFacePerShare;
        uint256 fundedIndex = state.completedFundedPerShare + _activeFundedPerShare(state);
        uint256 impairmentIndex = state.completedImpairedPerShare + _activeImpairedPerShare(state);
        if (shares != 0) {
            entitlement.face += Math.mulDiv(shares, faceIndex - entitlement.faceCheckpoint, PROFIT_SCALE);
            entitlement.funded += Math.mulDiv(shares, fundedIndex - entitlement.fundedCheckpoint, PROFIT_SCALE);
            entitlement.impaired +=
                Math.mulDiv(shares, impairmentIndex - entitlement.impairmentCheckpoint, PROFIT_SCALE);
            entitlement.units += Math.mulDiv(shares, state.activeUnitsPerShare - entitlement.unitsIndex, PROFIT_SCALE);
            entitlement.fundedDebt +=
                Math.mulDiv(shares, state.activeFundedDebtPerShare - entitlement.fundedDebtIndex, PROFIT_SCALE);
            entitlement.impairmentDebt +=
                Math.mulDiv(shares, state.activeImpairmentDebtPerShare - entitlement.impairmentDebtIndex, PROFIT_SCALE);
            entitlement.activeFundedCheckpoint = Math.mulDiv(entitlement.units, state.activeFundingIndex, PROFIT_SCALE);
            entitlement.activeImpairmentCheckpoint =
                Math.mulDiv(entitlement.units, state.activeImpairmentIndex, PROFIT_SCALE);
            entitlement.activeEpoch = state.epoch;
        }
        entitlement.faceCheckpoint = faceIndex;
        entitlement.fundedCheckpoint = fundedIndex;
        entitlement.impairmentCheckpoint = impairmentIndex;
        entitlement.unitsIndex = state.activeUnitsPerShare;
        entitlement.fundedDebtIndex = state.activeFundedDebtPerShare;
        entitlement.impairmentDebtIndex = state.activeImpairmentDebtPerShare;
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
        state.finalFundingIndex[state.epoch] = state.activeFundingIndex;
        state.finalImpairmentIndex[state.epoch] = state.activeImpairmentIndex;
        state.completedFacePerShare += state.activeFacePerShare;
        state.completedFundedPerShare += _activeFundedPerShare(state);
        state.completedImpairedPerShare += _activeImpairedPerShare(state);
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
        if (version != 1) revert FreshDeploymentRequired(version);
    }

    function _state() private view returns (ProfitStorage storage state) {
        bytes32 slot = _PROFIT_STORAGE_SLOT;
        assembly {
            state.slot := slot
        }
    }
}
