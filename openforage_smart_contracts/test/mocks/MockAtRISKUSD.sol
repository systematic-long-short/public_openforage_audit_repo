// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Mock atRISKUSD tier vault for StakingQueue tests.
/// Tracks calls to deposit, redeemForUpgrade, redeemForReversion, renewLockup.
/// Supports configurable totalAssets, revert triggers, and lockup state.
contract MockAtRISKUSD {
    IERC20 public riskusd;
    uint256 public mockTotalAssets;
    uint256 public mockLegitimateAssets;
    uint256 public mockTotalSupply;

    // Deposit return control
    bool public useCustomDepositReturn;
    uint256 public customDepositReturnShares;

    // Revert controls
    bool public shouldRevertDeposit;
    bool public shouldRevertRedeemForUpgrade;
    bool public shouldRevertRedeemForReversion;
    bool public shouldRevertRenewLockup;
    address public authorizedQueue; // when non-zero, only this address can call restricted functions

    // Lockup state per depositor
    struct LockupInfo {
        bool hasLockup;
        bool isExpired;
        bool autoRenew;
        bool hasPendingWithdrawal;
        uint256 shares;
    }
    mapping(address => LockupInfo) public lockups;

    // Call tracking
    struct DepositCall {
        uint256 riskusdAmount;
        address depositor;
    }

    struct RedeemForUpgradeCall {
        address depositor;
        uint256 atriskusdAmount;
    }

    struct RedeemForReversionCall {
        address depositor;
        uint256 shares;
    }
    address[] public renewLockupCalls;

    DepositCall[] public depositCalls;
    RedeemForUpgradeCall[] public redeemForUpgradeCalls;
    RedeemForReversionCall[] public redeemForReversionCalls;

    // Return values
    uint256 public redeemForUpgradeReturnAmount;
    uint256 public redeemForReversionReturnAmount;
    uint256 public renewLockupReturnExpiry;

    error UnauthorizedStakingQueue();

    constructor(address riskusd_) {
        riskusd = IERC20(riskusd_);
        redeemForUpgradeReturnAmount = 1e6; // default 1 RISKUSD
        redeemForReversionReturnAmount = 1e6;
        renewLockupReturnExpiry = block.timestamp + 365 days;
    }

    function deposit(uint256 riskusdAmount, address depositor) external returns (uint256) {
        if (shouldRevertDeposit) revert("MockAtRISKUSD: deposit reverted");
        depositCalls.push(DepositCall(riskusdAmount, depositor));
        mockTotalAssets += riskusdAmount;
        mockLegitimateAssets += riskusdAmount;
        // Transfer RISKUSD from caller to this vault
        riskusd.transferFrom(msg.sender, address(this), riskusdAmount);
        uint256 shares = useCustomDepositReturn ? customDepositReturnShares : riskusdAmount;
        mockTotalSupply += shares;
        return shares; // 1:1 shares by default for simplicity
    }

    function redeemForUpgrade(address depositor, uint256 atriskusdAmount) external returns (uint256) {
        if (shouldRevertRedeemForUpgrade) revert("MockAtRISKUSD: redeemForUpgrade reverted");
        redeemForUpgradeCalls.push(RedeemForUpgradeCall(depositor, atriskusdAmount));
        uint256 riskusdAmount = redeemForUpgradeReturnAmount;
        if (mockTotalAssets >= riskusdAmount) {
            mockTotalAssets -= riskusdAmount;
        }
        _decreaseMockSupply(atriskusdAmount);
        _decreaseMockLegitimateAssets(riskusdAmount);
        // Transfer RISKUSD back to caller (StakingQueue)
        riskusd.transfer(msg.sender, riskusdAmount);
        return riskusdAmount;
    }

    function redeemForReversion(address depositor, uint256 shares) external returns (uint256) {
        if (authorizedQueue != address(0) && msg.sender != authorizedQueue) {
            revert("MockAtRISKUSD: restricted to queue");
        }
        if (shouldRevertRedeemForReversion) revert("MockAtRISKUSD: redeemForReversion reverted");
        redeemForReversionCalls.push(RedeemForReversionCall(depositor, shares));
        uint256 riskusdAmount = redeemForReversionReturnAmount;
        if (mockTotalAssets >= riskusdAmount) {
            mockTotalAssets -= riskusdAmount;
        }
        _decreaseMockSupply(shares);
        _decreaseMockLegitimateAssets(riskusdAmount);
        riskusd.transfer(msg.sender, riskusdAmount);
        return riskusdAmount;
    }

    function renewLockup(address depositor) external returns (uint256) {
        if (authorizedQueue != address(0) && msg.sender != authorizedQueue) {
            revert("MockAtRISKUSD: restricted to queue");
        }
        if (shouldRevertRenewLockup) revert("MockAtRISKUSD: renewLockup reverted");
        renewLockupCalls.push(depositor);
        return renewLockupReturnExpiry;
    }

    function totalAssets() external view returns (uint256) {
        return mockTotalAssets;
    }

    function totalSupply() external view returns (uint256) {
        return mockTotalSupply;
    }

    function legitimateAssets() external view returns (uint256) {
        return mockLegitimateAssets;
    }

    // ── Configuration helpers ──
    function setMockTotalAssets(uint256 amount) external {
        mockTotalAssets = amount;
        mockLegitimateAssets = amount;
    }

    function setMockLegitimateAssets(uint256 amount) external {
        mockLegitimateAssets = amount;
    }

    function setCustomDepositReturn(bool enabled, uint256 shares) external {
        useCustomDepositReturn = enabled;
        customDepositReturnShares = shares;
    }

    function setShouldRevertDeposit(bool flag) external {
        shouldRevertDeposit = flag;
    }

    function setShouldRevertRedeemForUpgrade(bool flag) external {
        shouldRevertRedeemForUpgrade = flag;
    }

    function setShouldRevertRedeemForReversion(bool flag) external {
        shouldRevertRedeemForReversion = flag;
    }

    function setShouldRevertRenewLockup(bool flag) external {
        shouldRevertRenewLockup = flag;
    }

    function setAuthorizedQueue(address queue_) external {
        authorizedQueue = queue_;
    }

    function setRedeemForUpgradeReturnAmount(uint256 amount) external {
        redeemForUpgradeReturnAmount = amount;
    }

    function setRedeemForReversionReturnAmount(uint256 amount) external {
        redeemForReversionReturnAmount = amount;
    }

    function setRenewLockupReturnExpiry(uint256 expiry) external {
        renewLockupReturnExpiry = expiry;
    }

    function setLockupInfo(
        address depositor,
        bool hasLockup_,
        bool isExpired_,
        bool autoRenew_,
        bool hasPendingWithdrawal_,
        uint256 shares_
    ) external {
        uint256 oldShares = lockups[depositor].hasLockup ? lockups[depositor].shares : 0;
        uint256 newShares = hasLockup_ ? shares_ : 0;
        if (newShares > oldShares) {
            mockTotalSupply += newShares - oldShares;
        } else if (oldShares > newShares) {
            _decreaseMockSupply(oldShares - newShares);
        }
        lockups[depositor] = LockupInfo(hasLockup_, isExpired_, autoRenew_, hasPendingWithdrawal_, shares_);
    }

    function _decreaseMockSupply(uint256 shares) internal {
        mockTotalSupply = mockTotalSupply >= shares ? mockTotalSupply - shares : 0;
    }

    function _decreaseMockLegitimateAssets(uint256 assets) internal {
        mockLegitimateAssets = mockLegitimateAssets >= assets ? mockLegitimateAssets - assets : 0;
    }

    // Call count helpers
    function depositCallCount() external view returns (uint256) {
        return depositCalls.length;
    }

    function redeemForUpgradeCallCount() external view returns (uint256) {
        return redeemForUpgradeCalls.length;
    }

    function redeemForReversionCallCount() external view returns (uint256) {
        return redeemForReversionCalls.length;
    }

    function renewLockupCallCount() external view returns (uint256) {
        return renewLockupCalls.length;
    }
}
