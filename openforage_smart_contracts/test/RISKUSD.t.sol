// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/RISKUSDTestBase.sol";
import "./helpers/RISKUSDV2.sol";
import "./helpers/RISKUSDV3.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

// ============================================================
// TC-01: Initialization and Constructor
// ============================================================
contract RISKUSD_TC01_Init is RISKUSDTestBase {
    function test_TC01_initSetsMetadata() public view {
        assertEq(token.name(), "RISKUSD");
        assertEq(token.symbol(), "RISKUSD");
        assertEq(token.owner(), owner);
    }

    function test_TC01_initSetsMinterToZero() public view {
        assertEq(token.minter(), address(0));
    }

    function test_TC01_initLeavesUnpaused() public view {
        assertFalse(token.paused());
    }

    function test_TC01_initRevertsOnZeroOwner() public {
        RISKUSD newImpl = new RISKUSD();
        bytes memory initData = abi.encodeCall(RISKUSD.initialize, (address(0)));

        vm.expectRevert(RISKUSD.ZeroAddress.selector);
        new ERC1967Proxy(address(newImpl), initData);
    }

    function test_TC01_doubleInitReverts() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        token.initialize(owner);
    }

    function test_TC01_constructorDisablesInitializers() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(owner);
    }

    function test_TC01_decimalsReturns6() public view {
        assertEq(token.decimals(), 6);
    }
}

// ============================================================
// TC-02: Minting
// ============================================================
contract RISKUSD_TC02_Mint is RISKUSDTestBase {
    function setUp() public override {
        super.setUp();
        _setupMinter();
    }

    function test_TC02_mintSucceeds() public {
        vm.prank(minterAddr);
        token.mint(alice, 1000e6);

        assertEq(token.balanceOf(alice), 1000e6);
        assertEq(token.totalSupply(), 1000e6);
    }

    function test_TC02_mintRevertsUnauthorized() public {
        vm.prank(attacker);
        vm.expectRevert(RISKUSD.UnauthorizedMinter.selector);
        token.mint(alice, 1000e6);
    }

    function test_TC02_mintRevertsZeroAddress() public {
        vm.prank(minterAddr);
        vm.expectRevert(RISKUSD.ZeroAddress.selector);
        token.mint(address(0), 1000e6);
    }

    function test_TC02_mintRevertsZeroAmount() public {
        vm.prank(minterAddr);
        vm.expectRevert(RISKUSD.ZeroAmount.selector);
        token.mint(alice, 0);
    }

    function test_TC02_mintRevertsWhenPaused() public {
        vm.prank(owner);
        token.pause();

        vm.prank(minterAddr);
        vm.expectRevert(abi.encodeWithSelector(PausableUpgradeable.EnforcedPause.selector));
        token.mint(alice, 1000e6);
    }

    function test_TC02_mintEmitsTransfer() public {
        vm.prank(minterAddr);
        vm.expectEmit(true, true, false, true);
        emit IERC20.Transfer(address(0), alice, 1000e6);
        token.mint(alice, 1000e6);
    }

    function test_TC02_mintMaxOverflowReverts() public {
        // L3 plan line 231: mint(to, type(uint256).max) should revert (overflow in totalSupply)
        // Must have non-zero totalSupply first so that adding type(uint256).max causes overflow
        vm.prank(minterAddr);
        token.mint(alice, 1);

        vm.prank(minterAddr);
        vm.expectRevert();
        token.mint(alice, type(uint256).max);
    }
}

