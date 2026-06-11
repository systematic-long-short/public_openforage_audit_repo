// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title RevertTarget - Always reverts on calls for TimelockController testing
contract RevertTarget {
    error AlwaysReverts();

    function doSomething() external pure {
        revert AlwaysReverts();
    }
}
