// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Mock ForageToken that returns configurable lockedBalance values.
/// Used by StakingQueue tests for priority lane routing.
/// Supports active locking with per-locker namespace: lock() and unlock() track per-locker balances.
contract MockForageTokenLocked is ERC20 {
    mapping(address => uint256) private _lockedBalances;
    mapping(address => mapping(address => uint256)) private _lockerBalances;

    constructor() ERC20("Forage Token", "FORAGE") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setLockedBalance(address account, uint256 amount) external {
        _lockedBalances[account] = amount;
    }

    function lockedBalance(address account) external view returns (uint256) {
        return _lockedBalances[account];
    }

    function lockerBalance(address account, address locker) external view returns (uint256) {
        return _lockerBalances[account][locker];
    }

    /// @dev Active locking support: lock amount for account (per-locker tracking).
    /// Requires sufficient unlocked balance (balanceOf - lockedBalance >= amount).
    function lock(address account, uint256 amount) external {
        uint256 unlocked = balanceOf(account) - _lockedBalances[account];
        require(unlocked >= amount, "MockForageTokenLocked: insufficient unlocked");
        _lockedBalances[account] += amount;
        _lockerBalances[account][msg.sender] += amount;
    }

    /// @dev Active unlocking support: unlock amount for account (per-locker enforcement).
    /// Checks per-locker balance if set (normal lock flow), falls back to aggregate
    /// if per-locker is zero (for tests using setLockedBalance to bypass lock()).
    function unlock(address account, uint256 amount) external {
        uint256 perLocker = _lockerBalances[account][msg.sender];
        if (perLocker > 0) {
            require(perLocker >= amount, "MockForageTokenLocked: insufficient per-locker locked");
            _lockerBalances[account][msg.sender] -= amount;
        } else {
            require(_lockedBalances[account] >= amount, "MockForageTokenLocked: insufficient locked");
        }
        _lockedBalances[account] -= amount;
    }
}
