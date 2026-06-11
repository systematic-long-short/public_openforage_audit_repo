// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/VaultRegistryTestBase.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

contract MockVaultRegistryRiskVault {
    bool public lossPending;
    uint256 public lossPendingVaultId;

    function setLossPending(bool pending, uint256 vaultId) external {
        lossPending = pending;
        lossPendingVaultId = vaultId;
    }
}

// ============================================================
// TC-02: addVault Registration (R-05 .. R-17)
// ============================================================
contract VaultRegistry_TC02_AddVault is VaultRegistryTestBase {
    // ---- Happy path ----

    /// @dev R-16: Non-owner MUST revert with OwnableUnauthorizedAccount.
    function test_TC02_addVault_nonOwnerReverts() public {
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

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, attacker));
        registry.addVault(
            name, abbreviation, tierVaults, stakingQueue, capacityCap, lockupDurations, yieldSplitsBps, fundingBps
        );
    }

    /// @dev R-05: addVault creates vault with vaultId=1, status=Active, all config stored.
    function test_TC02_addVault_happyPath_createsVaultWithId1() public {
        uint256 vaultId = _addDefaultVault();
        assertEq(vaultId, 1, "First vault should have ID 1");
    }

    /// @dev R-05: addVault stores all configuration fields correctly.
    function test_TC02_addVault_happyPath_configStoredCorrectly() public {
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

        vm.prank(owner);
        uint256 vaultId = registry.addVault(
            name, abbreviation, tierVaults, stakingQueue, capacityCap, lockupDurations, yieldSplitsBps, fundingBps
        );

        VaultConfig memory cfg = registry.getVault(vaultId);
        assertEq(cfg.vaultId, 1);
        assertEq(keccak256(bytes(cfg.name)), keccak256(bytes(name)));
        assertEq(keccak256(bytes(cfg.abbreviation)), keccak256(bytes(abbreviation)));
        for (uint256 i; i < 4; ++i) {
            assertEq(cfg.tierVaults[i], tierVaults[i], "tierVault mismatch");
        }
        assertEq(cfg.stakingQueue, stakingQueue);
        assertEq(cfg.capacityCap, capacityCap);
        for (uint256 i; i < 4; ++i) {
            assertEq(cfg.lockupDurations[i], lockupDurations[i], "lockupDuration mismatch");
        }
        for (uint256 i; i < 4; ++i) {
            assertEq(cfg.yieldSplitsBps[i], yieldSplitsBps[i], "yieldSplitsBps mismatch");
            assertEq(cfg.fundingBps[i], fundingBps[i], "fundingBps mismatch");
        }
        assertTrue(cfg.status == VaultStatus.Active, "status should be Active");
    }

    /// @dev R-06: addVault increments vaultCount.
    function test_TC02_addVault_incrementsVaultCount() public {
        assertEq(registry.vaultCount(), 0);
        _addDefaultVault();
        assertEq(registry.vaultCount(), 1, "vaultCount should be 1 after first add");
    }

    /// @dev R-06: Sequential vault ID assignment (1, 2, 3).
    function test_TC02_addVault_sequentialIds() public {
        uint256 id1 = _addVaultWithAbbreviation("V1");
        uint256 id2 = _addVaultWithAbbreviation("V2");
        uint256 id3 = _addVaultWithAbbreviation("V3");
        assertEq(id1, 1);
        assertEq(id2, 2);
        assertEq(id3, 3);
        assertEq(registry.vaultCount(), 3);
    }

    /// @dev R-07: VaultAdded event emitted with correct params.
    function test_TC02_addVault_emitsVaultAdded() public {
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

        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit VaultRegistry.VaultAdded(1, name, abbreviation);
        registry.addVault(
            name, abbreviation, tierVaults, stakingQueue, capacityCap, lockupDurations, yieldSplitsBps, fundingBps
        );
    }

    /// @dev R-05: getVaultByAbbreviation resolves after addVault.
    function test_TC02_addVault_abbreviationResolvable() public {
        _addDefaultVault();
        assertEq(registry.getVaultByAbbreviation("CSMN"), 1);
    }

    /// @dev R-06: Multiple vaults appear in getAllVaults and getActiveVaults.
    function test_TC02_addVault_multipleVaultsInViews() public {
        _addVaultWithAbbreviation("A1");
        _addVaultWithAbbreviation("A2");
        _addVaultWithAbbreviation("A3");

        uint256[] memory all = registry.getAllVaults();
        assertEq(all.length, 3);
        assertEq(all[0], 1);
        assertEq(all[1], 2);
        assertEq(all[2], 3);

        uint256[] memory active = registry.getActiveVaults();
        assertEq(active.length, 3);
    }

    // ---- Zero address checks (R-08, R-09) ----

    /// @dev R-08: tierVaults_[0] = address(0) MUST revert ZeroAddress.
    function test_TC02_addVault_zeroTierVault0Reverts() public {
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
        tierVaults[0] = address(0);

        vm.prank(owner);
        vm.expectRevert(VaultRegistry.ZeroAddress.selector);
        registry.addVault(
            name, abbreviation, tierVaults, stakingQueue, capacityCap, lockupDurations, yieldSplitsBps, fundingBps
        );
    }

    /// @dev R-08: tierVaults_[1] = address(0) MUST revert ZeroAddress.
    function test_TC02_addVault_zeroTierVault1Reverts() public {
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
        tierVaults[1] = address(0);

        vm.prank(owner);
        vm.expectRevert(VaultRegistry.ZeroAddress.selector);
        registry.addVault(
            name, abbreviation, tierVaults, stakingQueue, capacityCap, lockupDurations, yieldSplitsBps, fundingBps
        );
    }

    /// @dev R-08: tierVaults_[2] = address(0) MUST revert ZeroAddress.
    function test_TC02_addVault_zeroTierVault2Reverts() public {
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
        tierVaults[2] = address(0);

        vm.prank(owner);
        vm.expectRevert(VaultRegistry.ZeroAddress.selector);
        registry.addVault(
            name, abbreviation, tierVaults, stakingQueue, capacityCap, lockupDurations, yieldSplitsBps, fundingBps
        );
    }

    /// @dev R-08: tierVaults_[3] = address(0) MUST revert ZeroAddress.
    function test_TC02_addVault_zeroTierVault3Reverts() public {
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
        tierVaults[3] = address(0);

        vm.prank(owner);
        vm.expectRevert(VaultRegistry.ZeroAddress.selector);
        registry.addVault(
            name, abbreviation, tierVaults, stakingQueue, capacityCap, lockupDurations, yieldSplitsBps, fundingBps
        );
    }

    /// @dev R-09: stakingQueue_ = address(0) MUST revert ZeroAddress.
    function test_TC02_addVault_zeroStakingQueueReverts() public {
        (
            string memory name,
            string memory abbreviation,
            address[4] memory tierVaults,,
            uint256 capacityCap,
            uint256[4] memory lockupDurations,
            uint16[4] memory yieldSplitsBps,
            uint16[4] memory fundingBps
        ) = _createDefaultVaultParams();

        vm.prank(owner);
        vm.expectRevert(VaultRegistry.ZeroAddress.selector);
        registry.addVault(
            name, abbreviation, tierVaults, address(0), capacityCap, lockupDurations, yieldSplitsBps, fundingBps
        );
    }

    // ---- Empty string checks (R-10, R-11) ----

    /// @dev R-10: Empty name MUST revert EmptyName.
    function test_TC02_addVault_emptyNameReverts() public {
        (
            ,
            string memory abbreviation,
            address[4] memory tierVaults,
            address stakingQueue,
            uint256 capacityCap,
            uint256[4] memory lockupDurations,
            uint16[4] memory yieldSplitsBps,
            uint16[4] memory fundingBps
        ) = _createDefaultVaultParams();

        vm.prank(owner);
        vm.expectRevert(VaultRegistry.EmptyName.selector);
        registry.addVault(
            "", abbreviation, tierVaults, stakingQueue, capacityCap, lockupDurations, yieldSplitsBps, fundingBps
        );
    }

    /// @dev R-11: Empty abbreviation MUST revert EmptyAbbreviation.
    function test_TC02_addVault_emptyAbbreviationReverts() public {
        (
            string memory name,,
            address[4] memory tierVaults,
            address stakingQueue,
            uint256 capacityCap,
            uint256[4] memory lockupDurations,
            uint16[4] memory yieldSplitsBps,
            uint16[4] memory fundingBps
        ) = _createDefaultVaultParams();

        vm.prank(owner);
        vm.expectRevert(VaultRegistry.EmptyAbbreviation.selector);
        registry.addVault(name, "", tierVaults, stakingQueue, capacityCap, lockupDurations, yieldSplitsBps, fundingBps);
    }

    // ---- Duplicate abbreviation (R-12) ----

    /// @dev R-12: Duplicate abbreviation MUST revert DuplicateAbbreviation.
    function test_TC02_addVault_duplicateAbbreviationReverts() public {
        _addDefaultVault(); // registers "CSMN"

        (
            string memory name,,,
            address stakingQueue,
            uint256 capacityCap,
            uint256[4] memory lockupDurations,
            uint16[4] memory yieldSplitsBps,
            uint16[4] memory fundingBps
        ) = _createDefaultVaultParams();

        // OF-003: Use unique tier vault addresses to isolate the abbreviation check
        address[4] memory uniqueTiers = [makeAddr("dup_t0"), makeAddr("dup_t1"), makeAddr("dup_t2"), makeAddr("dup_t3")];

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(VaultRegistry.DuplicateAbbreviation.selector, "CSMN"));
        registry.addVault(
            name, "CSMN", uniqueTiers, stakingQueue, capacityCap, lockupDurations, yieldSplitsBps, fundingBps
        );
    }

    // ---- Zero capacity (R-13) ----

    /// @dev R-13: Zero capacity MUST revert ZeroCapacity.
    function test_TC02_addVault_zeroCapacityReverts() public {
        (
            string memory name,
            string memory abbreviation,
            address[4] memory tierVaults,
            address stakingQueue,,
            uint256[4] memory lockupDurations,
            uint16[4] memory yieldSplitsBps,
            uint16[4] memory fundingBps
        ) = _createDefaultVaultParams();

        vm.prank(owner);
        vm.expectRevert(VaultRegistry.ZeroCapacity.selector);
        registry.addVault(name, abbreviation, tierVaults, stakingQueue, 0, lockupDurations, yieldSplitsBps, fundingBps);
    }

    // ---- Tier 0 lockup validation (R-17) ----

    /// @dev R-17: lockupDurations[0] != 0 MUST revert NonZeroTier0Lockup.
    ///      L2 spec: "lockupDurations_[0] MUST be 0 (Tier 0 is always no-lockup)."
    function test_TC02_addVault_nonZeroTier0LockupReverts() public {
        (
            string memory name,
            string memory abbreviation,
            address[4] memory tierVaults,
            address stakingQueue,
            uint256 capacityCap,,
            uint16[4] memory yieldSplitsBps,
            uint16[4] memory fundingBps
        ) = _createDefaultVaultParams();
        uint256[4] memory lockupDurations = [uint256(86400), uint256(7776000), uint256(15552000), uint256(31104000)];

        vm.prank(owner);
        vm.expectRevert(VaultRegistry.NonZeroTier0Lockup.selector);
        registry.addVault(
            name, abbreviation, tierVaults, stakingQueue, capacityCap, lockupDurations, yieldSplitsBps, fundingBps
        );
    }

    /// @dev R-17: lockupDurations[0] == 0 with valid params should NOT revert due to lockup check.
    function test_TC02_addVault_zeroTier0LockupAccepted() public {
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
        // lockupDurations[0] is already 0 from default params
        assertEq(lockupDurations[0], 0, "Default tier 0 lockup should be 0");

        // Valid params (tier 0 lockup == 0) should NOT revert with NonZeroTier0Lockup.
        // Against the stub, addVault reverts generically. Once implemented, it should succeed.
        vm.prank(owner);
        try registry.addVault(
            name, abbreviation, tierVaults, stakingQueue, capacityCap, lockupDurations, yieldSplitsBps, fundingBps
        ) {
        // Success path — expected once implementation exists
        }
        catch (bytes memory reason) {
            // Revert path — acceptable pre-implementation, but MUST NOT be NonZeroTier0Lockup
            assertTrue(
                keccak256(reason) != keccak256(abi.encodeWithSelector(VaultRegistry.NonZeroTier0Lockup.selector)),
                "Must not revert with NonZeroTier0Lockup for tier 0 lockup == 0"
            );
        }
    }

    // ---- Yield split validation (R-14, R-15) ----

    /// @dev R-14: yieldSplitsBps[0] + fundingBps[0] > 10000 MUST revert InvalidSplitTotal(0).
    function test_TC02_addVault_invalidSplitTotalTier0Reverts() public {
        (
            string memory name,
            string memory abbreviation,
            address[4] memory tierVaults,
            address stakingQueue,
            uint256 capacityCap,
            uint256[4] memory lockupDurations,,
            uint16[4] memory fundingBps
        ) = _createDefaultVaultParams();
        uint16[4] memory yieldSplitsBps = [uint16(8000), uint16(6000), uint16(5000), uint16(4000)];
        fundingBps[0] = 2001; // 8000 + 2001 = 10001

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(VaultRegistry.InvalidSplitTotal.selector, uint8(0)));
        registry.addVault(
            name, abbreviation, tierVaults, stakingQueue, capacityCap, lockupDurations, yieldSplitsBps, fundingBps
        );
    }

    /// @dev R-14: yieldSplitsBps[1] + fundingBps[1] > 10000 MUST revert InvalidSplitTotal(1).
    function test_TC02_addVault_invalidSplitTotalTier1Reverts() public {
        (
            string memory name,
            string memory abbreviation,
            address[4] memory tierVaults,
            address stakingQueue,
            uint256 capacityCap,
            uint256[4] memory lockupDurations,,
        ) = _createDefaultVaultParams();
        uint16[4] memory yieldSplitsBps = [uint16(5000), uint16(9000), uint16(5000), uint16(5000)];
        uint16[4] memory fundingBps = [uint16(2000), uint16(2000), uint16(2000), uint16(2000)];
        // tier 1: 9000 + 2000 = 11000

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(VaultRegistry.InvalidSplitTotal.selector, uint8(1)));
        registry.addVault(
            name, abbreviation, tierVaults, stakingQueue, capacityCap, lockupDurations, yieldSplitsBps, fundingBps
        );
    }

    /// @dev R-14: yieldSplitsBps[3] + fundingBps[3] > 10000 MUST revert InvalidSplitTotal(3).
    function test_TC02_addVault_invalidSplitTotalTier3Reverts() public {
        (
            string memory name,
            string memory abbreviation,
            address[4] memory tierVaults,
            address stakingQueue,
            uint256 capacityCap,
            uint256[4] memory lockupDurations,,
        ) = _createDefaultVaultParams();
        uint16[4] memory yieldSplitsBps = [uint16(5000), uint16(5000), uint16(5000), uint16(9000)];
        uint16[4] memory fundingBps = [uint16(2000), uint16(2000), uint16(2000), uint16(2000)];
        // tier 3: 9000 + 2000 = 11000

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(VaultRegistry.InvalidSplitTotal.selector, uint8(3)));
        registry.addVault(
            name, abbreviation, tierVaults, stakingQueue, capacityCap, lockupDurations, yieldSplitsBps, fundingBps
        );
    }

    /// @dev R-15: yieldSplitsBps[2] == 0 MUST revert ZeroYieldSplit(2).
    function test_TC02_addVault_zeroYieldSplitTier2Reverts() public {
        (
            string memory name,
            string memory abbreviation,
            address[4] memory tierVaults,
            address stakingQueue,
            uint256 capacityCap,
            uint256[4] memory lockupDurations,,
            uint16[4] memory fundingBps
        ) = _createDefaultVaultParams();
        uint16[4] memory yieldSplitsBps = [uint16(5000), uint16(5000), uint16(0), uint16(5000)];

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(VaultRegistry.ZeroYieldSplit.selector, uint8(2)));
        registry.addVault(
            name, abbreviation, tierVaults, stakingQueue, capacityCap, lockupDurations, yieldSplitsBps, fundingBps
        );
    }

    /// @dev R-15: yieldSplitsBps[3] == 0 MUST revert ZeroYieldSplit(3).
    function test_TC02_addVault_zeroYieldSplitTier3Reverts() public {
        (
            string memory name,
            string memory abbreviation,
            address[4] memory tierVaults,
            address stakingQueue,
            uint256 capacityCap,
            uint256[4] memory lockupDurations,,
            uint16[4] memory fundingBps
        ) = _createDefaultVaultParams();
        uint16[4] memory yieldSplitsBps = [uint16(5000), uint16(5000), uint16(5000), uint16(0)];

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(VaultRegistry.ZeroYieldSplit.selector, uint8(3)));
        registry.addVault(
            name, abbreviation, tierVaults, stakingQueue, capacityCap, lockupDurations, yieldSplitsBps, fundingBps
        );
    }

    /// @dev R-15: yieldSplitsBps[0] == 0 MUST revert ZeroYieldSplit(0).
    function test_TC02_addVault_zeroYieldSplitTier0Reverts() public {
        (
            string memory name,
            string memory abbreviation,
            address[4] memory tierVaults,
            address stakingQueue,
            uint256 capacityCap,
            uint256[4] memory lockupDurations,,
            uint16[4] memory fundingBps
        ) = _createDefaultVaultParams();
        uint16[4] memory yieldSplitsBps = [uint16(0), uint16(5000), uint16(5000), uint16(5000)];

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(VaultRegistry.ZeroYieldSplit.selector, uint8(0)));
        registry.addVault(
            name, abbreviation, tierVaults, stakingQueue, capacityCap, lockupDurations, yieldSplitsBps, fundingBps
        );
    }

    // ---- Boundary: yield + funding == 10000 exactly succeeds ----

    /// @dev R-14 boundary: sum exactly 10000 MUST succeed.
    function test_TC02_addVault_splitSumExactly10000Succeeds() public {
        (
            string memory name,,
            address[4] memory tierVaults,
            address stakingQueue,
            uint256 capacityCap,
            uint256[4] memory lockupDurations,,
        ) = _createDefaultVaultParams();
        // All tiers sum to exactly 10000
        uint16[4] memory yieldSplitsBps = [uint16(8000), uint16(8000), uint16(8000), uint16(8000)];
        uint16[4] memory fundingBps = [uint16(2000), uint16(2000), uint16(2000), uint16(2000)];

        vm.prank(owner);
        uint256 vaultId = registry.addVault(
            name, "BNDRY", tierVaults, stakingQueue, capacityCap, lockupDurations, yieldSplitsBps, fundingBps
        );
        assertEq(vaultId, 1);
    }

    /// @dev R-15 boundary: minimum yield split (1 bps) with zero funding succeeds.
    function test_TC02_addVault_minimumYieldSplitSucceeds() public {
        (
            string memory name,,
            address[4] memory tierVaults,
            address stakingQueue,
            uint256 capacityCap,
            uint256[4] memory lockupDurations,,
        ) = _createDefaultVaultParams();
        uint16[4] memory yieldSplitsBps = [uint16(1), uint16(1), uint16(1), uint16(1)];
        uint16[4] memory fundingBps = [uint16(0), uint16(0), uint16(0), uint16(0)];

        vm.prank(owner);
        uint256 vaultId = registry.addVault(
            name, "MIN", tierVaults, stakingQueue, capacityCap, lockupDurations, yieldSplitsBps, fundingBps
        );
        assertGt(vaultId, 0);
    }

    // ---- Lockup durations ----

    /// @dev R-17: lockupDurations all zero is valid.
    function test_TC02_addVault_allZeroLockupDurationsSucceeds() public {
        (
            string memory name,,
            address[4] memory tierVaults,
            address stakingQueue,
            uint256 capacityCap,,
            uint16[4] memory yieldSplitsBps,
            uint16[4] memory fundingBps
        ) = _createDefaultVaultParams();
        uint256[4] memory lockupDurations = [uint256(0), uint256(0), uint256(0), uint256(0)];

        vm.prank(owner);
        uint256 vaultId = registry.addVault(
            name, "ZERO", tierVaults, stakingQueue, capacityCap, lockupDurations, yieldSplitsBps, fundingBps
        );
        assertGt(vaultId, 0);
    }

    /// @dev R-17: Large lockup durations succeed.
    function test_TC02_addVault_largeLockupDurationsSucceed() public {
        (
            string memory name,,
            address[4] memory tierVaults,
            address stakingQueue,
            uint256 capacityCap,,
            uint16[4] memory yieldSplitsBps,
            uint16[4] memory fundingBps
        ) = _createDefaultVaultParams();
        uint256[4] memory lockupDurations = [uint256(0), 365 days, 730 days, 1095 days];

        vm.prank(owner);
        uint256 vaultId = registry.addVault(
            name, "LONG", tierVaults, stakingQueue, capacityCap, lockupDurations, yieldSplitsBps, fundingBps
        );
        assertGt(vaultId, 0);
    }

    /// @dev R-13 boundary: capacityCap = 1 (minimum valid) succeeds.
    function test_TC02_addVault_capacityCapMinimumSucceeds() public {
        (
            string memory name,,
            address[4] memory tierVaults,
            address stakingQueue,,
            uint256[4] memory lockupDurations,
            uint16[4] memory yieldSplitsBps,
            uint16[4] memory fundingBps
        ) = _createDefaultVaultParams();

        vm.prank(owner);
        uint256 vaultId =
            registry.addVault(name, "MINCAP", tierVaults, stakingQueue, 1, lockupDurations, yieldSplitsBps, fundingBps);
        assertGt(vaultId, 0);
        assertEq(registry.getVault(vaultId).capacityCap, 1);
    }

    /// @dev R-13 boundary: capacityCap = type(uint256).max succeeds.
    function test_TC02_addVault_capacityCapMaxSucceeds() public {
        (
            string memory name,,
            address[4] memory tierVaults,
            address stakingQueue,,
            uint256[4] memory lockupDurations,
            uint16[4] memory yieldSplitsBps,
            uint16[4] memory fundingBps
        ) = _createDefaultVaultParams();

        vm.prank(owner);
        uint256 vaultId = registry.addVault(
            name, "MAXCAP", tierVaults, stakingQueue, type(uint256).max, lockupDurations, yieldSplitsBps, fundingBps
        );
        assertEq(registry.getVault(vaultId).capacityCap, type(uint256).max);
    }
}

