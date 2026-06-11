// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/AtRISKUSDTestBase.sol";

// ============================================================
// TC-08: Loss Absorption Tests (R-11, R-12, R-44)
// ============================================================
contract AtRISKUSD_TC08_LossAbsorption is AtRISKUSDTestBase {
    function setUp() public override {
        super.setUp();
        _raiseWeeklyWithdrawalCap(vault);
    }

    // ----- L3 Step 1: Proportional loss across depositors via exchange rate -----
    function test_TC08_proportionalLossAcrossDepositors() public {
        // Alice deposits 600e6, Bob deposits 400e6 (total 1000e6)
        uint256 aliceShares = _depositViaQueue(alice, 600e6);
        uint256 bobShares = _depositViaQueue(bob, 400e6);

        // Absorb 100e6 loss -- totalAssets goes from 1000e6 to 900e6 (10% loss)
        _absorbLoss(100e6);

        // Alice's assets should be ~540e6 (600 * 0.9), Bob's ~360e6 (400 * 0.9)
        // Allow small rounding tolerance due to virtual offset
        uint256 aliceAssets = vault.convertToAssets(aliceShares);
        uint256 bobAssets = vault.convertToAssets(bobShares);

        // Both lost approximately 10%
        assertApproxEqAbs(aliceAssets, 540e6, 2, "Alice should have ~540e6 after 10% loss");
        assertApproxEqAbs(bobAssets, 360e6, 2, "Bob should have ~360e6 after 10% loss");
    }

    // ----- L3 Step 2: Loss does not change share balances -----
    function test_TC08_lossDoesNotChangeShareBalances() public {
        uint256 aliceShares = _depositViaQueue(alice, 600e6);
        uint256 bobShares = _depositViaQueue(bob, 400e6);

        _absorbLoss(100e6);

        assertEq(vault.balanceOf(alice), aliceShares, "Alice share balance must not change after loss");
        assertEq(vault.balanceOf(bob), bobShares, "Bob share balance must not change after loss");
    }

    // ----- L3 Step 3: Total wipeout — totalAssets == 0, shares still exist but worth 0 -----
    function test_TC08_totalWipeout() public {
        uint256 aliceShares = _depositViaQueue(alice, 1000e6);

        _absorbLoss(1000e6);

        assertEq(vault.totalAssets(), 0, "totalAssets should be 0 after total wipeout");
        assertTrue(vault.balanceOf(alice) > 0, "Alice should still hold shares");
        assertEq(vault.convertToAssets(aliceShares), 0, "Shares should be worth 0 after wipeout");
    }

    // ----- L3 Step 4: Deposit after total wipeout is blocked while legacy shares remain -----
    function test_TC08_depositAfterTotalWipeoutReverts() public {
        _depositViaQueue(alice, 1000e6);
        _absorbLoss(1000e6); // total wipeout

        assertEq(vault.totalAssets(), 0, "totalAssets must be 0 before new deposit");

        address charlie = makeAddr("charlie");
        riskusd.mint(stakingQueue, 100e6);
        vm.startPrank(stakingQueue);
        riskusd.approve(address(vault), 100e6);
        vm.expectRevert(atRISKUSD.ZeroAssetLegacySupply.selector);
        vault.deposit(100e6, charlie);
        vm.stopPrank();

        assertEq(vault.totalAssets(), 0, "totalAssets should remain 0 after blocked deposit");
    }

    // ----- L3 Step 5: Loss larger than totalAssets capped (type(uint256).max) -----
    function test_TC08_lossLargerThanTotalAssetsCapped() public {
        _depositViaQueue(alice, 500e6);

        uint256 yieldSourceBalBefore = riskusd.balanceOf(yieldSource);

        _absorbLoss(type(uint256).max); // absorbLoss caps to totalAssets

        // Only 500e6 should have been transferred
        assertEq(
            riskusd.balanceOf(yieldSource),
            yieldSourceBalBefore + 500e6,
            "Only totalAssets should be transferred even for max uint256"
        );
        assertEq(vault.totalAssets(), 0, "totalAssets should be 0");
    }

    // ----- L3 Step 6: Many small losses — precision maintained -----
    function test_TC08_manySmallLossesPrecision() public {
        _depositViaQueue(alice, 1000e6);

        uint256 totalAssetsBefore = vault.totalAssets();

        // Absorb 1 wei 100 times
        for (uint256 i = 0; i < 100; i++) {
            _absorbLoss(1);
        }

        assertEq(vault.totalAssets(), totalAssetsBefore - 100, "totalAssets should decrease by exactly 100 wei");
        assertEq(vault.totalLossAbsorbed(), 100, "totalLossAbsorbed should be 100");
    }

    // ----- L3 Step 7: Loss followed by withdrawal request — captures post-loss rate -----
    function test_TC08_lossFollowedByWithdrawalRequest() public {
        uint256 aliceShares = _depositViaQueue(alice, 1000e6);

        _absorbLoss(200e6); // totalAssets = 800e6

        // Get expected RISKUSD at post-loss rate
        uint256 sharesToWithdraw = aliceShares / 2;
        uint256 expectedRiskusd = vault.previewRedeem(sharesToWithdraw);

        // Warp past lockup
        vm.warp(block.timestamp + LOCKUP_PERIOD);

        vm.prank(alice);
        vault.requestWithdrawal(sharesToWithdraw);

        atRISKUSD.PendingWithdrawal memory pw = vault.pendingWithdrawal(alice);
        assertEq(pw.riskusdAmount, expectedRiskusd, "Captured amount should reflect post-loss rate");
        // Verify it is less than initial deposit amount (pre-loss rate)
        assertTrue(expectedRiskusd < 500e6, "Post-loss amount should be less than 500e6");
    }

    // ----- L3 Step 8: Loss followed by yield (recovery scenario) -----
    function test_TC08_lossFollowedByYieldRecovery() public {
        uint256 aliceShares = _depositViaQueue(alice, 1000e6);
        uint256 initialAssets = vault.convertToAssets(aliceShares);

        // 50% loss
        _absorbLoss(500e6);
        uint256 postLossAssets = vault.convertToAssets(aliceShares);
        assertTrue(postLossAssets < initialAssets, "Assets should decrease after loss");

        // Yield equal to loss
        _accrueYield(500e6);
        uint256 recoveredAssets = vault.convertToAssets(aliceShares);

        // Rate should return to approximately original (within rounding)
        assertApproxEqAbs(
            recoveredAssets, initialAssets, 2, "Exchange rate should recover to approximately initial after equal yield"
        );
    }

    // ----- Additional: yieldSource-only access for absorbLoss -----
    function test_TC08_absorbLossUnauthorizedReverts() public {
        _depositViaQueue(alice, 1000e6);
        vm.prank(attacker);
        vm.expectRevert(atRISKUSD.UnauthorizedYieldSource.selector);
        vault.absorbLoss(100e6);
    }

    // ----- Additional: Zero amount absorbLoss reverts -----
    function test_TC08_absorbLossZeroAmountReverts() public {
        _depositViaQueue(alice, 1000e6);
        vm.prank(yieldSource);
        vm.expectRevert(atRISKUSD.ZeroAmount.selector);
        vault.absorbLoss(0);
    }

    // ----- Additional: totalLossAbsorbed counter cumulative -----
    function test_TC08_totalLossAbsorbedCounterCumulative() public {
        _depositViaQueue(alice, 1000e6);

        _absorbLoss(100e6);
        assertEq(vault.totalLossAbsorbed(), 100e6, "counter after first loss");

        _absorbLoss(200e6);
        assertEq(vault.totalLossAbsorbed(), 300e6, "counter after second loss");
    }

    // ----- OF-L22: absorbLoss bypasses pause for emergency loss reporting -----
    function test_TC08_absorbLossWorksWhenPaused() public {
        _depositViaQueue(alice, 1000e6);

        vm.prank(owner);
        vault.pause();

        // OF-L22: loss reporting bypasses pause — auth-gated by yieldSource
        vm.prank(yieldSource);
        vault.absorbLoss(100e6);

        // Verify loss was absorbed even when paused
        assertEq(vault.totalAssets(), 900e6, "Loss should be absorbed even when paused");
    }
}
