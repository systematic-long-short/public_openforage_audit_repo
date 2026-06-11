// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Mock atRISKUSD tier vault for ProtocolTreasury tests.
/// Implements accrueYield(uint256), absorbLoss(uint256), totalAssets(), paused().
/// Configurable totalAssets, paused state, revert flags, call tracking.
contract MockProtocolTreasuryAtRISKUSD {
    IERC20 public riskusd;
    uint256 public mockTotalAssets;
    uint256 public mockTotalSupply;
    uint256 public mockPendingCooldownShares;
    bool public mockPaused;

    // Revert controls
    bool public shouldRevertAccrueYield;
    bool public shouldRevertAbsorbLoss;

    // Call tracking
    struct AccrueYieldCall {
        uint256 riskusdAmount;
    }

    struct AbsorbLossCall {
        uint256 riskusdAmount;
    }

    AccrueYieldCall[] public accrueYieldCalls;
    AbsorbLossCall[] public absorbLossCalls;

    constructor(address riskusd_) {
        riskusd = IERC20(riskusd_);
    }

    /// @dev Accrue yield (RISKUSD transferred from caller).
    function accrueYield(uint256 riskusdAmount) external {
        if (shouldRevertAccrueYield) revert("MockTierVault: accrueYield reverted");
        // Pull RISKUSD from caller
        riskusd.transferFrom(msg.sender, address(this), riskusdAmount);
        mockTotalAssets += riskusdAmount;
        accrueYieldCalls.push(AccrueYieldCall(riskusdAmount));
    }

    /// @dev Absorb loss (reduces totalAssets).
    function absorbLoss(uint256 riskusdAmount) external {
        if (shouldRevertAbsorbLoss) revert("MockTierVault: absorbLoss reverted");
        if (riskusdAmount <= mockTotalAssets) {
            mockTotalAssets -= riskusdAmount;
        } else {
            mockTotalAssets = 0;
        }
        absorbLossCalls.push(AbsorbLossCall(riskusdAmount));
    }

    function totalAssets() external view returns (uint256) {
        return mockTotalAssets;
    }

    function totalSupply() external view returns (uint256) {
        return mockTotalSupply;
    }

    function balanceOf(address account) external view returns (uint256) {
        return account == address(this) ? mockPendingCooldownShares : 0;
    }

    function legitimateAssets() external view returns (uint256) {
        return mockTotalAssets;
    }

    function paused() external view returns (bool) {
        return mockPaused;
    }

    // ── Configuration helpers ──
    function setMockTotalAssets(uint256 amount) external {
        mockTotalAssets = amount;
        mockTotalSupply = amount;
    }

    function setMockTotalSupply(uint256 amount) external {
        mockTotalSupply = amount;
    }

    function setMockPendingCooldownShares(uint256 amount) external {
        mockPendingCooldownShares = amount;
    }

    function setMockPaused(bool paused_) external {
        mockPaused = paused_;
    }

    function setShouldRevertAccrueYield(bool flag) external {
        shouldRevertAccrueYield = flag;
    }

    function setShouldRevertAbsorbLoss(bool flag) external {
        shouldRevertAbsorbLoss = flag;
    }

    // ── Call count helpers ──
    function accrueYieldCallCount() external view returns (uint256) {
        return accrueYieldCalls.length;
    }

    function absorbLossCallCount() external view returns (uint256) {
        return absorbLossCalls.length;
    }
}
