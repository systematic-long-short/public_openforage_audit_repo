// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/DelegatingVestingWalletTestBase.sol";

contract DelegatingVestingWalletStaticBlocklist {
    function isBlocked(address) external pure returns (bool) {
        return false;
    }
}

// ============================================================
// TC-01: Constructor Happy Path (R-01, R-03, R-11, R-27)
// ============================================================
contract DelegatingVestingWallet_TC01_ConstructorHappy is DelegatingVestingWalletTestBase {
    /// @dev Verify all state is correctly initialized after construction.
    function test_TC01_allStateInitialized() public view {
        assertEq(wallet.beneficiary(), beneficiary, "beneficiary mismatch");
        assertEq(wallet.start(), startTimestamp, "start mismatch");
        assertEq(wallet.duration(), TEAM_DURATION, "duration mismatch");
        assertEq(wallet.cliff(), TEAM_CLIFF, "cliff mismatch");
        assertEq(wallet.end(), startTimestamp + TEAM_DURATION, "end mismatch");
        assertEq(wallet.delegatee(), beneficiary, "delegatee should be beneficiary (R-11)");
        assertEq(wallet.tokenSetter(), tokenSetterAddr, "tokenSetter mismatch");
        assertEq(wallet.forageToken(), address(0), "forageToken should be unset");
        assertEq(wallet.released(), 0, "released should be 0");
    }

    /// @dev Verify team canonical parameters produce correct end timestamp.
    function test_TC01_teamCanonicalParameters() public view {
        // duration = 4 * 365.25 * 86400 = 126,230,400
        // cliff = 1 * 365.25 * 86400 = 31,557,600
        assertEq(wallet.duration(), 126_230_400, "team canonical duration");
        assertEq(wallet.cliff(), 31_557_600, "team canonical cliff");
        assertEq(wallet.end(), startTimestamp + 126_230_400, "team canonical end");
    }

    /// @dev Verify deployment with non-team parameters also works.
    function test_TC01_customParameters() public {
        uint64 customStart = uint64(block.timestamp + 1000);
        uint64 customDuration = 86400; // 1 day
        uint64 customCliff = 3600; // 1 hour
        address customBeneficiary = makeAddr("customBeneficiary");
        address customSetter = makeAddr("customSetter");

        DelegatingVestingWallet w =
            _deployWallet(customBeneficiary, customStart, customDuration, customCliff, customSetter);

        assertEq(w.beneficiary(), customBeneficiary);
        assertEq(w.start(), customStart);
        assertEq(w.duration(), customDuration);
        assertEq(w.cliff(), customCliff);
        assertEq(w.end(), customStart + customDuration);
        assertEq(w.delegatee(), customBeneficiary);
        assertEq(w.tokenSetter(), customSetter);
    }
}

// ============================================================
// TC-02: Constructor Validation (R-13, R-14, R-15)
// ============================================================
contract DelegatingVestingWallet_TC02_ConstructorValidation is Test {
    address internal beneficiary_;
    address internal tokenSetter_;

    function setUp() public {
        beneficiary_ = makeAddr("beneficiary");
        tokenSetter_ = makeAddr("tokenSetter");
    }

    /// @dev R-13: Zero beneficiary address MUST revert ZeroAddress().
    function test_TC02_revertZeroBeneficiary() public {
        vm.expectRevert(DelegatingVestingWallet.ZeroAddress.selector);
        new DelegatingVestingWallet(address(0), uint64(block.timestamp), 86400, 3600, tokenSetter_);
    }

    /// @dev R-14: Zero duration MUST revert ZeroDuration().
    function test_TC02_revertZeroDuration() public {
        vm.expectRevert(DelegatingVestingWallet.ZeroDuration.selector);
        new DelegatingVestingWallet(beneficiary_, uint64(block.timestamp), 0, 0, tokenSetter_);
    }

    /// @dev R-15: Cliff > duration MUST revert CliffExceedsDuration().
    function test_TC02_revertCliffExceedsDuration() public {
        vm.expectRevert(DelegatingVestingWallet.CliffExceedsDuration.selector);
        new DelegatingVestingWallet(beneficiary_, uint64(block.timestamp), 86400, 86401, tokenSetter_);
    }

    /// @dev R-15: Large cliff exceeding duration also reverts.
    function test_TC02_revertCliffExceedsDurationLarge() public {
        vm.expectRevert(DelegatingVestingWallet.CliffExceedsDuration.selector);
        new DelegatingVestingWallet(beneficiary_, uint64(block.timestamp), 100, type(uint64).max, tokenSetter_);
    }

    /// @dev R-13: Zero tokenSetter address MUST revert ZeroAddress().
    function test_TC02_revertZeroTokenSetter() public {
        vm.expectRevert(DelegatingVestingWallet.ZeroAddress.selector);
        new DelegatingVestingWallet(beneficiary_, uint64(block.timestamp), 86400, 3600, address(0));
    }

    /// @dev Valid edge case: cliff == duration MUST succeed.
    function test_TC02_validCliffEqualsDuration() public {
        DelegatingVestingWallet w =
            new DelegatingVestingWallet(beneficiary_, uint64(block.timestamp), 86400, 86400, tokenSetter_);
        assertEq(w.cliff(), 86400);
        assertEq(w.duration(), 86400);
    }

    /// @dev Valid edge case: cliff == 0 MUST succeed.
    function test_TC02_validZeroCliff() public {
        DelegatingVestingWallet w =
            new DelegatingVestingWallet(beneficiary_, uint64(block.timestamp), 86400, 0, tokenSetter_);
        assertEq(w.cliff(), 0);
    }
}

