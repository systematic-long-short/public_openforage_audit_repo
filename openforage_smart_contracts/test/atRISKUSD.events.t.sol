// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/AtRISKUSDTestBase.sol";

// ============================================================
// TC-27: Event Emission Tests (R-40)
// ============================================================
contract AtRISKUSD_TC27_Events is AtRISKUSDTestBase {
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

    // ----- L3 Step 1: YieldAccrued event -----
    function test_TC27_yieldAccruedEvent() public {
        _depositTier0(alice, 1000e6);

        riskusd.mint(yieldSource, 500e6);
        vm.startPrank(yieldSource);
        riskusd.approve(address(tier0Vault), 500e6);

        vm.expectEmit(true, true, true, true, address(tier0Vault));
        emit atRISKUSD.YieldAccrued(500e6);

        tier0Vault.accrueYield(500e6);
        vm.stopPrank();
    }

    // ----- L3 Step 2: LossAbsorbed event -----
    function test_TC27_lossAbsorbedEvent() public {
        _depositTier0(alice, 1000e6);

        vm.expectEmit(true, true, true, true, address(tier0Vault));
        emit atRISKUSD.LossAbsorbed(200e6);

        vm.prank(yieldSource);
        tier0Vault.absorbLoss(200e6);
    }

    // ----- L3 Step 2b: LossAbsorbed event — capped at totalAssets -----
    function test_TC27_lossAbsorbedEvent_capped() public {
        _depositTier0(alice, 100e6);

        // Request loss of 500e6 but totalAssets is only 100e6, so capped to 100e6
        vm.expectEmit(true, true, true, true, address(tier0Vault));
        emit atRISKUSD.LossAbsorbed(100e6); // Capped amount

        vm.prank(yieldSource);
        tier0Vault.absorbLoss(500e6);
    }

    // ----- L3 Step 3: WithdrawalRequested event -----
    function test_TC27_withdrawalRequestedEvent() public {
        _depositTier0(alice, 1000e6);
        uint256 aliceShares = tier0Vault.balanceOf(alice);
        uint256 requestAmount = aliceShares / 2;
        uint256 expectedRiskusd = tier0Vault.previewRedeem(requestAmount);
        uint256 expectedCooldownEnd = block.timestamp + COOLDOWN_PERIOD;

        vm.expectEmit(true, true, true, true, address(tier0Vault));
        emit atRISKUSD.WithdrawalRequested(alice, requestAmount, expectedRiskusd, expectedCooldownEnd);

        vm.prank(alice);
        tier0Vault.requestWithdrawal(requestAmount);
    }

    // ----- L3 Step 4: WithdrawalExecuted event -----
    function test_TC27_withdrawalExecutedEvent() public {
        _depositTier0(alice, 1000e6);
        uint256 aliceShares = tier0Vault.balanceOf(alice);

        vm.prank(alice);
        tier0Vault.requestWithdrawal(aliceShares);

        atRISKUSD.PendingWithdrawal memory pw = tier0Vault.pendingWithdrawal(alice);
        uint256 capturedAmount = pw.riskusdAmount;

        vm.warp(block.timestamp + COOLDOWN_PERIOD);

        vm.expectEmit(true, true, true, true, address(tier0Vault));
        emit atRISKUSD.WithdrawalExecuted(alice, capturedAmount);

        vm.prank(alice);
        tier0Vault.executeWithdrawal();
    }

    // ----- L3 Step 5: WithdrawalCancelled event -----
    function test_TC27_withdrawalCancelledEvent() public {
        _depositTier0(alice, 1000e6);
        uint256 aliceShares = tier0Vault.balanceOf(alice);
        uint256 requestAmount = aliceShares / 2;

        vm.prank(alice);
        tier0Vault.requestWithdrawal(requestAmount);

        vm.expectEmit(true, true, true, true, address(tier0Vault));
        emit atRISKUSD.WithdrawalCancelled(alice, requestAmount);

        vm.prank(alice);
        tier0Vault.cancelWithdrawal();
    }

    // ----- L3 Step 6: OF-016: Transfer blocked during active lockup -----
    function test_TC27_lockupTransferBlockedDuringLockup() public {
        // Use the default vault (tier 1 with lockup)
        _depositViaQueue(alice, 1000e6);
        uint256 aliceLock = vault.lockExpiry(alice);

        uint256 aliceShares = vault.balanceOf(alice);

        // OF-016: Transfer during active lockup should revert
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(atRISKUSD.LockupNotExpired.selector, aliceLock));
        vault.transfer(bob, aliceShares / 2);
    }

    // ----- L3 Step 7: AutoRenewChanged event -----
    function test_TC27_autoRenewChangedEvent_disable() public {
        vm.expectEmit(true, true, true, true, address(vault));
        emit atRISKUSD.AutoRenewChanged(alice, false);

        vm.prank(alice);
        vault.setAutoRenew(false);
    }

    function test_TC27_autoRenewChangedEvent_enable() public {
        // First disable
        vm.prank(alice);
        vault.setAutoRenew(false);

        // Re-enable
        vm.expectEmit(true, true, true, true, address(vault));
        emit atRISKUSD.AutoRenewChanged(alice, true);

        vm.prank(alice);
        vault.setAutoRenew(true);
    }

    // ----- L3 Step 8: LockupRenewed event -----
    function test_TC27_lockupRenewedEvent() public {
        _depositViaQueue(alice, 1000e6);

        // Auto-renewal ON by default
        assertTrue(vault.autoRenewEnabled(alice), "auto-renew should be ON");

        // Warp past lockup
        vm.warp(block.timestamp + LOCKUP_PERIOD);

        uint256 expectedNewExpiry = block.timestamp + LOCKUP_PERIOD;

        vm.expectEmit(true, true, true, true, address(vault));
        emit atRISKUSD.LockupRenewed(alice, expectedNewExpiry);

        vm.prank(stakingQueue);
        vault.renewLockup(alice);
    }

    // ----- L3 Step 9: YieldSourceUpdated event -----
    function test_TC27_yieldSourceUpdatedEvent() public {
        address newYieldSource = makeAddr("newYieldSource");
        address oldYieldSource = vault.yieldSource();

        vm.startPrank(owner);
        vm.expectEmit(true, true, true, true, address(vault));
        emit atRISKUSD.YieldSourceProposed(oldYieldSource, newYieldSource);
        vault.setYieldSource(newYieldSource);
        vm.warp(block.timestamp + 2 days + 1);
        vault.finalizeYieldSource();
        vm.stopPrank();
    }

    // ----- L3 Step 10: StakingQueueUpdated event -----
    function test_TC27_stakingQueueUpdatedEvent() public {
        address newQueue = makeAddr("newStakingQueue");
        address oldQueue = vault.stakingQueue();

        vm.startPrank(owner);
        vm.expectEmit(true, true, true, true, address(vault));
        emit atRISKUSD.StakingQueueProposed(oldQueue, newQueue);
        vault.setStakingQueue(newQueue);
        vm.warp(block.timestamp + 2 days + 1);
        vault.finalizeStakingQueue();
        vm.stopPrank();
    }

    // ----- L3 Step 11: ForageGovernorProposed on propose; ForageGovernorSet on finalize -----
    function test_TC27_forageGovernorSetEvent() public {
        address newGov = makeAddr("newGovernor");
        address oldGov = vault.forageGovernor();

        vm.startPrank(owner);
        vm.expectEmit(true, true, true, true, address(vault));
        emit atRISKUSD.ForageGovernorProposed(oldGov, newGov);
        vault.setForageGovernor(newGov);

        vm.warp(block.timestamp + 2 days + 1);
        vm.expectEmit(true, true, true, true, address(vault));
        emit atRISKUSD.ForageGovernorSet(oldGov, newGov);
        vault.finalizeForageGovernor();
        vm.stopPrank();
    }

    // ----- L3 Step 12: CooldownPeriodUpdated event -----
    function test_TC27_cooldownPeriodUpdatedEvent() public {
        uint256 oldCooldown = tier0Vault.cooldownPeriod();
        uint256 newCooldown = 14 days;

        vm.expectEmit(true, true, true, true, address(tier0Vault));
        emit atRISKUSD.CooldownPeriodUpdated(oldCooldown, newCooldown);

        vm.prank(owner);
        tier0Vault.setCooldownPeriod(newCooldown);
    }

    // ----- L3 Step 13: Standard ERC-20 Transfer event on deposit (mint) -----
    function test_TC27_erc20TransferEventOnDeposit() public {
        riskusd.mint(stakingQueue, 1000e6);
        vm.startPrank(stakingQueue);
        riskusd.approve(address(tier0Vault), 1000e6);

        // ERC-20 Transfer event (mint): from address(0) to alice
        // We just verify the deposit emits Transfer event
        vm.expectEmit(true, true, false, false, address(tier0Vault));
        emit IERC20.Transfer(address(0), alice, 0); // amount not checked with false

        tier0Vault.deposit(1000e6, alice);
        vm.stopPrank();
    }

    // ----- L3 Step 14: Standard ERC-4626 Deposit event -----
    function test_TC27_erc4626DepositEvent() public {
        riskusd.mint(stakingQueue, 1000e6);
        vm.startPrank(stakingQueue);
        riskusd.approve(address(tier0Vault), 1000e6);

        // ERC-4626 emits Deposit(caller, receiver, assets, shares)
        // We check the indexed params
        vm.expectEmit(true, true, false, false, address(tier0Vault));
        emit IERC4626.Deposit(stakingQueue, alice, 0, 0); // amounts not checked

        tier0Vault.deposit(1000e6, alice);
        vm.stopPrank();
    }

    function test_TC27_redeemForUpgradeEmitsERC4626WithdrawEvent() public {
        uint256 aliceShares = _depositViaQueue(alice, 1000e6);
        vm.warp(block.timestamp + LOCKUP_PERIOD);

        uint256 sharesToRedeem = aliceShares / 2;
        uint256 expectedAssets = vault.previewRedeem(sharesToRedeem);

        vm.expectEmit(true, true, true, true, address(vault));
        emit IERC4626.Withdraw(stakingQueue, stakingQueue, alice, expectedAssets, sharesToRedeem);

        vm.prank(stakingQueue);
        vault.redeemForUpgrade(alice, sharesToRedeem);
    }

    function test_TC27_redeemForReversionEmitsERC4626WithdrawEvent() public {
        uint256 aliceShares = _depositViaQueue(alice, 1000e6);

        vm.prank(alice);
        vault.setAutoRenew(false);
        vm.warp(block.timestamp + LOCKUP_PERIOD);

        uint256 sharesToRedeem = aliceShares / 2;
        uint256 expectedAssets = vault.previewRedeem(sharesToRedeem);

        vm.expectEmit(true, true, true, true, address(vault));
        emit IERC4626.Withdraw(stakingQueue, stakingQueue, alice, expectedAssets, sharesToRedeem);

        vm.prank(stakingQueue);
        vault.redeemForReversion(alice, sharesToRedeem);
    }

    // ----- L3 Step 15: Paused/Unpaused events -----
    function test_TC27_pausedEvent() public {
        vm.expectEmit(true, true, true, true, address(vault));
        emit PausableUpgradeable.Paused(owner);

        vm.prank(owner);
        vault.pause();
    }

    function test_TC27_unpausedEvent() public {
        vm.prank(owner);
        vault.pause();

        vm.expectEmit(true, true, true, true, address(vault));
        emit PausableUpgradeable.Unpaused(owner);

        vm.prank(owner);
        vault.unpause();
    }
}

import "@openzeppelin/contracts/interfaces/IERC4626.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
