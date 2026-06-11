// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title MockOwnable - Simple ownable contract for TimelockController ownership testing
contract MockOwnable {
    address public owner;
    uint256 public protectedValue;

    error OwnableUnauthorizedAccount(address account);

    event ValueChanged(uint256 oldValue, uint256 newValue);

    constructor(address _owner) {
        owner = _owner;
    }

    function setProtectedValue(uint256 newValue) external {
        if (msg.sender != owner) {
            revert OwnableUnauthorizedAccount(msg.sender);
        }
        uint256 oldValue = protectedValue;
        protectedValue = newValue;
        emit ValueChanged(oldValue, newValue);
    }
}