// ============================================================
// TC-03: setForageToken (R-04, R-10, R-12, R-16, R-17, R-24, R-31)
// ============================================================
contract DelegatingVestingWallet_TC03_SetForageToken is DelegatingVestingWalletTestBase {
    /// @dev R-04, R-10, R-24: One-time set succeeds, tokenSetter cleared, event emitted.
    function test_TC03_oneTimeSetSucceeds() public {
        mockToken.mint(address(wallet), TOTAL_ALLOCATION);

        vm.prank(tokenSetterAddr);
        wallet.precommitForageToken(address(mockToken));

        vm.expectEmit(true, false, false, true);
        emit DelegatingVestingWallet.ForageTokenSet(address(mockToken));

        vm.prank(tokenSetterAddr);
        wallet.setForageToken(address(mockToken));

        assertEq(wallet.forageToken(), address(mockToken), "forageToken should be set");
        assertEq(wallet.tokenSetter(), address(0), "tokenSetter should be cleared (R-10)");
    }

    function test_OPEN43_tokenSetterCanWireBlocklistAfterForageTokenSet() public {
        DelegatingVestingWalletStaticBlocklist deployedBlocklist = new DelegatingVestingWalletStaticBlocklist();
        _fundAndSetTokenDefault();
        assertEq(wallet.tokenSetter(), address(0), "token setter is burned after token wiring");

        vm.prank(tokenSetterAddr);
        wallet.setBlocklist(address(deployedBlocklist));

        assertEq(
            wallet.blocklist(), address(deployedBlocklist), "OPEN-43: deployment can wire blocklist after token setup"
        );
    }

    function test_SECURITY_tokenSetterCannotChangeBlocklistAfterOneShotWiring() public {
        DelegatingVestingWalletStaticBlocklist firstBlocklist = new DelegatingVestingWalletStaticBlocklist();
        DelegatingVestingWalletStaticBlocklist secondBlocklist = new DelegatingVestingWalletStaticBlocklist();
        _fundAndSetTokenDefault();

        vm.prank(tokenSetterAddr);
        wallet.setBlocklist(address(firstBlocklist));

        vm.prank(tokenSetterAddr);
        vm.expectRevert(DelegatingVestingWallet.BlocklistAlreadySet.selector);
        wallet.setBlocklist(address(secondBlocklist));

        assertEq(wallet.blocklist(), address(firstBlocklist), "blocklist remains one-shot wired");
    }

    function test_SECURITY_blocklistMustHaveCode() public {
        address eoaBlocklist = makeAddr("eoaBlocklist");
        _fundAndSetTokenDefault();

        vm.prank(tokenSetterAddr);
        vm.expectRevert(abi.encodeWithSelector(DelegatingVestingWallet.TargetHasNoCode.selector, eoaBlocklist));
        wallet.setBlocklist(eoaBlocklist);
    }

    /// @dev R-12: setForageToken triggers initial ForageToken.delegate(delegatee).
    function test_TC03_triggersInitialDelegation() public {
        mockToken.mint(address(wallet), TOTAL_ALLOCATION);

        vm.prank(tokenSetterAddr);
        wallet.precommitForageToken(address(mockToken));
        vm.prank(tokenSetterAddr);
        wallet.setForageToken(address(mockToken));

        // The wallet should have called delegate(beneficiary) on the token
        assertEq(mockToken.lastDelegatee(), beneficiary, "initial delegation should be to beneficiary (R-12)");
        assertGt(mockToken.delegateCallCount(), 0, "delegate must have been called");
    }

    /// @dev R-31: Second call MUST revert ForageTokenAlreadySet().
    function test_TC03_secondCallReverts() public {
        _fundAndSetTokenDefault();

        vm.expectRevert(DelegatingVestingWallet.ForageTokenAlreadySet.selector);
        wallet.setForageToken(address(mockToken));
    }

    /// @dev R-16: Non-tokenSetter MUST revert UnauthorizedTokenSetter.
    function test_TC03_unauthorizedCallerReverts() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(DelegatingVestingWallet.UnauthorizedTokenSetter.selector, attacker));
        wallet.setForageToken(address(mockToken));
    }

    /// @dev R-17: Zero address MUST revert ZeroAddress().
    function test_TC03_zeroAddressReverts() public {
        vm.prank(tokenSetterAddr);
        vm.expectRevert(DelegatingVestingWallet.ZeroAddress.selector);
        wallet.setForageToken(address(0));
    }

    /// @dev R-16: Even beneficiary cannot call setForageToken (only tokenSetter can).
    function test_TC03_beneficiaryCannotSet() public {
        vm.prank(beneficiary);
        vm.expectRevert(abi.encodeWithSelector(DelegatingVestingWallet.UnauthorizedTokenSetter.selector, beneficiary));
        wallet.setForageToken(address(mockToken));
    }
}

