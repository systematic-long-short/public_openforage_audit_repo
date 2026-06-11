// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "forge-std/Test.sol";
import "../../../src/DelegatingVestingWallet.sol";
import "../../mocks/MockForageTokenSimple.sol";

interface IV12VestingExpected {
    error ForageTokenNotPrecommitted();
    error UnexpectedForageToken(address expected, address provided);
    error InvalidBlocklist(address blocklist);

    function precommitForageToken(address forageToken_) external;
    function replaceBrokenBlocklist(address blocklist_) external;
}

contract V12VotingCompatibleFakeToken is ERC20 {
    mapping(address => address) private _delegates;

    constructor() ERC20("Fake Forage", "fFORAGE") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function delegate(address delegatee_) external {
        _delegates[msg.sender] = delegatee_;
    }

    function delegates(address account) external view returns (address) {
        return _delegates[account];
    }
}

contract V12MalformedBlocklist {
    fallback() external {}
}

contract V12MutableBlocklist {
    error BrokenBlocklist();

    bool private _broken;
    mapping(address => bool) private _blocked;

    function setBroken(bool broken_) external {
        _broken = broken_;
    }

    function setBlocked(address account, bool blocked_) external {
        _blocked[account] = blocked_;
    }

    function isBlocked(address account) external view returns (bool) {
        if (_broken) revert BrokenBlocklist();
        return _blocked[account];
    }
}

contract V12SelectiveRevertingBlocklist {
    error SelectiveBlocklistBreak(address account);

    mapping(address => bool) private _reverting;

    function setReverting(address account, bool reverting_) external {
        _reverting[account] = reverting_;
    }

    function isBlocked(address account) external view returns (bool) {
        if (_reverting[account]) revert SelectiveBlocklistBreak(account);
        return false;
    }
}

