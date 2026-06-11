// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../../src/RISKUSD.sol";

abstract contract RISKUSDTestBase is Test {
    RISKUSD public token;
    RISKUSD public implementation;

    address public owner;
    address public minterAddr;
    address public governorAddr;
    address public alice;
    address public bob;
    address public charlie;
    address public attacker;

    function setUp() public virtual {
        owner = makeAddr("owner");
        minterAddr = makeAddr("minter");
        governorAddr = makeAddr("governor");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        charlie = makeAddr("charlie");
        attacker = makeAddr("attacker");

        // Deploy implementation
        implementation = new RISKUSD();

        // Deploy proxy
        bytes memory initData = abi.encodeCall(RISKUSD.initialize, (owner));
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        token = RISKUSD(address(proxy));
    }

    function _setupMinter() internal {
        vm.startPrank(owner);
        token.setMinter(minterAddr);
        vm.warp(block.timestamp + 2 days + 1);
        token.finalizeMinter();
        vm.stopPrank();
    }

    function _setupGovernor() internal {
        vm.startPrank(owner);
        token.setForageGovernor(governorAddr);
        vm.warp(block.timestamp + 2 days + 1);
        token.finalizeForageGovernor();
        vm.stopPrank();
    }

    function _mintTokens(address to, uint256 amount) internal {
        vm.prank(minterAddr);
        token.mint(to, amount);
    }
}