// ============================================================
// TC-04: release() (R-05, R-06, R-18, R-19, R-25, R-29)
// ============================================================
contract DelegatingVestingWallet_TC04_Release is DelegatingVestingWalletTestBase {
    /// @dev R-05, R-25, R-29: Release after cliff transfers correct amount and emits event.
    function test_TC04_releaseAfterCliff() public {
        _fundAndSetTokenDefault();

        // Warp to cliff boundary
        vm.warp(startTimestamp + TEAM_CLIFF);

        uint256 expectedVested = TOTAL_ALLOCATION * uint256(TEAM_CLIFF) / uint256(TEAM_DURATION);
        assertEq(wallet.releasable(), expectedVested, "releasable at cliff");

        vm.expectEmit(true, false, false, true);
        emit DelegatingVestingWallet.TokensReleased(beneficiary, expectedVested);

        vm.prank(beneficiary);
        wallet.release();

        assertEq(wallet.released(), expectedVested, "released tracking (R-05)");
        assertEq(mockToken.balanceOf(beneficiary), expectedVested, "beneficiary received tokens");
        assertEq(mockToken.balanceOf(address(wallet)), TOTAL_ALLOCATION - expectedVested, "wallet balance decreased");
    }

    /// @dev R-19: Release immediately after release with no new vesting reverts NothingToRelease().
    function test_TC04_releaseNothingToRelease() public {
        _fundAndSetTokenDefault();

        vm.warp(startTimestamp + TEAM_CLIFF);

        vm.prank(beneficiary);
        wallet.release();

        // Try again immediately — nothing new vested
        vm.expectRevert(DelegatingVestingWallet.NothingToRelease.selector);
        vm.prank(beneficiary);
        wallet.release();
    }

    /// @dev R-05: Multiple releases over time accumulate correctly.
    function test_TC04_multipleReleasesAccumulate() public {
        _fundAndSetTokenDefault();

        // First release at cliff
        vm.warp(startTimestamp + TEAM_CLIFF);
        vm.prank(beneficiary);
        wallet.release();
        uint256 releasedAtCliff = wallet.released();

        // Second release at 50% through vesting
        uint64 midpoint = startTimestamp + TEAM_DURATION / 2;
        vm.warp(midpoint);
        uint256 expectedVestedAtMid = TOTAL_ALLOCATION * uint256(TEAM_DURATION / 2) / uint256(TEAM_DURATION);
        uint256 expectedSecondRelease = expectedVestedAtMid - releasedAtCliff;

        vm.prank(beneficiary);
        wallet.release();

        assertEq(wallet.released(), expectedVestedAtMid, "cumulative released at midpoint");
        assertEq(
            mockToken.balanceOf(beneficiary), releasedAtCliff + expectedSecondRelease, "beneficiary cumulative balance"
        );
    }

    /// @dev R-06: Full release at end equals totalAllocation.
    function test_TC04_fullReleaseAtEnd() public {
        _fundAndSetTokenDefault();

        vm.warp(startTimestamp + TEAM_DURATION);

        vm.prank(beneficiary);
        wallet.release();

        assertEq(wallet.released(), TOTAL_ALLOCATION, "released should equal total allocation at end (R-06)");
        assertEq(mockToken.balanceOf(beneficiary), TOTAL_ALLOCATION, "beneficiary should have all tokens");
        assertEq(mockToken.balanceOf(address(wallet)), 0, "wallet should be empty");
    }

    /// @dev R-19: Release at end after full release reverts.
    function test_TC04_releaseAfterFullVestingReverts() public {
        _fundAndSetTokenDefault();

        vm.warp(startTimestamp + TEAM_DURATION);
        vm.prank(beneficiary);
        wallet.release();

        vm.expectRevert(DelegatingVestingWallet.NothingToRelease.selector);
        vm.prank(beneficiary);
        wallet.release();
    }

    /// @dev R-18: Release before token set MUST revert ForageTokenNotSet().
    function test_TC04_releaseBeforeTokenSetReverts() public {
        // Token not set yet
        vm.prank(beneficiary);
        vm.expectRevert(DelegatingVestingWallet.ForageTokenNotSet.selector);
        wallet.release();
    }

    /// @dev R-19: Release before cliff with zero releasable reverts NothingToRelease().
    function test_TC04_releaseBeforeCliffReverts() public {
        _fundAndSetTokenDefault();

        // Before cliff — vested is 0
        vm.warp(startTimestamp + TEAM_CLIFF - 1);

        vm.prank(beneficiary);
        vm.expectRevert(DelegatingVestingWallet.NothingToRelease.selector);
        wallet.release();
    }

    /// @dev OF-L04: Only beneficiary can call release().
    function test_TC04_nonBeneficiaryCannotCallRelease() public {
        _fundAndSetTokenDefault();

        vm.warp(startTimestamp + TEAM_CLIFF);

        // Attacker calls release — should revert
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(DelegatingVestingWallet.UnauthorizedBeneficiary.selector, attacker));
        wallet.release();

        assertEq(wallet.released(), 0, "no release should occur");
    }
}

