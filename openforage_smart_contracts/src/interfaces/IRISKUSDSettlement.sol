// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IRISKUSDSettlement {
    function paused() external view returns (bool);
    function isTransferExempt(address account) external view returns (bool);
    function transferLossSettlement(address recipient, uint256 amount) external returns (bool);
}

interface IRISKUSDSettlementTier {
    function asset() external view returns (address);
    function yieldSource() external view returns (address);
}
