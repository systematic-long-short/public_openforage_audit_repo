// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console2.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../src/RISKUSDVault.sol";
import "../src/StakingQueue.sol";
import "../src/atRISKUSD.sol";

/// @dev Final-audit WET smoke flow against the split E2E Anvil deployment.
contract FinalAuditWetPrimaryFlow is Script {
    uint256 internal constant DEPOSIT_USDC = 100_000e6;
    uint256 internal constant STAKE_RISKUSD = 1_000e6;
    uint256 internal constant WITHDRAW_RISKUSD = 50e6;

    function runPhase1() external {
        IERC20 mockUsdc = IERC20(vm.envAddress("E2E_MOCK_USDC"));
        IERC20 riskusd = IERC20(vm.envAddress("E2E_RISKUSD"));
        RISKUSDVault riskVault = RISKUSDVault(vm.envAddress("E2E_RISKUSD_VAULT"));
        StakingQueue stakingQueue = StakingQueue(vm.envAddress("E2E_STAKING_QUEUE"));
        atRISKUSD tier0 = atRISKUSD(vm.envAddress("E2E_ATRISKUSD_TIER0"));

        vm.startBroadcast();
        mockUsdc.approve(address(riskVault), DEPOSIT_USDC);
        riskVault.deposit(DEPOSIT_USDC);

        riskusd.approve(address(stakingQueue), STAKE_RISKUSD);
        stakingQueue.joinQueue(STAKE_RISKUSD, 0);
        stakingQueue.processQueue(0, 10);

        uint256 sharesToWithdraw = tier0.previewWithdraw(WITHDRAW_RISKUSD);
        tier0.requestWithdrawal(sharesToWithdraw);
        vm.stopBroadcast();

        address depositor = _depositor();
        atRISKUSD.PendingWithdrawal memory pending = tier0.pendingWithdrawal(depositor);
        console2.log("phase1.usdcBalance", mockUsdc.balanceOf(depositor));
        console2.log("phase1.riskusdBalance", riskusd.balanceOf(depositor));
        console2.log("phase1.tier0Shares", tier0.balanceOf(depositor));
        console2.log("phase1.tier0EscrowedShares", tier0.balanceOf(address(tier0)));
        console2.log("phase1.pendingActive", pending.active ? uint256(1) : uint256(0));
        console2.log("phase1.pendingRiskusdAmount", pending.riskusdAmount);
        console2.log("phase1.pendingCooldownEnd", pending.requestTimestamp + pending.cooldownPeriod);
        console2.log("phase1.totalAssets", tier0.totalAssets());
    }

    function runPhase2() external {
        IERC20 mockUsdc = IERC20(vm.envAddress("E2E_MOCK_USDC"));
        IERC20 riskusd = IERC20(vm.envAddress("E2E_RISKUSD"));
        RISKUSDVault riskVault = RISKUSDVault(vm.envAddress("E2E_RISKUSD_VAULT"));
        atRISKUSD tier0 = atRISKUSD(vm.envAddress("E2E_ATRISKUSD_TIER0"));

        vm.startBroadcast();
        tier0.executeWithdrawal(0);
        riskusd.approve(address(riskVault), WITHDRAW_RISKUSD);
        riskVault.redeem(WITHDRAW_RISKUSD);
        vm.stopBroadcast();

        address depositor = _depositor();
        console2.log("phase2.usdcBalance", mockUsdc.balanceOf(depositor));
        console2.log("phase2.riskusdBalance", riskusd.balanceOf(depositor));
        console2.log("phase2.tier0Shares", tier0.balanceOf(depositor));
        console2.log("phase2.vaultUsdcBalance", mockUsdc.balanceOf(address(riskVault)));
        console2.log("phase2.tier0TotalAssets", tier0.totalAssets());
        console2.log("phase2.pendingActive", tier0.hasPendingWithdrawal(depositor) ? uint256(1) : uint256(0));
    }

    function _depositor() internal view returns (address) {
        return vm.envAddress("E2E_DEPOSITOR");
    }
}
