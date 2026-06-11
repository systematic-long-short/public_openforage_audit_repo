// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/RISKUSDVaultTestBase.sol";

abstract contract RISKUSDVaultEdgeBase is RISKUSDVaultTestBase {
    function _relaxMintCapsForEdgeFixture() internal {
        vm.startPrank(owner);
        vault.setPerBlockMintCap(10000, type(uint256).max);
        vault.setDailyMintCapBps(10000);
        vault.setWeeklyMintCapBps(20000);
        vm.stopPrank();
    }

    function _depositWithinMintCaps(address account, uint256 amount) internal {
        while (amount > 0) {
            uint256 weeklyRemaining = vault.weeklyMintRemaining();
            if (weeklyRemaining == 0) {
                vm.warp(block.timestamp + WEEKLY_WINDOW_DURATION);
                weeklyRemaining = vault.weeklyMintRemaining();
            }

            uint256 supply = riskusd.totalSupply();
            uint256 chunk = amount;
            if (supply != 0 && chunk > supply) {
                chunk = supply;
            }
            if (chunk > weeklyRemaining) {
                chunk = weeklyRemaining;
            }

            if (supply != 0) {
                vm.roll(block.number + 1);
            }
            _deposit(account, chunk);
            amount -= chunk;
        }
    }
}

// ============================================================
// TC-18: Time Boundary Tests
// ============================================================
contract RISKUSDVault_TC18_TimeBoundary is RISKUSDVaultEdgeBase {
    function setUp() public override {
        super.setUp();
        _setupAllRoles();
        _relaxMintCapsForEdgeFixture();
    }

    /// @dev R-15: T+604799 (1 second before reset) -- cap exhausted, redeem MUST revert
    function test_TC18_exactBoundaryOneSecondBeforeReset() public {
        _deposit(alice, 1000e6);
        uint256 cap = vault.effectiveWeeklyRedemptionCap(); // 50e6 (5% of 1000e6)

        // Exhaust cap
        _approveVaultRISKUSD(alice, cap);
        vm.prank(alice);
        vault.redeem(cap);

        // Warp to T + 604799 (1 second before reset)
        uint256 windowStart = vault.weeklyRedemptionWindowStart();
        vm.warp(windowStart + 604799);

        // Attempt another redeem -- MUST revert
        _deposit(alice, 100e6); // deposit more to have RISKUSD
        _approveVaultRISKUSD(alice, 1);
        vm.prank(alice);
        vm.expectRevert(RISKUSDVault.WeeklyRedemptionCapExceeded.selector);
        vault.redeem(1);
    }

    /// @dev R-15: T+604800 (exact reset boundary) -- MUST succeed, window resets
    function test_TC18_exactBoundaryResetMoment() public {
        _deposit(alice, 1000e6);
        uint256 cap = vault.effectiveWeeklyRedemptionCap();

        // Exhaust cap
        _approveVaultRISKUSD(alice, cap);
        vm.prank(alice);
        vault.redeem(cap);

        uint256 windowStart = vault.weeklyRedemptionWindowStart();

        // Warp to exactly T + 604800
        vm.warp(windowStart + WEEKLY_WINDOW_DURATION);

        // Redeem MUST succeed (window resets)
        _deposit(alice, 100e6);
        _approveVaultRISKUSD(alice, 1);
        vm.prank(alice);
        vault.redeem(1);

        // Verify the window advances by one full period at the exact boundary
        assertEq(
            vault.weeklyRedemptionWindowStart(),
            windowStart + WEEKLY_WINDOW_DURATION,
            "Window start must advance by one full period"
        );
        assertEq(vault.weeklyRedemptionUsed(), 1, "weeklyRedemptionUsed must be 1 after reset + redeem");
    }

    /// @dev R-15: T+604801 (1 second after boundary) -- window advances by elapsed full periods
    function test_TC18_exactBoundaryOneSecondAfterReset() public {
        _deposit(alice, 1000e6);
        uint256 cap = vault.effectiveWeeklyRedemptionCap();

        _approveVaultRISKUSD(alice, cap);
        vm.prank(alice);
        vault.redeem(cap);

        uint256 windowStart = vault.weeklyRedemptionWindowStart();
        uint256 newTimestamp = windowStart + WEEKLY_WINDOW_DURATION + 1;
        vm.warp(newTimestamp);

        _deposit(alice, 100e6);
        _approveVaultRISKUSD(alice, 1);
        vm.prank(alice);
        vault.redeem(1);

        // OF-M02 fix: window advances by exactly one period, not to block.timestamp
        assertEq(
            vault.weeklyRedemptionWindowStart(),
            windowStart + WEEKLY_WINDOW_DURATION,
            "Window start must advance by one period (OF-M02)"
        );
    }

    /// @dev R-15: Multiple weeks elapsed -- window advances by elapsed full periods
    function test_TC18_multipleWeeksElapsed() public {
        _deposit(alice, 1000e6);
        uint256 cap = vault.effectiveWeeklyRedemptionCap();

        _approveVaultRISKUSD(alice, cap);
        vm.prank(alice);
        vault.redeem(cap);

        uint256 windowStart = vault.weeklyRedemptionWindowStart();

        // Warp 2 weeks
        uint256 newTimestamp = windowStart + 2 * WEEKLY_WINDOW_DURATION;
        vm.warp(newTimestamp);

        _deposit(alice, 100e6);
        _approveVaultRISKUSD(alice, 1);
        vm.prank(alice);
        vault.redeem(1);

        // Two elapsed periods are applied in one lazy reset
        assertEq(vault.weeklyRedemptionWindowStart(), newTimestamp, "Must advance by two full periods");
        assertEq(vault.weeklyRedemptionUsed(), 1, "Used must be 1 after single reset");
    }

    /// @dev R-15: Very large time gap (1 year) -- window resets correctly
    function test_TC18_veryLargeTimeGap() public {
        _deposit(alice, 1000e6);
        uint256 cap = vault.effectiveWeeklyRedemptionCap();

        _approveVaultRISKUSD(alice, cap);
        vm.prank(alice);
        vault.redeem(cap);

        uint256 windowStart = vault.weeklyRedemptionWindowStart();
        uint256 oneYear = 365 * 86400;
        vm.warp(windowStart + oneYear);

        _deposit(alice, 100e6);
        _approveVaultRISKUSD(alice, 1);
        vm.prank(alice);
        vault.redeem(1);

        // OF-M02 fix: advance by elapsed full weeks, not to block.timestamp
        // 365 days / 7 days = 52 full weeks (52 * 604800 = 31449600)
        uint256 elapsedWeeks = oneYear / WEEKLY_WINDOW_DURATION;
        assertEq(
            vault.weeklyRedemptionWindowStart(),
            windowStart + elapsedWeeks * WEEKLY_WINDOW_DURATION,
            "Window must advance by full weeks (OF-M02)"
        );
    }

    /// @dev R-15: Block timestamp at uint32 boundary -- operations must still work (timestamps are uint256)
    function test_TC18_uint32TimestampBoundary() public {
        _deposit(alice, 1000e6);

        // Warp to uint32 max
        vm.warp(type(uint32).max);

        _deposit(bob, 500e6);
        assertEq(vault.totalDeposited(), 1500e6, "Deposit must work at uint32 boundary");

        _approveVaultRISKUSD(bob, 10e6);
        vm.prank(bob);
        vault.redeem(10e6);
        assertEq(vault.totalRedeemed(), 10e6, "Redeem must work at uint32 boundary");
    }

    /// @dev R-15: Two redemptions in same block after reset -- both use the newly reset window
    function test_TC18_twoRedemptionsSameBlockAfterReset() public {
        _deposit(alice, 2000e6);

        // Exhaust cap in first window
        uint256 cap = vault.effectiveWeeklyRedemptionCap(); // 200e6
        _approveVaultRISKUSD(alice, cap);
        vm.prank(alice);
        vault.redeem(cap);

        uint256 windowStart = vault.weeklyRedemptionWindowStart();
        vm.warp(windowStart + WEEKLY_WINDOW_DURATION);

        // Two redemptions in same block
        _approveVaultRISKUSD(alice, 130e6);

        vm.prank(alice);
        vault.redeem(50e6); // triggers reset

        vm.prank(alice);
        vault.redeem(30e6); // same block, same window

        assertEq(vault.weeklyRedemptionUsed(), 80e6, "Both redemptions must count in the reset window");
    }

    /// @dev R-15: Reset then immediate cap exhaust in a single transaction
    function test_TC18_resetThenImmediateCapExhaust() public {
        _deposit(alice, 1000e6);
        uint256 cap = vault.effectiveWeeklyRedemptionCap(); // 50e6

        // Exhaust first window
        _approveVaultRISKUSD(alice, cap);
        vm.prank(alice);
        vault.redeem(cap);

        uint256 windowStart = vault.weeklyRedemptionWindowStart();
        vm.warp(windowStart + WEEKLY_WINDOW_DURATION);

        // Expired-window cap uses the prior active supply snapshot, not post-burn live supply
        uint256 newCap = vault.effectiveWeeklyRedemptionCap(); // 50e6

        // Exhaust new cap in one call
        _approveVaultRISKUSD(alice, newCap);
        vm.prank(alice);
        vault.redeem(newCap);

        // Next redeem must revert
        _approveVaultRISKUSD(alice, 1);
        vm.prank(alice);
        vm.expectRevert(RISKUSDVault.WeeklyRedemptionCapExceeded.selector);
        vault.redeem(1);
    }

    /// @dev R-53: weeklyRedemptionRemaining() returns full cap after window expiry (view, no state mutation)
    function test_TC18_viewDuringExpiredWindow() public {
        _deposit(alice, 1000e6);
        uint256 cap = vault.effectiveWeeklyRedemptionCap(); // 50e6

        // Exhaust cap
        _approveVaultRISKUSD(alice, cap);
        vm.prank(alice);
        vault.redeem(cap);

        // Verify used == cap
        assertEq(vault.weeklyRedemptionUsed(), cap, "Used must equal cap after exhaust");

        // Warp past window
        uint256 windowStart = vault.weeklyRedemptionWindowStart();
        vm.warp(windowStart + WEEKLY_WINDOW_DURATION);

        // View must return full cap (logical reset without state mutation)
        uint256 remaining = vault.weeklyRedemptionRemaining();
        assertEq(
            remaining,
            vault.effectiveWeeklyRedemptionCap(),
            "weeklyRedemptionRemaining must return full cap after window expiry"
        );

        // But weeklyRedemptionUsed() is still the old value (no state mutation)
        assertEq(vault.weeklyRedemptionUsed(), cap, "weeklyRedemptionUsed must not mutate on view call");
    }

    /// @dev R-15: Window start consistency -- after reset, windowStart advances by elapsed full periods
    function test_TC18_windowStartConsistency() public {
        _deposit(alice, 1000e6);
        uint256 cap = vault.effectiveWeeklyRedemptionCap();

        _approveVaultRISKUSD(alice, cap);
        vm.prank(alice);
        vault.redeem(cap);

        uint256 windowStart = vault.weeklyRedemptionWindowStart();
        uint256 resetTime = windowStart + WEEKLY_WINDOW_DURATION + 42; // arbitrary offset
        vm.warp(resetTime);

        _deposit(alice, 100e6);
        _approveVaultRISKUSD(alice, 1);
        vm.prank(alice);
        vault.redeem(1);

        // OF-M02 fix: window advances by exactly one period from old start, not to block.timestamp
        assertEq(
            vault.weeklyRedemptionWindowStart(),
            windowStart + WEEKLY_WINDOW_DURATION,
            "Window start must advance by one period (OF-M02)"
        );
    }
}

