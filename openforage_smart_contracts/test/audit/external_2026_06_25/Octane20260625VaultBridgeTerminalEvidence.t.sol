// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "forge-std/StdStorage.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "../../../src/Blocklist.sol";
import "../../../src/CustodianRegistry.sol";
import "../../../src/RISKUSD.sol";
import "../../../src/RISKUSDVault.sol";
import "../../../src/USDCTreasury.sol";
import "../../../src/hyperliquid/HLTradingBridge.sol";
import "../../../src/interfaces/IVaultRegistry.sol";
import "../../mocks/MockRISKUSD.sol";
import "../../mocks/MockUSDC.sol";

contract Octane20260625FixedAssetsVault {
    uint256 public totalAssets;

    constructor(uint256 assets_) {
        totalAssets = assets_;
    }
}

contract Octane20260625BufferRegistry {
    address public riskusdVault;
    address public tierVault65;

    constructor(address riskusdVault_, address tierVault65_) {
        riskusdVault = riskusdVault_;
        tierVault65 = tierVault65_;
    }

    function getVaultsPage(uint256 offset, uint256 limit)
        external
        pure
        returns (uint256[] memory ids, uint256 nextOffset, uint256 total)
    {
        total = 65;
        if (offset >= total || limit == 0) return (new uint256[](0), total, total);
        uint256 end = offset + limit;
        if (end > total) end = total;
        ids = new uint256[](end - offset);
        for (uint256 i; i < ids.length; ++i) {
            ids[i] = offset + i + 1;
        }
        nextOffset = end;
    }

    function getVault(uint256 vaultId) external view returns (VaultConfig memory config) {
        config.vaultId = vaultId;
        config.name = "Octane Buffer";
        config.abbreviation = "OB";
        config.capacityCap = 10_000_000e6;
        config.status = VaultStatus.Active;
        if (vaultId == 65) {
            config.tierVaults[0] = tierVault65;
        }
    }

    function notifyLossResolved() external {}
}

