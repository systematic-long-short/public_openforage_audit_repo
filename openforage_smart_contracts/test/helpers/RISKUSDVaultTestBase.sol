// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../../src/RISKUSDVault.sol";
import "../mocks/MockUSDC.sol";
import "../mocks/MockRISKUSD.sol";

abstract contract RISKUSDVaultTestBase is Test {
    RISKUSDVault public vault;
    RISKUSDVault public implementation;
    MockUSDC public usdc;
    MockRISKUSD public riskusd;

    address public deployer;
    address public owner; // TimelockController
    address public custodianAddr;
    address public lossReporterAddr;
    address public governorAddr;
    address public alice;
    address public bob;
    address public charlie;
    address public attacker;

    uint256 constant DEFAULT_WEEKLY_CAP_BPS = 500; // 5%
    uint256 constant DEFAULT_MAX_DEPLOYMENT_RATIO_BPS = 9500; // 95%
    uint256 constant WEEKLY_WINDOW_DURATION = 604800; // 7 days
    uint256 constant MAX_BPS = 10000;

    function setUp() public virtual {
        deployer = makeAddr("deployer");
        owner = makeAddr("timelock");
        custodianAddr = makeAddr("custodian");
        lossReporterAddr = makeAddr("lossReporter");
        governorAddr = makeAddr("governor");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        charlie = makeAddr("charlie");
        attacker = makeAddr("attacker");

        // Deploy mocks
        usdc = new MockUSDC();
        riskusd = new MockRISKUSD();

        // Deploy implementation
        implementation = new RISKUSDVault();

        // Deploy proxy
        bytes memory initData = abi.encodeCall(RISKUSDVault.initialize, (address(usdc), address(riskusd), owner));
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        vault = RISKUSDVault(address(proxy));

        _useLegacyRedemptionCapModel();
    }

    // --- Helper: setup roles ---

    function _setupCustodian() internal {
        vm.startPrank(owner);
        vault.setCustodian(custodianAddr);
        vm.warp(block.timestamp + 2 days + 1);
        vault.finalizeCustodian();
        // Most unit tests exercise legacy local-book deployment behavior.
        // Dedicated deployment-buffer tests keep the production default enabled.
        vault.setDeploymentBufferBps(0);
        vm.stopPrank();
    }

    function _setupLossReporter() internal {
        vm.startPrank(owner);
        vault.setLossReporter(lossReporterAddr);
        vm.warp(block.timestamp + 2 days + 1);
        vault.finalizeLossReporter();
        vm.stopPrank();
    }

    function _setupGovernor() internal {
        vm.startPrank(owner);
        vault.setForageGovernor(governorAddr);
        vm.warp(block.timestamp + 2 days + 1);
        vault.finalizeForageGovernor();
        vm.stopPrank();
    }

    function _setupAllRoles() internal {
        _setupCustodian();
        _setupLossReporter();
        _setupGovernor();
    }

    function _useLegacyRedemptionCapModel() internal {
        vm.prank(owner);
        vault.setDailyRedemptionCapBps(MAX_BPS);
    }

    // --- Helper: fund and approve ---

    function _fundUSDC(address account, uint256 amount) internal {
        usdc.mint(account, amount);
    }

    function _approveVaultUSDC(address account, uint256 amount) internal {
        vm.prank(account);
        usdc.approve(address(vault), amount);
    }

    function _fundAndApproveUSDC(address account, uint256 amount) internal {
        _fundUSDC(account, amount);
        _approveVaultUSDC(account, amount);
    }

    function _approveVaultRISKUSD(address account, uint256 amount) internal {
        vm.prank(account);
        riskusd.approve(address(vault), amount);
    }

    // --- Helper: deposit flow ---

    function _deposit(address account, uint256 amount) internal {
        if (riskusd.totalSupply() != 0) {
            vm.roll(block.number + 1);
        }
        _fundAndApproveUSDC(account, amount);
        vm.prank(account);
        vault.deposit(amount);
    }

    // --- Helper: fund loss reporter with RISKUSD ---

    function _fundRISKUSD(address account, uint256 amount) internal {
        riskusd.mint(account, amount);
    }

    // --- Helper: prepare vault for burnForLoss ---
    // Attested loss flow: deposit RISKUSD to the loss reporter, deploy matching capital,
    // then record a nonce-bound zero-NAV attestation. Tests call burnForLoss/finalize explicitly.
    function _prepareForBurnForLoss(uint256 amount) internal {
        // Use the lossReporter deposit as the backed RISKUSD that burnForLoss will burn.
        // Expand mint caps for setup-only deposits; dedicated deposit tests cover launch caps.
        vm.startPrank(owner);
        vault.setPerBlockMintCap(10000, type(uint256).max);
        vault.setDailyMintCapBps(10000);
        vault.setMaxDeploymentRatioBps(10000);
        vm.stopPrank();
        _deposit(lossReporterAddr, amount);

        vm.prank(custodianAddr);
        vault.deployCapital(amount);

        uint256 lossNonce = vault.latestLossNonce() + 1;
        vm.prank(custodianAddr);
        vault.recordCustodianNAV(1, 0, lossNonce);
    }

    function _finalizePreparedAttestedLoss(uint256 vaultId, uint256 amount) internal {
        uint256 lossNonce = vault.latestLossNonce();
        vm.prank(custodianAddr);
        vault.finalizeAttestedLoss(vaultId, lossNonce, amount);
    }
}
