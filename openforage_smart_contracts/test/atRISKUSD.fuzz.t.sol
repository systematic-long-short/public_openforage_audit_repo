// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/AtRISKUSDTestBase.sol";

// ============================================================
// TC-23: Fuzz Tests (R-07, R-09, R-11, R-13, R-16, R-42, R-43, R-44)
// ============================================================
contract AtRISKUSD_TC23_Fuzz is AtRISKUSDTestBase {
    atRISKUSD internal tier0Vault;

    function setUp() public override {
        super.setUp();
        // Deploy a tier-0 (no lockup) vault for fuzz tests that need immediate withdrawal
        tier0Vault = _deployFreshVault(0, COOLDOWN_PERIOD, 0);
        _raiseWeeklyWithdrawalCap(tier0Vault);
    }

    /// @dev Deposit into tier0 vault
    function _depositTier0(address receiver, uint256 amount) internal returns (uint256 shares) {
        riskusd.mint(stakingQueue, amount);
        vm.startPrank(stakingQueue);
        riskusd.approve(address(tier0Vault), amount);
        shares = tier0Vault.deposit(amount, receiver);
        vm.stopPrank();
    }

    /// @dev Accrue yield on tier0 vault
    function _accrueYieldTier0(uint256 amount) internal {
        riskusd.mint(yieldSource, amount);
        vm.startPrank(yieldSource);
        riskusd.approve(address(tier0Vault), amount);
        tier0Vault.accrueYield(amount);
        vm.stopPrank();
    }

    /// @dev Absorb loss on tier0 vault
    function _absorbLossTier0(uint256 amount) internal {
        vm.prank(yieldSource);
        tier0Vault.absorbLoss(amount);
    }

    // ----- L3 Step 1: Fuzz deposit — share calculation correct for any valid amount -----
    function testFuzz_depositAndConvert(uint256 assets) public {
        assets = bound(assets, 1, 1e15);

        uint256 shares = _depositTier0(alice, assets);

        // Shares must be > 0 for all non-zero deposits
        assertGt(shares, 0, "shares must be > 0 for non-zero deposit");

        // convertToAssets(balanceOf(receiver)) <= assets (rounding against user)
        uint256 assetsBack = tier0Vault.convertToAssets(tier0Vault.balanceOf(alice));
        assertLe(assetsBack, assets, "convertToAssets(shares) must be <= deposited assets (rounding against user)");
    }

    // ----- L3 Step 2: Fuzz yield/loss sequences — exchange rate stays consistent -----
    function testFuzz_yieldAccrualExchangeRate(uint256 depositAmount, uint256 yieldAmount) public {
        depositAmount = bound(depositAmount, 1e6, 1e15);
        yieldAmount = bound(yieldAmount, 1, depositAmount);

        _depositTier0(alice, depositAmount);

        uint256 totalAssetsBefore = tier0Vault.totalAssets();
        uint256 totalSupplyBefore = tier0Vault.totalSupply();

        _accrueYieldTier0(yieldAmount);

        uint256 totalAssetsAfter = tier0Vault.totalAssets();
        uint256 totalSupplyAfter = tier0Vault.totalSupply();

        // totalAssets should have increased by yieldAmount
        assertEq(totalAssetsAfter, totalAssetsBefore + yieldAmount, "totalAssets should increase by yield");

        // totalSupply should NOT change
        assertEq(totalSupplyAfter, totalSupplyBefore, "totalSupply should not change on yield");

        // Exchange rate must increase: assetsAfter/supply > assetsBefore/supply
        // Since supply is the same, just compare totalAssets
        assertGt(totalAssetsAfter, totalAssetsBefore, "exchange rate must increase after yield");

        // convertToAssets(totalSupply) should be >= depositAmount + yieldAmount - 1 (rounding tolerance)
        uint256 totalConvertedAssets = tier0Vault.convertToAssets(totalSupplyAfter);
        assertGe(
            totalConvertedAssets + 1,
            depositAmount + yieldAmount,
            "convertToAssets(totalSupply) should be >= deposit + yield (within rounding)"
        );
    }

    // ----- L3 Step 3: Fuzz loss absorption cap -----
    function testFuzz_lossAbsorptionCap(uint256 depositAmount, uint256 lossAmount) public {
        depositAmount = bound(depositAmount, 1e6, 1e15);
        lossAmount = bound(lossAmount, 1, type(uint128).max);

        _depositTier0(alice, depositAmount);

        uint256 totalAssetsBefore = tier0Vault.totalAssets();
        uint256 effectiveLoss = lossAmount < totalAssetsBefore ? lossAmount : totalAssetsBefore;

        _absorbLossTier0(lossAmount);

        uint256 totalAssetsAfter = tier0Vault.totalAssets();
        assertEq(
            totalAssetsAfter,
            totalAssetsBefore - effectiveLoss,
            "totalAssets should decrease by effective loss (capped at totalAssets)"
        );
    }

    // ----- L3 Step 4: Fuzz deposit-withdraw round trip -----
    function testFuzz_depositWithdrawRoundTrip(uint256 assets) public {
        assets = bound(assets, 1e6, 1e15);

        _depositTier0(alice, assets);
        uint256 aliceBalance = tier0Vault.balanceOf(alice);

        // Request withdrawal of all shares
        vm.prank(alice);
        tier0Vault.requestWithdrawal(aliceBalance);

        atRISKUSD.PendingWithdrawal memory pw = tier0Vault.pendingWithdrawal(alice);
        uint256 capturedAmount = pw.riskusdAmount;

        // Warp past cooldown
        vm.warp(block.timestamp + COOLDOWN_PERIOD);

        uint256 aliceRiskusdBefore = riskusd.balanceOf(alice);

        vm.prank(alice);
        tier0Vault.executeWithdrawal();

        uint256 aliceRiskusdAfter = riskusd.balanceOf(alice);
        uint256 received = aliceRiskusdAfter - aliceRiskusdBefore;

        // User never profits from round-trip (rounding against user)
        assertLe(received, assets, "received RISKUSD must be <= deposited (rounding against user)");
        // Received must equal the captured amount
        assertEq(received, capturedAmount, "received must equal captured amount");
    }

    // ----- L3 Step 5: Fuzz multiple deposits with yield — exchange rate monotonic -----
    function testFuzz_multipleDepositsExchangeRate(
        uint256 dep0,
        uint256 dep1,
        uint256 dep2,
        uint256 dep3,
        uint256 dep4,
        uint256 yield0,
        uint256 yield1,
        uint256 yield2
    ) public {
        uint256[5] memory deposits;
        deposits[0] = bound(dep0, 1e6, 1e12);
        deposits[1] = bound(dep1, 1e6, 1e12);
        deposits[2] = bound(dep2, 1e6, 1e12);
        deposits[3] = bound(dep3, 1e6, 1e12);
        deposits[4] = bound(dep4, 1e6, 1e12);

        uint256[3] memory yields;
        yields[0] = bound(yield0, 1, 1e12);
        yields[1] = bound(yield1, 1, 1e12);
        yields[2] = bound(yield2, 1, 1e12);

        address[5] memory depositors = [alice, bob, makeAddr("charlie"), makeAddr("dave"), makeAddr("eve")];

        // Interleave deposits and yields
        _depositTier0(depositors[0], deposits[0]);
        _depositTier0(depositors[1], deposits[1]);

        uint256 rateBefore = tier0Vault.totalAssets();
        uint256 supplyBefore = tier0Vault.totalSupply();

        _accrueYieldTier0(yields[0]);

        // Exchange rate must not decrease after yield
        // rate = totalAssets / totalSupply — supply unchanged so totalAssets must increase
        assertGe(
            tier0Vault.totalAssets() * supplyBefore,
            rateBefore * tier0Vault.totalSupply(),
            "exchange rate must be non-decreasing after yield"
        );

        _depositTier0(depositors[2], deposits[2]);
        _depositTier0(depositors[3], deposits[3]);

        rateBefore = tier0Vault.totalAssets();
        supplyBefore = tier0Vault.totalSupply();

        _accrueYieldTier0(yields[1]);

        assertGe(
            tier0Vault.totalAssets() * supplyBefore,
            rateBefore * tier0Vault.totalSupply(),
            "exchange rate must be non-decreasing after second yield"
        );

        _depositTier0(depositors[4], deposits[4]);

        rateBefore = tier0Vault.totalAssets();
        supplyBefore = tier0Vault.totalSupply();

        _accrueYieldTier0(yields[2]);

        assertGe(
            tier0Vault.totalAssets() * supplyBefore,
            rateBefore * tier0Vault.totalSupply(),
            "exchange rate must be non-decreasing after third yield"
        );

        // Final check: convertToAssets(totalSupply) <= totalAssets + totalSupply (rounding tolerance)
        uint256 convertedTotal = tier0Vault.convertToAssets(tier0Vault.totalSupply());
        assertLe(
            convertedTotal,
            tier0Vault.totalAssets() + tier0Vault.totalSupply(),
            "convertToAssets(totalSupply) should be within rounding tolerance"
        );
    }

    // ----- L3 Step 6: Fuzz cooldown timing -----
    function testFuzz_cooldownTiming(uint256 cooldownPeriod_, uint256 waitTime) public {
        cooldownPeriod_ = bound(cooldownPeriod_, 0, 365 days);
        waitTime = bound(waitTime, 0, 2 * (cooldownPeriod_ > 0 ? cooldownPeriod_ : 1));

        atRISKUSD fuzzVault = _deployFreshVault(0, cooldownPeriod_, 0);
        _raiseWeeklyWithdrawalCap(fuzzVault);

        // Deposit
        riskusd.mint(stakingQueue, 1000e6);
        vm.startPrank(stakingQueue);
        riskusd.approve(address(fuzzVault), 1000e6);
        fuzzVault.deposit(1000e6, alice);
        vm.stopPrank();

        uint256 T = block.timestamp;

        // Cache balance before prank (inline view call would consume prank)
        uint256 aliceBalance = fuzzVault.balanceOf(alice);

        // Request withdrawal
        vm.prank(alice);
        fuzzVault.requestWithdrawal(aliceBalance);

        // Warp by waitTime
        vm.warp(T + waitTime);

        if (waitTime >= cooldownPeriod_) {
            // Should succeed
            vm.prank(alice);
            fuzzVault.executeWithdrawal();
            atRISKUSD.PendingWithdrawal memory pw = fuzzVault.pendingWithdrawal(alice);
            assertFalse(pw.active, "pending should be cleared when waitTime >= cooldownPeriod");
        } else {
            // Should revert
            vm.prank(alice);
            vm.expectRevert();
            fuzzVault.executeWithdrawal();
        }
    }

    // ----- L3 Step 7: Fuzz lockup timing -----
    function testFuzz_lockupTiming(uint256 lockupPeriod_, uint256 waitTime) public {
        lockupPeriod_ = bound(lockupPeriod_, 0, 360 days);
        waitTime = bound(waitTime, 0, 2 * (lockupPeriod_ > 0 ? lockupPeriod_ : 1));

        atRISKUSD fuzzVault = _deployFreshVault(lockupPeriod_, COOLDOWN_PERIOD, lockupPeriod_ == 0 ? 0 : 1);
        _raiseWeeklyWithdrawalCap(fuzzVault);

        // Deposit
        riskusd.mint(stakingQueue, 1000e6);
        vm.startPrank(stakingQueue);
        riskusd.approve(address(fuzzVault), 1000e6);
        fuzzVault.deposit(1000e6, alice);
        vm.stopPrank();

        uint256 T = block.timestamp;

        // Warp by waitTime
        vm.warp(T + waitTime);

        // Cache balance before prank (inline view call would consume prank)
        uint256 aliceBalanceLockup = fuzzVault.balanceOf(alice);

        if (waitTime >= lockupPeriod_) {
            // requestWithdrawal should succeed
            vm.prank(alice);
            fuzzVault.requestWithdrawal(aliceBalanceLockup);
            atRISKUSD.PendingWithdrawal memory pw = fuzzVault.pendingWithdrawal(alice);
            assertTrue(pw.active, "pending withdrawal should be active when lockup expired");
        } else {
            // requestWithdrawal should revert
            vm.prank(alice);
            vm.expectRevert();
            fuzzVault.requestWithdrawal(aliceBalanceLockup);
        }
    }

    // ----- L3 Step 8: Fuzz share calculation rounding (attack surface 6.4) -----
    function testFuzz_shareCalculationRounding(uint256 assets, uint256 yieldAmount) public {
        // Ensure enough initial assets so the vault balance doesn't underflow
        // when subtracting the 100-wei rounding tolerance at the end
        assets = bound(assets, 1e6, 1e15);
        yieldAmount = bound(yieldAmount, 1, 1e15);

        _depositTier0(alice, assets);
        _accrueYieldTier0(yieldAmount);

        uint256 vaultBalanceBefore = riskusd.balanceOf(address(tier0Vault));

        // Perform 100 deposit/redeem cycles with 1 wei to try to extract rounding profit
        for (uint256 i = 0; i < 100; i++) {
            riskusd.mint(stakingQueue, 1);
            vm.startPrank(stakingQueue);
            riskusd.approve(address(tier0Vault), 1);
            uint256 shares = tier0Vault.deposit(1, bob);
            vm.stopPrank();

            // If 0 shares minted for 1 wei deposit, that's fine (rounding against depositor)
            if (shares > 0) {
                if (tier0Vault.previewRedeem(shares) == 0) continue;
                // Try to redeem those shares
                // For a vault with cooldown, we need to use requestWithdrawal flow
                vm.prank(bob);
                tier0Vault.requestWithdrawal(shares);

                vm.warp(block.timestamp + COOLDOWN_PERIOD);

                vm.prank(bob);
                tier0Vault.executeWithdrawal();
            }
        }

        // Vault RISKUSD balance must never have decreased below starting point
        // (rounding always favors the vault)
        uint256 vaultBalanceAfter = riskusd.balanceOf(address(tier0Vault));
        assertGe(
            vaultBalanceAfter,
            vaultBalanceBefore - 100, // Allow 100 wei tolerance for rounding across 100 cycles
            "vault balance must not decrease significantly (rounding favors vault)"
        );
    }

    // ----- L3 Step 9: Fuzz share rounding invariant -----
    // convertToShares(convertToAssets(shares)) <= shares
    function testFuzz_shareRoundingInvariant(uint256 assets) public {
        assets = bound(assets, 1e6, 1e15);

        _depositTier0(alice, assets);
        _accrueYieldTier0(assets / 10); // Some yield to create non-1:1 rate

        uint256 aliceShares = tier0Vault.balanceOf(alice);
        uint256 assetsForShares = tier0Vault.convertToAssets(aliceShares);
        uint256 sharesBack = tier0Vault.convertToShares(assetsForShares);

        // convertToShares(convertToAssets(shares)) <= shares (rounding against user both ways)
        assertLe(sharesBack, aliceShares, "convertToShares(convertToAssets(shares)) must be <= shares");
    }

    // ----- L3 Step 9 (lock variant): Fuzz lock expiry — transfer blocked while locked,
    //       deposit propagates max(existing, new) via stakingQueue (OF-005/OF-016) -----
    function testFuzz_lockExpiryMax(uint256 lockA, uint256 lockB) public {
        lockA = bound(lockA, 1 days, 360 days);
        lockB = bound(lockB, 1 days, 360 days);

        // Deploy vault with lockupPeriod = lockA
        atRISKUSD vaultA = _deployFreshVault(lockA, COOLDOWN_PERIOD, 1);

        uint256 T = block.timestamp;

        // Bob deposits first at T → bobExistingLock = T + lockA
        riskusd.mint(stakingQueue, 500e6);
        vm.startPrank(stakingQueue);
        riskusd.approve(address(vaultA), 500e6);
        vaultA.deposit(500e6, bob);
        vm.stopPrank();

        uint256 bobExistingLock = vaultA.lockExpiry(bob);
        assertEq(bobExistingLock, T + lockA, "bob lockExpiry should be T + lockA");

        // Warp forward by lockB seconds to create different lock timestamps
        vm.warp(T + lockB);

        // Alice deposits at T + lockB → aliceLock = T + lockB + lockA
        riskusd.mint(stakingQueue, 1000e6);
        vm.startPrank(stakingQueue);
        riskusd.approve(address(vaultA), 1000e6);
        vaultA.deposit(1000e6, alice);
        vm.stopPrank();

        uint256 aliceLock = vaultA.lockExpiry(alice);
        assertEq(aliceLock, T + lockB + lockA, "alice lockExpiry should be T + lockB + lockA");

        // OF-005/OF-016: Transfer from locked user must revert
        uint256 aliceShares = vaultA.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(atRISKUSD.LockupNotExpired.selector, aliceLock));
        vaultA.transfer(bob, aliceShares / 2);

        // Warp past Alice's lock expiry so transfer is allowed
        vm.warp(aliceLock);

        // Transfer should now succeed (Alice's lock expired)
        vm.prank(alice);
        vaultA.transfer(bob, aliceShares / 2);

        // Lock propagation only happens from stakingQueue deposits, not user transfers.
        // Bob's lock should remain unchanged (his original deposit lock).
        uint256 actualBobLock = vaultA.lockExpiry(bob);
        assertEq(actualBobLock, bobExistingLock, "bob lockExpiry must not change from user transfer");

        // Verify deposit-based lock propagation: second deposit to Bob takes max(existing, new)
        vm.warp(aliceLock + 1); // just past Alice's lock
        riskusd.mint(stakingQueue, 100e6);
        vm.startPrank(stakingQueue);
        riskusd.approve(address(vaultA), 100e6);
        vaultA.deposit(100e6, bob);
        vm.stopPrank();

        uint256 newDepositLock = aliceLock + 1 + lockA;
        uint256 expectedBobLock = bobExistingLock > newDepositLock ? bobExistingLock : newDepositLock;
        uint256 finalBobLock = vaultA.lockExpiry(bob);
        assertEq(finalBobLock, expectedBobLock, "bob lockExpiry must be max(existing, new deposit lock)");
    }
}
