// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/CustodianRegistry.sol";

contract CustodianRegistryTest is Test {
    CustodianRegistry internal registry;
    address internal owner = makeAddr("timelock");
    address internal governor = makeAddr("governor");
    address internal guardian = makeAddr("guardianModule");
    address internal bridge = makeAddr("hlBridge");
    address internal executor = makeAddr("hlExecutor");
    address internal attacker = makeAddr("attacker");
    bytes32 internal peer = bytes32(uint256(0x1234));

    function setUp() public {
        CustodianRegistry implementation = new CustodianRegistry();
        bytes memory initData = abi.encodeCall(CustodianRegistry.initialize, (owner, governor, guardian));
        registry = CustodianRegistry(address(new ERC1967Proxy(address(implementation), initData)));
    }

    function _hyperLiquidConfig() internal view returns (CustodianRegistry.CustodianConfig memory config) {
        config = registry.hyperLiquidLaunchConfig(bridge, executor, 10_001, peer, 10_000_000e6);
    }

    function _registerHyperLiquid() internal {
        vm.startPrank(owner);
        registry.proposeCustodianConfig(_hyperLiquidConfig());
        vm.warp(block.timestamp + registry.FINALIZE_DELAY() + 1);
        registry.finalizeCustodianConfig(registry.HYPERLIQUID_CUSTODIAN_ID());
        vm.stopPrank();
    }

    function test_R27_finalizeHyperLiquidLaunchConfigSetsO1LookupState() public {
        _registerHyperLiquid();

        bytes32 id = registry.HYPERLIQUID_CUSTODIAN_ID();
        CustodianRegistry.CustodianView memory c = registry.getCustodian(id);

        assertTrue(c.exists, "exists");
        assertEq(uint8(c.kind), uint8(CustodianRegistry.CustodianKind.HyperLiquid), "kind");
        assertEq(c.bridge, bridge, "bridge");
        assertEq(c.executor, executor, "executor");
        assertEq(c.remoteEid, 10_001, "remote eid");
        assertEq(c.peer, peer, "peer");
        assertTrue(registry.isAllowedPeer(id, peer), "peer allowed");
        assertTrue(registry.hasCustodianRole(id, registry.ROLE_ACCOUNTANT(), bridge), "bridge accountant");
        assertTrue(registry.hasCustodianRole(id, registry.ROLE_NAV_ATTESTER(), bridge), "bridge nav");
        assertTrue(registry.hasCustodianRole(id, registry.ROLE_EXECUTOR(), executor), "executor role");
        assertEq(registry.custodianCount(), 1, "count");
        assertEq(registry.custodianIdAt(0), id, "id index");
    }

    function test_R27_finalizeBeforeDelayReverts() public {
        bytes32 id = registry.HYPERLIQUID_CUSTODIAN_ID();
        vm.startPrank(owner);
        registry.proposeCustodianConfig(_hyperLiquidConfig());
        vm.expectRevert(CustodianRegistry.FinalizeDelayNotElapsed.selector);
        registry.finalizeCustodianConfig(id);
        vm.stopPrank();
    }

    function test_R27_accountingIsPerCustodianAndAggregated() public {
        _registerHyperLiquid();
        bytes32 id = registry.HYPERLIQUID_CUSTODIAN_ID();

        vm.prank(bridge);
        registry.recordDeployment(id, 1_000e6);
        assertEq(registry.deployedByCustodian(id), 1_000e6, "custodian deployed");
        assertEq(registry.totalDeployed(), 1_000e6, "total deployed");

        vm.prank(bridge);
        registry.recordReturn(id, 100e6);
        assertEq(registry.deployedByCustodian(id), 900e6, "custodian returned");
        assertEq(registry.totalDeployed(), 900e6, "total returned");
    }

    function test_R27_deployCapsArePerCustodian() public {
        _registerHyperLiquid();
        bytes32 id = registry.HYPERLIQUID_CUSTODIAN_ID();

        vm.prank(bridge);
        registry.recordDeployment(id, 900_000e6);

        vm.prank(bridge);
        vm.expectRevert(
            abi.encodeWithSelector(CustodianRegistry.CustodianPerBlockCapExceeded.selector, id, 200_000e6, 100_000e6)
        );
        registry.recordDeployment(id, 200_000e6);
    }

    function test_R27_pauseBlocksDeployAndNavButAllowsReturnAccounting() public {
        _registerHyperLiquid();
        bytes32 id = registry.HYPERLIQUID_CUSTODIAN_ID();

        vm.prank(bridge);
        registry.recordDeployment(id, 1_000e6);

        vm.prank(guardian);
        registry.setCustodianPaused(id, true);

        vm.prank(bridge);
        vm.expectRevert(abi.encodeWithSelector(CustodianRegistry.CustodianPaused.selector, id));
        registry.recordDeployment(id, 1e6);

        vm.prank(bridge);
        vm.expectRevert(abi.encodeWithSelector(CustodianRegistry.CustodianPaused.selector, id));
        registry.recordNAV(id, 999e6);

        vm.prank(bridge);
        registry.recordReturn(id, 100e6);
        assertEq(registry.deployedByCustodian(id), 900e6, "return while paused");
    }

    function test_V12_67811_recordReturnRejectsPerCallCapByCustodianConfig() public {
        _registerHyperLiquid();
        bytes32 id = registry.HYPERLIQUID_CUSTODIAN_ID();

        vm.prank(bridge);
        registry.recordDeployment(id, 1_000_000e6);

        vm.prank(bridge);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustodianRegistry.CustodianReturnPerCallCapExceeded.selector, id, 100_000e6 + 1, 100_000e6
            )
        );
        registry.recordReturn(id, 100_000e6 + 1);

        vm.prank(bridge);
        registry.recordReturn(id, 100_000e6);
        assertEq(registry.deployedByCustodian(id), 900_000e6, "per-call capped return applies");
    }

    function test_V12_67811_recordReturnRejectsPerDayCapAndResetsNextDay() public {
        _registerHyperLiquid();
        bytes32 id = registry.HYPERLIQUID_CUSTODIAN_ID();

        vm.prank(bridge);
        registry.recordDeployment(id, 1_000_000e6);

        vm.startPrank(bridge);
        registry.recordReturn(id, 40_000e6);
        registry.recordReturn(id, 30_000e6);
        registry.recordReturn(id, 30_000e6);

        vm.expectRevert(abi.encodeWithSelector(CustodianRegistry.CustodianReturnPerDayCapExceeded.selector, id, 1, 0));
        registry.recordReturn(id, 1);

        vm.warp(block.timestamp + registry.DAY_SECONDS());
        registry.recordReturn(id, 90_000e6);
        vm.stopPrank();

        assertEq(registry.deployedByCustodian(id), 810_000e6, "next-day return cap resets");
    }

    function test_R27_navRequiresAttesterRole() public {
        _registerHyperLiquid();
        bytes32 id = registry.HYPERLIQUID_CUSTODIAN_ID();
        bytes32 navAttesterRole = registry.ROLE_NAV_ATTESTER();

        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(CustodianRegistry.UnauthorizedCustodianRole.selector, id, navAttesterRole, attacker)
        );
        registry.recordNAV(id, 1_200e6);

        vm.prank(bridge);
        registry.recordNAV(id, 1_200e6);

        (uint256 nav, uint256 timestamp) = registry.lastNAV(id);
        assertEq(nav, 1_200e6, "nav");
        assertEq(timestamp, block.timestamp, "timestamp");
    }

    function test_R27_lighterReadyFixtureUsesSeparateCustodianId() public {
        CustodianRegistry.CustodianConfig memory config = registry.lighterReadyFixture(
            makeAddr("lighterBridge"), makeAddr("lighterExecutor"), 20_002, bytes32(uint256(0x5678)), 5_000_000e6
        );

        assertEq(config.id, registry.LIGHTER_CUSTODIAN_ID(), "lighter id");
        assertEq(uint8(config.kind), uint8(CustodianRegistry.CustodianKind.Lighter), "lighter kind");
        assertEq(config.perBlockDeployCap, 500_000e6, "lighter block cap");
    }

    function test_R27_governorAndGuardianRotationUseFinalizeDelay() public {
        address newGovernor = makeAddr("newGovernor");
        address newGuardian = makeAddr("newGuardian");

        vm.startPrank(owner);
        registry.proposeForageGovernor(newGovernor);
        registry.proposeGuardianModule(newGuardian);

        vm.expectRevert(CustodianRegistry.FinalizeDelayNotElapsed.selector);
        registry.finalizeForageGovernor();
        vm.expectRevert(CustodianRegistry.FinalizeDelayNotElapsed.selector);
        registry.finalizeGuardianModule();

        vm.warp(block.timestamp + registry.FINALIZE_DELAY() + 1);
        registry.finalizeForageGovernor();
        registry.finalizeGuardianModule();
        vm.stopPrank();

        assertEq(registry.forageGovernor(), newGovernor, "new governor");
        assertEq(registry.guardianModule(), newGuardian, "new guardian");
    }

    function test_R33_peerWideningRequiresFinalizeDelayAndRechecksCustodian() public {
        _registerHyperLiquid();
        bytes32 id = registry.HYPERLIQUID_CUSTODIAN_ID();
        bytes32 newPeer = bytes32(uint256(0x9999));

        vm.startPrank(owner);
        registry.setAllowedPeer(id, newPeer, true);
        assertFalse(registry.isAllowedPeer(id, newPeer), "peer not active before finalize");

        vm.expectRevert(CustodianRegistry.FinalizeDelayNotElapsed.selector);
        registry.finalizeAllowedPeer(id, newPeer);

        vm.warp(block.timestamp + registry.FINALIZE_DELAY() + 1);
        registry.finalizeAllowedPeer(id, newPeer);
        vm.stopPrank();

        assertTrue(registry.isAllowedPeer(id, newPeer), "peer active after finalize");
    }

    function test_R33_roleWideningRequiresDelayButRevocationIsImmediate() public {
        _registerHyperLiquid();
        bytes32 id = registry.HYPERLIQUID_CUSTODIAN_ID();
        bytes32 role = registry.ROLE_EXECUTOR();
        address newExecutor = makeAddr("newExecutor");

        vm.startPrank(owner);
        registry.setCustodianRole(id, role, newExecutor, true);
        assertFalse(registry.hasCustodianRole(id, role, newExecutor), "role not active before finalize");

        vm.expectRevert(CustodianRegistry.FinalizeDelayNotElapsed.selector);
        registry.finalizeCustodianRole(id, role, newExecutor);

        vm.warp(block.timestamp + registry.FINALIZE_DELAY() + 1);
        registry.finalizeCustodianRole(id, role, newExecutor);
        assertTrue(registry.hasCustodianRole(id, role, newExecutor), "role active after finalize");

        registry.setCustodianRole(id, role, newExecutor, false);
        vm.stopPrank();

        assertFalse(registry.hasCustodianRole(id, role, newExecutor), "role revoked immediately");
    }
}
