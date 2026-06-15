// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/ForageTokenTestBase.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import "@openzeppelin/contracts/governance/utils/IVotes.sol";

// ============================================================
// TC-01: Initialization and Constructor
// ============================================================
contract ForageToken_TC01_Initialization is ForageTokenTestBase {
    function test_TC01_name() public view {
        assertEq(token.name(), "Forage Token");
    }

    function test_TC01_symbol() public view {
        assertEq(token.symbol(), "FORAGE");
    }

    function test_TC01_decimals() public view {
        assertEq(token.decimals(), 18);
    }

    function test_TC01_totalSupply() public view {
        assertEq(token.totalSupply(), TOTAL_SUPPLY);
    }

    function test_TC01_teamVestingBalance() public view {
        assertEq(token.balanceOf(teamVesting), TEAM_ALLOCATION);
    }

    function test_TC01_forageTreasuryBalance() public view {
        assertEq(token.balanceOf(forageTreasury), FORAGE_TREASURY_ALLOCATION);
    }

    function test_TC01_contractHoldsZero() public view {
        assertEq(token.balanceOf(address(token)), 0);
    }

    function test_TC01_ownerIsSet() public view {
        assertEq(token.owner(), owner);
    }

    function test_TC01_allocationsSumToTotal() public view {
        assertEq(token.balanceOf(teamVesting) + token.balanceOf(forageTreasury), token.totalSupply());
    }

    function test_TC01_constantAllocationsSumToTotal() public view {
        assertEq(token.TEAM_VESTING_ALLOCATION() + token.FORAGE_TREASURY_ALLOCATION(), token.TOTAL_SUPPLY());
        assertEq(
            token.AGENT_ALLOCATION() + token.DEPOSITOR_ALLOCATION() + token.PARTNERSHIP_ALLOCATION(),
            token.FORAGE_TREASURY_ALLOCATION()
        );
    }

    function test_TC01_eip712Domain() public view {
        (, string memory name, string memory version, uint256 chainId, address verifyingContract,,) =
            token.eip712Domain();
        assertEq(name, "Forage Token", "EIP712 name");
        assertEq(version, "1", "EIP712 version");
        assertEq(chainId, block.chainid, "EIP712 chainId");
        assertEq(verifyingContract, address(token), "EIP712 verifyingContract");
    }

    function test_TC01_constantValues() public view {
        assertEq(token.TOTAL_SUPPLY(), 100_000_000e18);
        assertEq(token.TEAM_VESTING_ALLOCATION(), 20_000_000e18);
        assertEq(token.AGENT_ALLOCATION(), 30_000_000e18);
        assertEq(token.DEPOSITOR_ALLOCATION(), 10_000_000e18);
        assertEq(token.PARTNERSHIP_ALLOCATION(), 40_000_000e18);
        assertEq(token.FORAGE_TREASURY_ALLOCATION(), 80_000_000e18);
    }

    function test_TC01_doubleInitReverts() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        token.initialize(teamVesting, forageTreasury, owner);
    }

    function test_TC01_implementationInitReverts() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(teamVesting, forageTreasury, owner);
    }

    function test_TC01_zeroTeamVestingReverts() public {
        ForageToken impl = new ForageToken();
        vm.expectRevert(ForageToken.ZeroAddress.selector);
        new ERC1967Proxy(address(impl), abi.encodeCall(ForageToken.initialize, (address(0), forageTreasury, owner)));
    }

    function test_TC01_zeroForageTreasuryReverts() public {
        ForageToken impl = new ForageToken();
        vm.expectRevert(ForageToken.ZeroAddress.selector);
        new ERC1967Proxy(address(impl), abi.encodeCall(ForageToken.initialize, (teamVesting, address(0), owner)));
    }

    function test_TC01_zeroOwnerReverts() public {
        ForageToken impl = new ForageToken();
        vm.expectRevert(ForageToken.ZeroAddress.selector);
        new ERC1967Proxy(
            address(impl), abi.encodeCall(ForageToken.initialize, (teamVesting, forageTreasury, address(0)))
        );
    }

    function test_TC01_initTransferEvents() public {
        ForageToken impl = new ForageToken();
        vm.recordLogs();
        new ERC1967Proxy(address(impl), abi.encodeCall(ForageToken.initialize, (teamVesting, forageTreasury, owner)));

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 transferSig = keccak256("Transfer(address,address,uint256)");

        uint256 transferCount;
        bool[2] memory found;
        address[2] memory expectedRecipients = [teamVesting, forageTreasury];
        uint256[2] memory expectedAmounts = [TEAM_ALLOCATION, FORAGE_TREASURY_ALLOCATION];

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == transferSig) {
                transferCount++;
                address from = address(uint160(uint256(logs[i].topics[1])));
                address to = address(uint160(uint256(logs[i].topics[2])));
                uint256 value = abi.decode(logs[i].data, (uint256));

                assertEq(from, address(0), "Transfer must be from zero (mint)");

                for (uint256 j = 0; j < 2; j++) {
                    if (to == expectedRecipients[j]) {
                        assertEq(value, expectedAmounts[j], "Incorrect allocation amount");
                        found[j] = true;
                    }
                }
            }
        }
        assertEq(transferCount, 2, "Expected 2 Transfer events during init");
        for (uint256 k = 0; k < 2; k++) {
            assertTrue(found[k], "Missing Transfer event for a recipient");
        }
    }
}

