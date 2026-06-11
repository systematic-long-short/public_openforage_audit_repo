// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/StakingQueueTestBase.sol";

contract MockGuardianModulePermissions {
    uint256 public constant PERMISSION_CAN_PAUSE = 1;
    mapping(address => uint256) public permissions;

    function setPermission(address account, uint256 permission) external {
        permissions[account] = permission;
    }

    function hasPermission(address account, uint256 permission) external view returns (bool) {
        return permissions[account] & permission != 0;
    }
}

contract MockGovernorForTierCaps {
    address public guardianModule;

    constructor(address guardianModule_) {
        guardianModule = guardianModule_;
    }
}

contract StakingQueue_TierDepositCaps is StakingQueueTestBase {
    address internal guardian = makeAddr("tierCapGuardian");

    function test_R9_defaultTierCapUsesVaultRegistryCapacity() public view {
        assertEq(queue.effectiveTierDepositCap(1), DEFAULT_COMBINED_CAPACITY, "default tier cap");
        assertEq(queue.tierDepositAvailableCapacity(1), DEFAULT_COMBINED_CAPACITY, "default available");
    }

    function test_R9_shrunkTierCapLimitsQueueProcessing() public {
        vm.prank(owner);
        queue.shrinkTierDepositCap(1, 1_000e6);

        _joinQueue(alice, 700e6, 1);
        uint256 secondId = _joinQueue(bob, 400e6, 1);

        queue.processQueue(1, 2);

        assertEq(vault1.mockLegitimateAssets(), 700e6, "only first entry processed");
        StakingQueue.QueueEntry memory second = queue.getQueueEntry(secondId);
        assertFalse(second.processed, "second entry remains queued until cap widens");
        assertEq(queue.tierDepositAvailableCapacity(1), 300e6, "remaining tier cap");
    }

    function test_R9_governanceTierCapChangeDoesNotAutoWidenOverTime() public {
        mockVaultRegistry.setTestCapacityCap(registeredVaultId, 10_000e6);

        vm.startPrank(owner);
        queue.shrinkTierDepositCap(2, 1_000e6);
        queue.proposeTierDepositCap(2, 5_000e6);
        vm.stopPrank();

        assertEq(queue.effectiveTierDepositCap(2), 5_000e6, "owner proposal applies atomically");

        vm.warp(block.timestamp + 1 hours);
        assertEq(queue.effectiveTierDepositCap(2), 5_000e6, "time alone does not widen");

        vm.warp(block.timestamp + 3 hours);
        assertEq(queue.effectiveTierDepositCap(2), 5_000e6, "cap remains static without governance action");
    }

    function test_R9_proposedCapCannotExceedVaultRegistryCapacity() public {
        mockVaultRegistry.setTestCapacityCap(registeredVaultId, 5_000e6);

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(StakingQueue.TierDepositCapAboveVaultCapacity.selector, 5_001e6, 5_000e6)
        );
        queue.proposeTierDepositCap(0, 5_001e6);
    }

    function test_R9_guardianCanShrinkButCannotWidenTierCap() public {
        MockGuardianModulePermissions guardianModule = new MockGuardianModulePermissions();
        guardianModule.setPermission(guardian, guardianModule.PERMISSION_CAN_PAUSE());
        MockGovernorForTierCaps mockGovernor = new MockGovernorForTierCaps(address(guardianModule));

        vm.startPrank(owner);
        queue.setForageGovernor(address(mockGovernor));
        vm.warp(block.timestamp + queue.FINALIZE_DELAY() + 1);
        queue.finalizeForageGovernor();
        queue.shrinkTierDepositCap(3, 2_000e6);
        vm.stopPrank();

        vm.prank(guardian);
        queue.shrinkTierDepositCap(3, 1_500e6);
        assertEq(queue.effectiveTierDepositCap(3), 1_500e6, "guardian shrink");

        vm.prank(guardian);
        vm.expectRevert(
            abi.encodeWithSelector(StakingQueue.TierDepositCapWideningNotAllowed.selector, 3, 1_600e6, 1_500e6)
        );
        queue.shrinkTierDepositCap(3, 1_600e6);
    }

    function test_R9_upgradeTierRespectsDestinationTierCap() public {
        vm.prank(owner);
        queue.shrinkTierDepositCap(2, 400e6);

        vault1.setMockTotalAssets(500e6);
        vault1.setRedeemForUpgradeReturnAmount(500e6);
        riskusd.mint(address(vault1), 500e6);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(StakingQueue.TierDepositCapExceeded.selector, 2, 500e6, 400e6));
        queue.upgradeTier(1, 2, 500e6);
    }

    function test_R9_expiredLockupReversionDoesNotConsumeFreshDepositCap() public {
        vm.prank(owner);
        queue.shrinkTierDepositCap(0, 0);

        vault1.setLockupInfo(alice, true, true, false, false, 300e6);
        vault1.setRedeemForReversionReturnAmount(300e6);
        vault1.setMockTotalAssets(300e6);
        riskusd.mint(address(vault1), 300e6);

        vm.prank(alice);
        queue.selfRevert(1);

        assertEq(vault0.mockLegitimateAssets(), 300e6, "tier0 reversion deposit");
        assertEq(queue.tierDepositAvailableCapacity(0), 0, "fresh cap remains closed");
    }
}
