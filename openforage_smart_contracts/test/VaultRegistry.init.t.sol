// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/VaultRegistryTestBase.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

// ============================================================
// TC-01: Initialization and Constructor Tests (R-01, R-02, R-03, R-04)
// ============================================================
contract VaultRegistry_TC01_Initialization is VaultRegistryTestBase {
    // ----- R-01: owner() returns the initialOwner_ address after init -----
    /// @dev Verify that initialize sets the Ownable2Step owner to the provided address.
    function test_TC01_initializeSetsOwner() public view {
        assertEq(registry.owner(), owner, "owner should be initialOwner_ after init");
    }

    // ----- R-01: vaultCount() returns 0 after init -----
    /// @dev Verify that vaultCount is 0 immediately after initialization (no vaults registered).
    function test_TC01_initializeVaultCountZero() public view {
        assertEq(registry.vaultCount(), 0, "vaultCount should be 0 after init");
    }

    // ----- R-01: getActiveVaults() returns empty array after init -----
    /// @dev Verify that getActiveVaults returns an empty array when no vaults exist.
    function test_TC01_initializeGetActiveVaultsEmpty() public view {
        uint256[] memory active = registry.getActiveVaults();
        assertEq(active.length, 0, "getActiveVaults should return empty array after init");
    }

    // ----- R-01: getAllVaults() returns empty array after init -----
    /// @dev Verify that getAllVaults returns an empty array when no vaults exist.
    function test_TC01_initializeGetAllVaultsEmpty() public view {
        uint256[] memory all = registry.getAllVaults();
        assertEq(all.length, 0, "getAllVaults should return empty array after init");
    }

    // ----- R-01: first addVault should get vaultId=1 (nextVaultId starts at 1) -----
    /// @dev Verify indirectly that _nextVaultId is initialized to 1 by adding a vault
    ///      and checking the returned vaultId is 1.
    function test_TC01_initializeNextVaultIdOne() public {
        uint256 vaultId = _addDefaultVault();
        assertEq(vaultId, 1, "first vault should get vaultId=1 (nextVaultId starts at 1)");
    }

    // ----- R-03: double initialization reverts InvalidInitialization -----
    /// @dev Calling initialize a second time on the proxy MUST revert with
    ///      Initializable.InvalidInitialization because the proxy is already initialized.
    function test_TC01_doubleInitReverts() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        registry.initialize(owner);
    }

    // ----- R-02: zero address owner reverts ZeroAddress -----
    /// @dev Deploying a fresh proxy with address(0) as owner MUST revert with ZeroAddress().
    function test_TC01_zeroAddressOwnerReverts() public {
        VaultRegistry impl = new VaultRegistry();
        vm.expectRevert(VaultRegistry.ZeroAddress.selector);
        new ERC1967Proxy(address(impl), abi.encodeCall(VaultRegistry.initialize, (address(0))));
    }

    // ----- R-04: implementation contract initializers disabled -----
    /// @dev The constructor calls _disableInitializers, so calling initialize directly
    ///      on the implementation MUST revert with InvalidInitialization.
    function test_TC01_implementationInitDisabled() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(owner);
    }

    // ----- R-04: proxiableUUID returns correct ERC1822 slot -----
    /// @dev proxiableUUID has `notDelegated` modifier in OZ UUPS, so call on the
    ///      implementation directly. Must return the ERC1967 implementation slot.
    function test_TC01_proxiableUUID() public view {
        bytes32 expectedSlot = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
        assertEq(
            implementation.proxiableUUID(), expectedSlot, "proxiableUUID should return ERC1967 implementation slot"
        );
    }

    // ----- R-01: pendingOwner is address(0) after initialization -----
    /// @dev Verify that pendingOwner() returns address(0) after initialization
    ///      (no ownership transfer is pending).
    function test_TC01_initializePendingOwnerZero() public view {
        assertEq(registry.pendingOwner(), address(0), "pendingOwner should be address(0) after init");
    }
}
