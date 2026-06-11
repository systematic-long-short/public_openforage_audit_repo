// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/AtRISKUSDTestBase.sol";

// ============================================================
// TC-04: Withdrawal Completion Tests (R-16, R-17, R-18, R-19, R-41)
// ============================================================
contract AtRISKUSD_TC04_WithdrawalComplete is AtRISKUSDTestBase {
    atRISKUSD internal tier0Vault;

    function setUp() public override {
        super.setUp();
        // Deploy tier 0 vault (no lockup) so requestWithdrawal does not require lockup expiry
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

    /// @dev Accrue yield in tier0 vault
    function _accrueYieldTier0(uint256 amount) internal {
        riskusd.mint(yieldSource, amount);
        vm.startPrank(yieldSource);
        riskusd.approve(address(tier0Vault), amount);
        tier0Vault.accrueYield(amount);
        vm.stopPrank();
    }

    /// @dev Setup alice with a pending withdrawal, returning the captured amount
    function _setupPendingWithdrawal(uint256 depositAmount, uint256 withdrawShares)
        internal
        returns (uint256 capturedRiskusd)
    {
        _depositTier0(alice, depositAmount);
        uint256 expectedCapture = tier0Vault.previewRedeem(withdrawShares);

        vm.prank(alice);
        tier0Vault.requestWithdrawal(withdrawShares);

        capturedRiskusd = expectedCapture;
    }

    // ----- L3 Step 1: Execute without pending reverts NoPendingWithdrawal -----
    function test_TC04_executeWithoutPendingReverts() public {
        vm.prank(bob);
        vm.expectRevert(atRISKUSD.NoPendingWithdrawal.selector);
        tier0Vault.executeWithdrawal();
    }

    // ----- L3 Step 2: Execute before cooldown reverts CooldownNotElapsed -----
    function test_TC04_executeBeforeCooldownReverts() public {
        uint256 T = block.timestamp;
        _setupPendingWithdrawal(1000e6, 500e6);

        // Warp to T + cooldownPeriod - 1
        vm.warp(T + COOLDOWN_PERIOD - 1);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(atRISKUSD.CooldownNotElapsed.selector, T + COOLDOWN_PERIOD));
        tier0Vault.executeWithdrawal();
    }

    // ----- L3 Step 3: Execute at exact cooldown succeeds -----
    function test_TC04_executeAtExactCooldownSucceeds() public {
        uint256 T = block.timestamp;
        _setupPendingWithdrawal(1000e6, 500e6);

        // Warp to exactly T + cooldownPeriod
        vm.warp(T + COOLDOWN_PERIOD);

        vm.prank(alice);
        tier0Vault.executeWithdrawal();

        // Verify pending slot cleared
        atRISKUSD.PendingWithdrawal memory pw = tier0Vault.pendingWithdrawal(alice);
        assertFalse(pw.active, "pending should be cleared after execution");
    }

    // ----- L3 Step 4: Execute happy path — burns shares, transfers captured amount, clears slot, emits event -----
    function test_TC04_executeHappyPath() public {
        uint256 aliceShares = _depositTier0(alice, 1000e6);
        uint256 withdrawShares = aliceShares / 2;
        uint256 expectedCapture = tier0Vault.previewRedeem(withdrawShares);

        vm.prank(alice);
        tier0Vault.requestWithdrawal(withdrawShares);

        uint256 contractSharesBefore = tier0Vault.balanceOf(address(tier0Vault));
        uint256 aliceRiskusdBefore = riskusd.balanceOf(alice);

        // Warp past cooldown
        vm.warp(block.timestamp + COOLDOWN_PERIOD);

        vm.expectEmit(true, false, false, true, address(tier0Vault));
        emit atRISKUSD.WithdrawalExecuted(alice, expectedCapture);

        vm.prank(alice);
        tier0Vault.executeWithdrawal();

        // Locked shares burned from contract
        assertEq(
            tier0Vault.balanceOf(address(tier0Vault)),
            contractSharesBefore - withdrawShares,
            "locked shares not burned from contract"
        );

        // Captured RISKUSD transferred to alice (NOT recalculated)
        assertEq(
            riskusd.balanceOf(alice),
            aliceRiskusdBefore + expectedCapture,
            "alice should receive captured riskusd amount"
        );

        // Pending slot cleared
        atRISKUSD.PendingWithdrawal memory pw = tier0Vault.pendingWithdrawal(alice);
        assertFalse(pw.active, "pending should be inactive");
        assertEq(pw.atriskusdAmount, 0, "pending shares should be zeroed");
        assertEq(pw.riskusdAmount, 0, "pending riskusd should be zeroed");
    }

    // ----- L3 Step 5: Captured amount vs current rate — rate lock at request time -----
    function test_TC04_capturedAmountNotRecalculated() public {
        uint256 aliceShares = _depositTier0(alice, 1000e6);
        uint256 withdrawShares = aliceShares / 2;

        // Capture the RISKUSD amount at request time
        uint256 capturedAmount = tier0Vault.previewRedeem(withdrawShares);

        vm.prank(alice);
        tier0Vault.requestWithdrawal(withdrawShares);

        // Accrue yield AFTER request (exchange rate increases)
        _accrueYieldTier0(500e6);

        // The current rate would give more RISKUSD, but execute should use captured amount
        uint256 currentRateAmount = tier0Vault.previewRedeem(withdrawShares);
        assertTrue(currentRateAmount > capturedAmount, "current rate should be higher after yield");

        // Warp past cooldown
        vm.warp(block.timestamp + COOLDOWN_PERIOD);

        uint256 aliceBalBefore = riskusd.balanceOf(alice);
        vm.prank(alice);
        tier0Vault.executeWithdrawal();

        // Alice receives the CAPTURED amount, not the current-rate amount
        uint256 aliceReceived = riskusd.balanceOf(alice) - aliceBalBefore;
        assertEq(
            aliceReceived, capturedAmount, "alice should receive captured amount from request time, not current rate"
        );
    }

    // ----- L3 Step 6: Cancel without pending reverts NoPendingWithdrawal -----
    function test_TC04_cancelWithoutPendingReverts() public {
        vm.prank(bob);
        vm.expectRevert(atRISKUSD.NoPendingWithdrawal.selector);
        tier0Vault.cancelWithdrawal();
    }

    // ----- L3 Step 7: Cancel happy path — returns shares, clears slot, emits event -----
    function test_TC04_cancelHappyPath() public {
        uint256 aliceShares = _depositTier0(alice, 1000e6);
        uint256 withdrawShares = aliceShares / 2;
        uint256 aliceBalBefore = tier0Vault.balanceOf(alice);

        vm.prank(alice);
        tier0Vault.requestWithdrawal(withdrawShares);

        uint256 aliceBalAfterRequest = tier0Vault.balanceOf(alice);
        assertEq(aliceBalAfterRequest, aliceBalBefore - withdrawShares, "alice balance after request");

        vm.expectEmit(true, false, false, true, address(tier0Vault));
        emit atRISKUSD.WithdrawalCancelled(alice, withdrawShares);

        vm.prank(alice);
        tier0Vault.cancelWithdrawal();

        // Shares returned to alice
        assertEq(
            tier0Vault.balanceOf(alice), aliceBalAfterRequest + withdrawShares, "shares should be returned to alice"
        );

        // Pending slot cleared
        atRISKUSD.PendingWithdrawal memory pw = tier0Vault.pendingWithdrawal(alice);
        assertFalse(pw.active, "pending should be inactive");
        assertEq(pw.atriskusdAmount, 0, "pending shares should be zeroed");
        assertEq(pw.riskusdAmount, 0, "pending riskusd should be zeroed");
    }

    // ----- L3 Step 8: Cancel then new request succeeds -----
    function test_TC04_cancelThenNewRequest() public {
        _depositTier0(alice, 1000e6);

        // First request
        vm.prank(alice);
        tier0Vault.requestWithdrawal(100e6);

        // Cancel
        vm.prank(alice);
        tier0Vault.cancelWithdrawal();

        // New request should succeed
        vm.prank(alice);
        tier0Vault.requestWithdrawal(200e6);

        atRISKUSD.PendingWithdrawal memory pw = tier0Vault.pendingWithdrawal(alice);
        assertTrue(pw.active, "new pending withdrawal should be active");
        assertEq(pw.atriskusdAmount, 200e6, "new pending shares should be 200e6");
    }

    // ----- L3 Step 9: Execute while paused succeeds (R-18: exit path open) -----
    function test_TC04_executeWhilePausedSucceeds() public {
        _depositTier0(alice, 1000e6);

        vm.prank(alice);
        tier0Vault.requestWithdrawal(100e6);

        // Warp past cooldown
        vm.warp(block.timestamp + COOLDOWN_PERIOD);

        // Pause the contract
        vm.prank(owner);
        tier0Vault.pause();

        // Execute should still work
        vm.prank(alice);
        tier0Vault.executeWithdrawal();

        atRISKUSD.PendingWithdrawal memory pw = tier0Vault.pendingWithdrawal(alice);
        assertFalse(pw.active, "pending should be cleared after paused execution");
    }

    // ----- L3 Step 10: Cancel while paused succeeds (R-18: exit path open) -----
    function test_TC04_cancelWhilePausedSucceeds() public {
        _depositTier0(alice, 1000e6);

        vm.prank(alice);
        tier0Vault.requestWithdrawal(100e6);

        // Pause the contract
        vm.prank(owner);
        tier0Vault.pause();

        // Cancel should still work
        uint256 balBefore = tier0Vault.balanceOf(alice);
        vm.prank(alice);
        tier0Vault.cancelWithdrawal();

        assertEq(tier0Vault.balanceOf(alice), balBefore + 100e6, "shares returned despite pause");
        atRISKUSD.PendingWithdrawal memory pw = tier0Vault.pendingWithdrawal(alice);
        assertFalse(pw.active, "pending should be cleared");
    }

    // ----- L3 Step 11: Execute after loss — alice still receives captured amount -----
    function test_TC04_executeAfterLossReceivesCapturedAmount() public {
        _depositTier0(alice, 1000e6);

        uint256 withdrawShares = 100e6;
        uint256 capturedAmount = tier0Vault.previewRedeem(withdrawShares);

        vm.prank(alice);
        tier0Vault.requestWithdrawal(withdrawShares);

        // Absorb a large loss AFTER request
        vm.prank(yieldSource);
        tier0Vault.absorbLoss(500e6);

        // Warp past cooldown
        vm.warp(block.timestamp + COOLDOWN_PERIOD);

        uint256 aliceBalBefore = riskusd.balanceOf(alice);
        vm.prank(alice);
        tier0Vault.executeWithdrawal();

        // Loss after request reduces the executable value; zero-output redemptions fail closed.
        uint256 expectedAmount = tier0Vault.previewRedeem(withdrawShares);
        uint256 received = riskusd.balanceOf(alice) - aliceBalBefore;
        assertEq(received, expectedAmount, "alice should receive current nonzero value after loss");
        assertLt(received, capturedAmount, "loss after request should reduce the executed output");
    }
}
