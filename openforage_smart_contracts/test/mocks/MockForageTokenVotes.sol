// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/utils/Nonces.sol";

/// @dev Full ERC20Votes mock for voting power integration tests (TC-12).
/// Provides actual voting power tracking via delegate() and getVotes().
contract MockForageTokenVotes is ERC20, ERC20Permit, ERC20Votes {
    constructor() ERC20("Forage Token", "FORAGE") ERC20Permit("Forage Token") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    /// @dev Override delegateBySig to always revert (simulating ForageToken's disabled delegateBySig)
    function delegateBySig(address, uint256, uint256, uint8, bytes32, bytes32) public pure override {
        revert("delegateBySig disabled");
    }

    // Required overrides for ERC20 + ERC20Votes
    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Votes) {
        super._update(from, to, value);
    }

    function nonces(address owner_) public view override(ERC20Permit, Nonces) returns (uint256) {
        return super.nonces(owner_);
    }
}