contract Octane20260625VaultBridgeTerminalEvidenceTest is Test {
    using stdStorage for StdStorage;

    struct BridgeFixture {
        MockUSDC usdc;
        RISKUSD riskusd;
        RISKUSDVault vault;
        USDCTreasury treasury;
        HLTradingBridge bridge;
        CustodianRegistry registry;
        Blocklist blocklist;
        address owner;
        address keeper;
        address executor;
        address guardianModule;
        address vaultDepositor;
        address coldAccount;
        bytes32 sourceAccount;
    }

    uint256 internal constant VAULT_ID = 1;
    uint64 internal constant WITHDRAWAL_CHAIN_SELECTOR = 421_614;

    function test_V4_redeemSucceedsBeforeLowerNAVPostsThenLossBlocksLaterRedeem() public {
        // PHASE15_REPRO_BINDING: V-4
        BridgeFixture memory f = _deployBridgeFixture();
        _deployAndPostHealthyNAV(f, 1_000_000e6);

        vm.prank(f.vaultDepositor);
        f.riskusd.approve(address(f.vault), 200_000e6);
        vm.prank(f.vaultDepositor);
        f.vault.redeem(100_000e6);
        assertFalse(f.vault.lossPending(), "redeem before the lower NAV consumes liquid USDC at par");

        vm.prank(f.keeper);
        f.bridge.postNAV(VAULT_ID, 1_000_000e6, 900_000e6, block.timestamp);
        assertTrue(f.vault.lossPending(), "lower keeper NAV creates a loss-pending window");

        vm.prank(f.vaultDepositor);
        vm.expectRevert(RISKUSDVault.LossPending.selector);
        f.vault.redeem(1);
    }

    function test_V4_suspectedLossFreezeBlocksRedeemBeforeNAVAndHealthyNAVClears() public {
        // CI-0067_POLICY_A_POSTFIX: V-4
        BridgeFixture memory f = _deployBridgeFixture();
        _deployAndPostHealthyNAV(f, 1_000_000e6);

        vm.prank(f.owner);
        f.vault.setSuspectedLossFreeze(true);

        vm.prank(f.vaultDepositor);
        f.riskusd.approve(address(f.vault), 1);
        vm.prank(f.vaultDepositor);
        vm.expectRevert(RISKUSDVault.LossPending.selector);
        f.vault.redeem(1);

        vm.prank(f.keeper);
        f.bridge.postNAV(VAULT_ID, 1_000_000e6, 1_000_000e6, block.timestamp);
        assertFalse(f.vault.lossPending(), "fresh healthy NAV clears suspected-loss freeze");
    }

    function test_RV41_bridgeNAVFreshnessUsesObservedAtAfterRemediation() public {
        // CI-0067_POLICY_A_POSTFIX: R-V-4-1
        BridgeFixture memory f = _deployBridgeFixture();

        vm.warp(block.timestamp + 2 days);
        vm.prank(f.executor);
        f.bridge.deployToHyperLiquid(1_000_000e6);
        uint256 submittedAt = block.timestamp;
        uint256 observedAt = submittedAt - 1 days + 1;
        vm.prank(f.keeper);
        f.bridge.postNAV(VAULT_ID, 1_000_000e6, 1_000_000e6, observedAt);

        uint256 interval = f.vault.attestationIntervalSeconds();
        vm.warp(observedAt + (2 * interval) + 1);
        assertTrue(f.vault.lossPending(), "vault treats the NAV as stale once observedAt exceeds the freshness window");
        assertGt(submittedAt, observedAt, "setup: submission is newer than the observation");
    }

    function test_RV41_vaultFreshnessAgesByObservedAtAfterRemediation() public {
        // CI-0067_POLICY_A_POSTFIX: R-V-4-1
        BridgeFixture memory f = _deployBridgeFixture();

        vm.warp(block.timestamp + 2 days);
        vm.prank(f.executor);
        f.bridge.deployToHyperLiquid(1_000_000e6);
        uint256 submittedAt = block.timestamp;
        uint256 observedAt = submittedAt - 1 days + 1;
        vm.prank(f.keeper);
        f.bridge.postNAV(VAULT_ID, 1_000_000e6, 1_000_000e6, observedAt);

        uint256 interval = f.vault.attestationIntervalSeconds();
        vm.warp(observedAt + (2 * interval) + 1);
        assertTrue(f.vault.lossPending(), "vault freshness must age from observedAt, not submission time");
    }

    function test_V7_deploymentBufferPaginatesBeyondSixtyFourRegistryIds() public {
        // CI-0067_POLICY_A_POSTFIX: V-7
        address owner = makeAddr("octane25.v7.owner");
        address custodian = makeAddr("octane25.v7.custodian");
        MockUSDC usdc = new MockUSDC();
        MockRISKUSD riskusd = new MockRISKUSD();
        RISKUSDVault vault = _deployMockRiskVault(address(usdc), address(riskusd), owner, custodian);
        Octane20260625FixedAssetsVault tierVault65 = new Octane20260625FixedAssetsVault(1_000_000e6);
        Octane20260625BufferRegistry registry = new Octane20260625BufferRegistry(address(vault), address(tierVault65));

        vm.prank(owner);
        vault.initializeV2(address(registry));
        vm.prank(owner);
        vault.setDeploymentBufferBps(500);

        usdc.mint(address(this), 1_000_000e6);
        usdc.approve(address(vault), 1_000_000e6);
        vault.deposit(1_000_000e6);

        vm.prank(custodian);
        vault.deployCapital(1);
        assertEq(vault.totalDeployed(), 1, "deployment buffer includes active assets past the first page");
    }

    function test_V7_deploymentBufferCountsAssetsBeyondSixtyFourRegistryIds() public {
        // CI-0067_POLICY_A_POSTFIX: V-7
        address owner = makeAddr("octane25.v7.post.owner");
        address custodian = makeAddr("octane25.v7.post.custodian");
        MockUSDC usdc = new MockUSDC();
        MockRISKUSD riskusd = new MockRISKUSD();
        RISKUSDVault vault = _deployMockRiskVault(address(usdc), address(riskusd), owner, custodian);
        Octane20260625FixedAssetsVault tierVault65 = new Octane20260625FixedAssetsVault(1_000_000e6);
        Octane20260625BufferRegistry registry = new Octane20260625BufferRegistry(address(vault), address(tierVault65));

        vm.prank(owner);
        vault.initializeV2(address(registry));
        vm.prank(owner);
        vault.setDeploymentBufferBps(500);

        usdc.mint(address(this), 1_000_000e6);
        usdc.approve(address(vault), 1_000_000e6);
        vault.deposit(1_000_000e6);

        vm.prank(custodian);
        vault.deployCapital(1);
        assertEq(vault.totalDeployed(), 1, "deployment buffer counted assets after the first 64 ids");
    }

    function test_V8_redeemPreservesNextWindowMintCapBaselines() public {
        // CI-0067_POLICY_A_POSTFIX: V-8
        address owner = makeAddr("octane25.v8.owner");
        address custodian = makeAddr("octane25.v8.custodian");
        address alice = makeAddr("octane25.v8.alice");
        MockUSDC usdc = new MockUSDC();
        MockRISKUSD riskusd = new MockRISKUSD();
        RISKUSDVault vault = _deployMockRiskVault(address(usdc), address(riskusd), owner, custodian);

        vm.startPrank(owner);
        vault.setDeploymentBufferBps(0);
        vault.setPerBlockMintCap(10_000, type(uint256).max);
        vault.setDailyMintCapBps(10_000);
        vault.setWeeklyMintCapBps(10_000);
        vault.setWeeklyRedemptionCapBps(10_000);
        vault.setDailyRedemptionCapBps(10_000);
        vm.stopPrank();

        _deposit(vault, usdc, alice, 1_000e6);
        vm.warp(block.timestamp + 7 days);
        vm.roll(block.number + 1);
        _deposit(vault, usdc, alice, 1_000e6);

        vm.prank(alice);
        riskusd.approve(address(vault), 1_900e6);
        vm.prank(alice);
        vault.redeem(1_900e6);
        assertEq(riskusd.totalSupply(), 100e6, "setup: redemption contracted active supply");

        vm.warp(block.timestamp + 7 days);
        assertEq(vault.effectiveWeeklyMintCap(), 1_000e6, "weekly mint cap keeps the prior high-water baseline");
        assertEq(vault.effectiveDailyMintCap(), 1_000e6, "daily mint cap keeps the prior high-water baseline");
    }

    function test_V8_redemptionDoesNotShrinkNextWindowMintCapsAfterRemediation() public {
        // CI-0067_POLICY_A_POSTFIX: V-8
        address owner = makeAddr("octane25.v8.post.owner");
        address custodian = makeAddr("octane25.v8.post.custodian");
        address alice = makeAddr("octane25.v8.post.alice");
        MockUSDC usdc = new MockUSDC();
        MockRISKUSD riskusd = new MockRISKUSD();
        RISKUSDVault vault = _deployMockRiskVault(address(usdc), address(riskusd), owner, custodian);

        vm.startPrank(owner);
        vault.setDeploymentBufferBps(0);
        vault.setPerBlockMintCap(10_000, type(uint256).max);
        vault.setDailyMintCapBps(10_000);
        vault.setWeeklyMintCapBps(10_000);
        vault.setWeeklyRedemptionCapBps(10_000);
        vault.setDailyRedemptionCapBps(10_000);
        vm.stopPrank();

        _deposit(vault, usdc, alice, 1_000e6);
        vm.warp(block.timestamp + 7 days);
        vm.roll(block.number + 1);
        _deposit(vault, usdc, alice, 1_000e6);

        vm.prank(alice);
        riskusd.approve(address(vault), 1_900e6);
        vm.prank(alice);
        vault.redeem(1_900e6);

        vm.warp(block.timestamp + 7 days);
        assertEq(vault.effectiveWeeklyMintCap(), 1_000e6, "weekly mint cap keeps the prior window baseline");
        assertEq(vault.effectiveDailyMintCap(), 1_000e6, "daily mint cap keeps the prior window baseline");
    }

    function test_V9_returnAfterAlreadyReducedNAVDoubleSubtractsUntilFreshNAV() public {
        // PHASE15_REPRO_BINDING: V-9
        BridgeFixture memory f = _deployBridgeFixture();
        _deployAndPostHealthyNAV(f, 1_000_000e6);

        vm.prank(f.keeper);
        f.bridge.postNAV(VAULT_ID, 1_000_000e6, 900_000e6, block.timestamp);
        assertEq(f.vault.adjustedCustodianNAV(), 900_000e6, "setup: keeper NAV already reflects a 100k return");

        _requestAndReconcile(f, 100_000e6);
        vm.prank(f.executor);
        f.bridge.returnPrincipalUSDC(100_000e6);

        assertEq(f.vault.totalDeployed(), 900_000e6, "local principal book is reduced by the return");
        assertEq(
            f.vault.adjustedCustodianNAV(),
            800_000e6,
            "returnedSinceLastAttestation subtracts the same 100k from an already-reduced NAV"
        );

        vm.prank(f.keeper);
        f.bridge.postNAV(VAULT_ID, 900_000e6, 900_000e6, block.timestamp);
        assertEq(f.vault.adjustedCustodianNAV(), 900_000e6, "fresh NAV clears the temporary double subtraction");
    }

    function test_V9_postReturnNAVBasisDoesNotDoubleSubtract() public {
        // CI-0067_POLICY_A_POSTFIX: V-9
        BridgeFixture memory f = _deployBridgeFixture();
        _deployAndPostHealthyNAV(f, 1_000_000e6);

        vm.prank(f.keeper);
        f.bridge.postNAV(VAULT_ID, 1_000_000e6, 900_000e6, block.timestamp);
        _requestAndReconcile(f, 100_000e6);
        vm.prank(f.executor);
        f.bridge.returnPrincipalUSDCWithNAVBasis(100_000e6, true);

        assertEq(f.vault.totalDeployed(), 900_000e6, "local principal book is reduced by the return");
        assertEq(f.vault.adjustedCustodianNAV(), 900_000e6, "post-return NAV basis is not subtracted twice");
    }

    function test_V13_zeroDeployedPrincipalMakesPositiveReturnAndIntentCapsZero() public {
        // PHASE15_REPRO_BINDING: V-13
        BridgeFixture memory f = _deployBridgeFixture();
        _deployAndPostHealthyNAV(f, 1_000_000e6);
        assertEq(f.bridge.deployedPrincipal(), 1_000_000e6, "setup: bridge has deployed principal");

        stdstore.target(address(f.bridge)).sig(f.bridge.deployedPrincipal.selector).checked_write(uint256(0));
        assertEq(f.bridge.deployedPrincipal(), 0, "external zero-principal state installed");

        vm.prank(f.executor);
        vm.expectRevert(abi.encodeWithSelector(HLTradingBridge.WithdrawalIntentAmountExceeded.selector, 1, 0));
        f.bridge.requestWithdrawalIntent(1, address(f.bridge), f.sourceAccount, WITHDRAWAL_CHAIN_SELECTOR);

        vm.prank(f.executor);
        vm.expectRevert(abi.encodeWithSelector(HLTradingBridge.ReturnPerCallCapExceeded.selector, 1, 0));
        f.bridge.returnPrincipalUSDC(1);
    }

    function test_V13_ownerZeroPrincipalCleanupPathAllowsIntentAndReturn() public {
        // CI-0067_POLICY_A_POSTFIX: V-13
        BridgeFixture memory f = _deployBridgeFixture();
        _deployAndPostHealthyNAV(f, 1_000_000e6);
        stdstore.target(address(f.bridge)).sig(f.bridge.deployedPrincipal.selector).checked_write(uint256(0));

        vm.prank(f.executor);
        vm.expectRevert(abi.encodeWithSelector(HLTradingBridge.WithdrawalIntentAmountExceeded.selector, 100_000e6, 0));
        f.bridge.requestWithdrawalIntent(100_000e6, address(f.bridge), f.sourceAccount, WITHDRAWAL_CHAIN_SELECTOR);

        vm.prank(f.owner);
        bytes32 intentId = f.bridge
            .requestZeroPrincipalWithdrawalIntent(
                100_000e6, address(f.bridge), f.sourceAccount, WITHDRAWAL_CHAIN_SELECTOR
            );
        f.usdc.mint(address(f.bridge), 100_000e6);
        vm.prank(f.keeper);
        f.bridge.reconcileWithdrawalArrival(intentId, 100_000e6);
        vm.prank(f.owner);
        f.bridge.returnZeroPrincipalUSDC(100_000e6, true);

        assertEq(f.vault.totalDeployed(), 900_000e6, "zero-principal cleanup returned principal to the vault");
        assertEq(f.bridge.deployedPrincipal(), 0, "bridge principal remains zero after cleanup");
    }

    function test_W1_openWithdrawalIntentHasTimeoutCancelPath() public {
        // CI-0067_POLICY_A_POSTFIX: W-1
        BridgeFixture memory f = _deployBridgeFixture();
        _deployAndPostHealthyNAV(f, 1_000_000e6);

        vm.prank(f.executor);
        bytes32 intentId =
            f.bridge.requestWithdrawalIntent(100_000e6, address(f.bridge), f.sourceAccount, WITHDRAWAL_CHAIN_SELECTOR);
        assertEq(f.bridge.openWithdrawalIntentId(), intentId, "setup: first withdrawal intent remains open");

        vm.warp(block.timestamp + 30 days);
        vm.prank(f.keeper);
        vm.expectRevert(HLTradingBridge.ArrivalAmountMismatch.selector);
        f.bridge.reconcileWithdrawalArrival(intentId, 100_000e6);

        vm.prank(f.executor);
        vm.expectRevert(abi.encodeWithSelector(HLTradingBridge.WithdrawalIntentPending.selector, intentId));
        f.bridge.requestWithdrawalIntent(1, address(f.bridge), f.sourceAccount, WITHDRAWAL_CHAIN_SELECTOR);

        vm.prank(f.keeper);
        f.bridge.cancelWithdrawalIntent(intentId);
        assertEq(f.bridge.openWithdrawalIntentId(), bytes32(0), "timeout cancel clears the open intent");
    }

    function test_W1_timeoutCancelUnblocksNextWithdrawalIntent() public {
        // CI-0067_POLICY_A_POSTFIX: W-1
        BridgeFixture memory f = _deployBridgeFixture();
        _deployAndPostHealthyNAV(f, 1_000_000e6);

        vm.prank(f.executor);
        bytes32 intentId =
            f.bridge.requestWithdrawalIntent(100_000e6, address(f.bridge), f.sourceAccount, WITHDRAWAL_CHAIN_SELECTOR);

        vm.prank(f.keeper);
        vm.expectRevert(HLTradingBridge.WithdrawalIntentNotExpired.selector);
        f.bridge.cancelWithdrawalIntent(intentId);

        vm.warp(block.timestamp + f.bridge.withdrawalIntentTimeoutSeconds() + 1);
        vm.prank(f.keeper);
        f.bridge.cancelWithdrawalIntent(intentId);
        assertEq(f.bridge.openWithdrawalIntentId(), bytes32(0), "timeout cancel clears open intent");

        vm.prank(f.executor);
        bytes32 nextIntent =
            f.bridge.requestWithdrawalIntent(50_000e6, address(f.bridge), f.sourceAccount, WITHDRAWAL_CHAIN_SELECTOR);
        assertEq(f.bridge.openWithdrawalIntentId(), nextIntent, "new withdrawal intent can open after cancellation");
    }

    function _deployBridgeFixture() internal returns (BridgeFixture memory f) {
        f.owner = makeAddr("octane25.bridge.owner");
        f.keeper = makeAddr("octane25.bridge.keeper");
        f.executor = makeAddr("octane25.bridge.executor");
        f.guardianModule = makeAddr("octane25.bridge.guardianModule");
        f.vaultDepositor = makeAddr("octane25.bridge.depositor");
        f.coldAccount = makeAddr("octane25.bridge.cold");
        f.sourceAccount = bytes32(uint256(uint160(address(0xBEEF))));

        f.usdc = new MockUSDC();
        f.riskusd = _deployRISKUSD(f.owner);
        f.registry = _deployCustodianRegistry(f.owner, makeAddr("octane25.bridge.forageGovernor"), f.guardianModule);
        f.vault = _deployTargetVault(address(f.usdc), address(f.riskusd), f.owner);
        f.treasury = _deployTreasury(
            address(f.usdc),
            address(f.vault),
            makeAddr("octane25.bridge.vaultRegistry"),
            f.owner,
            makeAddr("octane25.bridge.foundationPrimary"),
            makeAddr("octane25.bridge.foundationBackup"),
            makeAddr("octane25.bridge.protocolPrimary"),
            makeAddr("octane25.bridge.protocolBackup")
        );
        f.blocklist = _deployBlocklist(makeAddr("octane25.bridge.blocklistGuardian"), f.owner);
        f.bridge = _deployBridge(
            address(f.usdc),
            address(f.vault),
            address(f.treasury),
            address(f.registry),
            f.owner,
            f.keeper,
            f.executor,
            f.guardianModule,
            f.coldAccount,
            f.sourceAccount
        );

        CustodianRegistry.CustodianConfig memory hlConfig = f.registry
            .hyperLiquidLaunchConfig(
                address(f.bridge), f.executor, uint32(WITHDRAWAL_CHAIN_SELECTOR), f.sourceAccount, 10_000_000e6
            );

        vm.startPrank(f.owner);
        f.registry.proposeCustodianConfig(hlConfig);
        f.treasury.setHLTradingBridge(address(f.bridge));
        f.treasury.setBlocklist(address(f.blocklist));
        f.bridge.setBlocklist(address(f.blocklist));
        f.riskusd.setBlocklist(address(f.blocklist));
        f.riskusd.setMinter(address(f.vault));
        f.vault.setBlocklist(address(f.blocklist));
        f.vault.setCustodian(address(f.bridge));
        f.vault.setDeploymentBufferBps(0);
        f.vault.setPerBlockMintCap(10_000, type(uint256).max);
        f.vault.setDailyMintCapBps(10_000);
        f.vault.setWeeklyMintCapBps(20_000);
        vm.warp(block.timestamp + f.vault.FINALIZE_DELAY() + 1);
        f.registry.finalizeCustodianConfig(hlConfig.id);
        f.riskusd.finalizeMinter();
        f.vault.finalizeCustodian();
        vm.stopPrank();

        f.usdc.mint(f.vaultDepositor, 10_000_000e6);
        vm.startPrank(f.vaultDepositor);
        f.usdc.approve(address(f.vault), 10_000_000e6);
        f.vault.deposit(10_000_000e6);
        vm.stopPrank();
    }

    function _deployAndPostHealthyNAV(BridgeFixture memory f, uint256 amount) internal {
        vm.prank(f.executor);
        f.bridge.deployToHyperLiquid(amount);
        vm.prank(f.keeper);
        f.bridge.postNAV(VAULT_ID, amount, amount, block.timestamp);
        assertFalse(f.vault.lossPending(), "setup: fresh at-par NAV leaves vault healthy");
    }

    function _requestAndReconcile(BridgeFixture memory f, uint256 amount) internal returns (bytes32 intentId) {
        vm.prank(f.executor);
        intentId =
            f.bridge.requestWithdrawalIntent(amount, address(f.bridge), f.sourceAccount, WITHDRAWAL_CHAIN_SELECTOR);
        f.usdc.mint(address(f.bridge), amount);
        vm.prank(f.keeper);
        f.bridge.reconcileWithdrawalArrival(intentId, amount);
    }

    function _deposit(RISKUSDVault vault, MockUSDC usdc, address account, uint256 amount) internal {
        usdc.mint(account, amount);
        vm.startPrank(account);
        usdc.approve(address(vault), amount);
        vault.deposit(amount);
        vm.stopPrank();
    }

    function _deployMockRiskVault(address usdc, address riskusd, address owner, address custodian)
        internal
        returns (RISKUSDVault)
    {
        RISKUSDVault implementation = new RISKUSDVault();
        bytes memory initData = abi.encodeCall(RISKUSDVault.initializeTarget, (usdc, riskusd, owner, custodian, owner));
        return RISKUSDVault(address(new ERC1967Proxy(address(implementation), initData)));
    }

    function _deployRISKUSD(address owner) internal returns (RISKUSD) {
        RISKUSD implementation = new RISKUSD();
        bytes memory initData = abi.encodeCall(RISKUSD.initialize, (owner));
        return RISKUSD(address(new ERC1967Proxy(address(implementation), initData)));
    }

    function _deployTargetVault(address usdc, address riskusd, address owner) internal returns (RISKUSDVault) {
        RISKUSDVault implementation = new RISKUSDVault();
        bytes memory initData = abi.encodeCall(RISKUSDVault.initializeTarget, (usdc, riskusd, owner, owner, owner));
        return RISKUSDVault(address(new ERC1967Proxy(address(implementation), initData)));
    }

    function _deployTreasury(
        address usdc,
        address vault,
        address vaultRegistry,
        address owner,
        address foundationPrimary,
        address foundationBackup,
        address protocolPrimary,
        address protocolBackup
    ) internal returns (USDCTreasury) {
        USDCTreasury implementation = new USDCTreasury();
        bytes memory initData = abi.encodeCall(
            USDCTreasury.initialize,
            (usdc, vault, vaultRegistry, owner, foundationPrimary, foundationBackup, protocolPrimary, protocolBackup)
        );
        return USDCTreasury(address(new ERC1967Proxy(address(implementation), initData)));
    }

    function _deployCustodianRegistry(address owner, address forageGovernor, address guardianModule)
        internal
        returns (CustodianRegistry)
    {
        CustodianRegistry implementation = new CustodianRegistry();
        bytes memory initData = abi.encodeCall(CustodianRegistry.initialize, (owner, forageGovernor, guardianModule));
        return CustodianRegistry(address(new ERC1967Proxy(address(implementation), initData)));
    }

    function _deployBlocklist(address guardian, address owner) internal returns (Blocklist) {
        Blocklist implementation = new Blocklist();
        bytes memory initData = abi.encodeCall(Blocklist.initialize, (guardian, owner));
        return Blocklist(address(new ERC1967Proxy(address(implementation), initData)));
    }

    function _deployBridge(
        address usdc,
        address riskusdVault,
        address treasury,
        address registry,
        address owner,
        address keeper,
        address executor,
        address guardianModule,
        address coldAccount,
        bytes32 sourceAccount
    ) internal returns (HLTradingBridge) {
        HLTradingBridge implementation = new HLTradingBridge();
        bytes memory initData = abi.encodeCall(
            HLTradingBridge.initialize,
            (
                usdc,
                riskusdVault,
                treasury,
                registry,
                owner,
                keeper,
                executor,
                guardianModule,
                HLTradingBridge.RouteConfig({
                    coldAccount: coldAccount,
                    hyperliquidSourceAccount: sourceAccount,
                    withdrawalChainSelector: WITHDRAWAL_CHAIN_SELECTOR
                })
            )
        );
        return HLTradingBridge(address(new ERC1967Proxy(address(implementation), initData)));
    }
}