// ============================================================
// TC-02: Transfer with Lock Enforcement
// ============================================================
contract ForageToken_TC02_TransferLock is ForageTokenTestBase {
    function setUp() public override {
        super.setUp();
        _fundAlice(1000e18);
        _setupLocker();
    }

    function test_TC02_transferFullUnlockedBalance() public {
        vm.prank(alice);
        token.transfer(bob, 1000e18);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 1000e18);
    }

    function test_TC02_transferWithPartialLock() public {
        _lockTokens(alice, 400e18);

        vm.prank(alice);
        token.transfer(bob, 600e18);
        assertEq(token.balanceOf(alice), 400e18);
        assertEq(token.lockedBalance(alice), 400e18);
    }

    function test_TC02_transferExceedingUnlockedReverts() public {
        _lockTokens(alice, 400e18);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ForageToken.InsufficientUnlockedBalance.selector, alice, 600e18, 601e18));
        token.transfer(bob, 601e18);
    }

    function test_TC02_transferWhenFullyLockedReverts() public {
        _lockTokens(alice, 1000e18);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ForageToken.InsufficientUnlockedBalance.selector, alice, 0, 1));
        token.transfer(bob, 1);
    }

    function test_TC02_locksDoNotTravel() public {
        _lockTokens(alice, 400e18);

        vm.prank(alice);
        token.transfer(bob, 500e18);

        assertEq(token.lockedBalance(bob), 0, "Recipient should have no lock");
        assertEq(token.lockedBalance(alice), 400e18, "Sender lock unchanged");

        // Bob can transfer his full balance freely
        vm.prank(bob);
        token.transfer(charlie, 500e18);
        assertEq(token.balanceOf(charlie), 500e18);
    }

    function test_TC02_transferFromRespectsLock() public {
        _lockTokens(alice, 400e18);

        vm.prank(alice);
        token.approve(charlie, 700e18);

        // transferFrom within unlocked balance
        vm.prank(charlie);
        token.transferFrom(alice, bob, 600e18);
        assertEq(token.balanceOf(alice), 400e18);

        // transferFrom exceeding unlocked balance
        vm.prank(charlie);
        vm.expectRevert(abi.encodeWithSelector(ForageToken.InsufficientUnlockedBalance.selector, alice, 0, 1));
        token.transferFrom(alice, bob, 1);
    }

    function test_TC02_transferZeroAmount() public {
        vm.prank(alice);
        token.transfer(bob, 0);
        assertEq(token.balanceOf(alice), 1000e18);
    }

    function test_TC02_transferToSelfWithLock() public {
        _lockTokens(alice, 600e18);

        vm.prank(alice);
        token.transfer(alice, 400e18); // unlocked portion
        assertEq(token.balanceOf(alice), 1000e18);
    }

    function test_TC02_transferEmitsEvent() public {
        vm.prank(alice);
        vm.expectEmit(true, true, false, true);
        emit IERC20.Transfer(alice, bob, 100e18);
        token.transfer(bob, 100e18);
    }
}

// ============================================================
// TC-03: Delegation Tests
// ============================================================
contract ForageToken_TC03_Delegation is ForageTokenTestBase {
    function setUp() public override {
        super.setUp();
        _fundAlice(1000e18);
        _fundBob(500e18);
    }

    function test_TC03_beforeDelegation() public view {
        assertEq(token.getVotes(alice), 0, "No votes before delegation");
        assertEq(token.delegates(alice), address(0), "No delegate before delegation");
    }

    function test_TC03_selfDelegation() public {
        vm.prank(alice);
        vm.expectEmit(true, true, true, false);
        emit IVotes.DelegateChanged(alice, address(0), alice);
        vm.expectEmit(true, false, false, true);
        emit IVotes.DelegateVotesChanged(alice, 0, 1000e18);
        token.delegate(alice);

        assertEq(token.getVotes(alice), 1000e18);
        assertEq(token.delegates(alice), alice);
    }

    function test_TC03_delegateToAnother() public {
        vm.prank(alice);
        token.delegate(alice); // self-delegate first

        vm.prank(alice);
        vm.expectEmit(true, true, true, false);
        emit IVotes.DelegateChanged(alice, alice, bob);
        token.delegate(bob);

        assertEq(token.getVotes(alice), 0);
        assertEq(token.getVotes(bob), 1000e18);
        assertEq(token.delegates(alice), bob);
    }

    function test_TC03_multipleDelegators() public {
        vm.prank(alice);
        token.delegate(charlie);

        vm.prank(bob);
        token.delegate(charlie);

        assertEq(token.getVotes(charlie), 1500e18); // 1000 + 500
        assertEq(token.delegates(alice), charlie);
        assertEq(token.delegates(bob), charlie);
    }

    function test_TC03_transferAfterDelegation() public {
        vm.prank(alice);
        token.delegate(bob);
        uint256 bobVotesBefore = token.getVotes(bob);

        vm.prank(alice);
        vm.expectEmit(true, false, false, true);
        emit IVotes.DelegateVotesChanged(bob, bobVotesBefore, bobVotesBefore - 300e18);
        token.transfer(charlie, 300e18);

        assertEq(token.getVotes(bob), bobVotesBefore - 300e18);
    }

    function test_TC03_noAutoDelegationOnTransfer() public {
        vm.prank(alice);
        token.transfer(charlie, 300e18);

        assertEq(token.delegates(charlie), address(0), "No auto-delegation");
        assertEq(token.getVotes(charlie), 0, "No votes without delegation");
    }

    function test_TC03_delegateToZeroAddress() public {
        vm.prank(alice);
        token.delegate(alice); // self-delegate
        assertEq(token.getVotes(alice), 1000e18);

        vm.prank(alice);
        token.delegate(address(0));
        assertEq(token.getVotes(alice), 0);
    }

    function test_TC03_delegateWithZeroBalance() public {
        address zeroBalAcc = makeAddr("zeroBalance");
        vm.prank(zeroBalAcc);
        token.delegate(alice);
        assertEq(token.delegates(zeroBalAcc), alice);
    }
}

