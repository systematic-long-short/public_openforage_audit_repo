// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IBlocklist {
    function isBlocked(address account) external view returns (bool);

    function wasBlockedAt(address account, uint256 timepoint) external view returns (bool);

    function wasEffectivelyBlockedAt(address account, uint256 timepoint) external view returns (bool);
}

interface IBlocklistVoteEligibility {
    function blockedUntil(address account) external view returns (uint256);

    function supportsVoteEligibilityObserver() external pure returns (bool);

    function registerVoteEligibilityObserver() external;

    function unregisterVoteEligibilityObserver() external;
}
