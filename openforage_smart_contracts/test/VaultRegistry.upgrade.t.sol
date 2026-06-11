// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/VaultRegistryTestBase.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

// ============================================================
// V2, V3, V4 upgrade test contracts for VaultRegistry
// ============================================================

/// @dev V2 with one additional storage variable appended at end.
contract VaultRegistryV2 is VaultRegistry {
    uint256 public newV2Field;

    function setV2Field(uint256 val) external {
        newV2Field = val;
    }

    function version() external pure virtual returns (uint256) {
        return 2;
    }
}

/// @dev V3 extends V2 with another appended storage variable.
contract VaultRegistryV3 is VaultRegistryV2 {
    uint256 public newV3Field;

    function setV3Field(uint256 val) external {
        newV3Field = val;
    }

    function version() external pure virtual override returns (uint256) {
        return 3;
    }
}

/// @dev V4 extends V3 -- proves upgrade-after-upgrade-after-upgrade is not bricked.
contract VaultRegistryV4 is VaultRegistryV3 {
    uint256 public newV4Field;

    function setV4Field(uint256 val) external {
        newV4Field = val;
    }

    function version() external pure override returns (uint256) {
        return 4;
    }
}

// ============================================================
// TC-11: UUPS Upgrade Tests
// Requirements: R-04, R-50, R-51
// ============================================================
contract VaultRegistry_TC11_Upgrade is VaultRegistryTestBase {
    bytes32 internal constant ERC1967_IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    /// @dev TC-11 step 4: Non-owner calls upgradeToAndCall -- MUST revert OwnableUnauthorizedAccount.
    function test_TC11_unauthorizedUpgradeReverts() public {
        VaultRegistryV2 implV2 = new VaultRegistryV2();

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, attacker));
        registry.upgradeToAndCall(address(implV2), "");
    }

    /// @dev TC-11 step 3: Owner upgrades v1 -> v2. State preserved, implementation changes,
    ///      version() returns 2.
    function test_TC11_v1ToV2_statePreserved() public {
        // Create v1 state: add a vault
        uint256 vaultId = _addDefaultVault();
        uint256 countBefore = registry.vaultCount();
        address ownerBefore = registry.owner();
        address proxyAddr = address(registry);

        // Record v1 implementation address
        address v1Impl = address(uint160(uint256(vm.load(proxyAddr, ERC1967_IMPL_SLOT))));

        // Upgrade to V2
        VaultRegistryV2 implV2 = new VaultRegistryV2();
        vm.prank(owner);
        registry.upgradeToAndCall(address(implV2), "");

        // Verify implementation address changed
        address v2ImplAddr = address(uint160(uint256(vm.load(proxyAddr, ERC1967_IMPL_SLOT))));
        assertTrue(v2ImplAddr != v1Impl, "Implementation address should change after upgrade");
        assertEq(v2ImplAddr, address(implV2), "Implementation should point to V2");

        // Verify proxy address unchanged
        assertEq(address(registry), proxyAddr, "Proxy address should not change");

        // Verify v2 functionality
        assertEq(VaultRegistryV2(proxyAddr).version(), 2, "V2 version should be 2");

        // Verify v1 state preserved
        assertEq(registry.vaultCount(), countBefore, "vaultCount must be preserved after upgrade");
        assertEq(registry.owner(), ownerBefore, "owner must be preserved after upgrade");

        VaultConfig memory config = registry.getVault(vaultId);
        assertEq(config.vaultId, vaultId, "vault config must be preserved after upgrade");
        assertEq(keccak256(bytes(config.abbreviation)), keccak256(bytes("CSMN")), "abbreviation must be preserved");
    }

    /// @dev TC-11 step 5: v1 -> v2 -> v3 preserves all state from both versions.
    function test_TC11_v2ToV3_allStatePersists() public {
        // Create v1 state
        uint256 vaultId = _addDefaultVault();
        address proxyAddr = address(registry);

        // Upgrade to V2
        VaultRegistryV2 implV2 = new VaultRegistryV2();
        vm.prank(owner);
        registry.upgradeToAndCall(address(implV2), "");

        // Set V2 state
        VaultRegistryV2(proxyAddr).setV2Field(42);
        assertEq(VaultRegistryV2(proxyAddr).newV2Field(), 42, "V2 field should be set");

        // Upgrade to V3
        VaultRegistryV3 implV3 = new VaultRegistryV3();
        vm.prank(owner);
        registry.upgradeToAndCall(address(implV3), "");

        // Verify ALL prior state preserved
        assertEq(VaultRegistryV3(proxyAddr).version(), 3, "V3 version should be 3");
        assertEq(VaultRegistryV3(proxyAddr).newV2Field(), 42, "V2 state preserved through v3");
        assertEq(registry.owner(), owner, "V1 owner preserved through v3");
        assertEq(registry.vaultCount(), 1, "V1 vaultCount preserved through v3");

        VaultConfig memory config = registry.getVault(vaultId);
        assertEq(config.vaultId, vaultId, "V1 vault config preserved through v3");
    }

    /// @dev TC-11 step 10: Detailed state preservation. Add 2 vaults, pause one, set cap
    ///      on other, update yield splits. After upgrade, verify all state.
    function test_TC11_detailedStatePreservation() public {
        // Register 2 vaults
        uint256 vault1 = _addDefaultVault();
        uint256 vault2 = _addVaultWithAbbreviation("MN");

        // Pause vault 1
        vm.prank(owner);
        registry.pauseVault(vault1);

        // Set capacity cap on vault 2 (propose + finalize)
        uint256 newCap = 50_000_000e6;
        vm.startPrank(owner);
        registry.setCapacityCap(vault2, newCap);
        vm.warp(block.timestamp + 2 days + 1);
        registry.finalizeCapacityCap(vault2);
        vm.stopPrank();

        // Update yield splits on vault 2 (propose + finalize)
        uint16[4] memory newYieldBps = [uint16(6000), uint16(5000), uint16(4000), uint16(3000)];
        uint16[4] memory newFundBps = [uint16(4000), uint16(5000), uint16(6000), uint16(7000)];
        vm.startPrank(owner);
        registry.setYieldSplits(vault2, newYieldBps, newFundBps);
        vm.warp(block.timestamp + 2 days + 1);
        registry.finalizeYieldSplits(vault2);
        vm.stopPrank();

        // Upgrade to V2
        VaultRegistryV2 implV2 = new VaultRegistryV2();
        vm.prank(owner);
        registry.upgradeToAndCall(address(implV2), "");

        // Verify vault 1 is still Paused
        VaultConfig memory config1 = registry.getVault(vault1);
        assertEq(uint8(config1.status), uint8(VaultStatus.Paused), "Vault 1 should still be Paused after upgrade");

        // Verify vault 2 has updated capacity cap
        VaultConfig memory config2 = registry.getVault(vault2);
        assertEq(config2.capacityCap, newCap, "Vault 2 capacity cap should be preserved");

        // Verify vault 2 has updated yield splits
        for (uint256 i = 0; i < 4; i++) {
            assertEq(config2.yieldSplitsBps[i], newYieldBps[i], "Vault 2 yield splits should be preserved");
            assertEq(config2.fundingBps[i], newFundBps[i], "Vault 2 funding bps should be preserved");
        }

        // Verify vaultCount
        assertEq(registry.vaultCount(), 2, "vaultCount should be preserved after upgrade");

        // Verify getActiveVaults returns only vault 2 (vault 1 is Paused)
        uint256[] memory activeVaults = registry.getActiveVaults();
        assertEq(activeVaults.length, 1, "Only 1 active vault after pause + upgrade");
        assertEq(activeVaults[0], vault2, "Active vault should be vault 2");

        // Verify abbreviation lookups still work
        assertEq(registry.getVaultByAbbreviation("CSMN"), vault1, "CSMN lookup should still work");
        assertEq(registry.getVaultByAbbreviation("MN"), vault2, "MN lookup should still work");
    }

    /// @dev TC-11 step 6: v3 can still upgrade to v4 (no bricking).
    function test_TC11_v3ToV4_notBricked() public {
        address proxyAddr = address(registry);

        // Chain: v1 -> v2 -> v3 -> v4
        // Deploy before prank — CREATE consumes vm.prank in Foundry
        VaultRegistryV2 implV2 = new VaultRegistryV2();
        vm.prank(owner);
        registry.upgradeToAndCall(address(implV2), "");

        VaultRegistryV3 implV3 = new VaultRegistryV3();
        vm.prank(owner);
        registry.upgradeToAndCall(address(implV3), "");

        VaultRegistryV4 implV4 = new VaultRegistryV4();
        vm.prank(owner);
        registry.upgradeToAndCall(address(implV4), "");

        // Verify v4 is operational
        assertEq(VaultRegistryV4(proxyAddr).version(), 4, "V4 version should be 4");

        // Proxy address unchanged through 3 upgrades
        assertEq(address(registry), proxyAddr, "Proxy address stable through 3 upgrades");
    }

    /// @dev TC-11: Implementation address changes, proxy address stable across upgrades.
    function test_TC11_implementationAddressChangesEachUpgrade() public {
        address proxyAddr = address(registry);

        address impl1 = address(uint160(uint256(vm.load(proxyAddr, ERC1967_IMPL_SLOT))));

        // Deploy before prank — CREATE consumes vm.prank in Foundry
        VaultRegistryV2 v2Impl = new VaultRegistryV2();
        vm.prank(owner);
        registry.upgradeToAndCall(address(v2Impl), "");
        address impl2 = address(uint160(uint256(vm.load(proxyAddr, ERC1967_IMPL_SLOT))));

        VaultRegistryV3 v3Impl = new VaultRegistryV3();
        vm.prank(owner);
        registry.upgradeToAndCall(address(v3Impl), "");
        address impl3 = address(uint160(uint256(vm.load(proxyAddr, ERC1967_IMPL_SLOT))));

        assertTrue(impl1 != impl2, "V1 and V2 implementations should differ");
        assertTrue(impl2 != impl3, "V2 and V3 implementations should differ");
        assertTrue(impl1 != impl3, "V1 and V3 implementations should differ");

        // Proxy address never changed
        assertEq(address(registry), proxyAddr, "Proxy address must be stable");
    }

    /// @dev TC-11 step 1: proxiableUUID returns correct ERC1967 implementation slot.
    ///      proxiableUUID has notDelegated modifier, so call on implementation directly.
    function test_TC11_proxiableUUID() public view {
        bytes32 uuid = implementation.proxiableUUID();
        assertEq(uuid, ERC1967_IMPL_SLOT, "proxiableUUID must return ERC1967 implementation slot");
    }

    /// @dev TC-11 step 7: Implementation contract direct init blocked.
    ///      Calling initialize() on the raw implementation reverts InvalidInitialization.
    function test_TC11_implDirectInitReverts() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(owner);
    }

    /// @dev TC-11 steps 8-9: V2 and V3 implementation direct init also blocked.
    function test_TC11_implV2V3DirectInitReverts() public {
        VaultRegistryV2 implV2 = new VaultRegistryV2();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implV2.initialize(owner);

        VaultRegistryV3 implV3 = new VaultRegistryV3();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implV3.initialize(owner);
    }
}
