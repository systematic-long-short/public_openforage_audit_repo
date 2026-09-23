// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "../src/AllowlistGatedUpgradeable.sol";
import "../src/interfaces/IAllowlist.sol";
import "./mocks/MockAllowlist.sol";

contract AllowlistGatedHarness is AllowlistGatedUpgradeable {
    error BodyCheckFailed();

    bool public bodyRan;

    function initialize(address allowlist_) external initializer {
        __AllowlistGated_init(allowlist_);
    }

    function initDirect(address allowlist_) external {
        __AllowlistGated_init(allowlist_);
    }

    function setAllowlist(address allowlist_) external {
        _setAllowlist(allowlist_);
    }

    function gated() external onlyAllowedCaller {
        bodyRan = true;
    }

    function gatedWithBodyCheck(bool pass) external onlyAllowedCaller {
        if (!pass) revert BodyCheckFailed();
        bodyRan = true;
    }
}

contract ProbeReturnsNoData {
    fallback() external {}
}

contract ProbeReverts {
    fallback() external {
        revert();
    }
}

contract RevertingAllowlist is IAllowlist {
    function isAllowed(address) external pure returns (bool) {
        revert();
    }

    function allowedUntil(address) external pure returns (uint64) {
        return 0;
    }

    function basisOf(address) external pure returns (uint8) {
        return 0;
    }

    function isSystemAccount(address) external pure returns (bool) {
        return true;
    }
}

