// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {SymTest} from "halmos-cheatcodes/SymTest.sol";
import "../helpers/RISKUSDVaultTestBase.sol";

/// @title Halmos formal harness for crown invariant I-1 (solvency).
/// @notice Symbolically explores deposit / redeem / deployCapital / returnCapital
///         under bounded inputs and asserts the I-1 backing-supply relation
///         after each successful operation:
///
///             vaultUsdc + min(bookValue, adjustedNAV) >= RISKUSD.totalSupply()
///
/// where `vaultUsdc = vault.vaultUsdcBalance()`, `bookValue = vault.totalDeployed()`,
/// and `adjustedNAV = vault.adjustedCustodianNAV()`. Reverting paths are not
/// counterexamples (vault state is unchanged), so the harness focuses on
/// post-success states.
///
/// Run with halmos:
///   halmos --match-test "check_" --match-contract "Halmos_I1_Solvency"
///
/// `forge test` will compile this file but not execute the `check_*` functions
/// (they do not match the default Foundry test prefix), which is the intended
/// separation between formal and Foundry runs.
contract Halmos_I1_Solvency is RISKUSDVaultTestBase, SymTest {
    /// @dev Bounded amount domain. Wide enough to exercise solvency math, narrow
    ///      enough to keep the SMT solver tractable. 1 .. 1_000_000e6 USDC.
    uint256 internal constant MAX_AMOUNT = 1_000_000e6;

    function setUp() public override {
        super.setUp();
        _setupAllRoles();

        // Expand setup-only caps so this harness isolates I-1 (solvency) from
        // launch-pacing controls (per-block mint cap, weekly mint cap, weekly
        // redemption cap, deployment ratio, deployment buffer). Pacing has its
        // own tests; widening here keeps the symbolic model focused.
        vm.startPrank(owner);
        vault.setPerBlockMintCap(10000, type(uint256).max);
        vault.setWeeklyMintCapBps(20000); // 2x supply growth window (default)
        vault.setWeeklyRedemptionCapBps(10000); // 100% weekly redemption cap
        vault.setMaxDeploymentRatioBps(10000); // 100% deployment ratio
        vault.setDeploymentBufferBps(0); // disable cross-vault buffer
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // I-1 invariant assertion helper
    // ------------------------------------------------------------------

    function _assertI1() internal view {
        uint256 vaultUsdc = vault.vaultUsdcBalance();
        uint256 bookValue = vault.totalDeployed();
        uint256 adjustedNav = vault.adjustedCustodianNAV();
        uint256 conservative = adjustedNav < bookValue ? adjustedNav : bookValue;
        uint256 backing = vaultUsdc + conservative;
        uint256 supply = riskusd.totalSupply();
        assert(backing >= supply);
    }

    // ------------------------------------------------------------------
    // Symbolic check_* entry points (Halmos)
    // ------------------------------------------------------------------

    /// @notice I-1 holds after a successful symbolic deposit.
    function check_deposit_preservesSolvency(uint256 amount) public {
        vm.assume(amount > 0);
        vm.assume(amount <= MAX_AMOUNT);

        _fundAndApproveUSDC(alice, amount);

        vm.prank(alice);
        vault.deposit(amount);

        _assertI1();
    }

    /// @notice I-1 holds after a successful symbolic redeem.
    /// @dev A prior deposit establishes RISKUSD supply for alice to redeem.
    function check_redeem_preservesSolvency(uint256 depositAmount, uint256 redeemAmount) public {
        vm.assume(depositAmount > 0);
        vm.assume(depositAmount <= MAX_AMOUNT);
        vm.assume(redeemAmount > 0);
        vm.assume(redeemAmount <= depositAmount);

        // Establish supply via initial deposit.
        _fundAndApproveUSDC(alice, depositAmount);
        vm.prank(alice);
        vault.deposit(depositAmount);

        // Approve and redeem.
        _approveVaultRISKUSD(alice, redeemAmount);
        vm.prank(alice);
        vault.redeem(redeemAmount);

        _assertI1();
    }

    /// @notice I-1 holds after a successful symbolic deployCapital.
    /// @dev A prior deposit establishes vault USDC balance and depositor USDC.
    function check_deployCapital_preservesSolvency(uint256 depositAmount, uint256 deployAmount) public {
        vm.assume(depositAmount > 0);
        vm.assume(depositAmount <= MAX_AMOUNT);
        vm.assume(deployAmount > 0);
        vm.assume(deployAmount <= depositAmount);

        // Establish vault balance and depositor USDC.
        _fundAndApproveUSDC(alice, depositAmount);
        vm.prank(alice);
        vault.deposit(depositAmount);

        vm.prank(custodianAddr);
        vault.deployCapital(deployAmount);

        _assertI1();
    }

    /// @notice I-1 holds after a successful symbolic returnCapital.
    /// @dev returnCapital lacks an in-function _assertSolvency() call, so the
    ///      solver must reason that returning USDC strictly preserves I-1
    ///      (vaultUsdc grows by `returnAmount`, bookValue drops by the same).
    function check_returnCapital_preservesSolvency(uint256 depositAmount, uint256 deployAmount, uint256 returnAmount)
        public
    {
        vm.assume(depositAmount > 0);
        vm.assume(depositAmount <= MAX_AMOUNT);
        vm.assume(deployAmount > 0);
        vm.assume(deployAmount <= depositAmount);
        vm.assume(returnAmount > 0);
        vm.assume(returnAmount <= deployAmount);

        // Establish vault state with deployed capital.
        _fundAndApproveUSDC(alice, depositAmount);
        vm.prank(alice);
        vault.deposit(depositAmount);

        vm.prank(custodianAddr);
        vault.deployCapital(deployAmount);

        // Custodian returns part of the deployed USDC. The USDC is already in
        // the custodian's wallet from the deployCapital transfer; only an
        // approval is needed for vault to pull it back.
        vm.prank(custodianAddr);
        usdc.approve(address(vault), returnAmount);

        vm.prank(custodianAddr);
        vault.returnCapital(returnAmount);

        _assertI1();
    }
}
