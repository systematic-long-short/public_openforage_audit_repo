// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../../src/RISKUSDVault.sol";

contract EchidnaRiskUSD is ERC20 {
    constructor() ERC20("Echidna RISKUSD", "eRISKUSD") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

contract EchidnaObservedUSDC is ERC20 {
    EchidnaRiskUSD public observedRiskToken;
    bool public observeVaultPayout;
    bool public payoutObserved;
    bool public burnObservedAtPayout;
    uint256 public expectedSupplyBeforeRedeem;
    uint256 public expectedRedeemAmount;
    address public observedVault;

    constructor() ERC20("Echidna USDC", "eUSDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function armPayoutObserver(
        EchidnaRiskUSD riskToken,
        address vault,
        uint256 supplyBeforeRedeem,
        uint256 redeemAmount
    ) external {
        observedRiskToken = riskToken;
        observeVaultPayout = true;
        payoutObserved = false;
        burnObservedAtPayout = false;
        observedVault = vault;
        expectedSupplyBeforeRedeem = supplyBeforeRedeem;
        expectedRedeemAmount = redeemAmount;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (observeVaultPayout && msg.sender == observedVault) {
            payoutObserved = true;
            burnObservedAtPayout = observedRiskToken.balanceOf(observedVault) == 0
                && observedRiskToken.totalSupply() + expectedRedeemAmount == expectedSupplyBeforeRedeem
                && amount == expectedRedeemAmount;
        }
        return super.transfer(to, amount);
    }
}

/// @title EchidnaCrownInvariants
/// @notice Dynamic RISKUSDVault fuzz harness for I-1, I-2, and I-4.
///         atRISKUSD and StakingQueue I-4 coverage lives in the Round 4 Foundry suite.
contract EchidnaCrownInvariants {
    address public constant FORGE_BREAK_CALLER = address(uint160(uint256(keccak256("FORGE_BREAK_CALLER"))));
    uint256 internal constant SEED_DEPOSIT = 1_000_000e6;
    uint256 internal constant REDEEM_AMOUNT = 1e6;

    RISKUSDVault internal vault;
    EchidnaObservedUSDC internal usdc;
    EchidnaRiskUSD internal riskusd;

    bool internal i2OutflowBeforeBurn;
    uint256 internal minimumBackingMargin;

    modifier onlyForgeBreakCaller() {
        require(msg.sender == FORGE_BREAK_CALLER, "forge-only negative control");
        _;
    }

    constructor() {
        usdc = new EchidnaObservedUSDC();
        riskusd = new EchidnaRiskUSD();

        RISKUSDVault implementation = new RISKUSDVault();
        bytes memory initData =
            abi.encodeCall(RISKUSDVault.initialize, (address(usdc), address(riskusd), address(this)));
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        vault = RISKUSDVault(address(proxy));

        vault.setPerBlockMintCap(10000, type(uint256).max);
        vault.setWeeklyMintCapBps(20000);
        vault.setWeeklyRedemptionCapBps(10000);
        vault.setMaxDeploymentRatioBps(10000);
        vault.setDeploymentBufferBps(0);

        usdc.mint(address(this), SEED_DEPOSIT);
        usdc.approve(address(vault), type(uint256).max);
        riskusd.approve(address(vault), type(uint256).max);
        vault.deposit(SEED_DEPOSIT);
        usdc.mint(address(vault), 1);
        minimumBackingMargin = _vaultBackingMargin();

        uint256 supplyBefore = riskusd.totalSupply();
        usdc.armPayoutObserver(riskusd, address(vault), supplyBefore, REDEEM_AMOUNT);
        vault.redeem(REDEEM_AMOUNT);
    }

    function echidna_I1_solvency() public view returns (bool) {
        return _vaultBackingAssets() >= riskusd.totalSupply();
    }

    function echidna_I2_burnBeforeWithdraw() public view returns (bool) {
        return !i2OutflowBeforeBurn && usdc.payoutObserved() && usdc.burnObservedAtPayout();
    }

    function echidna_I4_backingPerShare_monotonic() public view returns (bool) {
        return _vaultBackingMargin() >= minimumBackingMargin;
    }

    function deposit(uint256 amount) public {
        amount = _boundAmount(amount);
        usdc.mint(address(this), amount);
        try vault.deposit(amount) {} catch {}
    }

    function redeem(uint256 amount) public {
        uint256 balance = riskusd.balanceOf(address(this));
        if (balance == 0) return;
        uint256 limit = _min(balance, vault.vaultUsdcBalance());
        limit = _min(limit, vault.weeklyRedemptionRemaining());
        limit = _min(limit, vault.dailyRedemptionRemaining());
        if (limit == 0) return;
        amount = (amount % limit) + 1;
        uint256 supplyBefore = riskusd.totalSupply();
        usdc.armPayoutObserver(riskusd, address(vault), supplyBefore, amount);
        try vault.redeem(amount) {} catch {}
    }

    function forge_breakI1Solvency() public onlyForgeBreakCaller {
        riskusd.mint(address(this), _vaultBackingAssets() + 1);
    }

    function forge_breakI2BurnBeforeWithdraw() public onlyForgeBreakCaller {
        i2OutflowBeforeBurn = true;
    }

    function forge_breakI4BackingPerShare() public onlyForgeBreakCaller {
        riskusd.mint(address(this), _vaultBackingMargin() + 1);
    }

    function _boundAmount(uint256 amount) internal pure returns (uint256) {
        return (amount % 100e6) + 1;
    }

    function _min(uint256 left, uint256 right) internal pure returns (uint256) {
        return left < right ? left : right;
    }

    function _vaultBackingAssets() internal view returns (uint256) {
        uint256 bookValue = vault.totalDeployed();
        uint256 adjustedNav = vault.adjustedCustodianNAV();
        uint256 conservativeCustodianValue = adjustedNav < bookValue ? adjustedNav : bookValue;
        return vault.vaultUsdcBalance() + conservativeCustodianValue;
    }

    function _vaultBackingMargin() internal view returns (uint256) {
        uint256 backingAssets = _vaultBackingAssets();
        uint256 supply = riskusd.totalSupply();
        if (backingAssets < supply) return 0;
        return backingAssets - supply;
    }
}