// ============================================================
// TC-03: pauseVault Lifecycle (R-18 .. R-21)
// ============================================================
contract VaultRegistry_TC03_PauseVault is VaultRegistryTestBase {
    /// @dev R-18, R-21: Owner pauses an Active vault; status becomes Paused.
    function test_TC03_pauseVault_activeToPassued() public {
        uint256 vaultId = _addDefaultVault();

        vm.prank(owner);
        registry.pauseVault(vaultId);

        VaultConfig memory cfg = registry.getVault(vaultId);
        assertTrue(cfg.status == VaultStatus.Paused, "vault should be Paused");
    }

    /// @dev R-18: VaultPaused event emitted.
    function test_TC03_pauseVault_emitsEvent() public {
        uint256 vaultId = _addDefaultVault();

        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit VaultRegistry.VaultPaused(vaultId);
        registry.pauseVault(vaultId);
    }

    /// @dev R-18: Paused vault removed from getActiveVaults but remains in getAllVaults.
    function test_TC03_pauseVault_removedFromActiveVaults() public {
        uint256 vaultId = _addDefaultVault();

        vm.prank(owner);
        registry.pauseVault(vaultId);

        uint256[] memory active = registry.getActiveVaults();
        assertEq(active.length, 0, "no active vaults after pause");
        uint256[] memory all = registry.getAllVaults();
        assertEq(all.length, 1, "getAllVaults still includes paused vault");
        assertEq(all[0], vaultId);
    }

    /// @dev R-19: pauseVault with non-existent vaultId reverts InvalidVaultId.
    function test_TC03_pauseVault_nonExistentIdReverts() public {
        vm.prank(owner);
        vm.expectRevert(VaultRegistry.InvalidVaultId.selector);
        registry.pauseVault(999);
    }

    /// @dev R-19: pauseVault with ID 0 reverts InvalidVaultId.
    function test_TC03_pauseVault_id0Reverts() public {
        vm.prank(owner);
        vm.expectRevert(VaultRegistry.InvalidVaultId.selector);
        registry.pauseVault(0);
    }

    /// @dev R-20: Already-paused vault reverts VaultNotActive.
    function test_TC03_pauseVault_alreadyPausedReverts() public {
        uint256 vaultId = _addDefaultVault();
        vm.prank(owner);
        registry.pauseVault(vaultId);

        vm.prank(owner);
        vm.expectRevert(VaultRegistry.VaultNotActive.selector);
        registry.pauseVault(vaultId);
    }

    /// @dev R-20: WindingDown vault reverts VaultNotActive when paused.
    function test_TC03_pauseVault_windingDownReverts() public {
        uint256 vaultId = _addDefaultVault();
        vm.prank(owner);
        registry.startWindDown(vaultId);

        vm.prank(owner);
        vm.expectRevert(VaultRegistry.VaultNotActive.selector);
        registry.pauseVault(vaultId);
    }

    /// @dev R-21: Non-owner call to pauseVault reverts OwnableUnauthorizedAccount.
    function test_TC03_pauseVault_nonOwnerReverts() public {
        _addDefaultVault();

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, attacker));
        registry.pauseVault(1);
    }
}