// ============================================================
// TC-04: DelegateBySig Disabled
// ============================================================
contract ForageToken_TC04_DelegateBySig is ForageTokenTestBase {
    function test_TC04_delegateBySigReverts() public {
        vm.expectRevert(ForageToken.DelegationBySignatureDisabled.selector);
        token.delegateBySig(bob, 0, block.timestamp + 100, 27, bytes32(0), bytes32(0));
    }

    function test_TC04_delegateBySigGarbageParams() public {
        vm.expectRevert(ForageToken.DelegationBySignatureDisabled.selector);
        token.delegateBySig(address(0), 0, 0, 0, bytes32(0), bytes32(0));
    }

    function test_TC04_delegateBySigFabricatedSig() public {
        vm.expectRevert(ForageToken.DelegationBySignatureDisabled.selector);
        token.delegateBySig(bob, 0, block.timestamp + 100, 27, bytes32(uint256(1)), bytes32(uint256(2)));
    }

    function test_TC04_validSignatureReverts() public {
        uint256 signerPk = 0xA11CE;
        address signer = vm.addr(signerPk);

        // Construct a valid EIP-712 delegation digest
        bytes32 DELEGATION_TYPEHASH = keccak256("Delegation(address delegatee,uint256 nonce,uint256 expiry)");
        uint256 nonce = 0;
        uint256 expiry = block.timestamp + 1000;

        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("Forage Token"),
                keccak256("1"),
                block.chainid,
                address(token)
            )
        );
        bytes32 structHash = keccak256(abi.encode(DELEGATION_TYPEHASH, bob, nonce, expiry));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, digest);

        // Even with a cryptographically valid signature, delegateBySig must revert
        vm.prank(signer);
        vm.expectRevert(ForageToken.DelegationBySignatureDisabled.selector);
        token.delegateBySig(bob, nonce, expiry, v, r, s);
    }

    function test_TC04_noStateChange() public {
        _fundAlice(1000e18);

        vm.prank(alice);
        token.delegate(alice);
        uint256 votesBefore = token.getVotes(alice);

        vm.expectRevert(ForageToken.DelegationBySignatureDisabled.selector);
        token.delegateBySig(bob, 0, block.timestamp + 100, 27, bytes32(0), bytes32(0));

        assertEq(token.getVotes(alice), votesBefore, "Votes unchanged after revert");
        assertEq(token.delegates(alice), alice, "Delegate unchanged after revert");
    }

    function test_TC04_noEventsOnRevert() public {
        vm.recordLogs();
        vm.expectRevert(ForageToken.DelegationBySignatureDisabled.selector);
        token.delegateBySig(bob, 0, block.timestamp + 100, 27, bytes32(0), bytes32(0));

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 0, "No events should be emitted on revert");
    }
}

