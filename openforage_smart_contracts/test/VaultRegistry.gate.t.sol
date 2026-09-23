// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/VaultRegistry.sol";
import "../src/interfaces/IAllowlist.sol";
import "./mocks/MockAllowlist.sol";

contract VaultRegistryGateTest is Test {
    VaultRegistry internal registry;
    MockAllowlist internal mockAllowlist;
    address internal caller = makeAddr("caller");

    function setUp() public {
        VaultRegistry implementation = new VaultRegistry();
        bytes memory initData = abi.encodeCall(VaultRegistry.initialize, (caller));
        registry = VaultRegistry(address(new ERC1967Proxy(address(implementation), initData)));

        mockAllowlist = new MockAllowlist();
        mockAllowlist.setAllAllowed(true);
        vm.prank(caller);
        registry.setAllowlist(address(mockAllowlist));
    }

    function _addVault() private {
        address[4] memory tierVaults =
            [makeAddr("tier0"), makeAddr("tier1"), makeAddr("tier2"), makeAddr("tier3")];
        uint256[4] memory lockupDurations = [uint256(0), 90 days, 180 days, 365 days];
        uint16[4] memory yieldSplitsBps = [uint16(7000), uint16(6000), uint16(5000), uint16(4000)];
        uint16[4] memory fundingBps = [uint16(3000), uint16(4000), uint16(5000), uint16(6000)];

        registry.addVault(
            "Crypto Spot Long/Short",
            "CSMN",
            tierVaults,
            makeAddr("stakingQueue"),
            10_000_000e6,
            lockupDurations,
            yieldSplitsBps,
            fundingBps
        );
    }

    function test_gate_unverifiedAddVaultRevertsCallerNotAllowed() public {
        mockAllowlist.setAllAllowed(false);
        mockAllowlist.setAllowed(caller, false);

        vm.expectRevert(abi.encodeWithSelector(IAllowlist.CallerNotAllowed.selector, caller));
        vm.prank(caller);
        _addVault();
    }

    function test_gate_verifiedAddVaultSucceeds() public {
        mockAllowlist.setAllAllowed(true);

        vm.prank(caller);
        uint256 vaultId = registry.addVault(
            "Crypto Spot Long/Short",
            "CSMN",
            [makeAddr("tier0"), makeAddr("tier1"), makeAddr("tier2"), makeAddr("tier3")],
            makeAddr("stakingQueue"),
            10_000_000e6,
            [uint256(0), 90 days, 180 days, 365 days],
            [uint16(7000), uint16(6000), uint16(5000), uint16(4000)],
            [uint16(3000), uint16(4000), uint16(5000), uint16(6000)]
        );

        assertGt(vaultId, 0, "verified caller adds a vault");
    }
}