contract V12_74875_74876_VestingBindingTest is Test {
    uint256 private constant TEAM_ALLOCATION = 20_000_000e18;
    uint256 private constant FAKE_ALLOCATION = 1_000e18;
    uint64 private constant TEAM_DURATION = 126_230_400;
    uint64 private constant TEAM_CLIFF = 31_557_600;

    address private beneficiary;
    address private tokenSetter;
    uint64 private startTimestamp;

    DelegatingVestingWallet private wallet;
    MockForageTokenSimple private forage;

    function setUp() public {
        beneficiary = makeAddr("beneficiary");
        tokenSetter = makeAddr("tokenSetter");
        startTimestamp = uint64(block.timestamp);
        wallet = new DelegatingVestingWallet(beneficiary, startTimestamp, TEAM_DURATION, TEAM_CLIFF, tokenSetter);
        forage = new MockForageTokenSimple();
    }

    function test_74875_unprecommittedVotesTokenCannotBindOrRescueCanonicalForage() public {
        V12VotingCompatibleFakeToken fakeToken = new V12VotingCompatibleFakeToken();
        forage.mint(address(wallet), TEAM_ALLOCATION);
        fakeToken.mint(address(wallet), FAKE_ALLOCATION);

        vm.expectRevert(IV12VestingExpected.ForageTokenNotPrecommitted.selector);
        vm.prank(tokenSetter);
        wallet.setForageToken(address(fakeToken));

        assertEq(wallet.forageToken(), address(0), "fake token must not bind as FORAGE");
        assertEq(wallet.tokenSetter(), tokenSetter, "token setter remains available for real FORAGE");
        assertEq(forage.balanceOf(address(wallet)), TEAM_ALLOCATION, "real FORAGE remains in vesting wallet");
        assertEq(forage.balanceOf(beneficiary), 0, "beneficiary cannot rescue locked real FORAGE");
    }

    function test_74875_precommittedForageRejectsDifferentVotingCompatibleToken() public {
        V12VotingCompatibleFakeToken fakeToken = new V12VotingCompatibleFakeToken();
        forage.mint(address(wallet), TEAM_ALLOCATION);
        fakeToken.mint(address(wallet), FAKE_ALLOCATION);

        vm.prank(tokenSetter);
        IV12VestingExpected(address(wallet)).precommitForageToken(address(forage));

        vm.expectRevert(
            abi.encodeWithSelector(
                IV12VestingExpected.UnexpectedForageToken.selector, address(forage), address(fakeToken)
            )
        );
        vm.prank(tokenSetter);
        wallet.setForageToken(address(fakeToken));

        assertEq(wallet.forageToken(), address(0), "mismatched token must not bind");
        assertEq(wallet.tokenSetter(), tokenSetter, "token setter remains usable after rejected mismatch");
        assertEq(forage.balanceOf(address(wallet)), TEAM_ALLOCATION, "real FORAGE remains locked");

        vm.prank(tokenSetter);
        wallet.setForageToken(address(forage));

        vm.expectRevert(DelegatingVestingWallet.CannotRescueForageToken.selector);
        vm.prank(beneficiary);
        wallet.rescueToken(address(forage), 1);
    }

    function test_74876_malformedBlocklistRejectedAtSetTimeAndHealthyReleaseWorks() public {
        V12MalformedBlocklist malformed = new V12MalformedBlocklist();

        vm.expectRevert(abi.encodeWithSelector(IV12VestingExpected.InvalidBlocklist.selector, address(malformed)));
        vm.prank(tokenSetter);
        wallet.setBlocklist(address(malformed));

        assertEq(wallet.blocklist(), address(0), "malformed blocklist must not be stored");

        V12MutableBlocklist healthy = new V12MutableBlocklist();
        vm.prank(tokenSetter);
        wallet.setBlocklist(address(healthy));

        _precommitFundAndSetForage();
        vm.warp(startTimestamp + TEAM_CLIFF);
        uint256 releasable = wallet.releasable();

        vm.prank(beneficiary);
        wallet.release();

        assertEq(wallet.released(), releasable, "healthy blocklist preserves vesting accounting");
        assertEq(forage.balanceOf(beneficiary), releasable, "healthy blocklist permits release");
    }

    function test_74876_blocklistHealthChecksBeneficiaryAtSetTime() public {
        V12SelectiveRevertingBlocklist selective = new V12SelectiveRevertingBlocklist();
        selective.setReverting(beneficiary, true);

        vm.expectRevert(abi.encodeWithSelector(IV12VestingExpected.InvalidBlocklist.selector, address(selective)));
        vm.prank(tokenSetter);
        wallet.setBlocklist(address(selective));

        assertEq(wallet.blocklist(), address(0), "beneficiary-broken blocklist must not be stored");
    }

    function test_74876_blocklistHealthChecksWalletAtSetTime() public {
        V12SelectiveRevertingBlocklist selective = new V12SelectiveRevertingBlocklist();
        selective.setReverting(address(wallet), true);

        vm.expectRevert(abi.encodeWithSelector(IV12VestingExpected.InvalidBlocklist.selector, address(selective)));
        vm.prank(tokenSetter);
        wallet.setBlocklist(address(selective));

        assertEq(wallet.blocklist(), address(0), "wallet-broken blocklist must not be stored");
    }

    function test_74876_brokenStoredBlocklistCanBeRecoveredBeforeRelease() public {
        V12MutableBlocklist broken = new V12MutableBlocklist();
        V12MutableBlocklist replacement = new V12MutableBlocklist();

        vm.prank(tokenSetter);
        wallet.setBlocklist(address(broken));

        _precommitFundAndSetForage();
        broken.setBroken(true);

        vm.warp(startTimestamp + TEAM_CLIFF);
        uint256 releasable = wallet.releasable();

        vm.expectRevert(V12MutableBlocklist.BrokenBlocklist.selector);
        vm.prank(beneficiary);
        wallet.release();

        vm.prank(tokenSetter);
        IV12VestingExpected(address(wallet)).replaceBrokenBlocklist(address(replacement));

        assertEq(wallet.blocklist(), address(replacement), "broken blocklist is replaceable");

        vm.prank(beneficiary);
        wallet.release();

        assertEq(wallet.released(), releasable, "recovery preserves vesting accounting");
        assertEq(forage.balanceOf(beneficiary), releasable, "release works after blocklist recovery");
    }

    function test_74876_recoveryDetectsBlocklistBrokenForReleaseAccounts() public {
        V12SelectiveRevertingBlocklist broken = new V12SelectiveRevertingBlocklist();
        V12MutableBlocklist replacement = new V12MutableBlocklist();

        vm.prank(tokenSetter);
        wallet.setBlocklist(address(broken));

        _precommitFundAndSetForage();
        broken.setReverting(beneficiary, true);

        vm.warp(startTimestamp + TEAM_CLIFF);
        uint256 releasable = wallet.releasable();

        vm.expectRevert(
            abi.encodeWithSelector(V12SelectiveRevertingBlocklist.SelectiveBlocklistBreak.selector, beneficiary)
        );
        vm.prank(beneficiary);
        wallet.release();

        vm.prank(tokenSetter);
        IV12VestingExpected(address(wallet)).replaceBrokenBlocklist(address(replacement));

        assertEq(wallet.blocklist(), address(replacement), "release-broken blocklist is replaceable");

        vm.prank(beneficiary);
        wallet.release();

        assertEq(wallet.released(), releasable, "recovery preserves release accounting");
        assertEq(forage.balanceOf(beneficiary), releasable, "release works after release-path recovery");
    }

    function test_74876_recoveryDoesNotReplaceHealthyBlocklist() public {
        V12MutableBlocklist healthy = new V12MutableBlocklist();
        V12MutableBlocklist replacement = new V12MutableBlocklist();

        vm.prank(tokenSetter);
        wallet.setBlocklist(address(healthy));

        vm.expectRevert(DelegatingVestingWallet.BlocklistAlreadySet.selector);
        vm.prank(tokenSetter);
        IV12VestingExpected(address(wallet)).replaceBrokenBlocklist(address(replacement));

        assertEq(wallet.blocklist(), address(healthy), "healthy blocklist remains one-shot wired");
    }

    function _precommitFundAndSetForage() private {
        forage.mint(address(wallet), TEAM_ALLOCATION);

        vm.prank(tokenSetter);
        IV12VestingExpected(address(wallet)).precommitForageToken(address(forage));

        vm.prank(tokenSetter);
        wallet.setForageToken(address(forage));
    }
}