// ============================================================
// TC-05: Burn Tests
// ============================================================
contract ForageToken_TC05_Burn is ForageTokenTestBase {
    function setUp() public override {
        super.setUp();
        _fundAlice(1000e18);
        _setupBurner();
        _setupLocker();
    }

    function test_TC05_authorizedBurnNoLocks() public {
        uint256 supplyBefore = token.totalSupply();

        vm.prank(authorizedBurner);
        vm.expectEmit(true, true, false, true);
        emit IERC20.Transfer(alice, address(0), 100e18);
        vm.expectEmit(true, true, true, true);
        emit ForageToken.ForageBurned(alice, 100e18, authorizedBurner);
        token.burn(alice, 100e18);

        assertEq(token.balanceOf(alice), 900e18);
        assertEq(token.totalSupply(), supplyBefore - 100e18);
    }

    function test_TC05_burnAllNoLocks() public {
        uint256 supplyBefore = token.totalSupply();

        vm.prank(authorizedBurner);
        token.burn(alice, 1000e18);

        assertEq(token.balanceOf(alice), 0);
        assertEq(token.totalSupply(), supplyBefore - 1000e18);
    }

    function test_TC05_burnWithLockCeilingAdjustment() public {
        _lockTokens(alice, 600e18);

        vm.prank(authorizedBurner);
        token.burn(alice, 500e18);

        // balance = 500e18, old lock = 600e18 => lock adjusted to 500e18
        assertEq(token.balanceOf(alice), 500e18);
        assertEq(token.lockedBalance(alice), 500e18);
    }

    function test_TC05_burnToZeroWithLock() public {
        _lockTokens(alice, 800e18);

        vm.prank(authorizedBurner);
        token.burn(alice, 1000e18);

        assertEq(token.balanceOf(alice), 0);
        assertEq(token.lockedBalance(alice), 0);
    }

    function test_TC05_burnNoLockAdjustmentNeeded() public {
        _lockTokens(alice, 200e18);

        vm.prank(authorizedBurner);
        token.burn(alice, 300e18);

        // balance = 700e18, lock = 200e18 => no adjustment needed
        assertEq(token.balanceOf(alice), 700e18);
        assertEq(token.lockedBalance(alice), 200e18);
    }

    function test_TC05_unauthorizedBurnReverts() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(ForageToken.UnauthorizedBurner.selector, attacker));
        token.burn(alice, 100e18);
    }

    function test_TC05_burnZeroAmountReverts() public {
        vm.prank(authorizedBurner);
        vm.expectRevert(ForageToken.ZeroAmount.selector);
        token.burn(alice, 0);
    }

    function test_TC05_burnFromZeroAddressReverts() public {
        vm.prank(authorizedBurner);
        vm.expectRevert(ForageToken.ZeroAddress.selector);
        token.burn(address(0), 100e18);
    }

    function test_TC05_burnExceedingBalanceReverts() public {
        vm.prank(authorizedBurner);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 1000e18, 1001e18));
        token.burn(alice, 1001e18);
    }

    function test_TC05_revokedBurnerReverts() public {
        vm.prank(owner);
        token.setAuthorizedBurner(authorizedBurner, false);

        vm.prank(authorizedBurner);
        vm.expectRevert(abi.encodeWithSelector(ForageToken.UnauthorizedBurner.selector, authorizedBurner));
        token.burn(alice, 100e18);
    }

    function test_TC05_burnAdjustsVotingCheckpoints() public {
        vm.prank(alice);
        token.delegate(alice);
        assertEq(token.getVotes(alice), 1000e18);

        vm.prank(authorizedBurner);
        vm.expectEmit(true, false, false, true);
        emit IVotes.DelegateVotesChanged(alice, 1000e18, 800e18);
        token.burn(alice, 200e18);

        assertEq(token.getVotes(alice), 800e18);
    }

    /// @dev OF-001: Burn with lock ceiling adjustment MUST emit ForageUnlocked with locker address
    function test_TC05_burn_withLockAdjustment_emitsForageUnlocked() public {
        _lockTokens(alice, 600e18);

        // Burning 500e18: newBalance=500e18 < locked=600e18 → ceiling reduces by 100e18
        // Per-locker: event references the locker who created the lock, not the burner
        vm.prank(authorizedBurner);
        vm.expectEmit(true, true, true, true);
        emit ForageToken.ForageUnlocked(alice, 100e18, authorizedLocker);
        token.burn(alice, 500e18);

        assertEq(token.lockedBalance(alice), 500e18);
        assertEq(token.lockerBalance(alice, authorizedLocker), 500e18);
    }

    /// @dev OF-001: Burn to zero with locks MUST emit ForageUnlocked for full locked amount
    function test_TC05_burn_toZero_withLocks_emitsForageUnlocked() public {
        _lockTokens(alice, 800e18);

        // Burning all 1000e18: newBalance=0 < locked=800e18 → ceiling reduces by 800e18
        // Per-locker: event references the locker who created the lock, not the burner
        vm.prank(authorizedBurner);
        vm.expectEmit(true, true, true, true);
        emit ForageToken.ForageUnlocked(alice, 800e18, authorizedLocker);
        token.burn(alice, 1000e18);

        assertEq(token.lockedBalance(alice), 0);
        assertEq(token.balanceOf(alice), 0);
    }

    /// @dev OF-001: Burn that does NOT trigger lock adjustment must NOT emit ForageUnlocked
    function test_TC05_burn_noLockAdjustment_noForageUnlocked() public {
        _lockTokens(alice, 200e18);

        // Burning 300e18: newBalance=700e18 > locked=200e18 → no ceiling adjustment
        vm.recordLogs();
        vm.prank(authorizedBurner);
        token.burn(alice, 300e18);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 forageUnlockedSig = keccak256("ForageUnlocked(address,uint256,address)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == forageUnlockedSig) {
                revert("ForageUnlocked should NOT be emitted when no lock adjustment occurs");
            }
        }

        assertEq(token.lockedBalance(alice), 200e18);
    }

    /// @dev OF-001: Burn on account with no locks must NOT emit ForageUnlocked
    function test_TC05_burn_noLocks_noForageUnlocked() public {
        // Alice has no locks — burn should emit only Transfer + ForageBurned
        vm.recordLogs();
        vm.prank(authorizedBurner);
        token.burn(alice, 100e18);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 forageUnlockedSig = keccak256("ForageUnlocked(address,uint256,address)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == forageUnlockedSig) {
                revert("ForageUnlocked should NOT be emitted when account has no locks");
            }
        }

        assertEq(token.balanceOf(alice), 900e18);
    }
}

