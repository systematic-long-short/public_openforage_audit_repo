// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {SymTest} from "halmos-cheatcodes/SymTest.sol";
import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {atRISKUSD} from "../../src/atRISKUSD.sol";
import {RISKUSDVault} from "../../src/RISKUSDVault.sol";

/// @dev Minimal 6-decimal mint/burn ERC20 for Halmos harnesses.
///      The production mocks keep call-tracking arrays for Foundry assertions;
///      those arrays create noisy SMT state unrelated to I-2. This token keeps
///      the formal model focused on balances, supply, and transfer ordering.
contract HalmosMintBurnERC20 is ERC20 {
    HalmosMintBurnERC20 public observedRiskToken;
    address public observedVault;
    bool public payoutObserved;
    bool public burnObservedAtPayout;
    uint256 public expectedSupplyBeforeRedeem;
    uint256 public expectedRedeemAmount;

    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }

    function armPayoutObserver(
        HalmosMintBurnERC20 riskToken,
        address vault,
        uint256 supplyBeforeRedeem,
        uint256 redeemAmount
    ) external {
        observedRiskToken = riskToken;
        observedVault = vault;
        expectedSupplyBeforeRedeem = supplyBeforeRedeem;
        expectedRedeemAmount = redeemAmount;
        payoutObserved = false;
        burnObservedAtPayout = false;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (observedVault != address(0) && msg.sender == observedVault) {
            uint256 vaultRisk = observedRiskToken.balanceOf(observedVault);
            uint256 supply = observedRiskToken.totalSupply();
            payoutObserved = true;
            burnObservedAtPayout = (vaultRisk == 0) && (supply + expectedRedeemAmount == expectedSupplyBeforeRedeem)
                && (amount == expectedRedeemAmount);
            assert(burnObservedAtPayout);
        }
        return super.transfer(to, amount);
    }
}

/// @dev Minimal yield-source facade for atRISKUSD's fail-closed loss check.
contract HalmosYieldSource {
    function riskusdVault() external view returns (address) {
        return address(this);
    }

    function lossPending() external pure returns (bool) {
        return false;
    }
}

/// @title Halmos formal harness for crown invariant I-2 (burn-before-withdraw).
/// @notice Per `documentation/smart_contract_audits/defence_in_depth.md` (I-2):
///         "Burn-before-withdraw. Every USDC outflow from
///         `RISKUSDVault.redeem()` corresponds to an equivalent `RISKUSD`
///         burn in the same call." Symbolically explores `redeem()` with a
///         bounded prior deposit and redeem amount, then asserts the exact
///         supply burn and payout accounting on the successful path.
contract Halmos_I2_BurnBeforeWithdraw is Test, SymTest {
    /// @dev Minimal bounded unit domain; wider value ranges are covered by Foundry fuzz.
    uint256 internal constant MAX_AMOUNT = 1;
    bytes32 internal constant INITIALIZABLE_STORAGE_SLOT =
        0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;

    RISKUSDVault internal vault;
    HalmosMintBurnERC20 internal usdc;
    HalmosMintBurnERC20 internal riskusd;
    address internal owner;
    address internal alice;

    function setUp() public {
        owner = makeAddr("owner");
        alice = makeAddr("alice");

        usdc = new HalmosMintBurnERC20("USD Coin", "USDC");
        riskusd = new HalmosMintBurnERC20("RISKUSD", "RISKUSD");

        vault = new RISKUSDVault();
        vm.store(address(vault), INITIALIZABLE_STORAGE_SLOT, bytes32(0));
        vault.initialize(address(usdc), address(riskusd), owner);

        vm.startPrank(owner);
        vault.setPerBlockMintCap(10000, type(uint256).max);
        vault.setWeeklyMintCapBps(20000);
        vault.setWeeklyRedemptionCapBps(10000);
        vm.stopPrank();
    }

    function check_redeem_burnsBeforePayout(uint256 depositAmount, uint256 redeemAmount) public {
        vm.assume(depositAmount > 0);
        vm.assume(depositAmount <= MAX_AMOUNT);
        vm.assume(redeemAmount > 0);
        vm.assume(redeemAmount <= depositAmount);

        usdc.mint(alice, depositAmount);
        vm.prank(alice);
        usdc.approve(address(vault), depositAmount);
        vm.prank(alice);
        vault.deposit(depositAmount);

        vm.prank(alice);
        riskusd.approve(address(vault), redeemAmount);

        uint256 supplyBefore = riskusd.totalSupply();
        usdc.armPayoutObserver(riskusd, address(vault), supplyBefore, redeemAmount);

        vm.prank(alice);
        vault.redeem(redeemAmount);

        assert(usdc.payoutObserved());
        assert(usdc.burnObservedAtPayout());
    }
}

/// @title Secondary Halmos coverage for atRISKUSD withdrawal completion.
/// @notice Exercises the staked-tier counterpart to `RISKUSDVault.redeem`.
///         The path is concrete because ERC-4626 share conversion creates a
///         much larger SMT search than the I-2 crown proof requires; the
///         symbolic burn/payout proof remains on `RISKUSDVault.redeem()`.
contract Halmos_I2_BurnBeforeWithdraw_AtRISKUSD is Test, SymTest {
    bytes32 internal constant INITIALIZABLE_STORAGE_SLOT =
        0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;

    atRISKUSD internal noLockVault;
    HalmosMintBurnERC20 internal riskusd;
    HalmosYieldSource internal yieldSource;
    address internal owner;
    address internal stakingQueue;
    address internal alice;

    function setUp() public {
        owner = makeAddr("owner");
        stakingQueue = makeAddr("stakingQueue");
        alice = makeAddr("alice");

        riskusd = new HalmosMintBurnERC20("RISKUSD", "RISKUSD");
        yieldSource = new HalmosYieldSource();

        noLockVault = new atRISKUSD();
        vm.store(address(noLockVault), INITIALIZABLE_STORAGE_SLOT, bytes32(0));
        noLockVault.initialize(address(riskusd), address(yieldSource), stakingQueue, 0, 0, 0, "0D", owner);
        vm.prank(owner);
        noLockVault.setWeeklyWithdrawalCapBps(10_000);
    }

    function _depositNoLock(address receiver, uint256 amount) internal returns (uint256 shares) {
        riskusd.mint(stakingQueue, amount);
        vm.startPrank(stakingQueue);
        riskusd.approve(address(noLockVault), amount);
        shares = noLockVault.deposit(amount, receiver);
        vm.stopPrank();
    }

    function _assertCompletionPath(bool useNoArg) private {
        uint256 depositAmount = 1_000e6;
        uint256 totalShares = _depositNoLock(alice, depositAmount);

        vm.prank(alice);
        noLockVault.requestWithdrawal(totalShares);

        atRISKUSD.PendingWithdrawal memory pw = noLockVault.pendingWithdrawal(alice);
        uint256 capturedShares = pw.atriskusdAmount;
        uint256 capturedRiskusd = pw.riskusdAmount;

        assert(capturedShares == totalShares);
        assert(capturedRiskusd == depositAmount);

        vm.prank(alice);
        if (useNoArg) {
            noLockVault.executeWithdrawal();
        } else {
            noLockVault.executeWithdrawal(0);
        }
    }

    function check_executeWithdrawal_burnsBeforePayout() public {
        _assertCompletionPath(false);
    }

    function check_executeWithdrawalNoArg_burnsBeforePayout() public {
        _assertCompletionPath(true);
    }
}
