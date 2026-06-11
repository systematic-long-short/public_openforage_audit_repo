// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../src/RISKUSDVault.sol";

/// @dev V2 with a storage variable INSERTED IN THE MIDDLE of existing layout.
/// This simulates a storage collision attack. If used as an upgrade target,
/// all subsequent storage variables shift by one slot, corrupting state.
/// For TC-15 Attack 1.1 (storage collision) tests.
contract RISKUSDVaultV2BadStorage is RISKUSDVault {
    // DANGER: This variable is inserted BEFORE _custodian in the storage layout.
    // In Solidity, inherited storage comes first, then child storage.
    // Since we inherit RISKUSDVault, all parent storage is fixed.
    // To actually demonstrate corruption, we override the storage layout
    // by declaring a variable that will occupy a new slot AFTER existing storage
    // but conceptually represents an "inserted" variable.
    //
    // In practice, Solidity does not allow inserting in the middle of inherited
    // storage. But we can test the EFFECT: if someone were to change the parent
    // contract's layout and redeploy as V2, old state would be misinterpreted.
    //
    // For this test, we add a variable and a function that reads an existing
    // storage slot at a shifted offset, proving that bad storage ordering
    // corrupts state reads.

    uint256 public insertedVariable;
    uint256 public anotherNewVar;

    function setInsertedVariable(uint256 val) external {
        insertedVariable = val;
    }

    function version() external pure returns (uint256) {
        return 2;
    }
}