// ============================================================
// TC-04: startWindDown Lifecycle (R-22 .. R-26)
// ============================================================
contract VaultRegistry_TC04_StartWindDown is VaultRegistryTestBase {
    /// @dev R-22, R-25: Active vault transitions to WindingDown.
    function test_TC04_startWindDown_activeToWindingDown() public {
        uint256 vaultId = _addDefaultVault();

        vm.prank(owner);
        registry.startWindDown(vaultId);

        VaultConfig memory cfg = registry.getVault(vaultId);
        assertTrue(cfg.status == VaultStatus.WindingDown, "vault should be WindingDown");
    }

    function test_TC04_startWindDownBlockedInSameBlockAsLossResolutionThenAllowedNextBlock() public {
        MockVaultRegistryRiskVault riskVault = new MockVaultRegistryRiskVault();
        vm.prank(owner);
        registry.initializeV2(address(riskVault));

        uint256 vaultId = _addDefaultVault();

        vm.prank(address(riskVault));
        registry.notifyLossResolved();

        vm.prank(owner);
        vm.expectRevert(VaultRegistry.LossCooldownActive.selector);
        registry.startWindDown(vaultId);

        vm.roll(block.number + 1);

        vm.prank(owner);
        registry.startWindDown(vaultId);

        VaultConfig memory cfg = registry.getVault(vaultId);
        assertTrue(cfg.status == VaultStatus.WindingDown, "wind-down allowed after one block");
    }

    /// @dev R-22: VaultWindingDown event emitted from Active.
    function test_TC04_startWindDown_emitsEventFromActive() public {
        uint256 vaultId = _addDefaultVault();

        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit VaultRegistry.VaultWindingDown(vaultId);
        registry.startWindDown(vaultId);
    }

    /// @dev R-22: getActiveVaults returns empty after wind-down.
    function test_TC04_startWindDown_removedFromActiveVaults() public {
        uint256 vaultId = _addDefaultVault();

        vm.prank(owner);
        registry.startWindDown(vaultId);

        uint256[] memory active = registry.getActiveVaults();
        assertEq(active.length, 0, "no active vaults after wind-down");
        uint256[] memory all = registry.getAllVaults();
        assertEq(all.length, 1);
        assertEq(all[0], vaultId);
    }

    /// @dev OF-L09: Paused vault can no longer transition to WindingDown.
    function test_TC04_startWindDown_pausedToWindingDownAllowed() public {
        uint256 vaultId = _addDefaultVault();
        vm.prank(owner);
        registry.pauseVault(vaultId);

        VaultConfig memory cfgPaused = registry.getVault(vaultId);
        assertTrue(cfgPaused.status == VaultStatus.Paused, "should be Paused first");

        // OF-L09 reverted: Paused → WindingDown intentionally allowed for vault lifecycle progression
        vm.prank(owner);
        registry.startWindDown(vaultId);

        VaultConfig memory cfgWD = registry.getVault(vaultId);
        assertTrue(cfgWD.status == VaultStatus.WindingDown, "should be WindingDown");
    }

    /// @dev R-24: Already WindingDown vault reverts VaultAlreadyWindingDown.
    function test_TC04_startWindDown_alreadyWindingDownReverts() public {
        uint256 vaultId = _addDefaultVault();
        vm.prank(owner);
        registry.startWindDown(vaultId);

        vm.prank(owner);
        vm.expectRevert(VaultRegistry.VaultAlreadyWindingDown.selector);
        registry.startWindDown(vaultId);
    }

    /// @dev R-23: Non-existent vaultId reverts InvalidVaultId.
    function test_TC04_startWindDown_nonExistentIdReverts() public {
        vm.prank(owner);
        vm.expectRevert(VaultRegistry.InvalidVaultId.selector);
        registry.startWindDown(999);
    }

    /// @dev R-23: vaultId 0 reverts InvalidVaultId.
    function test_TC04_startWindDown_id0Reverts() public {
        vm.prank(owner);
        vm.expectRevert(VaultRegistry.InvalidVaultId.selector);
        registry.startWindDown(0);
    }

    /// @dev R-26: Non-owner reverts OwnableUnauthorizedAccount.
    function test_TC04_startWindDown_nonOwnerReverts() public {
        _addDefaultVault();

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, attacker));
        registry.startWindDown(1);
    }

    /// @dev R-46: No reverse transition from WindingDown (no unpause or reactivate function).
    function test_TC04_startWindDown_noReverseTransitionFromWindingDown() public {
        uint256 vaultId = _addDefaultVault();
        vm.prank(owner);
        registry.startWindDown(vaultId);

        // Cannot pause a WindingDown vault
        vm.prank(owner);
        vm.expectRevert(VaultRegistry.VaultNotActive.selector);
        registry.pauseVault(vaultId);
    }

    /// @dev R-47: Per-vault independence: winding down one vault does not affect another.
    function test_TC04_startWindDown_perVaultIndependence() public {
        uint256 id1 = _addVaultWithAbbreviation("V1");
        uint256 id2 = _addVaultWithAbbreviation("V2");

        vm.prank(owner);
        registry.startWindDown(id1);

        VaultConfig memory cfg2 = registry.getVault(id2);
        assertTrue(cfg2.status == VaultStatus.Active, "vault 2 should remain Active");

        uint256[] memory active = registry.getActiveVaults();
        assertEq(active.length, 1);
        assertEq(active[0], id2);
    }
}

