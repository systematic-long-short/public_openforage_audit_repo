// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/governance/TimelockController.sol";

import "../src/Blocklist.sol";
import "../src/CustodianRegistry.sol";
import "../src/DelegatingVestingWallet.sol";
import "../src/FORAGETreasury.sol";
import "../src/ForageGovernor.sol";
import "../src/ForageToken.sol";
import "../src/GuardianModule.sol";
import "../src/RISKUSD.sol";
import "../src/RISKUSDVault.sol";
import "../src/StakingQueue.sol";
import "../src/USDCTreasury.sol";
import "../src/VaultRegistry.sol";
import "../src/atRISKUSD.sol";
import "../src/hyperliquid/HLTradingBridge.sol";

interface IForageGovernorWiredTarget {
    function FINALIZE_DELAY() external view returns (uint256);
    function setForageGovernor(address forageGovernor_) external;
    function finalizeForageGovernor() external;
}

/// @title Deploy
/// @notice Target-only deployer for the fourteen-contract OpenForage smart-contract stack.
/// @dev This deployer is intentionally limited to local dry-runs and Arbitrum Sepolia.
///      A mainnet deploy path must be a separate script with production governance timings.
contract Deploy is Script {
    error WrongDeployChain(uint256 chainId);
    error ExpectedDeployChainMismatch(uint256 expectedChainId, uint256 actualChainId);

    uint256 public constant LOCAL_CHAIN_ID = 31337;
    uint256 public constant ARBITRUM_SEPOLIA_CHAIN_ID = 421614;
    uint256 public constant MIN_DELAY = 0;
    uint256 public constant VOTING_DELAY = 0;
    uint256 public constant VOTING_PERIOD = 3600;
    uint256 public constant VESTING_DURATION = 126230400;
    uint256 public constant CLIFF_DURATION = 31557600;
    uint256 public constant COOLDOWN_PERIOD = 604800;
    uint256 public constant PROPOSAL_THRESHOLD_BPS = 100;
    uint256 public constant QUORUM_BPS = 400;
    uint256 public constant CAPACITY_CAP = 10_000_000e6;

    uint256 public constant GUARDIAN_PERMISSION_PAUSE = 1 << 0;
    bytes32 public constant PROPOSER_ROLE = keccak256("PROPOSER_ROLE");
    bytes32 public constant CANCELLER_ROLE = keccak256("CANCELLER_ROLE");
    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");

    uint256[4] public LOCKUP_PERIODS = [uint256(0), 7776000, 15552000, 31104000];
    uint16[4] public YIELD_SPLITS_BPS = [uint16(5000), 5500, 6000, 6500];
    uint16[4] public FUNDING_BPS = [uint16(2000), 1500, 1000, 500];

    address public deployedTimelock;
    address public deployedBlocklist;
    address public deployedCustodianRegistry;
    address public deployedVestingWallet;
    address public deployedFORAGETreasury;
    address public deployedForageToken;
    address public deployedGuardianModule;
    address public deployedRiskusd;
    address public deployedRiskusdVault;
    address public deployedVaultRegistry;
    address public deployedAtRiskTier0;
    address public deployedAtRiskTier1;
    address public deployedAtRiskTier2;
    address public deployedAtRiskTier3;
    address public deployedStakingQueue;
    address public deployedUSDCTreasury;
    address public deployedForageGovernor;
    address public deployedHLTradingBridge;

    address public implBlocklist;
    address public implCustodianRegistry;
    address public implFORAGETreasury;
    address public implForageToken;
    address public implGuardianModule;
    address public implRiskusd;
    address public implRiskusdVault;
    address public implVaultRegistry;
    address public implAtRiskUSD;
    address public implStakingQueue;
    address public implUSDCTreasury;
    address public implForageGovernor;
    address public implHLTradingBridge;

    address public cfgUsdc;
    address public cfgDeployer;
    address public cfgBeneficiary;
    address public cfgFoundationPrimary;
    address public cfgFoundationBackup;
    address public cfgProtocolPrimary;
    address public cfgProtocolBackup;
    address public cfgLaunchVotingDelegate;
    address public cfgKeeper;
    address public cfgCustodianExecutor;
    address public cfgColdAccount;
    bytes32 public cfgHyperliquidSourceAccount;
    uint64 public cfgWithdrawalChainSelector;
    bool public cfgRequireExplicitGuardians;

    event TargetProxyAddresses(
        address blocklist,
        address custodianRegistry,
        address forageTreasury,
        address forageToken,
        address guardianModule,
        address riskusd,
        address riskusdVault,
        address stakingQueue,
        address usdcTreasury,
        address vaultRegistry,
        address forageGovernor,
        address hlTradingBridge
    );

    struct AddressLedger {
        address[18] proxies;
        address[13] impls;
        address[11] configs;
    }

    struct PredictedAddresses {
        address vestingWallet;
        address forageTreasury;
        address forageToken;
        address riskusd;
        address vaultRegistry;
        address guardianModule;
        address forageGovernor;
        address blocklist;
        address custodianRegistry;
        address usdcTreasury;
        address hlTradingBridge;
        address riskusdVault;
        address[4] atRiskTiers;
        address stakingQueue;
    }

    function run() public virtual {
        _requireAllowedDeployChain();
        _requireExpectedDeployChain();

        uint256 deployerKey = vm.envOr("DEPLOYER_PRIVATE_KEY", uint256(0));
        address deployer = deployerKey == 0 ? msg.sender : vm.addr(deployerKey);
        cfgRequireExplicitGuardians = true;
        _requireExplicitGuardianConfig();
        DeployConfig memory cfg = DeployConfig({
            usdc: vm.envAddress("USDC_ADDRESS"),
            deployer: deployer,
            beneficiary: vm.envAddress("BENEFICIARY"),
            foundationPrimary: vm.envAddress("FOUNDATION_PRIMARY"),
            foundationBackup: vm.envAddress("FOUNDATION_BACKUP"),
            protocolPrimary: vm.envAddress("PROTOCOL_PRIMARY"),
            protocolBackup: vm.envAddress("PROTOCOL_BACKUP"),
            launchVotingDelegate: vm.envAddress("LAUNCH_VOTING_DELEGATE"),
            keeper: vm.envAddress("KEEPER_ADDRESS"),
            custodianExecutor: vm.envAddress("CUSTODIAN_EXECUTOR"),
            coldAccount: vm.envAddress("COLD_ACCOUNT_ADDRESS"),
            hyperliquidSourceAccount: vm.envBytes32("HYPERLIQUID_SOURCE_ACCOUNT"),
            withdrawalChainSelector: uint64(vm.envUint("WITHDRAWAL_CHAIN_SELECTOR")),
            manifestPath: vm.envOr("DEPLOYMENT_MANIFEST_PATH", string("deployments/arbitrum-sepolia/latest.json"))
        });

        if (deployerKey == 0) {
            vm.startBroadcast();
        } else {
            vm.startBroadcast(deployerKey);
        }

        _deployWithConfig(cfg, deployer);

        vm.stopBroadcast();
    }

    function _requireAllowedDeployChain() internal view {
        if (block.chainid != LOCAL_CHAIN_ID && block.chainid != ARBITRUM_SEPOLIA_CHAIN_ID) {
            revert WrongDeployChain(block.chainid);
        }
    }

    function _requireExpectedDeployChain() internal view {
        uint256 expectedChainId = vm.envUint("EXPECTED_CHAIN_ID");
        if (expectedChainId != block.chainid) {
            revert ExpectedDeployChainMismatch(expectedChainId, block.chainid);
        }
    }

    function _requireExplicitGuardianConfig() internal view {
        for (uint256 i; i < 7;) {
            string memory key = string.concat("GUARDIAN_", vm.toString(i));
            require(vm.envAddress(key) != address(0), "guardian required");
            unchecked {
                ++i;
            }
        }
    }

    function runWithConfig(
        address usdc,
        address beneficiary,
        address foundationPrimary,
        address foundationBackup,
        address protocolPrimary,
        address protocolBackup,
        address launchVotingDelegate
    ) public virtual {
        _deployWithConfig(
            DeployConfig({
                usdc: usdc,
                deployer: msg.sender,
                beneficiary: beneficiary,
                foundationPrimary: foundationPrimary,
                foundationBackup: foundationBackup,
                protocolPrimary: protocolPrimary,
                protocolBackup: protocolBackup,
                launchVotingDelegate: launchVotingDelegate,
                keeper: msg.sender,
                custodianExecutor: msg.sender,
                coldAccount: msg.sender,
                hyperliquidSourceAccount: bytes32(uint256(uint160(msg.sender))),
                withdrawalChainSelector: uint64(block.chainid),
                manifestPath: ""
            }),
            address(this)
        );
    }

    function getAddressLedger() external view returns (AddressLedger memory ledger) {
        ledger.proxies = [
            deployedTimelock,
            deployedBlocklist,
            deployedCustodianRegistry,
            deployedVestingWallet,
            deployedFORAGETreasury,
            deployedForageToken,
            deployedGuardianModule,
            deployedRiskusd,
            deployedRiskusdVault,
            deployedVaultRegistry,
            deployedAtRiskTier0,
            deployedAtRiskTier1,
            deployedAtRiskTier2,
            deployedAtRiskTier3,
            deployedStakingQueue,
            deployedUSDCTreasury,
            deployedForageGovernor,
            deployedHLTradingBridge
        ];
        ledger.impls = [
            implBlocklist,
            implCustodianRegistry,
            implFORAGETreasury,
            implForageToken,
            implGuardianModule,
            implRiskusd,
            implRiskusdVault,
            implVaultRegistry,
            implAtRiskUSD,
            implStakingQueue,
            implUSDCTreasury,
            implForageGovernor,
            implHLTradingBridge
        ];
        ledger.configs = [
            cfgUsdc,
            cfgDeployer,
            cfgBeneficiary,
            cfgFoundationPrimary,
            cfgFoundationBackup,
            cfgProtocolPrimary,
            cfgProtocolBackup,
            cfgLaunchVotingDelegate,
            cfgKeeper,
            cfgCustodianExecutor,
            cfgColdAccount
        ];
    }

    function deployedAtRiskTier(uint8 tier) external view returns (address) {
        if (tier == 0) return deployedAtRiskTier0;
        if (tier == 1) return deployedAtRiskTier1;
        if (tier == 2) return deployedAtRiskTier2;
        if (tier == 3) return deployedAtRiskTier3;
        revert("invalid tier");
    }

    struct DeployConfig {
        address usdc;
        address deployer;
        address beneficiary;
        address foundationPrimary;
        address foundationBackup;
        address protocolPrimary;
        address protocolBackup;
        address launchVotingDelegate;
        address keeper;
        address custodianExecutor;
        address coldAccount;
        bytes32 hyperliquidSourceAccount;
        uint64 withdrawalChainSelector;
        string manifestPath;
    }

    function _deployWithConfig(DeployConfig memory cfg, address createSender) internal {
        _recordConfig(cfg);
        _deployTimelock(cfg.deployer);
        _deployImplementations();
        PredictedAddresses memory predicted = _predictAddresses(createSender);
        _deployTokenAndTreasuries(cfg, predicted);
        _deployGovernanceAndRegistry(cfg, predicted);
        _deployRiskStack(cfg, predicted);
        _deployTierStack(predicted);
        _wireTargetStack(cfg);
        _emitAndWriteManifest(cfg.manifestPath);
    }

    function _recordConfig(DeployConfig memory cfg) internal {
        require(cfg.usdc != address(0), "usdc required");
        require(cfg.deployer != address(0), "deployer required");
        require(cfg.beneficiary != address(0), "beneficiary required");
        require(cfg.foundationPrimary != address(0), "foundation primary required");
        require(cfg.foundationBackup != address(0), "foundation backup required");
        require(cfg.protocolPrimary != address(0), "protocol primary required");
        require(cfg.protocolBackup != address(0), "protocol backup required");
        require(cfg.launchVotingDelegate != address(0), "launch delegate required");
        require(cfg.keeper != address(0), "keeper required");
        require(cfg.custodianExecutor != address(0), "executor required");
        require(cfg.coldAccount != address(0), "cold account required");
        require(cfg.hyperliquidSourceAccount != bytes32(0), "source account required");
        require(cfg.withdrawalChainSelector != 0, "withdrawal chain required");
        require(cfg.foundationPrimary != cfg.foundationBackup, "foundation wallets must differ");
        require(cfg.protocolPrimary != cfg.protocolBackup, "protocol wallets must differ");

        cfgUsdc = cfg.usdc;
        cfgDeployer = cfg.deployer;
        cfgBeneficiary = cfg.beneficiary;
        cfgFoundationPrimary = cfg.foundationPrimary;
        cfgFoundationBackup = cfg.foundationBackup;
        cfgProtocolPrimary = cfg.protocolPrimary;
        cfgProtocolBackup = cfg.protocolBackup;
        cfgLaunchVotingDelegate = cfg.launchVotingDelegate;
        cfgKeeper = cfg.keeper;
        cfgCustodianExecutor = cfg.custodianExecutor;
        cfgColdAccount = cfg.coldAccount;
        cfgHyperliquidSourceAccount = cfg.hyperliquidSourceAccount;
        cfgWithdrawalChainSelector = cfg.withdrawalChainSelector;
    }

    function _vestingStartTimestamp() internal view returns (uint64) {
        uint256 start = vm.envOr("VESTING_START_TIMESTAMP", block.timestamp + 1);
        require(start > block.timestamp, "vesting start must be future");
        return uint64(start);
    }

    function _minDelay() internal view virtual returns (uint256) {
        return MIN_DELAY;
    }

    function _votingDelay() internal view virtual returns (uint48) {
        return uint48(VOTING_DELAY);
    }

    function _votingPeriod() internal view virtual returns (uint32) {
        return uint32(VOTING_PERIOD);
    }

    function _timelockOperationDelay() internal view virtual returns (uint256) {
        return MIN_DELAY;
    }

    function _deployTimelock(address deployer) internal {
        address[] memory proposers = new address[](1);
        proposers[0] = deployer;
        address[] memory executors = new address[](2);
        executors[0] = deployer;
        executors[1] = address(0);
        deployedTimelock = address(new TimelockController(_minDelay(), proposers, executors, deployer));
    }

    function _deployImplementations() internal {
        implBlocklist = address(new Blocklist());
        implCustodianRegistry = address(new CustodianRegistry());
        implFORAGETreasury = address(new FORAGETreasury());
        implForageToken = address(new ForageToken());
        implGuardianModule = address(new GuardianModule());
        implRiskusd = address(new RISKUSD());
        implRiskusdVault = address(new RISKUSDVault());
        implVaultRegistry = address(new VaultRegistry());
        implAtRiskUSD = address(new atRISKUSD());
        implStakingQueue = address(new StakingQueue());
        implUSDCTreasury = address(new USDCTreasury());
        implForageGovernor = address(new ForageGovernor());
        implHLTradingBridge = address(new HLTradingBridge());
    }

    function _predictAddresses(address createSender) internal view returns (PredictedAddresses memory predicted) {
        uint256 nonce = vm.getNonce(createSender);
        predicted.vestingWallet = vm.computeCreateAddress(createSender, nonce++);
        predicted.forageTreasury = vm.computeCreateAddress(createSender, nonce++);
        predicted.forageToken = vm.computeCreateAddress(createSender, nonce++);
        predicted.guardianModule = vm.computeCreateAddress(createSender, nonce++);
        predicted.forageGovernor = vm.computeCreateAddress(createSender, nonce++);
        predicted.blocklist = vm.computeCreateAddress(createSender, nonce++);
        predicted.custodianRegistry = vm.computeCreateAddress(createSender, nonce++);
        predicted.riskusd = vm.computeCreateAddress(createSender, nonce++);
        predicted.vaultRegistry = vm.computeCreateAddress(createSender, nonce++);
        predicted.usdcTreasury = vm.computeCreateAddress(createSender, nonce++);
        predicted.hlTradingBridge = vm.computeCreateAddress(createSender, nonce++);
        predicted.riskusdVault = vm.computeCreateAddress(createSender, nonce++);
        predicted.atRiskTiers[0] = vm.computeCreateAddress(createSender, nonce++);
        predicted.atRiskTiers[1] = vm.computeCreateAddress(createSender, nonce++);
        predicted.atRiskTiers[2] = vm.computeCreateAddress(createSender, nonce++);
        predicted.atRiskTiers[3] = vm.computeCreateAddress(createSender, nonce++);
        predicted.stakingQueue = vm.computeCreateAddress(createSender, nonce++);
    }

    function _deployTokenAndTreasuries(DeployConfig memory cfg, PredictedAddresses memory predicted) internal {
        deployedVestingWallet = address(
            new DelegatingVestingWallet(
                cfg.beneficiary,
                _vestingStartTimestamp(),
                uint64(VESTING_DURATION),
                uint64(CLIFF_DURATION),
                cfg.deployer
            )
        );
        _requirePredicted(deployedVestingWallet, predicted.vestingWallet);

        deployedFORAGETreasury = _proxy(
            implFORAGETreasury, abi.encodeCall(FORAGETreasury.initialize, (predicted.forageToken, cfg.deployer))
        );
        _requirePredicted(deployedFORAGETreasury, predicted.forageTreasury);

        deployedForageToken = _proxy(
            implForageToken,
            abi.encodeWithSignature(
                "initialize(address,address,address)", deployedVestingWallet, deployedFORAGETreasury, cfg.deployer
            )
        );
        _requirePredicted(deployedForageToken, predicted.forageToken);
    }

    function _deployGovernanceAndRegistry(DeployConfig memory cfg, PredictedAddresses memory predicted) internal {
        address[] memory guardians = _guardianAddresses(cfg.deployer);
        uint256[] memory permissions = new uint256[](guardians.length);
        for (uint256 i; i < guardians.length;) {
            permissions[i] = GUARDIAN_PERMISSION_PAUSE;
            unchecked {
                ++i;
            }
        }

        deployedGuardianModule = _proxy(
            implGuardianModule,
            abi.encodeCall(
                GuardianModule.initialize, (predicted.forageGovernor, deployedTimelock, guardians, permissions)
            )
        );
        _requirePredicted(deployedGuardianModule, predicted.guardianModule);

        deployedForageGovernor = _proxy(
            implForageGovernor,
            abi.encodeCall(
                ForageGovernor.initialize,
                (
                    deployedForageToken,
                    deployedTimelock,
                    _votingDelay(),
                    _votingPeriod(),
                    PROPOSAL_THRESHOLD_BPS,
                    QUORUM_BPS,
                    deployedGuardianModule
                )
            )
        );
        _requirePredicted(deployedForageGovernor, predicted.forageGovernor);

        deployedBlocklist = _proxy(implBlocklist, abi.encodeCall(Blocklist.initialize, (guardians[0], cfg.deployer)));
        _requirePredicted(deployedBlocklist, predicted.blocklist);
        deployedCustodianRegistry = _proxy(
            implCustodianRegistry,
            abi.encodeCall(CustodianRegistry.initialize, (cfg.deployer, deployedForageGovernor, deployedGuardianModule))
        );
        _requirePredicted(deployedCustodianRegistry, predicted.custodianRegistry);
    }

    function _deployRiskStack(DeployConfig memory cfg, PredictedAddresses memory predicted) internal {
        deployedRiskusd = _proxy(implRiskusd, abi.encodeCall(RISKUSD.initialize, (cfg.deployer)));
        _requirePredicted(deployedRiskusd, predicted.riskusd);
        deployedVaultRegistry = _proxy(implVaultRegistry, abi.encodeCall(VaultRegistry.initialize, (cfg.deployer)));
        _requirePredicted(deployedVaultRegistry, predicted.vaultRegistry);

        deployedUSDCTreasury = _proxy(
            implUSDCTreasury,
            abi.encodeCall(
                USDCTreasury.initialize,
                (
                    cfg.usdc,
                    predicted.riskusdVault,
                    deployedVaultRegistry,
                    cfg.deployer,
                    cfg.foundationPrimary,
                    cfg.foundationBackup,
                    cfg.protocolPrimary,
                    cfg.protocolBackup
                )
            )
        );
        _requirePredicted(deployedUSDCTreasury, predicted.usdcTreasury);

        deployedHLTradingBridge = _proxy(
            implHLTradingBridge,
            abi.encodeCall(
                HLTradingBridge.initialize,
                (
                    cfg.usdc,
                    predicted.riskusdVault,
                    deployedUSDCTreasury,
                    deployedCustodianRegistry,
                    cfg.deployer,
                    cfg.keeper,
                    cfg.custodianExecutor,
                    deployedGuardianModule,
                    HLTradingBridge.RouteConfig({
                        coldAccount: cfg.coldAccount,
                        hyperliquidSourceAccount: cfg.hyperliquidSourceAccount,
                        withdrawalChainSelector: cfg.withdrawalChainSelector
                    })
                )
            )
        );
        _requirePredicted(deployedHLTradingBridge, predicted.hlTradingBridge);

        deployedRiskusdVault = _proxy(
            implRiskusdVault,
            abi.encodeCall(
                RISKUSDVault.initializeTarget,
                (cfg.usdc, deployedRiskusd, cfg.deployer, deployedHLTradingBridge, deployedUSDCTreasury)
            )
        );
        _requirePredicted(deployedRiskusdVault, predicted.riskusdVault);
    }

    function _deployTierStack(PredictedAddresses memory predicted) internal {
        deployedAtRiskTier0 = _deployAtRisk(0, "atRISK0", predicted.stakingQueue);
        _requirePredicted(deployedAtRiskTier0, predicted.atRiskTiers[0]);
        deployedAtRiskTier1 = _deployAtRisk(1, "atRISK1", predicted.stakingQueue);
        _requirePredicted(deployedAtRiskTier1, predicted.atRiskTiers[1]);
        deployedAtRiskTier2 = _deployAtRisk(2, "atRISK2", predicted.stakingQueue);
        _requirePredicted(deployedAtRiskTier2, predicted.atRiskTiers[2]);
        deployedAtRiskTier3 = _deployAtRisk(3, "atRISK3", predicted.stakingQueue);
        _requirePredicted(deployedAtRiskTier3, predicted.atRiskTiers[3]);

        address[4] memory tierVaults =
            [deployedAtRiskTier0, deployedAtRiskTier1, deployedAtRiskTier2, deployedAtRiskTier3];
        deployedStakingQueue = _proxy(
            implStakingQueue,
            abi.encodeCall(
                StakingQueue.initialize,
                (deployedRiskusd, deployedForageToken, tierVaults, deployedVaultRegistry, cfgDeployer)
            )
        );
        _requirePredicted(deployedStakingQueue, predicted.stakingQueue);
    }

    function _wireTargetStack(DeployConfig memory cfg) internal {
        TimelockController(payable(deployedTimelock)).grantRole(PROPOSER_ROLE, deployedForageGovernor);
        TimelockController(payable(deployedTimelock)).grantRole(CANCELLER_ROLE, deployedForageGovernor);

        DelegatingVestingWallet(deployedVestingWallet).setInitialDelegatee(cfg.launchVotingDelegate);
        DelegatingVestingWallet(deployedVestingWallet).precommitForageToken(deployedForageToken);
        DelegatingVestingWallet(deployedVestingWallet).setForageToken(deployedForageToken);

        VaultRegistry(deployedVaultRegistry).initializeV2(deployedRiskusdVault);
        VaultRegistry(deployedVaultRegistry).initializeV3();
        RISKUSDVault(deployedRiskusdVault).initializeV2(deployedVaultRegistry);

        address[4] memory tierVaults =
            [deployedAtRiskTier0, deployedAtRiskTier1, deployedAtRiskTier2, deployedAtRiskTier3];
        uint256 targetVaultId = VaultRegistry(deployedVaultRegistry)
            .addVault(
                "OpenForage Target Vault",
                "OF-TARGET",
                tierVaults,
                deployedStakingQueue,
                CAPACITY_CAP,
                LOCKUP_PERIODS,
                YIELD_SPLITS_BPS,
                FUNDING_BPS
            );
        StakingQueue(deployedStakingQueue).setVaultId(targetVaultId);

        RISKUSD(deployedRiskusd).setMinter(deployedRiskusdVault);
        RISKUSD(deployedRiskusd).setBlocklist(deployedBlocklist);

        RISKUSDVault(deployedRiskusdVault).setBlocklist(deployedBlocklist);
        RISKUSDVault(deployedRiskusdVault).setDailyRedemptionCapBps(200);

        ForageToken(deployedForageToken).setBlocklist(deployedBlocklist);
        ForageToken(deployedForageToken).setAuthorizedLocker(deployedStakingQueue, true);

        FORAGETreasury(deployedFORAGETreasury).setBlocklist(deployedBlocklist);

        USDCTreasury(deployedUSDCTreasury).setBlocklist(deployedBlocklist);
        USDCTreasury(deployedUSDCTreasury).setPnLAttestor(cfg.keeper);
        USDCTreasury(deployedUSDCTreasury).setHLTradingBridge(deployedHLTradingBridge);

        HLTradingBridge(deployedHLTradingBridge).setBlocklist(deployedBlocklist);

        StakingQueue(deployedStakingQueue).setBlocklist(deployedBlocklist);

        _wireForageGovernorPauseControls();

        _wireAtRisk(deployedAtRiskTier0);
        _wireAtRisk(deployedAtRiskTier1);
        _wireAtRisk(deployedAtRiskTier2);
        _wireAtRisk(deployedAtRiskTier3);

        DelegatingVestingWallet(deployedVestingWallet).setBlocklist(deployedBlocklist);

        CustodianRegistry.CustodianConfig memory config = CustodianRegistry(deployedCustodianRegistry)
            .hyperLiquidLaunchConfig(
                deployedHLTradingBridge,
                cfg.custodianExecutor,
                uint32(block.chainid),
                cfg.hyperliquidSourceAccount,
                CAPACITY_CAP
            );
        CustodianRegistry(deployedCustodianRegistry).proposeCustodianConfig(config);
        _afterInitialCustodianConfigProposed();

        _registerPausableTarget(deployedRiskusd);
        _registerPausableTarget(deployedRiskusdVault);
        _registerPausableTarget(deployedStakingQueue);
        _registerPausableTarget(deployedAtRiskTier0);
        _registerPausableTarget(deployedAtRiskTier1);
        _registerPausableTarget(deployedAtRiskTier2);
        _registerPausableTarget(deployedAtRiskTier3);
        _registerPausableTarget(deployedHLTradingBridge);
        _registerPausableTarget(deployedCustodianRegistry);
    }

    function _deployAtRisk(uint8 tier, string memory abbreviation, address stakingQueue_) internal returns (address) {
        return _proxy(
            implAtRiskUSD,
            abi.encodeCall(
                atRISKUSD.initialize,
                (
                    deployedRiskusd,
                    deployedUSDCTreasury,
                    stakingQueue_,
                    LOCKUP_PERIODS[tier],
                    COOLDOWN_PERIOD,
                    tier,
                    abbreviation,
                    cfgDeployer
                )
            )
        );
    }

    function _wireAtRisk(address tierVault) internal {
        atRISKUSD(tierVault).setBlocklist(deployedBlocklist);
        atRISKUSD(tierVault).initializeV2();
    }

    function _afterInitialCustodianConfigProposed() internal virtual {}

    function _wireForageGovernorPauseControls() internal {
        address[7] memory targets = [
            deployedRiskusd,
            deployedRiskusdVault,
            deployedStakingQueue,
            deployedAtRiskTier0,
            deployedAtRiskTier1,
            deployedAtRiskTier2,
            deployedAtRiskTier3
        ];

        uint256 readyAt = block.timestamp;
        for (uint256 i; i < targets.length;) {
            IForageGovernorWiredTarget target = IForageGovernorWiredTarget(targets[i]);
            target.setForageGovernor(deployedForageGovernor);
            uint256 targetReadyAt = block.timestamp + target.FINALIZE_DELAY() + 1;
            if (targetReadyAt > readyAt) {
                readyAt = targetReadyAt;
            }
            unchecked {
                ++i;
            }
        }

        if (block.timestamp < readyAt) {
            vm.warp(readyAt);
        }

        for (uint256 i; i < targets.length;) {
            IForageGovernorWiredTarget(targets[i]).finalizeForageGovernor();
            unchecked {
                ++i;
            }
        }
    }

    function _registerPausableTarget(address target) internal {
        bytes memory data = abi.encodeCall(GuardianModule.setPausableTarget, (target, true));
        _timelockCall(deployedGuardianModule, data);
    }

    function _timelockCall(address target, bytes memory data) internal {
        // Foundry dry runs start at timestamp 1, which OZ Timelock reserves as DONE_TIMESTAMP.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp <= 1) {
            vm.warp(2);
        }
        bytes32 salt = keccak256(abi.encode(target, data, block.number, block.timestamp));
        uint256 delay = _timelockOperationDelay();
        TimelockController timelock = TimelockController(payable(deployedTimelock));
        timelock.schedule(target, 0, data, bytes32(0), salt, delay);
        if (delay != 0) {
            vm.warp(block.timestamp + delay);
        }
        timelock.execute(target, 0, data, bytes32(0), salt);
    }

    function _proxy(address implementation, bytes memory initData) internal returns (address) {
        return address(new ERC1967Proxy(implementation, initData));
    }

    function _requirePredicted(address actual, address predicted) internal pure {
        require(actual == predicted, "predicted address mismatch");
    }

    function _guardianAddresses(address deployer) internal view returns (address[] memory guardians) {
        guardians = new address[](7);
        for (uint256 i; i < guardians.length;) {
            string memory key = string.concat("GUARDIAN_", vm.toString(i));
            if (cfgRequireExplicitGuardians) {
                guardians[i] = vm.envAddress(key);
                require(guardians[i] != address(0), "guardian required");
            } else {
                guardians[i] =
                    vm.envOr(key, address(uint160(uint256(keccak256(abi.encode(deployer, i, block.chainid))))));
            }
            unchecked {
                ++i;
            }
        }
    }

    function _emitAndWriteManifest(string memory manifestPath) internal {
        emit TargetProxyAddresses(
            deployedBlocklist,
            deployedCustodianRegistry,
            deployedFORAGETreasury,
            deployedForageToken,
            deployedGuardianModule,
            deployedRiskusd,
            deployedRiskusdVault,
            deployedStakingQueue,
            deployedUSDCTreasury,
            deployedVaultRegistry,
            deployedForageGovernor,
            deployedHLTradingBridge
        );

        if (bytes(manifestPath).length == 0) return;

        string memory root = "target_sc_gap";
        vm.serializeUint(root, "chainId", block.chainid);
        vm.serializeAddress(root, "usdc", cfgUsdc);
        vm.serializeAddress(root, "blocklist", deployedBlocklist);
        vm.serializeAddress(root, "custodianRegistry", deployedCustodianRegistry);
        vm.serializeAddress(root, "riskusd", deployedRiskusd);
        vm.serializeAddress(root, "riskusdVault", deployedRiskusdVault);
        vm.serializeAddress(root, "vaultRegistry", deployedVaultRegistry);
        vm.serializeAddress(root, "usdcTreasury", deployedUSDCTreasury);
        vm.serializeAddress(root, "forageToken", deployedForageToken);
        vm.serializeAddress(root, "forageTreasury", deployedFORAGETreasury);
        vm.serializeAddress(root, "forageGovernor", deployedForageGovernor);
        vm.serializeAddress(root, "timelockController", deployedTimelock);
        vm.serializeAddress(root, "guardianModule", deployedGuardianModule);
        vm.serializeAddress(root, "hlTradingBridge", deployedHLTradingBridge);
        vm.serializeAddress(root, "hyperliquidColdAccount", cfgColdAccount);
        vm.serializeAddress(root, "stakingQueue", deployedStakingQueue);
        address[] memory vestingWallets = new address[](1);
        vestingWallets[0] = deployedVestingWallet;
        vm.serializeAddress(root, "delegatingVestingWallets", vestingWallets);
        vm.serializeAddress(root, "atRiskusdTier0", deployedAtRiskTier0);
        vm.serializeAddress(root, "atRiskusdTier1", deployedAtRiskTier1);
        vm.serializeAddress(root, "atRiskusdTier2", deployedAtRiskTier2);
        string memory json = vm.serializeAddress(root, "atRiskusdTier3", deployedAtRiskTier3);
        vm.writeJson(json, manifestPath);
    }
}
