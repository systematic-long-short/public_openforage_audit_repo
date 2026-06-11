// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/ForageTokenTestBase.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

// ============================================================
// TC-13: Attack Vector -- Implementation Direct Call
// ============================================================
contract ForageToken_TC13_ImplDirectCall is ForageTokenTestBase {
    function _getImplementationAddress() internal view returns (address) {
        // Read implementation address from ERC1967 slot
        bytes32 slot = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
        return address(uint160(uint256(vm.load(address(token), slot))));
    }

    function test_TC13_implementationInitReverts() public {
        address implAddr = _getImplementationAddress();
        ForageToken impl = ForageToken(implAddr);

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(teamVesting, forageTreasury, owner);
    }

    function test_TC13_implementationBurnReverts() public {
        address implAddr = _getImplementationAddress();
        ForageToken impl = ForageToken(implAddr);

        // Implementation not initialized: burner mapping is empty
        vm.expectRevert(abi.encodeWithSelector(ForageToken.UnauthorizedBurner.selector, address(this)));
        impl.burn(alice, 100e18);
    }

    function test_TC13_implementationLockReverts() public {
        address implAddr = _getImplementationAddress();
        ForageToken impl = ForageToken(implAddr);

        // Implementation not initialized: locker mapping is empty
        vm.expectRevert(abi.encodeWithSelector(ForageToken.UnauthorizedLocker.selector, address(this)));
        impl.lock(alice, 100e18);
    }

    function test_TC13_implementationReleaseTokensReverts() public {
        address implAddr = _getImplementationAddress();
        ForageToken impl = ForageToken(implAddr);

        // Implementation not initialized: owner is address(0)
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, address(this)));
        impl.releaseTokens(alice, 100e18);
    }

    function test_TC13_implementationSetBurnerReverts() public {
        address implAddr = _getImplementationAddress();
        ForageToken impl = ForageToken(implAddr);

        // Implementation not initialized: owner is address(0)
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, address(this)));
        impl.setAuthorizedBurner(alice, true);
    }

    function test_TC13_implementationHasNoBalance() public view {
        address implAddr = _getImplementationAddress();
        assertEq(token.balanceOf(implAddr), 0);
    }

    function test_TC13_unauthorizedUpgradeReverts() public {
        address malicious = makeAddr("maliciousImpl");

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, attacker));
        token.upgradeToAndCall(malicious, "");
    }

    function test_TC13_randomEOAUpgradeReverts() public {
        address randomUser = makeAddr("randomUser");
        address malicious = makeAddr("maliciousImpl");

        vm.prank(randomUser);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, randomUser));
        token.upgradeToAndCall(malicious, "");
    }

    function test_TC13_noDelegatecallOutsideUUPS() public view {
        // Scan deployed implementation bytecode for DELEGATECALL opcode (0xf4).
        // UUPS uses at most 1 delegatecall in the implementation. Any custom
        // delegatecall added to ForageToken would increase this count.
        // Uses opcode-aware walker: skips PUSH1-PUSH32 operand bytes so that
        // 0xf4 appearing as data (metadata hash, selectors) is not miscounted.
        address implAddr = _getImplementationAddress();
        bytes memory code = implAddr.code;

        uint256 delegatecallCount = 0;
        uint256 i = 0;
        while (i < code.length) {
            uint8 op = uint8(code[i]);
            if (op == 0xf4) {
                delegatecallCount++;
                i++;
            } else if (op >= 0x60 && op <= 0x7f) {
                // PUSH1 (0x60) through PUSH32 (0x7f): skip operand bytes
                i += 1 + (op - 0x5f);
            } else {
                i++;
            }
        }

        // OZ v5.6.1 UUPS path generates 4 DELEGATECALL opcodes via ERC1967Utils
        // and ERC20VotesUpgradeable inheritance chain. All are internal to OZ
        // library code. Any custom delegatecall would exceed this count.
        assertLe(delegatecallCount, 4, "Implementation contains more DELEGATECALL opcodes than expected from UUPS");
    }
}

// ============================================================
// TC-14: Attack Vector -- Flash Loan Governance
// ============================================================
contract ForageToken_TC14_FlashLoan is ForageTokenTestBase {
    function setUp() public override {
        super.setUp();
        _fundAlice(1_000_000e18);
    }

    function test_TC14_flashLoanedTokensNoVotingPower() public {
        // Alice self-delegates at timestamp T
        vm.prank(alice);
        token.delegate(alice);
        uint256 snapshotTime = block.timestamp;

        // Advance to voting period (timestamp-based clock)
        vm.warp(block.timestamp + 20);

        // Attacker acquires tokens after snapshot (simulating flash loan)
        vm.prank(forageTreasury);
        token.transfer(attacker, 29_000_000e18);

        vm.prank(attacker);
        token.delegate(attacker);

        // Attacker had no balance at snapshot
        assertEq(token.getPastVotes(attacker, snapshotTime), 0, "Flash loan: no voting power at snapshot");

        // Legitimate voter had balance at snapshot
        assertEq(token.getPastVotes(alice, snapshotTime), 1_000_000e18, "Alice: voting power at snapshot");
    }

    function test_TC14_snapshotImmutableAfterReturn() public {
        vm.prank(alice);
        token.delegate(alice);
        uint256 snapshotTime = block.timestamp;

        vm.warp(block.timestamp + 10);

        // Attacker gets tokens
        vm.prank(forageTreasury);
        token.transfer(attacker, 29_000_000e18);

        // Attacker returns tokens (completing "flash loan")
        vm.prank(attacker);
        token.transfer(forageTreasury, 29_000_000e18);

        // Snapshot is still 0 for attacker
        assertEq(token.getPastVotes(attacker, snapshotTime), 0, "Snapshot immutable after return");
    }

    function test_TC14_lockAfterSnapshotNoRetroactivePower() public {
        _setupLocker();

        vm.prank(alice);
        token.delegate(alice);
        uint256 snapshotTime = block.timestamp;

        vm.warp(block.timestamp + 10);

        // Attacker gets tokens after snapshot and locks them
        vm.prank(forageTreasury);
        token.transfer(attacker, 29_000_000e18);

        _lockTokens(attacker, 29_000_000e18);

        // Locking does NOT retroactively grant voting power
        assertEq(token.getPastVotes(attacker, snapshotTime), 0, "Lock: no retroactive voting power");
    }

    function test_TC14_delegationAfterSnapshotNoPower() public {
        // Attacker gets tokens BEFORE snapshot but doesn't delegate
        vm.prank(forageTreasury);
        token.transfer(attacker, 29_000_000e18);

        vm.warp(block.timestamp + 5);
        uint256 snapshotTime = block.timestamp;

        // Attacker delegates AFTER snapshot
        vm.warp(block.timestamp + 5);
        vm.prank(attacker);
        token.delegate(attacker);

        // No delegation at snapshot means no voting power
        assertEq(token.getPastVotes(attacker, snapshotTime), 0, "No delegation at snapshot = no power");
    }
}

/// @dev Malicious contract for delegatecall attack testing
contract MaliciousTarget {
    function maliciousInit() external {
        // Would try to corrupt storage if delegatecalled
    }
}