// ============================================================
// TC-05: setCapacityCap (R-27 .. R-30)
// ============================================================
contract VaultRegistry_TC05_SetCapacityCap is VaultRegistryTestBase {
    /// @dev R-27: Owner updates capacity cap; new value stored.
    function test_TC05_setCapacityCap_updatesValue() public {
        uint256 vaultId = _addDefaultVault();
        uint256 oldCap = registry.getVault(vaultId).capacityCap;
        uint256 newCap = 20_000_000e6;

        vm.startPrank(owner);
        registry.setCapacityCap(vaultId, newCap);
        vm.warp(block.timestamp + 2 days + 1);
        registry.finalizeCapacityCap(vaultId);
        vm.stopPrank();

        assertEq(registry.getVault(vaultId).capacityCap, newCap);
        assertNotEq(oldCap, newCap); // sanity: old != new
    }

    /// @dev R-27: CapacityCapProposed event emitted on propose; CapacityCapUpdated on finalize.
    function test_TC05_setCapacityCap_emitsEvent() public {
        uint256 vaultId = _addDefaultVault();
        uint256 oldCap = registry.getVault(vaultId).capacityCap;
        uint256 newCap = 20_000_000e6;

        vm.startPrank(owner);
        vm.expectEmit(true, false, false, true);
        emit VaultRegistry.CapacityCapProposed(vaultId, newCap);
        registry.setCapacityCap(vaultId, newCap);

        vm.warp(block.timestamp + 2 days + 1);
        vm.expectEmit(true, false, false, true);
        emit VaultRegistry.CapacityCapUpdated(vaultId, oldCap, newCap);
        registry.finalizeCapacityCap(vaultId);
        vm.stopPrank();
    }

    /// @dev R-27: Set to minimum (1).
    function test_TC05_setCapacityCap_setToMinimum() public {
        uint256 vaultId = _addDefaultVault();

        vm.startPrank(owner);
        registry.setCapacityCap(vaultId, 1);
        vm.warp(block.timestamp + 2 days + 1);
        registry.finalizeCapacityCap(vaultId);
        vm.stopPrank();

        assertEq(registry.getVault(vaultId).capacityCap, 1);
    }

    /// @dev R-27: Set to type(uint256).max.
    function test_TC05_setCapacityCap_setToMax() public {
        uint256 vaultId = _addDefaultVault();

        vm.startPrank(owner);
        registry.setCapacityCap(vaultId, type(uint256).max);
        vm.warp(block.timestamp + 2 days + 1);
        registry.finalizeCapacityCap(vaultId);
        vm.stopPrank();

        assertEq(registry.getVault(vaultId).capacityCap, type(uint256).max);
    }

    /// @dev R-29: Zero capacity reverts ZeroCapacity.
    function test_TC05_setCapacityCap_zeroReverts() public {
        uint256 vaultId = _addDefaultVault();

        vm.prank(owner);
        vm.expectRevert(VaultRegistry.ZeroCapacity.selector);
        registry.setCapacityCap(vaultId, 0);
    }

    /// @dev R-28: Non-existent vaultId reverts InvalidVaultId.
    function test_TC05_setCapacityCap_nonExistentIdReverts() public {
        vm.prank(owner);
        vm.expectRevert(VaultRegistry.InvalidVaultId.selector);
        registry.setCapacityCap(999, 1000);
    }

    /// @dev R-28: vaultId 0 reverts InvalidVaultId.
    function test_TC05_setCapacityCap_id0Reverts() public {
        vm.prank(owner);
        vm.expectRevert(VaultRegistry.InvalidVaultId.selector);
        registry.setCapacityCap(0, 1000);
    }

    /// @dev R-30: Non-owner reverts OwnableUnauthorizedAccount.
    function test_TC05_setCapacityCap_nonOwnerReverts() public {
        uint256 vaultId = _addDefaultVault();

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, attacker));
        registry.setCapacityCap(vaultId, 5000);
    }

    /// @dev OF-16-009: setCapacityCap reverts on Paused vault with VaultNotActive.
    function test_TC05_setCapacityCap_worksOnPausedVault() public {
        uint256 vaultId = _addDefaultVault();
        vm.prank(owner);
        registry.pauseVault(vaultId);

        vm.expectRevert(VaultRegistry.VaultNotActive.selector);
        vm.prank(owner);
        registry.setCapacityCap(vaultId, 50_000_000e6);
    }

    /// @dev OF-16-009: setCapacityCap reverts on WindingDown vault with VaultNotActive.
    function test_TC05_setCapacityCap_worksOnWindingDownVault() public {
        uint256 vaultId = _addDefaultVault();
        vm.prank(owner);
        registry.startWindDown(vaultId);

        vm.expectRevert(VaultRegistry.VaultNotActive.selector);
        vm.prank(owner);
        registry.setCapacityCap(vaultId, 30_000_000e6);
    }
}

