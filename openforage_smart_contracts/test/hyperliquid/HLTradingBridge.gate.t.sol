// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "../../src/hyperliquid/HLTradingBridge.sol";
import "../../src/interfaces/IAllowlist.sol";
import "../mocks/MockAllowlist.sol";
import "../mocks/MockSequencerUptimeFeed.sol";

contract GateNAVVault {
    function recordCustodianNAV(uint256, uint256, uint256, uint256) external {}

    function latestLossNonce() external pure returns (uint256) {
        return 0;
    }
}

contract GateBlocklist {
    function isBlocked(address) external pure returns (bool) {
        return false;
    }
}

contract HLTradingBridge_Gate is Test {
    HLTradingBridge internal bridge;
    MockAllowlist internal mockAllowlist;
    MockSequencerUptimeFeed internal sequencer;

    address internal owner = makeAddr("gate-owner");
    address internal keeper = makeAddr("gate-keeper");
    address internal executor = makeAddr("gate-executor");
    uint256 internal vaultId = 1;
    bytes32 internal sourceAccount = bytes32(uint256(uint160(address(0xBEEF))));
    uint64 internal constant WITHDRAWAL_CHAIN_SELECTOR = 421_614;

    function setUp() public {
        vm.warp(2 days);
        sequencer = new MockSequencerUptimeFeed();
        sequencer.setRoundData(0, block.timestamp - 1 hours - 1, block.timestamp);

        HLTradingBridge implementation = new HLTradingBridge();
        bytes memory initData = abi.encodeCall(
            HLTradingBridge.initialize,
            (
                makeAddr("gate-usdc"),
                address(new GateNAVVault()),
                makeAddr("gate-treasury"),
                makeAddr("gate-registry"),
                owner,
                keeper,
                executor,
                makeAddr("gate-guardian-module"),
                HLTradingBridge.RouteConfig({
                    coldAccount: makeAddr("gate-cold"),
                    hyperliquidSourceAccount: sourceAccount,
                    withdrawalChainSelector: WITHDRAWAL_CHAIN_SELECTOR,
                    sequencerUptimeFeed: address(sequencer)
                })
            )
        );
        bridge = HLTradingBridge(address(new ERC1967Proxy(address(implementation), initData)));

        mockAllowlist = new MockAllowlist();
        mockAllowlist.setAllAllowed(true);
        vm.startPrank(owner);
        bridge.setAllowlist(address(mockAllowlist));
        bridge.setBlocklist(address(new GateBlocklist()));
        vm.stopPrank();
    }

    function test_gate_unverifiedPostNAVRevertsCallerNotAllowed() public {
        address caller = makeAddr("gate-unverified");
        mockAllowlist.setAllAllowed(false);

        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(IAllowlist.CallerNotAllowed.selector, caller));
        bridge.postNAV(vaultId, 0, 0, block.timestamp);
    }

    function test_gate_allowedKeeperPostNAVSucceeds() public {
        mockAllowlist.setAllAllowed(true);

        vm.prank(keeper);
        bridge.postNAV(vaultId, 0, 0, block.timestamp);

        assertEq(bridge.appliedNAV(), 0, "allowed keeper post must land");
        assertEq(bridge.lastNAVObservedAt(), block.timestamp, "allowed keeper post must record the observation");
    }
}
