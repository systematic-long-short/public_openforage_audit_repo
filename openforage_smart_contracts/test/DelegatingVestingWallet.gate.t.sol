// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/DelegatingVestingWallet.sol";
import "../src/interfaces/IAllowlist.sol";
import "./mocks/MockAllowlist.sol";

contract DelegatingVestingWallet_Gate is Test {
    uint64 internal constant TEAM_DURATION = 126_230_400;
    uint64 internal constant TEAM_CLIFF = 31_557_600;

    MockAllowlist internal mockAllowlist;

    function setUp() public {
        mockAllowlist = new MockAllowlist();
    }

    function _construct(address beneficiary_, uint64 duration_, address tokenSetter_)
        internal
        returns (DelegatingVestingWallet)
    {
        return new DelegatingVestingWallet(
            beneficiary_, uint64(block.timestamp), duration_, TEAM_CLIFF, tokenSetter_, address(mockAllowlist)
        );
    }

    function test_gate_unverifiedBeneficiaryConstructionRevertsCallerNotAllowed() public {
        address caller = makeAddr("gate-unverified-beneficiary");
        address tokenSetter = makeAddr("gate-token-setter");
        mockAllowlist.setAllAllowed(true);
        mockAllowlist.setAllowed(caller, false);

        vm.expectRevert(abi.encodeWithSelector(IAllowlist.CallerNotAllowed.selector, caller));
        _construct(caller, TEAM_DURATION, tokenSetter);
    }

    function test_gate_unverifiedBeneficiaryRevertsBeforeZeroDuration() public {
        address caller = makeAddr("gate-unverified-beneficiary");
        address tokenSetter = makeAddr("gate-token-setter");
        mockAllowlist.setAllAllowed(true);
        mockAllowlist.setAllowed(caller, false);

        vm.expectRevert(abi.encodeWithSelector(IAllowlist.CallerNotAllowed.selector, caller));
        _construct(caller, 0, tokenSetter);
    }

    function test_gate_verifiedBeneficiaryConstructionSucceeds() public {
        address caller = makeAddr("gate-verified-beneficiary");
        address tokenSetter = makeAddr("gate-token-setter");
        mockAllowlist.setAllAllowed(true);

        DelegatingVestingWallet wallet = _construct(caller, TEAM_DURATION, tokenSetter);

        assertEq(wallet.beneficiary(), caller, "beneficiary stored");
        assertEq(wallet.allowlist(), address(mockAllowlist), "allowlist wired at construction");
    }

    function test_gate_unverifiedCallerRevertsBeforeBeneficiaryCheck() public {
        address beneficiary = makeAddr("gate-verified-beneficiary");
        address attacker = makeAddr("gate-unverified-caller");
        address tokenSetter = makeAddr("gate-token-setter");
        mockAllowlist.setAllAllowed(true);

        DelegatingVestingWallet wallet = _construct(beneficiary, TEAM_DURATION, tokenSetter);
        mockAllowlist.setAllowed(attacker, false);

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IAllowlist.CallerNotAllowed.selector, attacker));
        wallet.release();
    }

    function test_gate_setAllowlistRejectsNonAdmin() public {
        address beneficiary = makeAddr("gate-verified-beneficiary");
        address tokenSetter = makeAddr("gate-token-setter");
        address attacker = makeAddr("gate-unverified-caller");
        mockAllowlist.setAllAllowed(true);

        DelegatingVestingWallet wallet = _construct(beneficiary, TEAM_DURATION, tokenSetter);

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(DelegatingVestingWallet.UnauthorizedTokenSetter.selector, attacker));
        wallet.setAllowlist(address(mockAllowlist));
    }
}