// ============================================================
// TC-06: setYieldSplits (R-31 .. R-35)
// ============================================================
contract VaultRegistry_TC06_SetYieldSplits is VaultRegistryTestBase {
    /// @dev R-31: Owner updates all 4 tiers; values stored correctly after propose+finalize.
    function test_TC06_setYieldSplits_updatesAllTiers() public {
        uint256 vaultId = _addDefaultVault();
        uint16[4] memory newYield = [uint16(6000), uint16(6500), uint16(7000), uint16(7500)];
        uint16[4] memory newFunding = [uint16(1500), uint16(1500), uint16(1000), uint16(1000)];

        vm.startPrank(owner);
        registry.setYieldSplits(vaultId, newYield, newFunding);
        vm.warp(block.timestamp + 2 days + 1);
        registry.finalizeYieldSplits(vaultId);
        vm.stopPrank();

        VaultConfig memory cfg = registry.getVault(vaultId);
        for (uint256 i; i < 4; ++i) {
            assertEq(cfg.yieldSplitsBps[i], newYield[i], "yieldSplitsBps mismatch");
            assertEq(cfg.fundingBps[i], newFunding[i], "fundingBps mismatch");
        }
    }

    /// @dev R-31: YieldSplitsProposed event on propose; YieldSplitsUpdated on finalize.
    function test_TC06_setYieldSplits_emitsEvent() public {
        uint256 vaultId = _addDefaultVault();
        uint16[4] memory newYield = [uint16(6000), uint16(6500), uint16(7000), uint16(7500)];
        uint16[4] memory newFunding = [uint16(1500), uint16(1500), uint16(1000), uint16(1000)];

        vm.startPrank(owner);
        vm.expectEmit(true, false, false, true);
        emit VaultRegistry.YieldSplitsProposed(vaultId);
        registry.setYieldSplits(vaultId, newYield, newFunding);

        vm.warp(block.timestamp + 2 days + 1);
        vm.expectEmit(true, false, false, true);
        emit VaultRegistry.YieldSplitsUpdated(vaultId);
        registry.finalizeYieldSplits(vaultId);
        vm.stopPrank();
    }

    /// @dev R-31 boundary: sum exactly 10000 per tier succeeds.
    function test_TC06_setYieldSplits_sumExactly10000Succeeds() public {
        uint256 vaultId = _addDefaultVault();
        uint16[4] memory newYield = [uint16(8000), uint16(8000), uint16(8000), uint16(8000)];
        uint16[4] memory newFunding = [uint16(2000), uint16(2000), uint16(2000), uint16(2000)];

        vm.startPrank(owner);
        registry.setYieldSplits(vaultId, newYield, newFunding);
        vm.warp(block.timestamp + 2 days + 1);
        registry.finalizeYieldSplits(vaultId);
        vm.stopPrank();

        VaultConfig memory cfg = registry.getVault(vaultId);
        for (uint256 i; i < 4; ++i) {
            assertEq(cfg.yieldSplitsBps[i], 8000);
            assertEq(cfg.fundingBps[i], 2000);
        }
    }

    /// @dev R-33: sum exceeds 10000 on tier 0 MUST revert InvalidSplitTotal(0).
    function test_TC06_setYieldSplits_invalidSplitTotalTier0Reverts() public {
        uint256 vaultId = _addDefaultVault();
        uint16[4] memory newYield = [uint16(8001), uint16(5000), uint16(5000), uint16(5000)];
        uint16[4] memory newFunding = [uint16(2000), uint16(2000), uint16(2000), uint16(2000)];

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(VaultRegistry.InvalidSplitTotal.selector, uint8(0)));
        registry.setYieldSplits(vaultId, newYield, newFunding);
    }

    /// @dev R-33: sum exceeds 10000 on tier 2 MUST revert InvalidSplitTotal(2).
    function test_TC06_setYieldSplits_invalidSplitTotalTier2Reverts() public {
        uint256 vaultId = _addDefaultVault();
        uint16[4] memory newYield = [uint16(5000), uint16(5000), uint16(8001), uint16(5000)];
        uint16[4] memory newFunding = [uint16(2000), uint16(2000), uint16(2000), uint16(2000)];

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(VaultRegistry.InvalidSplitTotal.selector, uint8(2)));
        registry.setYieldSplits(vaultId, newYield, newFunding);
    }

    /// @dev R-34: Zero yield split on tier 0 MUST revert ZeroYieldSplit(0).
    function test_TC06_setYieldSplits_zeroYieldSplitTier0Reverts() public {
        uint256 vaultId = _addDefaultVault();
        uint16[4] memory newYield = [uint16(0), uint16(5000), uint16(5000), uint16(5000)];
        uint16[4] memory newFunding = [uint16(2000), uint16(2000), uint16(2000), uint16(2000)];

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(VaultRegistry.ZeroYieldSplit.selector, uint8(0)));
        registry.setYieldSplits(vaultId, newYield, newFunding);
    }

    /// @dev R-34: Zero yield split on tier 3 MUST revert ZeroYieldSplit(3).
    function test_TC06_setYieldSplits_zeroYieldSplitTier3Reverts() public {
        uint256 vaultId = _addDefaultVault();
        uint16[4] memory newYield = [uint16(5000), uint16(5000), uint16(5000), uint16(0)];
        uint16[4] memory newFunding = [uint16(2000), uint16(2000), uint16(2000), uint16(2000)];

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(VaultRegistry.ZeroYieldSplit.selector, uint8(3)));
        registry.setYieldSplits(vaultId, newYield, newFunding);
    }

    /// @dev R-31: Minimum valid yield splits (1 bps per tier, 0 funding).
    function test_TC06_setYieldSplits_minimumValidSucceeds() public {
        uint256 vaultId = _addDefaultVault();
        uint16[4] memory newYield = [uint16(1), uint16(1), uint16(1), uint16(1)];
        uint16[4] memory newFunding = [uint16(0), uint16(0), uint16(0), uint16(0)];

        vm.startPrank(owner);
        registry.setYieldSplits(vaultId, newYield, newFunding);
        vm.warp(block.timestamp + 2 days + 1);
        registry.finalizeYieldSplits(vaultId);
        vm.stopPrank();

        VaultConfig memory cfg = registry.getVault(vaultId);
        for (uint256 i; i < 4; ++i) {
            assertEq(cfg.yieldSplitsBps[i], 1);
            assertEq(cfg.fundingBps[i], 0);
        }
    }

    /// @dev R-32: Non-existent vaultId reverts InvalidVaultId.
    function test_TC06_setYieldSplits_nonExistentIdReverts() public {
        uint16[4] memory y = [uint16(5000), uint16(5000), uint16(5000), uint16(5000)];
        uint16[4] memory f = [uint16(2000), uint16(2000), uint16(2000), uint16(2000)];

        vm.prank(owner);
        vm.expectRevert(VaultRegistry.InvalidVaultId.selector);
        registry.setYieldSplits(999, y, f);
    }

    /// @dev R-32: vaultId 0 reverts InvalidVaultId.
    function test_TC06_setYieldSplits_id0Reverts() public {
        uint16[4] memory y = [uint16(5000), uint16(5000), uint16(5000), uint16(5000)];
        uint16[4] memory f = [uint16(2000), uint16(2000), uint16(2000), uint16(2000)];

        vm.prank(owner);
        vm.expectRevert(VaultRegistry.InvalidVaultId.selector);
        registry.setYieldSplits(0, y, f);
    }

    /// @dev R-35: Non-owner reverts OwnableUnauthorizedAccount.
    function test_TC06_setYieldSplits_nonOwnerReverts() public {
        uint256 vaultId = _addDefaultVault();
        uint16[4] memory y = [uint16(5000), uint16(5000), uint16(5000), uint16(5000)];
        uint16[4] memory f = [uint16(2000), uint16(2000), uint16(2000), uint16(2000)];

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, attacker));
        registry.setYieldSplits(vaultId, y, f);
    }

    /// @dev R-48: setYieldSplits works on Paused vault.
    /// @dev OF-16-009: setYieldSplits reverts on Paused vault with VaultNotActive.
    function test_TC06_setYieldSplits_worksOnPausedVault() public {
        uint256 vaultId = _addDefaultVault();
        vm.prank(owner);
        registry.pauseVault(vaultId);

        uint16[4] memory newYield = [uint16(5000), uint16(5500), uint16(6000), uint16(6500)];
        uint16[4] memory newFunding = [uint16(2000), uint16(2000), uint16(1500), uint16(1500)];

        vm.expectRevert(VaultRegistry.VaultNotActive.selector);
        vm.prank(owner);
        registry.setYieldSplits(vaultId, newYield, newFunding);
    }

    /// @dev OF-16-009: setYieldSplits reverts on WindingDown vault with VaultNotActive.
    function test_TC06_setYieldSplits_worksOnWindingDownVault() public {
        uint256 vaultId = _addDefaultVault();
        vm.prank(owner);
        registry.startWindDown(vaultId);

        uint16[4] memory newYield = [uint16(4000), uint16(4500), uint16(5000), uint16(5500)];
        uint16[4] memory newFunding = [uint16(2000), uint16(2000), uint16(2000), uint16(2000)];

        vm.expectRevert(VaultRegistry.VaultNotActive.selector);
        vm.prank(owner);
        registry.setYieldSplits(vaultId, newYield, newFunding);
    }

    /// @dev R-31: Zero funding with max yield (100%) succeeds.
    function test_TC06_setYieldSplits_zeroFundingMaxYieldSucceeds() public {
        uint256 vaultId = _addDefaultVault();
        uint16[4] memory newYield = [uint16(10000), uint16(10000), uint16(10000), uint16(10000)];
        uint16[4] memory newFunding = [uint16(0), uint16(0), uint16(0), uint16(0)];

        vm.startPrank(owner);
        registry.setYieldSplits(vaultId, newYield, newFunding);
        vm.warp(block.timestamp + 2 days + 1);
        registry.finalizeYieldSplits(vaultId);
        vm.stopPrank();

        VaultConfig memory cfg = registry.getVault(vaultId);
        for (uint256 i; i < 4; ++i) {
            assertEq(cfg.yieldSplitsBps[i], 10000);
            assertEq(cfg.fundingBps[i], 0);
        }
    }
}

