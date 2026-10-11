// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IEmergencyPrincipalLane {
    function principalLaneOpen() external view returns (bool);
    function laneOpenUntil() external view returns (uint256);
    function isLaneGuardian(address account) external view returns (bool);
}
