// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/AtRISKUSDTestBase.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

// ============================================================
// TC-14: Authorization Management Tests (R-32, R-33, R-40)
// ============================================================
contract AtRISKUSD_TC14_Auth is AtRISKUSDTestBase {
    // ============================================================
    // L3 Step 1: setYieldSource authorization
    // ============================================================

    /// @dev Non-owner calls setYieldSource -- MUST revert OwnableUnauthorizedAccount.
    function test_TC14_setYieldSourceNonOwnerReverts() public {
        address newYS = makeAddr("newYieldSource");
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, alice));
        vault.setYieldSource(newYS);
    }

    /// @dev Owner calls setYieldSource with valid address -- MUST succeed.
    /// YieldSourceUpdated(old, new) event emitted.
    function test_TC14_setYieldSourceOwnerSucceeds() public {
        address newYS = makeAddr("newYieldSource");

        vm.startPrank(owner);
        vm.expectEmit(true, true, false, false, address(vault));
        emit atRISKUSD.YieldSourceProposed(yieldSource, newYS);
        vault.setYieldSource(newYS);
        vm.warp(block.timestamp + 2 days + 1);
        vault.finalizeYieldSource();
        vm.stopPrank();

        assertEq(vault.yieldSource(), newYS, "yieldSource should be updated");
    }

    /// @dev setYieldSource(address(0)) -- MUST revert ZeroAddress.
    function test_TC14_setYieldSourceZeroAddressReverts() public {
        vm.prank(owner);
        vm.expectRevert(atRISKUSD.ZeroAddress.selector);
        vault.setYieldSource(address(0));
    }

    // ============================================================
    // L3 Step 2: setStakingQueue authorization
    // ============================================================

    /// @dev Non-owner calls setStakingQueue -- MUST revert OwnableUnauthorizedAccount.
    function test_TC14_setStakingQueueNonOwnerReverts() public {
        address newSQ = makeAddr("newStakingQueue");
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, alice));
        vault.setStakingQueue(newSQ);
    }

    /// @dev Owner calls setStakingQueue with valid address -- MUST succeed.
    /// StakingQueueUpdated(old, new) event emitted.
    function test_TC14_setStakingQueueOwnerSucceeds() public {
        address newSQ = makeAddr("newStakingQueue");

        vm.startPrank(owner);
        vm.expectEmit(true, true, false, false, address(vault));
        emit atRISKUSD.StakingQueueProposed(stakingQueue, newSQ);
        vault.setStakingQueue(newSQ);
        vm.warp(block.timestamp + 2 days + 1);
        vault.finalizeStakingQueue();
        vm.stopPrank();

        assertEq(vault.stakingQueue(), newSQ, "stakingQueue should be updated");
    }

    /// @dev setStakingQueue(address(0)) -- MUST revert ZeroAddress.
    function test_TC14_setStakingQueueZeroAddressReverts() public {
        vm.prank(owner);
        vm.expectRevert(atRISKUSD.ZeroAddress.selector);
        vault.setStakingQueue(address(0));
    }

    // ============================================================
    // L3 Step 3: setForageGovernor authorization
    // ============================================================

    /// @dev Non-owner calls setForageGovernor -- MUST revert OwnableUnauthorizedAccount.
    function test_TC14_setForageGovernorNonOwnerReverts() public {
        address newGov = makeAddr("newGovernor");
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, alice));
        vault.setForageGovernor(newGov);
    }

    /// @dev Owner calls setForageGovernor with valid address -- MUST succeed after propose+finalize.
    /// ForageGovernorProposed(old, new) event emitted on propose; ForageGovernorSet on finalize.
    function test_TC14_setForageGovernorOwnerSucceeds() public {
        address newGov = makeAddr("newGovernor");

        vm.startPrank(owner);
        vm.expectEmit(true, true, false, false, address(vault));
        emit atRISKUSD.ForageGovernorProposed(address(0), newGov);
        vault.setForageGovernor(newGov);

        vm.warp(block.timestamp + 2 days + 1);
        vault.finalizeForageGovernor();
        vm.stopPrank();

        assertEq(vault.forageGovernor(), newGov, "forageGovernor should be updated");
    }

    /// @dev setForageGovernor(address(0)) -- MUST revert ZeroAddress.
    function test_TC14_setForageGovernorZeroAddressReverts() public {
        vm.prank(owner);
        vm.expectRevert(atRISKUSD.ZeroAddress.selector);
        vault.setForageGovernor(address(0));
    }

    // ============================================================
    // L3 Step 4: setCooldownPeriod authorization
    // ============================================================

    /// @dev Non-owner calls setCooldownPeriod -- MUST revert OwnableUnauthorizedAccount.
    function test_TC14_setCooldownPeriodNonOwnerReverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, alice));
        vault.setCooldownPeriod(14 days);
    }

    /// @dev Owner calls setCooldownPeriod with valid value -- MUST succeed.
    /// CooldownPeriodUpdated(old, new) event emitted.
    function test_TC14_setCooldownPeriodOwnerSucceeds() public {
        uint256 newCooldown = 14 days;

        vm.expectEmit(false, false, false, true, address(vault));
        emit atRISKUSD.CooldownPeriodUpdated(COOLDOWN_PERIOD, newCooldown);

        vm.prank(owner);
        vault.setCooldownPeriod(newCooldown);

        assertEq(vault.cooldownPeriod(), newCooldown, "cooldownPeriod should be updated");
    }

    /// @dev setCooldownPeriod(0) -- MUST succeed (no on-chain bounds, R-33).
    function test_TC14_setCooldownPeriodZeroSucceeds() public {
        vm.prank(owner);
        vault.setCooldownPeriod(0);

        assertEq(vault.cooldownPeriod(), 0, "cooldownPeriod should be 0");
    }

    /// @dev setCooldownPeriod(type(uint256).max) -- MUST succeed (no on-chain bounds, R-33).
    function test_TC14_setCooldownPeriodMaxUint256Succeeds() public {
        vm.prank(owner);
        vault.setCooldownPeriod(type(uint256).max);

        assertEq(vault.cooldownPeriod(), type(uint256).max, "cooldownPeriod should be type(uint256).max");
    }

    // ============================================================
    // L3 Step 5: setYieldSource functional verification
    // ============================================================

    /// @dev After setting new yield source, old source calls accrueYield() -- MUST revert.
    /// New source calls accrueYield() -- MUST succeed.
    function test_TC14_setYieldSourceFunctionalVerification() public {
        // Deposit so totalAssets > 0
        _depositViaQueue(alice, 1000e6);

        address newYieldSource = makeAddr("newYieldSource");

        vm.startPrank(owner);
        vault.setYieldSource(newYieldSource);
        vm.warp(block.timestamp + 2 days + 1);
        vault.finalizeYieldSource();
        vm.stopPrank();

        // Old yield source should now be unauthorized
        riskusd.mint(yieldSource, 100e6);
        vm.startPrank(yieldSource);
        riskusd.approve(address(vault), 100e6);
        vm.expectRevert(atRISKUSD.UnauthorizedYieldSource.selector);
        vault.accrueYield(100e6);
        vm.stopPrank();

        // New yield source should succeed
        riskusd.mint(newYieldSource, 100e6);
        vm.startPrank(newYieldSource);
        riskusd.approve(address(vault), 100e6);
        vault.accrueYield(100e6);
        vm.stopPrank();

        assertEq(vault.totalYieldAccrued(), 100e6, "yield should be accrued from new source");
    }

    // ============================================================
    // L3 Step 6: setStakingQueue functional verification
    // ============================================================

    /// @dev After setting new staking queue, old queue calls deposit() -- MUST revert.
    /// New queue calls deposit() -- MUST succeed.
    function test_TC14_setStakingQueueFunctionalVerification() public {
        address newStakingQueue = makeAddr("newStakingQueue");

        vm.startPrank(owner);
        vault.setStakingQueue(newStakingQueue);
        vm.warp(block.timestamp + 2 days + 1);
        vault.finalizeStakingQueue();
        vm.stopPrank();

        // Old staking queue should now be unauthorized
        riskusd.mint(stakingQueue, 1000e6);
        vm.startPrank(stakingQueue);
        riskusd.approve(address(vault), 1000e6);
        vm.expectRevert(atRISKUSD.UnauthorizedStakingQueue.selector);
        vault.deposit(1000e6, alice);
        vm.stopPrank();

        // New staking queue should succeed
        riskusd.mint(newStakingQueue, 1000e6);
        vm.startPrank(newStakingQueue);
        riskusd.approve(address(vault), 1000e6);
        uint256 shares = vault.deposit(1000e6, alice);
        vm.stopPrank();

        assertTrue(shares > 0, "deposit from new staking queue should succeed");
        assertEq(vault.balanceOf(alice), shares, "alice should have shares from new queue deposit");
    }
}
