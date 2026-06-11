// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/AtRISKUSDTestBase.sol";

// ============================================================
// TC-11: Auto-Renewal Tests (R-30, R-31, R-40)
// ============================================================
contract AtRISKUSD_TC11_AutoRenewal is AtRISKUSDTestBase {
    // ----- L3 Step 1: Default is ON -----
    function test_TC11_defaultIsOn() public view {
        // Alice has never called setAutoRenew
        assertTrue(vault.autoRenewEnabled(alice), "autoRenewEnabled should be true by default");
    }

    // ----- L3 Step 2: Opt-out — setAutoRenew(false) disables -----
    function test_TC11_optOut() public {
        vm.expectEmit(true, false, false, true, address(vault));
        emit atRISKUSD.AutoRenewChanged(alice, false);

        vm.prank(alice);
        vault.setAutoRenew(false);

        assertFalse(vault.autoRenewEnabled(alice), "autoRenewEnabled should be false after opt-out");
    }

    // ----- L3 Step 3: Re-opt-in — setAutoRenew(true) re-enables -----
    function test_TC11_reOptIn() public {
        // First opt out
        vm.prank(alice);
        vault.setAutoRenew(false);
        assertFalse(vault.autoRenewEnabled(alice), "should be false after opt-out");

        // Re-opt in
        vm.expectEmit(true, false, false, true, address(vault));
        emit atRISKUSD.AutoRenewChanged(alice, true);

        vm.prank(alice);
        vault.setAutoRenew(true);

        assertTrue(vault.autoRenewEnabled(alice), "autoRenewEnabled should be true after re-opt-in");
    }

    // ----- L3 Step 4: Idempotent calls — setAutoRenew(true) when already enabled -----
    function test_TC11_idempotentCallsSucceed() public {
        // Already enabled by default, call setAutoRenew(true) again
        vm.expectEmit(true, false, false, true, address(vault));
        emit atRISKUSD.AutoRenewChanged(alice, true);

        vm.prank(alice);
        vault.setAutoRenew(true);

        assertTrue(vault.autoRenewEnabled(alice), "should still be true");
    }

    // ----- L3 Step 5: Independent per depositor -----
    function test_TC11_independentPerDepositor() public {
        vm.prank(alice);
        vault.setAutoRenew(false);

        assertFalse(vault.autoRenewEnabled(alice), "Alice should be opted out");
        assertTrue(vault.autoRenewEnabled(bob), "Bob should still be opted in");
    }

    // ----- L3 Step 6: Works while paused (R-36) -----
    function test_TC11_worksWhilePaused() public {
        vm.prank(owner);
        vault.pause();

        // setAutoRenew must succeed even when paused
        vm.prank(alice);
        vault.setAutoRenew(false);

        assertFalse(vault.autoRenewEnabled(alice), "setAutoRenew should work while paused");
    }

    // ----- L3 Step 7: Interaction with redeemForReversion -----
    function test_TC11_interactionWithRedeemForReversion() public {
        uint256 aliceShares = _depositViaQueue(alice, 1000e6);

        // Alice opts out
        vm.prank(alice);
        vault.setAutoRenew(false);

        // Warp past lockup
        vm.warp(block.timestamp + LOCKUP_PERIOD);

        // StakingQueue calls redeemForReversion — should succeed
        uint256 sharesToRedeem = aliceShares / 2;
        vm.prank(stakingQueue);
        uint256 assets = vault.redeemForReversion(alice, sharesToRedeem);

        assertTrue(assets > 0, "redeemForReversion should return assets");
        assertEq(vault.balanceOf(alice), aliceShares - sharesToRedeem, "Alice shares should be reduced");
    }

    // ----- L3 Step 8a: Interaction with renewLockup — enabled succeeds -----
    function test_TC11_interactionWithRenewLockupEnabled() public {
        _depositViaQueue(bob, 1000e6);

        // Bob's auto-renewal is enabled by default
        assertTrue(vault.autoRenewEnabled(bob), "Bob auto-renewal should be enabled");

        // Warp past lockup
        vm.warp(block.timestamp + LOCKUP_PERIOD);

        uint256 renewTime = block.timestamp;

        // StakingQueue calls renewLockup — should succeed
        vm.prank(stakingQueue);
        vault.renewLockup(bob);

        assertEq(vault.lockExpiry(bob), renewTime + LOCKUP_PERIOD, "Bob's lockup should be renewed");
    }

    // ----- L3 Step 8b: Interaction with renewLockup — disabled reverts -----
    function test_TC11_interactionWithRenewLockupDisabledReverts() public {
        _depositViaQueue(bob, 1000e6);

        // Bob opts out
        vm.prank(bob);
        vault.setAutoRenew(false);

        // Warp past lockup
        vm.warp(block.timestamp + LOCKUP_PERIOD);

        // StakingQueue calls renewLockup — should revert
        vm.prank(stakingQueue);
        vm.expectRevert(atRISKUSD.AutoRenewDisabled.selector);
        vault.renewLockup(bob);
    }

    // ----- L3 Step 9: Opt-out during active lockup — allowed -----
    function test_TC11_optOutDuringActiveLockup() public {
        _depositViaQueue(alice, 1000e6);

        // Lockup is still active
        assertTrue(vault.lockExpiry(alice) > block.timestamp, "Lockup should be active");

        // setAutoRenew(false) should succeed regardless of lockup status
        vm.prank(alice);
        vault.setAutoRenew(false);

        assertFalse(vault.autoRenewEnabled(alice), "Opt-out during active lockup should work");
    }

    // ----- Additional: Callable by any address (no auth needed) -----
    function test_TC11_callableByAnyAddress() public {
        // Even attacker address can toggle their own auto-renewal
        vm.prank(attacker);
        vault.setAutoRenew(false);
        assertFalse(vault.autoRenewEnabled(attacker), "attacker can toggle their own auto-renewal");

        vm.prank(attacker);
        vault.setAutoRenew(true);
        assertTrue(vault.autoRenewEnabled(attacker), "attacker can re-enable their own auto-renewal");
    }
}
