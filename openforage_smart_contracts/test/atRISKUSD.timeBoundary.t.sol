// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/AtRISKUSDTestBase.sol";

// ============================================================
// TC-24: Time Boundary Tests (R-07, R-13, R-16, R-27, R-28)
// ============================================================
contract AtRISKUSD_TC24_TimeBoundary is AtRISKUSDTestBase {
    atRISKUSD internal tier0Vault; // no lockup, for cooldown boundary tests

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

    // ----- L3 Step 1: Cooldown expiry exact second -----
    // 1a: T + cooldownPeriod - 1 => reverts
    function test_TC24_cooldownOneSecondBefore_reverts() public {
        uint256 T = block.timestamp;
        _depositTier0(alice, 1000e6);

        vm.prank(alice);
        tier0Vault.requestWithdrawal(100e6);

        vm.warp(T + COOLDOWN_PERIOD - 1);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(atRISKUSD.CooldownNotElapsed.selector, T + COOLDOWN_PERIOD));
        tier0Vault.executeWithdrawal();
    }

    // 1b: T + cooldownPeriod => succeeds
    function test_TC24_cooldownAtExactSecond_succeeds() public {
        uint256 T = block.timestamp;
        _depositTier0(alice, 1000e6);

        vm.prank(alice);
        tier0Vault.requestWithdrawal(100e6);

        vm.warp(T + COOLDOWN_PERIOD);

        vm.prank(alice);
        tier0Vault.executeWithdrawal();

        atRISKUSD.PendingWithdrawal memory pw = tier0Vault.pendingWithdrawal(alice);
        assertFalse(pw.active, "pending should be cleared at exact cooldown second");
    }

    // 1c: T + cooldownPeriod + 1 => succeeds
    function test_TC24_cooldownOneSecondAfter_succeeds() public {
        uint256 T = block.timestamp;
        _depositTier0(alice, 1000e6);

        vm.prank(alice);
        tier0Vault.requestWithdrawal(100e6);

        vm.warp(T + COOLDOWN_PERIOD + 1);

        vm.prank(alice);
        tier0Vault.executeWithdrawal();

        atRISKUSD.PendingWithdrawal memory pw = tier0Vault.pendingWithdrawal(alice);
        assertFalse(pw.active, "pending should be cleared after cooldown + 1s");
    }

    // ----- L3 Step 2: Lockup expiry exact second -----
    // 2a: T + lockupPeriod - 1 => requestWithdrawal reverts
    function test_TC24_lockupOneSecondBefore_reverts() public {
        uint256 T = block.timestamp;
        // vault uses tier 1 (90-day lockup)
        _depositViaQueue(alice, 1000e6);

        vm.warp(T + LOCKUP_PERIOD - 1);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(atRISKUSD.LockupNotExpired.selector, T + LOCKUP_PERIOD));
        vault.requestWithdrawal(100e6);
    }

    // 2b: T + lockupPeriod => requestWithdrawal succeeds
    function test_TC24_lockupAtExactSecond_succeeds() public {
        uint256 T = block.timestamp;
        _depositViaQueue(alice, 1000e6);

        vm.warp(T + LOCKUP_PERIOD);

        vm.prank(alice);
        vault.requestWithdrawal(100e6);

        atRISKUSD.PendingWithdrawal memory pw = vault.pendingWithdrawal(alice);
        assertTrue(pw.active, "pending should be active at exact lockup expiry");
    }

    // 2c: T + lockupPeriod + 1 => requestWithdrawal succeeds
    function test_TC24_lockupOneSecondAfter_succeeds() public {
        uint256 T = block.timestamp;
        _depositViaQueue(alice, 1000e6);

        vm.warp(T + LOCKUP_PERIOD + 1);

        vm.prank(alice);
        vault.requestWithdrawal(100e6);

        atRISKUSD.PendingWithdrawal memory pw = vault.pendingWithdrawal(alice);
        assertTrue(pw.active, "pending should be active after lockup + 1s");
    }

    // ----- L3 Step 3: Auto-renewal boundary -----
    // 3a: renewLockup at exact lockup expiry => succeeds
    function test_TC24_renewLockupAtExactExpiry_succeeds() public {
        uint256 T = block.timestamp;
        _depositViaQueue(alice, 1000e6);

        // Auto-renewal is ON by default
        assertTrue(vault.autoRenewEnabled(alice), "auto-renew should be ON by default");

        // Warp to exactly lockup expiry
        vm.warp(T + LOCKUP_PERIOD);

        vm.prank(stakingQueue);
        vault.renewLockup(alice);

        uint256 newExpiry = vault.lockExpiry(alice);
        assertEq(newExpiry, T + LOCKUP_PERIOD + LOCKUP_PERIOD, "new expiry should be current timestamp + lockupPeriod");
    }

    // 3b: renewLockup 1 second before lockup expiry => reverts LockupNotExpired
    function test_TC24_renewLockupOneSecondBeforeExpiry_reverts() public {
        uint256 T = block.timestamp;
        _depositViaQueue(alice, 1000e6);

        vm.warp(T + LOCKUP_PERIOD - 1);

        vm.prank(stakingQueue);
        vm.expectRevert(abi.encodeWithSelector(atRISKUSD.LockupNotExpired.selector, T + LOCKUP_PERIOD));
        vault.renewLockup(alice);
    }

    // 3c: renewLockup 1 second after lockup expiry => succeeds
    function test_TC24_renewLockupOneSecondAfterExpiry_succeeds() public {
        uint256 T = block.timestamp;
        _depositViaQueue(alice, 1000e6);

        vm.warp(T + LOCKUP_PERIOD + 1);

        vm.prank(stakingQueue);
        vault.renewLockup(alice);

        uint256 newExpiry = vault.lockExpiry(alice);
        assertEq(newExpiry, T + LOCKUP_PERIOD + 1 + LOCKUP_PERIOD, "new expiry should be warp timestamp + lockupPeriod");
    }

    // ----- L3 Step 4: Reversion boundary -----
    // 4a: redeemForReversion at exact lockup expiry, auto-renew disabled => succeeds
    function test_TC24_reversionAtExactExpiry_succeeds() public {
        uint256 T = block.timestamp;
        _depositViaQueue(alice, 1000e6);

        // Disable auto-renewal
        vm.prank(alice);
        vault.setAutoRenew(false);

        vm.warp(T + LOCKUP_PERIOD);

        uint256 aliceShares = vault.balanceOf(alice);

        vm.prank(stakingQueue);
        uint256 assets = vault.redeemForReversion(alice, aliceShares);

        assertGt(assets, 0, "should return assets at exact lockup expiry");
    }

    // 4b: redeemForReversion 1 second before lockup expiry => reverts LockupNotExpired
    function test_TC24_reversionOneSecondBeforeExpiry_reverts() public {
        uint256 T = block.timestamp;
        _depositViaQueue(alice, 1000e6);

        vm.prank(alice);
        vault.setAutoRenew(false);

        vm.warp(T + LOCKUP_PERIOD - 1);

        uint256 aliceShares = vault.balanceOf(alice);

        vm.prank(stakingQueue);
        vm.expectRevert(abi.encodeWithSelector(atRISKUSD.LockupNotExpired.selector, T + LOCKUP_PERIOD));
        vault.redeemForReversion(alice, aliceShares);
    }

    // 4c: redeemForReversion 1 second after lockup expiry => succeeds
    function test_TC24_reversionOneSecondAfterExpiry_succeeds() public {
        uint256 T = block.timestamp;
        _depositViaQueue(alice, 1000e6);

        vm.prank(alice);
        vault.setAutoRenew(false);

        vm.warp(T + LOCKUP_PERIOD + 1);

        uint256 aliceShares = vault.balanceOf(alice);

        vm.prank(stakingQueue);
        uint256 assets = vault.redeemForReversion(alice, aliceShares);

        assertGt(assets, 0, "should return assets after lockup + 1s");
    }

    // ----- L3 Step 5: Cooldown period = 0 — request and execute in same block -----
    function test_TC24_zeroCooldownSameBlockExecution() public {
        atRISKUSD zeroCooldownVault = _deployFreshVault(0, 0, 0);
        _raiseWeeklyWithdrawalCap(zeroCooldownVault);

        riskusd.mint(stakingQueue, 1000e6);
        vm.startPrank(stakingQueue);
        riskusd.approve(address(zeroCooldownVault), 1000e6);
        zeroCooldownVault.deposit(1000e6, alice);
        vm.stopPrank();

        uint256 aliceShares = zeroCooldownVault.balanceOf(alice);

        // Request and execute in same block
        vm.prank(alice);
        zeroCooldownVault.requestWithdrawal(aliceShares);

        vm.prank(alice);
        zeroCooldownVault.executeWithdrawal();

        atRISKUSD.PendingWithdrawal memory pw = zeroCooldownVault.pendingWithdrawal(alice);
        assertFalse(pw.active, "should execute in same block with zero cooldown");
    }

    // ----- L3 Step 6: Lockup period = 0 — deposit and request in same block -----
    function test_TC24_zeroLockupSameBlockRequest() public {
        _depositTier0(alice, 1000e6);

        uint256 aliceShares = tier0Vault.balanceOf(alice);

        // Request immediately in same block (lockupPeriod == 0, so lockExpiry == block.timestamp)
        vm.prank(alice);
        tier0Vault.requestWithdrawal(aliceShares);

        atRISKUSD.PendingWithdrawal memory pw = tier0Vault.pendingWithdrawal(alice);
        assertTrue(pw.active, "should request in same block with zero lockup");
    }

    // ----- L3 Step 7: Very large timestamp (year ~2106) -----
    function test_TC24_veryLargeTimestamp() public {
        // Warp to uint32 max (~year 2106)
        uint256 farFuture = type(uint32).max;
        vm.warp(farFuture);

        _depositTier0(alice, 1000e6);

        // lockExpiry should be farFuture + 0 (tier 0, no lockup)
        uint256 lockExp = tier0Vault.lockExpiry(alice);
        assertEq(lockExp, farFuture, "lockExpiry at extreme timestamp for tier 0");

        // Cache balance before prank (inline view call would consume prank)
        uint256 aliceBal = tier0Vault.balanceOf(alice);

        // Request withdrawal should work
        vm.prank(alice);
        tier0Vault.requestWithdrawal(aliceBal);

        // Warp past cooldown
        vm.warp(farFuture + COOLDOWN_PERIOD);

        vm.prank(alice);
        tier0Vault.executeWithdrawal();

        atRISKUSD.PendingWithdrawal memory pw = tier0Vault.pendingWithdrawal(alice);
        assertFalse(pw.active, "should work at extreme timestamp");
    }

    // ----- L3 Step 8: Lockup max on deposit at extreme timestamps -----
    function test_TC24_lockupMaxAtExtremeTimestamp() public {
        uint256 farFuture = type(uint32).max;
        vm.warp(farFuture);

        // Deploy vault with 360-day lockup
        atRISKUSD tier3Vault = _deployFreshVault(31_104_000, COOLDOWN_PERIOD, 3);

        riskusd.mint(stakingQueue, 1000e6);
        vm.startPrank(stakingQueue);
        riskusd.approve(address(tier3Vault), 1000e6);
        tier3Vault.deposit(1000e6, alice);
        vm.stopPrank();

        uint256 lockExp = tier3Vault.lockExpiry(alice);
        assertEq(lockExp, farFuture + 31_104_000, "lockExpiry should be timestamp + 360 days, no overflow");
    }

    // ----- L3 Step 9: Two deposits in same block -----
    function test_TC24_twoDepositsInSameBlock() public {
        uint256 T = block.timestamp;

        // Two deposits for alice in same block
        _depositViaQueue(alice, 500e6);
        _depositViaQueue(alice, 500e6);

        uint256 lockExp = vault.lockExpiry(alice);
        // max(T + lockupPeriod, T + lockupPeriod) == T + lockupPeriod
        assertEq(lockExp, T + LOCKUP_PERIOD, "lockExpiry should be T + lockupPeriod for same-block deposits");
    }

    // ----- L3 Step 10: Cooldown reads current value (not value at request time) -----
    // OF-M03: cooldown is now stored at request time, not read at execute time
    function test_TC24_cooldownUsesStoredValue() public {
        uint256 T = block.timestamp;
        _depositTier0(alice, 1000e6);

        vm.prank(alice);
        tier0Vault.requestWithdrawal(100e6);

        // Owner changes cooldown from 7 days to 14 days AFTER request
        vm.prank(owner);
        tier0Vault.setCooldownPeriod(14 days);

        // OF-M03: stored cooldown is 7 days — should SUCCEED at 7 days
        vm.warp(T + 7 days);

        vm.prank(alice);
        tier0Vault.executeWithdrawal();

        atRISKUSD.PendingWithdrawal memory pw = tier0Vault.pendingWithdrawal(alice);
        assertFalse(pw.active, "pending should be cleared using stored cooldown");
    }
}
