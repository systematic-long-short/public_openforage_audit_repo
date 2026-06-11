// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/DelegatingVestingWalletTestBase.sol";

// ============================================================
// TC-06: Vesting Formula (R-02, R-28, R-29)
// ============================================================
contract DelegatingVestingWallet_TC06_VestingFormula is DelegatingVestingWalletTestBase {
    function setUp() public override {
        super.setUp();
        _fundAndSetTokenDefault();
    }

    /// @dev R-28: Zero vested before start.
    function test_TC06_zeroVestedBeforeStart() public view {
        if (startTimestamp > 0) {
            assertEq(wallet.vestedAmount(startTimestamp - 1), 0, "zero before start");
        }
    }

    /// @dev R-28: Zero vested at start (before cliff).
    function test_TC06_zeroVestedAtStart() public view {
        assertEq(wallet.vestedAmount(startTimestamp), 0, "zero at start");
    }

    /// @dev R-28: Zero vested 1 second before cliff ends.
    function test_TC06_zeroVestedBeforeCliff() public view {
        assertEq(wallet.vestedAmount(startTimestamp + TEAM_CLIFF - 1), 0, "zero 1s before cliff");
    }

    /// @dev R-28: Cliff jump — at cliff boundary, vested = totalAllocation * cliff / duration.
    function test_TC06_cliffJumpToLinearAmount() public view {
        uint256 expectedAtCliff = TOTAL_ALLOCATION * uint256(TEAM_CLIFF) / uint256(TEAM_DURATION);
        assertEq(wallet.vestedAmount(startTimestamp + TEAM_CLIFF), expectedAtCliff, "cliff jump to linear amount");
    }

    /// @dev R-28: Linear interpolation 1 second after cliff.
    function test_TC06_linearOneSecondAfterCliff() public view {
        uint256 expected = TOTAL_ALLOCATION * (uint256(TEAM_CLIFF) + 1) / uint256(TEAM_DURATION);
        assertEq(wallet.vestedAmount(startTimestamp + TEAM_CLIFF + 1), expected, "linear 1s after cliff");
    }

    /// @dev R-28: Linear interpolation at midpoint.
    function test_TC06_linearAtMidpoint() public view {
        uint64 midpoint = TEAM_DURATION / 2;
        uint256 expected = TOTAL_ALLOCATION * uint256(midpoint) / uint256(TEAM_DURATION);
        assertEq(wallet.vestedAmount(startTimestamp + midpoint), expected, "linear at midpoint");
    }

    /// @dev R-28: Linear interpolation at 75%.
    function test_TC06_linearAt75Percent() public view {
        uint64 threeQuarters = TEAM_DURATION * 3 / 4;
        uint256 expected = TOTAL_ALLOCATION * uint256(threeQuarters) / uint256(TEAM_DURATION);
        assertEq(wallet.vestedAmount(startTimestamp + threeQuarters), expected, "linear at 75%");
    }

    /// @dev R-28: 1 second before end.
    function test_TC06_oneSecondBeforeEnd() public view {
        uint256 expected = TOTAL_ALLOCATION * (uint256(TEAM_DURATION) - 1) / uint256(TEAM_DURATION);
        assertEq(wallet.vestedAmount(startTimestamp + TEAM_DURATION - 1), expected, "1s before end");
    }

    /// @dev R-28: Full vested at end.
    function test_TC06_fullVestedAtEnd() public view {
        assertEq(wallet.vestedAmount(startTimestamp + TEAM_DURATION), TOTAL_ALLOCATION, "full at end");
    }

    /// @dev R-28: Full vested well past end.
    function test_TC06_fullVestedPastEnd() public view {
        assertEq(wallet.vestedAmount(startTimestamp + TEAM_DURATION + 1_000_000), TOTAL_ALLOCATION, "full past end");
    }

    /// @dev R-29: releasable = vestedAmount - released at various points.
    function test_TC06_releasableEqualsVestedMinusReleased() public {
        // Before cliff
        assertEq(wallet.releasable(), 0, "releasable at start = 0");

        // At cliff
        vm.warp(startTimestamp + TEAM_CLIFF);
        uint256 vestedAtCliff = wallet.vestedAmount(uint64(block.timestamp));
        assertEq(wallet.releasable(), vestedAtCliff - wallet.released(), "releasable at cliff (R-29)");

        // After release
        vm.prank(beneficiary);
        wallet.release();
        assertEq(wallet.releasable(), 0, "releasable after release = 0");

        // After more time
        vm.warp(startTimestamp + TEAM_CLIFF + 86400);
        uint256 vestedNow = wallet.vestedAmount(uint64(block.timestamp));
        assertEq(wallet.releasable(), vestedNow - wallet.released(), "releasable after more time (R-29)");
    }

    /// @dev R-28: Vesting with small allocation for rounding verification.
    function test_TC06_smallAllocationRounding() public {
        // Deploy with 1000 tokens and 100 second duration, 10 second cliff
        DelegatingVestingWallet w = _deployWallet(beneficiary, startTimestamp, 100, 10, tokenSetterAddr);
        MockForageTokenSimple tok = new MockForageTokenSimple();
        tok.mint(address(w), 1000e18);
        vm.prank(tokenSetterAddr);
        w.precommitForageToken(address(tok));
        vm.prank(tokenSetterAddr);
        w.setForageToken(address(tok));

        // At cliff (t=10): vested = 1000e18 * 10 / 100 = 100e18
        assertEq(w.vestedAmount(startTimestamp + 10), 100e18, "small alloc at cliff");
        // At t=50: vested = 1000e18 * 50 / 100 = 500e18
        assertEq(w.vestedAmount(startTimestamp + 50), 500e18, "small alloc at 50%");
        // At t=100: vested = 1000e18
        assertEq(w.vestedAmount(startTimestamp + 100), 1000e18, "small alloc at end");
    }
}

