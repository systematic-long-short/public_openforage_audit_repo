// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/AtRISKUSDTestBase.sol";

// ============================================================
// TC-07: Exchange Rate Tests (R-08, R-09, R-10, R-11, R-12, R-42, R-43, R-44, R-40)
// ============================================================
contract AtRISKUSD_TC07_ExchangeRate is AtRISKUSDTestBase {
    // ----- L3 Step 1: Initial exchange rate is approximately 1:1 (with virtual offset) -----
    function test_TC07_initialExchangeRateApprox1to1() public view {
        // OF-002: With _decimalsOffset()=6, shares have 12 decimals (6 asset + 6 offset).
        // Empty vault: convertToShares(assets) = assets * 10^6 (virtual shares dominate).
        // So 1000e6 assets → 1000e12 shares. The "1:1" is at the decimal-adjusted level.
        uint256 shares = vault.convertToShares(1000e6);
        assertEq(shares, 1000e12, "initial convertToShares: 1000e6 assets -> 1000e12 shares");

        // convertToAssets(1000e12 shares) should return ~1000e6 assets
        uint256 assets = vault.convertToAssets(1000e12);
        assertApproxEqAbs(assets, 1000e6, 1, "initial convertToAssets: 1000e12 shares -> 1000e6 assets");
    }

    // ----- L3 Step 2: Non-yieldSource accrueYield reverts UnauthorizedYieldSource -----
    function test_TC07_accrueYieldNonYieldSourceReverts() public {
        _depositViaQueue(alice, 1000e6);
        riskusd.mint(attacker, 100e6);
        vm.startPrank(attacker);
        riskusd.approve(address(vault), 100e6);
        vm.expectRevert(atRISKUSD.UnauthorizedYieldSource.selector);
        vault.accrueYield(100e6);
        vm.stopPrank();
    }

    // ----- L3 Step 3: Zero amount accrueYield reverts ZeroAmount -----
    function test_TC07_accrueYieldZeroAmountReverts() public {
        _depositViaQueue(alice, 1000e6);
        vm.prank(yieldSource);
        vm.expectRevert(atRISKUSD.ZeroAmount.selector);
        vault.accrueYield(0);
    }

    // ----- L3 Step 4: Yield accrual happy path -----
    function test_TC07_accrueYieldHappyPath() public {
        uint256 depositAmount = 1000e6;
        uint256 aliceShares = _depositViaQueue(alice, depositAmount);

        // Accrue 100e6 yield
        _accrueYield(100e6);

        // (a) totalAssets updated
        assertEq(vault.totalAssets(), 1100e6, "totalAssets should be 1100e6 after yield");

        // (b) totalYieldAccrued updated
        assertEq(vault.totalYieldAccrued(), 100e6, "totalYieldAccrued should be 100e6");

        // (c) convertToShares(1100e6) returns approximately alice's shares
        // OF-002: With _decimalsOffset()=6, virtual shares (10^6) introduce bounded imprecision
        uint256 sharesFor1100 = vault.convertToShares(1100e6);
        assertApproxEqAbs(
            sharesFor1100, aliceShares, 1e6, "1100e6 assets should map to alice's shares (within virtual offset)"
        );
    }

    // ----- L3 Step 4e: YieldAccrued event emitted -----
    function test_TC07_accrueYieldEmitsEvent() public {
        _depositViaQueue(alice, 1000e6);

        riskusd.mint(yieldSource, 100e6);
        vm.startPrank(yieldSource);
        riskusd.approve(address(vault), 100e6);

        vm.expectEmit(false, false, false, true, address(vault));
        emit atRISKUSD.YieldAccrued(100e6);

        vault.accrueYield(100e6);
        vm.stopPrank();
    }

    // ----- L3 Step 5: Exchange rate increases after yield -----
    function test_TC07_exchangeRateIncreasesAfterYield() public {
        uint256 aliceShares = _depositViaQueue(alice, 1000e6);

        // Rate before yield
        uint256 assetsBefore = vault.convertToAssets(aliceShares);

        _accrueYield(100e6);

        // Rate after yield
        uint256 assetsAfter = vault.convertToAssets(aliceShares);

        assertTrue(assetsAfter > assetsBefore, "convertToAssets must return more after yield");
    }

    // ----- L3 Step 6: Non-yieldSource absorbLoss reverts UnauthorizedYieldSource -----
    function test_TC07_absorbLossNonYieldSourceReverts() public {
        _depositViaQueue(alice, 1000e6);
        vm.prank(attacker);
        vm.expectRevert(atRISKUSD.UnauthorizedYieldSource.selector);
        vault.absorbLoss(100e6);
    }

    // ----- L3 Step 7: Zero amount absorbLoss reverts ZeroAmount -----
    function test_TC07_absorbLossZeroAmountReverts() public {
        _depositViaQueue(alice, 1000e6);
        vm.prank(yieldSource);
        vm.expectRevert(atRISKUSD.ZeroAmount.selector);
        vault.absorbLoss(0);
    }

    // ----- L3 Step 8: Loss absorption happy path -----
    function test_TC07_absorbLossHappyPath() public {
        _depositViaQueue(alice, 1000e6);

        uint256 yieldSourceBalBefore = riskusd.balanceOf(yieldSource);

        _absorbLoss(200e6);

        // (a-b) 200e6 transferred to yieldSource
        assertEq(riskusd.balanceOf(yieldSource), yieldSourceBalBefore + 200e6, "yieldSource should receive 200e6");
        // (c) totalAssets updated
        assertEq(vault.totalAssets(), 800e6, "totalAssets should be 800e6 after loss");
        // (d) totalLossAbsorbed updated
        assertEq(vault.totalLossAbsorbed(), 200e6, "totalLossAbsorbed should be 200e6");
    }

    // ----- L3 Step 8e: LossAbsorbed event emitted -----
    function test_TC07_absorbLossEmitsEvent() public {
        _depositViaQueue(alice, 1000e6);

        vm.expectEmit(false, false, false, true, address(vault));
        emit atRISKUSD.LossAbsorbed(200e6);

        _absorbLoss(200e6);
    }

    // ----- L3 Step 9: Exchange rate decreases after loss -----
    function test_TC07_exchangeRateDecreasesAfterLoss() public {
        uint256 aliceShares = _depositViaQueue(alice, 1000e6);

        uint256 assetsBefore = vault.convertToAssets(aliceShares);

        _absorbLoss(200e6);

        uint256 assetsAfter = vault.convertToAssets(aliceShares);

        assertTrue(assetsAfter < assetsBefore, "convertToAssets must return less after loss");
    }

    // ----- L3 Step 10: Loss cap at totalAssets (excess ignored) -----
    function test_TC07_lossCappedAtTotalAssets() public {
        _depositViaQueue(alice, 500e6);

        uint256 yieldSourceBalBefore = riskusd.balanceOf(yieldSource);

        // Try to absorb 1000e6 but only 500e6 available
        vm.expectEmit(false, false, false, true, address(vault));
        emit atRISKUSD.LossAbsorbed(500e6);

        _absorbLoss(1000e6);

        // Only 500e6 should be transferred (capped)
        assertEq(
            riskusd.balanceOf(yieldSource),
            yieldSourceBalBefore + 500e6,
            "only totalAssets amount should be transferred"
        );
        assertEq(vault.totalAssets(), 0, "totalAssets should be 0 after capped loss");
    }

    // ----- L3 Step 11: Loss cap exact boundary -----
    function test_TC07_lossCappedExactBoundary() public {
        _depositViaQueue(alice, 500e6);

        _absorbLoss(500e6);

        assertEq(vault.totalAssets(), 0, "totalAssets should be 0 after exact-boundary loss");
    }

    // ----- L3 Step 12: Loss cap under boundary -----
    function test_TC07_lossCappedUnderBoundary() public {
        _depositViaQueue(alice, 500e6);

        _absorbLoss(499e6);

        assertEq(vault.totalAssets(), 1e6, "totalAssets should be 1e6 after under-boundary loss");
    }

    // ----- L3 Step 13: Sequential yield accruals — counter and monotonic rate -----
    function test_TC07_sequentialYieldAccruals() public {
        uint256 aliceShares = _depositViaQueue(alice, 1000e6);

        uint256 rate0 = vault.convertToAssets(aliceShares);

        _accrueYield(100e6);
        uint256 rate1 = vault.convertToAssets(aliceShares);
        assertTrue(rate1 > rate0, "rate after first yield > initial");

        _accrueYield(200e6);
        uint256 rate2 = vault.convertToAssets(aliceShares);
        assertTrue(rate2 > rate1, "rate after second yield > first yield");

        assertEq(vault.totalYieldAccrued(), 300e6, "totalYieldAccrued should be 300e6");
    }

    // ----- L3 Step 14: Sequential loss absorptions — counter and monotonic rate decrease -----
    function test_TC07_sequentialLossAbsorptions() public {
        uint256 aliceShares = _depositViaQueue(alice, 1000e6);

        uint256 rate0 = vault.convertToAssets(aliceShares);

        _absorbLoss(100e6);
        uint256 rate1 = vault.convertToAssets(aliceShares);
        assertTrue(rate1 < rate0, "rate after first loss < initial");

        _absorbLoss(200e6);
        uint256 rate2 = vault.convertToAssets(aliceShares);
        assertTrue(rate2 < rate1, "rate after second loss < first loss");

        assertEq(vault.totalLossAbsorbed(), 300e6, "totalLossAbsorbed should be 300e6");
    }

    // ----- L3 Step 15: Yield then loss — rate between initial and post-yield -----
    function test_TC07_yieldThenLoss() public {
        uint256 aliceShares = _depositViaQueue(alice, 1000e6);

        uint256 rateInitial = vault.convertToAssets(aliceShares);

        _accrueYield(500e6); // totalAssets = 1500e6
        uint256 rateAfterYield = vault.convertToAssets(aliceShares);

        _absorbLoss(300e6); // totalAssets = 1200e6
        uint256 rateAfterLoss = vault.convertToAssets(aliceShares);

        assertTrue(rateAfterLoss > rateInitial, "rate after yield+loss > initial");
        assertTrue(rateAfterLoss < rateAfterYield, "rate after yield+loss < post-yield");
    }

    // ----- L3 Step 16: Loss then yield (recovery) -----
    function test_TC07_lossThenYieldRecovery() public {
        uint256 aliceShares = _depositViaQueue(alice, 1000e6);

        uint256 rateInitial = vault.convertToAssets(aliceShares);

        _absorbLoss(300e6); // totalAssets = 700e6
        _accrueYield(500e6); // totalAssets = 1200e6

        uint256 rateAfterRecovery = vault.convertToAssets(aliceShares);

        assertTrue(rateAfterRecovery > rateInitial, "rate after recovery should exceed initial");
    }

    // ----- L3 Step 17: convertToShares rounds down (against depositor) -----
    function test_TC07_convertToSharesRoundsDown() public {
        _depositViaQueue(alice, 1000e6);
        _accrueYield(333e6); // Non-trivial exchange rate

        // Deposit 1 wei — shares received must be floor(1 * totalSupply / totalAssets)
        uint256 shares = vault.convertToShares(1);
        uint256 totalSupply = vault.totalSupply();
        uint256 totalAssets = vault.totalAssets();

        // Floor calculation: 1 * totalSupply / totalAssets
        uint256 expectedFloor = (1 * totalSupply) / totalAssets;
        assertEq(shares, expectedFloor, "convertToShares should round down");
    }

    // ----- L3 Step 18: convertToAssets rounds down (against withdrawer) -----
    function test_TC07_convertToAssetsRoundsDown() public {
        _depositViaQueue(alice, 1000e6);
        _accrueYield(333e6); // Non-trivial exchange rate

        // Redeem 1 share — assets received must be floor(1 * totalAssets / totalSupply)
        uint256 assets = vault.convertToAssets(1);
        uint256 totalSupply = vault.totalSupply();
        uint256 totalAssets = vault.totalAssets();

        uint256 expectedFloor = (1 * totalAssets) / totalSupply;
        assertEq(assets, expectedFloor, "convertToAssets should round down");
    }

    // ----- L3 Step 19: Precision at extreme exchange rates (1000:1) -----
    function test_TC07_precisionAtExtremeRate() public {
        // Deposit 1e6 RISKUSD (1 USDC)
        uint256 aliceShares = _depositViaQueue(alice, 1e6);

        // Accrue yield to push rate to ~1000:1 (1 share = ~1000 RISKUSD)
        _accrueYield(999e6); // totalAssets = 1000e6

        // Verify consistency: convertToAssets(convertToShares(X)) <= X
        uint256 testAmount = 500e6;
        uint256 shares = vault.convertToShares(testAmount);
        uint256 roundTrip = vault.convertToAssets(shares);

        assertTrue(roundTrip <= testAmount, "round-trip must not profit the user");
        // Also verify that at least some precision is maintained
        assertTrue(shares > 0, "shares should be > 0 for non-zero input at extreme rate");
        assertTrue(roundTrip > 0, "assets should be > 0 for non-zero shares at extreme rate");
    }

    // ----- L3 Step 20: Paused state blocks accrueYield -----
    function test_TC07_accrueYieldPausedReverts() public {
        _depositViaQueue(alice, 1000e6);

        vm.prank(owner);
        vault.pause();

        riskusd.mint(yieldSource, 100e6);
        vm.startPrank(yieldSource);
        riskusd.approve(address(vault), 100e6);
        vm.expectRevert();
        vault.accrueYield(100e6);
        vm.stopPrank();
    }

    // ----- OF-L22: absorbLoss bypasses pause for emergency loss reporting -----
    function test_TC07_absorbLossWorksWhenPaused() public {
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
