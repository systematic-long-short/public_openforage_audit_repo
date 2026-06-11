// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/DelegatingVestingWallet.sol";
import "../mocks/MockForageTokenSimple.sol";

/// @dev Abstract base for DelegatingVestingWallet tests.
/// Deploys the wallet with team canonical parameters and a simple mock token.
/// setUp() will revert against the stub (constructor reverts "STUB: not implemented"),
/// causing all tests to FAIL — which is the correct behavior before implementation.
abstract contract DelegatingVestingWalletTestBase is Test {
    DelegatingVestingWallet public wallet;
    MockForageTokenSimple public mockToken;

    address public beneficiary;
    address public tokenSetterAddr;
    address public attacker;
    address public delegatee1;
    address public delegatee2;

    uint256 public constant TOTAL_ALLOCATION = 20_000_000e18;
    uint256 public constant SMALL_ALLOCATION = 1_000e18;
    uint64 public constant TEAM_DURATION = 126_230_400; // 4 * 365.25 * 86400
    uint64 public constant TEAM_CLIFF = 31_557_600; // 1 * 365.25 * 86400

    uint64 public startTimestamp;

    function setUp() public virtual {
        beneficiary = makeAddr("beneficiary");
        tokenSetterAddr = makeAddr("tokenSetter");
        attacker = makeAddr("attacker");
        delegatee1 = makeAddr("delegatee1");
        delegatee2 = makeAddr("delegatee2");

        startTimestamp = uint64(block.timestamp);

        // Deploy mock token
        mockToken = new MockForageTokenSimple();

        // Deploy wallet — against the stub, this reverts with "STUB: not implemented",
        // causing setUp to fail and all tests in the contract to FAIL.
        wallet = new DelegatingVestingWallet(beneficiary, startTimestamp, TEAM_DURATION, TEAM_CLIFF, tokenSetterAddr);
    }

    /// @dev Fund the wallet with FORAGE and set the token via tokenSetter.
    function _fundAndSetToken(uint256 amount) internal {
        // Mint tokens to the wallet
        mockToken.mint(address(wallet), amount);

        // Set token as tokenSetter
        vm.prank(tokenSetterAddr);
        wallet.precommitForageToken(address(mockToken));
        vm.prank(tokenSetterAddr);
        wallet.setForageToken(address(mockToken));
    }

    /// @dev Fund wallet with TOTAL_ALLOCATION and set the token.
    function _fundAndSetTokenDefault() internal {
        _fundAndSetToken(TOTAL_ALLOCATION);
    }

    /// @dev Deploy a fresh wallet with custom parameters.
    function _deployWallet(address beneficiary_, uint64 start_, uint64 duration_, uint64 cliff_, address tokenSetter_)
        internal
        returns (DelegatingVestingWallet)
    {
        return new DelegatingVestingWallet(beneficiary_, start_, duration_, cliff_, tokenSetter_);
    }
}
