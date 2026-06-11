// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../../src/RISKUSDVault.sol";

/// @dev Malicious ERC-20 that re-enters RISKUSDVault.redeem() during transfer.
/// Used for TC-16 Attack 2.2 (redemption reentrancy) tests.
/// This mock replaces the vault's USDC — when the vault calls transfer(to, amount)
/// to send USDC to the redeemer, the mock re-enters redeem().
contract ReentrantMockUSDCTransfer is ERC20 {
    RISKUSDVault public target;
    bool public shouldReenter;
    uint256 public reenterAmount;

    constructor() ERC20("ReentrantUSDCT", "REUSDCT") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setReentrancy(address target_, uint256 amount_) external {
        target = RISKUSDVault(target_);
        shouldReenter = true;
        reenterAmount = amount_;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        bool result = super.transfer(to, amount);
        if (shouldReenter) {
            shouldReenter = false; // prevent infinite loop
            target.redeem(reenterAmount);
        }
        return result;
    }
}
