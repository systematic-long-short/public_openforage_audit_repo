// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/AtRISKUSDTestBase.sol";

// ============================================================
// TC-03: Withdrawal Initiation Tests (R-13, R-14, R-15, R-39, R-41, R-45)
// ============================================================
contract AtRISKUSD_TC03_WithdrawalInit is AtRISKUSDTestBase {
    // Use tier 0 (no lockup) by default for most tests; tier 1 for lockup-specific tests.
    atRISKUSD internal tier0Vault;

    function setUp() public override {
        super.setUp();
        // Deploy a tier 0 vault (no lockup) for withdrawal tests where lockup is not the focus
        tier0Vault = _deployFreshVault(0, COOLDOWN_PERIOD, 0);
        _raiseWeeklyWithdrawalCap(tier0Vault);
    }

    /// @dev Deposit into the tier0 vault via stakingQueue
    function _depositTier0(address receiver, uint256 amount) internal returns (uint256 shares) {
        riskusd.mint(stakingQueue, amount);
        vm.startPrank(stakingQueue);
        riskusd.approve(address(tier0Vault), amount);
        shares = tier0Vault.deposit(amount, receiver);
        vm.stopPrank();
    }

    /// @dev Accrue yield in tier0 vault
    function _accrueYieldTier0(uint256 amount) internal {
        riskusd.mint(yieldSource, amount);
        vm.startPrank(yieldSource);
        riskusd.approve(address(tier0Vault), amount);
        tier0Vault.accrueYield(amount);
        vm.stopPrank();
    }

    // ----- L3 Step 1: Zero amount reverts ZeroAmount -----
    function test_TC03_requestWithdrawalZeroAmountReverts() public {
        _depositTier0(alice, 1000e6);
        vm.prank(alice);
        vm.expectRevert(atRISKUSD.ZeroAmount.selector);
        tier0Vault.requestWithdrawal(0);
    }

    // ----- L3 Step 2: Lockup not expired (tier 1) reverts LockupNotExpired -----
    function test_TC03_requestWithdrawalLockupNotExpiredReverts() public {
        uint256 T = block.timestamp;
        _depositViaQueue(alice, 1000e6); // tier 1, lockExpiry = T + 90 days

        // At T + 1 day — lockup not expired
        vm.warp(T + 1 days);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(atRISKUSD.LockupNotExpired.selector, T + LOCKUP_PERIOD));
        vault.requestWithdrawal(100e6);
    }

    // ----- L3 Step 3: Lockup exactly expired — succeeds -----
    function test_TC03_requestWithdrawalLockupExactlyExpired() public {
        uint256 T = block.timestamp;
        _depositViaQueue(alice, 1000e6);

        // Warp to exactly T + lockupPeriod
        vm.warp(T + LOCKUP_PERIOD);
        vm.prank(alice);
        vault.requestWithdrawal(100e6);

        // Verify pending withdrawal is active
        atRISKUSD.PendingWithdrawal memory pw = vault.pendingWithdrawal(alice);
        assertTrue(pw.active, "pending withdrawal should be active");
    }

    // ----- L3 Step 4: No lockup (tier 0) — immediate request succeeds -----
    function test_TC03_requestWithdrawalNoLockupImmediate() public {
        _depositTier0(alice, 1000e6);

        // Request immediately after deposit
        vm.prank(alice);
        tier0Vault.requestWithdrawal(100e6);

        atRISKUSD.PendingWithdrawal memory pw = tier0Vault.pendingWithdrawal(alice);
        assertTrue(pw.active, "pending withdrawal should be active for tier 0");
    }

    // ----- L3 Step 5: Happy path — shares transferred, amount captured, event emitted -----
    function test_TC03_requestWithdrawalHappyPath() public {
        uint256 aliceShares = _depositTier0(alice, 1000e6);
        uint256 requestAmount = 500e6;

        // Pre-calculate expected RISKUSD capture
        uint256 expectedRiskusd = tier0Vault.previewRedeem(requestAmount);
        uint256 aliceBalBefore = tier0Vault.balanceOf(alice);
        uint256 contractBalBefore = tier0Vault.balanceOf(address(tier0Vault));
        uint256 requestTime = block.timestamp;

        vm.expectEmit(true, false, false, true, address(tier0Vault));
        emit atRISKUSD.WithdrawalRequested(alice, requestAmount, expectedRiskusd, requestTime + COOLDOWN_PERIOD);

        vm.prank(alice);
        tier0Vault.requestWithdrawal(requestAmount);

        // Shares transferred from alice to contract
        assertEq(tier0Vault.balanceOf(alice), aliceBalBefore - requestAmount, "alice shares not deducted");
        assertEq(
            tier0Vault.balanceOf(address(tier0Vault)),
            contractBalBefore + requestAmount,
            "contract should hold locked shares"
        );

        // Pending withdrawal stored correctly
        atRISKUSD.PendingWithdrawal memory pw = tier0Vault.pendingWithdrawal(alice);
        assertEq(pw.atriskusdAmount, requestAmount, "pending shares mismatch");
        assertEq(pw.riskusdAmount, expectedRiskusd, "pending riskusd mismatch");
        assertEq(pw.requestTimestamp, requestTime, "pending timestamp mismatch");
        assertTrue(pw.active, "pending should be active");
    }

    // ----- L3 Step 6: RISKUSD amount captured at request-time exchange rate -----
    function test_TC03_riskusdAmountCapturedAtRequestRate() public {
        _depositTier0(alice, 1000e6);
        _accrueYieldTier0(100e6); // exchange rate > 1:1

        uint256 requestAmount = 500e6;
        uint256 expectedRiskusd = tier0Vault.previewRedeem(requestAmount);

        vm.prank(alice);
        tier0Vault.requestWithdrawal(requestAmount);

        atRISKUSD.PendingWithdrawal memory pw = tier0Vault.pendingWithdrawal(alice);
        assertEq(pw.riskusdAmount, expectedRiskusd, "captured riskusdAmount should match previewRedeem at request time");
        // Rate > 1:1, so riskusdAmount should be greater than the share count
        // (accounting for virtual offset, this may not always hold, but the captured value is correct)
    }

    // ----- L3 Step 7: Single-slot enforcement — duplicate request reverts -----
    function test_TC03_requestWithdrawalDuplicateReverts() public {
        uint256 aliceShares = _depositTier0(alice, 1000e6);

        vm.prank(alice);
        tier0Vault.requestWithdrawal(100e6);

        // Second request while first is active
        vm.prank(alice);
        vm.expectRevert(atRISKUSD.PendingWithdrawalExists.selector);
        tier0Vault.requestWithdrawal(100e6);
    }

    // ----- L3 Step 8: Insufficient balance reverts -----
    function test_TC03_requestWithdrawalInsufficientBalanceReverts() public {
        uint256 aliceShares = _depositTier0(alice, 100e6);

        // Try to request more shares than alice has
        uint256 tooMany = aliceShares + 1;
        vm.prank(alice);
        vm.expectRevert(); // ERC-20 insufficient balance
        tier0Vault.requestWithdrawal(tooMany);
    }

    // ----- L3 Step 9: Paused state blocks requestWithdrawal -----
    function test_TC03_requestWithdrawalPausedReverts() public {
        _depositTier0(alice, 1000e6);
        vm.prank(owner);
        tier0Vault.pause();

        vm.prank(alice);
        vm.expectRevert(); // EnforcedPause
        tier0Vault.requestWithdrawal(100e6);
    }

    // ----- L3 Step 10: Full balance withdrawal -----
    function test_TC03_requestWithdrawalFullBalance() public {
        uint256 aliceShares = _depositTier0(alice, 1000e6);

        vm.prank(alice);
        tier0Vault.requestWithdrawal(aliceShares);

        assertEq(tier0Vault.balanceOf(alice), 0, "alice should have 0 shares after full withdrawal request");
        atRISKUSD.PendingWithdrawal memory pw = tier0Vault.pendingWithdrawal(alice);
        assertEq(pw.atriskusdAmount, aliceShares, "pending should contain full share amount");
        assertTrue(pw.active, "pending should be active");
    }
}
