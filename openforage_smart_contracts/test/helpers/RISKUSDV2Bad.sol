// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../src/RISKUSD.sol";

/// @dev Intentionally bad V2 with a storage variable inserted BEFORE existing state.
/// This simulates a storage collision: `badInsertedVar` occupies the slot where `_minter` was,
/// pushing `_minter` and `_forageGovernor` to different slots and corrupting state.
contract RISKUSDV2Bad is RISKUSD {
    // Inserted BEFORE existing storage -- causes collision with _minter slot
    uint256 public badInsertedVar;

    function version() external pure returns (uint256) {
        return 2;
    }
}