// ============================================================
// TC-03: Burning
// ============================================================
contract RISKUSD_TC03_Burn is RISKUSDTestBase {
    function setUp() public override {
        super.setUp();
        _setupMinter();
        _mintTokens(alice, 1000e6);
    }

    function test_TC03_burnSucceeds() public {
        uint256 supplyBefore = token.totalSupply();

        vm.prank(minterAddr);
        token.burn(alice, 400e6);

        assertEq(token.balanceOf(alice), 600e6);
        assertEq(token.totalSupply(), supplyBefore - 400e6);
    }

    function test_TC03_burnRevertsUnauthorized() public {
        vm.prank(attacker);
        vm.expectRevert(RISKUSD.UnauthorizedMinter.selector);
        token.burn(alice, 100e6);
    }

    function test_TC03_burnRevertsZeroAddress() public {
        vm.prank(minterAddr);
        vm.expectRevert(RISKUSD.ZeroAddress.selector);
        token.burn(address(0), 100e6);
    }

    function test_TC03_burnRevertsZeroAmount() public {
        vm.prank(minterAddr);
        vm.expectRevert(RISKUSD.ZeroAmount.selector);
        token.burn(alice, 0);
    }

    /// @dev OF-M06: burn now bypasses pause for minter
    function test_TC03_burnSucceedsDuringPause() public {
        vm.prank(owner);
        token.pause();

        // OF-M06: minter burn bypasses pause for emergency loss recording
        vm.prank(minterAddr);
        token.burn(alice, 100e6);
        assertEq(token.balanceOf(alice), 900e6);
    }

    function test_TC03_burnRevertsInsufficientBalance() public {
        vm.prank(minterAddr);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 1000e6, 2000e6));
        token.burn(alice, 2000e6);
    }

    function test_TC03_burnEmitsTransfer() public {
        vm.prank(minterAddr);
        vm.expectEmit(true, true, false, true);
        emit IERC20.Transfer(alice, address(0), 400e6);
        token.burn(alice, 400e6);
    }
}

// ============================================================
// TC-04: Authorization Management (setMinter)
// ============================================================
contract RISKUSD_TC04_Auth is RISKUSDTestBase {
    function test_TC04_setMinterSucceeds() public {
        vm.startPrank(owner);
        token.setMinter(minterAddr);
        vm.warp(block.timestamp + 2 days + 1);
        token.finalizeMinter();
        vm.stopPrank();

        assertEq(token.minter(), minterAddr);
    }

    function test_TC04_setMinterRevertsNonOwner() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, attacker));
        token.setMinter(minterAddr);
    }

    function test_TC04_setMinterRevertsZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(RISKUSD.ZeroAddress.selector);
        token.setMinter(address(0));
    }

    function test_TC04_setMinterEmitsEvent() public {
        vm.prank(owner);
        vm.expectEmit(true, true, false, true);
        emit RISKUSD.MinterProposed(address(0), minterAddr);
        token.setMinter(minterAddr);
    }

    function test_TC04_zeroMinterBlocksMinting() public {
        // Minter is zero by default (not set)
        assertEq(token.minter(), address(0));

        // Any address trying to mint should fail
        vm.prank(alice);
        vm.expectRevert(RISKUSD.UnauthorizedMinter.selector);
        token.mint(alice, 100e6);

        // Even owner cannot mint
        vm.prank(owner);
        vm.expectRevert(RISKUSD.UnauthorizedMinter.selector);
        token.mint(alice, 100e6);
    }

    function test_TC04_zeroMinterBlocksBurning() public {
        // Minter is zero by default (not set) — R-29 burn path
        assertEq(token.minter(), address(0));

        // Any address trying to burn should fail
        vm.prank(alice);
        vm.expectRevert(RISKUSD.UnauthorizedMinter.selector);
        token.burn(alice, 100e6);

        // Even owner cannot burn
        vm.prank(owner);
        vm.expectRevert(RISKUSD.UnauthorizedMinter.selector);
        token.burn(alice, 100e6);
    }
}

