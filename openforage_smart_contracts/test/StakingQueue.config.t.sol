// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/StakingQueueTestBase.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

// ============================================================
// TC-06: Capacity Management and Configuration Tests
// ============================================================
contract StakingQueue_TC06_Config is StakingQueueTestBase {
    // ── VaultId Configuration ──

    function test_TC06_setVaultIdNonOwnerReverts() public {
        StakingQueue impl = new StakingQueue();
        address[4] memory tierVaults = [address(vault0), address(vault1), address(vault2), address(vault3)];
        bytes memory initData = abi.encodeCall(
            StakingQueue.initialize, (address(riskusd), address(forage), tierVaults, address(mockVaultRegistry), owner)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        StakingQueue freshQueue = StakingQueue(address(proxy));

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, attacker));
        freshQueue.setVaultId(registeredVaultId);
    }

    function test_TC06_setVaultIdHappyPath() public {
        StakingQueue impl = new StakingQueue();
        address[4] memory tierVaults = [address(vault0), address(vault1), address(vault2), address(vault3)];
        bytes memory initData = abi.encodeCall(
            StakingQueue.initialize, (address(riskusd), address(forage), tierVaults, address(mockVaultRegistry), owner)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        StakingQueue freshQueue = StakingQueue(address(proxy));

        vm.expectEmit(false, false, false, true);
        emit StakingQueue.VaultIdSet(registeredVaultId);

        vm.prank(owner);
        freshQueue.setVaultId(registeredVaultId);

        assertEq(freshQueue.vaultId(), registeredVaultId, "vaultId should be set");
    }

    function test_TC06_setVaultIdAlreadySetReverts() public {
        vm.prank(owner);
        vm.expectRevert(StakingQueue.VaultIdAlreadySet.selector);
        queue.setVaultId(registeredVaultId);
    }

    // ── Capacity ──

    function test_TC06_capacityZeroViaRegistry() public {
        mockVaultRegistry.setTestCapacityCap(registeredVaultId, 0);
        assertEq(queue.combinedCapacity(), 0, "combinedCapacity should be 0");
        assertEq(queue.availableCapacity(), 0, "availableCapacity should be 0");

        _joinQueue(alice, STANDARD_DEPOSIT, 0);
        vm.expectRevert(StakingQueue.NoCapacityAvailable.selector);
        queue.processQueue(0, 1);
    }

    function test_TC06_capacityBelowStakedViaRegistry() public {
        vault0.setMockTotalAssets(2_000_000e6);
        vault1.setMockTotalAssets(1_000_000e6);
        vault2.setMockTotalAssets(1_000_000e6);
        vault3.setMockTotalAssets(1_000_000e6);

        mockVaultRegistry.setTestCapacityCap(registeredVaultId, 3_000_000e6);

        assertEq(queue.combinedCapacity(), 3_000_000e6, "combinedCapacity should be 3M");
        assertEq(queue.availableCapacity(), 0, "availableCapacity should be 0 (clamped, not negative)");
        assertEq(queue.combinedStaked(), 5_000_000e6, "combinedStaked should still be 5M");
    }

    function test_TC06_combinedStakedComputation() public {
        vault0.setMockTotalAssets(1_000_000e6);
        vault1.setMockTotalAssets(2_000_000e6);
        vault2.setMockTotalAssets(3_000_000e6);
        vault3.setMockTotalAssets(4_000_000e6);

        assertEq(queue.combinedStaked(), 10_000_000e6, "combinedStaked should be sum of all tier vault totalAssets");
    }

    function test_TC06_availableCapacityComputation() public {
        mockVaultRegistry.setTestCapacityCap(registeredVaultId, 15_000_000e6);
        vault0.setMockTotalAssets(2_500_000e6);
        vault1.setMockTotalAssets(2_500_000e6);
        vault2.setMockTotalAssets(2_500_000e6);
        vault3.setMockTotalAssets(2_500_000e6);

        assertEq(queue.availableCapacity(), 5_000_000e6, "availableCapacity should be 15M - 10M = 5M");
    }

    function test_TC06_availableCapacityOverCapacity() public {
        vault0.setMockTotalAssets(2_500_000e6);
        vault1.setMockTotalAssets(2_500_000e6);
        vault2.setMockTotalAssets(2_500_000e6);
        vault3.setMockTotalAssets(2_500_000e6);

        mockVaultRegistry.setTestCapacityCap(registeredVaultId, 8_000_000e6);

        assertEq(queue.availableCapacity(), 0, "availableCapacity should be 0 when staked exceeds capacity");
    }

    // ── FORAGE Price USD ──

    function test_TC06_setForagePriceUsdNonOwnerReverts() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, attacker));
        queue.setForagePriceUsd(1e6);
    }

    function test_TC06_setForagePriceUsdToNonZero() public {
        vm.expectEmit(false, false, false, true);
        emit StakingQueue.ForagePriceUsdProposed(0, 1e6);

        vm.startPrank(owner);
        queue.setForagePriceUsd(1e6);
        vm.warp(block.timestamp + queue.FINALIZE_DELAY() + 1);
        vm.expectEmit(false, false, false, true);
        emit StakingQueue.ForagePriceUsdUpdated(0, 1e6);
        queue.finalizeForagePriceUsd();
        vm.stopPrank();

        assertEq(queue.foragePriceUsd(), 1e6, "foragePriceUsd should be 1e6");
    }

    function test_TC06_setForagePriceUsdBackToZero() public {
        _setForagePriceUsd(1e6);
        assertEq(queue.foragePriceUsd(), 1e6, "price should be 1e6");

        vm.expectEmit(false, false, false, true);
        emit StakingQueue.ForagePriceUsdProposed(1e6, 0);

        vm.startPrank(owner);
        queue.setForagePriceUsd(0);
        vm.warp(block.timestamp + queue.FINALIZE_DELAY() + 1);
        vm.expectEmit(false, false, false, true);
        emit StakingQueue.ForagePriceUsdUpdated(1e6, 0);
        queue.finalizeForagePriceUsd();
        vm.stopPrank();
        assertEq(queue.foragePriceUsd(), 0, "foragePriceUsd should be 0");
    }

    // ── Priority Multiplier ──

    function test_TC06_setPriorityMultiplierNonOwnerReverts() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, attacker));
        queue.setPriorityMultiplier(10);
    }

    function test_TC06_setPriorityMultiplierToNonZero() public {
        vm.expectEmit(false, false, false, true);
        emit StakingQueue.PriorityMultiplierUpdated(0, 10);

        vm.prank(owner);
        queue.setPriorityMultiplier(10);

        assertEq(queue.priorityMultiplier(), 10, "priorityMultiplier should be 10");
    }

    function test_TC06_setPriorityMultiplierBackToZero() public {
        _setPriorityMultiplier(10);
        assertEq(queue.priorityMultiplier(), 10, "multiplier should be 10");

        vm.expectEmit(false, false, false, true);
        emit StakingQueue.PriorityMultiplierUpdated(10, 0);

        vm.prank(owner);
        queue.setPriorityMultiplier(0);
        assertEq(queue.priorityMultiplier(), 0, "priorityMultiplier should be 0");

        // Priority deactivated: high FORAGE user goes to standard
        forage.setLockedBalance(alice, 100_000e18);
        uint256 queueId = _joinQueue(alice, STANDARD_DEPOSIT, 0);
        StakingQueue.QueueEntry memory entry = queue.getQueueEntry(queueId);
        assertFalse(entry.priority, "entry should be standard when multiplier is 0");
    }

    // ── ForageGovernor ──

    function test_TC06_setForageGovernorNonOwnerReverts() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, attacker));
        queue.setForageGovernor(governor);
    }

    function test_TC06_setForageGovernorZeroAddressReverts() public {
        vm.prank(owner);
        vm.expectRevert(StakingQueue.ZeroAddress.selector);
        queue.setForageGovernor(address(0));
    }

    function test_TC06_setForageGovernorHappyPath() public {
        vm.startPrank(owner);
        vm.expectEmit(true, true, false, true);
        emit StakingQueue.ForageGovernorProposed(address(0), governor);
        queue.setForageGovernor(governor);

        vm.warp(block.timestamp + 2 days + 1);
        queue.finalizeForageGovernor();
        vm.stopPrank();

        assertEq(queue.forageGovernor(), governor, "forageGovernor should be set to governor");
    }

    function test_TC06_setForageGovernorChange() public {
        address newGovernor = makeAddr("newGovernor");

        _setGovernor();
        assertEq(queue.forageGovernor(), governor, "governor should be set initially");

        vm.startPrank(owner);
        vm.expectEmit(true, true, false, true);
        emit StakingQueue.ForageGovernorProposed(governor, newGovernor);
        queue.setForageGovernor(newGovernor);

        vm.warp(block.timestamp + 2 days + 1);
        queue.finalizeForageGovernor();
        vm.stopPrank();

        assertEq(queue.forageGovernor(), newGovernor, "forageGovernor should be updated");

        vm.prank(governor);
        vm.expectRevert();
        queue.pause();

        vm.prank(newGovernor);
        queue.pause();

        assertTrue(queue.paused(), "new governor should have successfully paused the contract");
    }
}
