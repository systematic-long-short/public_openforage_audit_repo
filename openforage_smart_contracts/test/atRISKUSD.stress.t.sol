// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/AtRISKUSDTestBase.sol";

// ============================================================
// TC-25: Stress Tests (R-06, R-11, R-12, R-41, R-42, R-43)
// ============================================================
contract AtRISKUSD_TC25_Stress is AtRISKUSDTestBase {
    atRISKUSD internal tier0Vault;

    function setUp() public override {
        super.setUp();
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

    // ----- L3 Step 1: Many depositors (100 depositors, proportional shares) -----
    function testStress_manyDepositors() public {
        uint256 numDepositors = 100;
        address[] memory depositors = new address[](numDepositors);
        uint256[] memory amounts = new uint256[](numDepositors);
        uint256[] memory shareAmounts = new uint256[](numDepositors);
        uint256 totalDeposited = 0;

        for (uint256 i = 0; i < numDepositors; i++) {
            depositors[i] = makeAddr(string(abi.encodePacked("depositor", vm.toString(i))));
            amounts[i] = (i + 1) * 1e6; // 1 RISKUSD to 100 RISKUSD
            totalDeposited += amounts[i];
        }

        // Deposit for each
        for (uint256 i = 0; i < numDepositors; i++) {
            shareAmounts[i] = _depositTier0(depositors[i], amounts[i]);
            assertGt(shareAmounts[i], 0, "each depositor must receive shares");
        }

        // totalSupply == sum of all shares (minus virtual offset check is impractical, just check sum)
        uint256 totalShares = 0;
        for (uint256 i = 0; i < numDepositors; i++) {
            totalShares += tier0Vault.balanceOf(depositors[i]);
        }
        // totalSupply includes virtual offset, so it may be slightly more than sum of minted shares
        assertGe(tier0Vault.totalSupply(), totalShares, "totalSupply must be >= sum of all shares");

        // totalAssets == sum of all deposits
        assertEq(tier0Vault.totalAssets(), totalDeposited, "totalAssets must equal sum of deposits");

        // Each depositor's convertToAssets(balance) is proportional to their deposit
        // With virtual offset, slight rounding expected. Verify within 1 wei per depositor.
        for (uint256 i = 0; i < numDepositors; i++) {
            uint256 balance = tier0Vault.balanceOf(depositors[i]);
            uint256 assetsForShares = tier0Vault.convertToAssets(balance);
            // Must be <= deposited amount (rounding against user)
            assertLe(assetsForShares, amounts[i], "convertToAssets must be <= deposited for each user");
            // Must be close (within 2 wei for rounding)
            assertGe(assetsForShares + 2, amounts[i], "convertToAssets must be close to deposited amount");
        }
    }

    // ----- L3 Step 2: Rapid deposit/withdraw cycles -----
    function testStress_rapidDepositWithdrawCycles() public {
        uint256 depositAmount = 1000e6; // 1000 RISKUSD
        uint256 cycles = 50;
        uint256 totalReceived = 0;

        for (uint256 i = 0; i < cycles; i++) {
            _depositTier0(alice, depositAmount);
            uint256 aliceBalance = tier0Vault.balanceOf(alice);

            vm.prank(alice);
            tier0Vault.requestWithdrawal(aliceBalance);

            vm.warp(block.timestamp + COOLDOWN_PERIOD);

            uint256 riskusdBefore = riskusd.balanceOf(alice);
            vm.prank(alice);
            tier0Vault.executeWithdrawal();
            uint256 received = riskusd.balanceOf(alice) - riskusdBefore;
            totalReceived += received;

            // Each cycle completes without error
            atRISKUSD.PendingWithdrawal memory pw = tier0Vault.pendingWithdrawal(alice);
            assertFalse(pw.active, "pending should be cleared each cycle");

            // OPEN-26: a stale-window execution consumes the current weekly cap.
            // This stress test is about repeated lifecycle integrity, so start a fresh cap window.
            vm.warp(block.timestamp + tier0Vault.WEEKLY_WITHDRAWAL_WINDOW());
        }

        // No state corruption: totalSupply should be back to virtual offset only
        // totalAssets should equal remaining vault balance
        assertEq(
            tier0Vault.totalAssets(),
            riskusd.balanceOf(address(tier0Vault)),
            "totalAssets must match vault RISKUSD balance after cycles"
        );
    }

    // ----- L3 Step 3: Large loss event (50%+ of totalAssets) -----
    function testStress_largeLossEvent() public {
        uint256 totalDeposit = 1_000_000e6; // 1M RISKUSD
        _depositTier0(alice, totalDeposit / 2);
        _depositTier0(bob, totalDeposit / 2);

        uint256 totalAssetsBefore = tier0Vault.totalAssets();
        assertEq(totalAssetsBefore, totalDeposit, "totalAssets should be 1M RISKUSD");

        // Absorb 999,999 RISKUSD loss (~99.9999%)
        uint256 lossAmount = 999_999e6;
        _absorbLossTier0(lossAmount);

        uint256 totalAssetsAfter = tier0Vault.totalAssets();
        assertEq(totalAssetsAfter, totalDeposit - lossAmount, "totalAssets should be 1 RISKUSD after loss");
        assertEq(totalAssetsAfter, 1e6, "remaining totalAssets should be 1e6");

        // Exchange rate dropped by ~99.9999%
        uint256 aliceShares = tier0Vault.balanceOf(alice);
        uint256 aliceAssets = tier0Vault.convertToAssets(aliceShares);
        // Alice had ~500K RISKUSD equivalent, now should be ~0.5 RISKUSD
        assertLt(aliceAssets, 1e6, "alice assets should be < 1 RISKUSD after massive loss");

        // All depositors can still request withdrawal
        vm.prank(alice);
        tier0Vault.requestWithdrawal(aliceShares);
        atRISKUSD.PendingWithdrawal memory pw = tier0Vault.pendingWithdrawal(alice);
        assertTrue(pw.active, "alice should be able to request withdrawal after large loss");

        // New deposits work at the deflated rate
        uint256 newDeposit = 1e6; // 1 RISKUSD
        uint256 newShares = _depositTier0(makeAddr("charlie"), newDeposit);
        assertGt(newShares, 0, "new deposit should mint shares at deflated rate");

        // New depositor gets proportionally many more shares (rate is very low)
        uint256 charlieAssets = tier0Vault.convertToAssets(newShares);
        // The new deposit of 1 RISKUSD should be worth approximately 1 RISKUSD (within rounding)
        assertLe(charlieAssets, newDeposit, "charlie's assets should be <= deposited (rounding)");
        assertGe(charlieAssets + 2, newDeposit, "charlie's assets should be close to deposited");
    }

    // ----- L3 Step 4: Many pending withdrawals (independent) -----
    function testStress_manyPendingWithdrawals() public {
        uint256 numUsers = 50;
        address[] memory users = new address[](numUsers);

        // Deposit for each user
        for (uint256 i = 0; i < numUsers; i++) {
            users[i] = makeAddr(string(abi.encodePacked("user", vm.toString(i))));
            _depositTier0(users[i], 1000e6);
        }

        // Each user requests withdrawal at different times
        for (uint256 i = 0; i < numUsers; i++) {
            vm.warp(block.timestamp + 1 hours); // Stagger requests by 1 hour
            uint256 balance = tier0Vault.balanceOf(users[i]);
            vm.prank(users[i]);
            tier0Vault.requestWithdrawal(balance);
        }

        // Verify each has an independent pending withdrawal
        for (uint256 i = 0; i < numUsers; i++) {
            atRISKUSD.PendingWithdrawal memory pw = tier0Vault.pendingWithdrawal(users[i]);
            assertTrue(pw.active, "each user should have active pending withdrawal");
            assertGt(pw.atriskusdAmount, 0, "each pending should have non-zero shares");
        }

        // Warp past all cooldowns (last request was at current time, so warp by cooldown)
        vm.warp(block.timestamp + COOLDOWN_PERIOD);

        // Each can execute after their individual cooldown
        for (uint256 i = 0; i < numUsers; i++) {
            vm.prank(users[i]);
            tier0Vault.executeWithdrawal();
            atRISKUSD.PendingWithdrawal memory pw = tier0Vault.pendingWithdrawal(users[i]);
            assertFalse(pw.active, "each pending should be cleared after execution");
        }
    }

    // ----- L3 Step 5: Alternating yield and loss -----
    function testStress_alternatingYieldAndLoss() public {
        _depositTier0(alice, 1_000_000e6);

        uint256 yieldTotal = 0;
        uint256 lossTotal = 0;

        for (uint256 i = 0; i < 100; i++) {
            if (i % 2 == 0) {
                // Yield
                uint256 yieldAmount = (i + 1) * 100e6; // 100 to 10000 RISKUSD
                _accrueYieldTier0(yieldAmount);
                yieldTotal += yieldAmount;
            } else {
                // Loss — ensure we don't lose more than totalAssets
                uint256 lossAmount = i * 50e6; // 50 to 4950 RISKUSD
                uint256 ta = tier0Vault.totalAssets();
                if (lossAmount > ta) {
                    lossAmount = ta;
                }
                if (lossAmount > 0) {
                    _absorbLossTier0(lossAmount);
                    lossTotal += lossAmount;
                }
            }
        }

        // Exchange rate remains consistent: totalAssets matches RISKUSD balance
        assertEq(
            tier0Vault.totalAssets(),
            riskusd.balanceOf(address(tier0Vault)),
            "totalAssets must match vault RISKUSD balance after alternating yield/loss"
        );

        // Counters are correct
        assertEq(tier0Vault.totalYieldAccrued(), yieldTotal, "totalYieldAccrued must match sum of yields");
        assertEq(tier0Vault.totalLossAbsorbed(), lossTotal, "totalLossAbsorbed must match sum of losses");
    }

    // ----- L3 Step 6: High-frequency state changes (mixed operations) -----
    function testStress_highFrequencyStateChanges() public {
        address charlie = makeAddr("charlie");
        address dave = makeAddr("dave");

        // Initial deposits
        _depositTier0(alice, 100_000e6);
        _depositTier0(bob, 100_000e6);
        _depositTier0(charlie, 100_000e6);
        _depositTier0(dave, 100_000e6);

        // 200 operations: mix of deposit, yield, loss, transfer, request, execute, cancel
        for (uint256 i = 0; i < 200; i++) {
            uint256 op = i % 7;

            if (op == 0) {
                // Deposit
                _depositTier0(alice, 1000e6);
            } else if (op == 1) {
                // Yield
                _accrueYieldTier0(500e6);
            } else if (op == 2) {
                // Loss (small, safe amount)
                uint256 ta = tier0Vault.totalAssets();
                if (ta > 100e6) {
                    _absorbLossTier0(50e6);
                }
            } else if (op == 3) {
                // Transfer
                uint256 aliceBalance = tier0Vault.balanceOf(alice);
                if (aliceBalance > 10) {
                    vm.prank(alice);
                    tier0Vault.transfer(bob, 10);
                }
            } else if (op == 4) {
                // Request withdrawal for charlie if no pending
                atRISKUSD.PendingWithdrawal memory pw = tier0Vault.pendingWithdrawal(charlie);
                uint256 charlieBalance = tier0Vault.balanceOf(charlie);
                if (!pw.active && charlieBalance > 100e6) {
                    vm.prank(charlie);
                    tier0Vault.requestWithdrawal(100e6);
                }
            } else if (op == 5) {
                // Execute withdrawal for charlie if pending and cooldown elapsed
                atRISKUSD.PendingWithdrawal memory pw = tier0Vault.pendingWithdrawal(charlie);
                if (pw.active && block.timestamp >= pw.requestTimestamp + tier0Vault.cooldownPeriod()) {
                    vm.prank(charlie);
                    tier0Vault.executeWithdrawal();
                }
            } else if (op == 6) {
                // Warp 1 day forward
                vm.warp(block.timestamp + 1 days);
            }
        }

        // State consistency: totalAssets matches vault RISKUSD balance
        assertEq(
            tier0Vault.totalAssets(),
            riskusd.balanceOf(address(tier0Vault)),
            "totalAssets must match vault RISKUSD balance after high-frequency ops"
        );
    }
}
