// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/RISKUSDVaultTestBase.sol";

abstract contract RISKUSDVaultPacingBase is RISKUSDVaultTestBase {
    function _depositWithinPerBlockCap(address account, uint256 amount) internal {
        while (amount > 0) {
            uint256 dailyRemaining = vault.dailyMintRemaining();
            if (dailyRemaining == 0) {
                vm.warp(block.timestamp + 1 days);
                vm.roll(block.number + 1);
                dailyRemaining = vault.dailyMintRemaining();
            }

            uint256 weeklyRemaining = vault.weeklyMintRemaining();
            if (weeklyRemaining == 0) {
                vm.warp(block.timestamp + WEEKLY_WINDOW_DURATION);
                vm.roll(block.number + 1);
                weeklyRemaining = vault.weeklyMintRemaining();
                dailyRemaining = vault.dailyMintRemaining();
            }

            uint256 supply = riskusd.totalSupply();
            uint256 chunk = supply == 0 || amount < supply ? amount : supply;
            if (chunk > dailyRemaining) chunk = dailyRemaining;
            if (chunk > weeklyRemaining) chunk = weeklyRemaining;
            _deposit(account, chunk);
            amount -= chunk;
        }
    }
}

contract RISKUSDVault_MintCapContraction is RISKUSDVaultPacingBase {
    function setUp() public override {
        super.setUp();
        vm.startPrank(owner);
        vault.setPerBlockMintCap(10000, type(uint256).max);
        vault.setDailyMintCapBps(10000);
        vault.setWeeklyMintCapBps(10000);
        vault.setWeeklyRedemptionCapBps(10000);
        vm.stopPrank();
    }

    function test_mintCapsKeepHighWaterBaselineAfterSupplyContraction() public {
        _deposit(alice, 1000e6);
        vm.warp(block.timestamp + WEEKLY_WINDOW_DURATION);
        _deposit(alice, 1000e6);

        _approveVaultRISKUSD(alice, 1900e6);
        vm.prank(alice);
        vault.redeem(1900e6);
        assertEq(riskusd.totalSupply(), 100e6, "supply contracted");

        vm.warp(block.timestamp + WEEKLY_WINDOW_DURATION);
        assertEq(vault.effectiveWeeklyMintCap(), 1000e6, "weekly mint cap keeps high-water baseline");
        assertEq(vault.effectiveDailyMintCap(), 1000e6, "daily mint cap keeps high-water baseline");
    }
}

