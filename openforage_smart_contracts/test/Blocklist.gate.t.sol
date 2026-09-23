// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/Blocklist.sol";
import "../src/interfaces/IAllowlist.sol";
import "./mocks/MockAllowlist.sol";

contract BlocklistGateTest is Test {
    Blocklist internal blocklist;
    MockAllowlist internal mockAllowlist;

    address internal owner;
    address internal guardian;
    address internal caller;

    function setUp() public {
        owner = makeAddr("blocklistGateOwner");
        guardian = makeAddr("blocklistGateGuardian");
        caller = makeAddr("blocklistGateCaller");

        Blocklist implementation = new Blocklist();
        bytes memory initData = abi.encodeCall(Blocklist.initialize, (guardian, owner));
        blocklist = Blocklist(address(new ERC1967Proxy(address(implementation), initData)));

        mockAllowlist = new MockAllowlist();
        vm.prank(owner);
        blocklist.setAllowlist(address(mockAllowlist));
    }

    function test_gate_unverifiedBlockAddressRevertsCallerNotAllowed() public {
        mockAllowlist.setAllowed(caller, false);

        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(IAllowlist.CallerNotAllowed.selector, caller));
        blocklist.blockAddress(caller);
    }

    function test_gate_verifiedBlockAddressSucceeds() public {
        mockAllowlist.setAllAllowed(true);

        vm.prank(guardian);
        blocklist.blockAddress(caller);

        assertTrue(blocklist.isBlocked(caller), "verified guardian blocks");
    }
}
