// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/Blocklist.sol";
import "../src/RISKUSD.sol";
import "../src/RISKUSDVault.sol";
import "../src/USDCTreasury.sol";
import "../src/VaultRegistry.sol";
import "../src/atRISKUSD.sol";
import "./mocks/MockUSDC.sol";

contract RevertingUSDCTreasuryBlocklist {
    function isBlocked(address) external pure returns (bool) {
        revert("blocklist unavailable");
    }
}

contract USDCTreasury_TargetAccounting is Test {
    USDCTreasury internal treasury;
    MockUSDC internal usdc;
    RISKUSD internal riskusd;
    RISKUSDVault internal riskusdVault;
    VaultRegistry internal vaultRegistry;
    atRISKUSD internal tier0;
    atRISKUSD internal tier1;
    atRISKUSD internal tier2;
    atRISKUSD internal tier3;

    address internal owner = makeAddr("timelock");
    address internal guardian = makeAddr("guardian");
    address internal attestor = makeAddr("pnl-attestor");
    address internal bridge = makeAddr("hl-bridge");
    address internal foundationPrimary = makeAddr("foundation-primary");
    address internal foundationBackup = makeAddr("foundation-backup");
    address internal protocolPrimary = makeAddr("protocol-primary");
    address internal protocolBackup = makeAddr("protocol-backup");
    address internal newFoundationPrimary = makeAddr("new-foundation-primary");
    address internal stakingQueue = makeAddr("staking-queue");
    uint256 internal vaultId;
    Blocklist internal blocklist;

    function setUp() public {
        usdc = new MockUSDC();

        RISKUSD riskusdImplementation = new RISKUSD();
        bytes memory riskusdInit = abi.encodeCall(RISKUSD.initialize, (owner));
        riskusd = RISKUSD(address(new ERC1967Proxy(address(riskusdImplementation), riskusdInit)));

        RISKUSDVault vaultImplementation = new RISKUSDVault();
        bytes memory vaultInit = abi.encodeCall(RISKUSDVault.initialize, (address(usdc), address(riskusd), owner));
        riskusdVault = RISKUSDVault(address(new ERC1967Proxy(address(vaultImplementation), vaultInit)));

        VaultRegistry registryImplementation = new VaultRegistry();
        bytes memory registryInit = abi.encodeCall(VaultRegistry.initialize, (owner));
        vaultRegistry = VaultRegistry(address(new ERC1967Proxy(address(registryImplementation), registryInit)));

        tier0 = _deployTier(0, 0, "TV0");
        tier1 = _deployTier(1, 90 days, "TV1");
        tier2 = _deployTier(2, 180 days, "TV2");
        tier3 = _deployTier(3, 360 days, "TV3");
        Blocklist blocklistImplementation = new Blocklist();
        bytes memory blocklistInit = abi.encodeCall(Blocklist.initialize, (guardian, owner));
        blocklist = Blocklist(address(new ERC1967Proxy(address(blocklistImplementation), blocklistInit)));

        address[4] memory tiers = [address(tier0), address(tier1), address(tier2), address(tier3)];
        uint256[4] memory lockups = [uint256(0), uint256(90 days), uint256(180 days), uint256(360 days)];
        uint16[4] memory yieldBps = [uint16(5000), uint16(5500), uint16(6000), uint16(6500)];
        uint16[4] memory fundingBps = [uint16(2000), uint16(1500), uint16(1000), uint16(500)];
        vm.startPrank(owner);
        vaultRegistry.initializeV2(address(riskusdVault));
        vaultId = vaultRegistry.addVault(
            "Target Vault", "TV", tiers, stakingQueue, 10_000_000e6, lockups, yieldBps, fundingBps
        );
        vm.stopPrank();

        USDCTreasury implementation = new USDCTreasury();
        bytes memory initData = abi.encodeCall(
            USDCTreasury.initialize,
            (
                address(usdc),
                address(riskusdVault),
                address(vaultRegistry),
                owner,
                foundationPrimary,
                foundationBackup,
                protocolPrimary,
                protocolBackup
            )
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        treasury = USDCTreasury(address(proxy));

        vm.startPrank(owner);
        treasury.setPnLAttestor(attestor);
        treasury.setHLTradingBridge(bridge);
        treasury.setBlocklist(address(blocklist));
        vm.stopPrank();
    }

    function _deployTier(uint8 tierId, uint256 lockup, string memory abbreviation) internal returns (atRISKUSD) {
        atRISKUSD implementation = new atRISKUSD();
        bytes memory initData = abi.encodeCall(
            atRISKUSD.initialize, (address(riskusd), address(0), stakingQueue, lockup, 0, tierId, abbreviation, owner)
        );
        return atRISKUSD(address(new ERC1967Proxy(address(implementation), initData)));
    }

    function test_TSCGB_A2_profitRecognitionIsAccountingOnly() public {
        uint256 profit = 1_000e6;

        usdc.mint(attestor, profit);
        vm.prank(attestor);
        usdc.approve(address(treasury), profit);

        uint256 attestorBalanceBefore = usdc.balanceOf(attestor);
        uint256 treasuryBalanceBefore = usdc.balanceOf(address(treasury));
        uint256 vaultBalanceBefore = usdc.balanceOf(address(riskusdVault));

        vm.prank(attestor);
        treasury.recognizePnL(vaultId, int256(profit));

        assertEq(usdc.balanceOf(attestor), attestorBalanceBefore, "attestation must not pull USDC");
        assertEq(usdc.balanceOf(address(treasury)), treasuryBalanceBefore, "attestation must not hold USDC");
        assertEq(usdc.balanceOf(address(riskusdVault)), vaultBalanceBefore, "attestation must not top up vault");
        assertEq(treasury.recognizedProfit(vaultId), profit, "profit accounting must be recorded");
    }

    function test_TSCGB_A2_lossMarksAllTiersDownEquallyBeforeRetainedBufferAndMovesNoCash() public {
        uint256 loss = 1_200e6;

        uint256 attestorBalanceBefore = usdc.balanceOf(attestor);
        uint256 treasuryBalanceBefore = usdc.balanceOf(address(treasury));
        uint256 vaultBalanceBefore = usdc.balanceOf(address(riskusdVault));

        vm.prank(attestor);
        treasury.recognizePnL(vaultId, -int256(loss));

        int256 tier0LossBps = treasury.tierAccountingAdjustmentBps(vaultId, 0);
        assertLt(tier0LossBps, 0, "loss must mark tier accounting down");
        assertEq(
            treasury.tierAccountingAdjustmentBps(vaultId, 1), tier0LossBps, "tier 1 loss percentage must match tier 0"
        );
        assertEq(
            treasury.tierAccountingAdjustmentBps(vaultId, 2), tier0LossBps, "tier 2 loss percentage must match tier 0"
        );
        assertEq(
            treasury.tierAccountingAdjustmentBps(vaultId, 3), tier0LossBps, "tier 3 loss percentage must match tier 0"
        );
        assertGt(
            treasury.retainedBufferLossAbsorbed(vaultId),
            0,
            "retained buffer must absorb the loss remainder after pro-rata tier markdown"
        );
        assertEq(usdc.balanceOf(attestor), attestorBalanceBefore, "loss attestation must not pull USDC");
        assertEq(usdc.balanceOf(address(treasury)), treasuryBalanceBefore, "loss attestation must not hold USDC");
        assertEq(usdc.balanceOf(address(riskusdVault)), vaultBalanceBefore, "loss attestation must not move vault cash");
    }

    function test_TSCGB_A2_minSignedLossMagnitudeDoesNotOverflow() public {
        vm.prank(attestor);
        treasury.recognizePnL(vaultId, type(int256).min);

        uint256 expectedLoss = uint256(type(int256).max) + 1;
        assertEq(
            treasury.retainedBufferLossAbsorbed(vaultId),
            expectedLoss / 10,
            "minimum int256 loss must be accounted without unary-minus overflow"
        );
        assertEq(treasury.tierAccountingAdjustmentBps(vaultId, 0), -1_000, "tier markdown must still be recorded");
    }

    function test_TSCGB_A3_directPrincipalTransferPathFailsLoudAndRecordIsAccountingOnly() public {
        uint256 principal = 400e6;
        usdc.mint(bridge, principal);

        vm.startPrank(bridge);
        usdc.approve(address(treasury), principal);
        vm.expectRevert(USDCTreasury.PrincipalReturnsUseVault.selector);
        treasury.returnPrincipalUSDC(principal);
        treasury.recordPrincipalReturnUSDC(principal);
        vm.stopPrank();

        assertEq(usdc.balanceOf(address(riskusdVault)), 0, "treasury must not move principal into the vault");
        assertEq(usdc.balanceOf(address(treasury)), 0, "principal must not remain in treasury");
        assertEq(usdc.balanceOf(bridge), principal, "principal cash remains with the bridge/vault return path");
        assertEq(treasury.totalPrincipalReturned(), principal, "principal counter records confirmed vault return");
    }

    function test_TSCGB_A3_returnedPnLFundsRecognizedClaimWithoutDoubleCountingTierMarkup() public {
        uint256 pnl = 1_000e6;

        vm.prank(attestor);
        treasury.recognizePnL(vaultId, int256(pnl));
        uint256 tier0AccountingAfterRecognition = treasury.tierAccountingValue(vaultId, 0);
        uint256 tier1AccountingAfterRecognition = treasury.tierAccountingValue(vaultId, 1);

        usdc.mint(bridge, pnl);
        vm.startPrank(bridge);
        usdc.approve(address(treasury), pnl);
        treasury.returnPnLUSDC(vaultId, pnl);
        vm.stopPrank();

        assertEq(
            treasury.tierAccountingValue(vaultId, 0),
            tier0AccountingAfterRecognition,
            "returning cash must not mark tier 0 up a second time"
        );
        assertEq(
            treasury.tierAccountingValue(vaultId, 1),
            tier1AccountingAfterRecognition,
            "returning cash must not mark tier 1 up a second time"
        );
        assertEq(
            treasury.earmarkBalance(treasury.EARMARK_VAULT_TOP_UP()),
            treasury.recognizedDepositorClaim(vaultId),
            "returned cash must fund the already-recognized depositor claim"
        );
    }

    function test_TSCGB_A3_repeatedPnLReturnsCannotFundSameRecognizedClaimTwice() public {
        uint256 pnl = 1_000e6;

        vm.prank(attestor);
        treasury.recognizePnL(vaultId, int256(pnl));

        usdc.mint(bridge, 2 * pnl);
        vm.startPrank(bridge);
        usdc.approve(address(treasury), 2 * pnl);
        treasury.returnPnLUSDC(vaultId, pnl);
        treasury.returnPnLUSDC(vaultId, pnl);
        vm.stopPrank();

        assertEq(
            treasury.earmarkBalance(treasury.EARMARK_VAULT_TOP_UP()),
            treasury.recognizedDepositorClaim(vaultId),
            "recognized depositor claim must be funded at most once"
        );
        assertEq(treasury.earmarkBalance(treasury.EARMARK_AGENT_PAY()), 700e6, "second return goes to agent pay");
    }

    function test_TSCGB_A4_returnPnLBooksFoundationAsFifteenPercentOfProfit() public {
        uint256 pnl = 1_000e6;
        usdc.mint(bridge, pnl);

        vm.startPrank(bridge);
        usdc.approve(address(treasury), pnl);
        treasury.returnPnLUSDC(vaultId, pnl);
        vm.stopPrank();

        assertEq(
            treasury.earmarkBalance(treasury.EARMARK_FOUNDATION()),
            150e6,
            "Foundation must receive 15% of profit: 50% of the 30% protocol share"
        );
        assertLe(treasury.foundationAllocationBps(), 5_000, "Foundation hard cap must be 50%");
    }

    function test_TSCGB_A5_disburseEnforcesPurposeEarmarkAndFoundationRollingCap() public {
        uint256 pnl = 1_000e6;
        usdc.mint(bridge, pnl);

        vm.startPrank(bridge);
        usdc.approve(address(treasury), pnl);
        treasury.returnPnLUSDC(vaultId, pnl);
        vm.stopPrank();

        bytes32 foundationEarmark = treasury.EARMARK_FOUNDATION();

        vm.prank(owner);
        treasury.disburse(foundationEarmark, foundationPrimary, 15e6);

        vm.prank(owner);
        vm.expectRevert(USDCTreasury.PurposeCapExceeded.selector);
        treasury.disburse(foundationEarmark, foundationPrimary, 1);

        assertEq(usdc.balanceOf(foundationPrimary), 15e6, "Foundation can receive only 10% per rolling 24h");
        assertEq(
            treasury.earmarkBalance(foundationEarmark), 135e6, "disbursement must debit only the Foundation earmark"
        );
    }

    function test_TSCGB_A5_vaultTopUpPaysOnlyVaultAndProtocolRetainedHasDailyCap() public {
        uint256 pnl = 10_000_000e6;

        vm.prank(attestor);
        treasury.recognizePnL(vaultId, int256(pnl));

        usdc.mint(bridge, pnl);
        vm.startPrank(bridge);
        usdc.approve(address(treasury), pnl);
        treasury.returnPnLUSDC(vaultId, pnl);
        vm.stopPrank();

        bytes32 vaultTopUp = treasury.EARMARK_VAULT_TOP_UP();
        vm.prank(owner);
        vm.expectRevert(USDCTreasury.DestinationNotAllowed.selector);
        treasury.disburse(vaultTopUp, makeAddr("not-vault"), 1);

        vm.prank(owner);
        treasury.disburse(vaultTopUp, address(riskusdVault), 100e6);
        assertEq(usdc.balanceOf(address(riskusdVault)), 100e6, "vault top-up must pay only the vault");

        uint256 retainedDailyCap = treasury.PROTOCOL_RETAINED_DAILY_CAP();
        vm.prank(owner);
        treasury.disburseProtocolRetained(retainedDailyCap);
        vm.prank(owner);
        vm.expectRevert(USDCTreasury.PurposeCapExceeded.selector);
        treasury.disburseProtocolRetained(1);
    }

    function test_TSCGB_A5_agentPayPerPaymentDailyCapAndBatchLimit() public {
        uint256 pnl = 1_000e6;
        usdc.mint(bridge, pnl);

        vm.startPrank(bridge);
        usdc.approve(address(treasury), pnl);
        treasury.returnPnLUSDC(vaultId, pnl);
        vm.stopPrank();

        bytes32 agentPay = treasury.EARMARK_AGENT_PAY();
        uint256 maxAgentPayment = treasury.earmarkBalance(agentPay) * treasury.AGENT_PAY_CAP_BPS() / 10_000;

        vm.prank(owner);
        vm.expectRevert(USDCTreasury.PurposeCapExceeded.selector);
        treasury.disburse(agentPay, makeAddr("agent-payee"), maxAgentPayment + 1);

        address[] memory recipients = new address[](101);
        uint256[] memory amounts = new uint256[](101);
        for (uint256 i; i < recipients.length; ++i) {
            recipients[i] = makeAddr(string.concat("agent-payee-", vm.toString(i)));
            amounts[i] = 1;
        }

        vm.prank(owner);
        vm.expectRevert(USDCTreasury.BatchLimitExceeded.selector);
        treasury.disburseAgentPayBatch(recipients, amounts);
    }

    function test_TSCGB_A6_blockedPrimaryFailsOverWithoutHaltingOtherEarmarks() public {
        uint256 pnl = 1_000e6;
        usdc.mint(bridge, pnl);

        vm.startPrank(bridge);
        usdc.approve(address(treasury), pnl);
        treasury.returnPnLUSDC(vaultId, pnl);
        vm.stopPrank();

        vm.prank(guardian);
        blocklist.blockAddress(foundationPrimary);

        vm.startPrank(owner);
        treasury.disburseFoundation(15e6);
        treasury.disburseProtocolRetained(100e6);
        vm.stopPrank();

        assertEq(usdc.balanceOf(foundationPrimary), 0, "blocked Foundation primary must not receive funds");
        assertEq(usdc.balanceOf(foundationBackup), 15e6, "Foundation backup must receive failover funds");
        assertEq(usdc.balanceOf(protocolPrimary), 100e6, "other earmarks must continue settling");
    }

    function test_TSCGB_A6_revertingBlocklistFailsLoudBeforeDisbursement() public {
        RevertingUSDCTreasuryBlocklist revertingBlocklist = new RevertingUSDCTreasuryBlocklist();

        vm.prank(owner);
        treasury.setBlocklist(address(revertingBlocklist));

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(USDCTreasury.BlocklistUnavailable.selector, address(revertingBlocklist)));
        treasury.disburseFoundation(1);
    }

    function test_TSCGB_A6_missingBlocklistFailsLoudBeforeDisbursement() public {
        USDCTreasury implementation = new USDCTreasury();
        bytes memory initData = abi.encodeCall(
            USDCTreasury.initialize,
            (
                address(usdc),
                address(riskusdVault),
                address(vaultRegistry),
                owner,
                foundationPrimary,
                foundationBackup,
                protocolPrimary,
                protocolBackup
            )
        );
        USDCTreasury unwiredTreasury = USDCTreasury(address(new ERC1967Proxy(address(implementation), initData)));

        vm.startPrank(owner);
        unwiredTreasury.setHLTradingBridge(bridge);
        vm.expectRevert(USDCTreasury.ZeroAddress.selector);
        unwiredTreasury.setBlocklist(address(0));
        vm.stopPrank();

        uint256 pnl = 100e6;
        usdc.mint(bridge, pnl);
        vm.startPrank(bridge);
        usdc.approve(address(unwiredTreasury), pnl);
        unwiredTreasury.returnPnLUSDC(vaultId, pnl);
        vm.stopPrank();

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(USDCTreasury.BlocklistUnavailable.selector, address(0)));
        unwiredTreasury.disburseFoundation(1);
    }

    function test_TSCGB_A7_walletRotationIsTwoStepAndTimeDelayed() public {
        vm.prank(owner);
        treasury.proposeFoundationPrimary(newFoundationPrimary);

        vm.prank(owner);
        vm.expectRevert(USDCTreasury.FinalizeDelayNotElapsed.selector);
        treasury.finalizeFoundationPrimary();

        vm.warp(block.timestamp + treasury.walletRotationDelay());

        vm.prank(owner);
        treasury.finalizeFoundationPrimary();

        assertEq(treasury.foundationPrimary(), newFoundationPrimary, "rotation must finalize after delay");
    }
}