// ============================================================
// TC-08: Time Boundary Tests (R-02, R-28, R-29)
// ============================================================
contract DelegatingVestingWallet_TC08_TimeBoundary is DelegatingVestingWalletTestBase {
    function setUp() public override {
        super.setUp();
        _fundAndSetTokenDefault();
    }

    // --- Cliff edge tests ---

    /// @dev 1 second before cliff: zero vested, release reverts.
    function test_TC08_cliffEdgeBefore() public {
        vm.warp(startTimestamp + TEAM_CLIFF - 1);
        assertEq(wallet.vestedAmount(uint64(block.timestamp)), 0, "zero before cliff");
        assertEq(wallet.releasable(), 0, "releasable zero before cliff");

        vm.prank(beneficiary);
        vm.expectRevert(DelegatingVestingWallet.NothingToRelease.selector);
        wallet.release();
    }

    /// @dev At cliff: non-zero jump, release succeeds.
    function test_TC08_cliffEdgeAt() public {
        vm.warp(startTimestamp + TEAM_CLIFF);
        uint256 expectedVested = TOTAL_ALLOCATION * uint256(TEAM_CLIFF) / uint256(TEAM_DURATION);
        assertEq(wallet.vestedAmount(uint64(block.timestamp)), expectedVested, "non-zero at cliff");
        assertGt(wallet.releasable(), 0, "releasable non-zero at cliff");

        vm.prank(beneficiary);
        wallet.release();
        assertEq(wallet.released(), expectedVested);
    }

    /// @dev 1 second after cliff: linearly increased by 1 second worth.
    function test_TC08_cliffEdgeAfter() public view {
        uint256 expected = TOTAL_ALLOCATION * (uint256(TEAM_CLIFF) + 1) / uint256(TEAM_DURATION);
        assertEq(wallet.vestedAmount(startTimestamp + TEAM_CLIFF + 1), expected, "1s after cliff");
    }

    // --- Vesting end tests ---

    /// @dev 1 second before end: not yet fully vested.
    function test_TC08_endBefore() public view {
        uint256 expected = TOTAL_ALLOCATION * (uint256(TEAM_DURATION) - 1) / uint256(TEAM_DURATION);
        assertEq(wallet.vestedAmount(startTimestamp + TEAM_DURATION - 1), expected, "1s before end");
        assertLt(expected, TOTAL_ALLOCATION, "not fully vested 1s before end");
    }

    /// @dev At end: fully vested.
    function test_TC08_endAt() public view {
        assertEq(wallet.vestedAmount(startTimestamp + TEAM_DURATION), TOTAL_ALLOCATION, "fully vested at end");
    }

    /// @dev After end: still fully vested (capped).
    function test_TC08_endAfter() public view {
        assertEq(
            wallet.vestedAmount(startTimestamp + TEAM_DURATION + 1), TOTAL_ALLOCATION, "still fully vested after end"
        );
    }

    // --- Pre-start tests ---

    /// @dev Well before start: zero vested.
    function test_TC08_preStartFarBefore() public view {
        if (startTimestamp > 1_000_000) {
            assertEq(wallet.vestedAmount(startTimestamp - 1_000_000), 0, "zero well before start");
        }
    }

    /// @dev At start (before cliff has passed): zero vested.
    function test_TC08_preStartAtStart() public view {
        assertEq(wallet.vestedAmount(startTimestamp), 0, "zero at start (cliff > 0)");
    }

    // --- Zero-cliff edge case ---

    /// @dev Zero cliff: vested at start = 0 (t - start = 0 gives 0).
    function test_TC08_zeroCliffAtStart() public {
        DelegatingVestingWallet w = _deployWallet(beneficiary, startTimestamp, TEAM_DURATION, 0, tokenSetterAddr);
        MockForageTokenSimple tok = new MockForageTokenSimple();
        tok.mint(address(w), TOTAL_ALLOCATION);
        vm.prank(tokenSetterAddr);
        w.precommitForageToken(address(tok));
        vm.prank(tokenSetterAddr);
        w.setForageToken(address(tok));

        // At start with zero cliff: vested = totalAlloc * 0 / duration = 0
        assertEq(w.vestedAmount(startTimestamp), 0, "zero cliff at start: 0");
    }

    /// @dev Zero cliff: vested at start + 1 is non-zero.
    function test_TC08_zeroCliffOneSecondAfterStart() public {
        DelegatingVestingWallet w = _deployWallet(beneficiary, startTimestamp, TEAM_DURATION, 0, tokenSetterAddr);
        MockForageTokenSimple tok = new MockForageTokenSimple();
        tok.mint(address(w), TOTAL_ALLOCATION);
        vm.prank(tokenSetterAddr);
        w.precommitForageToken(address(tok));
        vm.prank(tokenSetterAddr);
        w.setForageToken(address(tok));

        uint256 expected = TOTAL_ALLOCATION * 1 / uint256(TEAM_DURATION);
        assertEq(w.vestedAmount(startTimestamp + 1), expected, "zero cliff at start+1: non-zero");
        assertGt(expected, 0, "should be positive");
    }

    // --- Cliff-equals-duration edge case ---

    /// @dev Cliff equals duration: zero until end, then instant full vest.
    function test_TC08_cliffEqualsDurationBeforeEnd() public {
        uint64 dur = 86400;
        DelegatingVestingWallet w = _deployWallet(beneficiary, startTimestamp, dur, dur, tokenSetterAddr);
        MockForageTokenSimple tok = new MockForageTokenSimple();
        tok.mint(address(w), TOTAL_ALLOCATION);
        vm.prank(tokenSetterAddr);
        w.precommitForageToken(address(tok));
        vm.prank(tokenSetterAddr);
        w.setForageToken(address(tok));

        assertEq(w.vestedAmount(startTimestamp + dur - 1), 0, "cliff=dur: zero 1s before end");
    }

    /// @dev Cliff equals duration: at end, fully vested.
    function test_TC08_cliffEqualsDurationAtEnd() public {
        uint64 dur = 86400;
        DelegatingVestingWallet w = _deployWallet(beneficiary, startTimestamp, dur, dur, tokenSetterAddr);
        MockForageTokenSimple tok = new MockForageTokenSimple();
        tok.mint(address(w), TOTAL_ALLOCATION);
        vm.prank(tokenSetterAddr);
        w.precommitForageToken(address(tok));
        vm.prank(tokenSetterAddr);
        w.setForageToken(address(tok));

        // At t = start + duration = start + cliff:
        // vested = totalAlloc * duration / duration = totalAlloc (since cliff just passed and t = end)
        assertEq(w.vestedAmount(startTimestamp + dur), TOTAL_ALLOCATION, "cliff=dur: fully vested at end");
    }

    // --- Mid-vesting release sequence ---

    /// @dev Multi-step release at 50%, 75%, and 100%.
    function test_TC08_midVestingReleaseSequence() public {
        uint64 halfDuration = TEAM_DURATION / 2;
        uint64 threeQuarterDuration = TEAM_DURATION * 3 / 4;

        // Release at 50%
        vm.warp(startTimestamp + halfDuration);
        uint256 vested50 = TOTAL_ALLOCATION * uint256(halfDuration) / uint256(TEAM_DURATION);
        vm.prank(beneficiary);
        wallet.release();
        assertEq(wallet.released(), vested50, "released at 50%");

        // Release at 75%
        vm.warp(startTimestamp + threeQuarterDuration);
        uint256 vested75 = TOTAL_ALLOCATION * uint256(threeQuarterDuration) / uint256(TEAM_DURATION);
        vm.prank(beneficiary);
        wallet.release();
        assertEq(wallet.released(), vested75, "cumulative released at 75%");

        // Release at 100%
        vm.warp(startTimestamp + TEAM_DURATION);
        vm.prank(beneficiary);
        wallet.release();
        assertEq(wallet.released(), TOTAL_ALLOCATION, "cumulative released at 100%");

        // Verify beneficiary has all tokens
        assertEq(mockToken.balanceOf(beneficiary), TOTAL_ALLOCATION, "beneficiary has all tokens");
    }

    /// @dev Cumulative release equals totalAllocation.
    function test_TC08_cumulativeReleaseEqualsTotal() public {
        // Release in 4 stages
        uint64[4] memory timestamps = [
            startTimestamp + TEAM_CLIFF,
            startTimestamp + TEAM_DURATION / 3,
            startTimestamp + TEAM_DURATION * 2 / 3,
            startTimestamp + TEAM_DURATION
        ];

        for (uint256 i = 0; i < timestamps.length; i++) {
            vm.warp(timestamps[i]);
            if (wallet.releasable() > 0) {
                vm.prank(beneficiary);
                wallet.release();
            }
        }

        assertEq(wallet.released(), TOTAL_ALLOCATION, "cumulative released = totalAllocation");
    }

    // --- Team canonical boundary milestones ---

    /// @dev 1 second before 1-year cliff: zero.
    function test_TC08_teamCanonical1YearMinus1() public view {
        assertEq(wallet.vestedAmount(startTimestamp + 31_557_600 - 1), 0, "1s before 1y cliff: zero");
    }

    /// @dev Exact 1-year cliff: 25% (5M FORAGE).
    function test_TC08_teamCanonical1Year() public view {
        uint256 expected = 20_000_000e18 * 31_557_600 / 126_230_400;
        assertEq(expected, 5_000_000e18, "sanity: 25% = 5M");
        assertEq(wallet.vestedAmount(startTimestamp + 31_557_600), expected, "1y cliff: 25%");
    }

    /// @dev 2 years: 50% (10M FORAGE).
    function test_TC08_teamCanonical2Years() public view {
        uint256 expected = 20_000_000e18 * 63_115_200 / 126_230_400;
        assertEq(expected, 10_000_000e18, "sanity: 50% = 10M");
        assertEq(wallet.vestedAmount(startTimestamp + 63_115_200), expected, "2y: 50%");
    }

    /// @dev 4 years (end): 100% (20M FORAGE).
    function test_TC08_teamCanonical4Years() public view {
        assertEq(wallet.vestedAmount(startTimestamp + 126_230_400), 20_000_000e18, "4y: 100%");
    }
}

