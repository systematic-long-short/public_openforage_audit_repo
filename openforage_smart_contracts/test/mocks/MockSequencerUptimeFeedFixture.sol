// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import "./MockSequencerUptimeFeed.sol";

abstract contract MockSequencerUptimeFeedFixture is Test {
    function _deployHealthySequencerUptimeFeed(uint256 gracePeriod) internal returns (address feed) {
        if (block.timestamp <= gracePeriod + 1) vm.warp(gracePeriod + 2);

        MockSequencerUptimeFeed sequencer = new MockSequencerUptimeFeed();
        sequencer.setRoundData(0, block.timestamp - gracePeriod - 1, block.timestamp);
        return address(sequencer);
    }
}
