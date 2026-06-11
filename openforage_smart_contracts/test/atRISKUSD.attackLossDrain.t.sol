// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/AtRISKUSDTestBase.sol";

// ============================================================
// TC-22: Attack Vector -- Loss Absorption Drain Tests (R-10, R-11, R-12, R-44)
// ============================================================
contract AtRISKUSD_TC22_AttackLossDrain is AtRISKUSDTestBase {
    function setUp() public override {
        super.setUp();
        _raiseWeeklyWithdrawalCap(vault);
    }

    // ----- L3 Step 1: Sustained loss erosion (13.2) -----
    // 10 sequential losses, each 10% of current totalAssets.
    // After 10 losses: totalAssets ~34.9% of original (0.9^10).
    function test_TC22_sustainedLossErosion_10PercentRepeated() public {
        uint256 initialDeposit = 1_000_000e6;
        uint256 aliceShares = _depositViaQueue(alice, initialDeposit);
        uint256 bobShares = _depositViaQueue(bob, 500_000e6);

        uint256 totalSharesBefore = vault.totalSupply();
        uint256 totalLossBefore = vault.totalLossAbsorbed();

        // Track exchange rate decrease with each loss
        uint256 prevAssets = vault.totalAssets();
        uint256 cumulativeLoss = 0;

        for (uint256 i = 0; i < 10; i++) {
            uint256 currentAssets = vault.totalAssets();
            uint256 lossAmount = currentAssets / 10; // 10% of current totalAssets

            _absorbLoss(lossAmount);
            cumulativeLoss += lossAmount;

            uint256 newAssets = vault.totalAssets();

            // (a) Exchange rate decreased with this loss
            assertTrue(newAssets < currentAssets, "totalAssets must decrease after each loss");

            // (b) Share balances unchanged
            assertEq(vault.balanceOf(alice), aliceShares, "Alice shares unchanged after loss");
            assertEq(vault.balanceOf(bob), bobShares, "Bob shares unchanged after loss");
        }

        // After 10 losses of 10% each: totalAssets should be ~34.9% of original
        // Original: 1_500_000e6, expected ~523_658e6 (1_500_000 * 0.9^10)
        uint256 finalAssets = vault.totalAssets();
        uint256 expectedApprox = 1_500_000e6 * 3487 / 10000; // 0.3487 approximation
        assertApproxEqRel(
            finalAssets,
            expectedApprox,
            1e16, // 1% tolerance for rounding over 10 iterations
            "After 10x 10% losses, totalAssets should be ~34.87% of original"
        );

        // (c) totalLossAbsorbed accumulates correctly
        assertEq(
            vault.totalLossAbsorbed(), totalLossBefore + cumulativeLoss, "totalLossAbsorbed must accumulate all losses"
        );

        // (d) Depositors can still request withdrawal at reduced rate
        vm.warp(block.timestamp + LOCKUP_PERIOD);
        uint256 aliceShareBalance = vault.balanceOf(alice);
        uint256 expectedRiskusd = vault.previewRedeem(aliceShareBalance);

        vm.prank(alice);
        vault.requestWithdrawal(aliceShareBalance);

        atRISKUSD.PendingWithdrawal memory pw = vault.pendingWithdrawal(alice);
        assertEq(pw.riskusdAmount, expectedRiskusd, "Withdrawal captured at reduced rate");
        assertTrue(pw.riskusdAmount < initialDeposit, "Post-loss withdrawal amount must be less than initial deposit");
    }

    // ----- L3 Step 2: Total drain + further absorbLoss with totalAssets == 0 -----
    function test_TC22_totalDrain_furtherAbsorbLossIsZero() public {
        _depositViaQueue(alice, 1000e6);

        // Total drain
        _absorbLoss(1000e6);
        assertEq(vault.totalAssets(), 0, "totalAssets should be 0 after total drain");

        // Further absorbLoss: effective = min(100e6, 0) = 0
        uint256 yieldSourceBalBefore = riskusd.balanceOf(yieldSource);
        uint256 totalLossBefore = vault.totalLossAbsorbed();

        // Per L3 spec: absorbLoss caps at totalAssets. effective = min(100e6, 0) = 0.
        // Call should succeed with zero-effective loss. LossAbsorbed(0) emitted.
        vm.prank(yieldSource);
        vm.expectEmit(false, false, false, true);
        emit atRISKUSD.LossAbsorbed(0);
        vault.absorbLoss(100e6);

        // Verify 0 RISKUSD transferred
        assertEq(
            riskusd.balanceOf(yieldSource),
            yieldSourceBalBefore,
            "No RISKUSD should be transferred when totalAssets == 0"
        );

        // totalLossAbsorbed should record the effective amount (0)
        assertEq(vault.totalLossAbsorbed(), totalLossBefore, "totalLossAbsorbed unchanged when effective loss is 0");

        // totalAssets remains 0
        assertEq(vault.totalAssets(), 0, "totalAssets still 0 after zero-effective loss");
    }

    // ----- L3 Step 3: Exchange rate manipulation via loss then deposit (13.3) -----
    // Attack requires yieldSource auth for both loss and yield -- regular user cannot exploit.
    function test_TC22_lossDepositYieldManipulation_requiresAuth() public {
        _depositViaQueue(alice, 1000e6);

        // (a) Only yieldSource can absorb loss
        vm.prank(attacker);
        vm.expectRevert(atRISKUSD.UnauthorizedYieldSource.selector);
        vault.absorbLoss(500e6);

        // (b) Only yieldSource can accrue yield
        riskusd.mint(attacker, 500e6);
        vm.prank(attacker);
        vm.expectRevert(atRISKUSD.UnauthorizedYieldSource.selector);
        vault.accrueYield(500e6);

        // (c) Attacker cannot deposit directly -- only StakingQueue can
        vm.prank(attacker);
        riskusd.approve(address(vault), 1000e6);
        vm.prank(attacker);
        vm.expectRevert(atRISKUSD.UnauthorizedStakingQueue.selector);
        vault.deposit(1000e6, attacker);
    }

    // ----- L3 Step 3 variant: If authorized, the manipulation does work (expected behavior) -----
    function test_TC22_lossDepositYieldSequence_authorizedBehavior() public {
        _depositViaQueue(alice, 1000e6);
        uint256 aliceShares = vault.balanceOf(alice);

        uint256 aliceValueBefore = vault.convertToAssets(aliceShares);

        // (a) YieldSource absorbs loss -- deflates rate
        _absorbLoss(500e6);
        uint256 aliceValueAfterLoss = vault.convertToAssets(aliceShares);
        assertTrue(aliceValueAfterLoss < aliceValueBefore, "Alice value should decrease after loss");

        // (b) Attacker deposits at deflated rate (gets more shares per RISKUSD)
        uint256 attackerShares = _depositViaQueue(attacker, 500e6);

        // (c) YieldSource accrues yield -- inflates rate
        _accrueYield(500e6);
        uint256 attackerValueAfterYield = vault.convertToAssets(attackerShares);

        // Attacker deposited 500e6 and now has shares worth more
        // But this is only possible if attacker controls both loss and yield timing,
        // which requires yieldSource authorization. A regular user cannot do this.
        assertTrue(attackerValueAfterYield > 0, "Attacker shares have value after yield");
    }

    // ----- L3 Step 4: Recovery after drain is blocked while legacy shares remain -----
    function test_TC22_recoveryAfterDrainRevertsWithLegacySupply() public {
        _depositViaQueue(alice, 1000e6);

        // Total drain
        _absorbLoss(1000e6);
        assertEq(vault.totalAssets(), 0, "totalAssets should be 0 after drain");

        // OPEN-20: normal yield recovery must not recapitalize stale zero-value shares.
        riskusd.mint(yieldSource, 100e6);
        vm.startPrank(yieldSource);
        riskusd.approve(address(vault), 100e6);
        vm.expectRevert(atRISKUSD.ZeroAssetLegacySupply.selector);
        vault.accrueYield(100e6);
        vm.stopPrank();
        assertEq(vault.totalAssets(), 0, "totalAssets should remain 0 after blocked recovery yield");
    }

    // ----- L3 Step 5: Loss capping prevents over-drain -----
    function test_TC22_lossCappingPreventsOverDrain() public {
        _depositViaQueue(alice, 100e6);

        uint256 yieldSourceBalBefore = riskusd.balanceOf(yieldSource);

        // absorbLoss with max uint256 -- should cap to totalAssets (100e6)
        _absorbLoss(type(uint256).max);

        // Only 100e6 should have been transferred
        assertEq(
            riskusd.balanceOf(yieldSource), yieldSourceBalBefore + 100e6, "Transfer should be capped at totalAssets"
        );
        assertEq(vault.totalAssets(), 0, "totalAssets should be 0 after capped drain");

        // OPEN-20: normal deposit must not recapitalize stale zero-value shares.
        riskusd.mint(stakingQueue, 200e6);
        vm.startPrank(stakingQueue);
        riskusd.approve(address(vault), 200e6);
        vm.expectRevert(atRISKUSD.ZeroAssetLegacySupply.selector);
        vault.deposit(200e6, bob);
        vm.stopPrank();
        assertEq(vault.totalAssets(), 0, "totalAssets should remain 0 after blocked deposit");
    }

    // ----- L3 Step 6: Concurrent deposit and loss — state consistent regardless of ordering -----
    function test_TC22_concurrentDepositAndLoss_depositFirst() public {
        _depositViaQueue(alice, 1000e6);

        // Deposit first, then loss
        uint256 bobShares = _depositViaQueue(bob, 500e6);
        _absorbLoss(500e6);

        // State should be consistent
        uint256 finalAssets = vault.totalAssets();
        assertEq(finalAssets, 1000e6, "totalAssets = 1500e6 - 500e6 = 1000e6");
        assertTrue(vault.balanceOf(bob) > 0, "Bob should have shares");
    }

    function test_TC22_concurrentDepositAndLoss_lossFirst() public {
        _depositViaQueue(alice, 1000e6);

        // Loss first, then deposit
        _absorbLoss(500e6);
        uint256 bobShares = _depositViaQueue(bob, 500e6);

        // State should be consistent (but exchange rate is different)
        uint256 finalAssets = vault.totalAssets();
        assertEq(finalAssets, 1000e6, "totalAssets = 1000e6 - 500e6 + 500e6 = 1000e6");
        assertTrue(vault.balanceOf(bob) > 0, "Bob should have shares");

        // Bob gets more shares when depositing after loss (lower exchange rate)
        // This is expected and correct behavior
    }

    // ----- Additional: Exchange rate decreases proportionally with each loss -----
    function test_TC22_exchangeRateDecreasesProportionally() public {
        _depositViaQueue(alice, 1000e6);

        uint256 totalSupply = vault.totalSupply();

        // Rate before any loss
        uint256 assetsBefore = vault.convertToAssets(totalSupply);

        // 50% loss
        _absorbLoss(500e6);
        uint256 assetsAfter50 = vault.convertToAssets(totalSupply);

        // Assets should be approximately halved
        assertApproxEqAbs(
            assetsAfter50, assetsBefore / 2, 2, "After 50% loss, assets per totalSupply should be ~halved"
        );

        // Another 50% loss (of remaining)
        _absorbLoss(250e6);
        uint256 assetsAfter75 = vault.convertToAssets(totalSupply);

        // Assets should be approximately quartered from original
        assertApproxEqAbs(
            assetsAfter75, assetsBefore / 4, 2, "After 75% total loss, assets per totalSupply should be ~quartered"
        );
    }

    // ----- Additional: Unauthorized caller cannot call absorbLoss -----
    function test_TC22_unauthorizedAbsorbLossReverts() public {
        _depositViaQueue(alice, 1000e6);

        vm.prank(attacker);
        vm.expectRevert(atRISKUSD.UnauthorizedYieldSource.selector);
        vault.absorbLoss(100e6);

        vm.prank(alice);
        vm.expectRevert(atRISKUSD.UnauthorizedYieldSource.selector);
        vault.absorbLoss(100e6);

        vm.prank(stakingQueue);
        vm.expectRevert(atRISKUSD.UnauthorizedYieldSource.selector);
        vault.absorbLoss(100e6);

        vm.prank(owner);
        vm.expectRevert(atRISKUSD.UnauthorizedYieldSource.selector);
        vault.absorbLoss(100e6);
    }
}
