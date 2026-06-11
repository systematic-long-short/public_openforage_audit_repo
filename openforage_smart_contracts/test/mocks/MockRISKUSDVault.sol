// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./MockRISKUSD.sol";

/// @dev Mock RISKUSDVault for ProtocolTreasury tests.
/// Implements deposit(uint256) returns (uint256), burnForLoss(uint256,uint256), replenish(uint256).
/// Has configurable revert flags, call tracking, and a mock RISKUSD token it mints on deposit.
contract MockRISKUSDVault {
    IERC20 public usdc;
    MockRISKUSD public riskusdToken;
    bool public mockPaused;
    address public vaultRegistry;

    // Revert controls
    bool public shouldRevertDeposit;
    bool public shouldRevertBurnForLoss;
    bool public shouldRevertReplenish;

    // Configurable exchange rate: riskusdOut = usdcIn * exchangeRateNum / exchangeRateDen
    uint256 public exchangeRateNum = 1;
    uint256 public exchangeRateDen = 1;

    // Call tracking
    struct DepositCall {
        uint256 usdcAmount;
        uint256 riskusdReturned;
    }

    struct BurnForLossCall {
        uint256 riskusdAmount;
    }

    struct ReplenishCall {
        uint256 usdcAmount;
    }

    DepositCall[] public depositCalls;
    BurnForLossCall[] public burnForLossCalls;
    ReplenishCall[] public replenishCalls;

    // Reentrancy attack support
    address public reentrantTarget;
    bytes public reentrantCalldata;
    bool public reentrantArmed;

    error EnforcedPause();

    constructor(address usdc_, address riskusd_) {
        usdc = IERC20(usdc_);
        riskusdToken = MockRISKUSD(riskusd_);
    }

    /// @dev Deposit USDC, mint RISKUSD to caller (ProtocolTreasury).
    function deposit(uint256 usdcAmount) external returns (uint256) {
        if (shouldRevertDeposit) revert("MockRISKUSDVault: deposit reverted");
        if (mockPaused) revert EnforcedPause();

        // Pull USDC from caller
        usdc.transferFrom(msg.sender, address(this), usdcAmount);

        // Mint RISKUSD to caller
        uint256 riskusdOut = usdcAmount * exchangeRateNum / exchangeRateDen;
        riskusdToken.mint(msg.sender, riskusdOut);

        depositCalls.push(DepositCall(usdcAmount, riskusdOut));

        // Reentrancy attack
        if (reentrantArmed) {
            reentrantArmed = false;
            (bool ok,) = reentrantTarget.call(reentrantCalldata);
            require(ok, "Reentrant call failed");
        }

        return riskusdOut;
    }

    /// @dev Burn RISKUSD for loss.
    function burnForLoss(
        uint256,
        /* vaultId */
        uint256 riskusdAmount
    )
        external
    {
        if (shouldRevertBurnForLoss) revert("MockRISKUSDVault: burnForLoss reverted");
        burnForLossCalls.push(BurnForLossCall(riskusdAmount));
        // In a real implementation, this would burn RISKUSD tokens
    }

    /// @dev Replenish USDC for loss coverage.
    function replenish(uint256 usdcAmount) external {
        if (shouldRevertReplenish) revert("MockRISKUSDVault: replenish reverted");
        // Pull USDC from caller
        usdc.transferFrom(msg.sender, address(this), usdcAmount);
        replenishCalls.push(ReplenishCall(usdcAmount));
    }

    // ── Configuration helpers ──
    function setShouldRevertDeposit(bool flag) external {
        shouldRevertDeposit = flag;
    }

    function setShouldRevertBurnForLoss(bool flag) external {
        shouldRevertBurnForLoss = flag;
    }

    function setShouldRevertReplenish(bool flag) external {
        shouldRevertReplenish = flag;
    }

    function setMockPaused(bool paused_) external {
        mockPaused = paused_;
    }

    function setExchangeRate(uint256 num, uint256 den) external {
        exchangeRateNum = num;
        exchangeRateDen = den;
    }

    function setVaultRegistry(address vaultRegistry_) external {
        vaultRegistry = vaultRegistry_;
    }

    function armReentrant(address target, bytes calldata data) external {
        reentrantTarget = target;
        reentrantCalldata = data;
        reentrantArmed = true;
    }

    function disarmReentrant() external {
        reentrantArmed = false;
    }

    // ── Call count helpers ──
    function depositCallCount() external view returns (uint256) {
        return depositCalls.length;
    }

    function burnForLossCallCount() external view returns (uint256) {
        return burnForLossCalls.length;
    }

    function replenishCallCount() external view returns (uint256) {
        return replenishCalls.length;
    }
}
