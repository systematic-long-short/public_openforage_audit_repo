// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/AtRISKUSDTestBase.sol";

// ============================================================
// TC-06: Lockup Period Tests (R-07, R-13)
// ============================================================
contract AtRISKUSD_TC06_Lockup is AtRISKUSDTestBase {
    // Default setUp uses tier 1 (90-day lockup, 7-day cooldown)

    // ----- L3 Step 1a: Lockup exact second boundary — 1 second before expiry reverts -----
    function test_TC06_lockupOneSecondBeforeExpiryReverts() public {
        uint256 T = block.timestamp;
        _depositViaQueue(alice, 1000e6);

        // Warp to T + lockupPeriod - 1
        vm.warp(T + LOCKUP_PERIOD - 1);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(atRISKUSD.LockupNotExpired.selector, T + LOCKUP_PERIOD));
        vault.requestWithdrawal(100e6);
    }

    // ----- L3 Step 1b: Lockup exactly expired — succeeds -----
    function test_TC06_lockupExactlyExpiredSucceeds() public {
        uint256 T = block.timestamp;
        _depositViaQueue(alice, 1000e6);

        // Warp to exactly T + lockupPeriod
        vm.warp(T + LOCKUP_PERIOD);

        vm.prank(alice);
        vault.requestWithdrawal(100e6);

        atRISKUSD.PendingWithdrawal memory pw = vault.pendingWithdrawal(alice);
        assertTrue(pw.active, "request should succeed at exact lockup expiry");
    }

    // ----- L3 Step 1c: 1 second after lockup — succeeds -----
    function test_TC06_lockupOneSecondAfterSucceeds() public {
        uint256 T = block.timestamp;
        _depositViaQueue(alice, 1000e6);

        // Warp to T + lockupPeriod + 1
        vm.warp(T + LOCKUP_PERIOD + 1);

        vm.prank(alice);
        vault.requestWithdrawal(100e6);

        atRISKUSD.PendingWithdrawal memory pw = vault.pendingWithdrawal(alice);
        assertTrue(pw.active, "request should succeed 1 second after lockup expiry");
    }

    // ----- L3 Step 2: Lockup reset on additional deposit -----
    function test_TC06_lockupResetOnAdditionalDeposit() public {
        uint256 T = block.timestamp;
        _depositViaQueue(alice, 500e6); // lockExpiry = T + 90 days

        // At T + 50 days, deposit more
        vm.warp(T + 50 days);
        _depositViaQueue(alice, 500e6);

        // New lockExpiry = max(T + 90 days, T + 50 days + 90 days) = T + 140 days
        uint256 newLockExpiry = T + 140 days;
        assertEq(vault.lockExpiry(alice), newLockExpiry, "lockExpiry should be T + 140 days");

        // Alice cannot request withdrawal until T + 140 days
        vm.warp(T + 139 days);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(atRISKUSD.LockupNotExpired.selector, newLockExpiry));
        vault.requestWithdrawal(100e6);

        // At T + 140 days, should succeed
        vm.warp(newLockExpiry);
        vm.prank(alice);
        vault.requestWithdrawal(100e6);

        assertTrue(vault.pendingWithdrawal(alice).active, "request should succeed at new lockExpiry");
    }

    // ----- L3 Step 3: Lockup enforcement only at request, not at execute -----
    function test_TC06_lockupEnforcedAtRequestNotExecute() public {
        uint256 T = block.timestamp;
        _depositViaQueue(alice, 1000e6);

        // Warp to lockup expiry
        vm.warp(T + LOCKUP_PERIOD);

        // Alice requests withdrawal (lockup expired, success)
        vm.prank(alice);
        vault.requestWithdrawal(100e6);

        // During cooldown, a new deposit extends alice's lockExpiry
        vm.warp(T + LOCKUP_PERIOD + 1 days);
        _depositViaQueue(alice, 500e6);

        // Now alice's lockExpiry is extended, but the pending withdrawal is already in flight
        uint256 newLockExpiry = vault.lockExpiry(alice);
        assertTrue(newLockExpiry > T + LOCKUP_PERIOD + COOLDOWN_PERIOD, "lockExpiry should be extended");

        // Execute the original withdrawal after cooldown — should succeed
        // despite the new lockup
        vm.warp(T + LOCKUP_PERIOD + COOLDOWN_PERIOD);
        vm.prank(alice);
        vault.executeWithdrawal();

        atRISKUSD.PendingWithdrawal memory pw = vault.pendingWithdrawal(alice);
        assertFalse(pw.active, "execute should succeed regardless of new lockup");
    }

    // ----- L3 Step 4: Zero lockup (tier 0) — immediate request -----
    function test_TC06_zeroLockupImmediateRequest() public {
        atRISKUSD tier0 = _deployFreshVault(0, COOLDOWN_PERIOD, 0);

        riskusd.mint(stakingQueue, 1000e6);
        vm.startPrank(stakingQueue);
        riskusd.approve(address(tier0), 1000e6);
        tier0.deposit(1000e6, alice);
        vm.stopPrank();

        // lockExpiry == block.timestamp (lockupPeriod = 0)
        assertEq(tier0.lockExpiry(alice), block.timestamp, "tier0 lockExpiry should equal current timestamp");

        // Immediately request withdrawal
        vm.prank(alice);
        tier0.requestWithdrawal(100e6);

        assertTrue(tier0.pendingWithdrawal(alice).active, "tier 0 should allow immediate request");
    }

    // ----- L3 Step 5: Each tier lockup period -----
    function test_TC06_tier0LockupDuration() public {
        atRISKUSD t0 = _deployFreshVault(0, COOLDOWN_PERIOD, 0);
        assertEq(t0.lockupPeriod(), 0, "tier 0 lockup should be 0");
    }

    function test_TC06_tier1LockupDuration() public view {
        assertEq(vault.lockupPeriod(), 7_776_000, "tier 1 lockup should be 90 days (7776000s)");
    }

    function test_TC06_tier2LockupDuration() public {
        atRISKUSD t2 = _deployFreshVault(15_552_000, COOLDOWN_PERIOD, 2);
        assertEq(t2.lockupPeriod(), 15_552_000, "tier 2 lockup should be 180 days (15552000s)");
    }

    function test_TC06_tier3LockupDuration() public {
        atRISKUSD t3 = _deployFreshVault(31_104_000, COOLDOWN_PERIOD, 3);
        assertEq(t3.lockupPeriod(), 31_104_000, "tier 3 lockup should be 360 days (31104000s)");
    }

    // ----- L3 Step 6: Lockup does not affect executeWithdrawal -----
    function test_TC06_lockupDoesNotAffectExecute() public {
        uint256 T = block.timestamp;
        _depositViaQueue(alice, 1000e6);

        // Warp past lockup
        vm.warp(T + LOCKUP_PERIOD);
        vm.prank(alice);
        vault.requestWithdrawal(100e6);

        // New deposit resets lockup (extends beyond cooldown end)
        vm.warp(T + LOCKUP_PERIOD + 1);
        _depositViaQueue(alice, 500e6);

        // Verify lockup is extended beyond cooldown end
        uint256 cooldownEnd = T + LOCKUP_PERIOD + COOLDOWN_PERIOD;
        assertTrue(vault.lockExpiry(alice) > cooldownEnd, "lockExpiry should be after cooldown end");

        // Execute at cooldown end — should succeed (lockup check is at request time only)
        vm.warp(cooldownEnd);
        vm.prank(alice);
        vault.executeWithdrawal();

        assertFalse(vault.pendingWithdrawal(alice).active, "execute should work despite extended lockup");
    }

    // ----- L3 Step 7: Multiple depositors independent lockup timings -----
    function test_TC06_multipleDepositorsIndependentLockups() public {
        uint256 T = block.timestamp;

        // Alice deposits at T
        _depositViaQueue(alice, 500e6);
        uint256 aliceLockExpiry = T + LOCKUP_PERIOD;
        assertEq(vault.lockExpiry(alice), aliceLockExpiry, "alice lockExpiry mismatch");

        // Bob deposits at T + 30 days
        vm.warp(T + 30 days);
        _depositViaQueue(bob, 500e6);
        uint256 bobLockExpiry = T + 30 days + LOCKUP_PERIOD;
        assertEq(vault.lockExpiry(bob), bobLockExpiry, "bob lockExpiry mismatch");

        // Alice and bob have independent lock expiries
        assertTrue(aliceLockExpiry < bobLockExpiry, "alice lockExpiry should be before bob's");

        // At alice's lockExpiry: alice can request, bob cannot
        vm.warp(aliceLockExpiry);
        vm.prank(alice);
        vault.requestWithdrawal(100e6);
        assertTrue(vault.pendingWithdrawal(alice).active, "alice should be able to request");

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(atRISKUSD.LockupNotExpired.selector, bobLockExpiry));
        vault.requestWithdrawal(100e6);

        // At bob's lockExpiry: bob can request
        vm.warp(bobLockExpiry);
        vm.prank(bob);
        vault.requestWithdrawal(100e6);
        assertTrue(vault.pendingWithdrawal(bob).active, "bob should be able to request at his lockExpiry");
    }
}
