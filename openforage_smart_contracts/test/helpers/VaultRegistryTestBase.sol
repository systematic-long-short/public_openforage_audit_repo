// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../../src/VaultRegistry.sol";

/// @dev Abstract base for VaultRegistry tests.
/// Deploys VaultRegistry behind an ERC1967 proxy with standard test addresses.
abstract contract VaultRegistryTestBase is Test {
    VaultRegistry public registry;
    VaultRegistry public implementation;

    address public owner;
    address public attacker;
    address public user;
    /// @dev OF-003: Counter for generating unique tier vault addresses across addVault calls.
    uint256 private _tierVaultNonce;

    function setUp() public virtual {
        owner = makeAddr("timelock");
        attacker = makeAddr("attacker");
        user = makeAddr("user");

        // Deploy implementation
        implementation = new VaultRegistry();

        // Deploy proxy with initialize call
        bytes memory initData = abi.encodeCall(VaultRegistry.initialize, (owner));
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        registry = VaultRegistry(address(proxy));
    }

    /// @dev Return valid test data for vault registration.
    function _createDefaultVaultParams()
        internal
        returns (
            string memory name,
            string memory abbreviation,
            address[4] memory tierVaults,
            address stakingQueue,
            uint256 capacityCap,
            uint256[4] memory lockupDurations,
            uint16[4] memory yieldSplitsBps,
            uint16[4] memory fundingBps
        )
    {
        name = "Crypto Spot Long/Short";
        abbreviation = "CSMN";
        tierVaults = [makeAddr("tier0"), makeAddr("tier1"), makeAddr("tier2"), makeAddr("tier3")];
        stakingQueue = makeAddr("stakingQueue");
        capacityCap = 10_000_000e6;
        lockupDurations = [uint256(0), 90 days, 180 days, 365 days];
        yieldSplitsBps = [uint16(7000), uint16(6000), uint16(5000), uint16(4000)];
        fundingBps = [uint16(3000), uint16(4000), uint16(5000), uint16(6000)];
    }

    /// @dev Add a vault with default params. Pranks as owner.
    /// Returns the vaultId assigned by the contract.
    function _addDefaultVault() internal returns (uint256 vaultId) {
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
        vaultId = registry.addVault(
            name, abbreviation, tierVaults, stakingQueue, capacityCap, lockupDurations, yieldSplitsBps, fundingBps
        );
    }

    /// @dev Add a vault with a custom abbreviation and unique tier vault addresses.
    /// OF-003: Each call generates fresh tier vault addresses to avoid cross-vault reuse.
    /// Pranks as owner. Returns the vaultId assigned by the contract.
    function _addVaultWithAbbreviation(string memory abbr) internal returns (uint256 vaultId) {
        (
            string memory name,,,
            address stakingQueue,
            uint256 capacityCap,
            uint256[4] memory lockupDurations,
            uint16[4] memory yieldSplitsBps,
            uint16[4] memory fundingBps
        ) = _createDefaultVaultParams();

        // Generate unique tier vault addresses
        _tierVaultNonce++;
        address[4] memory tierVaults = [
            makeAddr(string(abi.encodePacked("tier0_v", vm.toString(_tierVaultNonce)))),
            makeAddr(string(abi.encodePacked("tier1_v", vm.toString(_tierVaultNonce)))),
            makeAddr(string(abi.encodePacked("tier2_v", vm.toString(_tierVaultNonce)))),
            makeAddr(string(abi.encodePacked("tier3_v", vm.toString(_tierVaultNonce))))
        ];

        vm.prank(owner);
        vaultId = registry.addVault(
            name, abbr, tierVaults, stakingQueue, capacityCap, lockupDurations, yieldSplitsBps, fundingBps
        );
    }
}
