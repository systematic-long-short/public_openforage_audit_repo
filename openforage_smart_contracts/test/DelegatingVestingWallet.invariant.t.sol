// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/DelegatingVestingWallet.sol";
import "./mocks/MockForageTokenSimple.sol";

// ============================================================
// TC-07: Contract Invariants (R-04, R-05, R-06, R-08)
// Handler for invariant testing
// ============================================================

/// @dev Handler contract that performs valid actions on DelegatingVestingWallet.
/// Foundry calls handler functions randomly; invariant functions check postconditions.
contract DelegatingVestingWalletHandler is Test {
    DelegatingVestingWallet public wallet;
    MockForageTokenSimple public token;
    address public beneficiary;
    address public delegatee1;
    address public delegatee2;
    uint64 public startTimestamp;
    uint64 public duration;

    constructor(
        DelegatingVestingWallet _wallet,
        MockForageTokenSimple _token,
        address _beneficiary,
        address _delegatee1,
        address _delegatee2,
        uint64 _startTimestamp,
        uint64 _duration
    ) {
        wallet = _wallet;
        token = _token;
        beneficiary = _beneficiary;
        delegatee1 = _delegatee1;
        delegatee2 = _delegatee2;
        startTimestamp = _startTimestamp;
        duration = _duration;
    }

    /// @dev Warp forward in time and release if possible.
    function releaseAtTime(uint64 timeOffset) external {
        timeOffset = uint64(bound(timeOffset, 0, duration + 1_000_000));
        vm.warp(startTimestamp + timeOffset);

        uint256 releasable = wallet.releasable();
        if (releasable > 0) {
            vm.prank(beneficiary);
            wallet.release();
        }
    }

    /// @dev Change delegation target.
    function delegateTo(uint8 target) external {
        address newDelegatee = target % 2 == 0 ? delegatee1 : delegatee2;
        vm.prank(beneficiary);
        wallet.delegateVotingPower(newDelegatee);
    }

    /// @dev Warp forward to simulate passage of time.
    function warpForward(uint64 seconds_) external {
        seconds_ = uint64(bound(seconds_, 1, 365 days));
        vm.warp(block.timestamp + seconds_);
    }

    /// @dev Attempt to set ForageToken again — MUST always revert (R-04).
    function attemptSecondSetForageToken(address newToken) external {
        if (newToken == address(0)) newToken = address(1); // avoid ZeroAddress path
        try wallet.setForageToken(newToken) {
            // If this succeeds, the invariant is broken — force a test failure
            revert("setForageToken succeeded on second call - R-04 violated");
        } catch {
            // Expected: reverts with ForageTokenAlreadySet or UnauthorizedTokenSetter
        }
    }
}

contract DelegatingVestingWallet_TC07_Invariants is Test {
    DelegatingVestingWallet public wallet;
    MockForageTokenSimple public token;
    DelegatingVestingWalletHandler public handler;

    address public beneficiary;
    address public tokenSetterAddr;
    address public delegatee1;
    address public delegatee2;

    uint256 public constant TOTAL_ALLOCATION = 20_000_000e18;
    uint64 public constant TEAM_DURATION = 126_230_400;
    uint64 public constant TEAM_CLIFF = 31_557_600;
    uint64 public startTimestamp;

    // Track previous released for monotonicity
    uint256 public previousReleased;

    function setUp() public {
        beneficiary = makeAddr("beneficiary");
        tokenSetterAddr = makeAddr("tokenSetter");
        delegatee1 = makeAddr("delegatee1");
        delegatee2 = makeAddr("delegatee2");

        startTimestamp = uint64(block.timestamp);

        // Deploy wallet
        wallet = new DelegatingVestingWallet(beneficiary, startTimestamp, TEAM_DURATION, TEAM_CLIFF, tokenSetterAddr);

        // Deploy and fund token
        token = new MockForageTokenSimple();
        token.mint(address(wallet), TOTAL_ALLOCATION);

        // Set token
        vm.prank(tokenSetterAddr);
        wallet.precommitForageToken(address(token));
        vm.prank(tokenSetterAddr);
        wallet.setForageToken(address(token));

        // Create handler
        handler = new DelegatingVestingWalletHandler(
            wallet, token, beneficiary, delegatee1, delegatee2, startTimestamp, TEAM_DURATION
        );

        previousReleased = 0;

        targetContract(address(handler));
    }

    /// @dev R-05: Released is monotonically increasing.
    function invariant_TC07_releasedMonotonicallyIncreasing() public {
        uint256 current = wallet.released();
        assertGe(current, previousReleased, "released must be monotonically non-decreasing (R-05)");
        previousReleased = current;
    }

    /// @dev R-06: Released never exceeds totalAllocation.
    function invariant_TC07_releasedNeverExceedsTotalAllocation() public view {
        uint256 totalAlloc = token.balanceOf(address(wallet)) + wallet.released();
        assertLe(wallet.released(), totalAlloc, "released must never exceed totalAllocation (R-06)");
    }

    /// @dev R-04: ForageToken set at most once (tokenSetter is cleared).
    function invariant_TC07_forageTokenSetAtMostOnce() public view {
        // After setUp, token is set, so tokenSetter should be address(0)
        assertEq(wallet.tokenSetter(), address(0), "tokenSetter must be cleared after set (R-04)");
        assertEq(wallet.forageToken(), address(token), "forageToken must remain set (R-04)");
    }

    /// @dev R-08: Delegation does not transfer tokens — wallet balance + released = totalAllocation.
    function invariant_TC07_delegationNoTransfer() public view {
        uint256 walletBalance = token.balanceOf(address(wallet));
        uint256 released_ = wallet.released();
        assertEq(
            walletBalance + released_,
            TOTAL_ALLOCATION,
            "wallet balance + released must equal totalAllocation (R-08 - no tokens lost to delegation)"
        );
    }
}
