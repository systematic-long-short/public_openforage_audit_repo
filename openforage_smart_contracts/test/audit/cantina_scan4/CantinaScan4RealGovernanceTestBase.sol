// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/governance/TimelockController.sol";

import {ForageGovernor} from "../../../src/ForageGovernor.sol";
import {ForageToken} from "../../../src/ForageToken.sol";
import {GuardianModule} from "../../../src/GuardianModule.sol";

abstract contract CantinaScan4RealGovernanceTestBase is Test {
    ForageGovernor public governor;
    ForageToken public token;
    GuardianModule public guardianModuleContract;
    TimelockController public timelock;

    address public deployer;
    address public proposer;
    address public voter1;
    address public voter2;
    address public voter3;
    address public guardian1;
    address public guardian2;
    address public guardian3;
    address public guardian4;
    address public attacker;

    uint256 public constant TOTAL_SUPPLY = 100_000_000 * 1e18;
    uint48 public constant DEFAULT_VOTING_DELAY = 0;
    uint32 public constant DEFAULT_VOTING_PERIOD = 3_600;
    uint256 public constant DEFAULT_QUORUM_BPS = 400;
    uint256 public constant DEFAULT_THRESHOLD_BPS = 100;
    uint256 public constant DEFAULT_MAX_ACTIVE = 10;
    uint256 public constant TIMELOCK_MIN_DELAY = 0;
    uint256 public constant PRODUCTION_TIMELOCK_DELAY = 691_200;

    function setUp() public virtual {
        vm.warp(100);

        deployer = makeAddr("deployer");
        proposer = makeAddr("proposer");
        voter1 = makeAddr("voter1");
        voter2 = makeAddr("voter2");
        voter3 = makeAddr("voter3");
        guardian1 = makeAddr("guardian1");
        guardian2 = makeAddr("guardian2");
        guardian3 = makeAddr("guardian3");
        guardian4 = makeAddr("guardian4");
        attacker = makeAddr("attacker");

        _deployRealForageToken();
        _delegateVotingPower();
        _deployGovernorAndGuardianModule();
    }

    function _deployRealForageToken() internal {
        ForageToken tokenImpl = new ForageToken();
        bytes memory tokenInit = abi.encodeCall(ForageToken.initialize, (proposer, voter1, deployer));
        token = ForageToken(address(new ERC1967Proxy(address(tokenImpl), tokenInit)));
    }

    function _delegateVotingPower() internal {
        vm.prank(proposer);
        token.delegate(proposer);
        vm.prank(voter1);
        token.delegate(voter1);
        vm.prank(voter2);
        token.delegate(voter2);
        vm.prank(voter3);
        token.delegate(voter3);

        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 1);
    }

    function _deployGovernorAndGuardianModule() internal {
        vm.startPrank(deployer);

        address[] memory proposers = new address[](1);
        proposers[0] = deployer;
        address[] memory executors = new address[](1);
        executors[0] = address(0);
        timelock = new TimelockController(TIMELOCK_MIN_DELAY, proposers, executors, address(0));

        ForageGovernor governorImpl = new ForageGovernor();
        bytes memory governorInit = abi.encodeCall(
            ForageGovernor.initialize,
            (
                address(token),
                address(timelock),
                DEFAULT_VOTING_DELAY,
                DEFAULT_VOTING_PERIOD,
                DEFAULT_THRESHOLD_BPS,
                DEFAULT_QUORUM_BPS,
                address(0)
            )
        );
        governor = ForageGovernor(payable(address(new ERC1967Proxy(address(governorImpl), governorInit))));

        GuardianModule guardianModuleImpl = new GuardianModule();
        address[] memory guardians = new address[](4);
        uint256[] memory permissions = new uint256[](4);
        guardians[0] = guardian1;
        permissions[0] = 14;
        guardians[1] = guardian2;
        permissions[1] = 1;
        guardians[2] = guardian3;
        permissions[2] = 2;
        guardians[3] = guardian4;
        permissions[3] = 4;

        bytes memory guardianInit =
            abi.encodeCall(GuardianModule.initialize, (address(governor), address(timelock), guardians, permissions));
        guardianModuleContract = GuardianModule(address(new ERC1967Proxy(address(guardianModuleImpl), guardianInit)));

        vm.stopPrank();

        _grantGovernorTimelockRoles();
        _setGuardianModule();
    }

    function _grantGovernorTimelockRoles() internal {
        bytes32 proposerRole = keccak256("PROPOSER_ROLE");
        bytes32 cancellerRole = keccak256("CANCELLER_ROLE");

        _scheduleAndExecuteTimelockSelfCall(
            abi.encodeCall(timelock.grantRole, (proposerRole, address(governor))), keccak256("grant_governor_proposer")
        );
        _scheduleAndExecuteTimelockSelfCall(
            abi.encodeCall(timelock.grantRole, (cancellerRole, address(governor))),
            keccak256("grant_governor_canceller")
        );
        _scheduleAndExecuteTimelockSelfCall(
            abi.encodeCall(timelock.revokeRole, (proposerRole, deployer)), keccak256("revoke_deployer_proposer")
        );
    }

    function _setGuardianModule() internal {
        bytes memory setModuleData = abi.encodeCall(ForageGovernor.setGuardianModule, (address(guardianModuleContract)));
        bytes32 setModuleSalt = keccak256(setModuleData);

        vm.prank(address(governor));
        timelock.schedule(address(governor), 0, setModuleData, bytes32(0), setModuleSalt, TIMELOCK_MIN_DELAY);
        vm.warp(block.timestamp + TIMELOCK_MIN_DELAY + 1);
        timelock.execute(address(governor), 0, setModuleData, bytes32(0), setModuleSalt);
    }

    function _scheduleAndExecuteTimelockSelfCall(bytes memory data, bytes32 salt) internal {
        vm.prank(deployer);
        timelock.schedule(address(timelock), 0, data, bytes32(0), salt, TIMELOCK_MIN_DELAY);
        vm.warp(block.timestamp + TIMELOCK_MIN_DELAY + 1);
        timelock.execute(address(timelock), 0, data, bytes32(0), salt);
    }

    function _createProposalWithParams(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description
    ) internal returns (uint256) {
        vm.prank(proposer);
        return governor.propose(targets, values, calldatas, description);
    }

    function _passProposal(uint256 proposalId) internal {
        vm.warp(block.timestamp + governor.votingDelay() + 1);
        vm.roll(block.number + 1);

        vm.prank(voter1);
        governor.castVote(proposalId, 1);

        vm.warp(block.timestamp + governor.votingPeriod() + 1);
        vm.roll(block.number + 1);
    }
}
