// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "../../../src/Blocklist.sol";
import "../../../src/CustodianRegistry.sol";
import "../../../src/FORAGETreasury.sol";
import "../../../src/RISKUSD.sol";
import "../../../src/RISKUSDVault.sol";
import "../../../src/USDCTreasury.sol";
import "../../../src/atRISKUSD.sol";
import "../../../src/hyperliquid/HLTradingBridge.sol";
import "../../../src/interfaces/IVaultRegistry.sol";
import "../../mocks/MockUSDC.sol";

contract Octane20260630FeeOnTransferUSDC is MockUSDC {
    address internal constant FEE_SINK = address(uint160(0xFEE));

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0) && value >= 100) {
            uint256 fee = value / 100;
            super._update(from, FEE_SINK, fee);
            super._update(from, to, value - fee);
            return;
        }
        super._update(from, to, value);
    }
}

contract Octane20260630VaultBridgeRedTest is Test {
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
        address manualReporter;
        address coldAccount;
        bytes32 sourceAccount;
    }

    uint256 internal constant VAULT_ID = 1;
    uint256 internal constant OTHER_VAULT_ID = 2;
    uint64 internal constant WITHDRAWAL_CHAIN_SELECTOR = 421_614;

    function test_V1_observationTimeLossSurvivesPostObservationPrincipalReturn() public {
        BridgeFixture memory f = _deployBridgeFixture();
        _deployAndPostHealthyNAV(f, 1_000_000e6);

        uint256 observedAt = block.timestamp;
        vm.warp(observedAt + 1 hours);
        _requestAndReconcile(f, 100_000e6);
        vm.prank(f.executor);
        f.bridge.returnPrincipalUSDC(100_000e6);

        vm.prank(f.keeper);
        f.bridge.postNAV(VAULT_ID, 1_000_000e6, 900_000e6, observedAt);

        assertTrue(
            f.vault.lossPending(), "observed 100k loss must remain pending after a post-observation principal return"
        );
        vm.prank(f.vaultDepositor);
        f.riskusd.approve(address(f.vault), 1);
        vm.prank(f.vaultDepositor);
        vm.expectRevert(RISKUSDVault.LossPending.selector);
        f.vault.redeem(1);
    }

    function test_V2_navBasisHealthyZeroNonceClearsStaleLossBindingBeforeDifferentVaultLoss() public {
        BridgeFixture memory f = _deployBridgeFixture();
        _deployAndPostHealthyNAV(f, 1_000_000e6);

        vm.prank(f.keeper);
        f.bridge.postNAV(VAULT_ID, 1_000_000e6, 900_000e6, block.timestamp);
        assertEq(f.vault.latestLossNonce(), 1, "setup: first attested loss nonce is open");

        _requestAndReconcile(f, 100_000e6);
        vm.prank(f.executor);
        f.bridge.returnPrincipalUSDCWithNAVBasis(100_000e6, true);

        vm.prank(f.keeper);
        f.bridge.postNAV(VAULT_ID, 900_000e6, 900_000e6, block.timestamp);
        assertFalse(f.vault.lossPending(), "setup: zero-nonce healthy NAV leaves no active shortfall");

        vm.prank(f.keeper);
        f.bridge.postNAV(OTHER_VAULT_ID, 900_000e6, 800_000e6, block.timestamp);

        assertEq(f.vault.latestLossNonce(), 2, "different-vault loss should post after stale binding cleanup");
        assertEq(f.vault.lossPendingVaultId(), OTHER_VAULT_ID, "new loss must bind to the new vault id");
    }

    function test_V3_cancelledWithdrawalIntentCanReconcileLateArrival() public {
        BridgeFixture memory f = _deployBridgeFixture();
        _deployAndPostHealthyNAV(f, 1_000_000e6);

        vm.prank(f.executor);
        bytes32 intentId =
            f.bridge.requestWithdrawalIntent(100_000e6, address(f.bridge), f.sourceAccount, WITHDRAWAL_CHAIN_SELECTOR);

        vm.warp(block.timestamp + f.bridge.withdrawalIntentTimeoutSeconds() + 1);
        vm.prank(f.keeper);
        f.bridge.cancelWithdrawalIntent(intentId);
        assertEq(f.bridge.openWithdrawalIntentId(), bytes32(0), "setup: timeout cancel clears the open intent");

        f.usdc.mint(address(f.bridge), 100_000e6);
        vm.prank(f.keeper);
        f.bridge.reconcileWithdrawalArrival(intentId, 100_000e6);

        assertEq(f.bridge.reconciledReturnLiquidity(), 100_000e6, "late arrival should become return liquidity");
    }

    function test_V4_mintCapsKeepHighWaterBaselineAfterRedemption() public {
        address owner = makeAddr("octane30.v4.owner");
        address alice = makeAddr("octane30.v4.alice");
        MockUSDC usdc = new MockUSDC();
        RISKUSD riskusd = _deployRISKUSD(owner);
        RISKUSDVault vault = _deployStandaloneVault(address(usdc), address(riskusd), owner);

        vm.startPrank(owner);
        riskusd.setMinter(address(vault));
        vault.setDeploymentBufferBps(0);
        vault.setPerBlockMintCap(10_000, type(uint256).max);
        vault.setDailyMintCapBps(10_000);
        vault.setWeeklyMintCapBps(10_000);
        vault.setWeeklyRedemptionCapBps(10_000);
        vault.setDailyRedemptionCapBps(10_000);
        vm.warp(block.timestamp + vault.FINALIZE_DELAY() + 1);
        riskusd.finalizeMinter();
        vm.stopPrank();

        _deposit(vault, usdc, alice, 1_000e6);
        vm.warp(block.timestamp + 7 days);
        vm.roll(block.number + 1);
        _deposit(vault, usdc, alice, 1_000e6);

        vm.prank(alice);
        riskusd.approve(address(vault), 1_900e6);
        vm.prank(alice);
        vault.redeem(1_900e6);
        assertEq(riskusd.totalSupply(), 100e6, "setup: circulating supply contracted to 100 USDC");

        vm.warp(block.timestamp + 7 days);
        assertEq(vault.effectiveWeeklyMintCap(), 1_000e6, "weekly mint cap keeps high-water baseline");
        assertEq(vault.effectiveDailyMintCap(), 1_000e6, "daily mint cap keeps high-water baseline");
    }

    function test_V6_zeroNonceManualNAVThatClampsBelowCurrentPrincipalIsDeferred() public {
        BridgeFixture memory f = _deployBridgeFixture();
        _deployAndPostHealthyNAV(f, 1_000_000e6);

        vm.startPrank(f.owner);
        f.vault.setManualAttestationReporter(f.manualReporter);
        vm.warp(block.timestamp + f.vault.FINALIZE_DELAY() + 1);
        f.vault.finalizeManualAttestationReporter();
        vm.stopPrank();

        vm.roll(block.number + 1);
        vm.prank(f.executor);
        f.bridge.deployToHyperLiquid(200_000e6);
        assertEq(f.vault.totalDeployed(), 1_200_000e6, "setup: post-attestation deployment exceeds 10 percent");

        vm.prank(f.manualReporter);
        f.vault.recordManualCustodianNAV(VAULT_ID, 1_200_000e6, 0);

        assertFalse(f.vault.lossPending(), "clamped zero-nonce manual NAV must not create a false shortfall");
    }

    function test_V7_zeroPrincipalReconciledPnLCanBeForwardedToTreasury() public {
        BridgeFixture memory f = _deployBridgeFixture();
        uint256 pnlAmount = 100_000e6;

        assertEq(f.bridge.deployedPrincipal(), 0, "setup: bridge starts with zero deployed principal");
        assertEq(f.vault.totalDeployed(), 0, "setup: vault starts with zero deployed principal");

        vm.prank(f.owner);
        bytes32 intentId = f.bridge
            .requestZeroPrincipalWithdrawalIntent(
                pnlAmount, address(f.bridge), f.sourceAccount, WITHDRAWAL_CHAIN_SELECTOR
            );
        f.usdc.mint(address(f.bridge), pnlAmount);
        vm.prank(f.keeper);
        f.bridge.reconcileWithdrawalArrival(intentId, pnlAmount);
        assertEq(f.bridge.reconciledReturnLiquidity(), pnlAmount, "setup: zero-principal PnL is reconciled");

        vm.prank(f.owner);
        (bool ok,) = address(f.bridge)
            .call(abi.encodeWithSignature("returnZeroPrincipalPnLUSDC(uint256,uint256)", VAULT_ID, pnlAmount));
        assertTrue(ok, "owner zero-principal PnL forwarder must route reconciled PnL to treasury");
        assertEq(f.usdc.balanceOf(address(f.treasury)), pnlAmount, "treasury receives zero-principal PnL");
    }

    function test_V8_feeOnTransferPnLReturnFailsLoudBeforeAccounting() public {
        address owner = makeAddr("octane30.v8.owner");
        address bridge = makeAddr("octane30.v8.bridge");
        Octane20260630FeeOnTransferUSDC usdc = new Octane20260630FeeOnTransferUSDC();
        USDCTreasury treasury = _deployTreasury(
            address(usdc),
            makeAddr("octane30.v8.vault"),
            makeAddr("octane30.v8.registry"),
            owner,
            makeAddr("octane30.v8.foundationPrimary"),
            makeAddr("octane30.v8.foundationBackup"),
            makeAddr("octane30.v8.protocolPrimary"),
            makeAddr("octane30.v8.protocolBackup")
        );
        uint256 amount = 1_000e6;

        vm.prank(owner);
        treasury.setHLTradingBridge(bridge);
        usdc.mint(bridge, amount);
        vm.prank(bridge);
        usdc.approve(address(treasury), amount);

        vm.expectRevert(abi.encodeWithSelector(USDCTreasury.USDCAmountMismatch.selector, amount, 990e6));
        vm.prank(bridge);
        treasury.returnPnLUSDC(VAULT_ID, amount);
    }

    function test_W1_deploymentBufferUsesActivePaginationWhenAvailable() public {
        address owner = makeAddr("octane30.w1.owner");
        address custodian = makeAddr("octane30.w1.custodian");
        address alice = makeAddr("octane30.w1.alice");
        MockUSDC usdc = new MockUSDC();
        RISKUSD riskusd = _deployRISKUSD(owner);
        RISKUSDVault vault = _deployStandaloneVault(address(usdc), address(riskusd), owner, custodian, owner);
        Octane20260630FixedAssetsVault tierVault = new Octane20260630FixedAssetsVault(800e6);
        Octane20260630ActiveOnlyBufferRegistry registry =
            new Octane20260630ActiveOnlyBufferRegistry(address(vault), VAULT_ID, address(tierVault));

        vm.startPrank(owner);
        riskusd.setMinter(address(vault));
        vault.initializeV2(address(registry));
        vault.setDeploymentBufferBps(500);
        vault.setMaxDeploymentRatioBps(10_000);
        vm.warp(block.timestamp + vault.FINALIZE_DELAY() + 1);
        riskusd.finalizeMinter();
        vm.stopPrank();

        _deposit(vault, usdc, alice, 1_000e6);

        vm.prank(custodian);
        vault.deployCapital(760e6);

        assertEq(vault.totalDeployed(), 760e6, "deployment buffer must use active-page assets");
    }

    function test_PNL_EXP_returnBeforeRecognitionOverAllocatesAgentEarmark() public {
        BridgeFixture memory f = _deployBridgeFixture();
        uint256 pnlAmount = 100_000e6;
        _deployAndPostHealthyNAV(f, 1_000_000e6);
        _requestAndReconcile(f, pnlAmount);

        vm.prank(f.executor);
        f.bridge.returnPnLUSDC(VAULT_ID, pnlAmount);

        bytes32 agent = f.treasury.EARMARK_AGENT_PAY();
        bytes32 vaultTopUp = f.treasury.EARMARK_VAULT_TOP_UP();
        assertEq(f.treasury.earmarkBalance(vaultTopUp), 0, "unrecognized PnL leaves no depositor top-up");
        assertEq(f.treasury.earmarkBalance(agent), 70_000e6, "residual PnL is over-allocated to agent pay");
        assertEq(f.treasury.fundedDepositorClaim(VAULT_ID), 0, "late recognition cannot backfill prior return");

        address attestor = makeAddr("octane30.pnl.attestor");
        vm.prank(f.owner);
        f.treasury.setPnLAttestor(attestor);
        vm.prank(attestor);
        f.treasury.recognizePnL(VAULT_ID, int256(pnlAmount));

        assertEq(f.treasury.recognizedDepositorClaim(VAULT_ID), 70_000e6, "recognition records the missed claim");
        assertEq(f.treasury.earmarkBalance(vaultTopUp), 0, "prior earmarks are not rebalanced after recognition");
        assertEq(f.treasury.earmarkBalance(agent), 70_000e6, "agent earmark remains over-allocated");
    }

    function test_PNL_EXP_recognitionBeforeReturnFundsDepositorClaimBeforeAgent() public {
        BridgeFixture memory f = _deployBridgeFixture();
        uint256 pnlAmount = 100_000e6;
        address attestor = makeAddr("octane30.pnl.attestor.first");
        _deployAndPostHealthyNAV(f, 1_000_000e6);

        vm.prank(f.owner);
        f.treasury.setPnLAttestor(attestor);
        vm.prank(attestor);
        f.treasury.recognizePnL(VAULT_ID, int256(pnlAmount));
        _requestAndReconcile(f, pnlAmount);

        vm.prank(f.executor);
        f.bridge.returnPnLUSDC(VAULT_ID, pnlAmount);

        bytes32 agent = f.treasury.EARMARK_AGENT_PAY();
        bytes32 vaultTopUp = f.treasury.EARMARK_VAULT_TOP_UP();
        assertEq(f.treasury.earmarkBalance(vaultTopUp), 70_000e6, "recognized depositor claim is funded first");
        assertEq(f.treasury.earmarkBalance(agent), 0, "agent receives no residual when claim consumes remainder");
        assertEq(f.treasury.fundedDepositorClaim(VAULT_ID), 70_000e6, "funded claim advances only on return");
    }

    function test_PNL_EXP_tierExchangeRateDoesNotMoveOnTreasuryPnLReturn() public {
        BridgeFixture memory f = _deployBridgeFixture();
        address stakingQueue = makeAddr("octane30.pnl.stakingQueue");
        atRISKUSD tier = _deployAtRiskTier(address(f.riskusd), address(f.treasury), stakingQueue, f.owner);
        uint256 initialAssets = 1_000e6;
        uint256 pnlAmount = 100_000e6;

        vm.prank(f.vaultDepositor);
        f.riskusd.transfer(stakingQueue, initialAssets);
        vm.startPrank(stakingQueue);
        f.riskusd.approve(address(tier), initialAssets);
        tier.deposit(initialAssets, f.vaultDepositor);
        vm.stopPrank();

        uint256 shares = tier.balanceOf(f.vaultDepositor);
        uint256 assetsBefore = tier.totalAssets();
        uint256 shareValueBefore = tier.convertToAssets(shares);
        uint256 riskusdBalanceBefore = f.riskusd.balanceOf(address(tier));

        vm.prank(f.owner);
        bytes32 intentId = f.bridge
            .requestZeroPrincipalWithdrawalIntent(
                pnlAmount, address(f.bridge), f.sourceAccount, WITHDRAWAL_CHAIN_SELECTOR
            );
        f.usdc.mint(address(f.bridge), pnlAmount);
        vm.prank(f.keeper);
        f.bridge.reconcileWithdrawalArrival(intentId, pnlAmount);
        vm.prank(f.owner);
        f.bridge.returnZeroPrincipalPnLUSDC(VAULT_ID, pnlAmount);

        assertEq(tier.totalAssets(), assetsBefore, "treasury USDC PnL return does not call tier accrueYield");
        assertEq(tier.convertToAssets(shares), shareValueBefore, "tier share value is unchanged");
        assertEq(f.riskusd.balanceOf(address(tier)), riskusdBalanceBefore, "tier receives no RISKUSD from treasury");
        assertEq(f.usdc.balanceOf(address(f.treasury)), pnlAmount, "PnL is held and earmarked in USDC treasury");
    }

    function test_PNL_EXP_staleObservedNAVRevertsBeforeVaultStateMutation() public {
        BridgeFixture memory f = _deployBridgeFixture();
        uint256 deployed = 1_000_000e6;
        _deployAndPostHealthyNAV(f, deployed);

        uint256 observedAt = f.bridge.lastNAVObservedAt();
        vm.warp(observedAt + f.bridge.DAY_SECONDS() + 1);

        vm.prank(f.keeper);
        vm.expectRevert(HLTradingBridge.StaleNAV.selector);
        f.bridge.postNAV(VAULT_ID, deployed, deployed, observedAt);

        assertEq(f.bridge.lastNAVObservedAt(), observedAt, "stale NAV must not update bridge timestamp");
        assertFalse(f.vault.lossPending(), "stale NAV must not mutate vault loss state");
    }

    function test_PNL_EXP_riskusdPauseExitLivenessDependsOnSenderExemption() public {
        BridgeFixture memory f = _deployBridgeFixture();
        address protocolSender = makeAddr("octane30.pnl.protocolSender");
        address recipient = makeAddr("octane30.pnl.recipient");
        uint256 amount = 1_000e6;

        vm.prank(f.vaultDepositor);
        f.riskusd.transfer(protocolSender, amount);
        vm.prank(f.owner);
        f.riskusd.pause();

        vm.prank(protocolSender);
        vm.expectRevert();
        f.riskusd.transfer(recipient, 1);

        vm.prank(f.owner);
        f.riskusd.setTransferExempt(protocolSender, true);
        vm.prank(protocolSender);
        f.riskusd.transfer(recipient, amount);

        assertEq(f.riskusd.balanceOf(recipient), amount, "sender exemption restores paused transfer liveness");
    }

    function test_PNL_EXP_expiredPendingKeeperCannotFinalizeWithoutOwnerCleanup() public {
        BridgeFixture memory f = _deployBridgeFixture();
        address staleKeeper = makeAddr("octane30.pnl.staleKeeper");
        address replacementKeeper = makeAddr("octane30.pnl.replacementKeeper");

        vm.prank(f.owner);
        f.bridge.proposeKeeper(staleKeeper);
        vm.warp(block.timestamp + f.bridge.PROPOSAL_EXPIRY() + 1);

        vm.prank(f.owner);
        vm.expectRevert(HLTradingBridge.ProposalExpired.selector);
        f.bridge.finalizeKeeper();
        assertEq(f.bridge.pendingKeeper(), staleKeeper, "expired pending keeper remains until explicit cleanup");

        vm.prank(f.owner);
        f.bridge.cancelPendingKeeper();
        vm.prank(f.owner);
        f.bridge.proposeKeeper(replacementKeeper);

        assertEq(f.bridge.pendingKeeper(), replacementKeeper, "owner cleanup is required before reproposal");
    }

    function test_PNL_EXP_republishingAgentRootResetsRoundAccountingButPreservesClaimFlag() public {
        address owner = makeAddr("octane30.pnl.forageTreasuryOwner");
        address agent = makeAddr("octane30.pnl.agent");
        address sweepRecipient = makeAddr("octane30.pnl.sweepRecipient");
        MockUSDC forage = new MockUSDC();
        FORAGETreasury treasury = _deployForageTreasury(address(forage), owner);
        uint256 roundId = 77;
        uint256 secondAmount = 200e6;
        Blocklist blocklist = _deployBlocklist(makeAddr("octane30.pnl.blocklistGuardian"), owner);

        vm.prank(owner);
        treasury.setBlocklist(address(blocklist));
        forage.mint(address(treasury), 300e6);

        _claimInitialAgentRound(treasury, owner, agent, roundId, 100e6);

        vm.warp(block.timestamp + treasury.AGENT_CLAIM_COOLDOWN() + 1);
        uint64 secondDeadline = _republishAgentRound(treasury, owner, agent, roundId, secondAmount);
        _assertAgentClaimStillBlocked(treasury, agent, roundId, secondAmount);

        vm.warp(uint256(secondDeadline) + 1);
        vm.prank(owner);
        treasury.sweepExpiredAgentRound(roundId, sweepRecipient);

        assertEq(forage.balanceOf(sweepRecipient), secondAmount, "expired replacement root sweeps reset amount");
    }

    function _deployBridgeFixture() internal returns (BridgeFixture memory f) {
        f.owner = makeAddr("octane30.bridge.owner");
        f.keeper = makeAddr("octane30.bridge.keeper");
        f.executor = makeAddr("octane30.bridge.executor");
        f.guardianModule = makeAddr("octane30.bridge.guardianModule");
        f.vaultDepositor = makeAddr("octane30.bridge.depositor");
        f.manualReporter = makeAddr("octane30.bridge.manualReporter");
        f.coldAccount = makeAddr("octane30.bridge.cold");
        f.sourceAccount = bytes32(uint256(uint160(address(0x6030))));

        f.usdc = new MockUSDC();
        f.riskusd = _deployRISKUSD(f.owner);
        f.registry = _deployCustodianRegistry(f.owner, makeAddr("octane30.bridge.forageGovernor"), f.guardianModule);
        f.vault = _deployStandaloneVault(address(f.usdc), address(f.riskusd), f.owner);
        f.treasury = _deployTreasury(
            address(f.usdc),
            address(f.vault),
            makeAddr("octane30.bridge.vaultRegistry"),
            f.owner,
            makeAddr("octane30.bridge.foundationPrimary"),
            makeAddr("octane30.bridge.foundationBackup"),
            makeAddr("octane30.bridge.protocolPrimary"),
            makeAddr("octane30.bridge.protocolBackup")
        );
        f.blocklist = _deployBlocklist(makeAddr("octane30.bridge.blocklistGuardian"), f.owner);
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
        f.vault.setWeeklyRedemptionCapBps(10_000);
        f.vault.setDailyRedemptionCapBps(10_000);
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

    function _deployRISKUSD(address owner) internal returns (RISKUSD) {
        RISKUSD implementation = new RISKUSD();
        bytes memory initData = abi.encodeCall(RISKUSD.initialize, (owner));
        return RISKUSD(address(new ERC1967Proxy(address(implementation), initData)));
    }

    function _deployStandaloneVault(address usdc, address riskusd, address owner) internal returns (RISKUSDVault) {
        return _deployStandaloneVault(usdc, riskusd, owner, owner, owner);
    }

    function _deployStandaloneVault(
        address usdc,
        address riskusd,
        address owner,
        address custodian,
        address lossReporter
    ) internal returns (RISKUSDVault) {
        RISKUSDVault implementation = new RISKUSDVault();
        bytes memory initData =
            abi.encodeCall(RISKUSDVault.initializeTarget, (usdc, riskusd, owner, custodian, lossReporter));
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

    function _deployAtRiskTier(address riskusd, address yieldSource, address stakingQueue, address owner)
        internal
        returns (atRISKUSD)
    {
        atRISKUSD implementation = new atRISKUSD();
        bytes memory initData =
            abi.encodeCall(atRISKUSD.initialize, (riskusd, yieldSource, stakingQueue, 0, 0, 0, "O30P", owner));
        return atRISKUSD(address(new ERC1967Proxy(address(implementation), initData)));
    }

    function _deployForageTreasury(address forageToken, address owner) internal returns (FORAGETreasury) {
        FORAGETreasury implementation = new FORAGETreasury();
        bytes memory initData = abi.encodeCall(FORAGETreasury.initialize, (forageToken, owner));
        return FORAGETreasury(address(new ERC1967Proxy(address(implementation), initData)));
    }

    function _claimInitialAgentRound(
        FORAGETreasury treasury,
        address owner,
        address agent,
        uint256 roundId,
        uint256 amount
    ) internal {
        bytes32[] memory emptyProof = new bytes32[](0);
        bytes32 root = _forageTreasuryLeaf(address(treasury), roundId, agent, amount);
        vm.prank(owner);
        treasury.publishAgentRoot(roundId, root, amount, uint64(block.timestamp + 10 days));
        vm.prank(agent);
        treasury.claimAgent(roundId, agent, amount, emptyProof);
        (,,, uint256 claimed, bool swept) = treasury.agentRounds(roundId);
        assertEq(claimed, amount, "setup: first round records claimed amount");
        assertFalse(swept, "setup: first round is unswept");
    }

    function _republishAgentRound(
        FORAGETreasury treasury,
        address owner,
        address agent,
        uint256 roundId,
        uint256 amount
    ) internal returns (uint64 deadline) {
        deadline = uint64(block.timestamp + 2 days);
        bytes32 root = _forageTreasuryLeaf(address(treasury), roundId, agent, amount);
        vm.prank(owner);
        treasury.publishAgentRoot(roundId, root, amount, deadline);

        (bytes32 storedRoot, uint256 storedTotal, uint64 storedDeadline, uint256 resetClaimed, bool resetSwept) =
            treasury.agentRounds(roundId);
        assertEq(storedRoot, root, "republish replaces root");
        assertEq(storedTotal, amount, "republish replaces total amount");
        assertEq(storedDeadline, deadline, "republish replaces deadline");
        assertEq(resetClaimed, 0, "republish resets per-round claimed accounting");
        assertFalse(resetSwept, "republish resets swept flag");
        assertTrue(treasury.agentClaimed(roundId, agent), "claimant flag survives republish");
    }

    function _assertAgentClaimStillBlocked(FORAGETreasury treasury, address agent, uint256 roundId, uint256 amount)
        internal
    {
        bytes32[] memory emptyProof = new bytes32[](0);
        vm.prank(agent);
        vm.expectRevert(FORAGETreasury.AlreadyClaimed.selector);
        treasury.claimAgent(roundId, agent, amount, emptyProof);
    }

    function _forageTreasuryLeaf(address treasury, uint256 roundId, address account, uint256 amount)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(bytes.concat(keccak256(abi.encode(treasury, roundId, account, amount))));
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

contract Octane20260630FixedAssetsVault {
    uint256 internal immutable _assets;

    constructor(uint256 assets_) {
        _assets = assets_;
    }

    function totalAssets() external view returns (uint256) {
        return _assets;
    }
}

contract Octane20260630ActiveOnlyBufferRegistry {
    address public immutable riskusdVault;
    VaultConfig internal _activeVault;

    constructor(address riskusdVault_, uint256 vaultId_, address tierVault_) {
        riskusdVault = riskusdVault_;
        address[4] memory tierVaults = [tierVault_, address(0), address(0), address(0)];
        uint256[4] memory lockups;
        uint16[4] memory yieldSplits = [uint16(1), uint16(1), uint16(1), uint16(1)];
        uint16[4] memory fundingBps;
        _activeVault = VaultConfig({
            vaultId: vaultId_,
            name: "Octane W1 Active",
            abbreviation: "O30W1",
            tierVaults: tierVaults,
            stakingQueue: address(0),
            capacityCap: 1,
            lockupDurations: lockups,
            yieldSplitsBps: yieldSplits,
            fundingBps: fundingBps,
            status: VaultStatus.Active
        });
    }

    function getVault(uint256 vaultId_) external view returns (VaultConfig memory) {
        require(vaultId_ == _activeVault.vaultId, "invalid vault id");
        return _activeVault;
    }

    function getAllVaults() external pure returns (uint256[] memory) {
        return new uint256[](0);
    }

    function getVaultsPage(uint256, uint256)
        external
        pure
        returns (uint256[] memory ids, uint256 nextOffset, uint256 total)
    {
        return (new uint256[](0), 0, 0);
    }

    function getActiveVaultsPage(uint256 offset, uint256 limit)
        external
        view
        returns (uint256[] memory ids, uint256 nextOffset, uint256 total)
    {
        total = 1;
        if (offset >= total || limit == 0) {
            return (new uint256[](0), total, total);
        }
        ids = new uint256[](1);
        ids[0] = _activeVault.vaultId;
        return (ids, total, total);
    }

    function notifyLossResolved() external {}
}
