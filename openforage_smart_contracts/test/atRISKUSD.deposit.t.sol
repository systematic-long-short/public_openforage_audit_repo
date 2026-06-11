// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/AtRISKUSDTestBase.sol";

// ============================================================
// TC-02: Deposit Tests (R-06, R-07, R-22, R-23, R-24, R-25, R-26, R-27, R-28, R-39, R-41)
// ============================================================
contract AtRISKUSD_TC02_Deposit is AtRISKUSDTestBase {
    // ----- L3 Step 1: Non-StakingQueue deposit reverts UnauthorizedStakingQueue -----
    function test_TC02_depositNonQueueReverts() public {
        riskusd.mint(attacker, 1000e6);
        vm.startPrank(attacker);
        riskusd.approve(address(vault), 1000e6);
        vm.expectRevert(atRISKUSD.UnauthorizedStakingQueue.selector);
        vault.deposit(1000e6, alice);
        vm.stopPrank();
    }

    // ----- L3 Step 2: Non-StakingQueue mint reverts UnauthorizedStakingQueue -----
    function test_TC02_mintNonQueueReverts() public {
        riskusd.mint(attacker, 1000e6);
        vm.startPrank(attacker);
        riskusd.approve(address(vault), 1000e6);
        vm.expectRevert(atRISKUSD.UnauthorizedStakingQueue.selector);
        vault.mint(1000e6, alice);
        vm.stopPrank();
    }

    // ----- L3 Step 3: Zero amount deposit reverts ZeroAmount -----
    function test_TC02_depositZeroAmountReverts() public {
        vm.prank(stakingQueue);
        vm.expectRevert(atRISKUSD.ZeroAmount.selector);
        vault.deposit(0, alice);
    }

    // ----- L3 Step 4: Zero amount mint reverts ZeroAmount -----
    function test_TC02_mintZeroAmountReverts() public {
        vm.prank(stakingQueue);
        vm.expectRevert(atRISKUSD.ZeroAmount.selector);
        vault.mint(0, alice);
    }

    // ----- L3 Step 5: First deposit — shares minted, totalAssets updated, RISKUSD pulled -----
    function test_TC02_firstDepositHappyPath() public {
        uint256 depositAmount = 1000e6;
        riskusd.mint(stakingQueue, depositAmount);

        vm.startPrank(stakingQueue);
        riskusd.approve(address(vault), depositAmount);
        uint256 shares = vault.deposit(depositAmount, alice);
        vm.stopPrank();

        // Alice received shares > 0
        assertTrue(shares > 0, "alice should receive shares");
        assertEq(vault.balanceOf(alice), shares, "alice share balance mismatch");
        // totalAssets reflects deposit
        assertEq(vault.totalAssets(), depositAmount, "totalAssets mismatch after first deposit");
        // RISKUSD pulled from stakingQueue to vault
        assertEq(riskusd.balanceOf(address(vault)), depositAmount, "vault RISKUSD balance mismatch");
    }

    // ----- L3 Step 6: Lockup update on deposit (tier 1, 90 days) -----
    function test_TC02_lockupSetOnDeposit() public {
        uint256 depositTime = block.timestamp;
        _depositViaQueue(alice, 1000e6);

        assertEq(
            vault.lockExpiry(alice), depositTime + LOCKUP_PERIOD, "lockExpiry should be depositTime + lockupPeriod"
        );
    }

    // ----- L3 Step 7: Lockup max preservation — existing lock is longer -----
    function test_TC02_lockupMaxPreservation_existingLonger() public {
        uint256 T = block.timestamp;
        _depositViaQueue(alice, 500e6); // lockExpiry = T + 90 days

        // Warp to T + 10 days, deposit again
        vm.warp(T + 10 days);
        _depositViaQueue(alice, 500e6);

        // New lockExpiry = max(T + 90 days, T + 10 days + 90 days) = T + 100 days
        uint256 expected = T + 100 days;
        assertEq(vault.lockExpiry(alice), expected, "lockExpiry should be T + 100 days");
    }

    // ----- L3 Step 7: Lockup max preservation — new deposit extends lock -----
    function test_TC02_lockupMaxPreservation_newExtends() public {
        uint256 T = block.timestamp;
        _depositViaQueue(alice, 500e6); // lockExpiry = T + 90 days

        // Warp to T + 50 days, deposit again
        vm.warp(T + 50 days);
        _depositViaQueue(alice, 500e6);

        // New lockExpiry = max(T + 90 days, T + 50 days + 90 days) = T + 140 days
        uint256 expected = T + 140 days;
        assertEq(vault.lockExpiry(alice), expected, "lockExpiry should be T + 140 days");
    }

    // ----- L3 Step 8: No lockup (tier 0) -----
    function test_TC02_noLockupTier0() public {
        atRISKUSD tier0 = _deployFreshVault(0, COOLDOWN_PERIOD, 0);
        riskusd.mint(stakingQueue, 1000e6);
        vm.startPrank(stakingQueue);
        riskusd.approve(address(tier0), 1000e6);
        tier0.deposit(1000e6, alice);
        vm.stopPrank();

        // lockExpiry == block.timestamp (lockupPeriod = 0)
        assertEq(tier0.lockExpiry(alice), block.timestamp, "tier0 lockExpiry should be block.timestamp");
    }

    // ----- L3 Step 9: Second deposit same user — shares added -----
    function test_TC02_secondDepositSameUser() public {
        uint256 shares1 = _depositViaQueue(alice, 500e6);
        uint256 shares2 = _depositViaQueue(alice, 500e6);

        assertEq(vault.balanceOf(alice), shares1 + shares2, "alice should have cumulative shares");
        assertEq(vault.totalAssets(), 1000e6, "totalAssets should be 1000e6");
    }

    // ----- L3 Step 10: Deposits for different users — independent balances -----
    function test_TC02_depositsForDifferentUsers() public {
        uint256 aliceShares = _depositViaQueue(alice, 600e6);
        uint256 bobShares = _depositViaQueue(bob, 400e6);

        assertEq(vault.balanceOf(alice), aliceShares, "alice shares mismatch");
        assertEq(vault.balanceOf(bob), bobShares, "bob shares mismatch");
        assertEq(vault.totalAssets(), 1000e6, "totalAssets should be 1000e6");
    }

    // ----- L3 Step 11: Deposit after yield — fewer shares per RISKUSD -----
    function test_TC02_depositAfterYield() public {
        uint256 initialShares = _depositViaQueue(alice, 1000e6);
        _accrueYield(100e6); // exchange rate > 1:1

        uint256 bobShares = _depositViaQueue(bob, 1000e6);

        // Bob should receive fewer shares than alice (same RISKUSD amount, higher rate)
        assertTrue(bobShares < initialShares, "bob should receive fewer shares after yield");
    }

    // ----- L3 Step 12: Deposit after loss — more shares per RISKUSD -----
    function test_TC02_depositAfterLoss() public {
        uint256 initialShares = _depositViaQueue(alice, 1000e6);
        _absorbLoss(100e6); // exchange rate < 1:1

        uint256 bobShares = _depositViaQueue(bob, 1000e6);

        // Bob should receive more shares than alice (same RISKUSD amount, lower rate)
        assertTrue(bobShares > initialShares, "bob should receive more shares after loss");
    }

    // ----- L3 Step 13: Paused state blocks deposit -----
    function test_TC02_depositWhenPausedReverts() public {
        vm.prank(owner);
        vault.pause();

        riskusd.mint(stakingQueue, 1000e6);
        vm.startPrank(stakingQueue);
        riskusd.approve(address(vault), 1000e6);
        vm.expectRevert();
        vault.deposit(1000e6, alice);
        vm.stopPrank();
    }

    // ----- L3 Step 14: redeemForUpgrade non-queue reverts UnauthorizedStakingQueue -----
    function test_TC02_redeemForUpgradeNonQueueReverts() public {
        _depositViaQueue(alice, 1000e6);
        vm.prank(attacker);
        vm.expectRevert(atRISKUSD.UnauthorizedStakingQueue.selector);
        vault.redeemForUpgrade(alice, 100);
    }

    // ----- L3 Step 15: redeemForUpgrade zero amount reverts ZeroAmount -----
    function test_TC02_redeemForUpgradeZeroAmountReverts() public {
        _depositViaQueue(alice, 1000e6);
        vm.prank(stakingQueue);
        vm.expectRevert(atRISKUSD.ZeroAmount.selector);
        vault.redeemForUpgrade(alice, 0);
    }

    // ----- L3 Step 16: redeemForUpgrade happy path -----
    function test_TC02_redeemForUpgradeHappyPath() public {
        uint256 aliceShares = _depositViaQueue(alice, 1000e6);

        // OF-NEW-10: redeemForUpgrade now checks lockup expiry — warp past lockup
        vm.warp(block.timestamp + LOCKUP_PERIOD + 1);

        uint256 sharesToRedeem = aliceShares / 2;
        uint256 expectedAssets = vault.previewRedeem(sharesToRedeem);

        uint256 queueBalBefore = riskusd.balanceOf(stakingQueue);
        uint256 aliceSharesBefore = vault.balanceOf(alice);

        vm.prank(stakingQueue);
        uint256 assetsReturned = vault.redeemForUpgrade(alice, sharesToRedeem);

        // Shares burned from alice
        assertEq(vault.balanceOf(alice), aliceSharesBefore - sharesToRedeem, "alice shares not burned");
        // RISKUSD transferred to stakingQueue at current exchange rate
        assertEq(assetsReturned, expectedAssets, "assets returned mismatch");
        assertEq(riskusd.balanceOf(stakingQueue), queueBalBefore + expectedAssets, "stakingQueue RISKUSD not received");
    }

    function test_TC02_redeemForUpgradeConsumesWeeklyWithdrawalCap() public {
        uint256 aliceShares = _depositViaQueue(alice, 1000e6);
        vm.prank(owner);
        vault.setWeeklyWithdrawalCapBps(100);
        vm.warp(block.timestamp + LOCKUP_PERIOD + 1);

        uint256 sharesToRedeem = aliceShares / 2;
        uint256 expectedAssets = vault.previewRedeem(sharesToRedeem);

        vm.prank(stakingQueue);
        vm.expectRevert(
            abi.encodeWithSelector(atRISKUSD.WeeklyWithdrawalCapExceeded.selector, expectedAssets, uint256(10e6))
        );
        vault.redeemForUpgrade(alice, sharesToRedeem);
    }

    // ----- L3 Step 17: redeemForUpgrade paused reverts -----
    function test_TC02_redeemForUpgradePausedReverts() public {
        _depositViaQueue(alice, 1000e6);
        vm.prank(owner);
        vault.pause();
        vm.prank(stakingQueue);
        vm.expectRevert();
        vault.redeemForUpgrade(alice, 100);
    }

    // ----- L3 Step 18: redeemForReversion non-queue reverts UnauthorizedStakingQueue -----
    function test_TC02_redeemForReversionNonQueueReverts() public {
        _depositViaQueue(alice, 1000e6);
        vm.prank(attacker);
        vm.expectRevert(atRISKUSD.UnauthorizedStakingQueue.selector);
        vault.redeemForReversion(alice, 100);
    }

    // ----- L3 Step 19: redeemForReversion lockup not expired reverts -----
    function test_TC02_redeemForReversionLockupNotExpiredReverts() public {
        uint256 aliceShares = _depositViaQueue(alice, 1000e6);

        // Disable auto-renew for alice
        vm.prank(alice);
        vault.setAutoRenew(false);

        // Lockup has NOT expired yet
        vm.prank(stakingQueue);
        vm.expectRevert(); // LockupNotExpired
        vault.redeemForReversion(alice, aliceShares);
    }

    // ----- L3 Step 19: redeemForReversion auto-renewal enabled reverts -----
    function test_TC02_redeemForReversionAutoRenewEnabledReverts() public {
        uint256 aliceShares = _depositViaQueue(alice, 1000e6);

        // Warp past lockup so it's expired, but auto-renewal is still enabled (default)
        vm.warp(block.timestamp + LOCKUP_PERIOD);

        vm.prank(stakingQueue);
        vm.expectRevert(atRISKUSD.AutoRenewEnabled.selector);
        vault.redeemForReversion(alice, aliceShares);
    }

    // ----- L3 Step 20: redeemForReversion happy path -----
    function test_TC02_redeemForReversionHappyPath() public {
        uint256 aliceShares = _depositViaQueue(alice, 1000e6);

        // Alice disables auto-renew
        vm.prank(alice);
        vault.setAutoRenew(false);

        // Warp past lockup
        vm.warp(block.timestamp + LOCKUP_PERIOD);

        uint256 sharesToRedeem = aliceShares / 2;
        uint256 expectedAssets = vault.previewRedeem(sharesToRedeem);
        uint256 queueBalBefore = riskusd.balanceOf(stakingQueue);

        vm.prank(stakingQueue);
        uint256 assetsReturned = vault.redeemForReversion(alice, sharesToRedeem);

        // Shares burned from alice
        assertEq(vault.balanceOf(alice), aliceShares - sharesToRedeem, "alice shares not burned");
        // RISKUSD transferred to stakingQueue
        assertEq(assetsReturned, expectedAssets, "assets returned mismatch");
        assertEq(riskusd.balanceOf(stakingQueue), queueBalBefore + expectedAssets, "stakingQueue RISKUSD not received");
    }

    function test_TC02_redeemForReversionConsumesWeeklyWithdrawalCap() public {
        uint256 aliceShares = _depositViaQueue(alice, 1000e6);
        vm.prank(owner);
        vault.setWeeklyWithdrawalCapBps(100);

        vm.prank(alice);
        vault.setAutoRenew(false);
        vm.warp(block.timestamp + LOCKUP_PERIOD);

        uint256 sharesToRedeem = aliceShares / 2;
        uint256 expectedAssets = vault.previewRedeem(sharesToRedeem);

        vm.prank(stakingQueue);
        vm.expectRevert(
            abi.encodeWithSelector(atRISKUSD.WeeklyWithdrawalCapExceeded.selector, expectedAssets, uint256(10e6))
        );
        vault.redeemForReversion(alice, sharesToRedeem);
    }

    // ----- L3 Step 21: redeemForReversion paused reverts -----
    function test_TC02_redeemForReversionPausedReverts() public {
        _depositViaQueue(alice, 1000e6);
        vm.prank(alice);
        vault.setAutoRenew(false);
        vm.warp(block.timestamp + LOCKUP_PERIOD);

        vm.prank(owner);
        vault.pause();

        vm.prank(stakingQueue);
        vm.expectRevert();
        vault.redeemForReversion(alice, 100);
    }

    // ----- L3 Step 22: renewLockup non-queue reverts UnauthorizedStakingQueue -----
    function test_TC02_renewLockupNonQueueReverts() public {
        _depositViaQueue(alice, 1000e6);
        vm.prank(attacker);
        vm.expectRevert(atRISKUSD.UnauthorizedStakingQueue.selector);
        vault.renewLockup(alice);
    }

    // ----- L3 Step 23: renewLockup lockup not expired reverts -----
    function test_TC02_renewLockupNotExpiredReverts() public {
        _depositViaQueue(alice, 1000e6);

        // Lockup has NOT expired
        vm.prank(stakingQueue);
        vm.expectRevert(); // LockupNotExpired
        vault.renewLockup(alice);
    }

    // ----- L3 Step 23: renewLockup auto-renewal disabled reverts -----
    function test_TC02_renewLockupAutoRenewDisabledReverts() public {
        _depositViaQueue(alice, 1000e6);

        // Disable auto-renew
        vm.prank(alice);
        vault.setAutoRenew(false);

        // Warp past lockup
        vm.warp(block.timestamp + LOCKUP_PERIOD);

        vm.prank(stakingQueue);
        vm.expectRevert(atRISKUSD.AutoRenewDisabled.selector);
        vault.renewLockup(alice);
    }

    // ----- L3 Step 24: renewLockup happy path -----
    function test_TC02_renewLockupHappyPath() public {
        _depositViaQueue(alice, 1000e6);

        // Warp past lockup (auto-renewal is enabled by default)
        vm.warp(block.timestamp + LOCKUP_PERIOD);

        uint256 renewTime = block.timestamp;

        vm.expectEmit(true, false, false, true, address(vault));
        emit atRISKUSD.LockupRenewed(alice, renewTime + LOCKUP_PERIOD);

        vm.prank(stakingQueue);
        vault.renewLockup(alice);

        assertEq(
            vault.lockExpiry(alice),
            renewTime + LOCKUP_PERIOD,
            "lockExpiry should be reset to current time + lockupPeriod"
        );
    }

    // ----- L3 Step 0 (implied): redeemForReversion zero amount reverts -----
    function test_TC02_redeemForReversionZeroAmountReverts() public {
        _depositViaQueue(alice, 1000e6);
        vm.prank(alice);
        vault.setAutoRenew(false);
        vm.warp(block.timestamp + LOCKUP_PERIOD);

        vm.prank(stakingQueue);
        vm.expectRevert(atRISKUSD.ZeroAmount.selector);
        vault.redeemForReversion(alice, 0);
    }

    function test_TC02_autoRenewDisabledEarliestRecomputedAfterEarliestHolderExits() public {
        uint256 start = block.timestamp;
        uint256 aliceShares = _depositViaQueue(alice, 1000e6);
        vm.prank(alice);
        vault.setAutoRenew(false);

        vm.warp(start + 10 days);
        _depositViaQueue(bob, 1000e6);
        vm.prank(bob);
        vault.setAutoRenew(false);

        uint256 aliceExpiry = vault.lockExpiry(alice);
        uint256 bobExpiry = vault.lockExpiry(bob);
        assertLt(aliceExpiry, bobExpiry, "test requires distinct lock expiries");

        vm.warp(aliceExpiry);
        assertTrue(vault.hasExpiredAutoRenewDisabledLockup(), "Alice's expired lockup excludes tier");

        vm.prank(stakingQueue);
        vault.redeemForReversion(alice, aliceShares);

        assertEq(vault.balanceOf(alice), 0, "Alice fully exited the tracked disabled set");
        assertGt(vault.balanceOf(bob), 0, "Bob remains in the tier");
        assertFalse(vault.hasExpiredAutoRenewDisabledLockup(), "Bob's later lockup is not expired yet");

        vm.warp(bobExpiry);
        assertTrue(vault.hasExpiredAutoRenewDisabledLockup(), "Bob excludes tier once his own lockup expires");
    }
}