// ============================================================
// TC-05: delegateVotingPower() (R-07, R-08, R-20, R-21, R-22, R-26)
// ============================================================
contract DelegatingVestingWallet_TC05_DelegateVotingPower is DelegatingVestingWalletTestBase {
    function setUp() public override {
        super.setUp();
        _fundAndSetTokenDefault();
    }

    /// @dev R-07, R-26: Beneficiary can delegate and event is emitted.
    function test_TC05_beneficiaryDelegates() public {
        assertEq(wallet.delegatee(), beneficiary, "initial delegatee is beneficiary");

        vm.expectEmit(true, true, false, true);
        emit DelegatingVestingWallet.VotingDelegateChanged(beneficiary, delegatee1);

        vm.prank(beneficiary);
        wallet.delegateVotingPower(delegatee1);

        assertEq(wallet.delegatee(), delegatee1, "delegatee updated");
        assertEq(mockToken.lastDelegatee(), delegatee1, "ForageToken.delegate called with delegatee1");
    }

    /// @dev R-08: Token balance unchanged after delegation (no-transfer invariant).
    function test_TC05_delegationDoesNotTransferTokens() public {
        uint256 walletBalanceBefore = mockToken.balanceOf(address(wallet));

        vm.prank(beneficiary);
        wallet.delegateVotingPower(delegatee1);

        assertEq(mockToken.balanceOf(address(wallet)), walletBalanceBefore, "wallet balance unchanged (R-08)");
    }

    /// @dev R-26: Sequential delegations emit correct old/new in events.
    function test_TC05_sequentialDelegationEvents() public {
        vm.prank(beneficiary);
        wallet.delegateVotingPower(delegatee1);

        vm.expectEmit(true, true, false, true);
        emit DelegatingVestingWallet.VotingDelegateChanged(delegatee1, delegatee2);

        vm.prank(beneficiary);
        wallet.delegateVotingPower(delegatee2);

        assertEq(wallet.delegatee(), delegatee2);
    }

    /// @dev R-07: Delegation works during vesting (after partial release).
    function test_TC05_delegationDuringVesting() public {
        vm.warp(startTimestamp + TEAM_CLIFF + 1000);

        vm.prank(beneficiary);
        wallet.release();

        // Delegation should still work
        vm.prank(beneficiary);
        wallet.delegateVotingPower(delegatee1);

        assertEq(wallet.delegatee(), delegatee1);
    }

    /// @dev R-20: Non-beneficiary MUST revert UnauthorizedBeneficiary.
    function test_TC05_nonBeneficiaryReverts() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(DelegatingVestingWallet.UnauthorizedBeneficiary.selector, attacker));
        wallet.delegateVotingPower(delegatee1);
    }

    /// @dev R-21: Before token set MUST revert ForageTokenNotSet().
    function test_TC05_beforeTokenSetReverts() public {
        // Deploy a fresh wallet without setting token
        DelegatingVestingWallet freshWallet =
            _deployWallet(beneficiary, startTimestamp, TEAM_DURATION, TEAM_CLIFF, tokenSetterAddr);

        vm.prank(beneficiary);
        vm.expectRevert(DelegatingVestingWallet.ForageTokenNotSet.selector);
        freshWallet.delegateVotingPower(delegatee1);
    }

    /// @dev R-22: Zero address MUST revert ZeroAddress().
    function test_TC05_zeroAddressReverts() public {
        vm.prank(beneficiary);
        vm.expectRevert(DelegatingVestingWallet.ZeroAddress.selector);
        wallet.delegateVotingPower(address(0));
    }
}

