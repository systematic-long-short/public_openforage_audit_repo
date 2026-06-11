// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/VaultRegistryTestBase.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";

// ============================================================
// TC-09: Access Control + Ownable2Step Ownership Transfer
// Requirements: R-52, R-53, R-54
// ============================================================
contract VaultRegistry_TC09_AccessControl is VaultRegistryTestBase {
    address internal newOwner;

    function setUp() public override {
        super.setUp();
        newOwner = makeAddr("newOwner");
    }

    // ---- Owner-only function access control (steps 1-6) ----

    /// @dev TC-09 step 1: Non-owner calls addVault -- MUST revert OwnableUnauthorizedAccount.
    function test_TC09_nonOwnerCannotAddVault() public {
        (
            string memory name,
            string memory abbreviation,
            address[4] memory tierVaults,
            address stakingQueue,
            uint256 capacityCap,
            uint256[4] memory lockupDurations,
            uint16[4] memory yieldSplitsBps,
            uint16[4] memory fundingBps
        ) = _createDefaultVaultParams();

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, attacker));
        registry.addVault(
            name, abbreviation, tierVaults, stakingQueue, capacityCap, lockupDurations, yieldSplitsBps, fundingBps
        );
    }

    /// @dev TC-09 step 2: Non-owner calls pauseVault -- MUST revert OwnableUnauthorizedAccount.
    function test_TC09_nonOwnerCannotPauseVault() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, attacker));
        registry.pauseVault(1);
    }

    /// @dev TC-09 step 3: Non-owner calls startWindDown -- MUST revert OwnableUnauthorizedAccount.
    function test_TC09_nonOwnerCannotStartWindDown() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, attacker));
        registry.startWindDown(1);
    }

    /// @dev TC-09 step 4: Non-owner calls setCapacityCap -- MUST revert OwnableUnauthorizedAccount.
    function test_TC09_nonOwnerCannotSetCapacityCap() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, attacker));
        registry.setCapacityCap(1, 5000);
    }

    /// @dev TC-09 step 5: Non-owner calls setYieldSplits -- MUST revert OwnableUnauthorizedAccount.
    function test_TC09_nonOwnerCannotSetYieldSplits() public {
        uint16[4] memory yieldBps = [uint16(5000), uint16(5000), uint16(5000), uint16(5000)];
        uint16[4] memory fundBps = [uint16(5000), uint16(5000), uint16(5000), uint16(5000)];

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, attacker));
        registry.setYieldSplits(1, yieldBps, fundBps);
    }

    /// @dev TC-09 step 6: Non-owner calls upgradeToAndCall -- MUST revert OwnableUnauthorizedAccount.
    function test_TC09_nonOwnerCannotUpgrade() public {
        VaultRegistry newImpl = new VaultRegistry();

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, attacker));
        registry.upgradeToAndCall(address(newImpl), "");
    }

    /// @dev TC-09 step 7: Non-owner calls transferOwnership -- MUST revert OwnableUnauthorizedAccount.
    function test_TC09_nonOwnerCannotTransferOwnership() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, attacker));
        registry.transferOwnership(attacker);
    }

    // ---- Two-step ownership transfer (steps 8-11) ----

    /// @dev TC-09 step 8: transferOwnership sets pendingOwner, owner unchanged.
    function test_TC09_transferOwnershipSetsPendingOwner() public {
        vm.prank(owner);
        registry.transferOwnership(newOwner);

        assertEq(registry.pendingOwner(), newOwner, "pendingOwner should be newOwner after transferOwnership");
        assertEq(registry.owner(), owner, "owner should still be original owner before acceptance");
    }

    /// @dev TC-09 step 9: newOwner calls acceptOwnership, becomes owner, pendingOwner cleared.
    function test_TC09_acceptOwnershipSucceeds() public {
        vm.prank(owner);
        registry.transferOwnership(newOwner);

        vm.prank(newOwner);
        registry.acceptOwnership();

        assertEq(registry.owner(), newOwner, "owner should be newOwner after acceptance");
        assertEq(registry.pendingOwner(), address(0), "pendingOwner should be cleared after acceptance");
    }

    /// @dev TC-09 step 13: Non-pendingOwner calls acceptOwnership -- MUST revert.
    function test_TC09_nonPendingOwnerCannotAccept() public {
        vm.prank(owner);
        registry.transferOwnership(newOwner);

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, attacker));
        registry.acceptOwnership();
    }

    /// @dev OF-020: renounceOwnership is disabled and reverts for any caller.
    function test_TC09_renounceOwnership() public {
        vm.prank(owner);
        vm.expectRevert(VaultRegistry.RenounceOwnershipDisabled.selector);
        registry.renounceOwnership();

        assertEq(registry.owner(), owner, "owner should remain unchanged after disabled renounce");
    }

    /// @dev OF-020: Since renounceOwnership is disabled, owner-only functions remain accessible.
    function test_TC09_afterRenounceAllOwnerFunctionsRevert() public {
        // renounceOwnership is disabled, so this just verifies the revert
        vm.prank(owner);
        vm.expectRevert(VaultRegistry.RenounceOwnershipDisabled.selector);
        registry.renounceOwnership();

        // Owner is still set, so owner-only functions should still work
        assertEq(registry.owner(), owner, "owner should remain unchanged");
    }

    /// @dev TC-09 step 12: Owner overwrites pending transfer before acceptance.
    ///      First proposed owner can no longer accept.
    function test_TC09_overwritePendingOwner() public {
        address differentOwner = makeAddr("differentOwner");

        vm.prank(owner);
        registry.transferOwnership(newOwner);
        assertEq(registry.pendingOwner(), newOwner, "pendingOwner should be newOwner");

        // Owner overwrites with a different pending owner
        vm.prank(owner);
        registry.transferOwnership(differentOwner);
        assertEq(registry.pendingOwner(), differentOwner, "pendingOwner should be differentOwner after overwrite");

        // Original newOwner can no longer accept
        vm.prank(newOwner);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, newOwner));
        registry.acceptOwnership();

        // differentOwner can accept
        vm.prank(differentOwner);
        registry.acceptOwnership();
        assertEq(registry.owner(), differentOwner, "owner should be differentOwner after acceptance");
    }

    /// @dev TC-09 steps 10-11: After ownership transfer, old owner cannot call owner-only,
    ///      new owner can.
    function test_TC09_afterTransferOldOwnerFailsNewOwnerWorks() public {
        vm.prank(owner);
        registry.transferOwnership(newOwner);

        vm.prank(newOwner);
        registry.acceptOwnership();

        // Old owner cannot call addVault
        (
            string memory name,
            string memory abbreviation,
            address[4] memory tierVaults,
            address stakingQueue,
            uint256 capacityCap,
            uint256[4] memory lockupDurations,
            uint16[4] memory yieldSplitsBps,
            uint16[4] memory fundingBps
        ) = _createDefaultVaultParams();

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, owner));
        registry.addVault(
            name, abbreviation, tierVaults, stakingQueue, capacityCap, lockupDurations, yieldSplitsBps, fundingBps
        );

        // New owner can call addVault
        vm.prank(newOwner);
        uint256 vaultId = registry.addVault(
            name, abbreviation, tierVaults, stakingQueue, capacityCap, lockupDurations, yieldSplitsBps, fundingBps
        );
        assertGt(vaultId, 0, "New owner should be able to add vault");
    }

    /// @dev OF-020: renounceOwnership is disabled, but view functions always work regardless.
    function test_TC09_afterRenounceViewsStillWork() public {
        // Add a vault before attempting renounce
        uint256 vaultId = _addDefaultVault();

        // renounceOwnership is disabled
        vm.prank(owner);
        vm.expectRevert(VaultRegistry.RenounceOwnershipDisabled.selector);
        registry.renounceOwnership();

        // View functions still work (owner unchanged)
        VaultConfig memory config = registry.getVault(vaultId);
        assertEq(config.vaultId, vaultId, "getVault should still work");

        uint256[] memory activeVaults = registry.getActiveVaults();
        assertEq(activeVaults.length, 1, "getActiveVaults should still work");

        uint256[] memory allVaults = registry.getAllVaults();
        assertEq(allVaults.length, 1, "getAllVaults should still work");

        assertEq(registry.vaultCount(), 1, "vaultCount should still work");
    }
}