// ============================================================
// TC-19: Front-Running Tests
// ============================================================
contract RISKUSDVault_TC19_FrontRunning is RISKUSDVaultEdgeBase {
    function setUp() public override {
        super.setUp();
        _setupAllRoles();
        _relaxMintCapsForEdgeFixture();
    }

    /// @dev R-49: Deposit front-run -- both get 1:1, no advantage
    function test_TC19_depositFrontRun() public {
        // Attacker front-runs Alice's deposit
        _deposit(attacker, 1000e6);
        _deposit(alice, 1000e6);

        // Both get 1:1 RISKUSD -- no exchange rate advantage
        assertEq(riskusd.balanceOf(attacker), 1000e6, "Attacker gets 1:1 RISKUSD");
        assertEq(riskusd.balanceOf(alice), 1000e6, "Alice gets 1:1 RISKUSD");
        assertEq(vault.totalDeposited(), 2000e6, "Total deposited correct");
    }

    /// @dev R-10, R-49: Redeem front-run -- first within cap succeeds, second reverts (no profit)
    function test_TC19_redeemFrontRun() public {
        // Both deposit
        _deposit(alice, 600e6);
        _deposit(attacker, 600e6);
        uint256 cap = vault.effectiveWeeklyRedemptionCap();

        // Attacker front-runs with redeem of the full weekly cap (exhausts cap)
        _approveVaultRISKUSD(attacker, cap);
        vm.prank(attacker);
        vault.redeem(cap);

        // Alice's redeem fails -- cap exhausted
        _approveVaultRISKUSD(alice, 100e6);
        vm.prank(alice);
        vm.expectRevert(RISKUSDVault.WeeklyRedemptionCapExceeded.selector);
        vault.redeem(100e6);
    }

    /// @dev R-49: Deposit-then-redeem sandwich -- nets zero (1:1 symmetric)
    function test_TC19_depositRedeemSandwich() public {
        // Alice deposits first
        _deposit(alice, 1000e6);

        // Attacker sandwiches: deposit before, redeem after
        _deposit(attacker, 500e6);

        // Total supply: 1500e6. Launch default cap: 5% = 75e6. Redeem of 500e6 exceeds cap.
        // Raise cap to 100% so the sandwich test focuses on value extraction, not cap limits.
        vm.prank(owner);
        vault.setWeeklyRedemptionCapBps(10000);

        // Now attacker redeems -- gets 1:1, no profit
        _approveVaultRISKUSD(attacker, 500e6);
        uint256 attackerUsdcBefore = usdc.balanceOf(attacker);
        vm.prank(attacker);
        vault.redeem(500e6);

        uint256 attackerUsdcAfter = usdc.balanceOf(attacker);
        assertEq(attackerUsdcAfter - attackerUsdcBefore, 500e6, "Attacker gets back exactly what they deposited");
        assertEq(riskusd.balanceOf(attacker), 0, "Attacker has 0 RISKUSD after full redeem");
    }

    /// @dev R-10: Weekly cap front-running -- timing advantage only, no value extraction
    function test_TC19_weeklyCapFrontRunning() public {
        _deposit(alice, 1000e6);
        _deposit(attacker, 1000e6);
        uint256 totalCap = vault.effectiveWeeklyRedemptionCap();
        uint256 firstRedeem = (totalCap * 3) / 4;
        uint256 remainingCap = totalCap - firstRedeem;

        // Exhaust most of cap
        _approveVaultRISKUSD(alice, firstRedeem);
        vm.prank(alice);
        vault.redeem(firstRedeem);

        // Both alice and attacker submit a redeem for the remaining cap.
        // Attacker gets timing advantage.
        _approveVaultRISKUSD(attacker, remainingCap);
        vm.prank(attacker);
        vault.redeem(remainingCap); // Attacker succeeds (timing)

        // Alice blocked
        _approveVaultRISKUSD(alice, remainingCap);
        vm.prank(alice);
        vm.expectRevert(RISKUSDVault.WeeklyRedemptionCapExceeded.selector);
        vault.redeem(remainingCap);

        // But attacker gained no value -- 1:1 redeem, just timing on when they access USDC
    }

    /// @dev R-49: No MEV at vault layer -- no exchange rate, no slippage, no oracle
    function test_TC19_noMevAtVaultLayer() public {
        // Sequence: attacker deposits, large deposit from alice, attacker redeems
        _deposit(attacker, 500e6);
        _depositWithinMintCaps(alice, 10_000e6);

        // Attacker redeems -- gets back exactly 1:1
        _approveVaultRISKUSD(attacker, 500e6);
        uint256 attackerUsdcBefore = usdc.balanceOf(attacker);
        vm.prank(attacker);
        vault.redeem(500e6);
        uint256 attackerUsdcAfter = usdc.balanceOf(attacker);

        // Net: 0 profit (got back exactly 500e6 USDC for 500e6 RISKUSD)
        assertEq(attackerUsdcAfter - attackerUsdcBefore, 500e6, "No MEV profit: 1:1 symmetric");
    }
}

