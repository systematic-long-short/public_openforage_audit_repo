// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/AtRISKUSDTestBase.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

// ============================================================
// TC-13: Pause/Unpause Tests (R-34, R-35, R-36, R-40)
// ============================================================
contract AtRISKUSD_TC13_Pause is AtRISKUSDTestBase {
    function setUp() public override {
        super.setUp();
        _raiseWeeklyWithdrawalCap(vault);
    }

    function _depositIntoVault(atRISKUSD target, address receiver, uint256 amount) internal returns (uint256 shares) {
        riskusd.mint(stakingQueue, amount);
        vm.startPrank(stakingQueue);
        riskusd.approve(address(target), amount);
        shares = target.deposit(amount, receiver);
        vm.stopPrank();
    }

    /// @dev Helper: set the forage governor on the vault so governor can pause/unpause.
    function _setGovernor() internal {
        vm.startPrank(owner);
        vault.setForageGovernor(governor);
        vm.warp(block.timestamp + 2 days + 1);
        vault.finalizeForageGovernor();
        vm.stopPrank();
    }

    // ----- L3 Step 1: Owner can pause -----
    function test_TC13_ownerCanPause() public {
        vm.expectEmit(true, false, false, false, address(vault));
        emit PausableUpgradeable.Paused(owner);

        vm.prank(owner);
        vault.pause();

        assertTrue(vault.paused(), "contract should be paused after owner pause");
    }

    // ----- L3 Step 2: Owner can unpause -----
    function test_TC13_ownerCanUnpause() public {
        vm.prank(owner);
        vault.pause();
        assertTrue(vault.paused(), "contract should be paused");

        vm.expectEmit(true, false, false, false, address(vault));
        emit PausableUpgradeable.Unpaused(owner);

        vm.prank(owner);
        vault.unpause();

        assertFalse(vault.paused(), "contract should not be paused after owner unpause");
    }

    // ----- L3 Step 3: Governor can pause -----
    function test_TC13_governorCanPause() public {
        _setGovernor();

        vm.prank(governor);
        vault.pause();

        assertTrue(vault.paused(), "contract should be paused after governor pause");
    }

    // ----- L3 Step 4: Governor can unpause -----
    function test_TC13_governorCanUnpause() public {
        _setGovernor();

        vm.prank(governor);
        vault.pause();
        assertTrue(vault.paused(), "contract should be paused");

        vm.prank(governor);
        vault.unpause();

        assertFalse(vault.paused(), "contract should not be paused after governor unpause");
    }

    // ----- L3 Step 5: Unauthorized pause reverts -----
    /// @dev pause() has dual authority (owner OR governor). An unauthorized caller MUST revert.
    function test_TC13_unauthorizedPauseReverts() public {
        vm.prank(attacker);
        vm.expectRevert();
        vault.pause();
    }

    // ----- L3 Step 6: Unauthorized unpause reverts -----
    function test_TC13_unauthorizedUnpauseReverts() public {
        vm.prank(owner);
        vault.pause();

        vm.prank(attacker);
        vm.expectRevert();
        vault.unpause();
    }

    // ----- L3 Step 7: Pause blocks deposit -----
    function test_TC13_pauseBlocksDeposit() public {
        vm.prank(owner);
        vault.pause();

        riskusd.mint(stakingQueue, 1000e6);
        vm.startPrank(stakingQueue);
        riskusd.approve(address(vault), 1000e6);
        vm.expectRevert(abi.encodeWithSelector(PausableUpgradeable.EnforcedPause.selector));
        vault.deposit(1000e6, alice);
        vm.stopPrank();
    }

    // ----- L3 Step 8: Pause blocks mint -----
    function test_TC13_pauseBlocksMint() public {
        vm.prank(owner);
        vault.pause();

        riskusd.mint(stakingQueue, 1000e6);
        vm.startPrank(stakingQueue);
        riskusd.approve(address(vault), 1000e6);
        vm.expectRevert(abi.encodeWithSelector(PausableUpgradeable.EnforcedPause.selector));
        vault.mint(1000e6, alice);
        vm.stopPrank();
    }

    function test_TC13_pauseBlocksZeroCooldownDirectWithdraw() public {
        atRISKUSD zeroCooldownVault = _deployFreshVault(0, 0, 0);
        _raiseWeeklyWithdrawalCap(zeroCooldownVault);
        _depositIntoVault(zeroCooldownVault, alice, 1000e6);

        vm.prank(owner);
        zeroCooldownVault.pause();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PausableUpgradeable.EnforcedPause.selector));
        zeroCooldownVault.withdraw(100e6, alice, alice);
    }

    function test_TC13_pauseBlocksZeroCooldownDirectRedeem() public {
        atRISKUSD zeroCooldownVault = _deployFreshVault(0, 0, 0);
        _raiseWeeklyWithdrawalCap(zeroCooldownVault);
        uint256 shares = _depositIntoVault(zeroCooldownVault, alice, 1000e6);

        vm.prank(owner);
        zeroCooldownVault.pause();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PausableUpgradeable.EnforcedPause.selector));
        zeroCooldownVault.redeem(shares / 10, alice, alice);
    }

    // ----- L3 Step 9: Pause blocks accrueYield -----
    function test_TC13_pauseBlocksAccrueYield() public {
        vm.prank(owner);
        vault.pause();

        riskusd.mint(yieldSource, 100e6);
        vm.startPrank(yieldSource);
        riskusd.approve(address(vault), 100e6);
        vm.expectRevert(abi.encodeWithSelector(PausableUpgradeable.EnforcedPause.selector));
        vault.accrueYield(100e6);
        vm.stopPrank();
    }

    // ----- L3 Step 10: OF-L22 — absorbLoss bypasses pause for emergency loss reporting -----
    function test_TC13_absorbLossBypassesPause() public {
        // Need deposits so absorbLoss has assets to absorb
        _depositViaQueue(alice, 1000e6);

        vm.prank(owner);
        vault.pause();

        // OF-L22: loss reporting bypasses pause — auth-gated by yieldSource
        vm.prank(yieldSource);
        vault.absorbLoss(100e6);

        // Verify loss was absorbed even when paused
        assertEq(vault.totalAssets(), 900e6, "Loss should be absorbed even when paused");
    }

    // ----- L3 Step 11: Pause blocks requestWithdrawal -----
    function test_TC13_pauseBlocksRequestWithdrawal() public {
        // Deposit first while unpaused
        uint256 shares = _depositViaQueue(alice, 1000e6);

        // Warp past lockup
        vm.warp(block.timestamp + LOCKUP_PERIOD);

        vm.prank(owner);
        vault.pause();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PausableUpgradeable.EnforcedPause.selector));
        vault.requestWithdrawal(shares);
    }

    // ----- L3 Step 12: Pause blocks redeemForUpgrade -----
    function test_TC13_pauseBlocksRedeemForUpgrade() public {
        uint256 shares = _depositViaQueue(alice, 1000e6);

        vm.prank(owner);
        vault.pause();

        vm.prank(stakingQueue);
        vm.expectRevert(abi.encodeWithSelector(PausableUpgradeable.EnforcedPause.selector));
        vault.redeemForUpgrade(alice, shares);
    }

    // ----- L3 Step 13: Pause blocks redeemForReversion -----
    function test_TC13_pauseBlocksRedeemForReversion() public {
        uint256 shares = _depositViaQueue(alice, 1000e6);

        // Alice disables auto-renew
        vm.prank(alice);
        vault.setAutoRenew(false);

        // Warp past lockup
        vm.warp(block.timestamp + LOCKUP_PERIOD);

        vm.prank(owner);
        vault.pause();

        vm.prank(stakingQueue);
        vm.expectRevert(abi.encodeWithSelector(PausableUpgradeable.EnforcedPause.selector));
        vault.redeemForReversion(alice, shares);
    }

    // ----- L3 Step 14: Pause blocks renewLockup -----
    function test_TC13_pauseBlocksRenewLockup() public {
        _depositViaQueue(alice, 1000e6);

        // Warp past lockup
        vm.warp(block.timestamp + LOCKUP_PERIOD);

        vm.prank(owner);
        vault.pause();

        vm.prank(stakingQueue);
        vm.expectRevert(abi.encodeWithSelector(PausableUpgradeable.EnforcedPause.selector));
        vault.renewLockup(alice);
    }

    // ----- L3 Step 15: Pause does NOT block executeWithdrawal -----
    function test_TC13_pauseDoesNotBlockExecuteWithdrawal() public {
        // Deposit and request withdrawal
        uint256 shares = _depositViaQueue(alice, 1000e6);

        // Warp past lockup
        vm.warp(block.timestamp + LOCKUP_PERIOD);

        // Request withdrawal
        vm.prank(alice);
        vault.requestWithdrawal(shares);

        // Warp past cooldown
        vm.warp(block.timestamp + COOLDOWN_PERIOD);

        // Pause
        vm.prank(owner);
        vault.pause();

        // executeWithdrawal MUST succeed even while paused (R-36, R-18)
        uint256 riskusdBefore = riskusd.balanceOf(alice);
        vm.prank(alice);
        vault.executeWithdrawal();

        assertTrue(
            riskusd.balanceOf(alice) > riskusdBefore, "alice should receive RISKUSD from executeWithdrawal while paused"
        );
    }

    // ----- L3 Step 16: Pause does NOT block cancelWithdrawal -----
    function test_TC13_pauseDoesNotBlockCancelWithdrawal() public {
        // Deposit and request withdrawal
        uint256 shares = _depositViaQueue(alice, 1000e6);

        // Warp past lockup
        vm.warp(block.timestamp + LOCKUP_PERIOD);

        // Request withdrawal
        vm.prank(alice);
        vault.requestWithdrawal(shares);

        // Pause
        vm.prank(owner);
        vault.pause();

        // cancelWithdrawal MUST succeed even while paused (R-36, R-18)
        vm.prank(alice);
        vault.cancelWithdrawal();

        // Shares should be returned to alice
        assertEq(vault.balanceOf(alice), shares, "shares should be returned after cancel while paused");
    }

    // ----- L3 Step 17: Pause does NOT block setAutoRenew -----
    function test_TC13_pauseDoesNotBlockSetAutoRenew() public {
        vm.prank(owner);
        vault.pause();

        // setAutoRenew MUST succeed even while paused (R-36)
        vm.prank(alice);
        vault.setAutoRenew(false);

        assertFalse(vault.autoRenewEnabled(alice), "setAutoRenew should work while paused");
    }

    // ----- L3 Step 18: Pause does NOT block transfers -----
    function test_TC13_pauseDoesNotBlockTransfers() public {
        uint256 shares = _depositViaQueue(alice, 1000e6);

        // OF-016: Must warp past lockup before transfers are allowed
        vm.warp(block.timestamp + LOCKUP_PERIOD);

        vm.prank(owner);
        vault.pause();

        // ERC-20 transfer MUST succeed while paused (R-36)
        uint256 transferAmount = shares / 2;
        vm.prank(alice);
        vault.transfer(bob, transferAmount);

        assertEq(vault.balanceOf(bob), transferAmount, "bob should receive shares via transfer while paused");
        assertEq(
            vault.balanceOf(alice),
            shares - transferAmount,
            "alice should have remaining shares after transfer while paused"
        );
    }

    // ----- L3 Step 19: Pause does NOT block view functions -----
    function test_TC13_pauseDoesNotBlockViewFunctions() public {
        _depositViaQueue(alice, 1000e6);

        vm.prank(owner);
        vault.pause();

        // All view functions MUST return correct values while paused (R-36)
        vault.tierId();
        vault.lockupPeriod();
        vault.cooldownPeriod();
        vault.yieldSource();
        vault.stakingQueue();
        vault.forageGovernor();
        vault.lockExpiry(alice);
        vault.autoRenewEnabled(alice);
        vault.pendingWithdrawal(alice);
        vault.totalYieldAccrued();
        vault.totalLossAbsorbed();
        vault.totalAssets();
        vault.totalSupply();
        vault.balanceOf(alice);
        vault.asset();
        vault.owner();
        vault.paused();

        assertTrue(true, "all view functions should be callable while paused");
    }

    // ----- L3 Step 20: Pause does NOT block admin setters -----
    function test_TC13_pauseDoesNotBlockAdminSetters() public {
        vm.prank(owner);
        vault.pause();

        address newYieldSource = makeAddr("newYieldSource");
        address newStakingQueue = makeAddr("newStakingQueue");
        address newGovernor = makeAddr("newGovernor");

        // setYieldSource should succeed while paused (propose + finalize)
        vm.startPrank(owner);
        vault.setYieldSource(newYieldSource);
        vm.warp(block.timestamp + 2 days + 1);
        vault.finalizeYieldSource();
        vm.stopPrank();
        assertEq(vault.yieldSource(), newYieldSource, "setYieldSource should work while paused");

        // setStakingQueue should succeed while paused (propose + finalize)
        vm.startPrank(owner);
        vault.setStakingQueue(newStakingQueue);
        vm.warp(block.timestamp + 2 days + 1);
        vault.finalizeStakingQueue();
        vm.stopPrank();
        assertEq(vault.stakingQueue(), newStakingQueue, "setStakingQueue should work while paused");

        // setCooldownPeriod should succeed while paused
        vm.prank(owner);
        vault.setCooldownPeriod(14 days);
        assertEq(vault.cooldownPeriod(), 14 days, "setCooldownPeriod should work while paused");

        // setForageGovernor should succeed while paused (propose + finalize)
        vm.startPrank(owner);
        vault.setForageGovernor(newGovernor);
        vm.warp(block.timestamp + 2 days + 1);
        vault.finalizeForageGovernor();
        vm.stopPrank();
        assertEq(vault.forageGovernor(), newGovernor, "setForageGovernor should work while paused");
    }
}
