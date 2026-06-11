// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/StakingQueueTestBase.sol";
import "./helpers/StakingQueueV2.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

// ============================================================
// TC-11: Authorization Management Tests
// ============================================================
contract StakingQueue_TC11_Auth is StakingQueueTestBase {
    function test_TC11_setVaultIdNonOwnerReverts() public {
        StakingQueue impl = new StakingQueue();
        address[4] memory tierVaults = [address(vault0), address(vault1), address(vault2), address(vault3)];
        bytes memory initData = abi.encodeCall(
            StakingQueue.initialize, (address(riskusd), address(forage), tierVaults, address(mockVaultRegistry), owner)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        StakingQueue freshQueue = StakingQueue(address(proxy));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, alice));
        freshQueue.setVaultId(registeredVaultId);
    }

    function test_TC11_setForagePriceUsdNonOwnerReverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, alice));
        queue.setForagePriceUsd(1e6);
    }

    function test_TC11_setPriorityMultiplierNonOwnerReverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, alice));
        queue.setPriorityMultiplier(10);
    }

    function test_TC11_setForageGovernorNonOwnerReverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, alice));
        queue.setForageGovernor(governor);
    }

    function test_TC11_pauseNonOwnerNonGovernorReverts() public {
        vm.prank(attacker);
        vm.expectRevert();
        queue.pause();
    }

    function test_TC11_unpauseNonOwnerNonGovernorReverts() public {
        vm.prank(owner);
        queue.pause();

        vm.prank(attacker);
        vm.expectRevert();
        queue.unpause();
    }

    function test_TC11_upgradeToAndCallNonOwnerReverts() public {
        StakingQueueV2 v2Impl = new StakingQueueV2();

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, attacker));
        queue.upgradeToAndCall(address(v2Impl), "");
    }

    function test_TC11_transferOwnershipNonOwnerReverts() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, attacker));
        queue.transferOwnership(attacker);
    }

    function test_TC11_allConfigFromOwnerSucceed() public {
        assertEq(queue.vaultId(), registeredVaultId, "vaultId should be set from setUp");

        // setForagePriceUsd
        vm.expectEmit(false, false, false, true);
        emit StakingQueue.ForagePriceUsdProposed(0, 1e6);
        vm.startPrank(owner);
        queue.setForagePriceUsd(1e6);
        vm.warp(block.timestamp + queue.FINALIZE_DELAY() + 1);
        vm.expectEmit(false, false, false, true);
        emit StakingQueue.ForagePriceUsdUpdated(0, 1e6);
        queue.finalizeForagePriceUsd();
        vm.stopPrank();
        assertEq(queue.foragePriceUsd(), 1e6, "price should be 1e6");

        // setPriorityMultiplier
        vm.expectEmit(false, false, false, true);
        emit StakingQueue.PriorityMultiplierUpdated(0, 10);
        vm.prank(owner);
        queue.setPriorityMultiplier(10);
        assertEq(queue.priorityMultiplier(), 10, "multiplier should be 10");

        // setForageGovernor (propose + finalize)
        vm.startPrank(owner);
        vm.expectEmit(true, true, false, true);
        emit StakingQueue.ForageGovernorProposed(address(0), governor);
        queue.setForageGovernor(governor);
        vm.warp(block.timestamp + 2 days + 1);
        queue.finalizeForageGovernor();
        vm.stopPrank();
        assertEq(queue.forageGovernor(), governor, "governor should be set");
    }

    function test_TC11_attack44_unauthorizedConfigReverts() public {
        vm.startPrank(attacker);

        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, attacker));
        queue.setForagePriceUsd(1);

        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, attacker));
        queue.setPriorityMultiplier(1);

        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, attacker));
        queue.setForageGovernor(attacker);

        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, attacker));
        queue.transferOwnership(attacker);

        StakingQueueV2 v2Impl = new StakingQueueV2();
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, attacker));
        queue.upgradeToAndCall(address(v2Impl), "");

        vm.stopPrank();

        vm.prank(attacker);
        vm.expectRevert();
        queue.pause();
    }
}
