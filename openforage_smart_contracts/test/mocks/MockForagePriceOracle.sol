// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract MockForagePriceOracle {
    uint8 public immutable decimals;
    uint80 public roundId = 1;
    int256 public answer;
    uint256 public updatedAt;
    uint80 public answeredInRound = 1;

    constructor(uint8 decimals_) {
        decimals = decimals_;
    }

    function setRoundData(int256 answer_, uint256 updatedAt_) external {
        answer = answer_;
        updatedAt = updatedAt_;
        roundId++;
        answeredInRound = roundId;
    }

    function setAnsweredInRound(uint80 answeredInRound_) external {
        answeredInRound = answeredInRound_;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (roundId, answer, updatedAt, updatedAt, answeredInRound);
    }
}