// ============================================================
// TC-05: Standard ERC-20 Operations
// ============================================================
contract RISKUSD_TC05_ERC20 is RISKUSDTestBase {
    function setUp() public override {
        super.setUp();
        _setupMinter();
        _mintTokens(alice, 1000e6);
    }

    function test_TC05_transfer() public {
        vm.prank(alice);
        token.transfer(bob, 300e6);

        assertEq(token.balanceOf(alice), 700e6);
        assertEq(token.balanceOf(bob), 300e6);
    }

    function test_TC05_transferFrom() public {
        vm.prank(alice);
        token.approve(bob, 500e6);

        vm.prank(bob);
        token.transferFrom(alice, charlie, 300e6);

        assertEq(token.balanceOf(alice), 700e6);
        assertEq(token.balanceOf(charlie), 300e6);
        assertEq(token.allowance(alice, bob), 200e6);
    }

    function test_TC05_approve() public {
        vm.prank(alice);
        token.approve(bob, 500e6);

        assertEq(token.allowance(alice, bob), 500e6);
    }

    function test_TC05_allowance() public view {
        assertEq(token.allowance(alice, bob), 0);
    }

    function test_TC05_balanceOf() public view {
        assertEq(token.balanceOf(alice), 1000e6);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_TC05_totalSupply() public view {
        assertEq(token.totalSupply(), 1000e6);
    }

    function test_TC05_transferWhilePausedReverts() public {
        vm.prank(owner);
        token.pause();

        // OF-029: Transfer MUST revert while paused
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PausableUpgradeable.EnforcedPause.selector));
        token.transfer(bob, 300e6);
    }

    function test_TC05_transferFromWhilePausedReverts() public {
        vm.prank(alice);
        token.approve(bob, 500e6);

        vm.prank(owner);
        token.pause();

        // OF-029: TransferFrom MUST revert while paused
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(PausableUpgradeable.EnforcedPause.selector));
        token.transferFrom(alice, charlie, 300e6);
    }

    function test_TC05_transferRevertsInsufficientBalance() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 1000e6, 2000e6));
        token.transfer(bob, 2000e6);
    }

    function test_TC05_transferFromRevertsInsufficientAllowance() public {
        vm.prank(alice);
        token.approve(bob, 100e6);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 100e6, 500e6));
        token.transferFrom(alice, charlie, 500e6);
    }

    function test_TC05_transferToZeroAddressReverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 100e6);
    }

    function test_TC05_unlimitedAllowanceNotDecremented() public {
        vm.prank(alice);
        token.approve(bob, type(uint256).max);

        vm.prank(bob);
        token.transferFrom(alice, charlie, 100e6);

        // Unlimited allowance should not be decremented
        assertEq(token.allowance(alice, bob), type(uint256).max);
    }
}

// ============================================================
// TC-06: Pause and Unpause (Dual Authorization)
// ============================================================
contract RISKUSD_TC06_Pause is RISKUSDTestBase {
    function setUp() public override {
        super.setUp();
        _setupMinter();
        _setupGovernor();
    }

    function test_TC06_ownerCanPause() public {
        vm.prank(owner);
        token.pause();
        assertTrue(token.paused());
    }

    function test_TC06_ownerCanUnpause() public {
        vm.prank(owner);
        token.pause();

        vm.prank(owner);
        token.unpause();
        assertFalse(token.paused());
    }

    function test_TC06_governorCanPause() public {
        vm.prank(governorAddr);
        token.pause();
        assertTrue(token.paused());
    }

    function test_TC06_governorCanUnpause() public {
        vm.prank(owner);
        token.pause();

        vm.prank(governorAddr);
        token.unpause();
        assertFalse(token.paused());
    }

    function test_TC06_nonAuthorizedCannotPause() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RISKUSD.UnauthorizedPauseControl.selector, attacker));
        token.pause();
    }

    function test_TC06_nonAuthorizedCannotUnpause() public {
        vm.prank(owner);
        token.pause();

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RISKUSD.UnauthorizedPauseControl.selector, attacker));
        token.unpause();
    }

    function test_TC06_pauseBlocksMint() public {
        vm.prank(owner);
        token.pause();

        vm.prank(minterAddr);
        vm.expectRevert(abi.encodeWithSelector(PausableUpgradeable.EnforcedPause.selector));
        token.mint(alice, 100e6);
    }

    /// @dev OF-M06: burn now bypasses pause for minter (emergency loss recording)
    function test_TC06_burnSucceedsDuringPause() public {
        _mintTokens(alice, 1000e6);

        vm.prank(owner);
        token.pause();

        // OF-M06: burn should succeed even when paused
        vm.prank(minterAddr);
        token.burn(alice, 100e6);

        assertEq(token.balanceOf(alice), 900e6, "Burn succeeded during pause");
    }

    function test_TC06_pauseBlocksTransfer() public {
        _mintTokens(alice, 1000e6);

        vm.prank(owner);
        token.pause();

        // OF-029: Transfer MUST revert while paused
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PausableUpgradeable.EnforcedPause.selector));
        token.transfer(bob, 300e6);
    }

    function test_TC06_pauseBlocksTransferFrom() public {
        _mintTokens(alice, 1000e6);

        vm.prank(alice);
        token.approve(bob, 500e6);

        vm.prank(owner);
        token.pause();

        // OF-029: TransferFrom MUST revert while paused
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(PausableUpgradeable.EnforcedPause.selector));
        token.transferFrom(alice, charlie, 300e6);
    }

    function test_TC06_doublePauseReverts() public {
        vm.prank(owner);
        token.pause();

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(PausableUpgradeable.EnforcedPause.selector));
        token.pause();
    }

    function test_TC06_unpauseWhenNotPausedReverts() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(PausableUpgradeable.ExpectedPause.selector));
        token.unpause();
    }

    function test_TC06_setForageGovernorSucceeds() public {
        address newGovernor = makeAddr("newGovernor");

        vm.startPrank(owner);
        token.setForageGovernor(newGovernor);
        vm.warp(block.timestamp + 2 days + 1);
        token.finalizeForageGovernor();
        vm.stopPrank();

        assertEq(token.forageGovernor(), newGovernor);
    }

    function test_TC06_setForageGovernorRevertsNonOwner() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, attacker));
        token.setForageGovernor(governorAddr);
    }

    function test_TC06_setForageGovernorRevertsZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(RISKUSD.ZeroAddress.selector);
        token.setForageGovernor(address(0));
    }
}

