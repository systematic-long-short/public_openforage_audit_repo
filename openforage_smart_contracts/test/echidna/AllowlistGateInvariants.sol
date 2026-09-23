// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/governance/TimelockController.sol";
import "../../src/Allowlist.sol";
import "../../src/Blocklist.sol";
import "../../src/CustodianRegistry.sol";
import "../../src/DelegatingVestingWallet.sol";
import "../../src/FORAGETreasury.sol";
import "../../src/ForageGovernor.sol";
import "../../src/ForageToken.sol";
import "../../src/GuardianModule.sol";
import "../../src/RISKUSD.sol";
import "../../src/RISKUSDVault.sol";
import "../../src/StakingQueue.sol";
import "../../src/USDCTreasury.sol";
import "../../src/VaultRegistry.sol";
import "../../src/atRISKUSD.sol";
import "../../src/hyperliquid/HLTradingBridge.sol";
import "../../src/modules/RISKUSDVaultModule.sol";
import "../../src/modules/StakingQueueModule.sol";
import "../mocks/MockUSDC.sol";

/// @title AllowlistGateInvariants
/// @notice Echidna property harness: no unverified, non-system sender changes a storage word
///         outside the three token contracts' balance and allowance mappings.
/// @dev The snapshot table is taken from `forge inspect <Contract> storageLayout --json` at the
///      base commit; mapping entries are read at keys derived from the fixed actor set.
contract AllowlistGateInvariants {
    address internal constant HEVM = 0x7109709ECfa91a80626fF3989D68f67F5b1DD12D;
    address public constant FORGE_BREAK_CALLER = address(uint160(uint256(keccak256("FORGE_BREAK_CALLER"))));

    address internal constant SENDER_0 = address(0x0000000000000000000000000000000000010000);
    address internal constant SENDER_1 = address(0x0000000000000000000000000000000000020000);
    address internal constant SENDER_2 = address(0x0000000000000000000000000000000000030000);

    address internal constant FOUNDATION_PRIMARY = address(0x0000000000000000000000000000000000001001);
    address internal constant FOUNDATION_BACKUP = address(0x0000000000000000000000000000000000001002);
    address internal constant PROTOCOL_PRIMARY = address(0x0000000000000000000000000000000000001003);
    address internal constant PROTOCOL_BACKUP = address(0x0000000000000000000000000000000000001004);
    address internal constant SEQUENCER_FEED = address(0x0000000000000000000000000000000000001005);
    address internal constant KEEPER = address(0x0000000000000000000000000000000000002001);
    address internal constant CUSTODIAN_EXECUTOR = address(0x0000000000000000000000000000000000002002);
    address internal constant COLD_ACCOUNT = address(0x0000000000000000000000000000000000002003);

    uint256 internal constant CAPACITY_CAP = 10_000_000e6;
    uint256 internal constant VESTING_DURATION = 126230400;
    uint256 internal constant CLIFF_DURATION = 31557600;
    uint256 internal constant COOLDOWN_PERIOD = 604800;
    uint8 internal constant ACTOR_COUNT = 19;
    uint8 internal constant MAPPING_KEY_COUNT = 5;
    uint8 internal constant TARGET_COUNT = 15;

    uint16 internal constant PLAIN_COUNT = 253;
    uint16 internal constant MAP_COUNT = 79;
    uint32 internal constant TOTAL_WORD_COUNT = PLAIN_COUNT + MAP_COUNT * MAPPING_KEY_COUNT + 3;

    function _plainTargets() private pure returns (uint8[253] memory t) {
        return [
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            1,
            1,
            1,
            1,
            1,
            1,
            1,
            1,
            1,
            1,
            1,
            1,
            1,
            1,
            1,
            1,
            1,
            1,
            1,
            1,
            1,
            1,
            1,
            1,
            1,
            1,
            1,
            1,
            1,
            1,
            1,
            1,
            1,
            1,
            1,
            1,
            1,
            1,
            1,
            1,
            1,
            1,
            1,
            1,
            1,
            1,
            1,
            1,
            1,
            1,
            1,
            1,
            1,
            1,
            1,
            1,
            1,
            1,
            1,
            1,
            1,
            1,
            1,
            1,
            1,
            1,
            2,
            2,
            2,
            2,
            2,
            2,
            2,
            2,
            2,
            3,
            3,
            3,
            3,
            3,
            3,
            3,
            3,
            3,
            3,
            3,
            3,
            3,
            3,
            3,
            3,
            3,
            3,
            3,
            3,
            3,
            3,
            3,
            3,
            3,
            4,
            4,
            4,
            4,
            4,
            4,
            4,
            4,
            4,
            4,
            4,
            4,
            4,
            4,
            4,
            4,
            4,
            4,
            4,
            4,
            4,
            4,
            4,
            4,
            4,
            4,
            4,
            4,
            4,
            4,
            4,
            4,
            4,
            5,
            5,
            6,
            6,
            6,
            6,
            6,
            6,
            6,
            6,
            6,
            6,
            6,
            7,
            7,
            7,
            7,
            7,
            7,
            8,
            8,
            8,
            8,
            8,
            8,
            8,
            8,
            8,
            8,
            8,
            8,
            8,
            8,
            8,
            8,
            8,
            9,
            9,
            9,
            9,
            9,
            9,
            10,
            10,
            10,
            10,
            11,
            11,
            11,
            11,
            11,
            11,
            11,
            11,
            11,
            12,
            12,
            12,
            12,
            12,
            12,
            12,
            12,
            12,
            13,
            13,
            13,
            13,
            13,
            13,
            13,
            13,
            13,
            13,
            13,
            13,
            13,
            13,
            13,
            13,
            13,
            13,
            13,
            13,
            13,
            13,
            13,
            13,
            13,
            13,
            13,
            13,
            13,
            13,
            13,
            13,
            13,
            13,
            13,
            13,
            14,
            14,
            14,
            14,
            14,
            14,
            14
        ];
    }

    function _plainSlots() private pure returns (uint8[253] memory t) {
        return [
            0,
            1,
            2,
            3,
            4,
            5,
            6,
            6,
            7,
            8,
            8,
            8,
            14,
            0,
            1,
            2,
            3,
            4,
            5,
            6,
            7,
            8,
            9,
            10,
            11,
            12,
            13,
            14,
            15,
            16,
            17,
            18,
            19,
            20,
            20,
            20,
            21,
            22,
            23,
            24,
            25,
            25,
            26,
            27,
            28,
            29,
            30,
            31,
            32,
            33,
            34,
            35,
            36,
            37,
            38,
            39,
            40,
            41,
            42,
            43,
            44,
            45,
            46,
            47,
            48,
            49,
            50,
            51,
            53,
            54,
            55,
            56,
            57,
            58,
            59,
            60,
            61,
            62,
            65,
            0,
            1,
            3,
            4,
            5,
            6,
            7,
            9,
            10,
            0,
            1,
            2,
            2,
            3,
            4,
            7,
            8,
            10,
            11,
            12,
            13,
            14,
            15,
            16,
            17,
            18,
            19,
            20,
            21,
            22,
            26,
            27,
            28,
            29,
            0,
            1,
            2,
            3,
            4,
            5,
            6,
            7,
            8,
            9,
            10,
            11,
            17,
            20,
            21,
            22,
            23,
            23,
            23,
            24,
            25,
            26,
            27,
            27,
            28,
            29,
            29,
            30,
            31,
            32,
            34,
            36,
            37,
            6,
            10,
            0,
            1,
            7,
            8,
            9,
            10,
            11,
            12,
            13,
            14,
            15,
            0,
            1,
            2,
            3,
            5,
            7,
            0,
            1,
            2,
            3,
            4,
            5,
            6,
            7,
            8,
            9,
            10,
            11,
            12,
            13,
            24,
            25,
            26,
            0,
            1,
            3,
            5,
            6,
            13,
            0,
            1,
            2,
            7,
            9,
            10,
            11,
            12,
            13,
            14,
            15,
            16,
            17,
            0,
            1,
            3,
            6,
            9,
            9,
            10,
            11,
            13,
            0,
            1,
            2,
            3,
            4,
            5,
            6,
            7,
            8,
            9,
            10,
            11,
            12,
            13,
            14,
            15,
            16,
            17,
            17,
            18,
            19,
            20,
            21,
            22,
            23,
            24,
            24,
            26,
            27,
            28,
            29,
            30,
            31,
            32,
            33,
            34,
            0,
            1,
            2,
            3,
            4,
            5,
            6
        ];
    }

    function _mapTargets() private pure returns (uint8[79] memory t) {
        return [
            0,
            0,
            0,
            0,
            0,
            1,
            1,
            1,
            2,
            2,
            3,
            3,
            3,
            3,
            3,
            3,
            4,
            4,
            4,
            4,
            4,
            4,
            4,
            4,
            4,
            5,
            5,
            5,
            5,
            5,
            5,
            5,
            5,
            5,
            6,
            6,
            6,
            6,
            6,
            7,
            7,
            8,
            8,
            8,
            8,
            8,
            8,
            8,
            8,
            8,
            8,
            9,
            9,
            9,
            9,
            9,
            9,
            9,
            9,
            10,
            10,
            10,
            10,
            11,
            11,
            11,
            11,
            11,
            11,
            11,
            11,
            11,
            12,
            12,
            12,
            12,
            12,
            12,
            13
        ];
    }

    function _mapSlots() private pure returns (uint8[79] memory t) {
        return [
            9,
            10,
            11,
            12,
            13,
            52,
            63,
            64,
            2,
            8,
            5,
            6,
            9,
            23,
            24,
            25,
            12,
            13,
            14,
            15,
            16,
            18,
            19,
            33,
            35,
            0,
            1,
            2,
            3,
            4,
            5,
            7,
            8,
            9,
            2,
            3,
            4,
            5,
            6,
            4,
            6,
            14,
            15,
            16,
            17,
            18,
            19,
            20,
            21,
            22,
            23,
            2,
            4,
            7,
            8,
            9,
            10,
            11,
            12,
            3,
            4,
            5,
            6,
            0,
            1,
            2,
            3,
            4,
            5,
            6,
            7,
            8,
            2,
            4,
            5,
            7,
            8,
            12,
            25
        ];
    }

    function _mapKeyTypes() private pure returns (uint8[79] memory t) {
        return [
            0,
            0,
            0,
            0,
            0,
            0,
            3,
            0,
            0,
            1,
            0,
            0,
            0,
            0,
            0,
            2,
            2,
            3,
            3,
            3,
            3,
            0,
            2,
            3,
            0,
            0,
            0,
            0,
            0,
            16,
            0,
            0,
            0,
            16,
            2,
            2,
            18,
            18,
            0,
            2,
            2,
            2,
            2,
            2,
            66,
            66,
            1,
            1,
            1,
            2,
            2,
            0,
            0,
            17,
            1,
            1,
            17,
            1,
            1,
            0,
            0,
            0,
            0,
            1,
            1,
            33,
            33,
            33,
            33,
            1,
            33,
            33,
            2,
            1,
            0,
            2,
            2,
            2,
            1
        ];
    }

    address internal usdc;
    address internal allowlist;
    address internal timelock;
    address internal vestingWallet;
    address internal forageTreasury;
    address internal forageToken;
    address internal guardianModule;
    address internal forageGovernor;
    address internal blocklist;
    address internal custodianRegistry;
    address internal riskusd;
    address internal vaultRegistry;
    address internal usdcTreasury;
    address internal hlTradingBridge;
    address internal riskusdVault;
    address internal atRiskusd;
    address internal stakingQueue;

    address[TARGET_COUNT] internal targets;
    address[ACTOR_COUNT] internal actors;

    bool internal gateViolation;
    uint32 internal violationWord;
    bytes32 internal violationBefore;
    bytes32 internal violationAfter;
    address internal prankedCaller;

    modifier onlyForgeBreakCaller() {
        require(msg.sender == FORGE_BREAK_CALLER, "forge-only negative control");
        _;
    }

    address internal implAllowlist;
    address internal implBlocklist;
    address internal implCustodianRegistry;
    address internal implFORAGETreasury;
    address internal implForageToken;
    address internal implGuardianModule;
    address internal implRiskusd;
    address internal implRiskusdVault;
    address internal implVaultRegistry;
    address internal implAtRiskUSD;
    address internal implStakingQueue;
    address internal implUSDCTreasury;
    address internal implForageGovernor;
    address internal implHLTradingBridge;
    address internal implRiskusdVaultModule;
    address internal implStakingQueueModule;

    constructor() {
        require(block.timestamp > 1, "echidna harness needs a timestamp above 1");

        usdc = address(new MockUSDC());
        _deployImplementations();
        timelock = address(new TimelockController(0, _single(address(this)), _single(address(this)), address(this)));

        address predictedAllowlist = _createAddress(17);
        address predictedForageToken = _createAddress(20);
        address predictedGovernor = _createAddress(22);
        address predictedVault = _createAddress(29);
        address predictedStakingQueue = _createAddress(31);

        _deployAllowlistAndVesting(predictedAllowlist);
        _deployTokenAndGovernance(predictedForageToken, predictedGovernor);
        _deployRegistryAndRisk(predictedVault);
        _deployTierAndQueue(predictedStakingQueue);
        _deployModulesAndWire();

        _registerSystemAccounts();
        _setAdopterAllowlists();
        _buildTargetsAndActors();
    }

    function _deployImplementations() private {
        implAllowlist = address(new Allowlist());
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

    function _deployAllowlistAndVesting(address predictedAllowlist) private {
        allowlist = _proxy(
            implAllowlist,
            abi.encodeCall(
                Allowlist.initialize, (address(this), _guardianAt(0), uint64(Allowlist(implAllowlist).FINALIZE_DELAY()))
            )
        );
        require(allowlist == predictedAllowlist, "allowlist address mismatch");
        Allowlist(allowlist).setSystemAccount(address(this), true);
        vestingWallet = address(
            new DelegatingVestingWallet(
                address(this),
                uint64(block.timestamp + 1),
                uint64(VESTING_DURATION),
                uint64(CLIFF_DURATION),
                address(this),
                allowlist
            )
        );
    }

    function _deployTokenAndGovernance(address predictedForageToken, address predictedGovernor) private {
        forageTreasury = _proxy(
            implFORAGETreasury, abi.encodeCall(FORAGETreasury.initialize, (predictedForageToken, address(this)))
        );
        forageToken = _proxy(
            implForageToken, abi.encodeCall(ForageToken.initialize, (vestingWallet, forageTreasury, address(this)))
        );
        require(forageToken == predictedForageToken, "forage token address mismatch");

        guardianModule = _proxy(
            implGuardianModule,
            abi.encodeCall(
                GuardianModule.initialize, (predictedGovernor, timelock, _guardians(), _guardianPermissions())
            )
        );
        forageGovernor = _proxy(
            implForageGovernor,
            abi.encodeCall(
                ForageGovernor.initialize,
                (forageToken, timelock, uint48(0), uint32(3600), uint256(100), uint256(400), guardianModule)
            )
        );
        require(forageGovernor == predictedGovernor, "forage governor address mismatch");

        blocklist = _proxy(implBlocklist, abi.encodeCall(Blocklist.initialize, (_guardianAt(0), address(this))));
        custodianRegistry = _proxy(
            implCustodianRegistry,
            abi.encodeCall(CustodianRegistry.initialize, (address(this), forageGovernor, guardianModule))
        );
    }

    function _deployRegistryAndRisk(address predictedVault) private {
        riskusd = _proxy(implRiskusd, abi.encodeCall(RISKUSD.initialize, (address(this))));
        vaultRegistry = _proxy(implVaultRegistry, abi.encodeCall(VaultRegistry.initialize, (address(this))));
        usdcTreasury = _proxy(
            implUSDCTreasury,
            abi.encodeCall(
                USDCTreasury.initialize,
                (
                    usdc,
                    predictedVault,
                    vaultRegistry,
                    address(this),
                    FOUNDATION_PRIMARY,
                    FOUNDATION_BACKUP,
                    PROTOCOL_PRIMARY,
                    PROTOCOL_BACKUP
                )
            )
        );
        hlTradingBridge = _proxy(
            implHLTradingBridge,
            abi.encodeCall(
                HLTradingBridge.initialize,
                (
                    usdc,
                    predictedVault,
                    usdcTreasury,
                    custodianRegistry,
                    address(this),
                    KEEPER,
                    CUSTODIAN_EXECUTOR,
                    guardianModule,
                    HLTradingBridge.RouteConfig({
                        coldAccount: COLD_ACCOUNT,
                        hyperliquidSourceAccount: bytes32(uint256(uint160(address(this)))),
                        withdrawalChainSelector: uint64(block.chainid),
                        sequencerUptimeFeed: SEQUENCER_FEED
                    })
                )
            )
        );
        riskusdVault = _proxy(
            implRiskusdVault,
            abi.encodeCall(RISKUSDVault.initializeTarget, (usdc, riskusd, address(this), hlTradingBridge, usdcTreasury))
        );
        require(riskusdVault == predictedVault, "riskusd vault address mismatch");
    }

    function _deployTierAndQueue(address predictedStakingQueue) private {
        atRiskusd = _proxy(
            implAtRiskUSD,
            abi.encodeCall(
                atRISKUSD.initialize,
                (
                    riskusd,
                    usdcTreasury,
                    predictedStakingQueue,
                    uint256(0),
                    COOLDOWN_PERIOD,
                    uint8(0),
                    "atRISK0",
                    address(this)
                )
            )
        );
        address[4] memory tierVaults = [atRiskusd, atRiskusd, atRiskusd, atRiskusd];
        stakingQueue = _proxy(
            implStakingQueue,
            abi.encodeCall(StakingQueue.initialize, (riskusd, forageToken, tierVaults, vaultRegistry, address(this)))
        );
        require(stakingQueue == predictedStakingQueue, "staking queue address mismatch");
    }

    /// @dev Module deployment comes last so the create-address predictions above keep their nonces.
    function _deployModulesAndWire() private {
        implRiskusdVaultModule = address(new RISKUSDVaultModule());
        implStakingQueueModule = address(new StakingQueueModule());
        RISKUSDVault(riskusdVault).setVaultModule(implRiskusdVaultModule);
        StakingQueue(stakingQueue).setQueueModule(implStakingQueueModule);
    }

    function _single(address account) private pure returns (address[] memory accounts) {
        accounts = new address[](1);
        accounts[0] = account;
    }

    function _guardianAt(uint256 index) private pure returns (address) {
        address[7] memory guardians = _guardianList();
        return guardians[index];
    }

    function _guardianList() private pure returns (address[7] memory guardians) {
        guardians = [
            address(0x0000000000000000000000000000000000003001),
            address(0x0000000000000000000000000000000000003002),
            address(0x0000000000000000000000000000000000003003),
            address(0x0000000000000000000000000000000000003004),
            address(0x0000000000000000000000000000000000003005),
            address(0x0000000000000000000000000000000000003006),
            address(0x0000000000000000000000000000000000003007)
        ];
    }

    function _guardians() private pure returns (address[] memory guardians) {
        address[7] memory list = _guardianList();
        guardians = new address[](7);
        for (uint256 i; i < 7; ++i) {
            guardians[i] = list[i];
        }
    }

    function _guardianPermissions() private pure returns (uint256[] memory permissions) {
        permissions = new uint256[](7);
        for (uint256 i; i < 7; ++i) {
            permissions[i] = 1;
        }
    }

    function _createAddress(uint8 nonce) private view returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xd6), bytes1(0x94), address(this), nonce)))));
    }

    function _proxy(address implementation, bytes memory initData) private returns (address) {
        return address(new ERC1967Proxy(implementation, initData));
    }

    function _registerSystemAccounts() private {
        Allowlist registry = Allowlist(allowlist);
        registry.setSystemAccount(timelock, true);
        registry.setSystemAccount(blocklist, true);
        registry.setSystemAccount(custodianRegistry, true);
        registry.setSystemAccount(vestingWallet, true);
        registry.setSystemAccount(forageTreasury, true);
        registry.setSystemAccount(forageToken, true);
        registry.setSystemAccount(guardianModule, true);
        registry.setSystemAccount(riskusd, true);
        registry.setSystemAccount(riskusdVault, true);
        registry.setSystemAccount(vaultRegistry, true);
        registry.setSystemAccount(atRiskusd, true);
        registry.setSystemAccount(stakingQueue, true);
        registry.setSystemAccount(usdcTreasury, true);
        registry.setSystemAccount(forageGovernor, true);
        registry.setSystemAccount(hlTradingBridge, true);
        registry.setSystemAccount(implRiskusdVaultModule, true);
        registry.setSystemAccount(implStakingQueueModule, true);
    }

    function _setAdopterAllowlists() private {
        Blocklist(blocklist).setAllowlist(allowlist);
        CustodianRegistry(custodianRegistry).setAllowlist(allowlist);
        DelegatingVestingWallet(vestingWallet).setAllowlist(allowlist);
        FORAGETreasury(forageTreasury).setAllowlist(allowlist);
        ForageToken(forageToken).setAllowlist(allowlist);
        RISKUSD(riskusd).setAllowlist(allowlist);
        RISKUSDVault(riskusdVault).setAllowlist(allowlist);
        VaultRegistry(vaultRegistry).setAllowlist(allowlist);
        atRISKUSD(atRiskusd).setAllowlist(allowlist);
        StakingQueue(stakingQueue).setAllowlist(allowlist);
        USDCTreasury(usdcTreasury).setAllowlist(allowlist);
        HLTradingBridge(hlTradingBridge).setAllowlist(allowlist);
        _timelockCall(guardianModule, abi.encodeCall(GuardianModule.setAllowlist, (allowlist)));
        _timelockCall(forageGovernor, abi.encodeCall(ForageGovernor.setAllowlist, (allowlist)));
    }

    function _timelockCall(address target, bytes memory data) private {
        TimelockController controller = TimelockController(payable(timelock));
        bytes32 salt = keccak256(abi.encode("AllowlistGateInvariants", target, data));
        controller.schedule(target, 0, data, bytes32(0), salt, 0);
        controller.execute(target, 0, data, bytes32(0), salt);
    }

    function _buildTargetsAndActors() private {
        targets[0] = allowlist;
        targets[1] = riskusdVault;
        targets[2] = riskusd;
        targets[3] = atRiskusd;
        targets[4] = stakingQueue;
        targets[5] = forageToken;
        targets[6] = forageTreasury;
        targets[7] = forageGovernor;
        targets[8] = usdcTreasury;
        targets[9] = guardianModule;
        targets[10] = blocklist;
        targets[11] = custodianRegistry;
        targets[12] = vaultRegistry;
        targets[13] = hlTradingBridge;
        targets[14] = vestingWallet;

        actors[0] = SENDER_0;
        actors[1] = SENDER_1;
        actors[2] = SENDER_2;
        actors[3] = address(this);
        actors[4] = timelock;
        for (uint256 i; i < 14; ++i) {
            actors[5 + i] = targets[1 + i];
        }
    }

    function _senderAt(uint8 callerIdx) private pure returns (address) {
        uint8 index = callerIdx % 3;
        if (index == 0) return SENDER_0;
        if (index == 1) return SENDER_1;
        return SENDER_2;
    }

    /// @dev The compile test's negative controls call the two gated contracts directly.
    function vaultAddress() external view returns (address) {
        return riskusdVault;
    }

    function queueAddress() external view returns (address) {
        return stakingQueue;
    }

    function _prank(address account) private {
        prankedCaller = account;
        (bool ok,) = HEVM.call(abi.encodeWithSignature("prank(address)", account));
        require(ok, "prank failed");
    }

    function _load(address account, uint256 slot) private view returns (bytes32 value) {
        address target = HEVM;
        bytes32 key = bytes32(slot);
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, shl(224, 0x667f9d70))
            mstore(add(ptr, 0x04), account)
            mstore(add(ptr, 0x24), key)
            if iszero(staticcall(gas(), target, ptr, 0x44, ptr, 0x20)) { revert(0, 0) }
            if iszero(eq(returndatasize(), 0x20)) { revert(0, 0) }
            value := mload(ptr)
        }
    }

    function _mapKey(uint256 slot, uint8 packed, uint256 actorIdx, bytes32 actorKey)
        private
        pure
        returns (bytes32 key)
    {
        bytes32 first = (packed & 0x0f) == 3 ? bytes32(actorIdx) : actorKey;
        uint8 second = packed >> 4;
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, first)
            mstore(add(ptr, 0x20), slot)
            key := keccak256(ptr, 0x40)
            mstore(0x40, add(ptr, 0x40))
            if second {
                let innerKey := sub(second, 1)
                mstore(ptr, first)
                if eq(innerKey, 3) { mstore(ptr, actorIdx) }
                mstore(add(ptr, 0x20), key)
                key := keccak256(ptr, 0x40)
            }
        }
    }

    function _erc20StorageLocation() private pure returns (uint256) {
        return
            uint256(
                keccak256(abi.encode(uint256(keccak256("openzeppelin.storage.ERC20")) - 1)) & ~bytes32(uint256(0xff))
            );
    }

    /// @dev Every mapping entry is read at the keys derived from the fixed actor set's caller-side
    ///      members: the three unverified senders, address(this) and the timelock. The fourteen
    ///      adopters are monitored targets, never callers after construction, so their derived keys
    ///      cannot receive a word written by a wrapped call.
    function _snapshot() private view returns (bytes32[] memory words) {
        words = new bytes32[](TOTAL_WORD_COUNT);
        uint8[PLAIN_COUNT] memory plainTargets = _plainTargets();
        uint8[PLAIN_COUNT] memory plainSlots = _plainSlots();
        for (uint256 i; i < PLAIN_COUNT; ++i) {
            words[i] = _load(targets[plainTargets[i]], plainSlots[i]);
        }
        uint8[MAP_COUNT] memory mapTargets = _mapTargets();
        uint8[MAP_COUNT] memory mapSlots = _mapSlots();
        uint8[MAP_COUNT] memory mapKeyTypes = _mapKeyTypes();
        bytes32[MAPPING_KEY_COUNT] memory actorKeys;
        for (uint256 a; a < MAPPING_KEY_COUNT; ++a) {
            actorKeys[a] = bytes32(uint256(uint160(actors[a])));
        }
        uint256 k = PLAIN_COUNT;
        for (uint256 i; i < MAP_COUNT; ++i) {
            address target = targets[mapTargets[i]];
            uint256 slot = mapSlots[i];
            uint8 packed = mapKeyTypes[i];
            for (uint256 a; a < MAPPING_KEY_COUNT; ++a) {
                words[k] = _load(target, uint256(_mapKey(slot, packed, a, actorKeys[a])));
                ++k;
            }
        }
        // The ERC20 namespaced balance and allowance mappings sit at base slot and base slot + 1
        // and are excluded; totalSupply (base slot + 2) stays monitored for the three tokens.
        uint256 erc20Slot = _erc20StorageLocation();
        words[k] = _load(riskusd, erc20Slot + 2);
        words[k + 1] = _load(atRiskusd, erc20Slot + 2);
        words[k + 2] = _load(forageToken, erc20Slot + 2);
        k += 3;
        require(k == TOTAL_WORD_COUNT, "snapshot incomplete");
    }

    /// @dev The property judges only unverified callers. Under Echidna the harness is deployed at
    ///      the first `echidna.yaml` sender, which the constructor registers as a system account,
    ///      so a call pranked with that address is outside the property; its snapshot is skipped.
    function _compare(bytes32[] memory before) private {
        if (Allowlist(allowlist).isAllowed(prankedCaller)) return;
        bytes32[] memory afterWords = _snapshot();
        for (uint256 i; i < before.length; ++i) {
            if (before[i] != afterWords[i]) {
                gateViolation = true;
                violationWord = uint32(i);
                violationBefore = before[i];
                violationAfter = afterWords[i];
                return;
            }
        }
    }

    function echidna_gate_noUnverifiedStateChange() public view returns (bool) {
        return !gateViolation;
    }

    function forge_breakGate() public onlyForgeBreakCaller {
        gateViolation = true;
        violationWord = type(uint32).max;
    }

    function gate_RISKUSDVault_deposit(uint8 callerIdx, uint256 usdcAmount) public {
        bytes32[] memory before = _snapshot();
        _prank(_senderAt(callerIdx));
        try RISKUSDVault(riskusdVault).deposit(usdcAmount) {} catch {}
        _compare(before);
    }

    function gate_RISKUSD_mint(uint8 callerIdx, address to, uint256 amount) public {
        bytes32[] memory before = _snapshot();
        _prank(_senderAt(callerIdx));
        try RISKUSD(riskusd).mint(to, amount) {} catch {}
        _compare(before);
    }

    function gate_atRISKUSD_deposit(uint8 callerIdx, uint256 assets, address receiver) public {
        bytes32[] memory before = _snapshot();
        _prank(_senderAt(callerIdx));
        try atRISKUSD(atRiskusd).deposit(assets, receiver) {} catch {}
        _compare(before);
    }

    function gate_StakingQueue_joinQueue(uint8 callerIdx, uint256 riskusdAmount, uint8 tier) public {
        bytes32[] memory before = _snapshot();
        _prank(_senderAt(callerIdx));
        try StakingQueue(stakingQueue).joinQueue(riskusdAmount, tier) {} catch {}
        _compare(before);
    }

    function gate_ForageToken_delegate(uint8 callerIdx, address delegatee) public {
        bytes32[] memory before = _snapshot();
        _prank(_senderAt(callerIdx));
        try ForageToken(forageToken).delegate(delegatee) {} catch {}
        _compare(before);
    }

    function gate_FORAGETreasury_publishAgentRoot(
        uint8 callerIdx,
        uint256 roundId,
        bytes32 root,
        uint256 totalAmount,
        uint64 deadline
    ) public {
        bytes32[] memory before = _snapshot();
        _prank(_senderAt(callerIdx));
        try FORAGETreasury(forageTreasury).publishAgentRoot(roundId, root, totalAmount, deadline) {} catch {}
        _compare(before);
    }

    function gate_ForageGovernor_cancel(uint8 callerIdx) public {
        address[] memory noTargets = new address[](0);
        uint256[] memory noValues = new uint256[](0);
        bytes[] memory noCalldatas = new bytes[](0);
        bytes32[] memory before = _snapshot();
        _prank(_senderAt(callerIdx));
        try ForageGovernor(payable(forageGovernor)).cancel(noTargets, noValues, noCalldatas, bytes32(0)) {} catch {}
        _compare(before);
    }

    function gate_USDCTreasury_recognizePnL(uint8 callerIdx, uint256 vaultId, int256 amount) public {
        bytes32[] memory before = _snapshot();
        _prank(_senderAt(callerIdx));
        try USDCTreasury(usdcTreasury).recognizePnL(vaultId, amount) {} catch {}
        _compare(before);
    }

    function gate_GuardianModule_guardianPause(uint8 callerIdx, address target) public {
        bytes32[] memory before = _snapshot();
        _prank(_senderAt(callerIdx));
        try GuardianModule(guardianModule).guardianPause(target) {} catch {}
        _compare(before);
    }

    function gate_Blocklist_blockAddress(uint8 callerIdx, address account) public {
        bytes32[] memory before = _snapshot();
        _prank(_senderAt(callerIdx));
        try Blocklist(blocklist).blockAddress(account) {} catch {}
        _compare(before);
    }

    function gate_CustodianRegistry_finalizeCustodianConfig(uint8 callerIdx, bytes32 id) public {
        bytes32[] memory before = _snapshot();
        _prank(_senderAt(callerIdx));
        try CustodianRegistry(custodianRegistry).finalizeCustodianConfig(id) {} catch {}
        _compare(before);
    }

    function gate_VaultRegistry_pauseVault(uint8 callerIdx, uint256 vaultId) public {
        bytes32[] memory before = _snapshot();
        _prank(_senderAt(callerIdx));
        try VaultRegistry(vaultRegistry).pauseVault(vaultId) {} catch {}
        _compare(before);
    }

    function gate_HLTradingBridge_deployToHyperLiquid(uint8 callerIdx, uint256 usdcE6) public {
        bytes32[] memory before = _snapshot();
        _prank(_senderAt(callerIdx));
        try HLTradingBridge(hlTradingBridge).deployToHyperLiquid(usdcE6) {} catch {}
        _compare(before);
    }

    function gate_DelegatingVestingWallet_release(uint8 callerIdx) public {
        bytes32[] memory before = _snapshot();
        _prank(_senderAt(callerIdx));
        try DelegatingVestingWallet(vestingWallet).release() {} catch {}
        _compare(before);
    }

    function gate_RISKUSD_transfer(uint8 callerIdx, address to, uint256 amount) public {
        bytes32[] memory before = _snapshot();
        _prank(_senderAt(callerIdx));
        try RISKUSD(riskusd).transfer(to, amount) {} catch {}
        _compare(before);
    }

    function gate_RISKUSD_approve(uint8 callerIdx, address spender, uint256 amount) public {
        bytes32[] memory before = _snapshot();
        _prank(_senderAt(callerIdx));
        try RISKUSD(riskusd).approve(spender, amount) {} catch {}
        _compare(before);
    }

    function gate_RISKUSD_transferFrom(uint8 callerIdx, address from, address to, uint256 amount) public {
        bytes32[] memory before = _snapshot();
        _prank(_senderAt(callerIdx));
        try RISKUSD(riskusd).transferFrom(from, to, amount) {} catch {}
        _compare(before);
    }

    function gate_atRISKUSD_transfer(uint8 callerIdx, address to, uint256 amount) public {
        bytes32[] memory before = _snapshot();
        _prank(_senderAt(callerIdx));
        try atRISKUSD(atRiskusd).transfer(to, amount) {} catch {}
        _compare(before);
    }

    function gate_atRISKUSD_approve(uint8 callerIdx, address spender, uint256 amount) public {
        bytes32[] memory before = _snapshot();
        _prank(_senderAt(callerIdx));
        try atRISKUSD(atRiskusd).approve(spender, amount) {} catch {}
        _compare(before);
    }

    function gate_atRISKUSD_transferFrom(uint8 callerIdx, address from, address to, uint256 amount) public {
        bytes32[] memory before = _snapshot();
        _prank(_senderAt(callerIdx));
        try atRISKUSD(atRiskusd).transferFrom(from, to, amount) {} catch {}
        _compare(before);
    }

    function gate_ForageToken_transfer(uint8 callerIdx, address to, uint256 amount) public {
        bytes32[] memory before = _snapshot();
        _prank(_senderAt(callerIdx));
        try ForageToken(forageToken).transfer(to, amount) {} catch {}
        _compare(before);
    }

    function gate_ForageToken_approve(uint8 callerIdx, address spender, uint256 amount) public {
        bytes32[] memory before = _snapshot();
        _prank(_senderAt(callerIdx));
        try ForageToken(forageToken).approve(spender, amount) {} catch {}
        _compare(before);
    }

    function gate_ForageToken_transferFrom(uint8 callerIdx, address from, address to, uint256 amount) public {
        bytes32[] memory before = _snapshot();
        _prank(_senderAt(callerIdx));
        try ForageToken(forageToken).transferFrom(from, to, amount) {} catch {}
        _compare(before);
    }

    // --- Moved-selector wrappers: the delegatecall cluster behind the two contracts' forwarders ---

    function gate_RISKUSDVault_pause(uint8 callerIdx) public {
        bytes32[] memory before = _snapshot();
        _prank(_senderAt(callerIdx));
        try RISKUSDVault(riskusdVault).pause() {} catch {}
        _compare(before);
    }

    function gate_RISKUSDVault_unpause(uint8 callerIdx) public {
        bytes32[] memory before = _snapshot();
        _prank(_senderAt(callerIdx));
        try RISKUSDVault(riskusdVault).unpause() {} catch {}
        _compare(before);
    }

    function gate_RISKUSDVault_setBlocklist(uint8 callerIdx, address newBlocklist) public {
        bytes32[] memory before = _snapshot();
        _prank(_senderAt(callerIdx));
        try RISKUSDVault(riskusdVault).setBlocklist(newBlocklist) {} catch {}
        _compare(before);
    }

    function gate_RISKUSDVault_setDailyMintCapBps(uint8 callerIdx, uint256 bps) public {
        bytes32[] memory before = _snapshot();
        _prank(_senderAt(callerIdx));
        try RISKUSDVault(riskusdVault).setDailyMintCapBps(bps) {} catch {}
        _compare(before);
    }

    function gate_RISKUSDVault_setDailyRedemptionCapBps(uint8 callerIdx, uint256 bps) public {
        bytes32[] memory before = _snapshot();
        _prank(_senderAt(callerIdx));
        try RISKUSDVault(riskusdVault).setDailyRedemptionCapBps(bps) {} catch {}
        _compare(before);
    }

    function gate_RISKUSDVault_burnForLoss(uint8 callerIdx, uint256 vaultId, uint256 riskusdAmount) public {
        bytes32[] memory before = _snapshot();
        _prank(_senderAt(callerIdx));
        try RISKUSDVault(riskusdVault).burnForLoss(vaultId, riskusdAmount) {} catch {}
        _compare(before);
    }

    function gate_RISKUSDVault_replenish(uint8 callerIdx, uint256 usdcAmount) public {
        bytes32[] memory before = _snapshot();
        _prank(_senderAt(callerIdx));
        try RISKUSDVault(riskusdVault).replenish(usdcAmount) {} catch {}
        _compare(before);
    }

    function gate_RISKUSDVault_recordCustodianNAV(uint8 callerIdx, uint256 vaultId, uint256 nav, uint256 lossNonce)
        public
    {
        bytes32[] memory before = _snapshot();
        _prank(_senderAt(callerIdx));
        try RISKUSDVault(riskusdVault).recordCustodianNAV(vaultId, nav, lossNonce) {} catch {}
        _compare(before);
    }

    function gate_StakingQueue_joinQueueWithBounds(
        uint8 callerIdx,
        uint256 riskusdAmount,
        uint8 tier,
        uint256 minimumShares,
        uint256 deadline
    ) public {
        bytes32[] memory before = _snapshot();
        _prank(_senderAt(callerIdx));
        try StakingQueue(stakingQueue).joinQueueWithBounds(riskusdAmount, tier, minimumShares, deadline) {} catch {}
        _compare(before);
    }

    function gate_StakingQueue_cancelQueue(uint8 callerIdx, uint256 queueId) public {
        bytes32[] memory before = _snapshot();
        _prank(_senderAt(callerIdx));
        try StakingQueue(stakingQueue).cancelQueue(queueId) {} catch {}
        _compare(before);
    }

    function gate_StakingQueue_processQueue(uint8 callerIdx, uint8 tier, uint256 maxEntries) public {
        bytes32[] memory before = _snapshot();
        _prank(_senderAt(callerIdx));
        try StakingQueue(stakingQueue).processQueue(tier, maxEntries) {} catch {}
        _compare(before);
    }

    function gate_StakingQueue_processExpiredLockups(uint8 callerIdx, uint8 tier) public {
        address[] memory depositors = new address[](1);
        depositors[0] = _senderAt(callerIdx);
        bytes32[] memory before = _snapshot();
        _prank(_senderAt(callerIdx));
        try StakingQueue(stakingQueue).processExpiredLockups(depositors, tier) {} catch {}
        _compare(before);
    }
}
