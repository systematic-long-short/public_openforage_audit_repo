// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title MockWithdrawable - Minimal mock for depositor exit flow testing
/// @dev Simulates the 3-step exit: requestWithdrawal (7-day cooldown) -> executeWithdrawal -> redeem
contract MockWithdrawable {
    uint256 public constant COOLDOWN = 7 days;

    mapping(address => uint256) public withdrawalRequestTime;
    mapping(address => bool) public hasExecutedWithdrawal;
    mapping(address => bool) public hasRedeemed;

    function requestWithdrawal() external {
        withdrawalRequestTime[msg.sender] = block.timestamp;
    }

    function executeWithdrawal() external {
        require(withdrawalRequestTime[msg.sender] > 0, "No withdrawal requested");
        require(block.timestamp >= withdrawalRequestTime[msg.sender] + COOLDOWN, "Cooldown not met");
        hasExecutedWithdrawal[msg.sender] = true;
    }

    function redeem() external {
        require(hasExecutedWithdrawal[msg.sender], "Must execute withdrawal first");
        hasRedeemed[msg.sender] = true;
    }
}