// ============================================================
// TC-07: Ownership Transfer (Ownable2Step)
// ============================================================
contract RISKUSD_TC07_Ownership is RISKUSDTestBase {
    function test_TC07_transferOwnership() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(owner);
        token.transferOwnership(newOwner);

        assertEq(token.pendingOwner(), newOwner);
        assertEq(token.owner(), owner); // Not yet transferred
    }

    function test_TC07_acceptOwnership() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(owner);
        token.transferOwnership(newOwner);

        vm.prank(newOwner);
        token.acceptOwnership();

        assertEq(token.owner(), newOwner);
        assertEq(token.pendingOwner(), address(0));
    }

    function test_TC07_renounceOwnership() public {
        vm.prank(owner);
        vm.expectRevert(RISKUSD.RenounceOwnershipDisabled.selector);
        token.renounceOwnership();

        assertEq(token.owner(), owner, "owner should remain unchanged after disabled renounce");
    }

    function test_TC07_nonOwnerCannotTransfer() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, attacker));
        token.transferOwnership(attacker);
    }

    function test_TC07_nonPendingCannotAccept() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(owner);
        token.transferOwnership(newOwner);

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, attacker));
        token.acceptOwnership();
    }
}

// ============================================================
// TC-08: UUPS Upgrade Tests (Multi-Generation)
// ============================================================
contract RISKUSD_TC08_Upgrade is RISKUSDTestBase {
    function test_TC08_ownerCanUpgrade() public {
        _setupMinter();
        _mintTokens(alice, 1000e6);

        RISKUSDV2 v2Impl = new RISKUSDV2();

        vm.prank(owner);
        token.upgradeToAndCall(address(v2Impl), "");

        // Verify upgrade succeeded by calling v2-specific function
        RISKUSDV2 tokenV2 = RISKUSDV2(address(token));
        assertEq(tokenV2.version(), 2);

        // State preserved
        assertEq(token.balanceOf(alice), 1000e6);
        assertEq(token.owner(), owner);
    }

    function test_TC08_nonOwnerCannotUpgrade() public {
        RISKUSDV2 v2Impl = new RISKUSDV2();

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, attacker));
        token.upgradeToAndCall(address(v2Impl), "");
    }

    function test_TC08_multiGenUpgradePreservesState() public {
        _setupMinter();
        _mintTokens(alice, 1000e6);

        // Upgrade to V2
        RISKUSDV2 v2Impl = new RISKUSDV2();
        vm.prank(owner);
        token.upgradeToAndCall(address(v2Impl), "");

        RISKUSDV2 tokenV2 = RISKUSDV2(address(token));
        tokenV2.setNewVariable(42);
        assertEq(tokenV2.newVariable(), 42);

        // Upgrade to V3
        RISKUSDV3 v3Impl = new RISKUSDV3();
        vm.prank(owner);
        token.upgradeToAndCall(address(v3Impl), "");

        RISKUSDV3 tokenV3 = RISKUSDV3(address(token));
        assertEq(tokenV3.version(), 3);

        // All state preserved across both upgrades
        assertEq(token.balanceOf(alice), 1000e6);
        assertEq(token.owner(), owner);
        assertEq(token.minter(), minterAddr);
        assertEq(tokenV3.newVariable(), 42);
    }

    function test_TC08_newImplInitDisabled() public {
        RISKUSDV2 v2Impl = new RISKUSDV2();

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        v2Impl.initialize(owner);

        RISKUSDV3 v3Impl = new RISKUSDV3();

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        v3Impl.initialize(owner);
    }
}

