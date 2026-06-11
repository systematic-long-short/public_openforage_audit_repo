// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {SymTest} from "halmos-cheatcodes/SymTest.sol";
import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../../src/RISKUSDVault.sol";
import "../mocks/MockUSDC.sol";

contract HalmosRound4RISKUSD is ERC20 {
    bool public overmintByOne;

    constructor() ERC20("Halmos Malicious RISKUSD", "hmRISKUSD") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function setOvermintByOne(bool enabled) external {
        overmintByOne = enabled;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount + (overmintByOne ? 1 : 0));
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

/// @title Halmos proof skeleton for RISKUSDVault I-4 backing/share monotonicity.
/// @notice atRISKUSD and StakingQueue I-4 coverage lives in
///         test/Round4BackingPerShareMonotonicity.t.sol.
contract Halmos_I4_BackingPerShareMonotonic is Test, SymTest {
    RISKUSDVault internal vault;
    MockUSDC internal usdc;
    HalmosRound4RISKUSD internal riskusd;

    address internal owner = address(0xA11CE);
    address internal alice = address(0xB0B);

    function setUp() public {
        usdc = new MockUSDC();
        riskusd = new HalmosRound4RISKUSD();

        RISKUSDVault implementation = new RISKUSDVault();
        bytes memory initData = abi.encodeCall(RISKUSDVault.initialize, (address(usdc), address(riskusd), owner));
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        vault = RISKUSDVault(address(proxy));

        vm.startPrank(owner);
        vault.setPerBlockMintCap(10000, type(uint256).max);
        vault.setWeeklyMintCapBps(20000);
        vault.setWeeklyRedemptionCapBps(10000);
        vault.setMaxDeploymentRatioBps(10000);
        vault.setDeploymentBufferBps(0);
        vm.stopPrank();
    }

    /// @notice I-4 blocks a deposit that would reduce backing per share.
    function check_vaultDeposit_blocksBackingPerShareDecrease(uint256 exploitDeposit) public {
        vm.assume(exploitDeposit == 1);

        _depositAs(alice, 1_000_000e6);
        usdc.mint(address(vault), 1);
        riskusd.setOvermintByOne(true);

        usdc.mint(alice, exploitDeposit);
        vm.startPrank(alice);
        usdc.approve(address(vault), exploitDeposit);
        vm.roll(block.number + 1);
        (bool ok,) = address(vault).call(abi.encodeCall(RISKUSDVault.deposit, (exploitDeposit)));
        vm.stopPrank();

        assert(!ok);
    }

    /// @notice I-4 holds after a successful honest public deposit.
    function check_vaultDeposit_preservesBackingMargin(uint256 depositAmount) public {
        vm.assume(depositAmount == 1);

        _depositAs(alice, 1_000_000e6);

        uint256 beforeMargin = _vaultBackingMargin();
        usdc.mint(alice, depositAmount);
        vm.startPrank(alice);
        usdc.approve(address(vault), depositAmount);
        vm.roll(block.number + 1);
        vault.deposit(depositAmount);
        vm.stopPrank();

        assert(_vaultBackingAssets() >= riskusd.totalSupply());
        assert(_vaultBackingMargin() >= beforeMargin);
    }

    function _depositAs(address account, uint256 amount) internal {
        usdc.mint(account, amount);
        vm.startPrank(account);
        usdc.approve(address(vault), amount);
        vault.deposit(amount);
        vm.stopPrank();
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
        assert(backingAssets >= supply);
        return backingAssets - supply;
    }
}
