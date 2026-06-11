// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/AtRISKUSDTestBase.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";

// ============================================================
// TC-15: Ownership Transfer Tests (R-38)
// ============================================================
contract AtRISKUSD_TC15_Ownership is AtRISKUSDTestBase {
    // ----- L3 Step 1: transferOwnership proposes newOwner -----
    function test_TC15_transferOwnershipProposes() public {
        vm.prank(owner);
        vault.transferOwnership(alice);

        assertEq(vault.pendingOwner(), alice, "pendingOwner should be alice after transferOwnership");
        // Owner should remain unchanged until acceptance
        assertEq(vault.owner(), owner, "owner should remain unchanged until acceptance");
    }

    // ----- L3 Step 2: Non-pending-owner cannot acceptOwnership -----
    function test_TC15_nonPendingOwnerCannotAccept() public {
        vm.prank(owner);
        vault.transferOwnership(alice);

        // Bob is not the pending owner
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, bob));
        vault.acceptOwnership();
    }

    // ----- L3 Step 3: Pending owner accepts, owner changes -----
    function test_TC15_pendingOwnerAcceptsOwnership() public {
        vm.prank(owner);
        vault.transferOwnership(alice);

        vm.prank(alice);
        vault.acceptOwnership();

        assertEq(vault.owner(), alice, "owner should be alice after acceptance");
        assertEq(vault.pendingOwner(), address(0), "pendingOwner should be cleared after acceptance");
    }

    // ----- L3 Step 4: Unauthorized transferOwnership reverts -----
    function test_TC15_unauthorizedTransferOwnershipReverts() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, attacker));
        vault.transferOwnership(attacker);
    }

    // ----- L3 Step 5: OwnershipTransferStarted event emitted -----
    function test_TC15_ownershipTransferStartedEvent() public {
        vm.expectEmit(true, true, false, false, address(vault));
        emit Ownable2StepUpgradeable.OwnershipTransferStarted(owner, alice);

        vm.prank(owner);
        vault.transferOwnership(alice);
    }

    // ----- L3 Step 5 (continued): OwnershipTransferred event emitted -----
    function test_TC15_ownershipTransferredEvent() public {
        vm.prank(owner);
        vault.transferOwnership(alice);

        vm.expectEmit(true, true, false, false, address(vault));
        emit OwnableUpgradeable.OwnershipTransferred(owner, alice);

        vm.prank(alice);
        vault.acceptOwnership();
    }

    // ----- L3 Step 6: renounceOwnership is disabled (OF-020) -----
    function test_TC15_renounceOwnership() public {
        vm.prank(owner);
        vm.expectRevert(atRISKUSD.RenounceOwnershipDisabled.selector);
        vault.renounceOwnership();

        assertEq(vault.owner(), owner, "owner should remain unchanged after disabled renounce");
    }

    // ----- L3 Step 6 (continued): renounceOwnership reverts so owner-only functions still work -----
    function test_TC15_ownerOnlyFunctionsRevertAfterRenounce() public {
        // renounceOwnership is disabled, so owner remains set
        vm.prank(owner);
        vm.expectRevert(atRISKUSD.RenounceOwnershipDisabled.selector);
        vault.renounceOwnership();

        // Owner is still set, so owner-only functions should still work for owner
        assertEq(vault.owner(), owner, "owner should remain unchanged");
    }

    // ----- L3 Step 7: Old owner cannot call owner-only functions after transfer -----
    function test_TC15_oldOwnerCannotCallAfterTransfer() public {
        // Transfer to alice
        vm.prank(owner);
        vault.transferOwnership(alice);

        vm.prank(alice);
        vault.acceptOwnership();

        // Old owner should be unauthorized
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, owner));
        vault.setYieldSource(makeAddr("newYS"));

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, owner));
        vault.setCooldownPeriod(0);

        // New owner should succeed
        vm.prank(alice);
        vault.setCooldownPeriod(14 days);
        assertEq(vault.cooldownPeriod(), 14 days, "new owner should be able to call setCooldownPeriod");
    }
}