// ============================================================
// TC-06: Lock and Unlock Tests
// ============================================================
contract ForageToken_TC06_LockUnlock is ForageTokenTestBase {
    function setUp() public override {
        super.setUp();
        _fundAlice(1000e18);
        _setupLocker();
    }

    // --- Lock tests ---

    function test_TC06_lockBasic() public {
        vm.prank(authorizedLocker);
        vm.expectEmit(true, true, true, true);
        emit ForageToken.ForageLocked(alice, 300e18, authorizedLocker);
        token.lock(alice, 300e18);

        assertEq(token.lockedBalance(alice), 300e18);
    }

    function test_TC06_lockCumulative() public {
        _lockTokens(alice, 300e18);
        _lockTokens(alice, 200e18);
        assertEq(token.lockedBalance(alice), 500e18);
    }

    function test_TC06_lockEntireBalance() public {
        _lockTokens(alice, 1000e18);
        assertEq(token.lockedBalance(alice), 1000e18);

        // Alice cannot transfer
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ForageToken.InsufficientUnlockedBalance.selector, alice, 0, 1));
        token.transfer(bob, 1);
    }

    function test_TC06_lockExceedingUnlockedReverts() public {
        _lockTokens(alice, 1000e18);

        vm.prank(authorizedLocker);
        vm.expectRevert(abi.encodeWithSelector(ForageToken.InsufficientUnlockedBalance.selector, alice, 0, 1));
        token.lock(alice, 1);
    }

    function test_TC06_lockVotingPowerPreserved() public {
        vm.prank(alice);
        token.delegate(alice);
        assertEq(token.getVotes(alice), 1000e18);

        _lockTokens(alice, 500e18);
        assertEq(token.getVotes(alice), 1000e18, "Voting power unchanged after lock");
    }

    function test_TC06_delegationAfterLock() public {
        _lockTokens(alice, 500e18);

        vm.prank(alice);
        token.delegate(bob);
        assertEq(token.getVotes(bob), 1000e18, "Full balance delegated including locked");
    }

    function test_TC06_lockZeroAmountReverts() public {
        vm.prank(authorizedLocker);
        vm.expectRevert(ForageToken.ZeroAmount.selector);
        token.lock(alice, 0);
    }

    function test_TC06_lockZeroAddressReverts() public {
        vm.prank(authorizedLocker);
        vm.expectRevert(ForageToken.ZeroAddress.selector);
        token.lock(address(0), 100e18);
    }

    function test_TC06_unauthorizedLockReverts() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(ForageToken.UnauthorizedLocker.selector, attacker));
        token.lock(alice, 100e18);
    }

    // --- Unlock tests ---

    function test_TC06_unlockBasic() public {
        _lockTokens(alice, 500e18);

        vm.prank(authorizedLocker);
        vm.expectEmit(true, true, true, true);
        emit ForageToken.ForageUnlocked(alice, 200e18, authorizedLocker);
        token.unlock(alice, 200e18);

        assertEq(token.lockedBalance(alice), 300e18);
    }

    function test_TC06_unlockEntireLockedBalance() public {
        _lockTokens(alice, 500e18);

        vm.prank(authorizedLocker);
        token.unlock(alice, 500e18);

        assertEq(token.lockedBalance(alice), 0);

        // Alice can transfer full balance
        vm.prank(alice);
        token.transfer(bob, 1000e18);
        assertEq(token.balanceOf(bob), 1000e18);
    }

    function test_TC06_unlockExceedingLockedReverts() public {
        _lockTokens(alice, 500e18);

        vm.prank(authorizedLocker);
        vm.expectRevert(abi.encodeWithSelector(ForageToken.InsufficientLockedBalance.selector, alice, 500e18, 501e18));
        token.unlock(alice, 501e18);
    }

    function test_TC06_unlockZeroAmountReverts() public {
        vm.prank(authorizedLocker);
        vm.expectRevert(ForageToken.ZeroAmount.selector);
        token.unlock(alice, 0);
    }

    function test_TC06_unlockZeroAddressReverts() public {
        vm.prank(authorizedLocker);
        vm.expectRevert(ForageToken.ZeroAddress.selector);
        token.unlock(address(0), 100e18);
    }

    function test_TC06_unauthorizedUnlockReverts() public {
        _lockTokens(alice, 500e18);

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(ForageToken.UnauthorizedLocker.selector, attacker));
        token.unlock(alice, 100e18);
    }

    function test_TC06_revokedLockerReverts() public {
        vm.prank(owner);
        token.setAuthorizedLocker(authorizedLocker, false);

        vm.prank(authorizedLocker);
        vm.expectRevert(abi.encodeWithSelector(ForageToken.UnauthorizedLocker.selector, authorizedLocker));
        token.lock(alice, 100e18);
    }

    // --- Lock + Transfer interaction ---

    function test_TC06_lockTransferInteraction() public {
        _lockTokens(alice, 600e18);

        vm.prank(alice);
        token.transfer(bob, 400e18);
        assertEq(token.balanceOf(alice), 600e18);
        assertEq(token.lockedBalance(alice), 600e18);

        // Alice cannot transfer any more
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ForageToken.InsufficientUnlockedBalance.selector, alice, 0, 1));
        token.transfer(bob, 1);
    }

    function test_TC06_unlockThenTransfer() public {
        _lockTokens(alice, 600e18);

        vm.prank(alice);
        token.transfer(bob, 400e18); // use all unlocked

        // Unlock 100e18
        vm.prank(authorizedLocker);
        token.unlock(alice, 100e18);

        // Now alice can transfer up to 100e18
        vm.prank(alice);
        token.transfer(bob, 100e18);
        assertEq(token.balanceOf(alice), 500e18);
    }
}

