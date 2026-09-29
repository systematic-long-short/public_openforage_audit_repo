// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IUSDCTreasuryYieldClaims {
    function yieldClaimsReady() external view returns (bool);
    function unfundedYieldClaim(address tierVault) external view returns (uint256);
    function riskusdVault() external view returns (address);
    function vaultRegistry() external view returns (address);
    function pnlAttestor() external view returns (address);
    function hlTradingBridge() external view returns (address);
}

interface IUSDCTreasuryLossSettlement {
    function settleLoss(uint256 vaultId, uint256 lossNonce) external returns (bool complete, uint256 originalLoss);
}

interface IUSDCTreasuryCallerEligibility {
    function allowlist() external view returns (address);
}

interface IYieldSourceBridgeRoute {
    function usdcTreasury() external view returns (address);
}