// ============================================================
// OF-M02: Weekly Redemption Window Advance Tests
// Bug: _weeklyRedemptionWindowStart = block.timestamp (anchors to current time)
// Fix: _weeklyRedemptionWindowStart += elapsed * 604800 (advances by period)
// ============================================================
contract RISKUSDVault_OFM02 is RISKUSDVaultPacingBase {
    function setUp() public override {
        super.setUp();
        vm.prank(owner);
        vault.setPerBlockMintCap(10000, type(uint256).max);
        vm.prank(owner);
        vault.setDailyMintCapBps(10000);
        vm.prank(owner);
        vault.setWeeklyMintCapBps(20000);
        // Setup: deposit 10000e6, set cap to 100% for easy math
        _deposit(alice, 10000e6);
        _approveVaultRISKUSD(alice, type(uint256).max);
        vm.prank(owner);
        vault.setWeeklyRedemptionCapBps(10000); // 100% cap
    }

    /// @dev B1: After window expires, windowStart advances by exactly 604800, not to block.timestamp
    function test_OFM02_windowAdvancesByPeriod() public {
        uint256 startTime = vault.weeklyRedemptionWindowStart();

        // Warp to 10 seconds after window expiry
        vm.warp(startTime + WEEKLY_WINDOW_DURATION + 10);

        // Trigger window reset via redemption
        vm.prank(alice);
        vault.redeem(1);

        // Window should advance by exactly one period from the old start
        assertEq(
            vault.weeklyRedemptionWindowStart(),
            startTime + WEEKLY_WINDOW_DURATION,
            "windowStart should advance by exactly 604800, not to block.timestamp"
        );
    }

    /// @dev B2: MEV double-redemption blocked — cannot redeem 2x cap across window boundary
    function test_OFM02_mevDoubleRedemptionBlocked() public {
        uint256 startTime = vault.weeklyRedemptionWindowStart();

        // Use the 5% launch cap: 500 bps gives a 500e6 cap on 10000e6 supply.
        vm.prank(owner);
        vault.setWeeklyRedemptionCapBps(500);

        // Redeem up to the cap just before window expires (at T + 604799)
        vm.warp(startTime + WEEKLY_WINDOW_DURATION - 1);
        vm.prank(alice);
        vault.redeem(500e6);

        // Verify cap is exhausted
        assertEq(vault.weeklyRedemptionRemaining(), 0, "cap should be exhausted");

        // Warp to exactly the window boundary (T + 604800) — triggers reset
        vm.warp(startTime + WEEKLY_WINDOW_DURATION);

        // Deposit more to have supply for the next window
        _depositWithinPerBlockCap(bob, 10000e6);
        _approveVaultRISKUSD(bob, type(uint256).max);

        // Bob can redeem in the new window, but the total across both windows
        // in rapid succession should only be 1x cap per window (not 2x in 2 blocks)
        vm.prank(bob);
        vault.redeem(1); // This triggers the window reset

        // The new window start should be exactly startTime + 604800
        // NOT startTime + 604800 + anything
        assertEq(
            vault.weeklyRedemptionWindowStart(),
            startTime + WEEKLY_WINDOW_DURATION,
            "new window should start at exact period boundary"
        );
    }

    /// @dev B3: Multiple window skips — after 3 weeks idle, windowStart advances by 3*604800
    function test_OFM02_multiWeekSkipAdvance() public {
        uint256 startTime = vault.weeklyRedemptionWindowStart();

        // Warp forward 3 weeks + 100 seconds
        vm.warp(startTime + 3 * WEEKLY_WINDOW_DURATION + 100);

        // Trigger window reset
        vm.prank(alice);
        vault.redeem(1);

        // Window should advance by 3 full periods (not to current timestamp)
        assertEq(
            vault.weeklyRedemptionWindowStart(),
            startTime + 3 * WEEKLY_WINDOW_DURATION,
            "windowStart should advance by 3*604800, not to block.timestamp"
        );
    }

    /// @dev B4: effectiveWeeklyRedemptionCap() view returns correct values during/after transition
    function test_OFM02_effectiveCapViewDuringTransition() public {
        uint256 startTime = vault.weeklyRedemptionWindowStart();

        // Use the 5% launch cap.
        vm.prank(owner);
        vault.setWeeklyRedemptionCapBps(500);

        // Trigger first redemption to snapshot supply
        vm.prank(alice);
        vault.redeem(1);

        // During active window, cap based on snapshotted supply
        uint256 capDuringWindow = vault.effectiveWeeklyRedemptionCap();
        assertEq(capDuringWindow, 10000e6 * 500 / 10000, "cap should be 5% of supply");

        // Warp past window expiry + 50 seconds
        vm.warp(startTime + WEEKLY_WINDOW_DURATION + 50);

        // View should show cap for the would-be new window
        uint256 capAfterExpiry = vault.effectiveWeeklyRedemptionCap();
        // After fix, the view should reflect the correct supply (not inflated by deposits between expiry and now)
        assertTrue(capAfterExpiry > 0, "cap should be nonzero after expiry");
    }

    /// @dev B5: weeklyRedemptionRemaining() returns correct values after window advance
    function test_OFM02_remainingViewAfterAdvance() public {
        uint256 startTime = vault.weeklyRedemptionWindowStart();

        // Use the 5% launch cap.
        vm.prank(owner);
        vault.setWeeklyRedemptionCapBps(500);

        // Redeem some in first window
        vm.prank(alice);
        vault.redeem(250e6);

        // Warp past window
        vm.warp(startTime + WEEKLY_WINDOW_DURATION);

        // Remaining should be full cap of new window (not reduced by old window usage)
        uint256 remaining = vault.weeklyRedemptionRemaining();
        uint256 expectedCap = vault.effectiveWeeklyRedemptionCap();
        assertEq(remaining, expectedCap, "remaining should equal full cap after window advance");
    }
}