// ============================================================
// TC-20: Stress Tests
// ============================================================
contract RISKUSDVault_TC20_Stress is RISKUSDVaultEdgeBase {
    function setUp() public override {
        super.setUp();
        _setupAllRoles();
        _relaxMintCapsForEdgeFixture();
    }

    /// @dev R-42, R-43: 100 depositors each deposit 100e6, verify invariants
    function testStress_manyDepositors() public {
        uint256 depositAmount = 100e6;
        uint256 numDepositors = 100;

        for (uint256 i = 0; i < numDepositors; i++) {
            address depositor = makeAddr(string(abi.encodePacked("depositor", vm.toString(i))));
            _deposit(depositor, depositAmount);
        }

        // Verify state
        assertEq(vault.totalDeposited(), depositAmount * numDepositors, "Total deposited must match");
        assertEq(
            riskusd.totalSupply(),
            vault.totalDeposited() - vault.totalRedeemed() - vault.totalBurnedForLoss(),
            "Supply invariant must hold"
        );
    }

    /// @dev R-42, R-43: Rapid deposit/redeem cycles (100x), verify cumulative counters
    function testStress_rapidDepositRedeemCycles() public {
        // Set cap to 100% so rapid cycles are not blocked by the 5% launch default.
        vm.prank(owner);
        vault.setWeeklyRedemptionCapBps(10000);

        uint256 cycles = 100;
        uint256 amount = 100e6;

        for (uint256 i = 0; i < cycles; i++) {
            // Deposit
            _deposit(alice, amount);

            // Redeem (within weekly cap check)
            uint256 effectiveCap = vault.effectiveWeeklyRedemptionCap();
            uint256 used = vault.weeklyRedemptionUsed();
            uint256 remaining = effectiveCap > used ? effectiveCap - used : 0;

            if (amount <= remaining) {
                _approveVaultRISKUSD(alice, amount);
                vm.prank(alice);
                vault.redeem(amount);
            } else {
                // Warp past window to reset cap
                vm.warp(block.timestamp + WEEKLY_WINDOW_DURATION);
                _approveVaultRISKUSD(alice, amount);
                vm.prank(alice);
                vault.redeem(amount);
            }
        }

        // Verify counters
        assertEq(vault.totalDeposited(), amount * cycles, "totalDeposited after rapid cycles");
        assertEq(vault.totalRedeemed(), amount * cycles, "totalRedeemed after rapid cycles");
        assertEq(vault.totalDepositorUsdc(), 0, "totalDepositorUsdc must be 0 after full cycles");

        // Supply invariant
        assertEq(
            riskusd.totalSupply(),
            vault.totalDeposited() - vault.totalRedeemed() - vault.totalBurnedForLoss(),
            "Supply invariant must hold after rapid cycles"
        );
    }

    /// @dev R-42: 1000 deposits of 1 wei each
    function testStress_manyTinyDeposits() public {
        uint256 numDeposits = 1000;

        for (uint256 i = 0; i < numDeposits; i++) {
            _deposit(alice, 1);
        }

        assertEq(vault.totalDeposited(), numDeposits, "totalDeposited must match tiny deposit count");
        assertEq(riskusd.totalSupply(), numDeposits, "Supply must match tiny deposit count");
    }

    /// @dev R-42, R-43: Mixed operations sequence (49 interleaved ops covering ALL op types), verify both invariants
    function testStress_mixedOperationsSequence() public {
        // Initial deposit
        _deposit(alice, 10_000e6);

        uint256 ops = 48; // divisible by 6 for clean cycling over live operations
        for (uint256 i = 0; i < ops; i++) {
            uint256 opType = i % 6;

            if (opType == 0) {
                // Deposit — may revert with LossPending if loss is pending (OF-13-056)
                _fundAndApproveUSDC(bob, 100e6);
                vm.prank(bob);
                (bool ok,) = address(vault).call(abi.encodeCall(vault.deposit, (100e6)));
            } else if (opType == 1) {
                // Redeem (if possible, with cap management)
                uint256 bal = riskusd.balanceOf(alice);
                if (bal >= 10e6) {
                    uint256 effectiveCap = vault.effectiveWeeklyRedemptionCap();
                    uint256 used = vault.weeklyRedemptionUsed();
                    uint256 remaining = effectiveCap > used ? effectiveCap - used : 0;
                    uint256 redeemAmt = 10e6;
                    if (redeemAmt > remaining) {
                        vm.warp(block.timestamp + WEEKLY_WINDOW_DURATION);
                    }
                    _approveVaultRISKUSD(alice, redeemAmt);
                    vm.prank(alice);
                    (bool ok,) = address(vault).call(abi.encodeCall(vault.redeem, (redeemAmt)));
                    // ok may be false if liquidity insufficient -- that's fine
                }
            } else if (opType == 2) {
                // Deploy capital
                uint256 vaultBal = usdc.balanceOf(address(vault));
                if (vaultBal >= 50e6) {
                    vm.prank(custodianAddr);
                    (bool ok,) = address(vault).call(abi.encodeCall(vault.deployCapital, (50e6)));
                    // May fail on ratio
                }
            } else if (opType == 3) {
                // Return capital
                uint256 deployed = vault.totalDeployed();
                if (deployed >= 20e6) {
                    _fundAndApproveUSDC(custodianAddr, 20e6);
                    vm.prank(custodianAddr);
                    (bool ok,) = address(vault).call(abi.encodeCall(vault.returnCapital, (20e6)));
                }
            } else if (opType == 4) {
                // burnForLoss: fund lossReporter with RISKUSD via vault deposit + transfer
                // Deposit may fail with LossPending (OF-13-056), in which case skip this op
                _fundAndApproveUSDC(charlie, 50e6);
                vm.prank(charlie);
                (bool depositOk,) = address(vault).call(abi.encodeCall(vault.deposit, (50e6)));
                if (!depositOk) continue; // skip burnForLoss if deposit failed
                vm.prank(charlie);
                riskusd.transfer(lossReporterAddr, 50e6);
                vm.prank(lossReporterAddr);
                (bool ok,) = address(vault).call(abi.encodeCall(vault.burnForLoss, (1, 50e6)));
            } else if (opType == 5) {
                // Replenish
                _fundAndApproveUSDC(lossReporterAddr, 10e6);
                vm.prank(lossReporterAddr);
                (bool ok,) = address(vault).call(abi.encodeCall(vault.replenish, (10e6)));
            }
        }

        // Verify both invariants after all operations
        assertEq(
            riskusd.totalSupply(),
            vault.totalDeposited() - vault.totalRedeemed() - vault.totalBurnedForLoss(),
            "Supply invariant must hold after mixed ops"
        );
        assertEq(
            usdc.balanceOf(address(vault)) + vault.totalDeployed() + vault.totalRedeemed() + vault.totalLostCapital(),
            vault.totalDeposited() + vault.totalReplenished(),
            "USDC accounting invariant must hold after mixed ops"
        );
    }

    /// @dev R-10: Cap exhaustion across many users -- exact cutoff
    function testStress_capExhaustionAcrossUsers() public {
        uint256 numUsers = 50;
        uint256 depositPerUser = 200e6;

        // All users deposit
        for (uint256 i = 0; i < numUsers; i++) {
            address user = makeAddr(string(abi.encodePacked("user", vm.toString(i))));
            _deposit(user, depositPerUser);
        }

        // Total supply: 50 * 200e6 = 10,000e6. Launch default cap: 5% = 500e6.
        uint256 totalCap = vault.effectiveWeeklyRedemptionCap();
        uint256 redeemPerUser = 100e6; // each tries to redeem 100e6
        uint256 usersWithinCap = totalCap / redeemPerUser; // 10 users

        uint256 successCount;
        for (uint256 i = 0; i < numUsers; i++) {
            address user = makeAddr(string(abi.encodePacked("user", vm.toString(i))));
            _approveVaultRISKUSD(user, redeemPerUser);
            vm.prank(user);
            (bool ok,) = address(vault).call(abi.encodeCall(vault.redeem, (redeemPerUser)));
            if (ok) successCount++;
        }

        assertEq(successCount, usersWithinCap, "Exactly N users must succeed before cap exhaustion");
    }

    /// @dev R-42, R-43: Deploy-return-deploy cycle accounting
    function testStress_deployReturnDeployCycles() public {
        _deposit(alice, 10_000e6);

        // Deploy 500e6
        vm.prank(custodianAddr);
        vault.deployCapital(500e6);
        vm.prank(custodianAddr);
        vault.recordCustodianNAV(500e6);

        // Return 300e6
        _fundAndApproveUSDC(custodianAddr, 300e6);
        vm.prank(custodianAddr);
        vault.returnCapital(300e6);

        // Deploy 200e6
        vm.prank(custodianAddr);
        vault.deployCapital(200e6);

        assertEq(vault.totalDeployed(), 400e6, "totalDeployed must be 400e6 after deploy-return-deploy");

        // USDC accounting invariant
        assertEq(
            usdc.balanceOf(address(vault)) + vault.totalDeployed() + vault.totalRedeemed() + vault.totalLostCapital(),
            vault.totalDeposited() + vault.totalReplenished(),
            "USDC accounting invariant must hold after deploy-return-deploy"
        );
    }
}

