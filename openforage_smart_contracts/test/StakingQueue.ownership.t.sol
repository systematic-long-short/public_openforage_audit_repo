// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/StakingQueueTestBase.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";

// ============================================================
// TC-12: Ownership Transfer Tests (L3 steps 1-9)
// Requirements: R-48
// ============================================================
contract StakingQueue_TC12_Ownership is StakingQueueTestBase {
    address internal newOwner;

    function setUp() public override {
        super.setUp();
        newOwner = makeAddr("newOwner");
    }

    /// @dev L3 step 1: Current owner calls transferOwnership(newOwner).
    ///      Assert pendingOwner() == newOwner.
    function test_TC12_transferOwnershipSetsPendingOwner() public {
        vm.prank(owner);
        queue.transferOwnership(newOwner);

        assertEq(queue.pendingOwner(), newOwner, "pendingOwner should be newOwner after transferOwnership");
        assertEq(queue.owner(), owner, "owner should remain unchanged until acceptance");
    }

    /// @dev L3 step 2: Non-pending-owner calls acceptOwnership() -- MUST revert.
    function test_TC12_nonPendingOwnerAcceptOwnershipReverts() public {
        vm.prank(owner);
        queue.transferOwnership(newOwner);

        // attacker (not the pending owner) tries to accept
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, attacker));
        queue.acceptOwnership();
    }

    /// @dev L3 step 3: newOwner calls acceptOwnership() -- MUST succeed. owner() == newOwner.
    function test_TC12_acceptOwnershipSucceeds() public {
        vm.prank(owner);
        queue.transferOwnership(newOwner);

        vm.prank(newOwner);
        queue.acceptOwnership();

        assertEq(queue.owner(), newOwner, "owner should be newOwner after acceptance");
        assertEq(queue.pendingOwner(), address(0), "pendingOwner should be cleared after acceptance");
    }

    /// @dev L3 step 4: Non-owner calls transferOwnership() -- MUST revert OwnableUnauthorizedAccount.
    function test_TC12_nonOwnerTransferOwnershipReverts() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, attacker));
        queue.transferOwnership(attacker);
    }

    /// @dev L3 step 5: OwnershipTransferStarted(oldOwner, newOwner) event emitted on transferOwnership.
    function test_TC12_ownershipTransferStartedEvent() public {
        vm.expectEmit(true, true, false, true);
        emit Ownable2StepUpgradeable.OwnershipTransferStarted(owner, newOwner);

        vm.prank(owner);
        queue.transferOwnership(newOwner);
    }

    /// @dev L3 step 6: OwnershipTransferred(oldOwner, newOwner) event emitted on acceptOwnership.
    function test_TC12_ownershipTransferredEvent() public {
        vm.prank(owner);
        queue.transferOwnership(newOwner);

        vm.expectEmit(true, true, false, true);
        emit OwnableUpgradeable.OwnershipTransferred(owner, newOwner);

        vm.prank(newOwner);
        queue.acceptOwnership();
    }

    /// @dev L3 step 7: After transfer: old owner cannot call owner-only functions. New owner can.
    function test_TC12_afterTransferOldOwnerFailsNewOwnerWorks() public {
        vm.prank(owner);
        queue.transferOwnership(newOwner);

        vm.prank(newOwner);
        queue.acceptOwnership();

        // Old owner cannot call owner-only functions
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, owner));
        queue.setForagePriceUsd(1e6);

        // New owner can propose and finalize owner-only price changes.
        vm.startPrank(newOwner);
        queue.setForagePriceUsd(1e6);
        vm.warp(block.timestamp + queue.FINALIZE_DELAY() + 1);
        queue.finalizeForagePriceUsd();
        vm.stopPrank();
        assertEq(queue.foragePriceUsd(), 1e6, "new owner should be able to call setForagePriceUsd");
    }

    /// @dev OF-020: renounceOwnership is disabled and reverts for any caller.
    function test_TC12_renounceOwnership() public {
        vm.prank(owner);
        vm.expectRevert(StakingQueue.RenounceOwnershipDisabled.selector);
        queue.renounceOwnership();

        assertEq(queue.owner(), owner, "owner should remain unchanged after disabled renounce");
    }

    /// @dev L3 step 9: Attack 4.7 coverage. Non-owner calls transferOwnership -- MUST revert.
    ///      Two-step prevents single-tx takeover.
    function test_TC12_attack47_ownershipTakeover() public {
        // Non-owner cannot initiate transfer
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, attacker));
        queue.transferOwnership(attacker);

        // Even if transfer is initiated by real owner, attacker cannot accept
        vm.prank(owner);
        queue.transferOwnership(newOwner);

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, attacker));
        queue.acceptOwnership();

        // Verify owner is still the original owner (two-step prevents single-tx takeover)
        assertEq(queue.owner(), owner, "owner should remain unchanged -- two-step prevents takeover");
    }
}
