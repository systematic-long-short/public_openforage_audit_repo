// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "./helpers/RISKUSDVaultTestBase.sol";

contract RISKUSDVault_RollingDailyRedeemCap is RISKUSDVaultTestBase {
    function setUp() public override {
        super.setUp();

        _deposit(alice, 10_000e6);

        vm.startPrank(owner);
        vault.setWeeklyRedemptionCapBps(10_000);
        vault.setDailyRedemptionCapBps(200); // target default: 2% rolling 24h
        vm.stopPrank();
    }

    function test_TSCGB_A8_dailyRedemptionCapBlocksCumulativeDrainInsideWindow() public {
        _approveVaultRISKUSD(alice, 201e6);

        vm.prank(alice);
        vault.redeem(200e6);

        vm.prank(alice);
        vm.expectRevert(RISKUSDVault.DailyRedemptionCapExceeded.selector);
        vault.redeem(1e6);

        assertEq(vault.dailyRedemptionUsed(), 200e6, "daily cap usage must be tracked cumulatively");
        assertEq(vault.dailyRedemptionRemaining(), 0, "daily remaining must be zero after 2% use");
    }

    function test_TSCGB_A8_dailyRedemptionCapUsesSupplyBeforeBurn() public {
        _approveVaultRISKUSD(alice, 200e6);

        vm.prank(alice);
        vault.redeem(200e6);

        assertEq(vault.dailyRedemptionUsed(), 200e6, "exact 2% of pre-burn supply must be redeemable");
    }

    function test_TSCGB_A8_dailyRedemptionWindowResetsAfterTwentyFourHours() public {
        _approveVaultRISKUSD(alice, 400e6);

        vm.prank(alice);
        vault.redeem(200e6);

        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 1);

        vm.prank(alice);
        vault.redeem(200e6);

        assertEq(vault.dailyRedemptionUsed(), 200e6, "new 24h window must track only post-reset usage");
    }

    function test_TSCGB_A8_weeklyCapStillBlocksWhenDailyCapAllows() public {
        vm.startPrank(owner);
        vault.setWeeklyRedemptionCapBps(100); // 1% of 10,000 RISKUSD = 100 RISKUSD
        vault.setDailyRedemptionCapBps(10_000);
        vm.stopPrank();

        _approveVaultRISKUSD(alice, 101e6);

        vm.prank(alice);
        vault.redeem(100e6);

        vm.prank(alice);
        vm.expectRevert(RISKUSDVault.WeeklyRedemptionCapExceeded.selector);
        vault.redeem(1e6);
    }

    function test_TSCGB_A9_staleCustodianNAVBlocksRedemptionAgainstUnreturnedCash() public {
        _setupCustodian();

        vm.startPrank(owner);
        vault.setWeeklyRedemptionCapBps(10_000);
        vault.setDailyRedemptionCapBps(10_000);
        vm.stopPrank();

        vm.prank(custodianAddr);
        vault.deployCapital(9_500e6);

        vm.prank(custodianAddr);
        vault.recordCustodianNAV(1, 9_500e6, 0);

        vm.warp(block.timestamp + (2 * vault.attestationIntervalSeconds()) + 1);

        _approveVaultRISKUSD(alice, 501e6);

        vm.prank(alice);
        vm.expectRevert(RISKUSDVault.LossPending.selector);
        vault.redeem(501e6);
    }

    function test_TSCGB_A9_staleCustodianNAVBlocksFurtherDeploymentAgainstUnreturnedCash() public {
        _setupCustodian();

        vm.prank(owner);
        vault.setMaxDeploymentRatioBps(10_000);

        vm.prank(custodianAddr);
        vault.deployCapital(9_500e6);

        vm.prank(custodianAddr);
        vault.recordCustodianNAV(1, 9_500e6, 0);

        vm.warp(block.timestamp + (2 * vault.attestationIntervalSeconds()) + 1);

        vm.prank(custodianAddr);
        vm.expectRevert(RISKUSDVault.LossPending.selector);
        vault.deployCapital(1);
    }

    function test_TSCGB_A24_targetInitializerSetsGenesisCustodianAndKeepsRotationDelayed() public {
        address genesisCustodian = makeAddr("genesisCustodian");
        address genesisLossReporter = makeAddr("genesisLossReporter");
        RISKUSDVault targetImplementation = new RISKUSDVault();
        ERC1967Proxy targetProxy = new ERC1967Proxy(
            address(targetImplementation),
            abi.encodeCall(
                RISKUSDVault.initializeTarget,
                (address(usdc), address(riskusd), owner, genesisCustodian, genesisLossReporter)
            )
        );
        RISKUSDVault targetVault = RISKUSDVault(address(targetProxy));

        assertEq(targetVault.custodian(), genesisCustodian, "genesis custodian");
        assertEq(targetVault.lossReporter(), genesisLossReporter, "genesis loss reporter");

        address nextCustodian = makeAddr("nextCustodian");
        vm.startPrank(owner);
        targetVault.setCustodian(nextCustodian);
        assertEq(targetVault.custodian(), genesisCustodian, "custodian cannot rotate immediately");
        vm.expectRevert(RISKUSDVault.FinalizeDelayNotElapsed.selector);
        targetVault.finalizeCustodian();
        vm.stopPrank();
    }
}
