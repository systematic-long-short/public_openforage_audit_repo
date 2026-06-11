// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/RISKUSD.sol";

// ============================================================
// TC-09: Invariant Tests
// Handler contract for Foundry invariant testing
// ============================================================

contract RISKUSDHandler is Test {
    RISKUSD public token;
    address public minterAddr;
    address[] public actors;

    // Ghost variables for behavioral invariant checking
    uint256 public unauthorizedMintAttempts;
    uint256 public unauthorizedMintSuccesses;
    uint256 public unauthorizedBurnAttempts;
    uint256 public unauthorizedBurnSuccesses;

    constructor(RISKUSD _token, address _minter, address[] memory _actors) {
        token = _token;
        minterAddr = _minter;
        actors = _actors;
    }

    function mint(uint256 actorSeed, uint256 amount) external {
        address to = actors[actorSeed % actors.length];
        amount = bound(amount, 1, 1_000_000e6);

        vm.prank(minterAddr);
        token.mint(to, amount);
    }

    function burn(uint256 actorSeed, uint256 amount) external {
        address from = actors[actorSeed % actors.length];
        uint256 balance = token.balanceOf(from);
        if (balance == 0) return;

        amount = bound(amount, 1, balance);

        vm.prank(minterAddr);
        token.burn(from, amount);
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];
        uint256 balance = token.balanceOf(from);
        if (balance == 0) return;

        amount = bound(amount, 1, balance);

        vm.prank(from);
        token.transfer(to, amount);
    }

    /// @dev Attempt unauthorized mint from a random actor (NOT the minter)
    function attemptUnauthorizedMint(uint256 actorSeed, uint256 amount) external {
        address caller = actors[actorSeed % actors.length];
        amount = bound(amount, 1, 1_000_000e6);

        unauthorizedMintAttempts++;

        vm.prank(caller);
        (bool success,) = address(token).call(abi.encodeCall(token.mint, (caller, amount)));

        if (success) {
            unauthorizedMintSuccesses++;
        }
    }

    /// @dev Attempt unauthorized burn from a random actor (NOT the minter)
    function attemptUnauthorizedBurn(uint256 actorSeed, uint256 amount) external {
        address caller = actors[actorSeed % actors.length];
        uint256 balance = token.balanceOf(caller);
        if (balance == 0) return;

        amount = bound(amount, 1, balance);

        unauthorizedBurnAttempts++;

        vm.prank(caller);
        (bool success,) = address(token).call(abi.encodeCall(token.burn, (caller, amount)));

        if (success) {
            unauthorizedBurnSuccesses++;
        }
    }

    function getActors() external view returns (address[] memory) {
        return actors;
    }
}

contract RISKUSD_TC09_Invariants is Test {
    RISKUSD public token;
    RISKUSDHandler public handler;

    address public owner;
    address public minterAddr;
    address[] public actors;

    function setUp() public {
        owner = makeAddr("owner");
        minterAddr = makeAddr("minter");

        RISKUSD impl = new RISKUSD();
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), abi.encodeCall(RISKUSD.initialize, (owner)));
        token = RISKUSD(address(proxy));

        // Setup minter (propose + delay + finalize)
        vm.startPrank(owner);
        token.setMinter(minterAddr);
        vm.warp(block.timestamp + 2 days + 1);
        token.finalizeMinter();
        vm.stopPrank();

        // Create actors — none of these are the minter
        actors.push(makeAddr("alice"));
        actors.push(makeAddr("bob"));
        actors.push(makeAddr("charlie"));

        // Mint initial tokens
        vm.prank(minterAddr);
        token.mint(actors[0], 10_000e6);

        vm.prank(minterAddr);
        token.mint(actors[1], 5_000e6);

        handler = new RISKUSDHandler(token, minterAddr, actors);
        targetContract(address(handler));
    }

    /// @dev R-06, R-28: Unauthorized mint attempts MUST always fail
    function invariant_onlyMinterCanMint() public view {
        // Every unauthorized mint attempt must have reverted
        assertEq(handler.unauthorizedMintSuccesses(), 0, "No unauthorized mint must ever succeed");
    }

    /// @dev R-11, R-28: Unauthorized burn attempts MUST always fail
    function invariant_onlyMinterCanBurn() public view {
        // Every unauthorized burn attempt must have reverted
        assertEq(handler.unauthorizedBurnSuccesses(), 0, "No unauthorized burn must ever succeed");
    }

    /// @dev R-10, R-16, R-32: Sum of all balances == totalSupply (exact conservation)
    function invariant_totalSupplyEqualsBalanceSum() public view {
        address[] memory actorList = handler.getActors();
        uint256 totalBalances;
        for (uint256 i = 0; i < actorList.length; i++) {
            totalBalances += token.balanceOf(actorList[i]);
        }
        // Handler only transfers between tracked actors
        assertEq(totalBalances, token.totalSupply(), "Sum of all balances must equal totalSupply");
    }

    /// @dev R-17, R-18, R-19: Minter address is never zero (once set)
    function invariant_minterAddressConsistency() public view {
        address currentMinter = token.minter();
        // setMinter rejects zero address (R-18), so once set, minter is always non-zero
        assertTrue(currentMinter != address(0), "Minter address must be non-zero once set");
    }
}
