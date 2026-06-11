// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title MockTarget - Records calls for TimelockController testing
/// @notice A simple contract that stores call data for verification
contract MockTarget {
    uint256 public callCount;
    address public lastCaller;
    uint256 public lastValue;

    event TargetCalled(address indexed caller, uint256 value);

    function doSomething() external payable {
        callCount++;
        lastCaller = msg.sender;
        lastValue = msg.value;
        emit TargetCalled(msg.sender, msg.value);
    }

    function doSomethingWithArgs(uint256 arg1, address arg2) external {
        callCount++;
        lastCaller = msg.sender;
        emit TargetCalled(msg.sender, 0);
    }

    function getValue() external view returns (uint256) {
        return callCount;
    }
}
