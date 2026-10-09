// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IRISKUSDVaultNAV {
    function adjustedCustodianNAV() external view returns (uint256);
    function lastAttestedNAV() external view returns (uint256);
    function lastAttestationTimestamp() external view returns (uint256);
    function attestationIntervalSeconds() external view returns (uint256);
    function totalDeployed() external view returns (uint256);
}

interface IUSDCTreasuryRoleState {
    function pnlAttestor() external view returns (address);
    function hlTradingBridge() external view returns (address);
}

interface IUSDCTreasuryRoleBridge {
    function keeper() external view returns (address);
    function pendingKeeper() external view returns (address);
    function custodianRegistry() external view returns (address);
    function usdcTreasury() external view returns (address);
}

interface IUSDCTreasuryRoleRegistry {
    function hasActiveExecutor(address account) external view returns (bool);
}

interface IUSDCTreasuryProfitPolicyHost {
    function blocklist() external view returns (address);
    function distributor() external view returns (address);
}

interface IUSDCTreasuryProfitPolicyBlocklist {
    function isBlocked(address account) external view returns (bool);
}

contract USDCTreasuryProfitPolicyModule {
    uint256 private constant SECONDS_PER_DAY = 86_400;
    uint8 private constant PNL_POLICY_RECOGNITION = 0;
    uint8 private constant PNL_POLICY_LOSS = 1;
    uint8 private constant PNL_POLICY_RETURN = 2;

    error DelegateCallRequired();
    error SettlementValueMismatch(address account, uint256 expected, uint256 actual);
    error CustodianNAVNotFresh(address vault, uint256 attestedAt, uint256 currentTime, uint256 interval);
    error ProfitRecognitionExceedsNAVHeadroom(uint256 requested, uint256 available);
    error LossExceedsUnreturnedProfit(uint256 requested, uint256 available);
    error PnLReturnExceedsNAVHeadroom(uint256 requested, uint256 available);
    error AgentPayWindowClosed(uint256 currentTime);
    error AgentPayTotalInvariant(uint256 credited, uint256 paid);
    error AgentPayLifetimeCapExceeded(uint256 credited, uint256 paid, uint256 requested, uint256 remaining);
    error TreasuryRoleCollision(address account, address conflictingAccount);
    error RoleSourceUnavailable(address source);
    error BlockedRecipient(address account);
    error BlocklistUnavailable(address blocklist);

    address private immutable _self;

    constructor() {
        _self = address(this);
    }

    modifier onlyDelegateCall() {
        if (address(this) == _self) revert DelegateCallRequired();
        _;
    }

    function updatePnLAccounting(
        address vault,
        uint256 amount,
        uint256 localUnreturned,
        uint256 aggregateSlot,
        uint8 mode
    ) external onlyDelegateCall {
        if (mode == PNL_POLICY_RECOGNITION || mode == PNL_POLICY_LOSS) {
            _requireNotBlocked(address(this), msg.sender);
        }
        if (mode == PNL_POLICY_RECOGNITION || mode == PNL_POLICY_LOSS) _requireRoleSeparation();
        (uint256 nav, uint256 principal, uint256 reportTimestamp) = _freshNAV(vault);
        uint256 reportSlot = aggregateSlot + 1;
        uint256 cashOutSlot = aggregateSlot + 2;
        uint256 aggregateUnreturned;
        uint256 storedReport;
        uint256 reportCashOut;
        assembly {
            aggregateUnreturned := sload(aggregateSlot)
            storedReport := sload(reportSlot)
            reportCashOut := sload(cashOutSlot)
        }
        if (storedReport != reportTimestamp) {
            storedReport = reportTimestamp;
            reportCashOut = 0;
            assembly {
                sstore(reportSlot, storedReport)
                sstore(cashOutSlot, 0)
            }
        }
        uint256 navExcess = nav > principal ? nav - principal : 0;
        uint256 available;
        if (mode == PNL_POLICY_RECOGNITION) {
            available = navExcess > aggregateUnreturned ? navExcess - aggregateUnreturned : 0;
            available = available > reportCashOut ? available - reportCashOut : 0;
            if (amount > available) revert ProfitRecognitionExceedsNAVHeadroom(amount, available);
            aggregateUnreturned += amount;
            assembly {
                sstore(aggregateSlot, aggregateUnreturned)
            }
        } else if (mode == PNL_POLICY_LOSS) {
            available = aggregateUnreturned > navExcess ? aggregateUnreturned - navExcess : 0;
            if (available > localUnreturned) available = localUnreturned;
            if (amount > available) revert LossExceedsUnreturnedProfit(amount, available);
            aggregateUnreturned -= amount;
            assembly {
                sstore(aggregateSlot, aggregateUnreturned)
            }
        } else if (mode == PNL_POLICY_RETURN) {
            available = navExcess > reportCashOut ? navExcess - reportCashOut : 0;
            if (amount > available) revert PnLReturnExceedsNAVHeadroom(amount, available);
            if (amount > aggregateUnreturned) {
                revert SettlementValueMismatch(vault, amount, aggregateUnreturned);
            }
            aggregateUnreturned -= amount;
            reportCashOut += amount;
            assembly {
                sstore(aggregateSlot, aggregateUnreturned)
                sstore(cashOutSlot, reportCashOut)
            }
        } else {
            revert SettlementValueMismatch(vault, PNL_POLICY_RETURN, mode);
        }
    }

    function _requireRoleSeparation() private view {
        IUSDCTreasuryRoleState treasury = IUSDCTreasuryRoleState(address(this));
        address attestor = treasury.pnlAttestor();
        address bridge = treasury.hlTradingBridge();
        if (bridge.code.length == 0) revert RoleSourceUnavailable(bridge);
        IUSDCTreasuryRoleBridge bridgeRole = IUSDCTreasuryRoleBridge(bridge);
        if (bridgeRole.usdcTreasury() != address(this)) revert RoleSourceUnavailable(bridge);
        address registry = bridgeRole.custodianRegistry();
        if (registry.code.length == 0) revert RoleSourceUnavailable(registry);

        address keeper = bridgeRole.keeper();
        address pendingKeeper = bridgeRole.pendingKeeper();
        _requireDistinct(attestor, keeper);
        _requireDistinct(attestor, pendingKeeper);
        _requireNotExecutor(registry, attestor);
        _requireNotExecutor(registry, keeper);
        _requireNotExecutor(registry, pendingKeeper);
    }

    function _requireDistinct(address attestor, address keeper) private pure {
        if (attestor != address(0) && attestor == keeper) {
            revert TreasuryRoleCollision(attestor, keeper);
        }
    }

    function _requireNotExecutor(address registry, address account) private view {
        if (account == address(0)) return;
        if (IUSDCTreasuryRoleRegistry(registry).hasActiveExecutor(account)) {
            revert TreasuryRoleCollision(account, registry);
        }
    }

    function nextAgentPayDisbursedTotal(address caller, uint256 credited, uint256 paid, uint256[] calldata amounts)
        external
        view
        returns (uint256 nextPaid)
    {
        address treasury = msg.sender;
        if (caller == IUSDCTreasuryProfitPolicyHost(treasury).distributor()) {
            _requireNotBlocked(treasury, caller);
        }
        if (!_agentPayWindowOpen(block.timestamp)) revert AgentPayWindowClosed(block.timestamp);
        if (paid > credited) revert AgentPayTotalInvariant(credited, paid);
        uint256 remaining = credited - paid;
        uint256 requested;
        for (uint256 i; i < amounts.length; ++i) {
            uint256 amount = amounts[i];
            if (amount > remaining - requested) {
                revert AgentPayLifetimeCapExceeded(credited, paid, amount, remaining - requested);
            }
            requested += amount;
        }
        nextPaid = paid + requested;
    }

    function _requireNotBlocked(address treasury, address account) private view {
        address blocklist_ = IUSDCTreasuryProfitPolicyHost(treasury).blocklist();
        if (blocklist_ == address(0)) revert BlocklistUnavailable(blocklist_);
        bool blocked;
        try IUSDCTreasuryProfitPolicyBlocklist(blocklist_).isBlocked(account) returns (bool result) {
            blocked = result;
        } catch {
            revert BlocklistUnavailable(blocklist_);
        }
        if (blocked) revert BlockedRecipient(account);
    }

    function _freshNAV(address vault) private view returns (uint256 nav, uint256 principal, uint256 attestedAt) {
        IRISKUSDVaultNAV source = IRISKUSDVaultNAV(vault);
        uint256 currentTime = block.timestamp;
        attestedAt = source.lastAttestationTimestamp();
        uint256 interval = source.attestationIntervalSeconds();
        if (attestedAt > currentTime || currentTime - attestedAt > interval) {
            revert CustodianNAVNotFresh(vault, attestedAt, currentTime, interval);
        }
        nav = source.adjustedCustodianNAV();
        principal = source.totalDeployed();
    }

    function _agentPayWindowOpen(uint256 timestamp) private pure returns (bool) {
        uint256 daysSinceEpoch = timestamp / SECONDS_PER_DAY;
        uint256 shiftedDays = daysSinceEpoch + 719_468;
        uint256 era = shiftedDays / 146_097;
        uint256 dayOfEra = shiftedDays - era * 146_097;
        uint256 yearOfEra = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365;
        uint256 dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100);
        uint256 monthPrime = (5 * dayOfYear + 2) / 153;
        uint256 dayOfMonth = dayOfYear - (153 * monthPrime + 2) / 5 + 1;
        uint256 month = monthPrime < 10 ? monthPrime + 3 : monthPrime - 9;
        return dayOfMonth <= 14 && (month == 1 || month == 4 || month == 7 || month == 10);
    }
}
