// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev BAD layout: inserts `insertedVar` between `usdc` and `_distributor`,
///      shifting all subsequent storage slots. Used by TC-12 negative layout test.
///      After upgrading to this, reading `_distributor` returns corrupted data
///      because it now reads from `totalDistributed`'s old slot.
contract FundingTreasuryV2BadLayout is
    Initializable,
    Ownable2StepUpgradeable,
    PausableUpgradeable,
    ReentrancyGuard,
    UUPSUpgradeable
{
    // ---- Storage layout: DELIBERATELY WRONG (inserted variable) ----
    IERC20 public usdc;
    uint256 public insertedVar; // <-- INSERTED HERE, shifts everything down
    address internal _distributor;
    uint256 public totalDistributed;
    uint256 public totalWithdrawn;
    uint256 public maxSingleDistribution;
    uint256 public maxPeriodDistribution;
    uint256 public periodWindowStart;
    uint256 public periodDistributed;
    address internal _forageGovernor;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function distributor() external view returns (address) {
        return _distributor;
    }

    function forageGovernor() external view returns (address) {
        return _forageGovernor;
    }

    function version() external pure returns (uint256) {
        return 99;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