contract AllowlistGatedTest is Test {
    MockAllowlist internal mock;
    AllowlistGatedHarness internal gated;

    address internal constant CALLER = address(0xCA11E2);

    function setUp() public {
        mock = new MockAllowlist();
        gated = new AllowlistGatedHarness();
        gated.initialize(address(mock));
    }

    function _expectedSlot() internal pure returns (bytes32) {
        return keccak256(abi.encode(uint256(keccak256("openforage.storage.AllowlistGated")) - 1))
            & ~bytes32(uint256(0xff));
    }

    // ----- Acceptance 3: ERC-7201 slot, zero plain storage -----

    /// @dev The stored allowlist is read back at the ERC-7201 formula slot.
    function test_storageSlotUsesErc7201Formula() public view {
        assertEq(gated.allowlist(), address(mock), "allowlist()");
        assertEq(
            vm.load(address(gated), _expectedSlot()),
            bytes32(uint256(uint160(address(mock)))),
            "ERC-7201 slot holds the allowlist"
        );
    }

    // ----- Acceptance 4: modifier verdict order -----

    /// @dev An unset allowlist is unavailable, never "allowed".
    function test_unsetAllowlistRevertsUnavailable() public {
        AllowlistGatedHarness fresh = new AllowlistGatedHarness();
        assertEq(fresh.allowlist(), address(0), "unset allowlist");
        vm.expectRevert(abi.encodeWithSelector(IAllowlist.AllowlistUnavailable.selector));
        fresh.gated();
    }

    /// @dev A reverting isAllowed call is unavailable, never "allowed".
    function test_revertingAllowlistMeansUnavailable() public {
        RevertingAllowlist reverting = new RevertingAllowlist();
        gated.setAllowlist(address(reverting));
        vm.expectRevert(abi.encodeWithSelector(IAllowlist.AllowlistUnavailable.selector));
        gated.gated();
    }

    /// @dev A denied caller reverts and the gated body does not run.
    function test_deniedCallerRevertsCallerNotAllowedAndBodyDoesNotRun() public {
        mock.setAllowed(CALLER, false);
        vm.prank(CALLER);
        vm.expectRevert(abi.encodeWithSelector(IAllowlist.CallerNotAllowed.selector, CALLER));
        gated.gated();
        assertFalse(gated.bodyRan(), "body must not run for a denied caller");
    }

    /// @dev The caller verdict precedes every body check of the gated function.
    function test_deniedCallerVerdictPrecedesBodyChecks() public {
        mock.setAllowed(CALLER, false);
        vm.prank(CALLER);
        vm.expectRevert(abi.encodeWithSelector(IAllowlist.CallerNotAllowed.selector, CALLER));
        gated.gatedWithBodyCheck(false);
        assertFalse(gated.bodyRan(), "body must not run for a denied caller");
    }

    /// @dev An allowed caller runs the gated body.
    function test_allowedCallerRunsBody() public {
        mock.setAllowed(CALLER, true);
        vm.prank(CALLER);
        gated.gated();
        assertTrue(gated.bodyRan(), "body must run for an allowed caller");
    }

    /// @dev An allowed caller passes the gate and reaches the body check.
    function test_allowedCallerReachesBodyCheck() public {
        mock.setAllowed(CALLER, true);
        vm.prank(CALLER);
        vm.expectRevert(AllowlistGatedHarness.BodyCheckFailed.selector);
        gated.gatedWithBodyCheck(false);
        assertFalse(gated.bodyRan(), "body must not complete when its own check fails");
    }

    // ----- Acceptance 5: probe, store, event, init -----

    function test_setAllowlistRejectsZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(IAllowlist.AllowlistUnavailable.selector));
        gated.setAllowlist(address(0));
    }

    function test_setAllowlistRejectsAddressWithoutCode() public {
        vm.expectRevert(abi.encodeWithSelector(IAllowlist.AllowlistUnavailable.selector));
        gated.setAllowlist(address(0xB0B));
    }

    function test_setAllowlistRejectsRevertingProbe() public {
        ProbeReverts probe = new ProbeReverts();
        vm.expectRevert(abi.encodeWithSelector(IAllowlist.AllowlistUnavailable.selector));
        gated.setAllowlist(address(probe));
    }

    function test_setAllowlistRejectsProbeWithShortReturn() public {
        ProbeReturnsNoData probe = new ProbeReturnsNoData();
        vm.expectRevert(abi.encodeWithSelector(IAllowlist.AllowlistUnavailable.selector));
        gated.setAllowlist(address(probe));
    }

    function test_setAllowlistStoresAndEmits() public {
        MockAllowlist next = new MockAllowlist();
        vm.expectEmit(true, true, false, true, address(gated));
        emit AllowlistGatedUpgradeable.AllowlistSet(address(mock), address(next));
        gated.setAllowlist(address(next));

        assertEq(gated.allowlist(), address(next), "allowlist() after set");
        assertEq(
            vm.load(address(gated), _expectedSlot()),
            bytes32(uint256(uint160(address(next)))),
            "ERC-7201 slot after set"
        );
    }

    function test_initSetsAllowlistAndEmits() public {
        AllowlistGatedHarness fresh = new AllowlistGatedHarness();
        vm.expectEmit(true, true, false, true, address(fresh));
        emit AllowlistGatedUpgradeable.AllowlistSet(address(0), address(mock));
        fresh.initialize(address(mock));
        assertEq(fresh.allowlist(), address(mock), "init sets the allowlist");
    }

    /// @dev `__AllowlistGated_init` is onlyInitializing; a direct call outside one reverts.
    function test_initDirectOutsideInitializingReverts() public {
        AllowlistGatedHarness fresh = new AllowlistGatedHarness();
        vm.expectRevert(Initializable.NotInitializing.selector);
        fresh.initDirect(address(mock));
    }

    function test_reinitializeReverts() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        gated.initialize(address(mock));
    }

    // ----- Acceptance 6: mock answers -----

    function test_mockDefaultsDenyAndExplicitAllow() public view {
        assertFalse(mock.isAllowed(CALLER), "default is denied");
    }

    function test_mockExplicitAllowAndDeny() public {
        mock.setAllowed(CALLER, true);
        assertTrue(mock.isAllowed(CALLER), "explicit allow");
        mock.setAllowed(CALLER, false);
        assertFalse(mock.isAllowed(CALLER), "explicit deny");
    }

    function test_mockAllAllowedHonoursExplicitDeny() public {
        mock.setAllAllowed(true);
        assertTrue(mock.isAllowed(address(0xD00D)), "all allowed");
        mock.setAllowed(address(0xD00D), false);
        assertFalse(mock.isAllowed(address(0xD00D)), "explicit deny wins over all-allowed");
    }

    function test_mockAuxiliaryViews() public {
        mock.setAllowedUntil(CALLER, 1234);
        mock.setBasis(CALLER, 3);
        mock.setSystemAccount(CALLER, true);
        assertEq(mock.allowedUntil(CALLER), 1234, "allowedUntil");
        assertEq(mock.basisOf(CALLER), 3, "basisOf");
        assertTrue(mock.isSystemAccount(CALLER), "isSystemAccount");
    }
}
