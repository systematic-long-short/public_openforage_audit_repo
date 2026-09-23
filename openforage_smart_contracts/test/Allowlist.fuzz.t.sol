// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/Allowlist.sol";

/// @title AllowlistFuzzTest
/// @notice Randomised pins for the Allowlist registry: the 400-day approval bound, the exact field
///         writes of `approve` and `approveOperator`, and the tightening-only daily cap shrink.
contract AllowlistFuzzTest is Test {
    uint256 internal constant TERM_LIMIT = 400 days;

    address internal constant GUARDIAN = address(0xBEEF);
    address internal constant REGISTRAR = address(0xCAFE);

    Allowlist internal allowlist;
    address[] internal actors;

    function setUp() public {
        Allowlist impl = new Allowlist();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(Allowlist.initialize, (address(this), GUARDIAN, uint64(Allowlist(impl).FINALIZE_DELAY())))
        );
        allowlist = Allowlist(address(proxy));

        allowlist.proposeRegistrar(REGISTRAR);
        vm.warp(block.timestamp + allowlist.FINALIZE_DELAY() + 1);
        allowlist.finalizeRegistrar();

        actors.push(makeAddr("fuzz-actor-0"));
        actors.push(makeAddr("fuzz-actor-1"));
        actors.push(makeAddr("fuzz-actor-2"));
        actors.push(makeAddr("fuzz-actor-3"));
    }

    function _actor(address seed) internal view returns (address) {
        return actors[uint256(uint160(seed)) % actors.length];
    }

    /// @dev The 400-day bound and the exact field writes of `approve`.
    function testFuzz_approve(address accountSeed, uint64 until, uint8 basis, bytes32 caseRef) public {
        address account = _actor(accountSeed);
        uint64 maxUntil = uint64(block.timestamp + TERM_LIMIT);

        if (until > maxUntil) {
            vm.prank(REGISTRAR);
            vm.expectRevert(Allowlist.ExpiryTooFar.selector);
            allowlist.approve(account, until, basis, caseRef);
            return;
        }

        vm.prank(REGISTRAR);
        allowlist.approve(account, until, basis, caseRef);

        assertEq(uint256(allowlist.allowedUntil(account)), uint256(until), "allowedUntil must be written exactly");
        assertEq(uint256(allowlist.basisOf(account)), uint256(basis), "basisOf must be written exactly");
        assertEq(allowlist.caseRefOf(account), caseRef, "caseRefOf must be written exactly");
    }

    /// @dev `approveOperator` writes a non-expiring approval with basis 0 and no case reference.
    function testFuzz_approveOperator(address accountSeed) public {
        address account = _actor(accountSeed);

        allowlist.approveOperator(account);

        assertEq(
            uint256(allowlist.allowedUntil(account)), uint256(type(uint64).max), "operator approval must not expire"
        );
        assertEq(uint256(allowlist.basisOf(account)), 0, "operator approval basis must be zero");
        assertEq(allowlist.caseRefOf(account), bytes32(0), "operator approval caseRef must be zero");
        assertTrue(allowlist.isAllowed(account), "operator must be allowed");
    }

    /// @dev A cap shrink reverts exactly when the new cap is not strictly smaller, else lowers the cap.
    function testFuzz_shrinkApprovalsPerDayCap(uint32 newCap) public {
        uint32 previous = allowlist.approvalsPerDayCap();

        if (newCap >= previous) {
            vm.expectRevert(Allowlist.CapNotShrunk.selector);
            allowlist.shrinkApprovalsPerDayCap(newCap);
            return;
        }

        vm.expectEmit(true, true, true, true, address(allowlist));
        emit Allowlist.ApprovalsPerDayCapShrunk(previous, newCap);
        allowlist.shrinkApprovalsPerDayCap(newCap);

        assertEq(uint256(allowlist.approvalsPerDayCap()), uint256(newCap), "cap must be lowered exactly");
    }
}