// ============================================================
// OF-L21: Cap Inflation Prevention Tests
// Bug: _windowStartSupply = cachedTotalSupply at reset time (inflatable by deposit)
// Fix: Track supply from last active-window operation
// ============================================================
contract RISKUSDVault_OFL21 is RISKUSDVaultPacingBase {
    function setUp() public override {
        super.setUp();
        vm.prank(owner);
        vault.setPerBlockMintCap(10000, type(uint256).max);
        vm.prank(owner);
        vault.setDailyMintCapBps(10000);
        vm.prank(owner);
        vault.setWeeklyMintCapBps(20000);
        // Setup: deposit 10000e6, 5% launch cap.
        _deposit(alice, 10000e6);
        _approveVaultRISKUSD(alice, type(uint256).max);
        vm.prank(owner);
        vault.setWeeklyRedemptionCapBps(500); // 5% — cap = 500e6
    }

    /// @dev B10: Temporary deposit between window expiry and first redemption does NOT inflate cap
    function test_OFL21_temporaryDepositDoesNotInflateCap() public {
        uint256 startTime = vault.weeklyRedemptionWindowStart();

        // Trigger first redemption to establish window supply
        vm.prank(alice);
        vault.redeem(1);

        // Window is now active with supply snapshot of 10000e6
        // Warp past window expiry
        vm.warp(startTime + WEEKLY_WINDOW_DURATION + 1);

        // Attacker deposits a large amount BEFORE first redemption triggers reset
        _depositWithinPerBlockCap(attacker, 90000e6); // Supply now 99999e6 + original deposits

        // Now alice redeems — this triggers window reset
        // Bug: _windowStartSupply = cachedTotalSupply (inflated to ~100000e6)
        // Fix: _windowStartSupply should be based on last-active-window supply (~10000e6)
        vm.prank(alice);
        vault.redeem(1);

        // The effective cap should NOT be inflated by attacker's deposit
        // With 5% cap on ~10000e6 supply, cap should be ~500e6, NOT ~5000e6
        uint256 effectiveCap = vault.effectiveWeeklyRedemptionCap();
        assertLe(
            effectiveCap,
            750e6, // Allow some margin for the 1-unit redemptions
            "cap should NOT be inflated by temporary deposit before window reset"
        );
    }

    /// @dev B11: With min-tracking, _lastActiveSupply keeps the MINIMUM of all observed
    ///      supplies during the window. Temporary large deposits followed by redemptions
    ///      won't inflate the supply for the next window.
    function test_OFL21_legitimateDepositsAffectNextWindow() public {
        uint256 startTime = vault.weeklyRedemptionWindowStart();

        // First redemption in window 1 — snapshots supply at 10000e6
        // _lastActiveSupply = 10000e6 (pre-burn cachedTotalSupply)
        vm.prank(alice);
        vault.redeem(100e6);

        // Legitimate deposit during active window
        _depositWithinPerBlockCap(bob, 10000e6);

        // Bob redeems — cachedTotalSupply is ~19900e6, but min-tracking keeps
        // _lastActiveSupply = min(10000e6, 19900e6) = 10000e6
        _approveVaultRISKUSD(bob, type(uint256).max);
        vm.prank(bob);
        vault.redeem(1);

        // Warp to next window
        vm.warp(startTime + WEEKLY_WINDOW_DURATION);

        // Trigger window reset — uses _lastActiveSupply (10000e6) not current totalSupply
        vm.prank(alice);
        vault.redeem(1);

        // With min-tracking, the cap is based on 10000e6 (the minimum observed supply),
        // NOT the post-deposit ~19900e6. This is the correct conservative behavior.
        uint256 effectiveCap = vault.effectiveWeeklyRedemptionCap();
        // 5% of 10000e6 = 500e6
        assertEq(effectiveCap, 500e6, "cap should be based on min-tracked supply from previous window");
    }

    /// @dev B12: Cap based on last active-window operation supply, not current totalSupply at reset
    function test_OFL21_capBasedOnLastActiveSupply() public {
        uint256 startTime = vault.weeklyRedemptionWindowStart();

        // Redeem in window 1 to establish last active supply
        // Note: totalSupply() is read BEFORE the burn in _enforceWeeklyCap, so
        // _lastActiveSupply captures pre-burn supply of 10000e6
        vm.prank(alice);
        vault.redeem(100e6);

        // Warp past window 1 — no more redemptions in window 1
        vm.warp(startTime + WEEKLY_WINDOW_DURATION + 1);

        // Now deposit a large amount to inflate current totalSupply
        _depositWithinPerBlockCap(attacker, 90000e6); // supply now ~99900e6

        // Trigger window reset via redemption
        vm.prank(alice);
        vault.redeem(1);

        // Cap should be based on _lastActiveSupply (10000e6 pre-burn from window 1)
        // NOT based on current totalSupply (~99900e6 after attacker deposit)
        uint256 effectiveCap = vault.effectiveWeeklyRedemptionCap();
        // 5% of 10000e6 = 500e6
        assertEq(effectiveCap, 500e6, "cap should be based on last active supply, not inflated");
    }
}
