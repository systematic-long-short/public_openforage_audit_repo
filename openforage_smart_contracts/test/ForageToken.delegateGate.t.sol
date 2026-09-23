// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/ForageTokenTestBase.sol";
import "./helpers/AllowlistTestBase.sol";
import "../src/interfaces/IAllowlist.sol";

contract ForageTokenDelegateGateTest is ForageTokenTestBase, AllowlistTestBase {
    address internal registrar;
    address internal dexBuyer;
    address internal delegatee;
    address internal verifiedOperator;

    uint256 internal constant DEX_BALANCE = 1_000_000e18;
    uint256 internal constant REGISTRAR_BALANCE = 250_000e18;

    function setUp() public override {
        super.setUp();

        registrar = makeAddr("registrar");
        dexBuyer = makeAddr("dexBuyer");
        delegatee = makeAddr("delegatee");
        verifiedOperator = makeAddr("verifiedOperator");

        address[] memory systemAccounts = new address[](1);
        systemAccounts[0] = address(token);
        address[] memory actors = new address[](1);
        actors[0] = verifiedOperator;
        deployAllowlistHarness(systemAccounts, actors);

        vm.prank(owner);
        token.setAllowlist(address(allowlist));

        allowlist.proposeRegistrar(registrar);
        vm.warp(vm.getBlockTimestamp() + allowlist.FINALIZE_DELAY() + 1);
        allowlist.finalizeRegistrar();

        vm.prank(forageTreasury);
        token.transfer(dexBuyer, DEX_BALANCE);
    }

    function _approveByRegistrar(address account) internal {
        vm.prank(registrar);
        allowlist.approve(account, uint64(block.timestamp + 200 days), 7, keccak256(abi.encode("delegateGate", account)));
    }

    function test_delegateBySig_revertsForUnapprovedCallerAndKeepsDelegationState() public {
        assertFalse(allowlist.isAllowed(dexBuyer), "dex buyer unverified");

        vm.prank(dexBuyer);
        vm.expectRevert(ForageToken.DelegationBySignatureDisabled.selector);
        token.delegateBySig(delegatee, 0, 0, 0, bytes32(0), bytes32(0));

        assertEq(token.delegates(dexBuyer), address(0), "unverified caller delegation stays unset");
    }

    function test_delegateBySig_revertsForVerifiedCallersAndKeepsDelegationState() public {
        assertTrue(allowlist.isAllowed(verifiedOperator), "operator approved by the harness");

        vm.prank(verifiedOperator);
        vm.expectRevert(ForageToken.DelegationBySignatureDisabled.selector);
        token.delegateBySig(delegatee, 1, 0, 27, bytes32(uint256(1)), bytes32(uint256(2)));
        assertEq(token.delegates(verifiedOperator), address(0), "operator delegation stays unset");

        _approveByRegistrar(dexBuyer);
        assertTrue(allowlist.isAllowed(dexBuyer), "dex buyer approved by the registrar");

        vm.prank(dexBuyer);
        vm.expectRevert(ForageToken.DelegationBySignatureDisabled.selector);
        token.delegateBySig(delegatee, 2, 0, 28, bytes32(uint256(3)), bytes32(uint256(4)));
        assertEq(token.delegates(dexBuyer), address(0), "registrar-approved delegation stays unset");
    }

    function test_delegate_unverifiedSelfRevertsCallerNotAllowed() public {
        assertGt(token.balanceOf(dexBuyer), 0, "unverified holder carries a balance");
        assertFalse(allowlist.isAllowed(dexBuyer), "dex buyer unverified");

        vm.prank(dexBuyer);
        vm.expectRevert(abi.encodeWithSelector(IAllowlist.CallerNotAllowed.selector, dexBuyer));
        token.delegate(dexBuyer);

        assertEq(token.delegates(dexBuyer), address(0), "self delegation stays unset");
    }

    function test_delegate_unverifiedOtherRevertsCallerNotAllowed() public {
        assertGt(token.balanceOf(dexBuyer), 0, "unverified holder carries a balance");
        assertFalse(allowlist.isAllowed(dexBuyer), "dex buyer unverified");

        vm.prank(dexBuyer);
        vm.expectRevert(abi.encodeWithSelector(IAllowlist.CallerNotAllowed.selector, dexBuyer));
        token.delegate(delegatee);

        assertEq(token.delegates(dexBuyer), address(0), "delegation to another stays unset");
    }

    function test_delegate_verifiedSelfAndOtherMoveDelegation() public {
        address holder = makeAddr("registrarApprovedHolder");
        vm.prank(forageTreasury);
        token.transfer(holder, REGISTRAR_BALANCE);
        _approveByRegistrar(holder);
        assertTrue(allowlist.isAllowed(holder), "registrar approved the holder");

        vm.prank(holder);
        token.delegate(holder);
        assertEq(token.delegates(holder), holder, "self delegation sets the holder");
        assertEq(token.getVotes(holder), REGISTRAR_BALANCE, "self delegation carries the balance");

        vm.prank(holder);
        token.delegate(delegatee);
        assertEq(token.delegates(holder), delegatee, "delegation moves to the other wallet");
        assertEq(token.getVotes(holder), 0, "delegating away leaves no votes");
        assertEq(token.getVotes(delegatee), REGISTRAR_BALANCE, "delegatee carries the holder balance");
    }

    function test_getVotes_dexBalanceCarriesNoVotesUntilVerifiedAndDelegated() public {
        assertGt(token.balanceOf(dexBuyer), 0, "dex buyer bought a balance");
        assertEq(token.getVotes(dexBuyer), 0, "holder has no votes before verification");
        assertEq(token.getVotes(delegatee), 0, "delegatee has no votes before delegation");

        vm.prank(dexBuyer);
        vm.expectRevert(abi.encodeWithSelector(IAllowlist.CallerNotAllowed.selector, dexBuyer));
        token.delegate(delegatee);

        _approveByRegistrar(dexBuyer);
        assertTrue(allowlist.isAllowed(dexBuyer), "registrar approved the dex buyer");

        vm.prank(dexBuyer);
        token.delegate(delegatee);

        assertEq(token.delegates(dexBuyer), delegatee, "dex balance delegated after verification");
        assertEq(token.getVotes(delegatee), DEX_BALANCE, "delegatee now carries the dex balance");
        assertEq(token.getVotes(dexBuyer), 0, "delegated dex balance carries no direct votes");
    }
}