// ============================================================
// TC-07: Authorization Management
// ============================================================
contract ForageToken_TC07_AuthManagement is ForageTokenTestBase {
    function setUp() public override {
        super.setUp();
        _fundAlice(1000e18);
    }

    function test_TC07_grantBurner() public {
        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit ForageToken.AuthorizedBurnerUpdated(authorizedBurner, true);
        token.setAuthorizedBurner(authorizedBurner, true);

        // Verify can burn
        vm.prank(authorizedBurner);
        token.burn(alice, 10e18);
        assertEq(token.balanceOf(alice), 990e18);
    }

    function test_TC07_revokeBurner() public {
        _setupBurner();

        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit ForageToken.AuthorizedBurnerUpdated(authorizedBurner, false);
        token.setAuthorizedBurner(authorizedBurner, false);

        vm.prank(authorizedBurner);
        vm.expectRevert(abi.encodeWithSelector(ForageToken.UnauthorizedBurner.selector, authorizedBurner));
        token.burn(alice, 10e18);
    }

    function test_TC07_grantLocker() public {
        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit ForageToken.AuthorizedLockerUpdated(authorizedLocker, true);
        token.setAuthorizedLocker(authorizedLocker, true);

        vm.prank(authorizedLocker);
        token.lock(alice, 100e18);
        assertEq(token.lockedBalance(alice), 100e18);
    }

    function test_TC07_revokeLocker() public {
        _setupLocker();

        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit ForageToken.AuthorizedLockerUpdated(authorizedLocker, false);
        token.setAuthorizedLocker(authorizedLocker, false);

        vm.prank(authorizedLocker);
        vm.expectRevert(abi.encodeWithSelector(ForageToken.UnauthorizedLocker.selector, authorizedLocker));
        token.lock(alice, 100e18);
    }

    function test_TC07_nonOwnerSetBurnerReverts() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, attacker));
        token.setAuthorizedBurner(authorizedBurner, true);
    }

    function test_TC07_nonOwnerSetLockerReverts() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, attacker));
        token.setAuthorizedLocker(authorizedLocker, true);
    }

    function test_TC07_zeroBurnerAddressReverts() public {
        vm.prank(owner);
        vm.expectRevert(ForageToken.ZeroAddress.selector);
        token.setAuthorizedBurner(address(0), true);
    }

    function test_TC07_zeroLockerAddressReverts() public {
        vm.prank(owner);
        vm.expectRevert(ForageToken.ZeroAddress.selector);
        token.setAuthorizedLocker(address(0), true);
    }

    function test_TC07_multipleBurners() public {
        address burner2 = makeAddr("burner2");
        vm.startPrank(owner);
        token.setAuthorizedBurner(authorizedBurner, true);
        token.setAuthorizedBurner(burner2, true);
        vm.stopPrank();

        vm.prank(authorizedBurner);
        token.burn(alice, 10e18);

        vm.prank(burner2);
        token.burn(alice, 10e18);

        assertEq(token.balanceOf(alice), 980e18);
    }

    function test_TC07_revokeOneBurnerOthersRemain() public {
        address burner2 = makeAddr("burner2");
        vm.startPrank(owner);
        token.setAuthorizedBurner(authorizedBurner, true);
        token.setAuthorizedBurner(burner2, true);
        token.setAuthorizedBurner(authorizedBurner, false);
        vm.stopPrank();

        vm.prank(authorizedBurner);
        vm.expectRevert(abi.encodeWithSelector(ForageToken.UnauthorizedBurner.selector, authorizedBurner));
        token.burn(alice, 10e18);

        // burner2 still works
        vm.prank(burner2);
        token.burn(alice, 10e18);
        assertEq(token.balanceOf(alice), 990e18);
    }

    function test_TC07_idempotentGrant() public {
        _setupBurner();

        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit ForageToken.AuthorizedBurnerUpdated(authorizedBurner, true);
        token.setAuthorizedBurner(authorizedBurner, true); // already true
    }

    function test_TC07_idempotentRevoke() public {
        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit ForageToken.AuthorizedBurnerUpdated(authorizedBurner, false);
        token.setAuthorizedBurner(authorizedBurner, false); // already false
    }
}

