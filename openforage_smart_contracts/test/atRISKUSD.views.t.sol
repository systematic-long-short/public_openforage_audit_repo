// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/AtRISKUSDTestBase.sol";

// ============================================================
// TC-28: View Function Tests (R-03, R-07, R-09, R-12, R-15, R-30, R-31)
// ============================================================
contract AtRISKUSD_TC28_Views is AtRISKUSDTestBase {
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

    // ----- L3 Step 1: After initialization — all view functions return correct init values -----
    function test_TC28_afterInit_tierId() public view {
        assertEq(vault.tierId(), TIER_ID, "tierId must match initialized value");
    }

    function test_TC28_afterInit_lockupPeriod() public view {
        assertEq(vault.lockupPeriod(), LOCKUP_PERIOD, "lockupPeriod must match initialized value");
    }

    function test_TC28_afterInit_cooldownPeriod() public view {
        assertEq(vault.cooldownPeriod(), COOLDOWN_PERIOD, "cooldownPeriod must match initialized value");
    }

    function test_TC28_afterInit_yieldSource() public view {
        assertEq(vault.yieldSource(), yieldSource, "yieldSource must match initialized address");
    }

    function test_TC28_afterInit_stakingQueue() public view {
        assertEq(vault.stakingQueue(), stakingQueue, "stakingQueue must match initialized address");
    }

    function test_TC28_afterInit_totalYieldAccrued() public view {
        assertEq(vault.totalYieldAccrued(), 0, "totalYieldAccrued must be 0 after init");
    }

    function test_TC28_afterInit_totalLossAbsorbed() public view {
        assertEq(vault.totalLossAbsorbed(), 0, "totalLossAbsorbed must be 0 after init");
    }

    // ----- L3 Step 2: After deposit — lockExpiry, totalSupply, totalAssets -----
    function test_TC28_afterDeposit_lockExpiry() public {
        uint256 T = block.timestamp;
        _depositViaQueue(alice, 1000e6);

        assertEq(vault.lockExpiry(alice), T + LOCKUP_PERIOD, "lockExpiry must be T + lockupPeriod after deposit");
    }

    function test_TC28_afterDeposit_totalSupply() public {
        _depositViaQueue(alice, 1000e6);
        assertGt(vault.totalSupply(), 0, "totalSupply must be > 0 after deposit");
    }

    function test_TC28_afterDeposit_totalAssets() public {
        _depositViaQueue(alice, 1000e6);
        assertEq(vault.totalAssets(), 1000e6, "totalAssets must equal deposited RISKUSD");
    }

    // ----- L3 Step 3: After yield — totalYieldAccrued, totalAssets increased -----
    function test_TC28_afterYield_totalYieldAccrued() public {
        _depositViaQueue(alice, 1000e6);

        uint256 yieldAmount = 500e6;
        _accrueYield(yieldAmount);

        assertEq(vault.totalYieldAccrued(), yieldAmount, "totalYieldAccrued must equal yield amount");
    }

    function test_TC28_afterYield_totalAssetsIncreased() public {
        _depositViaQueue(alice, 1000e6);

        uint256 totalAssetsBefore = vault.totalAssets();
        uint256 yieldAmount = 500e6;
        _accrueYield(yieldAmount);

        assertEq(vault.totalAssets(), totalAssetsBefore + yieldAmount, "totalAssets must increase by yield amount");
    }

    // ----- L3 Step 4: After loss — totalLossAbsorbed, totalAssets decreased -----
    function test_TC28_afterLoss_totalLossAbsorbed() public {
        _depositViaQueue(alice, 1000e6);

        uint256 lossAmount = 200e6;
        _absorbLoss(lossAmount);

        assertEq(vault.totalLossAbsorbed(), lossAmount, "totalLossAbsorbed must equal loss amount");
    }

    function test_TC28_afterLoss_totalAssetsDecreased() public {
        _depositViaQueue(alice, 1000e6);

        uint256 totalAssetsBefore = vault.totalAssets();
        uint256 lossAmount = 200e6;
        _absorbLoss(lossAmount);

        assertEq(vault.totalAssets(), totalAssetsBefore - lossAmount, "totalAssets must decrease by loss amount");
    }

    // ----- L3 Step 5: After withdrawal request — pendingWithdrawal returns correct struct -----
    function test_TC28_afterWithdrawalRequest_pendingWithdrawal() public {
        _depositTier0(alice, 1000e6);
        uint256 aliceShares = tier0Vault.balanceOf(alice);
        uint256 requestAmount = aliceShares / 2;
        uint256 expectedRiskusd = tier0Vault.previewRedeem(requestAmount);
        uint256 T = block.timestamp;

        vm.prank(alice);
        tier0Vault.requestWithdrawal(requestAmount);

        atRISKUSD.PendingWithdrawal memory pw = tier0Vault.pendingWithdrawal(alice);
        assertEq(pw.atriskusdAmount, requestAmount, "pending shares must match requested amount");
        assertEq(pw.riskusdAmount, expectedRiskusd, "pending riskusd must match preview at request time");
        assertEq(pw.requestTimestamp, T, "pending timestamp must match request block timestamp");
        assertTrue(pw.active, "pending must be active");
    }

    function test_TC28_afterWithdrawalRequest_pendingWithdrawalNamedGetters() public {
        _depositTier0(alice, 1000e6);
        uint256 aliceShares = tier0Vault.balanceOf(alice);
        uint256 requestAmount = aliceShares / 2;

        vm.prank(alice);
        tier0Vault.requestWithdrawal(requestAmount);

        atRISKUSD.PendingWithdrawal memory pw = tier0Vault.pendingWithdrawal(alice);
        (uint256 riskusdAmount, uint256 atriskusdAmount) = tier0Vault.pendingWithdrawalAmount(alice);
        (uint256 windowStart, uint256 reservedAssets) = tier0Vault.pendingWithdrawalWeeklyCap(alice);

        assertEq(riskusdAmount, pw.riskusdAmount, "named riskusd amount must match struct");
        assertEq(atriskusdAmount, pw.atriskusdAmount, "named atriskusd amount must match struct");
        assertEq(
            tier0Vault.pendingWithdrawalCooldownEnd(alice),
            pw.requestTimestamp + pw.cooldownPeriod,
            "named cooldown end must match struct"
        );
        assertEq(tier0Vault.pendingWithdrawalActive(alice), pw.active, "named active flag must match struct");
        assertEq(windowStart, pw.weeklyCapWindowStart, "named weekly cap window must match struct");
        assertEq(reservedAssets, pw.weeklyCapReservedAssets, "named weekly cap reserved assets must match struct");
    }

    // ----- L3 Step 6: After withdrawal execution — pendingWithdrawal returns zeroed struct -----
    function test_TC28_afterWithdrawalExecution_pendingWithdrawalCleared() public {
        _depositTier0(alice, 1000e6);
        uint256 aliceShares = tier0Vault.balanceOf(alice);

        vm.prank(alice);
        tier0Vault.requestWithdrawal(aliceShares);

        vm.warp(block.timestamp + COOLDOWN_PERIOD);

        vm.prank(alice);
        tier0Vault.executeWithdrawal();

        atRISKUSD.PendingWithdrawal memory pw = tier0Vault.pendingWithdrawal(alice);
        assertEq(pw.atriskusdAmount, 0, "pending shares must be 0 after execution");
        assertEq(pw.riskusdAmount, 0, "pending riskusd must be 0 after execution");
        assertFalse(pw.active, "pending must be inactive after execution");
    }

    // ----- L3 Step 7: After withdrawal cancellation — pendingWithdrawal returns zeroed struct -----
    function test_TC28_afterWithdrawalCancellation_pendingWithdrawalCleared() public {
        _depositTier0(alice, 1000e6);
        uint256 aliceShares = tier0Vault.balanceOf(alice);

        vm.prank(alice);
        tier0Vault.requestWithdrawal(aliceShares / 2);

        vm.prank(alice);
        tier0Vault.cancelWithdrawal();

        atRISKUSD.PendingWithdrawal memory pw = tier0Vault.pendingWithdrawal(alice);
        assertEq(pw.atriskusdAmount, 0, "pending shares must be 0 after cancellation");
        assertEq(pw.riskusdAmount, 0, "pending riskusd must be 0 after cancellation");
        assertFalse(pw.active, "pending must be inactive after cancellation");
    }

    // ----- L3 Step 8: autoRenewEnabled — default true, toggle false, toggle back true -----
    function test_TC28_autoRenewEnabled_default() public view {
        assertTrue(vault.autoRenewEnabled(alice), "autoRenewEnabled must be true by default");
    }

    function test_TC28_autoRenewEnabled_afterDisable() public {
        vm.prank(alice);
        vault.setAutoRenew(false);
        assertFalse(vault.autoRenewEnabled(alice), "autoRenewEnabled must be false after disable");
    }

    function test_TC28_autoRenewEnabled_afterReEnable() public {
        vm.prank(alice);
        vault.setAutoRenew(false);
        vm.prank(alice);
        vault.setAutoRenew(true);
        assertTrue(vault.autoRenewEnabled(alice), "autoRenewEnabled must be true after re-enable");
    }

    // ----- L3 Step 9: After address changes — updated addresses returned -----
    function test_TC28_afterAddressChanges_yieldSource() public {
        address newYS = makeAddr("newYieldSource");
        vm.startPrank(owner);
        vault.setYieldSource(newYS);
        vm.warp(block.timestamp + 2 days + 1);
        vault.finalizeYieldSource();
        vm.stopPrank();
        assertEq(vault.yieldSource(), newYS, "yieldSource must return updated address");
    }

    function test_TC28_afterAddressChanges_stakingQueue() public {
        address newSQ = makeAddr("newStakingQueue");
        vm.startPrank(owner);
        vault.setStakingQueue(newSQ);
        vm.warp(block.timestamp + 2 days + 1);
        vault.finalizeStakingQueue();
        vm.stopPrank();
        assertEq(vault.stakingQueue(), newSQ, "stakingQueue must return updated address");
    }

    function test_TC28_afterAddressChanges_forageGovernor() public {
        address newGov = makeAddr("newGovernor");
        vm.startPrank(owner);
        vault.setForageGovernor(newGov);
        vm.warp(block.timestamp + 2 days + 1);
        vault.finalizeForageGovernor();
        vm.stopPrank();
        assertEq(vault.forageGovernor(), newGov, "forageGovernor must return updated address");
    }

    // ----- L3 Step 10: After cooldown change — cooldownPeriod returns new value -----
    function test_TC28_afterCooldownChange_cooldownPeriod() public {
        uint256 newCooldown = 14 days;
        vm.prank(owner);
        vault.setCooldownPeriod(newCooldown);
        assertEq(vault.cooldownPeriod(), newCooldown, "cooldownPeriod must return new value after change");
    }

    // ----- L3 Step 11: For address with no activity — default values -----
    function test_TC28_noActivity_lockExpiry() public {
        address newAddr = makeAddr("noActivity");
        assertEq(vault.lockExpiry(newAddr), 0, "lockExpiry must be 0 for uninitialized address");
    }

    function test_TC28_noActivity_autoRenewEnabled() public {
        address newAddr = makeAddr("noActivity");
        assertTrue(vault.autoRenewEnabled(newAddr), "autoRenewEnabled must be true for uninitialized address");
    }

    function test_TC28_noActivity_pendingWithdrawal() public {
        address newAddr = makeAddr("noActivity");
        atRISKUSD.PendingWithdrawal memory pw = vault.pendingWithdrawal(newAddr);
        assertFalse(pw.active, "pending must be inactive for uninitialized address");
        assertEq(pw.atriskusdAmount, 0, "pending shares must be 0 for uninitialized address");
        assertEq(pw.riskusdAmount, 0, "pending riskusd must be 0 for uninitialized address");
    }

    function test_TC28_noActivity_pendingWithdrawalNamedGetters() public {
        address newAddr = makeAddr("noActivityNamedGetters");
        (uint256 riskusdAmount, uint256 atriskusdAmount) = vault.pendingWithdrawalAmount(newAddr);
        (uint256 windowStart, uint256 reservedAssets) = vault.pendingWithdrawalWeeklyCap(newAddr);

        assertEq(riskusdAmount, 0, "named riskusd amount must be 0 for uninitialized address");
        assertEq(atriskusdAmount, 0, "named atriskusd amount must be 0 for uninitialized address");
        assertEq(vault.pendingWithdrawalCooldownEnd(newAddr), 0, "named cooldown end must be 0");
        assertFalse(vault.pendingWithdrawalActive(newAddr), "named active flag must be false");
        assertEq(windowStart, 0, "named weekly cap window must be 0");
        assertEq(reservedAssets, 0, "named weekly cap reserved assets must be 0");
    }

    // ----- Additional: Tier 0 specific view values -----
    function test_TC28_tier0ViewValues() public view {
        assertEq(tier0Vault.tierId(), 0, "tier0 vault tierId must be 0");
        assertEq(tier0Vault.lockupPeriod(), 0, "tier0 vault lockupPeriod must be 0");
        assertEq(tier0Vault.cooldownPeriod(), COOLDOWN_PERIOD, "tier0 vault cooldownPeriod must match");
    }

    // ----- After transfer — lockExpiry updated for recipient -----
    function test_TC28_afterTransfer_lockExpiry() public {
        _depositViaQueue(alice, 1000e6);

        // Bob has no lock
        assertEq(vault.lockExpiry(bob), 0, "bob lockExpiry must be 0 before transfer");

        // OF-016: Must warp past lockup before transfer is allowed
        vm.warp(block.timestamp + LOCKUP_PERIOD);

        uint256 aliceShares = vault.balanceOf(alice);

        // Transfer from alice to bob (lockup expired, so transfer allowed)
        vm.prank(alice);
        vault.transfer(bob, aliceShares / 2);

        // OF-016: No lock inheritance from non-StakingQueue transfers
        uint256 bobLock = vault.lockExpiry(bob);
        assertEq(bobLock, 0, "bob lockExpiry must remain 0 (no lock inheritance from user transfer)");
    }
}
