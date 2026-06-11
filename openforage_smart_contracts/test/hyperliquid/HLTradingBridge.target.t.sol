// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "../../src/Blocklist.sol";
import "../../src/CustodianRegistry.sol";
import "../../src/RISKUSD.sol";
import "../../src/RISKUSDVault.sol";
import "../../src/USDCTreasury.sol";
import "../../src/hyperliquid/HLTradingBridge.sol";
import "../mocks/MockUSDC.sol";

contract RevertingHLBridgeBlocklist {
    function isBlocked(address) external pure returns (bool) {
        revert("blocklist unavailable");
    }
}

contract HLTradingBridge_TargetCustody is Test {
    MockUSDC internal usdc;
    RISKUSD internal riskusd;
    RISKUSDVault internal riskusdVault;
    USDCTreasury internal treasury;
    HLTradingBridge internal bridge;
    CustodianRegistry internal custodianRegistry;
    Blocklist internal blocklist;

    address internal owner = makeAddr("timelock");
    address internal blocklistGuardian = makeAddr("blocklist-guardian");
    address internal forageGovernor = makeAddr("forage-governor");
    address internal keeper = makeAddr("keeper");
    address internal executor = makeAddr("executor");
    address internal guardianModule = makeAddr("guardian-module");
    address internal vaultRegistry = makeAddr("vault-registry");
    address internal vaultDepositor = makeAddr("vault-depositor");
    address internal coldAccount = makeAddr("hyperliquid-cold-account");
    address internal foundationPrimary = makeAddr("foundation-primary");
    address internal foundationBackup = makeAddr("foundation-backup");
    address internal protocolPrimary = makeAddr("protocol-primary");
    address internal protocolBackup = makeAddr("protocol-backup");
    address internal newKeeper = makeAddr("new-keeper");
    bytes32 internal sourceAccount = bytes32(uint256(uint160(address(0xBEEF))));

    uint256 internal constant VAULT_ID = 1;
    uint64 internal constant WITHDRAWAL_CHAIN_SELECTOR = 421_614;

    function setUp() public {
        usdc = new MockUSDC();

        RISKUSD riskusdImplementation = new RISKUSD();
        bytes memory riskusdInit = abi.encodeCall(RISKUSD.initialize, (owner));
        riskusd = RISKUSD(address(new ERC1967Proxy(address(riskusdImplementation), riskusdInit)));

        CustodianRegistry registryImplementation = new CustodianRegistry();
        bytes memory registryInit =
            abi.encodeCall(CustodianRegistry.initialize, (owner, forageGovernor, guardianModule));
        custodianRegistry = CustodianRegistry(address(new ERC1967Proxy(address(registryImplementation), registryInit)));

        RISKUSDVault vaultImplementation = new RISKUSDVault();
        bytes memory vaultInit =
            abi.encodeCall(RISKUSDVault.initializeTarget, (address(usdc), address(riskusd), owner, owner, owner));
        riskusdVault = RISKUSDVault(address(new ERC1967Proxy(address(vaultImplementation), vaultInit)));

        USDCTreasury treasuryImplementation = new USDCTreasury();
        bytes memory treasuryInit = abi.encodeCall(
            USDCTreasury.initialize,
            (
                address(usdc),
                address(riskusdVault),
                vaultRegistry,
                owner,
                foundationPrimary,
                foundationBackup,
                protocolPrimary,
                protocolBackup
            )
        );
        treasury = USDCTreasury(address(new ERC1967Proxy(address(treasuryImplementation), treasuryInit)));

        Blocklist blocklistImplementation = new Blocklist();
        bytes memory blocklistInit = abi.encodeCall(Blocklist.initialize, (blocklistGuardian, owner));
        blocklist = Blocklist(address(new ERC1967Proxy(address(blocklistImplementation), blocklistInit)));

        HLTradingBridge implementation = new HLTradingBridge();
        bytes memory initData = abi.encodeCall(
            HLTradingBridge.initialize,
            (
                address(usdc),
                address(riskusdVault),
                address(treasury),
                address(custodianRegistry),
                owner,
                keeper,
                executor,
                guardianModule,
                HLTradingBridge.RouteConfig({
                    coldAccount: coldAccount,
                    hyperliquidSourceAccount: sourceAccount,
                    withdrawalChainSelector: WITHDRAWAL_CHAIN_SELECTOR
                })
            )
        );
        bridge = HLTradingBridge(address(new ERC1967Proxy(address(implementation), initData)));

        CustodianRegistry.CustodianConfig memory hlConfig =
            custodianRegistry.hyperLiquidLaunchConfig(address(bridge), executor, 421_614, sourceAccount, 10_000_000e6);

        vm.startPrank(owner);
        custodianRegistry.proposeCustodianConfig(hlConfig);
        treasury.setHLTradingBridge(address(bridge));
        treasury.setBlocklist(address(blocklist));
        bridge.setBlocklist(address(blocklist));
        riskusd.setBlocklist(address(blocklist));
        riskusd.setMinter(address(riskusdVault));
        riskusdVault.setBlocklist(address(blocklist));
        riskusdVault.setCustodian(address(bridge));
        riskusdVault.setDeploymentBufferBps(0);
        riskusdVault.setPerBlockMintCap(10_000, type(uint256).max);
        riskusdVault.setDailyMintCapBps(10_000);
        riskusdVault.setWeeklyMintCapBps(20_000);
        vm.warp(block.timestamp + 2 days + 1);
        custodianRegistry.finalizeCustodianConfig(hlConfig.id);
        riskusd.finalizeMinter();
        riskusdVault.finalizeCustodian();
        vm.stopPrank();

        usdc.mint(vaultDepositor, 10_000_000e6);
        vm.startPrank(vaultDepositor);
        usdc.approve(address(riskusdVault), 10_000_000e6);
        riskusdVault.deposit(10_000_000e6);
        vm.stopPrank();
    }

    function _deployBridgeWithoutBlocklist() internal returns (HLTradingBridge) {
        HLTradingBridge implementation = new HLTradingBridge();
        bytes memory initData = abi.encodeCall(
            HLTradingBridge.initialize,
            (
                address(usdc),
                address(riskusdVault),
                address(treasury),
                address(custodianRegistry),
                owner,
                keeper,
                executor,
                guardianModule,
                HLTradingBridge.RouteConfig({
                    coldAccount: coldAccount,
                    hyperliquidSourceAccount: sourceAccount,
                    withdrawalChainSelector: WITHDRAWAL_CHAIN_SELECTOR
                })
            )
        );
        return HLTradingBridge(address(new ERC1967Proxy(address(implementation), initData)));
    }

    function test_TSCGB_A14_keeperNAVIsClampedAndStaleReportsRevert() public {
        vm.prank(keeper);
        bridge.postNAV(VAULT_ID, 1_000_000e6, 1_150_000e6, block.timestamp);
        assertEq(bridge.appliedNAV(), 1_100_000e6, "upward NAV must clamp to 10% per interval");
        assertEq(riskusdVault.lastAttestedNAV(), 1_100_000e6, "bridge NAV must feed vault attestation");

        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(keeper);
        vm.expectRevert(HLTradingBridge.StaleNAV.selector);
        bridge.postNAV(VAULT_ID, 1_000_000e6, 1_000_000e6, block.timestamp - 1 days - 1);
    }

    function test_TSCGB_A15_deployCapsApplyPerBlockAndPerRollingDay() public {
        uint256 vaultBalanceBefore = usdc.balanceOf(address(riskusdVault));

        vm.prank(executor);
        bridge.deployToHyperLiquid(1_000_000e6);
        assertEq(usdc.balanceOf(address(bridge)), 0, "deploy must not strand USDC in bridge");
        assertEq(usdc.balanceOf(coldAccount), 1_000_000e6, "deploy must forward USDC to cold account");
        assertEq(
            usdc.balanceOf(address(riskusdVault)), vaultBalanceBefore - 1_000_000e6, "deploy must debit vault USDC"
        );
        assertEq(
            custodianRegistry.deployedByCustodian(custodianRegistry.HYPERLIQUID_CUSTODIAN_ID()),
            1_000_000e6,
            "deploy must be recorded against the approved registry destination"
        );

        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSelector(HLTradingBridge.PerBlockDeployCapExceeded.selector, 1, 0));
        bridge.deployToHyperLiquid(1);

        vm.roll(block.number + 1);
        for (uint256 i; i < 4; ++i) {
            uint256 deployedPrincipal = bridge.deployedPrincipal();
            vm.prank(keeper);
            bridge.postNAV(VAULT_ID, deployedPrincipal, deployedPrincipal, block.timestamp);
            vm.prank(executor);
            bridge.deployToHyperLiquid(1_000_000e6);
            vm.roll(block.number + 1);
        }

        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSelector(HLTradingBridge.PerDayDeployCapExceeded.selector, 1, 0));
        bridge.deployToHyperLiquid(1);
    }

    function test_R8_M01_deployRequiresUnpausedRegistryDestination() public {
        bytes32 id = custodianRegistry.HYPERLIQUID_CUSTODIAN_ID();

        vm.prank(owner);
        custodianRegistry.setCustodianPaused(id, true);

        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSelector(CustodianRegistry.CustodianPaused.selector, id));
        bridge.deployToHyperLiquid(1_000e6);
    }

    function test_R8_M01_deployRequiresRegistryRouteToThisBridge() public {
        bytes32 id = custodianRegistry.HYPERLIQUID_CUSTODIAN_ID();
        address replacementBridge = makeAddr("replacement-bridge");
        CustodianRegistry.CustodianConfig memory replacementConfig = custodianRegistry.hyperLiquidLaunchConfig(
            replacementBridge, executor, 421_614, sourceAccount, 10_000_000e6
        );

        vm.startPrank(owner);
        custodianRegistry.proposeCustodianConfig(replacementConfig);
        vm.warp(block.timestamp + custodianRegistry.FINALIZE_DELAY());
        custodianRegistry.finalizeCustodianConfig(id);
        vm.stopPrank();

        bytes32 accountantRole = custodianRegistry.ROLE_ACCOUNTANT();
        vm.prank(executor);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustodianRegistry.UnauthorizedCustodianRole.selector, id, accountantRole, address(bridge)
            )
        );
        bridge.deployToHyperLiquid(1_000e6);
    }

    function test_TSCGB_A16_principalAndPnLReturnsStaySeparatedAndKeeperIsTwoStep() public {
        bytes32 id = custodianRegistry.HYPERLIQUID_CUSTODIAN_ID();

        vm.prank(executor);
        bridge.deployToHyperLiquid(20_000e6);
        assertEq(custodianRegistry.deployedByCustodian(id), 20_000e6, "deploy must increase registry exposure");

        vm.prank(executor);
        bytes32 intentId =
            bridge.requestWithdrawalIntent(1_500e6, address(bridge), sourceAccount, WITHDRAWAL_CHAIN_SELECTOR);
        usdc.mint(address(bridge), 1_500e6);
        vm.prank(keeper);
        bridge.reconcileWithdrawalArrival(intentId, 1_500e6);

        uint256 bridgeBalanceBeforeReturns = usdc.balanceOf(address(bridge));
        uint256 vaultBalanceBeforeReturns = usdc.balanceOf(address(riskusdVault));
        vm.startPrank(executor);
        bridge.returnPrincipalUSDC(1_000e6);
        assertEq(riskusdVault.totalDeployed(), 19_000e6, "principal return must reduce vault deployed accounting");
        assertEq(custodianRegistry.deployedByCustodian(id), 19_000e6, "principal return must reduce registry exposure");
        assertEq(
            riskusdVault.returnedSinceLastAttestation(), 1_000e6, "principal return must update vault return accounting"
        );
        vm.stopPrank();

        vm.prank(keeper);
        bridge.postNAV(VAULT_ID, 19_000e6, 19_000e6, block.timestamp);
        assertFalse(riskusdVault.lossPending(), "true remaining NAV after return must not create false loss pending");

        vm.prank(executor);
        bridge.returnPnLUSDC(VAULT_ID, 500e6);
        assertEq(custodianRegistry.deployedByCustodian(id), 19_000e6, "PnL return must not reduce deployed exposure");

        assertEq(
            usdc.balanceOf(address(riskusdVault)),
            vaultBalanceBeforeReturns + 1_000e6,
            "principal must route only to vault"
        );
        assertEq(usdc.balanceOf(address(treasury)), 500e6, "PnL must route only to USDCTreasury");
        assertEq(
            usdc.balanceOf(address(bridge)),
            bridgeBalanceBeforeReturns - 1_500e6,
            "bridge must spend verified returned custody cash"
        );
        assertEq(usdc.allowance(address(bridge), address(treasury)), 0, "bridge must reset treasury allowance");
        assertEq(usdc.allowance(address(bridge), address(riskusdVault)), 0, "bridge must reset vault allowance");
        assertEq(
            treasury.totalPrincipalReturned(), 1_000e6, "treasury must record returned principal after vault return"
        );
        assertEq(treasury.earmarkBalance(treasury.EARMARK_FOUNDATION()), 75e6, "treasury must book PnL earmarks");

        vm.prank(owner);
        bridge.proposeKeeper(newKeeper);
        vm.prank(owner);
        vm.expectRevert(HLTradingBridge.FinalizeDelayNotElapsed.selector);
        bridge.finalizeKeeper();

        vm.warp(block.timestamp + bridge.wiringChangeDelay());
        vm.prank(owner);
        bridge.finalizeKeeper();
        assertEq(bridge.keeper(), newKeeper, "keeper change must be two-step/time-delayed");
    }

    function test_R9_M01_principalReturnRestoresRegistryDeployCapacity() public {
        bytes32 id = custodianRegistry.HYPERLIQUID_CUSTODIAN_ID();

        vm.prank(owner);
        riskusdVault.setMaxDeploymentRatioBps(10_000);

        for (uint256 i; i < 10; ++i) {
            if (i == 5) {
                vm.warp(block.timestamp + 1 days + 1);
            }
            uint256 deployedPrincipal = bridge.deployedPrincipal();
            if (deployedPrincipal != 0) {
                vm.prank(keeper);
                bridge.postNAV(VAULT_ID, deployedPrincipal, deployedPrincipal, block.timestamp);
            }
            vm.prank(executor);
            bridge.deployToHyperLiquid(1_000_000e6);
            vm.roll(block.number + 1);
        }
        assertEq(custodianRegistry.deployedByCustodian(id), 10_000_000e6, "registry max exposure reached");

        vm.prank(executor);
        bytes32 intentId =
            bridge.requestWithdrawalIntent(1_000_000e6, address(bridge), sourceAccount, WITHDRAWAL_CHAIN_SELECTOR);
        usdc.mint(address(bridge), 1_000_000e6);
        vm.prank(keeper);
        bridge.reconcileWithdrawalArrival(intentId, 1_000_000e6);

        vm.prank(executor);
        bridge.returnPrincipalUSDC(1_000_000e6);
        assertEq(custodianRegistry.deployedByCustodian(id), 9_000_000e6, "principal return must restore capacity");

        vm.warp(block.timestamp + 1 days + 1);
        vm.roll(block.number + 1);
        vm.prank(keeper);
        bridge.postNAV(VAULT_ID, 9_000_000e6, 9_000_000e6, block.timestamp);

        vm.prank(executor);
        bridge.deployToHyperLiquid(1_000_000e6);
        assertEq(custodianRegistry.deployedByCustodian(id), 10_000_000e6, "restored capacity can be redeployed");
    }

    function test_R9_M01_principalReturnUsesEmergencyRegistryReturnWhenRegistryPaused() public {
        bytes32 id = custodianRegistry.HYPERLIQUID_CUSTODIAN_ID();

        vm.prank(executor);
        bridge.deployToHyperLiquid(1_000_000e6);

        vm.prank(executor);
        bytes32 intentId =
            bridge.requestWithdrawalIntent(100_000e6, address(bridge), sourceAccount, WITHDRAWAL_CHAIN_SELECTOR);
        usdc.mint(address(bridge), 100_000e6);
        vm.prank(keeper);
        bridge.reconcileWithdrawalArrival(intentId, 100_000e6);

        vm.prank(guardianModule);
        custodianRegistry.pause();

        vm.prank(executor);
        bridge.returnPrincipalUSDC(100_000e6);
        assertEq(custodianRegistry.deployedByCustodian(id), 900_000e6, "emergency return must reduce exposure");
    }

    function test_TSCGB_A17_bridgeAndRegistryReturnCapsAreTenPercentPerCallAndPerDay() public {
        assertEq(bridge.returnPerCallCapBps(), 1_000, "bridge per-call return cap must be 10%");
        assertEq(bridge.returnPerDayCapBps(), 1_000, "bridge daily return cap must be 10%");

        CustodianRegistry.CustodianConfig memory config =
            custodianRegistry.hyperLiquidLaunchConfig(address(bridge), executor, 421_614, sourceAccount, 10_000_000e6);
        assertEq(config.returnPerCallBps, 1_000, "registry launch per-call return cap must be 10%");
        assertEq(config.returnPerDayBps, 1_000, "registry launch daily return cap must be 10%");

        vm.prank(owner);
        custodianRegistry.proposeCustodianConfig(config);
        vm.warp(block.timestamp + custodianRegistry.FINALIZE_DELAY());
        vm.prank(owner);
        custodianRegistry.finalizeCustodianConfig(config.id);

        CustodianRegistry.CustodianView memory view_ = custodianRegistry.getCustodian(config.id);
        assertEq(view_.returnPerCallBps, 1_000, "finalized registry per-call return cap must be 10%");
        assertEq(view_.returnPerDayBps, 1_000, "finalized registry daily return cap must be 10%");
    }

    function test_TSCGB_A19_guardianEmergencyBridgePortsAreTightenOnly() public {
        vm.prank(guardianModule);
        bridge.shrinkPerBlockDeployCap(500_000e6);
        assertEq(bridge.perBlockDeployCap(), 500_000e6, "guardian must shrink per-block deploy cap");

        vm.prank(guardianModule);
        vm.expectRevert(HLTradingBridge.GuardianCannotLoosen.selector);
        bridge.shrinkPerBlockDeployCap(500_001e6);

        vm.prank(guardianModule);
        bridge.shrinkPerDayDeployCap(4_000_000e6);
        assertEq(bridge.perDayDeployCap(), 4_000_000e6, "guardian must shrink per-day deploy cap");

        vm.prank(guardianModule);
        bridge.tightenReturnCapitalCaps(500, 750);
        assertEq(bridge.returnPerCallCapBps(), 500, "guardian must tighten per-call return cap");
        assertEq(bridge.returnPerDayCapBps(), 750, "guardian must tighten daily return cap");

        vm.prank(guardianModule);
        vm.expectRevert(HLTradingBridge.GuardianCannotLoosen.selector);
        bridge.tightenReturnCapitalCaps(501, 750);

        vm.prank(guardianModule);
        bridge.freezeAttestations();
        assertTrue(bridge.directionalFreeze(), "guardian must freeze bridge attestations");

        vm.prank(guardianModule);
        vm.expectRevert(HLTradingBridge.GuardianCannotLoosen.selector);
        bridge.setDirectionalFreeze(false);

        vm.prank(owner);
        bridge.setDirectionalFreeze(false);
        assertFalse(bridge.directionalFreeze(), "owner governance can unfreeze");
    }

    function test_TSCGB_A19_missingBridgeBlocklistFailsLoudBeforeCustodyActions() public {
        HLTradingBridge unwiredBridge = _deployBridgeWithoutBlocklist();

        vm.prank(owner);
        vm.expectRevert(HLTradingBridge.ZeroAddress.selector);
        unwiredBridge.setBlocklist(address(0));

        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSelector(HLTradingBridge.BlocklistUnavailable.selector, address(0)));
        unwiredBridge.deployToHyperLiquid(1);
    }

    function test_TSCGB_A19_revertingBridgeBlocklistFailsLoudBeforeCustodyActions() public {
        RevertingHLBridgeBlocklist revertingBlocklist = new RevertingHLBridgeBlocklist();

        vm.prank(owner);
        bridge.setBlocklist(address(revertingBlocklist));

        vm.prank(executor);
        vm.expectRevert(
            abi.encodeWithSelector(HLTradingBridge.BlocklistUnavailable.selector, address(revertingBlocklist))
        );
        bridge.deployToHyperLiquid(1);
    }

    function test_TSCGB_A18_withdrawalIntentConsumesOnlyAfterArrivalReconciliation() public {
        vm.prank(executor);
        bridge.deployToHyperLiquid(1_000_000e6);

        vm.prank(executor);
        bytes32 intentId =
            bridge.requestWithdrawalIntent(100_000e6, address(bridge), sourceAccount, WITHDRAWAL_CHAIN_SELECTOR);

        assertFalse(bridge.withdrawalIntentConsumed(intentId), "intent starts unconsumed");

        vm.prank(keeper);
        vm.expectRevert(HLTradingBridge.ArrivalAmountMismatch.selector);
        bridge.reconcileWithdrawalArrival(intentId, 99_999e6);

        vm.prank(keeper);
        vm.expectRevert(HLTradingBridge.ArrivalAmountMismatch.selector);
        bridge.reconcileWithdrawalArrival(intentId, 100_000e6);
        assertFalse(bridge.withdrawalIntentConsumed(intentId), "intent remains open until cash arrives");

        usdc.mint(address(bridge), 100_000e6);
        vm.prank(keeper);
        bridge.reconcileWithdrawalArrival(intentId, 100_000e6);
        assertTrue(bridge.withdrawalIntentConsumed(intentId), "arrival reconciliation consumes intent");
    }

    function test_TSCGB_A18_executorFundedReturnsRequireReconciledArrival() public {
        vm.prank(executor);
        bridge.deployToHyperLiquid(20_000e6);

        usdc.mint(executor, 1_000e6);
        vm.startPrank(executor);
        usdc.approve(address(bridge), 1_000e6);
        vm.expectRevert(abi.encodeWithSelector(HLTradingBridge.InsufficientReconciledLiquidity.selector, 1_000e6, 0));
        bridge.returnPrincipalUSDC(1_000e6);
        vm.stopPrank();

        assertEq(usdc.balanceOf(address(bridge)), 0, "executor cash must not be pulled into bridge");
        assertEq(usdc.balanceOf(executor), 1_000e6, "executor balance remains untouched without reconciled cash");
    }

    function test_TSCGB_A18_overlappingWithdrawalIntentsReconcileAfterPriorLiquidityIsReturned() public {
        vm.prank(executor);
        bridge.deployToHyperLiquid(20_000e6);

        vm.prank(executor);
        bytes32 firstIntent =
            bridge.requestWithdrawalIntent(1_000e6, address(bridge), sourceAccount, WITHDRAWAL_CHAIN_SELECTOR);
        usdc.mint(address(bridge), 1_000e6);
        vm.prank(keeper);
        bridge.reconcileWithdrawalArrival(firstIntent, 1_000e6);

        vm.prank(executor);
        bytes32 secondIntent =
            bridge.requestWithdrawalIntent(500e6, address(bridge), sourceAccount, WITHDRAWAL_CHAIN_SELECTOR);
        vm.prank(executor);
        bridge.returnPrincipalUSDC(1_000e6);

        usdc.mint(address(bridge), 500e6);
        vm.prank(keeper);
        bridge.reconcileWithdrawalArrival(secondIntent, 500e6);

        assertTrue(bridge.withdrawalIntentConsumed(secondIntent), "fresh arrival must reconcile after old cash is used");
        assertEq(bridge.reconciledReturnLiquidity(), 500e6, "newly arrived cash remains usable for later returns");
    }

    function test_TSCGB_A18_newIntentBlockedWhilePriorArrivalIsUnreconciled() public {
        vm.prank(executor);
        bridge.deployToHyperLiquid(20_000e6);

        vm.prank(executor);
        bytes32 firstIntent =
            bridge.requestWithdrawalIntent(1_000e6, address(bridge), sourceAccount, WITHDRAWAL_CHAIN_SELECTOR);
        usdc.mint(address(bridge), 1_000e6);

        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSelector(HLTradingBridge.WithdrawalIntentPending.selector, firstIntent));
        bridge.requestWithdrawalIntent(500e6, address(bridge), sourceAccount, WITHDRAWAL_CHAIN_SELECTOR);

        vm.prank(keeper);
        bridge.reconcileWithdrawalArrival(firstIntent, 1_000e6);
        assertEq(bridge.openWithdrawalIntentId(), bytes32(0), "open intent clears after reconciliation");

        vm.prank(executor);
        bytes32 secondIntent =
            bridge.requestWithdrawalIntent(500e6, address(bridge), sourceAccount, WITHDRAWAL_CHAIN_SELECTOR);
        assertEq(bridge.openWithdrawalIntentId(), secondIntent, "new intent opens after previous reconciliation");
        assertFalse(bridge.withdrawalIntentConsumed(secondIntent), "reconciled old cash no longer blocks new intent");
    }

    function test_TSCGB_A18_unsolicitedDustDoesNotBlockWithdrawalIntent() public {
        vm.prank(executor);
        bridge.deployToHyperLiquid(20_000e6);

        usdc.mint(address(bridge), 500e6);

        vm.prank(executor);
        bytes32 intentId =
            bridge.requestWithdrawalIntent(500e6, address(bridge), sourceAccount, WITHDRAWAL_CHAIN_SELECTOR);
        assertEq(bridge.openWithdrawalIntentId(), intentId, "direct dust must not block a new intent");

        vm.prank(keeper);
        vm.expectRevert(HLTradingBridge.ArrivalAmountMismatch.selector);
        bridge.reconcileWithdrawalArrival(intentId, 500e6);

        usdc.mint(address(bridge), 500e6);
        vm.prank(keeper);
        bridge.reconcileWithdrawalArrival(intentId, 500e6);

        vm.prank(executor);
        bridge.returnPrincipalUSDC(500e6);
        assertEq(usdc.balanceOf(address(bridge)), 500e6, "unsolicited dust remains unreconciled after real return");
    }

    function test_TSCGB_A18_withdrawalIntentIsCappedAndPinnedToCustodianRoute() public {
        vm.prank(executor);
        bridge.deployToHyperLiquid(1_000_000e6);

        vm.prank(executor);
        vm.expectRevert(
            abi.encodeWithSelector(HLTradingBridge.InvalidWithdrawalRecipient.selector, address(riskusdVault))
        );
        bridge.requestWithdrawalIntent(100_000e6, address(riskusdVault), sourceAccount, WITHDRAWAL_CHAIN_SELECTOR);

        vm.prank(executor);
        vm.expectRevert(
            abi.encodeWithSelector(
                HLTradingBridge.WithdrawalIntentSourceMismatch.selector, bytes32(uint256(0xBADD)), sourceAccount
            )
        );
        bridge.requestWithdrawalIntent(100_000e6, address(bridge), bytes32(uint256(0xBADD)), WITHDRAWAL_CHAIN_SELECTOR);

        vm.prank(executor);
        vm.expectRevert(
            abi.encodeWithSelector(
                HLTradingBridge.WithdrawalIntentChainMismatch.selector,
                uint64(WITHDRAWAL_CHAIN_SELECTOR + 1),
                WITHDRAWAL_CHAIN_SELECTOR
            )
        );
        bridge.requestWithdrawalIntent(100_000e6, address(bridge), sourceAccount, WITHDRAWAL_CHAIN_SELECTOR + 1);

        vm.prank(executor);
        vm.expectRevert(
            abi.encodeWithSelector(HLTradingBridge.WithdrawalIntentAmountExceeded.selector, 100_000e6 + 1, 100_000e6)
        );
        bridge.requestWithdrawalIntent(100_000e6 + 1, address(bridge), sourceAccount, WITHDRAWAL_CHAIN_SELECTOR);
    }

    function test_TSCGB_A19_directionalFreezeBlocksDeploysButAllowsPrincipalReturns() public {
        vm.prank(executor);
        bridge.deployToHyperLiquid(10_000e6);

        vm.prank(guardianModule);
        bridge.setDirectionalFreeze(true);

        vm.prank(executor);
        vm.expectRevert(HLTradingBridge.DirectionFrozen.selector);
        bridge.deployToHyperLiquid(1_000e6);

        vm.prank(executor);
        bytes32 intentId =
            bridge.requestWithdrawalIntent(500e6, address(bridge), sourceAccount, WITHDRAWAL_CHAIN_SELECTOR);
        usdc.mint(address(bridge), 500e6);
        vm.prank(keeper);
        bridge.reconcileWithdrawalArrival(intentId, 500e6);

        uint256 vaultBalanceBeforeReturn = usdc.balanceOf(address(riskusdVault));
        vm.prank(executor);
        bridge.returnPrincipalUSDC(500e6);

        assertEq(
            usdc.balanceOf(address(riskusdVault)),
            vaultBalanceBeforeReturn + 500e6,
            "verified principal return must stay open"
        );
    }

    function test_TSCGB_A25_bridgeExposesTierShareSettlementHookForAtRiskusd() public {
        (bool okBefore, bytes memory dataBefore) =
            address(bridge).staticcall(abi.encodeWithSignature("tierShareActionsPaused()"));
        assertTrue(okBefore, "bridge custodian must answer atRISKUSD settlement hook");
        assertFalse(abi.decode(dataBefore, (bool)), "tier share actions open before directional freeze");

        vm.prank(guardianModule);
        bridge.freezeAttestations();

        (bool okAfter, bytes memory dataAfter) =
            address(bridge).staticcall(abi.encodeWithSignature("tierShareActionsPaused()"));
        assertTrue(okAfter, "bridge settlement hook remains reachable after freeze");
        assertTrue(abi.decode(dataAfter, (bool)), "directional freeze pauses tier share actions");
    }
}
