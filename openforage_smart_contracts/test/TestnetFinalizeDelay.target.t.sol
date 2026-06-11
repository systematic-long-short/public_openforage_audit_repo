// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "../src/CustodianRegistry.sol";
import "../src/GuardianModule.sol";
import "../src/RISKUSD.sol";
import "../src/hyperliquid/HLTradingBridge.sol";

contract TestnetFinalizeDelayTargetTest is Test {
    uint256 internal constant ARBITRUM_SEPOLIA_CHAIN_ID = 421614;
    uint256 internal constant ARBITRUM_ONE_CHAIN_ID = 42161;

    address internal owner = makeAddr("owner");
    address internal governor = makeAddr("governor");
    address internal guardianModule = makeAddr("guardian-module");
    address internal bridge = makeAddr("bridge");
    address internal executor = makeAddr("executor");
    address internal keeper = makeAddr("keeper");
    bytes32 internal peer = bytes32(uint256(uint160(address(0xBEEF))));

    function _deployRiskusd() internal returns (RISKUSD riskusd) {
        RISKUSD implementation = new RISKUSD();
        bytes memory initData = abi.encodeCall(RISKUSD.initialize, (owner));
        riskusd = RISKUSD(address(new ERC1967Proxy(address(implementation), initData)));
    }

    function _deployRegistry() internal returns (CustodianRegistry registry) {
        CustodianRegistry implementation = new CustodianRegistry();
        bytes memory initData = abi.encodeCall(CustodianRegistry.initialize, (owner, governor, guardianModule));
        registry = CustodianRegistry(address(new ERC1967Proxy(address(implementation), initData)));
    }

    function _deployBridge() internal returns (HLTradingBridge tradingBridge) {
        HLTradingBridge implementation = new HLTradingBridge();
        bytes memory initData = abi.encodeCall(
            HLTradingBridge.initialize,
            (
                makeAddr("usdc"),
                makeAddr("riskusd-vault"),
                makeAddr("usdc-treasury"),
                makeAddr("custodian-registry"),
                owner,
                keeper,
                executor,
                guardianModule,
                HLTradingBridge.RouteConfig({
                    coldAccount: makeAddr("cold-account"),
                    hyperliquidSourceAccount: peer,
                    withdrawalChainSelector: uint64(ARBITRUM_SEPOLIA_CHAIN_ID)
                })
            )
        );
        tradingBridge = HLTradingBridge(address(new ERC1967Proxy(address(implementation), initData)));
    }

    function test_TSCGB_A25_testnetFinalizeDelayIsTenMinutesAndProductionDelayStaysTwoDays() public {
        vm.chainId(ARBITRUM_SEPOLIA_CHAIN_ID);
        assertEq(_deployRiskusd().FINALIZE_DELAY(), 10 minutes, "Sepolia RISKUSD delay");
        assertEq(_deployRegistry().FINALIZE_DELAY(), 10 minutes, "Sepolia registry delay");
        assertEq(_deployBridge().FINALIZE_DELAY(), 10 minutes, "Sepolia bridge delay");

        vm.chainId(ARBITRUM_ONE_CHAIN_ID);
        assertEq(_deployRiskusd().FINALIZE_DELAY(), 2 days, "production RISKUSD delay");
        assertEq(_deployRegistry().FINALIZE_DELAY(), 2 days, "production registry delay");
        assertEq(_deployBridge().FINALIZE_DELAY(), 2 days, "production bridge delay");
    }

    function test_TSCGB_A25_riskusdMinterFinalizesAfterTenMinutesOnTestnet() public {
        vm.chainId(ARBITRUM_SEPOLIA_CHAIN_ID);
        RISKUSD riskusd = _deployRiskusd();
        address vault = makeAddr("riskusd-vault");

        vm.prank(owner);
        riskusd.proposeMinter(vault);

        vm.warp(block.timestamp + 10 minutes - 1);
        vm.prank(owner);
        vm.expectRevert(RISKUSD.FinalizeDelayNotElapsed.selector);
        riskusd.finalizeMinter();

        vm.warp(block.timestamp + 1);
        vm.prank(owner);
        riskusd.finalizeMinter();

        assertEq(riskusd.minter(), vault, "testnet minter did not finalize after 10 minutes");
    }

    function test_TSCGB_A25_custodianConfigFinalizesAfterTenMinutesOnTestnet() public {
        vm.chainId(ARBITRUM_SEPOLIA_CHAIN_ID);
        CustodianRegistry registry = _deployRegistry();

        CustodianRegistry.CustodianConfig memory config =
            registry.hyperLiquidLaunchConfig(bridge, executor, uint32(ARBITRUM_SEPOLIA_CHAIN_ID), peer, 10_000_000e6);
        bytes32 id = registry.HYPERLIQUID_CUSTODIAN_ID();

        vm.prank(owner);
        registry.proposeCustodianConfig(config);

        vm.warp(block.timestamp + 10 minutes - 1);
        vm.prank(owner);
        vm.expectRevert(CustodianRegistry.FinalizeDelayNotElapsed.selector);
        registry.finalizeCustodianConfig(id);

        vm.warp(block.timestamp + 1);
        vm.prank(owner);
        registry.finalizeCustodianConfig(id);

        assertTrue(registry.getCustodian(id).exists, "custodian config missing");
    }

    function test_TSCGB_A25_guardianAccelerationFloorRemainsTenMinutesOnTestnet() public {
        vm.chainId(ARBITRUM_SEPOLIA_CHAIN_ID);
        address[] memory initialGuardians = new address[](7);
        uint256[] memory permissions = new uint256[](7);
        for (uint256 i; i < 7; ++i) {
            initialGuardians[i] = makeAddr(string.concat("guardian-", vm.toString(i)));
            permissions[i] = 1 << 0;
        }

        GuardianModule implementation = new GuardianModule();
        bytes memory initData =
            abi.encodeCall(GuardianModule.initialize, (governor, owner, initialGuardians, permissions));
        GuardianModule module = GuardianModule(address(new ERC1967Proxy(address(implementation), initData)));

        assertEq(module.ACCELERATED_ROTATION_FLOOR(), 10 minutes, "guardian acceleration floor changed");
    }
}
