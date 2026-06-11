// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/StakingQueueTestBase.sol";
import "./helpers/StakingQueueV2.sol";
import "./helpers/StakingQueueV3.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

// ============================================================
// TC-13: UUPS Upgrade Tests (L3 steps 1-10)
// Requirements: R-02, R-47
// ============================================================
contract StakingQueue_TC13_Upgrade is StakingQueueTestBase {
    bytes32 internal constant ERC1967_IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    /// @dev Helper to read the implementation address from the ERC1967 proxy storage slot.
    function _getImplementationAddress() internal view returns (address) {
        return address(uint160(uint256(vm.load(address(queue), ERC1967_IMPL_SLOT))));
    }

    /// @dev L3 step 1: Non-owner upgrade. Non-owner calls upgradeToAndCall() -- MUST revert.
    function test_TC13_nonOwnerUpgradeReverts() public {
        StakingQueueV2 v2Impl = new StakingQueueV2();

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, attacker));
        queue.upgradeToAndCall(address(v2Impl), "");
    }

    /// @dev L3 step 2: Owner upgrade to v2. Deploy StakingQueueV2 implementation.
    ///      Owner calls upgradeToAndCall(v2Impl, ""). MUST succeed.
    function test_TC13_ownerUpgradeToV2Succeeds() public {
        address implBefore = _getImplementationAddress();
        StakingQueueV2 v2Impl = new StakingQueueV2();

        vm.prank(owner);
        queue.upgradeToAndCall(address(v2Impl), "");

        address implAfter = _getImplementationAddress();
        assertTrue(implAfter != implBefore, "implementation address should change after upgrade");
        assertEq(implAfter, address(v2Impl), "implementation should be v2");
    }

    /// @dev State snapshot struct to avoid stack-too-deep in state preservation tests.
    struct StateSnapshot {
        address riskusdAddr;
        address forageAddr;
        address tv0;
        address tv1;
        address tv2;
        address tv3;
        uint256 cap;
        uint256 price;
        uint256 multiplier;
        address gov;
        uint256 nextId;
        uint256 totalQueued;
        address ownerAddr;
        bool pausedState;
    }

    function _takeSnapshot() internal view returns (StateSnapshot memory s) {
        s.riskusdAddr = queue.riskusd();
        s.forageAddr = queue.forage();
        s.tv0 = queue.tierVault(0);
        s.tv1 = queue.tierVault(1);
        s.tv2 = queue.tierVault(2);
        s.tv3 = queue.tierVault(3);
        s.cap = queue.combinedCapacity();
        s.price = queue.foragePriceUsd();
        s.multiplier = queue.priorityMultiplier();
        s.gov = queue.forageGovernor();
        s.nextId = queue.nextQueueId();
        s.totalQueued = queue.totalQueuedRiskusd();
        s.ownerAddr = queue.owner();
        s.pausedState = queue.paused();
    }

    function _verifySnapshot(StateSnapshot memory s) internal view {
        assertEq(queue.riskusd(), s.riskusdAddr, "riskusd should be preserved");
        assertEq(queue.forage(), s.forageAddr, "forage should be preserved");
        assertEq(queue.tierVault(0), s.tv0, "tierVault(0) should be preserved");
        assertEq(queue.tierVault(1), s.tv1, "tierVault(1) should be preserved");
        assertEq(queue.tierVault(2), s.tv2, "tierVault(2) should be preserved");
        assertEq(queue.tierVault(3), s.tv3, "tierVault(3) should be preserved");
        assertEq(queue.combinedCapacity(), s.cap, "combinedCapacity should be preserved");
        assertEq(queue.foragePriceUsd(), s.price, "foragePriceUsd should be preserved");
        assertEq(queue.priorityMultiplier(), s.multiplier, "priorityMultiplier should be preserved");
        assertEq(queue.forageGovernor(), s.gov, "forageGovernor should be preserved");
        assertEq(queue.nextQueueId(), s.nextId, "nextQueueId should be preserved");
        assertEq(queue.totalQueuedRiskusd(), s.totalQueued, "totalQueuedRiskusd should be preserved");
        assertEq(queue.owner(), s.ownerAddr, "owner should be preserved");
        assertEq(queue.paused(), s.pausedState, "paused state should be preserved");
    }

    /// @dev L3 step 3: State preservation after v1->v2. All state vars unchanged.
    function test_TC13_statePreservationV1ToV2() public {
        // Set up state before upgrade
        _setGovernor();
        _activatePriority(1e6, 10);
        mockVaultRegistry.setTestCapacityCap(registeredVaultId, 15_000_000e6);

        // Queue an entry so we have queue state
        uint256 queueId = _joinQueue(alice, STANDARD_DEPOSIT, 0);

        // Snapshot state before upgrade
        StateSnapshot memory snap = _takeSnapshot();

        // Upgrade to v2
        StakingQueueV2 v2Impl = new StakingQueueV2();
        vm.prank(owner);
        queue.upgradeToAndCall(address(v2Impl), "");

        // Verify all state preserved
        _verifySnapshot(snap);

        // Queue entry should be retrievable and unchanged
        StakingQueue.QueueEntry memory entry = queue.getQueueEntry(queueId);
        assertEq(entry.depositor, alice, "queue entry depositor should be preserved");
        assertEq(entry.riskusdAmount, STANDARD_DEPOSIT, "queue entry amount should be preserved");
        assertEq(entry.tier, 0, "queue entry tier should be preserved");
    }

    /// @dev L3 step 4: Multi-generation v2->v3. Upgrade from v2 to v3. State still preserved.
    function test_TC13_multiGenerationV2ToV3() public {
        // Queue entry before upgrades
        uint256 queueId = _joinQueue(alice, STANDARD_DEPOSIT, 0);

        // Upgrade v1 -> v2
        StakingQueueV2 v2Impl = new StakingQueueV2();
        vm.prank(owner);
        queue.upgradeToAndCall(address(v2Impl), "");

        // Set v2 new variable
        StakingQueueV2(address(queue)).setNewVariableV2(42);
        assertEq(StakingQueueV2(address(queue)).newVariableV2(), 42, "v2 variable should be set");

        // Upgrade v2 -> v3
        StakingQueueV3 v3Impl = new StakingQueueV3();
        vm.prank(owner);
        queue.upgradeToAndCall(address(v3Impl), "");

        // Original state preserved
        assertEq(queue.owner(), owner, "owner should be preserved across v2->v3");
        StakingQueue.QueueEntry memory entry = queue.getQueueEntry(queueId);
        assertEq(entry.depositor, alice, "queue entry should survive v2->v3");

        // V2 variable preserved
        assertEq(StakingQueueV3(address(queue)).newVariableV2(), 42, "v2 variable should survive v2->v3");

        // V3 new variable accessible
        StakingQueueV3(address(queue)).setAnotherVariableV3(99);
        assertEq(StakingQueueV3(address(queue)).anotherVariableV3(), 99, "v3 variable should be accessible");
    }

    /// @dev L3 step 5: Functionality after upgrade. After v2 upgrade, all functions work.
    function test_TC13_functionalityAfterUpgrade() public {
        // Upgrade to v2
        StakingQueueV2 v2Impl = new StakingQueueV2();
        vm.prank(owner);
        queue.upgradeToAndCall(address(v2Impl), "");

        // joinQueue should work
        uint256 queueId = _joinQueue(alice, STANDARD_DEPOSIT, 0);
        StakingQueue.QueueEntry memory entry = queue.getQueueEntry(queueId);
        assertEq(entry.depositor, alice, "joinQueue should work after upgrade");

        // processQueue should work
        queue.processQueue(0, 1);
        entry = queue.getQueueEntry(queueId);
        assertTrue(entry.processed, "processQueue should work after upgrade");

        // cancelQueue should work (need new entry)
        uint256 cancelId = _joinQueue(bob, STANDARD_DEPOSIT, 0);
        vm.prank(bob);
        queue.cancelQueue(cancelId);
        entry = queue.getQueueEntry(cancelId);
        assertTrue(entry.cancelled, "cancelQueue should work after upgrade");

        // upgradeTier should work after upgrade (queue alice into tier 0, then upgrade to tier 1)
        uint256 upgradeId = _joinQueue(alice, STANDARD_DEPOSIT, 0);
        queue.processQueue(0, 1);
        // Attempt tier upgrade from 0 to 1 -- verifies function is callable post-upgrade
        vm.prank(alice);
        queue.upgradeTier(0, 1, STANDARD_DEPOSIT);

        // processExpiredLockups should work after upgrade
        address[] memory depositors = new address[](1);
        depositors[0] = alice;
        queue.processExpiredLockups(depositors, 1);
    }

    /// @dev L3 step 6: Implementation protection. Call initialize() on v2 implementation directly.
    ///      MUST revert with InvalidInitialization().
    function test_TC13_implementationProtectionV2() public {
        StakingQueueV2 v2Impl = new StakingQueueV2();

        address[4] memory tierVaults = [address(vault0), address(vault1), address(vault2), address(vault3)];

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        v2Impl.initialize(address(riskusd), address(forage), tierVaults, address(mockVaultRegistry), owner);
    }

    /// @dev L3 step 7: Attack 1.2 (Implementation Direct Call).
    ///      Call initialize() on v1 implementation directly -- MUST revert.
    function test_TC13_attack12_implementationDirectCall() public {
        address[4] memory tierVaults = [address(vault0), address(vault1), address(vault2), address(vault3)];

        // v1 implementation has _disableInitializers() in constructor
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(address(riskusd), address(forage), tierVaults, address(mockVaultRegistry), owner);
    }

    /// @dev L3 step 8: Attack 1.3 (Unauthorized Upgrade).
    ///      Non-owner calls upgradeToAndCall() -- MUST revert.
    function test_TC13_attack13_unauthorizedUpgrade() public {
        StakingQueueV2 v2Impl = new StakingQueueV2();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, alice));
        queue.upgradeToAndCall(address(v2Impl), "");
    }

    /// @dev L3 step 9: Attack 1.4 (Upgrade-After-Upgrade).
    ///      After v1->v2, verify upgradeToAndCall() to v3 still works.
    function test_TC13_attack14_upgradeAfterUpgrade() public {
        // Upgrade v1 -> v2
        StakingQueueV2 v2Impl = new StakingQueueV2();
        vm.prank(owner);
        queue.upgradeToAndCall(address(v2Impl), "");
        assertEq(StakingQueueV2(address(queue)).version(), 2, "should be v2");

        // Upgrade v2 -> v3 (upgrade mechanism not broken)
        StakingQueueV3 v3Impl = new StakingQueueV3();
        vm.prank(owner);
        queue.upgradeToAndCall(address(v3Impl), "");
        assertEq(StakingQueueV3(address(queue)).version(), 3, "should be v3 after upgrade-after-upgrade");
    }

    /// @dev L3 step 10: proxiableUUID returns correct EIP-1822 slot.
    function test_TC13_proxiableUUIDReturnsCorrectSlot() public view {
        // proxiableUUID has notDelegated modifier -- call on implementation directly
        bytes32 expected = bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);
        assertEq(implementation.proxiableUUID(), expected, "proxiableUUID should return ERC1967 implementation slot");
        assertEq(implementation.proxiableUUID(), ERC1967_IMPL_SLOT, "proxiableUUID should match constant");
    }
}