// ============================================================
// TC-08: ReleaseTokens
// ============================================================
contract ForageToken_TC08_ReleaseTokens is ForageTokenTestBase {
    function setUp() public override {
        super.setUp();
        // Send some FORAGE to the token contract (simulating accidental transfer)
        vm.prank(forageTreasury);
        token.transfer(address(token), 100e18);
    }

    function test_TC08_releaseTokens() public {
        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit ForageToken.TokensReleased(alice, 50e18);
        token.releaseTokens(alice, 50e18);

        assertEq(token.balanceOf(alice), 50e18);
        assertEq(token.balanceOf(address(token)), 50e18);
    }

    function test_TC08_releaseRemainingBalance() public {
        vm.prank(owner);
        token.releaseTokens(alice, 50e18);

        vm.prank(owner);
        token.releaseTokens(alice, 50e18);

        assertEq(token.balanceOf(address(token)), 0);
    }

    function test_TC08_releaseExceedingBalanceReverts() public {
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(token), 100e18, 101e18)
        );
        token.releaseTokens(alice, 101e18);
    }

    function test_TC08_releaseToZeroAddressReverts() public {
        vm.prank(owner);
        vm.expectRevert(ForageToken.ZeroAddress.selector);
        token.releaseTokens(address(0), 50e18);
    }

    function test_TC08_releaseZeroAmountReverts() public {
        vm.prank(owner);
        vm.expectRevert(ForageToken.ZeroAmount.selector);
        token.releaseTokens(alice, 0);
    }

    function test_TC08_nonOwnerReverts() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, attacker));
        token.releaseTokens(alice, 50e18);
    }

    function test_TC08_onlyTransfersFromContract() public {
        uint256 forageTreasuryBefore = token.balanceOf(forageTreasury);

        vm.prank(owner);
        token.releaseTokens(alice, 50e18);

        // Other addresses unaffected
        assertEq(token.balanceOf(forageTreasury), forageTreasuryBefore);
    }
}

