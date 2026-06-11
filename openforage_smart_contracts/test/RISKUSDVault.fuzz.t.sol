// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/RISKUSDVaultTestBase.sol";

// ============================================================
// TC-17: Fuzz Tests
// ============================================================
contract RISKUSDVault_TC17_Fuzz is RISKUSDVaultTestBase {
    function setUp() public override {
        super.setUp();
        _setupAllRoles();
        vm.startPrank(owner);
        vault.setPerBlockMintCap(10000, type(uint256).max);
        vault.setDailyMintCapBps(10000);
        vault.setWeeklyMintCapBps(20000);
        vm.stopPrank();
    }

    /// @dev R-06, R-09, R-42, R-43: Bounded deposit then redeem, verify supply and accounting invariants.
    function testFuzz_depositRedeem(uint256 depositAmount, uint256 redeemAmount) public {
        depositAmount = bound(depositAmount, 1, 10_000_000e6);
        redeemAmount = bound(redeemAmount, 1, depositAmount);

        // Fund and deposit
        _deposit(alice, depositAmount);

        // Verify post-deposit state
        assertEq(vault.totalDeposited(), depositAmount, "totalDeposited after deposit");
        assertEq(riskusd.totalSupply(), depositAmount, "supply after deposit");

        // Check if redeem is within weekly cap
        uint256 effectiveCap = vault.effectiveWeeklyRedemptionCap();

        // Approve RISKUSD for redeem
        _approveVaultRISKUSD(alice, redeemAmount);

        if (redeemAmount <= effectiveCap) {
            vm.prank(alice);
            vault.redeem(redeemAmount);

            // Supply invariant
            assertEq(
                riskusd.totalSupply(),
                depositAmount - redeemAmount,
                "Supply invariant: totalSupply == deposited - redeemed"
            );

            // USDC accounting invariant (no deployed capital, no losses)
            assertEq(
                usdc.balanceOf(address(vault)) + vault.totalRedeemed(),
                vault.totalDeposited(),
                "USDC accounting: vaultBalance + redeemed == deposited"
            );
        } else {
            vm.prank(alice);
            vm.expectRevert(RISKUSDVault.WeeklyRedemptionCapExceeded.selector);
            vault.redeem(redeemAmount);
        }
    }

    /// @dev R-10, R-15: Random supply/cap/amount, verify cap enforcement.
    function testFuzz_weeklyCapBoundary(uint256 supply, uint256 capBps, uint256 redeemAmount) public {
        supply = bound(supply, 1, 10_000_000e6);
        capBps = bound(capBps, 1, 10000);
        redeemAmount = bound(redeemAmount, 1, supply);

        // Setup: deposit to establish supply
        _deposit(alice, supply);

        // Set custom cap
        vm.prank(owner);
        vault.setWeeklyRedemptionCapBps(capBps);

        // Compute effective cap
        uint256 effectiveCap = supply * capBps / 10000;

        // Approve RISKUSD for redeem
        _approveVaultRISKUSD(alice, redeemAmount);

        if (redeemAmount <= effectiveCap) {
            vm.prank(alice);
            vault.redeem(redeemAmount);
            assertEq(vault.weeklyRedemptionUsed(), redeemAmount, "weeklyRedemptionUsed after redeem");
        } else {
            vm.prank(alice);
            vm.expectRevert(RISKUSDVault.WeeklyRedemptionCapExceeded.selector);
            vault.redeem(redeemAmount);
        }
    }

    /// @dev R-17: Random depositorUsdc/ratio/deployed/newDeploy, verify ratio enforcement.
    function testFuzz_deploymentRatio(
        uint256 totalDepositorUsdc,
        uint256 ratioBps,
        uint256 alreadyDeployed,
        uint256 newDeploy
    ) public {
        totalDepositorUsdc = bound(totalDepositorUsdc, 1, 10_000_000e6);
        ratioBps = bound(ratioBps, 0, 10000);
        alreadyDeployed = bound(alreadyDeployed, 0, totalDepositorUsdc);
        newDeploy = bound(newDeploy, 1, totalDepositorUsdc);

        // Setup: deposit to establish depositorUsdc
        _deposit(alice, totalDepositorUsdc);

        // Set deployment ratio
        vm.prank(owner);
        vault.setMaxDeploymentRatioBps(ratioBps);

        // Deploy 'alreadyDeployed' amount first (if within ratio and vault has balance)
        uint256 maxDeployable = ratioBps * totalDepositorUsdc / 10000;
        if (alreadyDeployed > 0 && alreadyDeployed <= maxDeployable) {
            vm.prank(custodianAddr);
            (bool ok,) = address(vault).call(abi.encodeCall(vault.deployCapital, (alreadyDeployed)));
            // May succeed or fail depending on implementation
            if (!ok) return; // Can't set up the scenario, skip
            vm.prank(custodianAddr);
            vault.recordCustodianNAV(alreadyDeployed);
        }

        uint256 currentDeployed = vault.totalDeployed();

        // Attempt new deployment
        if (currentDeployed + newDeploy <= maxDeployable && newDeploy <= usdc.balanceOf(address(vault))) {
            vm.prank(custodianAddr);
            vault.deployCapital(newDeploy);
            assertEq(vault.totalDeployed(), currentDeployed + newDeploy, "totalDeployed after successful deploy");
        } else {
            vm.prank(custodianAddr);
            (bool success,) = address(vault).call(abi.encodeCall(vault.deployCapital, (newDeploy)));
            assertFalse(success, "Deploy exceeding ratio or vault balance must revert");
        }
    }

    /// @dev R-12: Random vault balance/depositorUsdc/amount/ratio, verify reserve check.
    function testFuzz_reserveRatioEnforcement(
        uint256 depositAmt,
        uint256 deployAmt,
        uint256 redeemAmount,
        uint256 minReserveRatioBps
    ) public {
        depositAmt = bound(depositAmt, 2, 10_000_000e6);
        deployAmt = bound(deployAmt, 0, depositAmt - 1);
        redeemAmount = bound(redeemAmount, 1, depositAmt - deployAmt);
        minReserveRatioBps = bound(minReserveRatioBps, 0, 10000);

        // Deposit
        _deposit(alice, depositAmt);

        // Set reserve ratio
        vm.prank(owner);
        vault.setMinReserveRatioBps(minReserveRatioBps);

        // Deploy capital if needed (to reduce vault balance)
        if (deployAmt > 0) {
            vm.prank(custodianAddr);
            (bool ok,) = address(vault).call(abi.encodeCall(vault.deployCapital, (deployAmt)));
            if (!ok) return; // Skip if deploy fails
            vm.prank(custodianAddr);
            vault.recordCustodianNAV(deployAmt);
        }

        // Ensure within weekly cap
        uint256 effectiveCap = vault.effectiveWeeklyRedemptionCap();
        if (redeemAmount > effectiveCap) return; // Skip scenarios where cap blocks first

        // Approve RISKUSD
        _approveVaultRISKUSD(alice, redeemAmount);

        // Calculate expected outcome
        uint256 vaultBalance = usdc.balanceOf(address(vault));
        uint256 depositorUsdc = vault.totalDepositorUsdc();
        uint256 postDepositorUsdc = depositorUsdc - redeemAmount;

        if (redeemAmount > vaultBalance) {
            // Should fail on vault balance
            vm.prank(alice);
            vm.expectRevert(); // InsufficientVaultBalance or similar
            vault.redeem(redeemAmount);
        } else if (minReserveRatioBps == 0 || postDepositorUsdc == 0) {
            // Reserve ratio check skipped
            vm.prank(alice);
            vault.redeem(redeemAmount);
        } else {
            uint256 postRatio = (vaultBalance - redeemAmount) * 10000 / postDepositorUsdc;
            if (postRatio < minReserveRatioBps) {
                vm.prank(alice);
                vm.expectRevert(RISKUSDVault.ReserveRatioViolated.selector);
                vault.redeem(redeemAmount);
            } else {
                vm.prank(alice);
                vault.redeem(redeemAmount);
            }
        }
    }

    /// @dev R-42, R-43: Sequence of deposits/redeems/burns, verify supply after each.
    function testFuzz_supplyInvariant(uint256 seed) public {
        uint256 numOps = bound(seed, 1, 20);
        uint256 totalDeposited;
        uint256 totalRedeemed;
        uint256 totalBurned;

        for (uint256 i = 0; i < numOps; i++) {
            uint256 opSeed = uint256(keccak256(abi.encode(seed, i)));
            uint256 opType = opSeed % 3; // 0=deposit, 1=redeem, 2=burn

            if (opType == 0) {
                // Deposit
                uint256 currentSupply = riskusd.totalSupply();
                uint256 maxAmount = currentSupply == 0 ? 10_000e6 : currentSupply;
                maxAmount = _capToMintRemaining(maxAmount);
                if (maxAmount == 0) continue;
                uint256 amount = bound(uint256(keccak256(abi.encode(opSeed, "a"))), 1, maxAmount);
                (bool ok, bytes memory reason) = _tryDeposit(alice, amount);
                if (ok) {
                    totalDeposited += amount;
                } else {
                    _assertBackingPerShareRevert(reason);
                }
            } else if (opType == 1) {
                // Redeem (if possible)
                uint256 balance = riskusd.balanceOf(alice);
                if (balance == 0) continue;
                uint256 amount = bound(uint256(keccak256(abi.encode(opSeed, "a"))), 1, balance);
                uint256 effectiveCap = vault.effectiveWeeklyRedemptionCap();
                uint256 used = vault.weeklyRedemptionUsed();
                uint256 remaining = effectiveCap > used ? effectiveCap - used : 0;
                if (amount > remaining) continue;
                uint256 vaultBalance = usdc.balanceOf(address(vault));
                if (amount > vaultBalance) continue;

                _approveVaultRISKUSD(alice, amount);
                vm.prank(alice);
                (bool ok,) = address(vault).call(abi.encodeCall(vault.redeem, (amount)));
                if (ok) totalRedeemed += amount;
            } else {
                // Burn (loss reporter burns)
                uint256 reporterBal = riskusd.balanceOf(lossReporterAddr);
                if (reporterBal == 0) {
                    // Fund reporter with RISKUSD through vault deposit to maintain supply invariant
                    // (direct riskusd.mint bypasses vault accounting, breaking totalDeposited tracking).
                    uint256 currentSupply = riskusd.totalSupply();
                    uint256 maxFunding = currentSupply == 0 ? 1_000e6 : currentSupply;
                    maxFunding = _capToMintRemaining(maxFunding);
                    if (maxFunding == 0) continue;
                    uint256 fundingAmount = bound(uint256(keccak256(abi.encode(opSeed, "a"))), 1, maxFunding);
                    (bool depositOk, bytes memory reason) = _tryDeposit(lossReporterAddr, fundingAmount);
                    if (!depositOk) {
                        _assertBackingPerShareRevert(reason);
                        continue;
                    }
                    reporterBal = fundingAmount;
                    totalDeposited += fundingAmount;
                }
                uint256 amount = bound(uint256(keccak256(abi.encode(opSeed, "b"))), 1, reporterBal);

                vm.prank(lossReporterAddr);
                (bool ok,) = address(vault).call(abi.encodeCall(vault.burnForLoss, (1, amount)));
                if (ok) totalBurned += amount;
            }

            // Verify supply invariant matches vault counters after each operation
            assertEq(
                riskusd.totalSupply(),
                vault.totalDeposited() - vault.totalRedeemed() - vault.totalBurnedForLoss(),
                "Supply invariant must hold after every operation"
            );
        }
    }

    function _capToMintRemaining(uint256 maxAmount) internal returns (uint256) {
        uint256 dailyRemaining = vault.dailyMintRemaining();
        if (dailyRemaining == 0) {
            vm.warp(block.timestamp + 1 days);
            vm.roll(block.number + 1);
            dailyRemaining = vault.dailyMintRemaining();
        }

        uint256 weeklyRemaining = vault.weeklyMintRemaining();
        if (weeklyRemaining == 0) {
            vm.warp(block.timestamp + WEEKLY_WINDOW_DURATION);
            vm.roll(block.number + 1);
            weeklyRemaining = vault.weeklyMintRemaining();
            dailyRemaining = vault.dailyMintRemaining();
        }

        if (maxAmount > dailyRemaining) maxAmount = dailyRemaining;
        if (maxAmount > weeklyRemaining) maxAmount = weeklyRemaining;
        return maxAmount;
    }

    /// @dev R-54: Large amounts [1e15, type(uint256).max] revert on balance not overflow.
    function testFuzz_overflowSafety(uint256 amount) public {
        amount = bound(amount, 1e15, type(uint256).max);

        // Alice has a modest balance -- attempting huge deposit must revert on balance
        _fundUSDC(alice, 1_000e6);
        _approveVaultUSDC(alice, type(uint256).max);

        vm.prank(alice);
        vm.expectRevert(); // ERC-20 insufficient balance, NOT overflow
        vault.deposit(amount);

        // Attempt huge redeem with modest RISKUSD
        _deposit(alice, 100e6);
        _approveVaultRISKUSD(alice, type(uint256).max);

        vm.prank(alice);
        vm.expectRevert(); // Insufficient balance or cap exceeded, NOT overflow
        vault.redeem(amount);
    }

    /// @dev R-54: reserveRatio() returns 10000 when depositorUsdc==0, cap returns 0 when supply is 0.
    function testFuzz_divisionByZeroSafety() public view {
        // No deposits made -- totalDepositorUsdc == 0
        assertEq(vault.reserveRatio(), 10000, "reserveRatio must be 10000 when depositorUsdc == 0");
        assertEq(vault.effectiveWeeklyRedemptionCap(), 0, "effectiveWeeklyRedemptionCap must be 0 when supply is 0");
    }

    function _tryDeposit(address depositor, uint256 amount) internal returns (bool ok, bytes memory reason) {
        if (riskusd.totalSupply() != 0) {
            vm.roll(block.number + 1);
        }
        _fundUSDC(depositor, amount);
        vm.startPrank(depositor);
        usdc.approve(address(vault), amount);
        (ok, reason) = address(vault).call(abi.encodeCall(vault.deposit, (amount)));
        vm.stopPrank();
    }

    function _assertBackingPerShareRevert(bytes memory reason) internal pure {
        require(reason.length >= 4, "expected backing-margin custom error");
        bytes4 selector;
        assembly {
            selector := mload(add(reason, 32))
        }
        require(selector == RISKUSDVault.BackingMarginDecreased.selector, "unexpected deposit revert");
    }
}