// ============================================================
// TC-22: View Function Tests
// ============================================================
contract RISKUSDVault_TC22_ViewFunctions is RISKUSDVaultEdgeBase {
    function setUp() public override {
        super.setUp();
        _setupAllRoles();
    }

    /// @dev R-03, R-04: After initialization -- all counters 0, addresses correct, defaults correct
    function test_TC22_viewsAfterInit() public view {
        assertEq(vault.totalDeposited(), 0, "totalDeposited must be 0 after init");
        assertEq(vault.totalRedeemed(), 0, "totalRedeemed must be 0 after init");
        assertEq(vault.totalDeployed(), 0, "totalDeployed must be 0 after init");
        assertEq(vault.totalBurnedForLoss(), 0, "totalBurnedForLoss must be 0 after init");
        assertEq(vault.totalReplenished(), 0, "totalReplenished must be 0 after init");
        assertEq(vault.totalLostCapital(), 0, "totalLostCapital must be 0 after init");
        assertEq(vault.totalDepositorUsdc(), 0, "totalDepositorUsdc must be 0 after init");
        assertEq(vault.usdc(), address(usdc), "usdc address must match");
        assertEq(vault.riskusd(), address(riskusd), "riskusd address must match");
        assertEq(vault.weeklyRedemptionCapBps(), DEFAULT_WEEKLY_CAP_BPS, "Default weekly cap BPS");
        assertEq(vault.maxDeploymentRatioBps(), DEFAULT_MAX_DEPLOYMENT_RATIO_BPS, "Default max deployment ratio");
        assertEq(vault.weeklyRedemptionUsed(), 0, "weeklyRedemptionUsed must be 0");
        assertFalse(vault.paused(), "Must not be paused after init");
    }

    /// @dev R-52: After deposit -- totalDeposited increased, totalDepositorUsdc matches, reserveRatio correct
    function test_TC22_viewsAfterDeposit() public {
        _deposit(alice, 1000e6);

        assertEq(vault.totalDeposited(), 1000e6, "totalDeposited after deposit");
        assertEq(vault.totalDepositorUsdc(), 1000e6, "totalDepositorUsdc after deposit");
        assertEq(vault.vaultUsdcBalance(), 1000e6, "vaultUsdcBalance after deposit");
        assertEq(vault.reserveRatio(), 10000, "reserveRatio 100% when nothing deployed");
    }

    /// @dev R-52, R-53: After redeem -- counters updated correctly
    function test_TC22_viewsAfterRedeem() public {
        // Set cap to 100% so 200e6 redeem is not blocked by the 5% launch-default cap (50e6)
        vm.prank(owner);
        vault.setWeeklyRedemptionCapBps(10000);

        _deposit(alice, 1000e6);
        _approveVaultRISKUSD(alice, 200e6);
        vm.prank(alice);
        vault.redeem(200e6);

        assertEq(vault.totalRedeemed(), 200e6, "totalRedeemed after redeem");
        assertEq(vault.weeklyRedemptionUsed(), 200e6, "weeklyRedemptionUsed after redeem");
        assertEq(vault.totalDepositorUsdc(), 800e6, "totalDepositorUsdc after redeem");
        assertEq(vault.vaultUsdcBalance(), 800e6, "vaultUsdcBalance after redeem");
    }

    /// @dev After deploy -- totalDeployed increased, vault balance decreased, reserveRatio decreased
    function test_TC22_viewsAfterDeploy() public {
        _deposit(alice, 1000e6);
        vm.prank(custodianAddr);
        vault.deployCapital(400e6);

        assertEq(vault.totalDeployed(), 400e6, "totalDeployed after deploy");
        assertEq(vault.vaultUsdcBalance(), 600e6, "vaultUsdcBalance after deploy");
        // reserveRatio = 600e6 * 10000 / 1000e6 = 6000
        assertEq(vault.reserveRatio(), 6000, "reserveRatio after deploy");
    }

    /// @dev After return -- totalDeployed decreased, vault balance increased
    function test_TC22_viewsAfterReturn() public {
        _deposit(alice, 1000e6);
        vm.prank(custodianAddr);
        vault.deployCapital(400e6);

        _fundAndApproveUSDC(custodianAddr, 200e6);
        vm.prank(custodianAddr);
        vault.returnCapital(200e6);

        assertEq(vault.totalDeployed(), 200e6, "totalDeployed after return");
        assertEq(vault.vaultUsdcBalance(), 800e6, "vaultUsdcBalance after return");
        // reserveRatio = 800e6 * 10000 / 1000e6 = 8000
        assertEq(vault.reserveRatio(), 8000, "reserveRatio after return");
    }

    /// @dev R-52: effectiveWeeklyRedemptionCap() -- snapshot-based cap with pre-snapshot fallback
    function test_TC22_effectiveWeeklyRedemptionCap() public {
        // With supply 1000e6 and cap 500 bps (5%): 50e6
        _deposit(alice, 1000e6);
        assertEq(vault.effectiveWeeklyRedemptionCap(), 50e6, "Cap with 5% of 1000e6");

        // With zero supply: 0
        // (can't check zero supply after deposit, but initial state was 0)
    }

    /// @dev R-52: effectiveWeeklyRedemptionCap() returns 0 when supply is 0
    function test_TC22_effectiveWeeklyRedemptionCapZeroSupply() public view {
        // Before any deposits, supply is 0, cap should be 0
        // _setupAllRoles() only sets addresses, it does not deposit or change counters
        assertEq(vault.effectiveWeeklyRedemptionCap(), 0, "Cap must be 0 with zero supply");
    }

    /// @dev R-53: weeklyRedemptionRemaining() -- cap - used, clamped to 0, full cap if window expired
    function test_TC22_weeklyRedemptionRemaining() public {
        _deposit(alice, 1000e6);
        uint256 cap = vault.effectiveWeeklyRedemptionCap(); // 50e6

        // Initial: remaining == full cap
        assertEq(vault.weeklyRedemptionRemaining(), cap, "Remaining must equal full cap initially");

        // After partial redeem
        _approveVaultRISKUSD(alice, 25e6);
        vm.prank(alice);
        vault.redeem(25e6);
        assertEq(vault.weeklyRedemptionRemaining(), cap - 25e6, "Remaining after partial redeem");

        // Cap decrease makes remaining clamp to 0
        vm.prank(owner);
        vault.setWeeklyRedemptionCapBps(50); // 0.5% of ~975e6 supply = 4.875e6 -- less than 25e6 used
        assertEq(vault.weeklyRedemptionRemaining(), 0, "Remaining clamped to 0 when used exceeds new cap");
    }

    /// @dev R-53: weeklyRedemptionRemaining() returns full cap after window expiry (lazy reset)
    function test_TC22_weeklyRedemptionRemainingAfterWindowExpiry() public {
        _deposit(alice, 1000e6);

        // Use some cap
        _approveVaultRISKUSD(alice, 50e6);
        vm.prank(alice);
        vault.redeem(50e6);
        assertEq(vault.weeklyRedemptionUsed(), 50e6);

        // Warp past window
        vm.warp(block.timestamp + 604800);

        // Remaining should be full cap (window expired, lazy reset)
        uint256 cap = vault.effectiveWeeklyRedemptionCap();
        assertEq(vault.weeklyRedemptionRemaining(), cap, "Full cap after window expiry");
    }

    /// @dev R-54: reserveRatio() -- returns 10000 when depositorUsdc==0, correct ratio otherwise
    function test_TC22_reserveRatio() public {
        // No deposits: depositorUsdc == 0, must return 10000
        assertEq(vault.reserveRatio(), 10000, "reserveRatio must be 10000 when no deposits");

        // After deposit with no deployment: 100%
        _deposit(alice, 1000e6);
        assertEq(vault.reserveRatio(), 10000, "reserveRatio 100% when nothing deployed");

        // After deploying half
        vm.prank(custodianAddr);
        vault.deployCapital(500e6);
        assertEq(vault.reserveRatio(), 5000, "reserveRatio 50% when half deployed");
    }

    /// @dev availableForRedemption() == vaultUsdcBalance()
    function test_TC22_availableForRedemption() public {
        _deposit(alice, 1000e6);
        assertEq(vault.availableForRedemption(), vault.vaultUsdcBalance(), "availableForRedemption == vaultUsdcBalance");

        vm.prank(custodianAddr);
        vault.deployCapital(400e6);
        assertEq(vault.availableForRedemption(), 600e6, "availableForRedemption after deploy");
    }

    /// @dev After burnForLoss -- totalBurnedForLoss increased, totalDepositorUsdc decreased
    function test_TC22_viewsAfterBurnForLoss() public {
        _deposit(alice, 1000e6);
        vm.prank(alice);
        riskusd.transfer(lossReporterAddr, 200e6);

        vm.prank(custodianAddr);
        vault.deployCapital(200e6);
        uint256 lossNonce = vault.latestLossNonce() + 1;
        vm.prank(custodianAddr);
        vault.recordCustodianNAV(1, 0, lossNonce);

        vm.prank(lossReporterAddr);
        vault.burnForLoss(1, 200e6);
        _finalizePreparedAttestedLoss(1, 200e6);

        assertEq(vault.totalBurnedForLoss(), 200e6, "totalBurnedForLoss after burn");
        // depositorUsdc = 1000 (deposited) - 200 (burned) = 800
        assertEq(vault.totalDepositorUsdc(), 800e6, "totalDepositorUsdc after burn");
    }

    /// @dev After replenish -- totalReplenished increased, vaultUsdcBalance increased
    function test_TC22_viewsAfterReplenish() public {
        _deposit(alice, 1000e6);
        _fundAndApproveUSDC(lossReporterAddr, 300e6);

        vm.prank(lossReporterAddr);
        vault.replenish(300e6);

        assertEq(vault.totalReplenished(), 300e6, "totalReplenished after replenish");
        assertEq(vault.vaultUsdcBalance(), 1300e6, "vaultUsdcBalance after replenish");
    }

    /// @dev After finalized attested loss -- totalDeployed decreased, totalLostCapital increased
    function test_TC22_viewsAfterFinalizedAttestedLoss() public {
        _deposit(alice, 1000e6);
        vm.prank(alice);
        riskusd.transfer(lossReporterAddr, 200e6);
        vm.prank(custodianAddr);
        vault.deployCapital(500e6);

        uint256 lossNonce = vault.latestLossNonce() + 1;
        vm.prank(custodianAddr);
        vault.recordCustodianNAV(1, 300e6, lossNonce);

        vm.prank(lossReporterAddr);
        vault.burnForLoss(1, 200e6);
        _finalizePreparedAttestedLoss(1, 200e6);

        assertEq(vault.totalDeployed(), 300e6, "totalDeployed after attested loss");
        assertEq(vault.totalLostCapital(), 200e6, "totalLostCapital after attested loss");
    }

    /// @dev owner() and pendingOwner() correct after ownership transfer
    function test_TC22_ownerAndPendingOwner() public {
        assertEq(vault.owner(), owner, "owner after init");

        address newOwner = makeAddr("newOwner");
        vm.prank(owner);
        vault.transferOwnership(newOwner);
        assertEq(vault.pendingOwner(), newOwner, "pendingOwner after transfer");

        vm.prank(newOwner);
        vault.acceptOwnership();
        assertEq(vault.owner(), newOwner, "owner after accept");
    }
}