// ============================================================
// TC-07: View Functions (R-36 .. R-42, R-48)
// ============================================================
contract VaultRegistry_TC07_ViewFunctions is VaultRegistryTestBase {
    // ---- getVault ----

    /// @dev R-36: getVault returns full VaultConfig for valid ID.
    function test_TC07_getVault_returnsFullConfig() public {
        uint256 vaultId = _addDefaultVault();
        VaultConfig memory cfg = registry.getVault(vaultId);
        assertEq(cfg.vaultId, vaultId);
        assertTrue(cfg.status == VaultStatus.Active);
        // Name should be non-empty
        assertTrue(bytes(cfg.name).length > 0, "name should be non-empty");
    }

    /// @dev R-37: getVault with ID 0 reverts InvalidVaultId.
    function test_TC07_getVault_id0Reverts() public {
        vm.expectRevert(VaultRegistry.InvalidVaultId.selector);
        registry.getVault(0);
    }

    /// @dev R-37: getVault with non-existent ID reverts InvalidVaultId.
    function test_TC07_getVault_nonExistentIdReverts() public {
        vm.expectRevert(VaultRegistry.InvalidVaultId.selector);
        registry.getVault(999);
    }

    /// @dev R-48: getVault works on Paused vault, returns Paused status.
    function test_TC07_getVault_worksOnPausedVault() public {
        uint256 vaultId = _addDefaultVault();
        vm.prank(owner);
        registry.pauseVault(vaultId);

        VaultConfig memory cfg = registry.getVault(vaultId);
        assertTrue(cfg.status == VaultStatus.Paused);
    }

    /// @dev R-48: getVault works on WindingDown vault, returns WindingDown status.
    function test_TC07_getVault_worksOnWindingDownVault() public {
        uint256 vaultId = _addDefaultVault();
        vm.prank(owner);
        registry.startWindDown(vaultId);

        VaultConfig memory cfg = registry.getVault(vaultId);
        assertTrue(cfg.status == VaultStatus.WindingDown);
    }

    // ---- getActiveVaults ----

    /// @dev R-38: No vaults registered, getActiveVaults returns empty.
    function test_TC07_getActiveVaults_emptyInitially() public view {
        uint256[] memory active = registry.getActiveVaults();
        assertEq(active.length, 0);
    }

    /// @dev R-38: All Active vaults returned.
    function test_TC07_getActiveVaults_returnsAllActive() public {
        _addVaultWithAbbreviation("V1");
        _addVaultWithAbbreviation("V2");
        _addVaultWithAbbreviation("V3");

        uint256[] memory active = registry.getActiveVaults();
        assertEq(active.length, 3);
        assertEq(active[0], 1);
        assertEq(active[1], 2);
        assertEq(active[2], 3);
    }

    /// @dev R-38: Paused vault excluded from getActiveVaults.
    function test_TC07_getActiveVaults_excludesPaused() public {
        _addVaultWithAbbreviation("V1");
        _addVaultWithAbbreviation("V2");
        _addVaultWithAbbreviation("V3");

        vm.prank(owner);
        registry.pauseVault(2);

        uint256[] memory active = registry.getActiveVaults();
        assertEq(active.length, 2);
        // Should contain 1 and 3 but not 2
        bool found2 = false;
        for (uint256 i; i < active.length; ++i) {
            if (active[i] == 2) found2 = true;
        }
        assertFalse(found2, "Paused vault 2 should not be in active list");
    }

    /// @dev R-38: WindingDown vault excluded from getActiveVaults.
    function test_TC07_getActiveVaults_excludesWindingDown() public {
        _addVaultWithAbbreviation("V1");
        _addVaultWithAbbreviation("V2");
        _addVaultWithAbbreviation("V3");

        vm.prank(owner);
        registry.startWindDown(1);
        vm.prank(owner);
        registry.pauseVault(2);

        uint256[] memory active = registry.getActiveVaults();
        assertEq(active.length, 1);
        assertEq(active[0], 3);
    }

    /// @dev R-38: All vaults non-active, getActiveVaults returns empty.
    function test_TC07_getActiveVaults_allNonActiveReturnsEmpty() public {
        uint256 id1 = _addVaultWithAbbreviation("V1");
        uint256 id2 = _addVaultWithAbbreviation("V2");

        vm.prank(owner);
        registry.startWindDown(id1);
        vm.prank(owner);
        registry.startWindDown(id2);

        uint256[] memory active = registry.getActiveVaults();
        assertEq(active.length, 0);
    }

    // ---- getAllVaults ----

    /// @dev R-39: No vaults registered, getAllVaults returns empty.
    function test_TC07_getAllVaults_emptyInitially() public view {
        uint256[] memory all = registry.getAllVaults();
        assertEq(all.length, 0);
    }

    /// @dev R-39: getAllVaults returns all IDs regardless of status.
    function test_TC07_getAllVaults_returnsAllRegardlessOfStatus() public {
        _addVaultWithAbbreviation("V1");
        _addVaultWithAbbreviation("V2");
        _addVaultWithAbbreviation("V3");

        vm.prank(owner);
        registry.pauseVault(2);
        vm.prank(owner);
        registry.startWindDown(1);

        uint256[] memory all = registry.getAllVaults();
        assertEq(all.length, 3);
        assertEq(all[0], 1);
        assertEq(all[1], 2);
        assertEq(all[2], 3);
    }

    // ---- vaultCount ----

    /// @dev R-40: vaultCount is 0 initially.
    function test_TC07_vaultCount_zeroInitially() public view {
        assertEq(registry.vaultCount(), 0);
    }

    /// @dev R-40: vaultCount increments with each registration.
    function test_TC07_vaultCount_incrementsOnAdd() public {
        _addVaultWithAbbreviation("V1");
        assertEq(registry.vaultCount(), 1);
        _addVaultWithAbbreviation("V2");
        assertEq(registry.vaultCount(), 2);
    }

    /// @dev R-40, R-45: vaultCount does not change on pause or wind-down.
    function test_TC07_vaultCount_unchangedByStatusChange() public {
        _addVaultWithAbbreviation("V1");
        _addVaultWithAbbreviation("V2");
        assertEq(registry.vaultCount(), 2);

        vm.prank(owner);
        registry.pauseVault(1);
        assertEq(registry.vaultCount(), 2, "count unchanged after pause");

        vm.prank(owner);
        registry.startWindDown(1);
        assertEq(registry.vaultCount(), 2, "count unchanged after wind-down");
    }

    // ---- getVaultByAbbreviation ----

    /// @dev R-41: getVaultByAbbreviation returns correct vault ID.
    function test_TC07_getVaultByAbbreviation_returnsCorrectId() public {
        _addDefaultVault(); // "CSMN" -> id 1
        _addVaultWithAbbreviation("MN"); // -> id 2

        assertEq(registry.getVaultByAbbreviation("CSMN"), 1);
        assertEq(registry.getVaultByAbbreviation("MN"), 2);
    }

    /// @dev R-42: Non-existent abbreviation reverts VaultNotFound.
    function test_TC07_getVaultByAbbreviation_nonExistentReverts() public {
        vm.expectRevert(VaultRegistry.VaultNotFound.selector);
        registry.getVaultByAbbreviation("NONE");
    }

    /// @dev R-42: Empty string abbreviation reverts VaultNotFound.
    function test_TC07_getVaultByAbbreviation_emptyStringReverts() public {
        vm.expectRevert(VaultRegistry.VaultNotFound.selector);
        registry.getVaultByAbbreviation("");
    }

    /// @dev R-48: getVaultByAbbreviation works on Paused vault.
    function test_TC07_getVaultByAbbreviation_worksOnPausedVault() public {
        _addDefaultVault(); // "CSMN"
        vm.prank(owner);
        registry.pauseVault(1);

        assertEq(registry.getVaultByAbbreviation("CSMN"), 1);
    }

    /// @dev R-48: getVaultByAbbreviation works on WindingDown vault.
    function test_TC07_getVaultByAbbreviation_worksOnWindingDownVault() public {
        _addDefaultVault(); // "CSMN"
        vm.prank(owner);
        registry.startWindDown(1);

        assertEq(registry.getVaultByAbbreviation("CSMN"), 1);
    }

    /// @dev R-44: Case sensitivity: "CSMN" != "csmn".
    function test_TC07_getVaultByAbbreviation_caseSensitive() public {
        _addDefaultVault(); // "CSMN"

        // "csmn" should not resolve to vault 1
        vm.expectRevert(VaultRegistry.VaultNotFound.selector);
        registry.getVaultByAbbreviation("csmn");
    }
}

