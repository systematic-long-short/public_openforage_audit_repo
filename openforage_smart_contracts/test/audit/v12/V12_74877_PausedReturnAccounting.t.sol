// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import "../../../src/CustodianRegistry.sol";

interface ICustodianRegistryEmergencyReturn {
    function recordEmergencyReturn(bytes32 id, uint256 amount) external;
}

/**
 * @title Fix proof: V12 #74877 paused return accounting is explicitly named and audited
 * @notice The registry-wide pause freezes the default return path; only a named emergency
 * return path may mutate deployed totals while paused.
 */
contract V12_74877_PausedReturnAccountingTest is Test {
    event CustodianEmergencyReturnRecorded(
        bytes32 indexed id, address indexed caller, uint256 amount, uint256 deployed
    );

    CustodianRegistry internal registry;

    address internal owner = makeAddr("owner");
    address internal governor = makeAddr("governor");
    address internal guardian = makeAddr("guardian");
    address internal bridge = makeAddr("bridge");
    address internal executor = makeAddr("executor");
    address internal attacker = makeAddr("attacker");
    bytes32 internal peer = bytes32(uint256(0x1234));

    function setUp() public {
        CustodianRegistry implementation = new CustodianRegistry();
        bytes memory initData = abi.encodeCall(CustodianRegistry.initialize, (owner, governor, guardian));
        registry = CustodianRegistry(address(new ERC1967Proxy(address(implementation), initData)));
    }

    function test_74877_fix_recordReturnRevertsUnderGlobalPauseAndPreservesTotals() public {
        bytes32 id = _registerAndDeploy(1_000e6);

        vm.prank(guardian);
        registry.pause();

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vm.prank(bridge);
        registry.recordReturn(id, 100e6);

        assertEq(registry.deployedByCustodian(id), 1_000e6, "paused default return must not reduce deployed");
        assertEq(registry.totalDeployed(), 1_000e6, "paused default return must not reduce total deployed");
    }

    function test_74877_fix_emergencyReturnIsNamedRoleGatedAndEventCovered() public {
        bytes32 id = _registerAndDeploy(1_000e6);
        ICustodianRegistryEmergencyReturn emergencyRegistry = ICustodianRegistryEmergencyReturn(address(registry));

        vm.prank(guardian);
        registry.pause();

        vm.expectRevert(
            abi.encodeWithSelector(
                CustodianRegistry.UnauthorizedCustodianRole.selector, id, registry.ROLE_ACCOUNTANT(), attacker
            )
        );
        vm.prank(attacker);
        emergencyRegistry.recordEmergencyReturn(id, 100e6);

        vm.expectEmit(true, true, true, true, address(registry));
        emit CustodianEmergencyReturnRecorded(id, bridge, 100e6, 900e6);
        vm.prank(bridge);
        emergencyRegistry.recordEmergencyReturn(id, 100e6);

        assertEq(registry.deployedByCustodian(id), 900e6, "named emergency return reduces custodian deployed");
        assertEq(registry.totalDeployed(), 900e6, "named emergency return reduces total deployed");

        vm.prank(guardian);
        registry.unpause();

        vm.expectRevert(PausableUpgradeable.ExpectedPause.selector);
        vm.prank(bridge);
        emergencyRegistry.recordEmergencyReturn(id, 1e6);
    }

    function _registerAndDeploy(uint256 amount) internal returns (bytes32 id) {
        id = registry.HYPERLIQUID_CUSTODIAN_ID();
        CustodianRegistry.CustodianConfig memory config =
            registry.hyperLiquidLaunchConfig(bridge, executor, 10_001, peer, 10_000_000e6);

        vm.startPrank(owner);
        registry.proposeCustodianConfig(config);
        vm.warp(block.timestamp + registry.FINALIZE_DELAY() + 1);
        registry.finalizeCustodianConfig(id);
        vm.stopPrank();

        vm.prank(bridge);
        registry.recordDeployment(id, amount);
    }
}
