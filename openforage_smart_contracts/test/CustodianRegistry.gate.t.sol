// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/CustodianRegistry.sol";
import "../src/interfaces/IAllowlist.sol";
import "./mocks/MockAllowlist.sol";

contract CustodianRegistryGateTest is Test {
    CustodianRegistry internal registry;
    MockAllowlist internal mockAllowlist;
    address internal caller = makeAddr("caller");
    address internal executor = makeAddr("executor");
    bytes32 internal custodianId;
    bytes32 internal peer = bytes32(uint256(0x1234));

    function setUp() public {
        CustodianRegistry implementation = new CustodianRegistry();
        bytes memory initData =
            abi.encodeCall(CustodianRegistry.initialize, (address(this), makeAddr("governor"), makeAddr("guardian")));
        registry = CustodianRegistry(address(new ERC1967Proxy(address(implementation), initData)));

        mockAllowlist = new MockAllowlist();
        mockAllowlist.setAllAllowed(true);
        registry.setAllowlist(address(mockAllowlist));

        custodianId = registry.HYPERLIQUID_CUSTODIAN_ID();
        registry.proposeCustodianConfig(registry.hyperLiquidLaunchConfig(caller, executor, 10_001, peer, 10_000_000e6));
        vm.warp(block.timestamp + registry.FINALIZE_DELAY() + 1);
        registry.finalizeCustodianConfig(custodianId);
    }

    function test_gate_unverifiedRecordNAVRevertsCallerNotAllowed() public {
        mockAllowlist.setAllAllowed(false);
        mockAllowlist.setAllowed(caller, false);

        vm.expectRevert(abi.encodeWithSelector(IAllowlist.CallerNotAllowed.selector, caller));
        vm.prank(caller);
        registry.recordNAV(custodianId, 1_000e6);
    }

    function test_gate_verifiedRecordNAVSucceeds() public {
        mockAllowlist.setAllAllowed(true);

        vm.prank(caller);
        registry.recordNAV(custodianId, 1_000e6);

        (uint256 nav,) = registry.lastNAV(custodianId);
        assertEq(nav, 1_000e6, "verified caller records nav");
    }
}