// ============================================================
// TC-16: Per-Locker Namespace Tests (OF-001 fix)
// ============================================================
contract ForageToken_TC16_PerLocker is ForageTokenTestBase {
    function setUp() public override {
        super.setUp();
        _fundAlice(1000e18);
        _setupLocker();
        _setupLocker2();
        _setupBurner();
    }

    /// @dev Verify per-locker vs aggregate balance views
    function test_TC16_lockerBalanceView() public {
        _lockTokensAs(authorizedLocker, alice, 300e18);

        assertEq(token.lockedBalance(alice), 300e18, "aggregate should be 300");
        assertEq(token.lockerBalance(alice, authorizedLocker), 300e18, "locker1 should be 300");
        assertEq(token.lockerBalance(alice, authorizedLocker2), 0, "locker2 should be 0");
    }

    /// @dev Two lockers lock independently; verify independent balances
    function test_TC16_multiLockerLock() public {
        _lockTokensAs(authorizedLocker, alice, 300e18);
        _lockTokensAs(authorizedLocker2, alice, 200e18);

        assertEq(token.lockedBalance(alice), 500e18, "aggregate should be 500");
        assertEq(token.lockerBalance(alice, authorizedLocker), 300e18, "locker1 should be 300");
        assertEq(token.lockerBalance(alice, authorizedLocker2), 200e18, "locker2 should be 200");
    }

    /// @dev Locker A cannot unlock locker B's reservation
    function test_TC16_lockerCannotUnlockOthersReservation() public {
        _lockTokensAs(authorizedLocker, alice, 300e18);
        _lockTokensAs(authorizedLocker2, alice, 200e18);

        // Locker A tries to unlock 400 (more than its own 300)
        vm.prank(authorizedLocker);
        vm.expectRevert(abi.encodeWithSelector(ForageToken.InsufficientLockedBalance.selector, alice, 300e18, 400e18));
        token.unlock(alice, 400e18);
    }

    /// @dev Locker A unlocks its own balance; aggregate drops correctly
    function test_TC16_lockerUnlockExactlyOwnBalance() public {
        _lockTokensAs(authorizedLocker, alice, 300e18);
        _lockTokensAs(authorizedLocker2, alice, 200e18);

        // Locker A unlocks exactly its 300
        vm.prank(authorizedLocker);
        token.unlock(alice, 300e18);

        assertEq(token.lockedBalance(alice), 200e18, "aggregate should be 200");
        assertEq(token.lockerBalance(alice, authorizedLocker), 0, "locker1 should be 0");
        assertEq(token.lockerBalance(alice, authorizedLocker2), 200e18, "locker2 should be 200");
    }

    /// @dev OF-15-020: setLockExempt(true) reverts when account has active locks.
    /// Must unlock via authorized lockers first, then setLockExempt succeeds.
    function test_TC16_setLockExemptZerosPerLockerBalances() public {
        _lockTokensAs(authorizedLocker, alice, 300e18);
        _lockTokensAs(authorizedLocker2, alice, 200e18);

        // OF-15-020: setLockExempt(true) now reverts if active locks exist
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ForageToken.AccountHasActiveLocks.selector, alice, 500e18));
        token.setLockExempt(alice, true);

        // Unlock via authorized lockers (emergencyUnlock only works on deauthorized lockers)
        vm.prank(authorizedLocker);
        token.unlock(alice, 300e18);
        vm.prank(authorizedLocker2);
        token.unlock(alice, 200e18);

        // Now setLockExempt(true) succeeds
        vm.prank(owner);
        token.setLockExempt(alice, true);

        assertEq(token.lockedBalance(alice), 0, "aggregate should be 0");
        assertEq(token.lockerBalance(alice, authorizedLocker), 0, "locker1 should be 0");
        assertEq(token.lockerBalance(alice, authorizedLocker2), 0, "locker2 should be 0");
    }

    /// @dev OF-15-020: setLockExempt(true) reverts when locks exist, then succeeds after unlock.
    function test_TC16_setLockExemptEmitsPerLockerEvents() public {
        _lockTokensAs(authorizedLocker, alice, 300e18);
        _lockTokensAs(authorizedLocker2, alice, 200e18);

        // Unlock via authorized lockers (emergencyUnlock only works on deauthorized lockers)
        vm.prank(authorizedLocker);
        token.unlock(alice, 300e18);
        vm.prank(authorizedLocker2);
        token.unlock(alice, 200e18);

        vm.prank(owner);
        token.setLockExempt(alice, true);

        // After unlock + exempt, verify exemption was set by attempting a lock
        // (which should revert with LockExemptAccount)
        vm.prank(authorizedLocker);
        vm.expectRevert(ForageToken.LockExemptAccount.selector);
        token.lock(alice, 1);
    }

    /// @dev Burn pro-rata across two lockers
    function test_TC16_burnProRataAcrossLockers() public {
        _lockTokensAs(authorizedLocker, alice, 600e18);
        _lockTokensAs(authorizedLocker2, alice, 400e18);
        // aggregate = 1000, balance = 1000

        // Burn 500 → newBalance=500, locked=1000, excess=500
        // Pro-rata: locker1 reduces by 600*500/1000=300, locker2 absorbs rest=200
        vm.prank(authorizedBurner);
        token.burn(alice, 500e18);

        assertEq(token.lockedBalance(alice), 500e18, "aggregate should be 500");
        assertEq(token.lockerBalance(alice, authorizedLocker), 300e18, "locker1 should be 300");
        assertEq(token.lockerBalance(alice, authorizedLocker2), 200e18, "locker2 should be 200");
    }

    /// @dev accountLockers view tracks additions and removals
    function test_TC16_accountLockersView() public {
        assertEq(token.accountLockers(alice).length, 0, "initially empty");

        _lockTokensAs(authorizedLocker, alice, 300e18);
        address[] memory lockers = token.accountLockers(alice);
        assertEq(lockers.length, 1, "one locker after first lock");
        assertEq(lockers[0], authorizedLocker, "should be locker1");

        _lockTokensAs(authorizedLocker2, alice, 200e18);
        lockers = token.accountLockers(alice);
        assertEq(lockers.length, 2, "two lockers");

        // Unlock all of locker1's balance — should be removed from set
        vm.prank(authorizedLocker);
        token.unlock(alice, 300e18);
        lockers = token.accountLockers(alice);
        assertEq(lockers.length, 1, "one locker after full unlock");
        assertEq(lockers[0], authorizedLocker2, "should be locker2");
    }

    /// @dev unlockBatch respects per-locker ceiling
    function test_TC16_unlockBatchPerLockerEnforcement() public {
        _fundBob(500e18);
        _lockTokensAs(authorizedLocker, alice, 300e18);
        _lockTokensAs(authorizedLocker, bob, 200e18);

        // Locker2 locks alice separately
        _lockTokensAs(authorizedLocker2, alice, 100e18);

        // Locker2 tries batch unlock on alice for 200 (only has 100 per-locker)
        address[] memory accounts = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        accounts[0] = alice;
        amounts[0] = 200e18;

        vm.prank(authorizedLocker2);
        vm.expectRevert(abi.encodeWithSelector(ForageToken.InsufficientLockedBalance.selector, alice, 100e18, 200e18));
        token.unlockBatch(accounts, amounts);

        // Locker1 batch unlock should work
        accounts = new address[](2);
        amounts = new uint256[](2);
        accounts[0] = alice;
        amounts[0] = 300e18;
        accounts[1] = bob;
        amounts[1] = 200e18;

        vm.prank(authorizedLocker);
        token.unlockBatch(accounts, amounts);

        assertEq(token.lockerBalance(alice, authorizedLocker), 0);
        assertEq(token.lockerBalance(bob, authorizedLocker), 0);
        assertEq(token.lockerBalance(alice, authorizedLocker2), 100e18, "locker2 unchanged");
    }

    /// @dev Single locker behavior unchanged (regression test)
    function test_TC16_singleLockerBehaviorUnchanged() public {
        _lockTokens(alice, 500e18);
        assertEq(token.lockedBalance(alice), 500e18);
        assertEq(token.lockerBalance(alice, authorizedLocker), 500e18);

        vm.prank(authorizedLocker);
        token.unlock(alice, 200e18);
        assertEq(token.lockedBalance(alice), 300e18);
        assertEq(token.lockerBalance(alice, authorizedLocker), 300e18);

        // Transfer enforcement still works
        vm.prank(alice);
        token.transfer(bob, 700e18);
        assertEq(token.balanceOf(alice), 300e18);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ForageToken.InsufficientUnlockedBalance.selector, alice, 0, 1));
        token.transfer(bob, 1);
    }
}
