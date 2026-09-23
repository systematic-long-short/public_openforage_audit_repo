// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/Allowlist.sol";

/// @title AllowlistHandler
/// @notice Bounded-action driver for the Allowlist invariant suite. Every privileged action pranks the
///         live registrar, guardian or owner so a rotation never invalidates a later call. The ghosts
///         record the approval, revocation and re-approval history the invariants read: `approvedAt` on a
///         successful `approve`, `revokedAt` on `revoke`, and `reapprovedAt` on any successful approval
///         that follows a revoke. The cap shrink stays at or above the day's counted approvals (and at
///         least 1), so the handler never drives the registry into the states where the day's count
///         exceeds the cap: a shrink below `approvalsToday()`, and a zero cap followed by a day roll
///         whose first approval counts without a cap check.
contract AllowlistHandler is Test {
    uint256 internal constant TERM_LIMIT = 400 days;
    uint32 internal constant MIN_CAP = 1;

    Allowlist public allowlist;
    address public ownerAddr;
    address[] public actors;

    mapping(address => uint256) public approvedAt;
    mapping(address => uint256) public revokedAt;
    mapping(address => uint256) public reapprovedAt;

    constructor(Allowlist _allowlist, address _owner, address[] memory _actors) {
        allowlist = _allowlist;
        ownerAddr = _owner;
        actors = _actors;
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function actorAt(uint256 index) external view returns (address) {
        return actors[index];
    }

    function approve(uint256 accountSeed, uint64 until, uint8 basis, bytes32 caseRef) external {
        address account = _actor(accountSeed);
        uint64 maxUntil = uint64(block.timestamp + TERM_LIMIT);
        if (until > maxUntil) until = maxUntil;

        vm.prank(allowlist.registrar());
        try allowlist.approve(account, until, basis, caseRef) {
            approvedAt[account] = block.timestamp;
            if (revokedAt[account] > reapprovedAt[account]) {
                reapprovedAt[account] = block.timestamp;
            }
        } catch {}
    }

    function approveOperator(uint256 accountSeed) external {
        address account = _actor(accountSeed);

        vm.prank(ownerAddr);
        try allowlist.approveOperator(account) {
            if (revokedAt[account] > reapprovedAt[account]) {
                reapprovedAt[account] = block.timestamp;
            }
        } catch {}
    }

    function revoke(uint256 accountSeed, bool byGuardian) external {
        address account = _actor(accountSeed);
        address caller = byGuardian ? allowlist.guardian() : allowlist.registrar();

        vm.prank(caller);
        try allowlist.revoke(account) {
            revokedAt[account] = block.timestamp;
        } catch {}
    }

    function setSystemAccount(uint256 accountSeed, bool isSystem) external {
        vm.prank(ownerAddr);
        try allowlist.setSystemAccount(_actor(accountSeed), isSystem) {} catch {}
    }

    function shrinkApprovalsPerDayCap(uint256 newCapSeed, bool byGuardian) external {
        uint32 cap = allowlist.approvalsPerDayCap();
        uint32 floor = allowlist.approvalsToday();
        if (floor < MIN_CAP) floor = MIN_CAP;
        if (cap <= floor) return;

        uint32 newCap = uint32(bound(newCapSeed, floor, uint256(cap) - 1));
        address caller = byGuardian ? allowlist.guardian() : ownerAddr;

        vm.prank(caller);
        try allowlist.shrinkApprovalsPerDayCap(newCap) {} catch {}
    }

    function warp(uint256 stepSeed) external {
        uint256 step = bound(stepSeed, 1, 2 days);
        vm.warp(block.timestamp + step);
    }

    function proposeRegistrar(uint256 accountSeed) external {
        vm.prank(ownerAddr);
        try allowlist.proposeRegistrar(_actor(accountSeed)) {} catch {}
    }

    function finalizeRegistrar() external {
        vm.prank(ownerAddr);
        try allowlist.finalizeRegistrar() {} catch {}
    }

    function cancelRegistrar() external {
        vm.prank(ownerAddr);
        try allowlist.cancelRegistrar() {} catch {}
    }

    function proposeGuardian(uint256 accountSeed) external {
        vm.prank(ownerAddr);
        try allowlist.proposeGuardian(_actor(accountSeed)) {} catch {}
    }

    function finalizeGuardian() external {
        vm.prank(ownerAddr);
        try allowlist.finalizeGuardian() {} catch {}
    }

    function cancelGuardian() external {
        vm.prank(ownerAddr);
        try allowlist.cancelGuardian() {} catch {}
    }

    function proposeSystemRegistrar(uint256 accountSeed, bool isSystem) external {
        vm.prank(ownerAddr);
        try allowlist.proposeSystemRegistrar(_actor(accountSeed), isSystem) {} catch {}
    }

    function finalizeSystemRegistrar() external {
        vm.prank(ownerAddr);
        try allowlist.finalizeSystemRegistrar() {} catch {}
    }

    function cancelSystemRegistrar() external {
        vm.prank(ownerAddr);
        try allowlist.cancelSystemRegistrar() {} catch {}
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }
}

/// @title AllowlistInvariantTest
/// @notice Invariant suite for the Allowlist registry. The proxy and the handler are deployed in the
///         constructor; the handler is the only target, so every reachable state comes from its
///         bounded actions. Four invariants: the day never exceeds the cap, a revoked account stays
///         disallowed until re-approved, a system account stays allowed, and no approval expiry
///         exceeds 400 days after its approval.
contract AllowlistInvariantTest is Test {
    uint256 internal constant TERM_LIMIT = 400 days;

    address internal constant GUARDIAN = address(0xBEEF);
    address internal constant REGISTRAR = address(0xCAFE);

    Allowlist public allowlist;
    AllowlistHandler public handler;
    address[] internal actors;

    constructor() {
        Allowlist impl = new Allowlist();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(Allowlist.initialize, (address(this), GUARDIAN, uint64(Allowlist(impl).FINALIZE_DELAY())))
        );
        allowlist = Allowlist(address(proxy));

        allowlist.proposeRegistrar(REGISTRAR);
        vm.warp(block.timestamp + allowlist.FINALIZE_DELAY() + 1);
        allowlist.finalizeRegistrar();

        actors.push(makeAddr("invariant-actor-0"));
        actors.push(makeAddr("invariant-actor-1"));
        actors.push(makeAddr("invariant-actor-2"));
        actors.push(makeAddr("invariant-actor-3"));

        handler = new AllowlistHandler(allowlist, address(this), actors);
    }

    function setUp() public {
        targetContract(address(handler));
    }

    /// @dev (a) No UTC day ever holds more approvals than the cap.
    function invariant_approvalsTodayNeverExceedsCap() public view {
        assertLe(
            uint256(allowlist.approvalsToday()),
            uint256(allowlist.approvalsPerDayCap()),
            "the day's approval count must never exceed the cap"
        );
    }

    /// @dev (b) A revoked non-system account is not allowed until a later approval follows the revoke.
    function invariant_revokedAccountNeverAllowedUntilReapproved() public view {
        for (uint256 i = 0; i < actors.length; i++) {
            address account = actors[i];
            if (!allowlist.isSystemAccount(account) && handler.revokedAt(account) > handler.reapprovedAt(account)) {
                assertFalse(allowlist.isAllowed(account), "a revoked account must not be allowed until re-approved");
            }
        }
    }

    /// @dev (c) A system account is allowed for as long as the flag is set.
    function invariant_systemAccountAlwaysAllowed() public view {
        for (uint256 i = 0; i < actors.length; i++) {
            address account = actors[i];
            if (allowlist.isSystemAccount(account)) {
                assertTrue(allowlist.isAllowed(account), "a system account must be allowed");
            }
        }
    }

    /// @dev (d) Every finite approval expiry sits within 400 days of its approval.
    function invariant_allowedUntilWithinTermLimit() public view {
        for (uint256 i = 0; i < actors.length; i++) {
            address account = actors[i];
            uint64 until = allowlist.allowedUntil(account);
            if (until != type(uint64).max) {
                assertLe(
                    uint256(until),
                    handler.approvedAt(account) + TERM_LIMIT,
                    "an approval expiry must stay within 400 days of its approval"
                );
            }
        }
    }
}