// ============================================================
// TC-23: Edge Case Tests
// ============================================================
contract RISKUSDVault_TC23_EdgeCases is RISKUSDVaultEdgeBase {
    function setUp() public override {
        super.setUp();
        _setupAllRoles();
        // Set weekly redemption cap to 100% so edge-case redeem tests are not blocked by the 5% launch default.
        vm.prank(owner);
        vault.setWeeklyRedemptionCapBps(10000);
    }

    /// @dev R-44, R-49: Zero deposits state -- all views return correct defaults
    function test_TC23_zeroDepositsState() public view {
        assertEq(vault.totalDepositorUsdc(), 0, "totalDepositorUsdc must be 0");
        assertEq(vault.reserveRatio(), 10000, "reserveRatio must be 10000 when no deposits");
        assertEq(vault.effectiveWeeklyRedemptionCap(), 0, "Cap must be 0 with zero supply");
    }

    /// @dev R-44, R-49: Redeem must fail when there are zero deposits (user has no RISKUSD)
    function test_TC23_redeemFailsWithZeroDeposits() public {
        // No deposits made. Trying to redeem should fail
        // (user has no RISKUSD to redeem)
        vm.prank(alice);
        vm.expectRevert(); // No RISKUSD balance
        vault.redeem(1);
    }

    /// @dev R-49: Single wei deposit and redeem
    function test_TC23_singleWeiDepositAndRedeem() public {
        _deposit(alice, 1);
        assertEq(riskusd.balanceOf(alice), 1, "1 wei RISKUSD minted");

        _approveVaultRISKUSD(alice, 1);
        vm.prank(alice);
        vault.redeem(1);

        assertEq(usdc.balanceOf(alice), 1, "1 wei USDC returned");
        assertEq(vault.totalDepositorUsdc(), 0, "totalDepositorUsdc must be 0 after full redeem");
    }

    /// @dev R-54: Redeem entire balance -- depositorUsdc becomes 0, reserveRatio returns 10000
    function test_TC23_redeemEntireBalance() public {
        _deposit(alice, 1000e6);

        // Must be within weekly cap
        uint256 cap = vault.effectiveWeeklyRedemptionCap(); // 50e6
        // Set cap to 100% for this test
        vm.prank(owner);
        vault.setWeeklyRedemptionCapBps(10000);

        _approveVaultRISKUSD(alice, 1000e6);
        vm.prank(alice);
        vault.redeem(1000e6);

        assertEq(vault.totalDepositorUsdc(), 0, "totalDepositorUsdc after full redeem");
        assertEq(vault.reserveRatio(), 10000, "reserveRatio must return 10000 when depositorUsdc==0");
    }

    /// @dev R-49: Deposit after full redeem -- system resumes normally
    function test_TC23_depositAfterFullRedeem() public {
        // Full cycle
        _deposit(alice, 1000e6);
        vm.prank(owner);
        vault.setWeeklyRedemptionCapBps(10000);
        _approveVaultRISKUSD(alice, 1000e6);
        vm.prank(alice);
        vault.redeem(1000e6);

        // New deposit should work
        _deposit(bob, 500e6);
        assertEq(vault.totalDeposited(), 1500e6, "totalDeposited accumulates across cycles");
        assertEq(vault.totalDepositorUsdc(), 500e6, "totalDepositorUsdc after new deposit");
        assertEq(riskusd.balanceOf(bob), 500e6, "Bob gets 1:1 RISKUSD");
    }

    /// @dev R-44: Max uint256 amounts revert on balance (no overflow)
    function test_TC23_maxUint256Amounts() public {
        // Deposit max uint -- must revert on ERC-20 balance, not overflow
        _fundUSDC(alice, 1000e6);
        _approveVaultUSDC(alice, type(uint256).max);
        vm.prank(alice);
        vm.expectRevert(); // Insufficient balance
        vault.deposit(type(uint256).max);

        // Redeem max uint -- must revert on RISKUSD balance or cap
        _deposit(alice, 100e6);
        _approveVaultRISKUSD(alice, type(uint256).max);
        vm.prank(alice);
        vm.expectRevert(); // Cap exceeded or insufficient balance
        vault.redeem(type(uint256).max);
    }

    /// @dev R-49: Self-transfer deposit+redeem in same tx (via contract helper not needed -- sequential)
    function test_TC23_sameBlockDepositAndRedeem() public {
        _deposit(alice, 1000e6);
        _approveVaultRISKUSD(alice, 100e6);
        vm.prank(alice);
        vault.redeem(100e6);

        // Net: USDC in == USDC out for the 100e6 portion
        // Counters incremented for both
        assertEq(vault.totalDeposited(), 1000e6, "totalDeposited includes original deposit");
        assertEq(vault.totalRedeemed(), 100e6, "totalRedeemed includes the redeem");
    }

    /// @dev R-17: deployCapital when no deposits -- ratio revert
    function test_TC23_deployCapitalNoDeposits() public {
        // No deposits, totalDepositorUsdc == 0
        // maxDeploymentRatioBps * 0 / 10000 == 0
        // deployCapital(1) must revert with DeploymentRatioExceeded
        vm.prank(custodianAddr);
        vm.expectRevert(RISKUSDVault.DeploymentRatioExceeded.selector);
        vault.deployCapital(1);
    }

    /// @dev R-21: returnCapital when nothing deployed -- ExcessiveReturn
    function test_TC23_returnCapitalNothingDeployed() public {
        // No capital deployed
        _fundAndApproveUSDC(custodianAddr, 100e6);
        vm.prank(custodianAddr);
        vm.expectRevert(RISKUSDVault.ExcessiveReturn.selector);
        vault.returnCapital(1);
    }

    /// @dev R-25: burnForLoss more than total supply (succeed if caller has the RISKUSD)
    function test_TC23_burnForLossEntireSupply() public {
        _deposit(alice, 1000e6);
        // Transfer alice's RISKUSD to loss reporter (through vault deposit, not direct mint)
        vm.prank(alice);
        riskusd.transfer(lossReporterAddr, 1000e6);

        vm.prank(owner);
        vault.setMaxDeploymentRatioBps(10000);
        vm.prank(custodianAddr);
        vault.deployCapital(1000e6);
        uint256 lossNonce = vault.latestLossNonce() + 1;
        vm.prank(custodianAddr);
        vault.recordCustodianNAV(1, 0, lossNonce);

        vm.prank(lossReporterAddr);
        vault.burnForLoss(1, 1000e6);
        _finalizePreparedAttestedLoss(1, 1000e6);

        assertEq(vault.totalBurnedForLoss(), 1000e6, "totalBurnedForLoss after burning entire supply");
        assertEq(riskusd.totalSupply(), 0, "Supply must be zero after burning all");
    }

    /// @dev R-28: Replenish without prior loss -- succeed, creates excess collateral
    function test_TC23_replenishWithoutPriorLoss() public {
        _deposit(alice, 1000e6);

        // No loss occurred -- replenish should succeed anyway
        _fundAndApproveUSDC(lossReporterAddr, 100e6);
        vm.prank(lossReporterAddr);
        vault.replenish(100e6);

        assertEq(vault.totalReplenished(), 100e6, "totalReplenished after replenish without loss");
        assertEq(vault.vaultUsdcBalance(), 1100e6, "Vault is now over-collateralized");
    }

    /// @dev R-30, R-31: an attested loss can exactly equal totalDeployed
    function test_TC23_attestedLossExactlyEqualsDeployed() public {
        _deposit(alice, 1000e6);
        vm.prank(alice);
        riskusd.transfer(lossReporterAddr, 500e6);
        vm.prank(custodianAddr);
        vault.deployCapital(500e6);

        uint256 lossNonce = vault.latestLossNonce() + 1;
        vm.prank(custodianAddr);
        vault.recordCustodianNAV(1, 0, lossNonce);

        vm.prank(lossReporterAddr);
        vault.burnForLoss(1, 500e6);
        _finalizePreparedAttestedLoss(1, 500e6);

        assertEq(vault.totalDeployed(), 0, "totalDeployed must be 0 after settling all");
        assertEq(vault.totalLostCapital(), 500e6, "totalLostCapital after full attested settlement");
    }
}

