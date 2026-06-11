// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Simple ERC-20 mock with delegate() recording for DelegatingVestingWallet tests.
/// Records the last delegate call so tests can verify delegation behavior.
contract MockForageTokenSimple is ERC20 {
    address private _lastDelegatee;
    uint256 private _delegateCallCount;
    mapping(address => address) private _delegates;

    constructor() ERC20("Forage Token", "FORAGE") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @dev Records the delegatee for test verification. Does not track voting power.
    function delegate(address delegatee_) external {
        _delegates[msg.sender] = delegatee_;
        _lastDelegatee = delegatee_;
        _delegateCallCount++;
    }

    function delegates(address account) external view returns (address) {
        return _delegates[account];
    }

    /// @dev Returns the last address passed to delegate().
    function lastDelegatee() external view returns (address) {
        return _lastDelegatee;
    }

    /// @dev Returns the number of times delegate() was called.
    function delegateCallCount() external view returns (uint256) {
        return _delegateCallCount;
    }
}