// ============================================================
// TC-09: PHASE4A-017 Transfer Exemption During Pause
// ============================================================
contract RISKUSD_TC09_TransferExempt is RISKUSDTestBase {
    address exemptAddr;

    function setUp() public override {
        super.setUp();
        _setupMinter();
        exemptAddr = makeAddr("exemptProtocol");
    }

    // ----- setTransferExempt: owner-only access -----
    function test_TC09_setTransferExemptOwnerOnly() public {
        vm.prank(owner);
        token.setTransferExempt(exemptAddr, true);
        assertTrue(token.isTransferExempt(exemptAddr), "should be exempt after owner sets");
    }

    function test_TC09_setTransferExemptNonOwnerReverts() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, attacker));
        token.setTransferExempt(exemptAddr, true);
    }

    // ----- setTransferExempt: toggle on and off -----
    function test_TC09_setTransferExemptToggle() public {
        vm.prank(owner);
        token.setTransferExempt(exemptAddr, true);
        assertTrue(token.isTransferExempt(exemptAddr), "should be exempt");

        vm.prank(owner);
        token.setTransferExempt(exemptAddr, false);
        assertFalse(token.isTransferExempt(exemptAddr), "should not be exempt after toggle off");
    }

    // ----- setTransferExempt: event emission -----
    function test_TC09_setTransferExemptEmitsEvent() public {
        vm.expectEmit(true, false, false, true, address(token));
        emit RISKUSD.TransferExemptSet(exemptAddr, true);

        vm.prank(owner);
        token.setTransferExempt(exemptAddr, true);
    }

    // ----- Exempt sender can transfer during pause -----
    function test_TC09_exemptSenderTransfersDuringPause() public {
        _mintTokens(exemptAddr, 1000e6);

        vm.prank(owner);
        token.setTransferExempt(exemptAddr, true);

        vm.prank(owner);
        token.pause();

        // Exempt sender can transfer to non-exempt recipient while paused
        vm.prank(exemptAddr);
        token.transfer(alice, 500e6);

        assertEq(token.balanceOf(alice), 500e6, "alice should receive 500e6");
        assertEq(token.balanceOf(exemptAddr), 500e6, "exempt should have 500e6 remaining");
    }

    // ----- Exempt recipient can receive during pause -----
    function test_TC09_exemptRecipientReceivesDuringPause() public {
        _mintTokens(alice, 1000e6);

        vm.prank(owner);
        token.setTransferExempt(exemptAddr, true);

        vm.prank(owner);
        token.pause();

        // Non-exempt sender cannot route through an exempt recipient while paused
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PausableUpgradeable.EnforcedPause.selector));
        token.transfer(exemptAddr, 500e6);
    }

    // ----- Non-exempt to non-exempt still blocked during pause -----
    function test_TC09_nonExemptTransferBlockedDuringPause() public {
        _mintTokens(alice, 1000e6);

        vm.prank(owner);
        token.pause();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PausableUpgradeable.EnforcedPause.selector));
        token.transfer(bob, 500e6);
    }

    // ----- Exemption revoked: transfers blocked again during pause -----
    function test_TC09_revokedExemptionBlocksTransfer() public {
        _mintTokens(exemptAddr, 1000e6);

        vm.prank(owner);
        token.setTransferExempt(exemptAddr, true);

        // Revoke exemption
        vm.prank(owner);
        token.setTransferExempt(exemptAddr, false);

        vm.prank(owner);
        token.pause();

        // Previously exempt sender can no longer transfer while paused
        vm.prank(exemptAddr);
        vm.expectRevert(abi.encodeWithSelector(PausableUpgradeable.EnforcedPause.selector));
        token.transfer(alice, 500e6);
    }

    // ----- Transfers work normally when not paused (exempt or not) -----
    function test_TC09_transfersWorkWhenNotPaused() public {
        _mintTokens(alice, 1000e6);

        // No exemption needed when not paused
        vm.prank(alice);
        token.transfer(bob, 500e6);

        assertEq(token.balanceOf(bob), 500e6, "normal transfer should work when not paused");
    }

    // ----- setTransferExempt: zero address reverts -----
    function test_TC09_setTransferExemptZeroAddressReverts() public {
        vm.prank(owner);
        vm.expectRevert(RISKUSD.ZeroAddress.selector);
        token.setTransferExempt(address(0), true);
    }

    // ----- isTransferExempt view function -----
    function test_TC09_isTransferExemptDefault() public view {
        assertFalse(token.isTransferExempt(alice), "non-exempt by default");
        assertFalse(token.isTransferExempt(address(0)), "zero address non-exempt by default");
    }
}

