// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./MockForageTokenLocking.sol";

/// @title MockSecondaryLocker
/// @dev Simulates an independent second authorized locker on ForageToken.
///      Used in TC-22 (dual-locker scenario) to verify StakingQueue's per-entry
///      tracking is independent from other lockers' aggregate locks.
contract MockSecondaryLocker {
    MockForageTokenLocking public forageToken;

    constructor(address forage_) {
        forageToken = MockForageTokenLocking(forage_);
    }

    /// @notice Lock FORAGE from an independent authorized locker.
    function lockExternal(address account, uint256 amount) external {
        forageToken.lock(account, amount);
    }

    /// @notice Unlock FORAGE from an independent authorized locker.
    function unlockExternal(address account, uint256 amount) external {
        forageToken.unlock(account, amount);
    }
}
