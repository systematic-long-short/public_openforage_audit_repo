// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/ForageTokenTestBase.sol";
import "../src/interfaces/IAllowlist.sol";

contract ForageToken_TC17_CallerGate is ForageTokenTestBase {
    function test_gate_unverifiedDelegateRevertsCallerNotAllowed() public {
        address caller = makeAddr("unverifiedCaller");
        allowlistMock.setAllowed(caller, false);

        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(IAllowlist.CallerNotAllowed.selector, caller));
        token.delegate(caller);
    }

    function test_gate_allowedDelegateSucceeds() public {
        address caller = makeAddr("verifiedCaller");

        allowlistMock.setAllAllowed(true);
        vm.prank(caller);
        token.delegate(caller);

        assertEq(token.delegates(caller), caller);
    }
}
