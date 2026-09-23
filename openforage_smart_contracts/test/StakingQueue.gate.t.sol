// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/StakingQueueTestBase.sol";
import "./mocks/MockAllowlist.sol";
import "../src/interfaces/IAllowlist.sol";

// ============================================================
// TC-27: Caller gate negative proof (DEC-1074, DEC-1075)
// An unverified caller is rejected by onlyAllowedCaller before
// any other check of the target function.
// ============================================================
contract StakingQueue_TC27_Gate is StakingQueueTestBase {
    function test_gate_unverifiedJoinQueueRevertsCallerNotAllowed() public {
        address caller = makeAddr("unverified-caller");
        mockAllowlist.setAllowed(caller, false);
        _fundUser(caller, STANDARD_DEPOSIT);

        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(IAllowlist.CallerNotAllowed.selector, caller));
        queue.joinQueue(STANDARD_DEPOSIT, 0);
    }

    function test_gate_unverifiedJoinQueueRevertsBeforeTierCheck() public {
        address caller = makeAddr("unverified-caller-tier");
        mockAllowlist.setAllowed(caller, false);
        _fundUser(caller, STANDARD_DEPOSIT);

        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(IAllowlist.CallerNotAllowed.selector, caller));
        queue.joinQueue(STANDARD_DEPOSIT, 4);
    }

    function test_gate_allowedJoinQueueSucceeds() public {
        address caller = makeAddr("verified-caller");
        _fundUser(caller, STANDARD_DEPOSIT);

        vm.prank(caller);
        queue.joinQueue(STANDARD_DEPOSIT, 0);

        assertEq(queue.tierStandardQueueLength(0), 1, "verified caller joins the standard lane");
        assertEq(queue.totalQueuedRiskusd(), STANDARD_DEPOSIT, "verified caller's deposit is queued");
    }
}
