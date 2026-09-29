// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IAtRiskUSDProfitClaims {
    function recognizeUnpaidProfit(uint256 amount) external;
    function writeDownUnpaidProfit(uint256 amount) external;
}