// ============================================================
// TC-10: View Function Correctness (R-01, R-02, R-03, R-04, R-05, R-07, R-10, R-28, R-29, R-30)
// ============================================================
contract DelegatingVestingWallet_TC10_ViewFunctions is DelegatingVestingWalletTestBase {
    /// @dev All view functions return correct values at construction.
    function test_TC10_viewsAtConstruction() public view {
        assertEq(wallet.beneficiary(), beneficiary, "beneficiary() (R-01)");
        assertEq(wallet.start(), startTimestamp, "start()");
        assertEq(wallet.duration(), TEAM_DURATION, "duration()");
        assertEq(wallet.cliff(), TEAM_CLIFF, "cliff() (R-03)");
        assertEq(wallet.end(), startTimestamp + TEAM_DURATION, "end() = start + duration (R-30)");
        assertEq(wallet.tokenSetter(), tokenSetterAddr, "tokenSetter()");
        assertEq(wallet.forageToken(), address(0), "forageToken() before set (R-04)");
        assertEq(wallet.released(), 0, "released() at construction (R-05)");
        assertEq(wallet.delegatee(), beneficiary, "delegatee() = beneficiary (R-07)");
    }

    /// @dev forageToken and tokenSetter update after setForageToken.
    function test_TC10_viewsAfterSetToken() public {
        _fundAndSetTokenDefault();

        assertEq(wallet.forageToken(), address(mockToken), "forageToken() after set");
        assertEq(wallet.tokenSetter(), address(0), "tokenSetter() cleared (R-10)");
    }

    /// @dev releasable and vestedAmount match formula at cliff boundary.
    function test_TC10_releasableAndVestedAtCliff() public {
        _fundAndSetTokenDefault();

        vm.warp(startTimestamp + TEAM_CLIFF);

        uint256 expectedVested = TOTAL_ALLOCATION * uint256(TEAM_CLIFF) / uint256(TEAM_DURATION);
        assertEq(wallet.vestedAmount(uint64(block.timestamp)), expectedVested, "vestedAmount at cliff (R-28)");
        assertEq(wallet.releasable(), expectedVested, "releasable at cliff (R-29)");
    }

    /// @dev released and releasable update after release.
    function test_TC10_viewsAfterRelease() public {
        _fundAndSetTokenDefault();

        vm.warp(startTimestamp + TEAM_CLIFF);
        uint256 expectedVested = TOTAL_ALLOCATION * uint256(TEAM_CLIFF) / uint256(TEAM_DURATION);

        vm.prank(beneficiary);
        wallet.release();

        assertEq(wallet.released(), expectedVested, "released() updated (R-05)");
        assertEq(wallet.releasable(), 0, "releasable() = 0 after release (R-29)");
    }

    /// @dev delegatee updates after delegation.
    function test_TC10_viewsAfterDelegation() public {
        _fundAndSetTokenDefault();

        vm.prank(beneficiary);
        wallet.delegateVotingPower(delegatee1);

        assertEq(wallet.delegatee(), delegatee1, "delegatee() updated");
    }

    /// @dev vestedAmount returns 0 before cliff.
    function test_TC10_vestedAmountBeforeCliff() public view {
        assertEq(wallet.vestedAmount(startTimestamp), 0, "vestedAmount at start = 0 (R-28)");
        assertEq(wallet.vestedAmount(startTimestamp + TEAM_CLIFF - 1), 0, "vestedAmount just before cliff = 0");
    }

    /// @dev vestedAmount returns totalAllocation at and after end.
    function test_TC10_vestedAmountAtEnd() public {
        _fundAndSetTokenDefault();

        uint64 endTs = startTimestamp + TEAM_DURATION;
        assertEq(wallet.vestedAmount(endTs), TOTAL_ALLOCATION, "vestedAmount at end = totalAllocation (R-28)");
        assertEq(wallet.vestedAmount(endTs + 1_000_000), TOTAL_ALLOCATION, "vestedAmount after end = totalAllocation");
    }

    /// @dev end() = start + duration (R-30).
    function test_TC10_endEqualsStartPlusDuration() public view {
        assertEq(wallet.end(), wallet.start() + wallet.duration(), "end() == start() + duration() (R-30)");
    }
}

