// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/VaultRegistry.sol";
import "../src/GuardianModule.sol";

// ============================================================
// OF-16-002: VaultRegistry wind-down cooldown after loss resolution
// ============================================================
contract Audit16_OF002_WindDownCooldown is Test {
    VaultRegistry public registry;
    MockRISKUSDVault16 public vault;

    address public owner;

    function setUp() public {
        owner = makeAddr("owner");

        VaultRegistry impl = new VaultRegistry();
        bytes memory initData = abi.encodeCall(VaultRegistry.initialize, (owner));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        registry = VaultRegistry(address(proxy));

        vault = new MockRISKUSDVault16();

        // Wire RISKUSDVault reference
        vm.prank(owner);
        registry.initializeV2(address(vault));

        // Add a vault
        address[4] memory tiers = [makeAddr("t0"), makeAddr("t1"), makeAddr("t2"), makeAddr("t3")];
        uint16[4] memory splits = [uint16(2500), uint16(2500), uint16(2500), uint16(2500)];
        uint16[4] memory funding = [uint16(0), uint16(0), uint16(0), uint16(0)];
        uint256[4] memory lockups = [uint256(0), uint256(30 days), uint256(90 days), uint256(180 days)];

        vm.prank(owner);
        registry.addVault("Test", "TST", tiers, makeAddr("sq"), 1e18, lockups, splits, funding);
    }

    function test_OF16002_windDownBlockedDuringCooldown() public {
        // Simulate loss resolution notification
        vm.prank(address(vault));
        registry.notifyLossResolved();

        // Try wind-down immediately — should be blocked by cooldown
        vm.expectRevert(VaultRegistry.LossCooldownActive.selector);
        vm.prank(owner);
        registry.startWindDown(1);
    }

    function test_OF16002_windDownAllowedAfterCooldown() public {
        // Simulate loss resolution
        vm.prank(address(vault));
        registry.notifyLossResolved();

        // Advance past the same-block TOCTOU guard.
        vm.roll(block.number + 2);

        // Wind-down should succeed
        vm.prank(owner);
        registry.startWindDown(1);
    }
}

/// @dev Mock RISKUSDVault for VaultRegistry tests
contract MockRISKUSDVault16 {
    bool public lossPending;
    uint256 public lossPendingVaultId;

    function setLossPending(bool pending, uint256 vaultId) external {
        lossPending = pending;
        lossPendingVaultId = vaultId;
    }

    function vaultRegistry() external pure returns (address) {
        return address(0); // not needed for this test
    }
}

// ============================================================
// OF-16-003: ForageToken burn NatSpec is integration documentation
// (No regression test needed — this is a documentation fix)
// ============================================================

// ============================================================
// OF-16-005: Guardian permission separation
// ============================================================
contract Audit16_OF005_GuardianPermissionSeparation is Test {
    GuardianModule public guardian;

    address public timelock;
    address public governor;

    function setUp() public {
        timelock = makeAddr("timelock");
        governor = makeAddr("governor");

        address[] memory initialGuardians = new address[](0);
        uint256[] memory initialPerms = new uint256[](0);

        GuardianModule impl = new GuardianModule();
        bytes memory initData = abi.encodeCall(
            GuardianModule.initialize,
            (governor, timelock, initialGuardians, initialPerms) // governor first, timelock second per contract
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        guardian = GuardianModule(address(proxy));
    }

    /// @dev A guardian cannot have both PAUSE and CANCEL permissions
    function test_OF16005_pauseAndCancelForbidden() public {
        uint256 pausePerm = guardian.PERMISSION_CAN_PAUSE();
        uint256 cancelPerm = guardian.PERMISSION_CAN_CANCEL();
        uint256 bothPerms = pausePerm | cancelPerm;

        vm.expectRevert(GuardianModule.PauseAndCancelForbidden.selector);
        vm.prank(timelock);
        guardian.setGuardianPermissions(makeAddr("guardian1"), bothPerms);
    }

    /// @dev Individual PAUSE or CANCEL permissions are allowed separately
    function test_OF16005_separatePermissionsAllowed() public {
        address g1 = makeAddr("guardian1");
        address g2 = makeAddr("guardian2");
        // Cache constants to avoid vm.prank consumption by view calls
        uint256 pausePerm = guardian.PERMISSION_CAN_PAUSE();
        uint256 cancelPerm = guardian.PERMISSION_CAN_CANCEL();

        vm.prank(timelock);
        guardian.setGuardianPermissions(g1, pausePerm);

        vm.prank(timelock);
        guardian.setGuardianPermissions(g2, cancelPerm);

        assertTrue(guardian.hasPermission(g1, pausePerm));
        assertTrue(guardian.hasPermission(g2, cancelPerm));
    }

    /// @dev OF-16-014: Invalid bitmask rejected
    function test_OF16014_invalidBitmaskRejected() public {
        vm.expectRevert(GuardianModule.InvalidPermissionBitmask.selector);
        vm.prank(timelock);
        guardian.setGuardianPermissions(makeAddr("g"), type(uint256).max);
    }
}
