// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../../src/RISKUSDVault.sol";

/// @dev Mock USDC that records vault state during transferFrom callback.
/// Used for TC-16 Attack 2.1 CEI pattern verification.
/// During transferFrom (when vault pulls USDC from depositor), this mock
/// reads vault.totalDeposited() to verify the vault updated state BEFORE
/// the external call (Checks-Effects-Interactions pattern).
contract CEIObserverUSDC is ERC20 {
    RISKUSDVault public target;
    bool public shouldObserve;
    uint256 public observedTotalDeposited;
    bool public observed;

    constructor() ERC20("CEIObserverUSDC", "CEIUSDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setObservation(address target_) external {
        target = RISKUSDVault(target_);
        shouldObserve = true;
        observed = false;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        bool result = super.transferFrom(from, to, amount);
        if (shouldObserve) {
            shouldObserve = false;
            observed = true;
            // Record vault state during the external call
            observedTotalDeposited = target.totalDeposited();
        }
        return result;
    }
}

/// @dev Mock USDC that records vault state during transfer callback.
/// Used for TC-16 Attack 2.2 CEI pattern verification.
/// During transfer (when vault pushes USDC to redeemer), this mock
/// reads vault state to verify updates happened before the external call.
contract CEIObserverUSDCTransfer is ERC20 {
    RISKUSDVault public target;
    bool public shouldObserve;
    uint256 public observedTotalRedeemed;
    uint256 public observedWeeklyRedemptionUsed;
    bool public observed;

    constructor() ERC20("CEIObserverUSDCT", "CEIIUSDCT") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setObservation(address target_) external {
        target = RISKUSDVault(target_);
        shouldObserve = true;
        observed = false;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        bool result = super.transfer(to, amount);
        if (shouldObserve) {
            shouldObserve = false;
            observed = true;
            // Record vault state during the external call
            observedTotalRedeemed = target.totalRedeemed();
            observedWeeklyRedemptionUsed = target.weeklyRedemptionUsed();
        }
        return result;
    }
}
