// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/AtRISKUSDTestBase.sol";

// ============================================================
// TC-10: Transfer with Lock Tests (R-29, R-40)
// Updated for OF-016: Transfers blocked during active lockup.
// Lock propagation only from StakingQueue deposits.
// ============================================================
contract AtRISKUSD_TC10_TransferLock is AtRISKUSDTestBase {
    // ----- L3 Step 1: OF-016: Transfer during active lockup reverts -----
    function test_TC10_transferDuringLockupReverts() public {
        uint256 T = block.timestamp;

        _depositViaQueue(alice, 1000e6);
        assertEq(vault.lockExpiry(alice), T + LOCKUP_PERIOD, "Alice lockExpiry after deposit");

        // OF-016: Transfer during active lockup must revert
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(atRISKUSD.LockupNotExpired.selector, T + LOCKUP_PERIOD));
        vault.transfer(bob, 100);
    }

    // ----- L3 Step 2: Transfer succeeds after lockup expires -----
    function test_TC10_transferAfterLockupExpires() public {
        uint256 shares = _depositViaQueue(alice, 1000e6);

        // Warp past lockup
        vm.warp(block.timestamp + LOCKUP_PERIOD);

        // Transfer should succeed
        uint256 transferAmount = shares / 2;
        vm.prank(alice);
        vault.transfer(bob, transferAmount);

        assertEq(vault.balanceOf(bob), transferAmount, "bob should receive shares");
        assertEq(vault.balanceOf(alice), shares - transferAmount, "alice should have remaining shares");
    }

    function test_TC10_expiredAutoRenewDisabledSharesCannotTransferToClearTierExclusion() public {
        uint256 shares = _depositViaQueue(alice, 1000e6);
        vm.prank(alice);
        vault.setAutoRenew(false);

        vm.warp(block.timestamp + LOCKUP_PERIOD);

        vm.prank(alice);
        vm.expectRevert(atRISKUSD.ExpiredAutoRenewDisabledLockup.selector);
        vault.transfer(bob, shares / 2);

        assertTrue(vault.hasExpiredAutoRenewDisabledLockup(), "expired disabled holder still excludes tier");
    }

    function test_TC10_expiredAutoRenewDisabledCooldownCancelCannotClearTierExclusion() public {
        uint256 shares = _depositViaQueue(alice, 1000e6);
        vm.prank(alice);
        vault.setAutoRenew(false);

        vm.warp(block.timestamp + LOCKUP_PERIOD);

        vm.prank(alice);
        vault.requestWithdrawal(shares);

        assertEq(vault.balanceOf(alice), 0, "shares move into cooldown");
        assertTrue(vault.hasExpiredAutoRenewDisabledLockup(), "pending cooldown is not an actual exit");

        vm.prank(alice);
        vault.setAutoRenew(true);
        assertTrue(vault.hasExpiredAutoRenewDisabledLockup(), "reenable does not clear expired pending shares");

        vm.prank(alice);
        vault.cancelWithdrawal();

        assertEq(vault.balanceOf(alice), shares, "shares return to holder on cancel");
        assertTrue(vault.hasExpiredAutoRenewDisabledLockup(), "cancelled cooldown still excludes tier");
    }

    function test_TC10_expiredAutoRenewDisabledCooldownExecutionClearsTierExclusion() public {
        uint256 shares = _depositViaQueue(alice, 1000e6);
        vm.prank(alice);
        vault.setAutoRenew(false);

        vm.warp(block.timestamp + LOCKUP_PERIOD);

        vm.prank(alice);
        vault.requestWithdrawal(shares);

        vm.warp(block.timestamp + COOLDOWN_PERIOD);

        vm.prank(alice);
        vault.executeWithdrawal();

        assertEq(vault.balanceOf(alice), 0, "holder exited");
        assertFalse(vault.hasExpiredAutoRenewDisabledLockup(), "actual exit clears tier exclusion");
    }

    // ----- L3 Step 3: No lock inheritance on user-to-user transfer -----
    function test_TC10_noLockInheritanceOnUserTransfer() public {
        _depositViaQueue(alice, 1000e6);

        // Warp past lockup so transfer is allowed
        vm.warp(block.timestamp + LOCKUP_PERIOD);

        // Bob has no lock
        assertEq(vault.lockExpiry(bob), 0, "Bob lockExpiry should be 0 initially");

        // Alice transfers to Bob — OF-016: no lock propagation from non-StakingQueue
        vm.prank(alice);
        vault.transfer(bob, 100);

        // Bob should NOT inherit any lock (only StakingQueue propagates locks)
        assertEq(vault.lockExpiry(bob), 0, "Bob should not inherit lock from regular transfer");
    }

    // ----- L3 Step 4: StakingQueue deposit propagates lock -----
    function test_TC10_stakingQueueDepositPropagatesLock() public {
        uint256 T = block.timestamp;

        // Alice deposits via StakingQueue — lock propagated
        _depositViaQueue(alice, 1000e6);

        assertEq(vault.lockExpiry(alice), T + LOCKUP_PERIOD, "StakingQueue deposit should propagate lock");
    }

    // ----- L3 Step 5: StakingQueue deposit extends lock (max of old and new) -----
    function test_TC10_stakingQueueDepositExtendsLock() public {
        uint256 T = block.timestamp;

        _depositViaQueue(alice, 500e6); // lockExpiry = T + 90 days

        // Warp forward 30 days, deposit more
        vm.warp(T + 30 days);
        uint256 T2 = block.timestamp;

        _depositViaQueue(alice, 500e6);

        // Alice's lockExpiry should be max(T + 90 days, T2 + 90 days) = T2 + 90 days = T + 120 days
        uint256 expected = T2 + LOCKUP_PERIOD;
        assertEq(vault.lockExpiry(alice), expected, "Lock should extend to latest deposit lockup");
    }

    // ----- L3 Step 6: Transfer does not bypass lockup for withdrawal -----
    function test_TC10_transferDoesNotBypassLockupForWithdrawal() public {
        _depositViaQueue(alice, 1000e6);

        // OF-016: Can't even transfer during lockup
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(atRISKUSD.LockupNotExpired.selector, block.timestamp + LOCKUP_PERIOD));
        vault.transfer(bob, 500);
    }

    // ----- L3 Step 7: Mint (deposit) does not trigger lock inheritance from address(0) -----
    function test_TC10_mintDoesNotTriggerLockInheritance() public {
        uint256 T = block.timestamp;

        _depositViaQueue(alice, 500e6); // lockExpiry = T + 90 days

        vm.warp(T + 30 days);
        uint256 T2 = block.timestamp;

        _depositViaQueue(alice, 500e6);

        // Lock updated via StakingQueue deposit logic, not from address(0)
        uint256 expected = T2 + LOCKUP_PERIOD;
        assertEq(vault.lockExpiry(alice), expected, "Lock should update via deposit logic, not from address(0) lock");
    }

    // ----- L3 Step 8: Burn does not trigger lock inheritance (address(0) is to) -----
    function test_TC10_burnDoesNotTriggerLockInheritance() public {
        _depositViaQueue(alice, 1000e6);

        vm.warp(block.timestamp + LOCKUP_PERIOD);

        vm.prank(alice);
        vault.requestWithdrawal(100e6);

        vm.warp(block.timestamp + COOLDOWN_PERIOD);

        vm.prank(alice);
        vault.executeWithdrawal();

        assertEq(vault.lockExpiry(address(0)), 0, "address(0) lockExpiry should remain 0");
    }

    // ----- L3 Step 9: TransferFrom during lockup also blocked -----
    function test_TC10_transferFromDuringLockupReverts() public {
        uint256 T = block.timestamp;

        _depositViaQueue(alice, 1000e6);

        address charlie = makeAddr("charlie");

        vm.prank(alice);
        vault.approve(charlie, 500);

        // OF-016: transferFrom also blocked during lockup
        vm.prank(charlie);
        vm.expectRevert(abi.encodeWithSelector(atRISKUSD.LockupNotExpired.selector, T + LOCKUP_PERIOD));
        vault.transferFrom(alice, charlie, 200);
    }

    // ----- L3 Step 10: Zero-address edge — mint and burn skip lock logic -----
    function test_TC10_zeroAddressEdgeMintBurnSkipLock() public {
        _depositViaQueue(alice, 100e6);

        assertEq(vault.lockExpiry(address(0)), 0, "address(0) lockExpiry should be 0 after mint");
        assertTrue(vault.lockExpiry(alice) > 0, "Alice should have a valid lock");
    }

    // ----- L3 Step 11: TransferFrom succeeds after lockup expires -----
    function test_TC10_transferFromAfterLockupExpires() public {
        _depositViaQueue(alice, 1000e6);

        // Warp past lockup
        vm.warp(block.timestamp + LOCKUP_PERIOD);

        address charlie = makeAddr("charlie");
        vm.prank(alice);
        vault.approve(charlie, 500);

        vm.prank(charlie);
        vault.transferFrom(alice, charlie, 200);

        assertEq(vault.balanceOf(charlie), 200, "charlie should receive shares via transferFrom");
    }
}
