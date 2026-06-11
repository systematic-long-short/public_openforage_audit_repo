// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/governance/TimelockController.sol";
import "../script/DeployMainnet.s.sol";
import "../src/CustodianRegistry.sol";
import "../src/FinalizeDelayProfile.sol";
import "../src/ForageGovernor.sol";
import "../src/hyperliquid/HLTradingBridge.sol";
import "../src/RISKUSDVault.sol";

interface IOwnableView {
    function owner() external view returns (address);
}

interface IGuardianModuleView {
    function governor() external view returns (address);
    function timelock() external view returns (address);
}

contract MainnetFinalizeDelayProbe is FinalizeDelayProfile {}

contract DeployMainnetTargetTest is Test {
    DeployMainnet internal deployer;

    function setUp() public {
        deployer = new DeployMainnet();
    }

    function test_productionConstantsUseMainnetProfile() public view {
        assertEq(deployer.MAINNET_CHAIN_ID(), 42161, "Arbitrum One chain id");
        assertEq(deployer.PRODUCTION_MIN_DELAY(), 8 days, "production timelock");
        assertEq(deployer.PRODUCTION_VOTING_DELAY(), 1 days, "production voting delay");
        assertEq(deployer.PRODUCTION_VOTING_PERIOD(), 5 days, "production voting period");
    }

    function test_finalizeDelayIsProductionOnMainnet() public {
        vm.chainId(deployer.MAINNET_CHAIN_ID());
        MainnetFinalizeDelayProbe probe = new MainnetFinalizeDelayProbe();

        assertEq(probe.FINALIZE_DELAY(), 2 days, "mainnet finalize delay");
    }

    function test_mainnetDryRunSucceedsWithProductionGovernance() public {
        vm.chainId(deployer.MAINNET_CHAIN_ID());

        deployer.runDryRunWithPlaceholders();

        TimelockController timelock = TimelockController(payable(deployer.deployedTimelock()));
        ForageGovernor governor = ForageGovernor(payable(deployer.deployedForageGovernor()));
        RISKUSDVault vault = RISKUSDVault(deployer.deployedRiskusdVault());

        assertEq(timelock.getMinDelay(), 8 days, "deployed production timelock");
        assertEq(governor.votingDelay(), 1 days, "deployed production voting delay");
        assertEq(governor.votingPeriod(), 5 days, "deployed production voting period");
        assertEq(vault.FINALIZE_DELAY(), 2 days, "deployed mainnet finalize delay");
    }

    function test_mainnetDryRunHandsOwnershipAndTimelockRolesToGovernance() public {
        vm.chainId(deployer.MAINNET_CHAIN_ID());

        deployer.runDryRunWithPlaceholders();

        TimelockController timelock = TimelockController(payable(deployer.deployedTimelock()));
        address governor = deployer.deployedForageGovernor();

        assertTrue(timelock.hasRole(bytes32(0), address(timelock)), "timelock remains self-administered");
        assertFalse(timelock.hasRole(bytes32(0), address(deployer)), "deployer admin revoked");
        assertFalse(timelock.hasRole(deployer.PROPOSER_ROLE(), address(deployer)), "deployer proposer revoked");
        assertFalse(timelock.hasRole(deployer.CANCELLER_ROLE(), address(deployer)), "deployer canceller revoked");
        assertFalse(timelock.hasRole(deployer.EXECUTOR_ROLE(), address(deployer)), "deployer executor revoked");
        assertTrue(timelock.hasRole(deployer.PROPOSER_ROLE(), governor), "governor proposer retained");
        assertTrue(timelock.hasRole(deployer.CANCELLER_ROLE(), governor), "governor canceller retained");

        _assertOwnedByTimelock(deployer.deployedBlocklist(), address(timelock), "blocklist");
        _assertOwnedByTimelock(deployer.deployedCustodianRegistry(), address(timelock), "custodian registry");
        _assertOwnedByTimelock(deployer.deployedFORAGETreasury(), address(timelock), "FORAGE treasury");
        _assertOwnedByTimelock(deployer.deployedForageToken(), address(timelock), "FORAGE token");
        _assertOwnedByTimelock(deployer.deployedRiskusd(), address(timelock), "RISKUSD");
        _assertOwnedByTimelock(deployer.deployedRiskusdVault(), address(timelock), "RISKUSD vault");
        _assertOwnedByTimelock(deployer.deployedVaultRegistry(), address(timelock), "vault registry");
        _assertOwnedByTimelock(deployer.deployedAtRiskTier0(), address(timelock), "atRISK tier 0");
        _assertOwnedByTimelock(deployer.deployedAtRiskTier1(), address(timelock), "atRISK tier 1");
        _assertOwnedByTimelock(deployer.deployedAtRiskTier2(), address(timelock), "atRISK tier 2");
        _assertOwnedByTimelock(deployer.deployedAtRiskTier3(), address(timelock), "atRISK tier 3");
        _assertOwnedByTimelock(deployer.deployedStakingQueue(), address(timelock), "staking queue");
        _assertOwnedByTimelock(deployer.deployedUSDCTreasury(), address(timelock), "USDC treasury");
        _assertOwnedByTimelock(deployer.deployedHLTradingBridge(), address(timelock), "HL bridge");
        assertEq(ForageGovernor(payable(governor)).timelock(), address(timelock), "governor timelock binding");
        assertEq(
            IGuardianModuleView(deployer.deployedGuardianModule()).governor(), governor, "guardian governor binding"
        );
        assertEq(
            IGuardianModuleView(deployer.deployedGuardianModule()).timelock(),
            address(timelock),
            "guardian timelock binding"
        );
    }

    function test_mainnetRunWithConfigUsesConfiguredCustodyRoute() public {
        vm.chainId(deployer.MAINNET_CHAIN_ID());
        address keeper = address(0xCA11);
        address custodianExecutor = address(0xCECE);
        address coldAccount = address(0xC01D);
        bytes32 sourceAccount = bytes32(uint256(uint160(coldAccount)));
        _setMainnetConfigEnv(keeper, custodianExecutor, coldAccount, sourceAccount, uint64(deployer.MAINNET_CHAIN_ID()));

        deployer.runWithConfig(
            address(0x1001),
            address(0x1002),
            address(0x1003),
            address(0x1004),
            address(0x1005),
            address(0x1006),
            address(0x1007)
        );

        assertEq(deployer.cfgKeeper(), keeper, "keeper sourced from config env");
        assertEq(deployer.cfgCustodianExecutor(), custodianExecutor, "executor sourced from config env");
        assertEq(deployer.cfgColdAccount(), coldAccount, "cold account sourced from config env");
        assertEq(deployer.cfgHyperliquidSourceAccount(), sourceAccount, "source account sourced from config env");
        assertEq(
            deployer.cfgWithdrawalChainSelector(),
            uint64(deployer.MAINNET_CHAIN_ID()),
            "withdrawal chain sourced from config env"
        );

        CustodianRegistry registry = CustodianRegistry(deployer.deployedCustodianRegistry());
        HLTradingBridge bridge = HLTradingBridge(deployer.deployedHLTradingBridge());
        bytes32 id = registry.HYPERLIQUID_CUSTODIAN_ID();
        CustodianRegistry.CustodianView memory custodian = registry.getCustodian(id);

        assertTrue(custodian.exists, "HyperLiquid custodian finalized");
        assertEq(custodian.bridge, address(bridge), "registry bridge matches deployed bridge");
        assertEq(custodian.executor, custodianExecutor, "registry executor matches config");
        assertEq(custodian.remoteEid, uint32(deployer.MAINNET_CHAIN_ID()), "registry chain matches mainnet");
        assertEq(custodian.peer, sourceAccount, "registry peer matches bridge source account");
        assertTrue(registry.isAllowedPeer(id, sourceAccount), "configured source peer is allowed");
        assertTrue(registry.hasCustodianRole(id, registry.ROLE_ACCOUNTANT(), address(bridge)), "bridge accountant");
        assertTrue(registry.hasCustodianRole(id, registry.ROLE_NAV_ATTESTER(), address(bridge)), "bridge NAV attester");
        assertTrue(registry.hasCustodianRole(id, registry.ROLE_EXECUTOR(), custodianExecutor), "executor role");
        assertEq(bridge.coldAccount(), coldAccount, "bridge cold account matches config");
        assertEq(bridge.hyperliquidSourceAccount(), sourceAccount, "bridge source account matches config");
        assertEq(bridge.withdrawalChainSelector(), uint64(deployer.MAINNET_CHAIN_ID()), "bridge chain matches mainnet");
        uint256 proposedAt = deployer.initialHyperLiquidConfigProposedAt();
        uint256 finalizedAt = deployer.initialHyperLiquidConfigFinalizedAt();
        uint256 preFinalizeTimestamp = deployer.initialHyperLiquidConfigPreFinalizeTimestamp();
        assertEq(finalizedAt, proposedAt + registry.FINALIZE_DELAY() + 1, "finalized as soon as config matured");
        assertLe(finalizedAt, proposedAt + registry.PROPOSAL_EXPIRY(), "finalized before expiry");
        assertLe(
            preFinalizeTimestamp, proposedAt + registry.PROPOSAL_EXPIRY(), "finalization was reached before expiry"
        );
        assertLe(finalizedAt, block.timestamp, "dry-run time remains monotonic after finalization");

        vm.expectRevert(abi.encodeWithSelector(CustodianRegistry.NoPendingCustodianConfig.selector, id));
        registry.pendingCustodianConfig(id);
    }

    function test_mainnetDryRunRejectsNonMainnetChain() public {
        vm.chainId(421614);

        vm.expectRevert(abi.encodeWithSelector(DeployMainnet.WrongMainnetDryRunChain.selector, 421614));
        deployer.runDryRunWithPlaceholders();
    }

    function _assertOwnedByTimelock(address target, address timelock, string memory label) internal view {
        assertEq(IOwnableView(target).owner(), timelock, string.concat(label, " owned by timelock"));
    }

    function _setMainnetConfigEnv(
        address keeper,
        address custodianExecutor,
        address coldAccount,
        bytes32 sourceAccount,
        uint64 withdrawalChainSelector
    ) internal {
        vm.setEnv("KEEPER_ADDRESS", vm.toString(keeper));
        vm.setEnv("CUSTODIAN_EXECUTOR", vm.toString(custodianExecutor));
        vm.setEnv("COLD_ACCOUNT_ADDRESS", vm.toString(coldAccount));
        vm.setEnv("HYPERLIQUID_SOURCE_ACCOUNT", vm.toString(sourceAccount));
        vm.setEnv("WITHDRAWAL_CHAIN_SELECTOR", vm.toString(withdrawalChainSelector));
        for (uint256 i; i < 7;) {
            vm.setEnv(string.concat("GUARDIAN_", vm.toString(i)), vm.toString(address(uint160(0x5000 + i))));
            unchecked {
                ++i;
            }
        }
    }
}
