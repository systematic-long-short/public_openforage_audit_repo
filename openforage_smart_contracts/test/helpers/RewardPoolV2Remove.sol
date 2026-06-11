// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/// @dev BAD layout: REMOVES forageToken field entirely.
///      After upgrading, nextRoundId now occupies forageToken's old slot,
///      totalAirdropped occupies nextRoundId's old slot, etc.
///      Reading nextRoundId() returns what was stored as forageToken (an address as uint256).
///      The OZ upgrades plugin would reject this field removal at build time.
contract RewardPoolV2Remove is
    Initializable,
    Ownable2StepUpgradeable,
    PausableUpgradeable,
    ReentrancyGuard,
    UUPSUpgradeable
{
    // ---- Storage layout: DELIBERATELY WRONG (removed forageToken) ----
    // Original: forageToken, nextRoundId, totalAirdropped, ...
    // Removed: forageToken gone, everything shifts up
    uint256 public nextRoundId; // <-- now in forageToken's old slot
    uint256 public totalAirdropped;
    mapping(uint256 => bytes32) internal _airdropRoots;
    mapping(uint256 => mapping(address => bool)) public hasClaimed;
    uint256 public defaultClaimWindow;
    mapping(uint256 => bool) public swept;
    address internal _forageGovernor;
    uint256 internal _totalCommittedUnclaimed;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function forageGovernor() external view returns (address) {
        return _forageGovernor;
    }

    function version() external pure returns (uint256) {
        return 99;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
