// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/AtRISKUSDTestBase.sol";

// ============================================================
// TC-05: Cooldown Period Tests (R-16, R-20, R-21)
// ============================================================
contract AtRISKUSD_TC05_Cooldown is AtRISKUSDTestBase {
    atRISKUSD internal tier0Vault;

    function setUp() public override {
        super.setUp();
        // Tier 0 (no lockup) so withdrawal request is not blocked by lockup
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

    // ----- L3 Step 1a: 1 second before cooldown — reverts CooldownNotElapsed -----
    function test_TC05_executeOneSecondBeforeCooldownReverts() public {
        uint256 T = block.timestamp;
        _depositTier0(alice, 1000e6);

        vm.prank(alice);
        tier0Vault.requestWithdrawal(100e6);

        // Warp to T + cooldownPeriod - 1
        vm.warp(T + COOLDOWN_PERIOD - 1);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(atRISKUSD.CooldownNotElapsed.selector, T + COOLDOWN_PERIOD));
        tier0Vault.executeWithdrawal();
    }

    // ----- L3 Step 1b: At exact cooldown — succeeds -----
    function test_TC05_executeAtExactCooldownSucceeds() public {
        uint256 T = block.timestamp;
        _depositTier0(alice, 1000e6);

        vm.prank(alice);
        tier0Vault.requestWithdrawal(100e6);

        // Warp to exactly T + cooldownPeriod
        vm.warp(T + COOLDOWN_PERIOD);

        vm.prank(alice);
        tier0Vault.executeWithdrawal();

        atRISKUSD.PendingWithdrawal memory pw = tier0Vault.pendingWithdrawal(alice);
        assertFalse(pw.active, "pending should be cleared at exact cooldown");
    }

    // ----- L3 Step 1c: 1 second after cooldown — succeeds -----
    function test_TC05_executeOneSecondAfterCooldownSucceeds() public {
        uint256 T = block.timestamp;
        _depositTier0(alice, 1000e6);

        vm.prank(alice);
        tier0Vault.requestWithdrawal(100e6);

        // Warp to T + cooldownPeriod + 1
        vm.warp(T + COOLDOWN_PERIOD + 1);

        vm.prank(alice);
        tier0Vault.executeWithdrawal();

        atRISKUSD.PendingWithdrawal memory pw = tier0Vault.pendingWithdrawal(alice);
        assertFalse(pw.active, "pending should be cleared after cooldown + 1s");
    }

    // ----- L3 Step 2a: Zero cooldown — standard withdraw() works (R-21) -----
    function test_TC05_zeroCooldownStandardWithdrawWorks() public {
        // Deploy vault with cooldownPeriod = 0
        atRISKUSD zeroCooldownVault = _deployFreshVault(0, 0, 0);
        _raiseWeeklyWithdrawalCap(zeroCooldownVault);

        riskusd.mint(stakingQueue, 1000e6);
        vm.startPrank(stakingQueue);
        riskusd.approve(address(zeroCooldownVault), 1000e6);
        zeroCooldownVault.deposit(1000e6, alice);
        vm.stopPrank();

        uint256 aliceShares = zeroCooldownVault.balanceOf(alice);
        uint256 aliceAssets = zeroCooldownVault.previewRedeem(aliceShares);

        // Standard redeem should work when cooldown == 0
        vm.prank(alice);
        zeroCooldownVault.redeem(aliceShares, alice, alice);

        assertEq(zeroCooldownVault.balanceOf(alice), 0, "alice should have 0 shares after redeem");
        assertTrue(riskusd.balanceOf(alice) > 0, "alice should have received RISKUSD");
    }

    // ----- L3 Step 2b: Zero cooldown — requestWithdrawal + executeWithdrawal succeeds immediately -----
    function test_TC05_zeroCooldownImmediateExecute() public {
        atRISKUSD zeroCooldownVault = _deployFreshVault(0, 0, 0);
        _raiseWeeklyWithdrawalCap(zeroCooldownVault);

        riskusd.mint(stakingQueue, 1000e6);
        vm.startPrank(stakingQueue);
        riskusd.approve(address(zeroCooldownVault), 1000e6);
        zeroCooldownVault.deposit(1000e6, alice);
        vm.stopPrank();

        vm.prank(alice);
        zeroCooldownVault.requestWithdrawal(100e6);

        // Execute immediately (cooldown = 0, always elapsed)
        vm.prank(alice);
        zeroCooldownVault.executeWithdrawal();

        atRISKUSD.PendingWithdrawal memory pw = zeroCooldownVault.pendingWithdrawal(alice);
        assertFalse(pw.active, "pending should be cleared with zero cooldown");
    }

    // ----- L3 Step 3: Non-zero cooldown blocks standard withdraw/redeem with CooldownEnabled -----
    function test_TC05_nonZeroCooldownBlocksStandardWithdraw() public {
        _depositTier0(alice, 1000e6);

        vm.prank(alice);
        vm.expectRevert(atRISKUSD.CooldownEnabled.selector);
        tier0Vault.withdraw(100, alice, alice);
    }

    function test_TC05_nonZeroCooldownBlocksStandardRedeem() public {
        _depositTier0(alice, 1000e6);

        vm.prank(alice);
        vm.expectRevert(atRISKUSD.CooldownEnabled.selector);
        tier0Vault.redeem(100, alice, alice);
    }

    // ----- L3 Step 4: Cooldown period change mid-withdrawal -----
    // OF-M03: cooldown is now stored at request time, not read at execute time
    function test_TC05_cooldownChangeMidWithdrawal() public {
        uint256 T = block.timestamp;
        _depositTier0(alice, 1000e6);

        vm.prank(alice);
        tier0Vault.requestWithdrawal(100e6);

        // Owner increases cooldown from 7 days to 14 days AFTER request
        vm.prank(owner);
        tier0Vault.setCooldownPeriod(14 days);

        // OF-M03: stored cooldown is still 7 days — should SUCCEED at 7 days
        vm.warp(T + 7 days);

        vm.prank(alice);
        tier0Vault.executeWithdrawal();

        atRISKUSD.PendingWithdrawal memory pw = tier0Vault.pendingWithdrawal(alice);
        assertFalse(pw.active, "pending should be cleared using stored cooldown");
    }

    // ----- L3 Step 5: Multiple users different cooldown timings -----
    function test_TC05_multipleUsersDifferentTimings() public {
        _depositTier0(alice, 1000e6);
        _depositTier0(bob, 1000e6);

        uint256 T = block.timestamp;

        // Alice requests at T
        vm.prank(alice);
        tier0Vault.requestWithdrawal(100e6);

        // Bob requests at T + 1 day
        vm.warp(T + 1 days);
        vm.prank(bob);
        tier0Vault.requestWithdrawal(100e6);

        // At T + 7 days: alice can execute, bob cannot
        vm.warp(T + COOLDOWN_PERIOD);
        vm.prank(alice);
        tier0Vault.executeWithdrawal();

        vm.prank(bob);
        vm.expectRevert(); // CooldownNotElapsed
        tier0Vault.executeWithdrawal();

        // At T + 8 days: bob can execute
        vm.warp(T + 1 days + COOLDOWN_PERIOD);
        vm.prank(bob);
        tier0Vault.executeWithdrawal();

        atRISKUSD.PendingWithdrawal memory pwAlice = tier0Vault.pendingWithdrawal(alice);
        atRISKUSD.PendingWithdrawal memory pwBob = tier0Vault.pendingWithdrawal(bob);
        assertFalse(pwAlice.active, "alice pending should be cleared");
        assertFalse(pwBob.active, "bob pending should be cleared");
    }

    // ----- L3 Step 6: Long cooldown period (365 days) -----
    function test_TC05_longCooldownPeriod() public {
        // Deploy vault with 365-day cooldown
        atRISKUSD longCooldownVault = _deployFreshVault(0, 365 days, 0);

        riskusd.mint(stakingQueue, 1000e6);
        vm.startPrank(stakingQueue);
        riskusd.approve(address(longCooldownVault), 1000e6);
        longCooldownVault.deposit(1000e6, alice);
        vm.stopPrank();

        uint256 T = block.timestamp;
        vm.prank(alice);
        longCooldownVault.requestWithdrawal(100e6);

        // 364 days + 23:59:59 — should fail
        vm.warp(T + 365 days - 1);
        vm.prank(alice);
        vm.expectRevert(); // CooldownNotElapsed
        longCooldownVault.executeWithdrawal();

        // Warp 1 more second — should succeed
        vm.warp(T + 365 days);
        vm.prank(alice);
        longCooldownVault.executeWithdrawal();

        atRISKUSD.PendingWithdrawal memory pw = longCooldownVault.pendingWithdrawal(alice);
        assertFalse(pw.active, "pending should be cleared after 365-day cooldown");
    }
}
