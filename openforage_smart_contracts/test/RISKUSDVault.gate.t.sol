// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../src/interfaces/IAllowlist.sol";
import "./helpers/RISKUSDVaultTestBase.sol";
import "./mocks/MockAllowlist.sol";

/// @dev KYC-02/KYC-03: the caller gate runs before any deposit check and the basis-2
/// first-deposit minimum refuses a short first deposit before any USDC moves.
contract RISKUSDVault_Gate is RISKUSDVaultTestBase {
    address internal caller;

    function setUp() public override {
        super.setUp();
        caller = makeAddr("unverified");
    }

    function test_gate_unverifiedDepositRevertsCallerNotAllowed() public {
        allowlistMock.setAllowed(caller, false);
        _fundAndApproveUSDC(caller, 1_000e6);

        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(IAllowlist.CallerNotAllowed.selector, caller));
        vault.deposit(1_000e6);
    }

    function test_gate_gateRunsBeforeZeroAmountCheck() public {
        allowlistMock.setAllowed(caller, false);

        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(IAllowlist.CallerNotAllowed.selector, caller));
        vault.deposit(0);
    }

    function test_gate_allowedDepositSucceeds() public {
        allowlistMock.setAllAllowed(true);
        _fundAndApproveUSDC(caller, 1_000e6);

        vm.prank(caller);
        vault.deposit(1_000e6);

        assertEq(riskusd.balanceOf(caller), 1_000e6, "allowed caller deposits");
    }

    function test_gate_setAllowlistIsOwnerOnly() public {
        MockAllowlist next = new MockAllowlist();
        next.setAllAllowed(true);

        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", caller));
        vault.setAllowlist(address(next));
    }

    function test_gate_basis2FirstDepositBelowMinimumReverts() public {
        allowlistMock.setBasis(caller, 2);
        vm.prank(owner);
        vault.setMinimumFirstDeposit(2, 200_000e6);
        assertEq(vault.minimumFirstDeposit(2), 200_000e6, "basis-2 minimum stored");
        _fundAndApproveUSDC(caller, 199_999e6);

        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(RISKUSDVault.FirstDepositBelowMinimum.selector, 199_999e6, 200_000e6));
        vault.deposit(199_999e6);
    }

    function test_gate_basis2MinimumMetThenLaterDepositFree() public {
        allowlistMock.setBasis(caller, 2);
        vm.prank(owner);
        vault.setMinimumFirstDeposit(2, 200_000e6);

        _deposit(caller, 200_000e6);
        assertEq(riskusd.balanceOf(caller), 200_000e6, "first deposit at the minimum");

        _deposit(caller, 1e6);
        assertEq(riskusd.balanceOf(caller), 200_001e6, "later deposit is not bound by the minimum");
    }

    function test_gate_otherBasisIgnoresMinimum() public {
        allowlistMock.setBasis(caller, 1);
        vm.prank(owner);
        vault.setMinimumFirstDeposit(2, 200_000e6);

        _deposit(caller, 1e6);
        assertEq(riskusd.balanceOf(caller), 1e6, "basis 1 is untouched");
    }
}
