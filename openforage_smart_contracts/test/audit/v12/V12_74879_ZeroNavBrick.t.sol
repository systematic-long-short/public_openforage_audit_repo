// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "../../../src/CustodianRegistry.sol";

/**
 * @title Fix proof: V12 #74879 zero NAV cannot brick later positive NAV attestations
 * @notice A zero NAV must not become the delta-cap baseline because that makes every later
 * positive NAV exceed a zero-sized cap.
 */
contract V12_74879_ZeroNavBrickTest is Test {
    CustodianRegistry internal registry;

    address internal owner = makeAddr("owner");
    address internal governor = makeAddr("governor");
    address internal guardian = makeAddr("guardian");
    address internal bridge = makeAddr("bridge");
    address internal executor = makeAddr("executor");
    bytes32 internal peer = bytes32(uint256(0x1234));

    function setUp() public {
        CustodianRegistry implementation = new CustodianRegistry();
        bytes memory initData = abi.encodeCall(CustodianRegistry.initialize, (owner, governor, guardian));
        registry = CustodianRegistry(address(new ERC1967Proxy(address(implementation), initData)));
    }

    function test_74879_fix_zeroNavUnderDeltaCapIsRejectedAndPositiveNavCanInitializeBaseline() public {
        bytes32 id = registry.HYPERLIQUID_CUSTODIAN_ID();
        _finalizeHyperliquidConfig(bridge, executor, peer);

        vm.prank(bridge);
        vm.expectRevert(CustodianRegistry.ZeroAmount.selector);
        registry.recordNAV(id, 0);

        (uint256 navAfterRejectedZero, uint256 timestampAfterRejectedZero) = registry.lastNAV(id);
        assertEq(navAfterRejectedZero, 0, "rejected zero NAV must not become the baseline");
        assertEq(timestampAfterRejectedZero, 0, "rejected zero NAV must not set a timestamp");

        vm.prank(bridge);
        registry.recordNAV(id, 1_000e6);

        (uint256 positiveNav, uint256 positiveTimestamp) = registry.lastNAV(id);
        assertEq(positiveNav, 1_000e6, "first positive NAV initializes the baseline");
        assertGt(positiveTimestamp, 0, "positive NAV records the first timestamp");

        vm.prank(bridge);
        vm.expectRevert(
            abi.encodeWithSelector(CustodianRegistry.CustodianNAVDeltaCapExceeded.selector, id, 1_000e6, 1_200e6)
        );
        registry.recordNAV(id, 1_200e6);
    }

    function test_74879_fix_reconfigurationAfterRejectedZeroDoesNotCarryAZeroBaseline() public {
        bytes32 id = registry.HYPERLIQUID_CUSTODIAN_ID();
        _finalizeHyperliquidConfig(bridge, executor, peer);

        vm.prank(bridge);
        vm.expectRevert(CustodianRegistry.ZeroAmount.selector);
        registry.recordNAV(id, 0);

        address replacementBridge = makeAddr("replacementBridge");
        address replacementExecutor = makeAddr("replacementExecutor");
        bytes32 replacementPeer = bytes32(uint256(0x5678));
        _finalizeHyperliquidConfig(replacementBridge, replacementExecutor, replacementPeer);

        CustodianRegistry.CustodianView memory afterReconfig = registry.getCustodian(id);
        assertEq(afterReconfig.lastNAV, 0, "reconfiguration must not inherit rejected zero NAV");
        assertEq(afterReconfig.lastNAVTimestamp, 0, "reconfiguration must not inherit rejected zero timestamp");
        assertFalse(registry.hasCustodianRole(id, registry.ROLE_NAV_ATTESTER(), bridge), "old attester removed");
        assertTrue(
            registry.hasCustodianRole(id, registry.ROLE_NAV_ATTESTER(), replacementBridge),
            "replacement bridge becomes NAV attester"
        );

        vm.prank(replacementBridge);
        registry.recordNAV(id, 500e6);

        (uint256 recoveredNav, uint256 recoveredTimestamp) = registry.lastNAV(id);
        assertEq(recoveredNav, 500e6, "replacement attester can initialize positive NAV");
        assertGt(recoveredTimestamp, 0, "replacement positive NAV records timestamp");
    }

    function _finalizeHyperliquidConfig(address bridge_, address executor_, bytes32 peer_) internal {
        CustodianRegistry.CustodianConfig memory config =
            registry.hyperLiquidLaunchConfig(bridge_, executor_, 10_001, peer_, 10_000_000e6);
        config.navDeltaCapBps = 1_000;

        vm.startPrank(owner);
        registry.proposeCustodianConfig(config);
        vm.warp(block.timestamp + registry.FINALIZE_DELAY() + 1);
        registry.finalizeCustodianConfig(config.id);
        vm.stopPrank();
    }
}
