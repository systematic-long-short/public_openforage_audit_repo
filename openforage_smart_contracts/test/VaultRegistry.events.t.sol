// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/VaultRegistryTestBase.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";

// ============================================================
// TC-10: Event Emission Tests
// Requirements: R-07, R-18, R-22, R-27, R-31, R-52, R-55
// ============================================================
contract VaultRegistry_TC10_Events is VaultRegistryTestBase {
    address internal newOwner;

    function setUp() public override {
        super.setUp();
        newOwner = makeAddr("newOwner");
    }

    // ---- VaultAdded event (steps 1-2) ----

    /// @dev TC-10 step 1: VaultAdded emitted on addVault with correct indexed vaultId,
    ///      non-indexed name and abbreviation.
    function test_TC10_addVaultEmitsVaultAdded() public {
        (
            string memory name,
            string memory abbreviation,
            address[4] memory tierVaults,
            address stakingQueue,
            uint256 capacityCap,
            uint256[4] memory lockupDurations,
            uint16[4] memory yieldSplitsBps,
            uint16[4] memory fundingBps
        ) = _createDefaultVaultParams();

        // Expect VaultAdded(1, name, abbreviation) -- vaultId=1 is indexed (topic)
        vm.expectEmit(true, true, true, true);
        emit VaultRegistry.VaultAdded(1, name, abbreviation);

        vm.prank(owner);
        registry.addVault(
            name, abbreviation, tierVaults, stakingQueue, capacityCap, lockupDurations, yieldSplitsBps, fundingBps
        );
    }

    /// @dev TC-10 step 2: Second vault emits VaultAdded with vaultId=2.
    function test_TC10_secondVaultEmitsVaultAddedWithId2() public {
        _addDefaultVault();

        (
            string memory name,,,
            address stakingQueue,
            uint256 capacityCap,
            uint256[4] memory lockupDurations,
            uint16[4] memory yieldSplitsBps,
            uint16[4] memory fundingBps
        ) = _createDefaultVaultParams();

        // OF-003: Use unique tier vault addresses for second vault
        address[4] memory uniqueTiers = [makeAddr("ev_t0"), makeAddr("ev_t1"), makeAddr("ev_t2"), makeAddr("ev_t3")];
        string memory secondAbbr = "MN";

        vm.expectEmit(true, true, true, true);
        emit VaultRegistry.VaultAdded(2, name, secondAbbr);

        vm.prank(owner);
        registry.addVault(
            name, secondAbbr, uniqueTiers, stakingQueue, capacityCap, lockupDurations, yieldSplitsBps, fundingBps
        );
    }

    // ---- VaultPaused event (steps 3-4) ----

    /// @dev TC-10 step 3: VaultPaused emitted on pauseVault with correct indexed vaultId.
    function test_TC10_pauseVaultEmitsVaultPaused() public {
        uint256 vaultId = _addDefaultVault();

        vm.expectEmit(true, true, true, true);
        emit VaultRegistry.VaultPaused(vaultId);

        vm.prank(owner);
        registry.pauseVault(vaultId);
    }

    /// @dev TC-10 step 4: Pausing vault 1 does not emit VaultPaused for vault 2.
    function test_TC10_pauseVault1DoesNotEmitForVault2() public {
        uint256 vault1 = _addDefaultVault();
        uint256 vault2 = _addVaultWithAbbreviation("MN");

        vm.recordLogs();
        vm.prank(owner);
        registry.pauseVault(vault1);

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 vaultPausedSig = keccak256("VaultPaused(uint256)");

        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics[0] == vaultPausedSig) {
                // The indexed vaultId is in topics[1]
                uint256 emittedVaultId = uint256(entries[i].topics[1]);
                assertTrue(
                    emittedVaultId != vault2, "VaultPaused should not be emitted for vault 2 when pausing vault 1"
                );
            }
        }
    }

    // ---- VaultWindingDown event (steps 5-6) ----

    /// @dev TC-10 step 5: VaultWindingDown emitted on startWindDown with indexed vaultId.
    function test_TC10_startWindDownEmitsVaultWindingDown() public {
        uint256 vaultId = _addDefaultVault();

        vm.expectEmit(true, true, true, true);
        emit VaultRegistry.VaultWindingDown(vaultId);

        vm.prank(owner);
        registry.startWindDown(vaultId);
    }

    /// @dev TC-10 step 6: Pause then wind down emits VaultWindingDown.
    function test_TC10_pauseThenWindDownEmitsVaultWindingDown() public {
        uint256 vaultId = _addVaultWithAbbreviation("MN");

        vm.prank(owner);
        registry.pauseVault(vaultId);

        vm.expectEmit(true, true, true, true);
        emit VaultRegistry.VaultWindingDown(vaultId);

        vm.prank(owner);
        registry.startWindDown(vaultId);
    }

    // ---- CapacityCapUpdated event (steps 7-8) ----

    /// @dev TC-10 step 7: CapacityCapUpdated emitted on setCapacityCap with correct
    ///      indexed vaultId, oldCap, and newCap.
    function test_TC10_setCapacityCapEmitsCapacityCapUpdated() public {
        uint256 vaultId = _addDefaultVault();

        uint256 oldCap = 10_000_000e6; // default from _createDefaultVaultParams
        uint256 newCap = 20_000_000e6;

        vm.startPrank(owner);
        vm.expectEmit(true, true, true, true);
        emit VaultRegistry.CapacityCapProposed(vaultId, newCap);
        registry.setCapacityCap(vaultId, newCap);

        vm.warp(block.timestamp + 2 days + 1);
        vm.expectEmit(true, true, true, true);
        emit VaultRegistry.CapacityCapUpdated(vaultId, oldCap, newCap);
        registry.finalizeCapacityCap(vaultId);
        vm.stopPrank();
    }

    /// @dev TC-10 step 8: Second setCapacityCap reflects updated old/new values.
    function test_TC10_secondSetCapacityCapEmitsCorrectOldNew() public {
        uint256 vaultId = _addDefaultVault();

        uint256 firstNewCap = 20_000_000e6;
        vm.startPrank(owner);
        registry.setCapacityCap(vaultId, firstNewCap);
        vm.warp(block.timestamp + 2 days + 1);
        registry.finalizeCapacityCap(vaultId);

        uint256 secondNewCap = 30_000_000e6;

        vm.expectEmit(true, true, true, true);
        emit VaultRegistry.CapacityCapProposed(vaultId, secondNewCap);
        registry.setCapacityCap(vaultId, secondNewCap);

        vm.warp(block.timestamp + 2 days + 1);
        vm.expectEmit(true, true, true, true);
        emit VaultRegistry.CapacityCapUpdated(vaultId, firstNewCap, secondNewCap);
        registry.finalizeCapacityCap(vaultId);
        vm.stopPrank();
    }

    // ---- YieldSplitsUpdated event (step 9) ----

    /// @dev TC-10 step 9: YieldSplitsProposed emitted on setYieldSplits; YieldSplitsUpdated on finalize.
    function test_TC10_setYieldSplitsEmitsYieldSplitsUpdated() public {
        uint256 vaultId = _addDefaultVault();

        uint16[4] memory newYieldBps = [uint16(6000), uint16(5000), uint16(4000), uint16(3000)];
        uint16[4] memory newFundBps = [uint16(4000), uint16(5000), uint16(6000), uint16(7000)];

        vm.startPrank(owner);
        vm.expectEmit(true, true, true, true);
        emit VaultRegistry.YieldSplitsProposed(vaultId);
        registry.setYieldSplits(vaultId, newYieldBps, newFundBps);

        vm.warp(block.timestamp + 2 days + 1);
        vm.expectEmit(true, true, true, true);
        emit VaultRegistry.YieldSplitsUpdated(vaultId);
        registry.finalizeYieldSplits(vaultId);
        vm.stopPrank();
    }

    // ---- OwnershipTransferStarted / OwnershipTransferred events (steps 10-11) ----

    /// @dev TC-10 step 10: OwnershipTransferStarted emitted on transferOwnership.
    function test_TC10_transferOwnershipEmitsOwnershipTransferStarted() public {
        vm.expectEmit(true, true, false, true);
        emit Ownable2StepUpgradeable.OwnershipTransferStarted(owner, newOwner);

        vm.prank(owner);
        registry.transferOwnership(newOwner);
    }

    /// @dev TC-10 step 11: OwnershipTransferred emitted on acceptOwnership.
    function test_TC10_acceptOwnershipEmitsOwnershipTransferred() public {
        vm.prank(owner);
        registry.transferOwnership(newOwner);

        vm.expectEmit(true, true, false, true);
        emit OwnableUpgradeable.OwnershipTransferred(owner, newOwner);

        vm.prank(newOwner);
        registry.acceptOwnership();
    }
}
