// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IAllowlist {
    error CallerNotAllowed(address caller);
    error AllowlistUnavailable();
    error AllowlistFreshDeploymentRequired(uint256 layoutVersion);
    error CurrentOwnerMustRemainEligible(address account);

    function isAllowed(address account) external view returns (bool);

    function allowedUntil(address account) external view returns (uint64);

    function basisOf(address account) external view returns (uint8);

    function isSystemAccount(address account) external view returns (bool);

    function isVestingSourceRegistrationPending(address source) external view returns (bool);
}

interface IAllowlistVestingRegistry {
    function vestingSourceBeneficiary(address source) external view returns (address);

    function maxVestingSourcesPerBeneficiary() external view returns (uint256);
}

interface IVoteEligibilityObserver {
    function syncVoteEligibility(address account) external;
}

interface IAllowlistVoteEligibility {
    function isAllowedAt(address account, uint256 timepoint) external view returns (bool);

    function isSystemAccountAt(address account, uint256 timepoint) external view returns (bool);

    function supportsVoteEligibilityObserver() external pure returns (bool);

    function registerVoteEligibilityObserver() external;

    function unregisterVoteEligibilityObserver() external;
}

interface IVestingBeneficiarySource {
    function beneficiary() external view returns (address);
}
