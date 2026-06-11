// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/DelegatingVestingWallet.sol";
import "./mocks/MockForageTokenVotes.sol";

// ============================================================
// TC-12: Voting Power Integration (R-07, R-09)
// Uses MockForageTokenVotes (full ERC20Votes) for actual voting power tracking.
// ============================================================
contract DelegatingVestingWallet_TC12_VotingPower is Test {
    DelegatingVestingWallet public wallet;
    MockForageTokenVotes public votesToken;

    address public beneficiary;
    address public tokenSetterAddr;
    address public delegatee1;
    address public delegatee2;

    uint256 public constant TOTAL_ALLOCATION = 20_000_000e18;
    uint64 public constant TEAM_DURATION = 126_230_400;
    uint64 public constant TEAM_CLIFF = 31_557_600;
    uint64 public startTimestamp;

    function setUp() public {
        beneficiary = makeAddr("beneficiary");
        tokenSetterAddr = makeAddr("tokenSetter");
        delegatee1 = makeAddr("delegatee1");
        delegatee2 = makeAddr("delegatee2");

        startTimestamp = uint64(block.timestamp);

        // Deploy wallet
        wallet = new DelegatingVestingWallet(beneficiary, startTimestamp, TEAM_DURATION, TEAM_CLIFF, tokenSetterAddr);

        // Deploy ERC20Votes token and fund wallet
        votesToken = new MockForageTokenVotes();
        votesToken.mint(address(wallet), TOTAL_ALLOCATION);

        // Set token — triggers initial delegation to beneficiary
        vm.prank(tokenSetterAddr);
        wallet.precommitForageToken(address(votesToken));
        vm.prank(tokenSetterAddr);
        wallet.setForageToken(address(votesToken));
    }

    /// @dev R-07: Initial delegation gives beneficiary voting power for vesting wallet's tokens.
    function test_TC12_initialDelegationGivesBeneficiaryVotingPower() public view {
        // After setForageToken, wallet called delegate(beneficiary) on the token
        // So beneficiary should have voting power equal to wallet's balance
        assertEq(votesToken.getVotes(beneficiary), TOTAL_ALLOCATION, "beneficiary should have voting power from wallet");
    }

    function test_TC12_rescueBeforeForageTokenSetReverts() public {
        DelegatingVestingWallet freshWallet =
            new DelegatingVestingWallet(beneficiary, startTimestamp, TEAM_DURATION, TEAM_CLIFF, tokenSetterAddr);
        votesToken.mint(address(freshWallet), 1 ether);

        vm.prank(beneficiary);
        vm.expectRevert(DelegatingVestingWallet.ForageTokenNotSet.selector);
        freshWallet.rescueToken(address(votesToken), 1 ether);
    }

    /// @dev R-07: Delegation changes move voting power between delegatees.
    function test_TC12_delegationChangesVotingPower() public {
        // Currently beneficiary has the votes
        assertEq(votesToken.getVotes(beneficiary), TOTAL_ALLOCATION);

        // Delegate to delegatee1
        vm.prank(beneficiary);
        wallet.delegateVotingPower(delegatee1);

        // delegatee1 now has the votes
        assertEq(votesToken.getVotes(delegatee1), TOTAL_ALLOCATION, "delegatee1 should have votes");
        assertEq(votesToken.getVotes(beneficiary), 0, "beneficiary should lose votes");
    }

    /// @dev R-09: Release decreases wallet voting power and delegatee voting power.
    function test_TC12_releaseDecreasesWalletVotingPower() public {
        // Delegate to delegatee1
        vm.prank(beneficiary);
        wallet.delegateVotingPower(delegatee1);
        assertEq(votesToken.getVotes(delegatee1), TOTAL_ALLOCATION);

        // Warp past cliff and release
        vm.warp(startTimestamp + TEAM_CLIFF);
        uint256 releasable = wallet.releasable();
        assertGt(releasable, 0, "should have releasable tokens");

        vm.prank(beneficiary);
        wallet.release();

        // Delegatee1's voting power decreased by released amount
        assertEq(
            votesToken.getVotes(delegatee1),
            TOTAL_ALLOCATION - releasable,
            "delegatee voting power decreased by released amount (R-09)"
        );
    }

    /// @dev R-09: Beneficiary does NOT automatically gain voting power for released tokens.
    function test_TC12_beneficiaryNoAutoVotingPowerOnRelease() public {
        // Delegate wallet to delegatee1
        vm.prank(beneficiary);
        wallet.delegateVotingPower(delegatee1);

        // Release tokens
        vm.warp(startTimestamp + TEAM_CLIFF);
        vm.prank(beneficiary);
        wallet.release();

        uint256 released_ = wallet.released();
        assertGt(released_, 0);

        // Beneficiary has tokens but NO voting power (hasn't delegated on ForageToken directly)
        assertEq(votesToken.balanceOf(beneficiary), released_, "beneficiary has released tokens");
        assertEq(votesToken.getVotes(beneficiary), 0, "beneficiary has NO auto voting power (R-09)");
    }

    /// @dev R-09: Beneficiary gains voting power after explicit self-delegation on ForageToken.
    function test_TC12_beneficiarySelfDelegateActivatesVotingPower() public {
        vm.prank(beneficiary);
        wallet.delegateVotingPower(delegatee1);

        vm.warp(startTimestamp + TEAM_CLIFF);
        vm.prank(beneficiary);
        wallet.release();

        uint256 released_ = wallet.released();

        // Beneficiary explicitly delegates to self on ForageToken
        vm.prank(beneficiary);
        votesToken.delegate(beneficiary);

        // Now beneficiary has voting power for released tokens
        assertEq(votesToken.getVotes(beneficiary), released_, "beneficiary has voting power after self-delegation");
    }

    /// @dev R-07: Delegation works at multiple vesting points.
    function test_TC12_delegationAtMultipleVestingPoints() public {
        // Pre-cliff: delegate to delegatee1 (all tokens locked)
        vm.prank(beneficiary);
        wallet.delegateVotingPower(delegatee1);
        assertEq(votesToken.getVotes(delegatee1), TOTAL_ALLOCATION, "pre-cliff: all to delegatee1");

        // Mid-vesting: release and switch delegation
        vm.warp(startTimestamp + TEAM_CLIFF);
        vm.prank(beneficiary);
        wallet.release();
        uint256 remaining = votesToken.balanceOf(address(wallet));

        vm.prank(beneficiary);
        wallet.delegateVotingPower(delegatee2);
        assertEq(votesToken.getVotes(delegatee2), remaining, "mid-vesting: remaining to delegatee2");
        assertEq(votesToken.getVotes(delegatee1), 0, "mid-vesting: delegatee1 has 0");

        // Post-vesting: release all and delegate
        vm.warp(startTimestamp + TEAM_DURATION);
        vm.prank(beneficiary);
        wallet.release();

        // Wallet is empty — delegatee2's voting power from wallet is 0
        assertEq(votesToken.balanceOf(address(wallet)), 0, "wallet empty");
        assertEq(votesToken.getVotes(delegatee2), 0, "post-vesting: delegatee2 has 0 from wallet");
    }
}
