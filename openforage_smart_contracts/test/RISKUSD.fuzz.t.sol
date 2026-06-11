// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/RISKUSDTestBase.sol";

// ============================================================
// TC-12: Fuzz Tests
// ============================================================
contract RISKUSD_TC12_Fuzz is RISKUSDTestBase {
    function setUp() public override {
        super.setUp();
        _setupMinter();
    }

    function testFuzz_mintAmounts(uint256 amount) public {
        amount = bound(amount, 1, type(uint128).max);

        uint256 supplyBefore = token.totalSupply();

        vm.prank(minterAddr);
        token.mint(alice, amount);

        assertEq(token.balanceOf(alice), amount);
        assertEq(token.totalSupply(), supplyBefore + amount);
    }

    function testFuzz_burnAmounts(uint256 mintAmount, uint256 burnAmount) public {
        mintAmount = bound(mintAmount, 1, type(uint128).max);
        burnAmount = bound(burnAmount, 1, mintAmount);

        vm.prank(minterAddr);
        token.mint(alice, mintAmount);

        uint256 supplyBefore = token.totalSupply();

        vm.prank(minterAddr);
        token.burn(alice, burnAmount);

        assertEq(token.balanceOf(alice), mintAmount - burnAmount);
        assertEq(token.totalSupply(), supplyBefore - burnAmount);
    }

    function testFuzz_transferSequences(uint256 seed) public {
        uint256 numOps = bound(seed, 1, 30);

        // Mint initial tokens to alice
        vm.prank(minterAddr);
        token.mint(alice, 10_000e6);

        address[3] memory accounts = [alice, bob, charlie];

        for (uint256 i = 0; i < numOps; i++) {
            uint256 opSeed = uint256(keccak256(abi.encode(seed, i)));
            uint256 fromIdx = opSeed % 3;
            uint256 toIdx = (opSeed >> 8) % 3;
            address from = accounts[fromIdx];
            address to = accounts[toIdx];

            uint256 balance = token.balanceOf(from);
            if (balance == 0) continue;

            uint256 amount = bound(uint256(keccak256(abi.encode(opSeed, "amt"))), 1, balance);

            vm.prank(from);
            token.transfer(to, amount);
        }

        // Supply conservation: sum of all balances == totalSupply
        uint256 totalBalances = token.balanceOf(alice) + token.balanceOf(bob) + token.balanceOf(charlie);
        assertEq(totalBalances, token.totalSupply(), "Supply conservation after transfers");
    }

    function testFuzz_mintBurnTransferInterleaved(uint256 seed) public {
        uint256 numOps = bound(seed, 1, 30);

        address[3] memory accounts = [alice, bob, charlie];

        // Mint initial tokens
        vm.prank(minterAddr);
        token.mint(alice, 5_000e6);

        for (uint256 i = 0; i < numOps; i++) {
            uint256 opSeed = uint256(keccak256(abi.encode(seed, i)));
            uint256 opType = opSeed % 3; // 0=mint, 1=burn, 2=transfer
            uint256 actorIdx = (opSeed >> 8) % 3;
            address actor = accounts[actorIdx];

            if (opType == 0) {
                uint256 amount = bound(uint256(keccak256(abi.encode(opSeed, "a"))), 1, 10_000e6);
                vm.prank(minterAddr);
                token.mint(actor, amount);
            } else if (opType == 1) {
                uint256 balance = token.balanceOf(actor);
                if (balance == 0) continue;
                uint256 amount = bound(uint256(keccak256(abi.encode(opSeed, "a"))), 1, balance);
                vm.prank(minterAddr);
                token.burn(actor, amount);
            } else {
                uint256 balance = token.balanceOf(actor);
                if (balance == 0) continue;
                uint256 amount = bound(uint256(keccak256(abi.encode(opSeed, "a"))), 1, balance);
                address other = accounts[(actorIdx + 1) % 3];
                vm.prank(actor);
                token.transfer(other, amount);
            }
        }

        // Supply conservation after all operations
        uint256 totalBalances = token.balanceOf(alice) + token.balanceOf(bob) + token.balanceOf(charlie);
        assertEq(totalBalances, token.totalSupply(), "Supply conservation after interleaved ops");
    }
}
