// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/DelegatingVestingWallet.sol";
import "./mocks/MockForageTokenSimple.sol";

// ============================================================
// TC-09: Fuzz Tests (R-02, R-05, R-06, R-28, R-29)
// ============================================================
contract DelegatingVestingWallet_TC09_Fuzz is Test {
    /// @dev Fuzz 1: vestedAmount never exceeds totalAllocation for any parameters.
    function testFuzz_TC09_vestedNeverExceedsTotalAllocation(
        uint64 startTs,
        uint64 duration,
        uint64 cliff,
        uint128 totalAllocation,
        uint64 queryTimestamp
    ) public {
        // Bound inputs to valid ranges
        vm.assume(duration > 0);
        vm.assume(cliff <= duration);
        vm.assume(totalAllocation > 0);
        // OF-L15: startTimestamp must be >= block.timestamp
        vm.assume(startTs >= uint64(block.timestamp));

        address ben = makeAddr("fuzzBeneficiary");
        address setter = makeAddr("fuzzSetter");

        DelegatingVestingWallet w = new DelegatingVestingWallet(ben, startTs, duration, cliff, setter);

        MockForageTokenSimple tok = new MockForageTokenSimple();
        tok.mint(address(w), uint256(totalAllocation));

        vm.prank(setter);
        w.precommitForageToken(address(tok));
        vm.prank(setter);
        w.setForageToken(address(tok));

        assertLe(
            w.vestedAmount(queryTimestamp), uint256(totalAllocation), "vestedAmount must never exceed totalAllocation"
        );
    }

    /// @dev Fuzz 2: vestedAmount is monotonically non-decreasing over time.
    function testFuzz_TC09_vestedMonotonicallyNonDecreasing(uint64 t1, uint64 t2) public {
        vm.assume(t1 <= t2);

        address ben = makeAddr("fuzzBeneficiary");
        address setter = makeAddr("fuzzSetter");
        uint64 startTs = uint64(block.timestamp); // OF-L15: must be >= block.timestamp
        uint64 duration = 126_230_400;
        uint64 cliff = 31_557_600;
        uint256 total = 20_000_000e18;

        DelegatingVestingWallet w = new DelegatingVestingWallet(ben, startTs, duration, cliff, setter);

        MockForageTokenSimple tok = new MockForageTokenSimple();
        tok.mint(address(w), total);

        vm.prank(setter);
        w.precommitForageToken(address(tok));
        vm.prank(setter);
        w.setForageToken(address(tok));

        assertLe(w.vestedAmount(t1), w.vestedAmount(t2), "vestedAmount must be monotonically non-decreasing");
    }

    /// @dev Fuzz 3: releasable equals vested minus released at any timestamp.
    function testFuzz_TC09_releasableEqualsVestedMinusReleased(uint64 timestamp) public {
        address ben = makeAddr("fuzzBeneficiary");
        address setter = makeAddr("fuzzSetter");
        uint64 startTs = uint64(block.timestamp);
        uint64 duration = 126_230_400;
        uint64 cliff = 31_557_600;
        uint256 total = 20_000_000e18;

        DelegatingVestingWallet w = new DelegatingVestingWallet(ben, startTs, duration, cliff, setter);

        MockForageTokenSimple tok = new MockForageTokenSimple();
        tok.mint(address(w), total);

        vm.prank(setter);
        w.precommitForageToken(address(tok));
        vm.prank(setter);
        w.setForageToken(address(tok));

        vm.warp(timestamp);

        uint256 vested = w.vestedAmount(uint64(block.timestamp));
        uint256 released_ = w.released();

        if (vested >= released_) {
            assertEq(w.releasable(), vested - released_, "releasable = vested - released (R-29)");
        } else {
            assertEq(w.releasable(), 0, "releasable = 0 when released > vested");
        }
    }

    /// @dev Fuzz 4: zero vested before cliff for any timestamp before cliff.
    function testFuzz_TC09_zeroBeforeCliff(uint64 timestamp) public {
        address ben = makeAddr("fuzzBeneficiary");
        address setter = makeAddr("fuzzSetter");
        uint64 startTs = 1000;
        uint64 duration = 126_230_400;
        uint64 cliff = 31_557_600;
        uint256 total = 20_000_000e18;

        vm.assume(timestamp < startTs + cliff);

        DelegatingVestingWallet w = new DelegatingVestingWallet(ben, startTs, duration, cliff, setter);

        MockForageTokenSimple tok = new MockForageTokenSimple();
        tok.mint(address(w), total);

        vm.prank(setter);
        w.precommitForageToken(address(tok));
        vm.prank(setter);
        w.setForageToken(address(tok));

        assertEq(w.vestedAmount(timestamp), 0, "zero vested before cliff");
    }

    /// @dev Fuzz 5: multiple partial releases never exceed total allocation.
    function testFuzz_TC09_multiplePartialReleasesNeverExceedTotal(uint8 releaseCount) public {
        vm.assume(releaseCount > 0 && releaseCount <= 20);

        address ben = makeAddr("fuzzBeneficiary");
        address setter = makeAddr("fuzzSetter");
        uint64 startTs = uint64(block.timestamp);
        uint64 duration = 126_230_400;
        uint64 cliff = 31_557_600;
        uint256 total = 20_000_000e18;

        DelegatingVestingWallet w = new DelegatingVestingWallet(ben, startTs, duration, cliff, setter);

        MockForageTokenSimple tok = new MockForageTokenSimple();
        tok.mint(address(w), total);

        vm.prank(setter);
        w.precommitForageToken(address(tok));
        vm.prank(setter);
        w.setForageToken(address(tok));

        uint256 cumulativeReleased = 0;
        uint64 timeStep = duration / uint64(releaseCount);

        for (uint8 i = 0; i < releaseCount; i++) {
            uint64 newTime = startTs + cliff + uint64(i) * timeStep;
            if (newTime <= uint64(block.timestamp)) continue;
            vm.warp(newTime);

            uint256 releasable = w.releasable();
            if (releasable > 0) {
                vm.prank(ben);
                w.release();
                cumulativeReleased += releasable;
            }

            // Invariant: released never exceeds total
            assertLe(w.released(), total, "released must never exceed totalAllocation (R-06)");
            assertLe(cumulativeReleased, total, "cumulative released must never exceed totalAllocation");
        }

        // Final release past end
        vm.warp(startTs + duration + 1);
        if (w.releasable() > 0) {
            vm.prank(ben);
            w.release();
        }
        assertEq(w.released(), total, "all tokens released at end");
    }
}
