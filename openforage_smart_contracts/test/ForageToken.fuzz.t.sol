// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/ForageTokenTestBase.sol";

// ============================================================
// TC-15: Fuzz Tests
// ============================================================
contract ForageToken_TC15_Fuzz is ForageTokenTestBase {
    function setUp() public override {
        super.setUp();
        _fundAlice(1000e18);
        _setupBurner();
        _setupLocker();
    }

    function testFuzz_transferWithLock(uint256 lockAmount, uint256 transferAmount) public {
        lockAmount = bound(lockAmount, 0, 1000e18);
        transferAmount = bound(transferAmount, 0, type(uint128).max); // cap to avoid overflow

        if (lockAmount > 0) {
            _lockTokens(alice, lockAmount);
        }

        uint256 unlocked = 1000e18 - lockAmount;

        if (transferAmount <= unlocked) {
            vm.prank(alice);
            token.transfer(bob, transferAmount);
            assertEq(token.balanceOf(alice), 1000e18 - transferAmount);
            assertEq(token.lockedBalance(alice), lockAmount);
        } else {
            vm.prank(alice);
            vm.expectRevert(
                abi.encodeWithSelector(
                    ForageToken.InsufficientUnlockedBalance.selector, alice, unlocked, transferAmount
                )
            );
            token.transfer(bob, transferAmount);
        }

        // Lock ceiling invariant
        assertLe(token.lockedBalance(alice), token.balanceOf(alice));
    }

    function testFuzz_burnWithLockAdjustment(uint256 lockAmount, uint256 burnAmount) public {
        lockAmount = bound(lockAmount, 0, 1000e18);
        burnAmount = bound(burnAmount, 1, 1000e18);

        if (lockAmount > 0) {
            _lockTokens(alice, lockAmount);
        }

        uint256 supplyBefore = token.totalSupply();

        vm.prank(authorizedBurner);
        token.burn(alice, burnAmount);

        uint256 newBalance = token.balanceOf(alice);
        uint256 newLocked = token.lockedBalance(alice);

        // Lock ceiling always holds
        assertLe(newLocked, newBalance, "Lock ceiling after burn");

        // Supply decreased by exact burn amount
        assertEq(token.totalSupply(), supplyBefore - burnAmount);

        // Lock adjustment logic
        if (newBalance < lockAmount) {
            assertEq(newLocked, newBalance, "Lock adjusted to new balance");
        } else {
            assertEq(newLocked, lockAmount, "Lock unchanged");
        }
    }

    function testFuzz_lockUnlockSequence(uint256 seed) public {
        uint256 numOps = bound(seed, 1, 50);

        for (uint256 i = 0; i < numOps; i++) {
            uint256 opSeed = uint256(keccak256(abi.encode(seed, i)));
            bool isLock = opSeed % 2 == 0;

            uint256 balance = token.balanceOf(alice);
            uint256 locked = token.lockedBalance(alice);
            uint256 unlocked = balance - locked;

            if (isLock && unlocked > 0) {
                uint256 amount = bound(uint256(keccak256(abi.encode(opSeed, "amount"))), 1, unlocked);
                _lockTokens(alice, amount);
            } else if (!isLock && locked > 0) {
                uint256 amount = bound(uint256(keccak256(abi.encode(opSeed, "amount"))), 1, locked);
                vm.prank(authorizedLocker);
                token.unlock(alice, amount);
            }

            // Invariant check at every step
            assertLe(token.lockedBalance(alice), token.balanceOf(alice), "Lock ceiling at every step");
        }
    }

    function testFuzz_delegationSequence(uint256 seed) public {
        uint256 numDelegations = bound(seed, 1, 20);
        address lastDelegatee;

        vm.prank(alice);
        token.delegate(alice); // self-delegate first

        for (uint256 i = 0; i < numDelegations; i++) {
            uint256 delegateSeed = uint256(keccak256(abi.encode(seed, i)));
            address delegatee = address(uint160(bound(delegateSeed, 1, type(uint160).max)));

            vm.prank(alice);
            token.delegate(delegatee);

            assertEq(token.delegates(alice), delegatee);
            assertEq(token.getVotes(delegatee), 1000e18);

            if (lastDelegatee != address(0) && lastDelegatee != delegatee) {
                assertEq(token.getVotes(lastDelegatee), 0);
            }

            lastDelegatee = delegatee;
        }
    }

    function testFuzz_transferPreservesLockInvariant(uint256 lockAmount, uint256 transferAmount) public {
        lockAmount = bound(lockAmount, 0, 1000e18);

        if (lockAmount > 0) {
            _lockTokens(alice, lockAmount);
        }

        uint256 unlocked = 1000e18 - lockAmount;
        transferAmount = bound(transferAmount, 0, unlocked);

        vm.prank(alice);
        token.transfer(bob, transferAmount);

        assertLe(token.lockedBalance(alice), token.balanceOf(alice), "Lock invariant after transfer");
    }

    function testFuzz_burnPreservesSupplyInvariant(uint256 burnAmount) public {
        burnAmount = bound(burnAmount, 1, 1000e18);

        uint256 supplyBefore = token.totalSupply();

        vm.prank(authorizedBurner);
        token.burn(alice, burnAmount);

        assertEq(token.totalSupply(), supplyBefore - burnAmount);
        assertLe(token.totalSupply(), 100_000_000e18);
    }

    function testFuzz_multiLockerLockUnlock(uint256 lockA, uint256 lockB, uint256 unlockA) public {
        _setupLocker2();

        lockA = bound(lockA, 1, 999e18);
        uint256 remaining = 1000e18 - lockA;
        if (remaining == 0) return;
        lockB = bound(lockB, 1, remaining);

        _lockTokensAs(authorizedLocker, alice, lockA);
        _lockTokensAs(authorizedLocker2, alice, lockB);

        // Invariant: sum of per-locker == aggregate
        assertEq(
            token.lockerBalance(alice, authorizedLocker) + token.lockerBalance(alice, authorizedLocker2),
            token.lockedBalance(alice),
            "per-locker sum must equal aggregate"
        );

        // Unlock part of locker A
        unlockA = bound(unlockA, 0, lockA);
        if (unlockA > 0) {
            vm.prank(authorizedLocker);
            token.unlock(alice, unlockA);
        }

        // Invariant still holds
        assertEq(
            token.lockerBalance(alice, authorizedLocker) + token.lockerBalance(alice, authorizedLocker2),
            token.lockedBalance(alice),
            "per-locker sum must equal aggregate after unlock"
        );
    }

    function testFuzz_burnWithMultiLockerAdjustment(uint256 lockA, uint256 lockB, uint256 burnAmount) public {
        _setupLocker2();

        lockA = bound(lockA, 1, 500e18);
        lockB = bound(lockB, 1, 500e18);
        if (lockA + lockB > 1000e18) return;

        _lockTokensAs(authorizedLocker, alice, lockA);
        _lockTokensAs(authorizedLocker2, alice, lockB);

        burnAmount = bound(burnAmount, 1, 1000e18);

        vm.prank(authorizedBurner);
        token.burn(alice, burnAmount);

        // Invariant: per-locker sum == aggregate
        assertEq(
            token.lockerBalance(alice, authorizedLocker) + token.lockerBalance(alice, authorizedLocker2),
            token.lockedBalance(alice),
            "per-locker sum must equal aggregate after burn"
        );

        // Lock ceiling
        assertLe(token.lockedBalance(alice), token.balanceOf(alice), "lock ceiling after burn");
    }

    function testFuzz_multiAccountLockTransfer(uint256 seed) public {
        _fundBob(500e18);

        uint256 numOps = bound(seed, 1, 30);

        address[2] memory accounts = [alice, bob];

        for (uint256 i = 0; i < numOps; i++) {
            uint256 opSeed = uint256(keccak256(abi.encode(seed, i)));
            uint256 opType = opSeed % 4; // 0=lock, 1=unlock, 2=transfer, 3=burn
            uint256 actorIdx = (opSeed >> 8) % 2;
            address actor = accounts[actorIdx];

            uint256 balance = token.balanceOf(actor);
            uint256 locked = token.lockedBalance(actor);
            uint256 unlocked = balance - locked;

            if (opType == 0 && unlocked > 0) {
                uint256 amount = bound(uint256(keccak256(abi.encode(opSeed, "a"))), 1, unlocked);
                _lockTokens(actor, amount);
            } else if (opType == 1 && locked > 0) {
                uint256 amount = bound(uint256(keccak256(abi.encode(opSeed, "a"))), 1, locked);
                vm.prank(authorizedLocker);
                token.unlock(actor, amount);
            } else if (opType == 2 && unlocked > 0) {
                address other = accounts[1 - actorIdx];
                uint256 amount = bound(uint256(keccak256(abi.encode(opSeed, "a"))), 1, unlocked);
                vm.prank(actor);
                token.transfer(other, amount);
            } else if (opType == 3 && balance > 0) {
                uint256 amount = bound(uint256(keccak256(abi.encode(opSeed, "a"))), 1, balance);
                vm.prank(authorizedBurner);
                token.burn(actor, amount);
            }

            // Invariants after every operation
            for (uint256 j = 0; j < 2; j++) {
                assertLe(token.lockedBalance(accounts[j]), token.balanceOf(accounts[j]), "Lock ceiling invariant");
                // Transferable balance = balance - locked (non-negative by lock ceiling)
                assertGe(
                    token.balanceOf(accounts[j]),
                    token.lockedBalance(accounts[j]),
                    "Transferable balance is non-negative"
                );
            }

            // Supply conservation: sum of all known holder balances == totalSupply
            uint256 totalBalances = token.balanceOf(alice) + token.balanceOf(bob) + token.balanceOf(teamVesting)
                + token.balanceOf(forageTreasury) + token.balanceOf(address(token));
            assertEq(totalBalances, token.totalSupply(), "Supply conservation");
        }

        assertLe(token.totalSupply(), 100_000_000e18, "Supply never exceeds initial");
    }
}
