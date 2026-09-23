// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "../src/FORAGETreasury.sol";
import "../src/interfaces/IAllowlist.sol";
import "./mocks/MockAllowlist.sol";
import "./mocks/MockForageTokenSimple.sol";

contract FORAGETreasury_Gate is Test {
    FORAGETreasury internal treasury;
    MockAllowlist internal mockAllowlist;
    MockForageTokenSimple internal forage;

    address internal owner = makeAddr("gate-owner");
    uint256 internal constant ROUND_ID = 1;
    bytes32 internal root = keccak256(abi.encode("gate-agent-root"));

    function setUp() public {
        forage = new MockForageTokenSimple();
        FORAGETreasury implementation = new FORAGETreasury();
        bytes memory initData = abi.encodeCall(FORAGETreasury.initialize, (address(forage), owner));
        treasury = FORAGETreasury(address(new ERC1967Proxy(address(implementation), initData)));

        mockAllowlist = new MockAllowlist();
        mockAllowlist.setAllAllowed(true);
        vm.prank(owner);
        treasury.setAllowlist(address(mockAllowlist));
    }

    function test_gate_unverifiedPublishAgentRootRevertsCallerNotAllowed() public {
        address caller = owner;
        mockAllowlist.setAllAllowed(false);

        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(IAllowlist.CallerNotAllowed.selector, caller));
        treasury.publishAgentRoot(ROUND_ID, root, 1e18, uint64(block.timestamp + 30 days));
    }

    function test_gate_publishAgentRootSucceedsOnceAllowed() public {
        mockAllowlist.setAllAllowed(true);

        vm.prank(owner);
        treasury.publishAgentRoot(ROUND_ID, root, 1e18, uint64(block.timestamp + 30 days));

        (bytes32 storedRoot,,,,) = treasury.agentRounds(ROUND_ID);
        assertEq(storedRoot, root, "allowed owner publishes once the gate passes");
    }
}
