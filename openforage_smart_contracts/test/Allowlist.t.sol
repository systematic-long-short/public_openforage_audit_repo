// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "../src/Allowlist.sol";

contract AllowlistTest is Test {
    address internal constant GUARDIAN = address(0xA11CE);
    address internal constant REGISTRAR = address(0xB0B);
    address internal constant OUTSIDER = address(0xCAFE);

    Allowlist internal allowlist;

    function setUp() public {
        Allowlist impl = new Allowlist();
        bytes memory initData =
            abi.encodeCall(Allowlist.initialize, (address(this), GUARDIAN, uint64(Allowlist(impl).FINALIZE_DELAY())));
        allowlist = Allowlist(address(new ERC1967Proxy(address(impl), initData)));

        vm.label(GUARDIAN, "guardian");
        vm.label(REGISTRAR, "registrar");
        vm.label(OUTSIDER, "outsider");

        allowlist.proposeRegistrar(REGISTRAR);
        vm.warp(block.timestamp + allowlist.FINALIZE_DELAY() + 1);
        allowlist.finalizeRegistrar();
    }

    function _approve(address account, uint64 until, uint8 basis, bytes32 caseRef) internal {
        vm.prank(REGISTRAR);
        allowlist.approve(account, until, basis, caseRef);
    }

    function test_approveSetsFieldsEmitsAndExpiresAtAllowedUntil() public {
        address investor = makeAddr("investor");
        uint64 until = uint64(block.timestamp + 200 days);
        bytes32 caseRef = keccak256("case-1");

        vm.prank(REGISTRAR);
        vm.expectEmit(true, false, false, true);
        emit Allowlist.Approved(investor, until, 7, caseRef);
        allowlist.approve(investor, until, 7, caseRef);

        assertEq(allowlist.allowedUntil(investor), until, "allowedUntil stored");
        assertEq(allowlist.basisOf(investor), 7, "basis stored");
        assertEq(allowlist.caseRefOf(investor), caseRef, "caseRef stored");
        assertTrue(allowlist.isAllowed(investor), "allowed now");

        vm.warp(until);
        assertTrue(allowlist.isAllowed(investor), "allowed at allowedUntil");

        vm.warp(until + 1);
        assertFalse(allowlist.isAllowed(investor), "expired one second later");
    }

    function test_approveRejectsZeroAccount() public {
        vm.prank(REGISTRAR);
        vm.expectRevert(Allowlist.ZeroAddress.selector);
        allowlist.approve(address(0), uint64(block.timestamp + 1 days), 1, keccak256("case-zero"));
    }

    function test_approveRejectsNonRegistrarBeforeOtherChecks() public {
        vm.prank(OUTSIDER);
        vm.expectRevert(Allowlist.NotRegistrar.selector);
        allowlist.approve(address(0), type(uint64).max, 1, keccak256("case-priority"));
    }

    function test_approveEnforcesFourHundredDayBound() public {
        address investor = makeAddr("investor");
        uint64 maxUntil = uint64(block.timestamp + 400 days);

        vm.prank(REGISTRAR);
        allowlist.approve(investor, maxUntil, 1, keccak256("case-bound"));
        assertEq(allowlist.allowedUntil(investor), maxUntil, "bound accepted");

        vm.prank(REGISTRAR);
        vm.expectRevert(Allowlist.ExpiryTooFar.selector);
        allowlist.approve(investor, maxUntil + 1, 1, keccak256("case-too-far"));
    }

    function test_dailyCapFiftyThenResetsOnNextUtcDay() public {
        uint64 until = uint64(block.timestamp + 30 days);
        for (uint256 i = 0; i < 50; i++) {
            _approve(address(uint160(0x1000 + i)), until, 1, keccak256(abi.encode("cap", i)));
        }
        assertEq(allowlist.approvalsToday(), 50, "fifty approvals counted");

        vm.prank(REGISTRAR);
        vm.expectRevert(Allowlist.DailyCapReached.selector);
        allowlist.approve(address(uint160(0x2000)), until, 1, keccak256("cap-overflow"));

        vm.warp((block.timestamp / 1 days + 1) * 1 days + 1);
        assertEq(allowlist.approvalsToday(), 0, "counter resets with the UTC day");

        vm.prank(REGISTRAR);
        allowlist.approve(address(uint160(0x2001)), uint64(block.timestamp + 30 days), 1, keccak256("cap-next-day"));
        assertEq(allowlist.approvalsToday(), 1, "one approval on the new day");
    }

    function test_revokeByRegistrarClearsAndEmits() public {
        address investor = makeAddr("investor");
        _approve(investor, uint64(block.timestamp + 100 days), 3, keccak256("case-revoke"));

        vm.prank(REGISTRAR);
        vm.expectEmit(true, true, false, false);
        emit Allowlist.Revoked(investor, REGISTRAR);
        allowlist.revoke(investor);

        assertEq(allowlist.allowedUntil(investor), 0, "allowedUntil cleared");
        assertEq(allowlist.basisOf(investor), 0, "basis cleared");
        assertEq(allowlist.caseRefOf(investor), bytes32(0), "caseRef cleared");
        assertFalse(allowlist.isAllowed(investor), "revoked account not allowed");

        _approve(investor, uint64(block.timestamp + 100 days), 3, keccak256("case-reapprove"));
        assertTrue(allowlist.isAllowed(investor), "re-approved account allowed");
    }

    function test_revokeByGuardianClearsAndEmits() public {
        address investor = makeAddr("investor");
        _approve(investor, uint64(block.timestamp + 100 days), 3, keccak256("case-revoke"));

        vm.prank(GUARDIAN);
        vm.expectEmit(true, true, false, false);
        emit Allowlist.Revoked(investor, GUARDIAN);
        allowlist.revoke(investor);

        assertEq(allowlist.allowedUntil(investor), 0, "allowedUntil cleared");
        assertEq(allowlist.basisOf(investor), 0, "basis cleared");
        assertEq(allowlist.caseRefOf(investor), bytes32(0), "caseRef cleared");
        assertFalse(allowlist.isAllowed(investor), "guardian revoked account not allowed");
    }

    function test_revokeRejectsOutsider() public {
        vm.prank(OUTSIDER);
        vm.expectRevert(Allowlist.NotGuardianOrRegistrar.selector);
        allowlist.revoke(makeAddr("investor"));
    }

    function test_operatorApprovalNeverExpiresAndSkipsDailyCap() public {
        address operator = makeAddr("operator");

        vm.expectEmit(true, false, false, true);
        emit Allowlist.OperatorApproved(operator);
        allowlist.approveOperator(operator);

        assertEq(allowlist.allowedUntil(operator), type(uint64).max, "operator never expires");
        assertEq(allowlist.basisOf(operator), 0, "operator basis zero");
        assertEq(allowlist.caseRefOf(operator), bytes32(0), "operator case ref zero");
        assertEq(allowlist.approvalsToday(), 0, "operator approval not counted");

        uint64 until = uint64(block.timestamp + 30 days);
        for (uint256 i = 0; i < 50; i++) {
            _approve(address(uint160(0x3000 + i)), until, 1, keccak256(abi.encode("fill", i)));
        }
        assertEq(allowlist.approvalsToday(), 50, "investor cap reached");

        address secondOperator = makeAddr("secondOperator");
        vm.expectEmit(true, false, false, true);
        emit Allowlist.OperatorApproved(secondOperator);
        allowlist.approveOperator(secondOperator);
        assertTrue(allowlist.isAllowed(secondOperator), "operator allowed at cap");
        assertEq(allowlist.approvalsToday(), 50, "operator approval leaves cap counter");
    }

    function test_operatorApprovalRevocableByRegistrarAndGuardian() public {
        address operator = makeAddr("operator");

        allowlist.approveOperator(operator);
        assertTrue(allowlist.isAllowed(operator), "operator allowed");

        vm.prank(REGISTRAR);
        vm.expectEmit(true, true, false, false);
        emit Allowlist.Revoked(operator, REGISTRAR);
        allowlist.revoke(operator);
        assertEq(allowlist.allowedUntil(operator), 0, "registrar clears operator");
        assertFalse(allowlist.isAllowed(operator), "registrar revoked operator");

        allowlist.approveOperator(operator);
        vm.prank(GUARDIAN);
        vm.expectEmit(true, true, false, false);
        emit Allowlist.Revoked(operator, GUARDIAN);
        allowlist.revoke(operator);
        assertEq(allowlist.allowedUntil(operator), 0, "guardian clears operator");
        assertFalse(allowlist.isAllowed(operator), "guardian revoked operator");
    }

    function test_operatorApprovalRejectsOutsider() public {
        vm.prank(OUTSIDER);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, OUTSIDER));
        allowlist.approveOperator(makeAddr("operator"));
    }

    function test_shrinkCapOwnerAndGuardianEmitAndTightenOnly() public {
        assertEq(allowlist.approvalsPerDayCap(), 50, "default cap");

        vm.expectEmit(false, false, false, true);
        emit Allowlist.ApprovalsPerDayCapShrunk(uint32(50), uint32(40));
        allowlist.shrinkApprovalsPerDayCap(40);
        assertEq(allowlist.approvalsPerDayCap(), 40, "owner shrank cap");

        vm.prank(GUARDIAN);
        vm.expectEmit(false, false, false, true);
        emit Allowlist.ApprovalsPerDayCapShrunk(uint32(40), uint32(30));
        allowlist.shrinkApprovalsPerDayCap(30);
        assertEq(allowlist.approvalsPerDayCap(), 30, "guardian shrank cap");

        vm.expectRevert(Allowlist.CapNotShrunk.selector);
        allowlist.shrinkApprovalsPerDayCap(30);
        vm.expectRevert(Allowlist.CapNotShrunk.selector);
        allowlist.shrinkApprovalsPerDayCap(31);
        assertEq(allowlist.approvalsPerDayCap(), 30, "cap unchanged after rejections");
    }

    function test_shrinkCapRejectsOutsider() public {
        vm.prank(OUTSIDER);
        vm.expectRevert(Allowlist.NotOwnerOrGuardian.selector);
        allowlist.shrinkApprovalsPerDayCap(10);
    }

    function test_setSystemAccountByOwnerSetsAndUnsets() public {
        address account = makeAddr("systemAccount");

        vm.expectEmit(true, false, false, true);
        emit Allowlist.SystemAccountSet(account, true);
        allowlist.setSystemAccount(account, true);
        assertTrue(allowlist.isSystemAccount(account), "system flag set");
        assertTrue(allowlist.isAllowed(account), "system account allowed without expiry");
        assertEq(allowlist.allowedUntil(account), 0, "no expiry stored");

        vm.expectEmit(true, false, false, true);
        emit Allowlist.SystemAccountSet(account, false);
        allowlist.setSystemAccount(account, false);
        assertFalse(allowlist.isSystemAccount(account), "system flag unset");
        assertFalse(allowlist.isAllowed(account), "unset system account not allowed");
    }

    function test_systemRegistrarSetsSystemAccountAndOutsiderRejected() public {
        address systemRegistrar = makeAddr("systemRegistrar");
        address account = makeAddr("systemAccount");

        allowlist.proposeSystemRegistrar(systemRegistrar, true);
        vm.warp(block.timestamp + allowlist.FINALIZE_DELAY() + 1);
        allowlist.finalizeSystemRegistrar();
        assertTrue(allowlist.isSystemRegistrar(systemRegistrar), "system registrar installed");

        vm.prank(systemRegistrar);
        vm.expectEmit(true, false, false, true);
        emit Allowlist.SystemAccountSet(account, true);
        allowlist.setSystemAccount(account, true);
        assertTrue(allowlist.isSystemAccount(account), "system registrar set the account");

        vm.prank(OUTSIDER);
        vm.expectRevert(Allowlist.NotSystemRegistrar.selector);
        allowlist.setSystemAccount(account, true);

        vm.expectRevert(Allowlist.ZeroAddress.selector);
        allowlist.setSystemAccount(address(0), true);
    }

    function test_revokedSystemAccountStaysAllowed() public {
        address account = makeAddr("systemAccount");

        allowlist.setSystemAccount(account, true);
        _approve(account, uint64(block.timestamp + 100 days), 4, keccak256("case-system"));

        vm.prank(REGISTRAR);
        allowlist.revoke(account);
        assertEq(allowlist.allowedUntil(account), 0, "investor approval cleared");
        assertTrue(allowlist.isSystemAccount(account), "system flag survives revoke");
        assertTrue(allowlist.isAllowed(account), "system account still allowed");

        allowlist.setSystemAccount(account, false);
        assertFalse(allowlist.isAllowed(account), "unset system account is not allowed");
    }

    function test_registrarTrioDelayEventsAndCancel() public {
        address newRegistrar = makeAddr("newRegistrar");

        vm.expectEmit(true, false, false, true);
        emit Allowlist.RegistrarProposed(newRegistrar, block.timestamp);
        allowlist.proposeRegistrar(newRegistrar);

        vm.expectRevert(Allowlist.FinalizeDelayNotElapsed.selector);
        allowlist.finalizeRegistrar();

        vm.warp(block.timestamp + allowlist.FINALIZE_DELAY() + 1);

        vm.expectEmit(true, true, false, false);
        emit Allowlist.RegistrarUpdated(REGISTRAR, newRegistrar);
        allowlist.finalizeRegistrar();
        assertEq(allowlist.registrar(), newRegistrar, "registrar rotated");

        address cancelled = makeAddr("cancelledRegistrar");
        vm.expectEmit(true, false, false, true);
        emit Allowlist.RegistrarProposed(cancelled, block.timestamp);
        allowlist.proposeRegistrar(cancelled);

        vm.expectEmit(true, false, false, true);
        emit Allowlist.RegistrarProposalCancelled(cancelled);
        allowlist.cancelRegistrar();

        vm.expectRevert(Allowlist.NoPendingProposal.selector);
        allowlist.finalizeRegistrar();
        assertEq(allowlist.registrar(), newRegistrar, "cancel leaves registrar unchanged");
    }

    function test_guardianTrioDelayEventsAndCancel() public {
        address newGuardian = makeAddr("newGuardian");

        vm.expectEmit(true, false, false, true);
        emit Allowlist.GuardianProposed(newGuardian, block.timestamp);
        allowlist.proposeGuardian(newGuardian);

        vm.expectRevert(Allowlist.FinalizeDelayNotElapsed.selector);
        allowlist.finalizeGuardian();

        vm.warp(block.timestamp + allowlist.FINALIZE_DELAY() + 1);

        vm.expectEmit(true, true, false, false);
        emit Allowlist.GuardianUpdated(GUARDIAN, newGuardian);
        allowlist.finalizeGuardian();
        assertEq(allowlist.guardian(), newGuardian, "guardian rotated");

        address cancelled = makeAddr("cancelledGuardian");
        vm.expectEmit(true, false, false, true);
        emit Allowlist.GuardianProposed(cancelled, block.timestamp);
        allowlist.proposeGuardian(cancelled);

        vm.expectEmit(true, false, false, true);
        emit Allowlist.GuardianProposalCancelled(cancelled);
        allowlist.cancelGuardian();

        vm.expectRevert(Allowlist.NoPendingProposal.selector);
        allowlist.finalizeGuardian();
        assertEq(allowlist.guardian(), newGuardian, "cancel leaves guardian unchanged");
    }

    function test_systemRegistrarTrioDelayEventsAndCancel() public {
        address systemRegistrar = makeAddr("systemRegistrar");

        vm.expectEmit(true, false, false, true);
        emit Allowlist.SystemRegistrarProposed(systemRegistrar, true, block.timestamp);
        allowlist.proposeSystemRegistrar(systemRegistrar, true);

        vm.expectRevert(Allowlist.FinalizeDelayNotElapsed.selector);
        allowlist.finalizeSystemRegistrar();

        vm.warp(block.timestamp + allowlist.FINALIZE_DELAY() + 1);

        vm.expectEmit(true, false, false, true);
        emit Allowlist.SystemRegistrarUpdated(systemRegistrar, true);
        allowlist.finalizeSystemRegistrar();
        assertTrue(allowlist.isSystemRegistrar(systemRegistrar), "system registrar installed");

        address cancelled = makeAddr("cancelledSystemRegistrar");
        vm.expectEmit(true, false, false, true);
        emit Allowlist.SystemRegistrarProposed(cancelled, true, block.timestamp);
        allowlist.proposeSystemRegistrar(cancelled, true);

        vm.expectEmit(true, false, false, true);
        emit Allowlist.SystemRegistrarProposalCancelled(cancelled);
        allowlist.cancelSystemRegistrar();

        vm.expectRevert(Allowlist.NoPendingProposal.selector);
        allowlist.finalizeSystemRegistrar();
        assertFalse(allowlist.isSystemRegistrar(cancelled), "cancel leaves system registrar unset");
    }

    function test_pendingProposalsExpireAfterThirtyDays() public {
        allowlist.proposeRegistrar(makeAddr("expiredRegistrar"));
        allowlist.proposeGuardian(makeAddr("expiredGuardian"));
        allowlist.proposeSystemRegistrar(makeAddr("expiredSystemRegistrar"), true);

        vm.warp(block.timestamp + allowlist.PROPOSAL_EXPIRY() + 1);

        vm.expectRevert(Allowlist.ProposalExpired.selector);
        allowlist.finalizeRegistrar();
        vm.expectRevert(Allowlist.ProposalExpired.selector);
        allowlist.finalizeGuardian();
        vm.expectRevert(Allowlist.ProposalExpired.selector);
        allowlist.finalizeSystemRegistrar();
    }

    function test_delayedTriosRejectNonOwner() public {
        bytes memory unauthorized = abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, OUTSIDER);

        vm.startPrank(OUTSIDER);
        vm.expectRevert(unauthorized);
        allowlist.proposeRegistrar(OUTSIDER);
        vm.expectRevert(unauthorized);
        allowlist.proposeGuardian(OUTSIDER);
        vm.expectRevert(unauthorized);
        allowlist.proposeSystemRegistrar(OUTSIDER, true);
        vm.expectRevert(unauthorized);
        allowlist.finalizeRegistrar();
        vm.expectRevert(unauthorized);
        allowlist.cancelRegistrar();
        vm.expectRevert(unauthorized);
        allowlist.finalizeGuardian();
        vm.expectRevert(unauthorized);
        allowlist.cancelSystemRegistrar();
        vm.stopPrank();
    }
}