// ============================================================
// TC-24: Integration Seam Tests
// ============================================================
contract RISKUSDVault_TC24_IntegrationSeam is RISKUSDVaultEdgeBase {
    address public protocolTreasury;

    function setUp() public override {
        super.setUp();
        _setupAllRoles();
        protocolTreasury = makeAddr("protocolTreasury");
        // Set weekly redemption cap to 100% so integration seam redeem tests are not blocked by the 5% launch default.
        vm.prank(owner);
        vault.setWeeklyRedemptionCapBps(10000);
    }

    /// @dev R-48: ProtocolTreasury deposits USDC as yield (acts as any depositor)
    function test_TC24_protocolTreasuryDepositsAsYield() public {
        _deposit(protocolTreasury, 500e6);

        assertEq(riskusd.balanceOf(protocolTreasury), 500e6, "Treasury gets 1:1 RISKUSD");
        assertEq(vault.totalDeposited(), 500e6, "totalDeposited reflects treasury deposit");
    }

    /// @dev R-48: ProtocolTreasury as lossReporter -- burnForLoss flow
    function test_TC24_protocolTreasuryAsLossReporterBurn() public {
        // Set protocol treasury as loss reporter
        vm.startPrank(owner);
        vault.setLossReporter(protocolTreasury);
        vm.warp(block.timestamp + 2 days + 1);
        vault.finalizeLossReporter();
        vm.stopPrank();

        _deposit(alice, 200e6);
        vm.prank(alice);
        riskusd.transfer(protocolTreasury, 200e6);

        vm.prank(owner);
        vault.setMaxDeploymentRatioBps(10000);
        vm.prank(custodianAddr);
        vault.deployCapital(200e6);
        uint256 lossNonce = vault.latestLossNonce() + 1;
        vm.prank(custodianAddr);
        vault.recordCustodianNAV(1, 0, lossNonce);

        vm.prank(protocolTreasury);
        vault.burnForLoss(1, 200e6);
        _finalizePreparedAttestedLoss(1, 200e6);

        assertEq(vault.totalBurnedForLoss(), 200e6, "Treasury burned RISKUSD as loss reporter");
    }

    /// @dev R-48: ProtocolTreasury as lossReporter -- replenish flow
    function test_TC24_protocolTreasuryAsLossReporterReplenish() public {
        vm.startPrank(owner);
        vault.setLossReporter(protocolTreasury);
        vm.warp(block.timestamp + 2 days + 1);
        vault.finalizeLossReporter();
        vm.stopPrank();

        _fundAndApproveUSDC(protocolTreasury, 300e6);

        vm.prank(protocolTreasury);
        vault.replenish(300e6);

        assertEq(vault.totalReplenished(), 300e6, "Treasury replenished USDC as loss reporter");
    }

    /// @dev R-48: Allowance direction verification
    function test_TC24_allowanceDirection() public {
        // Vault pulls FROM callers for deposit (USDC from depositor)
        _fundUSDC(alice, 100e6);
        // Without approval, deposit should revert
        vm.prank(alice);
        vm.expectRevert(); // ERC-20 insufficient allowance
        vault.deposit(100e6);

        // With approval, deposit succeeds
        _approveVaultUSDC(alice, 100e6);
        vm.prank(alice);
        vault.deposit(100e6);

        // Vault pushes TO callers for redeem (USDC to redeemer)
        // No vault allowance needed for pushing -- vault uses transfer()
        // But redeemer needs RISKUSD allowance for vault to pull RISKUSD
        vm.prank(alice);
        vm.expectRevert(); // No RISKUSD allowance
        vault.redeem(50e6);

        _approveVaultRISKUSD(alice, 50e6);
        vm.prank(alice);
        vault.redeem(50e6);
    }

    /// @dev R-48: RISKUSD allowance required for redeem()
    function test_TC24_riskusdAllowanceRequiredForRedeem() public {
        _deposit(alice, 1000e6);

        // Without RISKUSD approval, redeem must revert
        vm.prank(alice);
        vm.expectRevert(); // ERC-20 insufficient allowance
        vault.redeem(100e6);

        // With approval, redeem succeeds
        _approveVaultRISKUSD(alice, 100e6);
        vm.prank(alice);
        vault.redeem(100e6);
        assertEq(vault.totalRedeemed(), 100e6, "Redeem succeeded with proper allowance");
    }

    /// @dev R-48: returnCapital and replenish allowance direction verification
    function test_TC24_returnCapitalAndReplenishAllowanceDirection() public {
        _deposit(alice, 1000e6);

        // Deploy capital first
        vm.prank(custodianAddr);
        vault.deployCapital(500e6);

        // returnCapital: vault pulls USDC FROM custodian (needs custodian approval)
        _fundUSDC(custodianAddr, 200e6);
        // Without approval, should revert
        vm.prank(custodianAddr);
        vm.expectRevert(); // ERC-20 insufficient allowance
        vault.returnCapital(200e6);

        // With approval, succeeds
        _approveVaultUSDC(custodianAddr, 200e6);
        vm.prank(custodianAddr);
        vault.returnCapital(200e6);

        // replenish: vault pulls USDC FROM lossReporter (needs lossReporter approval)
        _fundUSDC(lossReporterAddr, 100e6);
        // Without approval, should revert
        vm.prank(lossReporterAddr);
        vm.expectRevert(); // ERC-20 insufficient allowance
        vault.replenish(100e6);

        // With approval, succeeds
        _approveVaultUSDC(lossReporterAddr, 100e6);
        vm.prank(lossReporterAddr);
        vault.replenish(100e6);
    }

    /// @dev R-48, R-42: End-to-end yield path
    function test_TC24_endToEndYieldPath() public {
        // ProtocolTreasury deposits USDC as yield
        _deposit(protocolTreasury, 500e6);

        // Verify supply invariant at vault level
        assertEq(
            riskusd.totalSupply(),
            vault.totalDeposited() - vault.totalRedeemed() - vault.totalBurnedForLoss(),
            "Supply invariant after yield deposit"
        );
        assertEq(riskusd.balanceOf(protocolTreasury), 500e6, "Treasury holds RISKUSD for delivery to tier vaults");
        // NOTE: Tier vault delivery is handled by atRISKUSD contract, not RISKUSDVault.
        // This seam tests vault-level yield deposit only.
    }

    /// @dev R-48, R-42, R-43: End-to-end loss path -- burnForLoss + replenish, verify both invariants
    function test_TC24_endToEndLossPath() public {
        // Setup: deposits first
        _deposit(alice, 1000e6);

        // Set protocol treasury as loss reporter
        vm.startPrank(owner);
        vault.setLossReporter(protocolTreasury);
        vm.warp(block.timestamp + 2 days + 1);
        vault.finalizeLossReporter();
        vm.stopPrank();

        // Loss path step 1: burnForLoss
        // Fund protocolTreasury with RISKUSD via vault deposit (maintains supply invariant)
        _deposit(protocolTreasury, 100e6);

        vm.prank(custodianAddr);
        vault.deployCapital(100e6);
        uint256 lossNonce = vault.latestLossNonce() + 1;
        vm.prank(custodianAddr);
        vault.recordCustodianNAV(1, 0, lossNonce);

        vm.prank(protocolTreasury);
        vault.burnForLoss(1, 100e6);
        _finalizePreparedAttestedLoss(1, 100e6);

        // Verify supply invariant after burn
        assertEq(
            riskusd.totalSupply(),
            vault.totalDeposited() - vault.totalRedeemed() - vault.totalBurnedForLoss(),
            "Supply invariant after burnForLoss"
        );

        // Loss path step 2: replenish (partial recovery)
        _fundAndApproveUSDC(protocolTreasury, 50e6);
        vm.prank(protocolTreasury);
        vault.replenish(50e6);

        // Verify USDC accounting invariant after replenish
        assertEq(
            usdc.balanceOf(address(vault)) + vault.totalDeployed() + vault.totalRedeemed() + vault.totalLostCapital(),
            vault.totalDeposited() + vault.totalReplenished(),
            "USDC accounting invariant after loss path"
        );
    }
}