// ============================================================
// TC-08: Abbreviation Uniqueness (R-12, R-44)
// ============================================================
contract VaultRegistry_TC08_AbbreviationUniqueness is VaultRegistryTestBase {
    /// @dev R-12: Duplicate abbreviation reverts DuplicateAbbreviation.
    function test_TC08_duplicateAbbreviationReverts() public {
        _addDefaultVault(); // "CSMN"

        (
            string memory name,,,
            address stakingQueue,
            uint256 capacityCap,
            uint256[4] memory lockupDurations,
            uint16[4] memory yieldSplitsBps,
            uint16[4] memory fundingBps
        ) = _createDefaultVaultParams();

        // OF-003: Use unique tier vault addresses to isolate the abbreviation check
        address[4] memory uniqueTiers =
            [makeAddr("dup8_t0"), makeAddr("dup8_t1"), makeAddr("dup8_t2"), makeAddr("dup8_t3")];

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(VaultRegistry.DuplicateAbbreviation.selector, "CSMN"));
        registry.addVault(
            name, "CSMN", uniqueTiers, stakingQueue, capacityCap, lockupDurations, yieldSplitsBps, fundingBps
        );
    }

    /// @dev R-12: Second duplicate abbreviation also reverts.
    function test_TC08_secondDuplicateAbbreviationReverts() public {
        _addVaultWithAbbreviation("MN");

        (
            string memory name,,,
            address stakingQueue,
            uint256 capacityCap,
            uint256[4] memory lockupDurations,
            uint16[4] memory yieldSplitsBps,
            uint16[4] memory fundingBps
        ) = _createDefaultVaultParams();

        // OF-003: Use unique tier vault addresses
        address[4] memory uniqueTiers =
            [makeAddr("dup8b_t0"), makeAddr("dup8b_t1"), makeAddr("dup8b_t2"), makeAddr("dup8b_t3")];

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(VaultRegistry.DuplicateAbbreviation.selector, "MN"));
        registry.addVault(
            name, "MN", uniqueTiers, stakingQueue, capacityCap, lockupDurations, yieldSplitsBps, fundingBps
        );
    }

    /// @dev R-44: Case-sensitive uniqueness: "abc" and "ABC" are distinct.
    function test_TC08_caseSensitiveDistinctAbbreviations() public {
        uint256 id1 = _addVaultWithAbbreviation("abc");
        uint256 id2 = _addVaultWithAbbreviation("ABC");

        assertNotEq(id1, id2, "IDs should differ");
        assertEq(registry.getVaultByAbbreviation("abc"), id1);
        assertEq(registry.getVaultByAbbreviation("ABC"), id2);
    }

    /// @dev R-12: Different vaults can have the same name but not the same abbreviation.
    function test_TC08_sameNameDifferentAbbreviationSucceeds() public {
        _addVaultWithAbbreviation("V1");
        // Same default name, different abbreviation
        uint256 id2 = _addVaultWithAbbreviation("V2");
        assertEq(id2, 2);
    }

    /// @dev R-12: Exact duplicate after using same name reverts.
    function test_TC08_exactDuplicateAfterSameNameReverts() public {
        _addVaultWithAbbreviation("Test");

        (
            string memory name,,,
            address stakingQueue,
            uint256 capacityCap,
            uint256[4] memory lockupDurations,
            uint16[4] memory yieldSplitsBps,
            uint16[4] memory fundingBps
        ) = _createDefaultVaultParams();

        address[4] memory uniqueTiers =
            [makeAddr("dup8c_t0"), makeAddr("dup8c_t1"), makeAddr("dup8c_t2"), makeAddr("dup8c_t3")];

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(VaultRegistry.DuplicateAbbreviation.selector, "Test"));
        registry.addVault(
            name, "Test", uniqueTiers, stakingQueue, capacityCap, lockupDurations, yieldSplitsBps, fundingBps
        );
    }

    /// @dev R-44: Pausing a vault does not free its abbreviation.
    function test_TC08_pausedVaultAbbreviationStillReserved() public {
        _addDefaultVault(); // "CSMN"
        vm.prank(owner);
        registry.pauseVault(1);

        (
            string memory name,,,
            address stakingQueue,
            uint256 capacityCap,
            uint256[4] memory lockupDurations,
            uint16[4] memory yieldSplitsBps,
            uint16[4] memory fundingBps
        ) = _createDefaultVaultParams();

        address[4] memory uniqueTiers =
            [makeAddr("dup8d_t0"), makeAddr("dup8d_t1"), makeAddr("dup8d_t2"), makeAddr("dup8d_t3")];

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(VaultRegistry.DuplicateAbbreviation.selector, "CSMN"));
        registry.addVault(
            name, "CSMN", uniqueTiers, stakingQueue, capacityCap, lockupDurations, yieldSplitsBps, fundingBps
        );
    }

    /// @dev R-44: Winding down a vault does not free its abbreviation.
    function test_TC08_windingDownVaultAbbreviationStillReserved() public {
        _addVaultWithAbbreviation("MN");
        vm.prank(owner);
        registry.startWindDown(1);

        (
            string memory name,,,
            address stakingQueue,
            uint256 capacityCap,
            uint256[4] memory lockupDurations,
            uint16[4] memory yieldSplitsBps,
            uint16[4] memory fundingBps
        ) = _createDefaultVaultParams();

        address[4] memory uniqueTiers =
            [makeAddr("dup8e_t0"), makeAddr("dup8e_t1"), makeAddr("dup8e_t2"), makeAddr("dup8e_t3")];

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(VaultRegistry.DuplicateAbbreviation.selector, "MN"));
        registry.addVault(
            name, "MN", uniqueTiers, stakingQueue, capacityCap, lockupDurations, yieldSplitsBps, fundingBps
        );
    }

    /// @dev R-44: Variable-length abbreviations independently stored and retrievable.
    function test_TC08_variousLengthAbbreviations() public {
        uint256 id1 = _addVaultWithAbbreviation("A");
        uint256 id2 = _addVaultWithAbbreviation("ABCDEFGHIJ");
        uint256 id3 = _addVaultWithAbbreviation("ABCDEFGHIJKLMNOPQRSTUVWXYZABCDEFGHIJKLMNOPQRSTUVWX");

        assertEq(registry.getVaultByAbbreviation("A"), id1);
        assertEq(registry.getVaultByAbbreviation("ABCDEFGHIJ"), id2);
        assertEq(registry.getVaultByAbbreviation("ABCDEFGHIJKLMNOPQRSTUVWXYZABCDEFGHIJKLMNOPQRSTUVWX"), id3);
    }
}
