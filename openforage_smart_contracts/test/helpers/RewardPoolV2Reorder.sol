// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev BAD layout: REORDERS _forageGovernor and forageToken (swapped positions).
///      After upgrading, reading forageGovernor() returns what was in forageToken's slot,
///      and reading forageToken() returns what was in nextRoundId's old slot.
///      The OZ upgrades plugin would reject this reorder at build time.
contract RewardPoolV2Reorder is
    Initializable,
    Ownable2StepUpgradeable,
    PausableUpgradeable,
    ReentrancyGuard,
    UUPSUpgradeable
{
    // ---- Storage layout: DELIBERATELY WRONG (reordered fields) ----
    // Original: forageToken, nextRoundId, totalAirdropped, ..., _forageGovernor, ...
    // Reordered: _forageGovernor FIRST, then the rest
    address internal _forageGovernor; // <-- MOVED to forageToken's slot
    IERC20 public forageToken; // <-- shifted to nextRoundId's old slot
    uint256 public nextRoundId;
    uint256 public totalAirdropped;
    mapping(uint256 => bytes32) internal _airdropRoots;
    mapping(uint256 => mapping(address => bool)) public hasClaimed;
    uint256 public defaultClaimWindow;
    mapping(uint256 => bool) public swept;
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