// ============================================================
// TC-10: OF-003 Two-Step Minter Handoff (proposeMinter / acceptMinter)
// ============================================================
contract RISKUSD_TC10_TwoStepMinter is RISKUSDTestBase {
    address pendingMinterAddr;

    function setUp() public override {
        super.setUp();
        _setupMinter();
        pendingMinterAddr = makeAddr("pendingMinter");
    }

    function test_TC10_proposeMinter_succeeds() public {
        vm.prank(owner);
        vm.expectEmit(true, true, false, true);
        emit RISKUSD.MinterProposed(minterAddr, pendingMinterAddr);
        token.proposeMinter(pendingMinterAddr);

        assertEq(token.pendingMinter(), pendingMinterAddr);
        // Current minter unchanged
        assertEq(token.minter(), minterAddr);
    }

    function test_TC10_proposeMinter_revertsNonOwner() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, attacker));
        token.proposeMinter(pendingMinterAddr);
    }

    function test_TC10_proposeMinter_revertsZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(RISKUSD.ZeroAddress.selector);
        token.proposeMinter(address(0));
    }

    function test_TC10_acceptMinter_succeeds() public {
        vm.prank(owner);
        token.proposeMinter(pendingMinterAddr);

        vm.warp(block.timestamp + 2 days + 1);

        vm.prank(pendingMinterAddr);
        vm.expectEmit(true, true, false, true);
        emit RISKUSD.MinterUpdated(minterAddr, pendingMinterAddr);
        token.acceptMinter();

        assertEq(token.minter(), pendingMinterAddr);
        assertEq(token.pendingMinter(), address(0));
    }

    function test_TC10_acceptMinter_revertsNotPendingMinter() public {
        vm.prank(owner);
        token.proposeMinter(pendingMinterAddr);

        vm.warp(block.timestamp + 2 days + 1);

        vm.prank(attacker);
        vm.expectRevert(RISKUSD.NotPendingMinter.selector);
        token.acceptMinter();
    }

    /// @dev OF-002 regression test: setMinter() overrides the pending minter proposal,
    /// preventing stale proposals from being accepted after the owner proposes a different address.
    function test_TC10_setMinter_clearsPendingMinter() public {
        address newMinter = makeAddr("newMinter");

        // Step 1: Propose pendingMinterAddr via two-step
        vm.prank(owner);
        token.proposeMinter(pendingMinterAddr);
        assertEq(token.pendingMinter(), pendingMinterAddr);

        // Step 2: Owner overrides via setMinter to newMinter (proposal-only, resets pending)
        vm.prank(owner);
        token.setMinter(newMinter);

        // Step 3: pendingMinter is now newMinter (setMinter overwrites the proposal)
        assertEq(token.pendingMinter(), newMinter, "OF-002: pendingMinter should be overwritten by setMinter");

        // Step 4: Finalize to complete the minter change
        vm.warp(block.timestamp + 2 days + 1);
        vm.prank(owner);
        token.finalizeMinter();
        assertEq(token.minter(), newMinter);
        assertEq(token.pendingMinter(), address(0), "pendingMinter should be cleared after finalize");

        // Step 5: The stale pending minter MUST NOT be able to accept
        vm.prank(pendingMinterAddr);
        vm.expectRevert(RISKUSD.NotPendingMinter.selector);
        token.acceptMinter();
    }

    function test_TC10_proposeMinter_overwrite() public {
        address secondCandidate = makeAddr("secondCandidate");

        // First proposal
        vm.prank(owner);
        token.proposeMinter(pendingMinterAddr);
        assertEq(token.pendingMinter(), pendingMinterAddr);

        // Overwrite with second candidate
        vm.prank(owner);
        token.proposeMinter(secondCandidate);
        assertEq(token.pendingMinter(), secondCandidate);

        vm.warp(block.timestamp + 2 days + 1);

        // First candidate cannot accept
        vm.prank(pendingMinterAddr);
        vm.expectRevert(RISKUSD.NotPendingMinter.selector);
        token.acceptMinter();

        // Second candidate can accept
        vm.prank(secondCandidate);
        token.acceptMinter();
        assertEq(token.minter(), secondCandidate);
        assertEq(token.pendingMinter(), address(0));
    }
}