// ============================================================
// TC-14: Team Canonical Integration (R-27)
// ============================================================
contract DelegatingVestingWallet_TC14_TeamCanonical is DelegatingVestingWalletTestBase {
    function setUp() public override {
        super.setUp();
        _fundAndSetTokenDefault();
    }

    /// @dev R-27: Verify all team schedule milestones.
    function test_TC14_milestoneVerification() public view {
        // 0% at start
        assertEq(wallet.vestedAmount(startTimestamp), 0, "0% at start");

        // 0% at 1 second before cliff
        assertEq(wallet.vestedAmount(startTimestamp + 31_557_599), 0, "0% before cliff");

        // 25% at 1 year cliff (5,000,000e18)
        assertEq(wallet.vestedAmount(startTimestamp + 31_557_600), 5_000_000e18, "25% at 1y");

        // 50% at 2 years (10,000,000e18)
        assertEq(wallet.vestedAmount(startTimestamp + 63_115_200), 10_000_000e18, "50% at 2y");

        // 75% at 3 years (15,000,000e18)
        assertEq(wallet.vestedAmount(startTimestamp + 94_672_800), 15_000_000e18, "75% at 3y");

        // 100% at 4 years (20,000,000e18)
        assertEq(wallet.vestedAmount(startTimestamp + 126_230_400), 20_000_000e18, "100% at 4y");
    }

    /// @dev R-27: Release at each milestone with correct amounts.
    function test_TC14_releaseAtMilestones() public {
        // Release at 1 year (25%)
        vm.warp(startTimestamp + 31_557_600);
        vm.prank(beneficiary);
        wallet.release();
        assertEq(wallet.released(), 5_000_000e18, "released at 1y = 25%");
        assertEq(wallet.releasable(), 0, "nothing left after release at 1y");

        // Release at 2 years (50% total, so additional 25% = 5M more)
        vm.warp(startTimestamp + 63_115_200);
        assertEq(wallet.releasable(), 5_000_000e18, "releasable at 2y");
        vm.prank(beneficiary);
        wallet.release();
        assertEq(wallet.released(), 10_000_000e18, "cumulative released at 2y = 50%");

        // Release at 3 years (75% total, additional 25% = 5M more)
        vm.warp(startTimestamp + 94_672_800);
        assertEq(wallet.releasable(), 5_000_000e18, "releasable at 3y");
        vm.prank(beneficiary);
        wallet.release();
        assertEq(wallet.released(), 15_000_000e18, "cumulative released at 3y = 75%");

        // Release at 4 years (100% total, final 25% = 5M more)
        vm.warp(startTimestamp + 126_230_400);
        assertEq(wallet.releasable(), 5_000_000e18, "releasable at 4y");
        vm.prank(beneficiary);
        wallet.release();
        assertEq(wallet.released(), 20_000_000e18, "cumulative released at 4y = 100%");

        // Verify beneficiary has all tokens
        assertEq(mockToken.balanceOf(beneficiary), 20_000_000e18, "beneficiary has 20M");
    }

    /// @dev R-27: releasable returns 0 immediately after each release.
    function test_TC14_releasableZeroAfterEachRelease() public {
        uint64[4] memory milestones = [uint64(31_557_600), uint64(63_115_200), uint64(94_672_800), uint64(126_230_400)];

        for (uint256 i = 0; i < milestones.length; i++) {
            vm.warp(startTimestamp + milestones[i]);
            vm.prank(beneficiary);
            wallet.release();
            assertEq(wallet.releasable(), 0, "releasable = 0 after release at milestone");
        }
    }

    /// @dev R-27: Team canonical parameters are correct.
    function test_TC14_canonicalParameterValues() public view {
        assertEq(wallet.duration(), 126_230_400, "4 * 365.25 * 86400");
        assertEq(wallet.cliff(), 31_557_600, "1 * 365.25 * 86400");
        assertEq(wallet.end(), startTimestamp + 126_230_400, "end = start + 4 years");
    }
}
