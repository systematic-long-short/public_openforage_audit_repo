// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/// @dev BAD layout: RETYPES forageToken from IERC20 (address) to uint256.
///      At the EVM level, both occupy 32-byte slots, but the semantic interpretation
///      changes. The OZ upgrades plugin would reject this type change at build time.
///      Reading forageTokenAsUint() returns the address value interpreted as uint256.
contract RewardPoolV2Retype is
    Initializable,
    Ownable2StepUpgradeable,
    PausableUpgradeable,
    ReentrancyGuard,
    UUPSUpgradeable
{
    // ---- Storage layout: DELIBERATELY WRONG (retyped forageToken) ----
    // Original: IERC20 public forageToken (address type)
    // Retyped: uint256 (same slot, different type interpretation)
    uint256 public forageTokenAsUint; // <-- was IERC20 (address), now uint256
    uint256 public nextRoundId;
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
