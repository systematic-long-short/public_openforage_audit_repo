// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/AtRISKUSDTestBase.sol";

// ============================================================
// TC-26: Front-Running Tests (R-06, R-16, R-20, R-30, R-44)
// ============================================================
contract AtRISKUSD_TC26_FrontRunning is AtRISKUSDTestBase {
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

    // ----- L3 Step 1: Deposit before yield — front-runner gets proportional benefit -----
    // Attacker cannot extract in same block because of cooldown enforcement
    function test_TC26_depositBeforeYield_cooldownPreventsExtraction() public {
        // Existing depositor
        _depositTier0(alice, 10_000e6);

        // Attacker deposits right before yield
        uint256 attackerShares = _depositTier0(attacker, 10_000e6);

        // Yield accrues in same block
        _accrueYieldTier0(1000e6);

        // Attacker's shares appreciated, but cannot extract immediately
        // Attacker requests withdrawal
        vm.prank(attacker);
        tier0Vault.requestWithdrawal(attackerShares);

        // Attempt to execute in same block (should fail due to cooldown)
        vm.prank(attacker);
        vm.expectRevert(); // CooldownNotElapsed
        tier0Vault.executeWithdrawal();

        // Verify cooldown enforced: attacker must wait 7 days
        atRISKUSD.PendingWithdrawal memory pw = tier0Vault.pendingWithdrawal(attacker);
        assertTrue(pw.active, "attacker pending should be active");
        // During 7-day wait, attacker is exposed to losses
    }

    // ----- L3 Step 2: Withdraw before loss — captured amount is pre-loss -----
    function test_TC26_withdrawBeforeLoss_capturedAmountIsPreLoss() public {
        _depositTier0(alice, 10_000e6);
        _depositTier0(attacker, 10_000e6);

        uint256 attackerShares = tier0Vault.balanceOf(attacker);
        uint256 previewBeforeLoss = tier0Vault.previewRedeem(attackerShares);

        // Attacker requests withdrawal BEFORE loss
        vm.prank(attacker);
        tier0Vault.requestWithdrawal(attackerShares);

        atRISKUSD.PendingWithdrawal memory pw = tier0Vault.pendingWithdrawal(attacker);
        uint256 capturedAmount = pw.riskusdAmount;

        // Captured amount should match pre-loss preview
        assertEq(capturedAmount, previewBeforeLoss, "captured amount must match pre-loss preview");

        // Loss occurs AFTER the request
        _absorbLossTier0(5_000e6);

        // Warp past cooldown
        vm.warp(block.timestamp + COOLDOWN_PERIOD);

        // OF-004: Repricing — current value of shares is less than captured amount
        uint256 currentValue = tier0Vault.convertToAssets(pw.atriskusdAmount);
        assertTrue(currentValue < capturedAmount, "loss should reduce current value below captured");

        uint256 attackerBefore = riskusd.balanceOf(attacker);

        // Execute withdrawal — OF-004: receives min(captured, currentValue)
        vm.prank(attacker);
        tier0Vault.executeWithdrawal();

        uint256 attackerAfter = riskusd.balanceOf(attacker);
        uint256 received = attackerAfter - attackerBefore;

        // OF-004: Received is repriced to current value (not the stale captured amount)
        assertEq(received, currentValue, "received must equal repriced (current) value after loss");
        assertTrue(received < capturedAmount, "loss during cooldown reduces payout");
    }

    // ----- L3 Step 3: Sandwich attack on deposit — unprofitable because deposit doesn't change rate -----
    function test_TC26_sandwichAttackOnDeposit_unprofitable() public {
        // Existing deposits
        _depositTier0(alice, 100_000e6);

        // Record rate before attack
        uint256 rateBeforeNum = tier0Vault.totalAssets();
        uint256 rateBeforeDen = tier0Vault.totalSupply();

        // Step A: Attacker deposits before victim
        uint256 attackerShares = _depositTier0(attacker, 10_000e6);

        // Record rate after attacker deposit — should not change
        uint256 rateAfterAttackerNum = tier0Vault.totalAssets();
        uint256 rateAfterAttackerDen = tier0Vault.totalSupply();

        // Rate should be the same: assets/supply proportional
        // rateBeforeNum / rateBeforeDen == rateAfterAttackerNum / rateAfterAttackerDen
        assertEq(
            rateBeforeNum * rateAfterAttackerDen,
            rateAfterAttackerNum * rateBeforeDen,
            "exchange rate must not change after standard deposit"
        );

        // Step B: Victim deposits (standard deposit does NOT change exchange rate)
        address victim = makeAddr("victim");
        _depositTier0(victim, 10_000e6);

        // Step C: Rate check — still proportional
        uint256 rateAfterVictimNum = tier0Vault.totalAssets();
        uint256 rateAfterVictimDen = tier0Vault.totalSupply();

        assertEq(
            rateAfterAttackerNum * rateAfterVictimDen,
            rateAfterVictimNum * rateAfterAttackerDen,
            "exchange rate must not change after victim deposit"
        );

        // Step D: Attacker tries to withdraw — must wait cooldown
        vm.prank(attacker);
        tier0Vault.requestWithdrawal(attackerShares);

        atRISKUSD.PendingWithdrawal memory pw = tier0Vault.pendingWithdrawal(attacker);
        uint256 capturedAmount = pw.riskusdAmount;

        // Attacker gets back <= what they deposited (rounding against user, no profit from sandwich)
        assertLe(capturedAmount, 10_000e6, "attacker should not profit from sandwich on plain deposit");
    }

    // ----- L3 Step 4: Sandwich attack on yield — 7-day cooldown prevents atomic extraction -----
    function test_TC26_sandwichAttackOnYield_cooldownPreventsAtomicExtraction() public {
        _depositTier0(alice, 100_000e6);

        // Attacker deposits before yield
        uint256 attackerShares = _depositTier0(attacker, 100_000e6);

        // Yield accrued
        _accrueYieldTier0(10_000e6);

        // Attacker requests withdrawal
        vm.prank(attacker);
        tier0Vault.requestWithdrawal(attackerShares);

        // Cannot execute immediately — 7-day cooldown
        vm.prank(attacker);
        vm.expectRevert(); // CooldownNotElapsed
        tier0Vault.executeWithdrawal();

        // During the 7-day wait, a loss could occur
        _absorbLossTier0(5_000e6);

        // Warp past cooldown
        vm.warp(block.timestamp + COOLDOWN_PERIOD);

        // OF-004: Withdrawal repricing — attacker gets min(captured, current value)
        atRISKUSD.PendingWithdrawal memory pw = tier0Vault.pendingWithdrawal(attacker);
        assertTrue(pw.active, "pending should still be active");

        // Current value of attacker's shares is less than captured amount due to loss
        uint256 currentValue = tier0Vault.convertToAssets(pw.atriskusdAmount);
        assertTrue(currentValue < pw.riskusdAmount, "loss should reduce current value below captured");

        uint256 attackerBefore = riskusd.balanceOf(attacker);
        vm.prank(attacker);
        tier0Vault.executeWithdrawal();
        uint256 received = riskusd.balanceOf(attacker) - attackerBefore;

        // OF-004: Repriced to current value (min of captured vs current)
        assertEq(received, currentValue, "received must equal repriced (current) value after loss");
    }

    // ----- L3 Step 5: Auto-renewal toggle front-running -----
    function test_TC26_autoRenewalToggleFrontRunning() public {
        // Deposit into locked vault
        _depositViaQueue(alice, 1000e6);

        // Auto-renewal is ON by default
        assertTrue(vault.autoRenewEnabled(alice), "auto-renew should be ON by default");

        // Warp to lockup expiry
        vm.warp(block.timestamp + LOCKUP_PERIOD);

        // Alice disables auto-renewal in same block as lockup expiry
        vm.prank(alice);
        vault.setAutoRenew(false);
        assertFalse(vault.autoRenewEnabled(alice), "auto-renew should be disabled");

        // In same block, StakingQueue tries to renew lockup
        // Should revert because auto-renew is now disabled
        vm.prank(stakingQueue);
        vm.expectRevert(atRISKUSD.AutoRenewDisabled.selector);
        vault.renewLockup(alice);

        // StakingQueue can instead call redeemForReversion since auto-renew is off and lockup expired
        uint256 aliceShares = vault.balanceOf(alice);
        vm.prank(stakingQueue);
        uint256 assets = vault.redeemForReversion(alice, aliceShares);
        assertGt(assets, 0, "reversion should succeed after auto-renew disabled");
    }

    // ----- Additional: Verify attacker proportional benefit (not excess) -----
    function test_TC26_depositBeforeYield_proportionalBenefit() public {
        // Alice deposits first
        _depositTier0(alice, 10_000e6);
        uint256 aliceSharesBefore = tier0Vault.balanceOf(alice);

        // Attacker deposits equal amount
        uint256 attackerShares = _depositTier0(attacker, 10_000e6);

        // Verify equal shares (both deposited at same rate)
        assertEq(attackerShares, aliceSharesBefore, "same deposit amount should give same shares");

        // Yield accrues
        _accrueYieldTier0(2000e6);

        // Both get proportional benefit
        uint256 aliceAssets = tier0Vault.convertToAssets(tier0Vault.balanceOf(alice));
        uint256 attackerAssets = tier0Vault.convertToAssets(tier0Vault.balanceOf(attacker));

        // Both should have approximately 11000e6 each (10000 + 1000 each from yield)
        assertEq(aliceAssets, attackerAssets, "same shares should give same asset value");
    }
}