// ============================================================
// TC-11: Non-Upgradeable Architecture (R-23)
// ============================================================
contract DelegatingVestingWallet_TC11_NonUpgradeable is DelegatingVestingWalletTestBase {
    /// @dev Scan deployed bytecode for a 4-byte function selector.
    /// Returns true if the selector appears anywhere in the runtime bytecode.
    function _bytecodeContainsSelector(address target, bytes4 selector) internal view returns (bool) {
        bytes memory code = target.code;
        if (code.length < 4) return false;
        for (uint256 i = 0; i <= code.length - 4; i++) {
            if (
                code[i] == selector[0] && code[i + 1] == selector[1] && code[i + 2] == selector[2]
                    && code[i + 3] == selector[3]
            ) {
                return true;
            }
        }
        return false;
    }

    /// @dev R-23: No proxiableUUID selector in bytecode (not UUPSUpgradeable).
    function test_TC11_noProxiableUUID() public view {
        bytes4 selector = bytes4(keccak256("proxiableUUID()"));
        assertFalse(
            _bytecodeContainsSelector(address(wallet), selector),
            "proxiableUUID selector must not exist in bytecode (R-23)"
        );
    }

    /// @dev R-23: No upgradeToAndCall selector in bytecode (not UUPSUpgradeable).
    function test_TC11_noUpgradeToAndCall() public view {
        bytes4 selector = bytes4(keccak256("upgradeToAndCall(address,bytes)"));
        assertFalse(
            _bytecodeContainsSelector(address(wallet), selector),
            "upgradeToAndCall selector must not exist in bytecode (R-23)"
        );
    }

    /// @dev R-23: No initialize selector in bytecode (uses constructor, not Initializable).
    function test_TC11_noInitialize() public view {
        bytes4 selector = bytes4(keccak256("initialize()"));
        assertFalse(
            _bytecodeContainsSelector(address(wallet), selector),
            "initialize selector must not exist in bytecode (R-23)"
        );
    }

    /// @dev R-23: Contract is deployed directly (not a proxy). Verify ERC-1967
    /// implementation slot is empty (no proxy delegation).
    function test_TC11_directDeployment() public view {
        // ERC-1967 implementation slot: bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1)
        bytes32 implSlot = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
        bytes32 stored = vm.load(address(wallet), implSlot);
        assertEq(stored, bytes32(0), "ERC-1967 implementation slot must be empty (R-23 - not a proxy)");

        // Also verify code exists at the address
        assertGt(address(wallet).code.length, 0, "Contract code must exist at address");
    }
}
