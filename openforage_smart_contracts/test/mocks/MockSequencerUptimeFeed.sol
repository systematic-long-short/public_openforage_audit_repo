// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract MockSequencerUptimeFeed {
    uint80 public roundId = 1;
    int256 public answer;
    uint256 public startedAt;
    uint256 public updatedAt;
    uint80 public answeredInRound = 1;

    function setRoundData(int256 answer_, uint256 startedAt_, uint256 updatedAt_) external {
        answer = answer_;
        startedAt = startedAt_;
        updatedAt = updatedAt_;
        roundId++;
        answeredInRound = roundId;
    }

    function setAnsweredInRound(uint80 answeredInRound_) external {
        answeredInRound = answeredInRound_;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (roundId, answer, startedAt, updatedAt, answeredInRound);
    }
}
