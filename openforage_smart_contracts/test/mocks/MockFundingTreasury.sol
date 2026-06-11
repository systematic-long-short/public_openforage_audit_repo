// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Mock FundingTreasury for ProtocolTreasury tests.
/// Simple receiver that tracks USDC received.
contract MockFundingTreasury {
    IERC20 public usdc;
    uint256 public totalReceived;

    struct ReceiveCall {
        uint256 amount;
    }
    ReceiveCall[] public receiveCalls;

    constructor(address usdc_) {
        usdc = IERC20(usdc_);
    }

    /// @dev Track how much USDC was transferred to this contract.
    /// Call after an expected transfer to record receipt.
    function recordReceived(uint256 amount) external {
        totalReceived += amount;
        receiveCalls.push(ReceiveCall(amount));
    }

    function receiveCallCount() external view returns (uint256) {
        return receiveCalls.length;
    }

    /// @dev Get current USDC balance of this contract.
    function balance() external view returns (uint256) {
        return usdc.balanceOf(address(this));
    }
}
