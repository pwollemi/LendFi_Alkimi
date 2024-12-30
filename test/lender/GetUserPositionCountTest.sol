// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../BasicDeploy.sol";
import {console2} from "forge-std/console2.sol";
import {IPROTOCOL} from "../../contracts/interfaces/IProtocol.sol";
import {Lendefi} from "../../contracts/lender/Lendefi.sol";
import {WETHPriceConsumerV3} from "../../contracts/mock/WETHOracle.sol";
import {TokenMock} from "../../contracts/mock/TokenMock.sol";
import {RWAPriceConsumerV3} from "../../contracts/mock/RWAOracle.sol";

contract GetUserPositionsCountTest is BasicDeploy {
    WETHPriceConsumerV3 internal wethOracleInstance;
    TokenMock internal rwaToken;
    RWAPriceConsumerV3 internal rwaOracleInstance;

    function setUp() public {
        deployComplete();
        usdcInstance = new USDC();

        // Deploy tokens and oracles
        wethOracleInstance = new WETHPriceConsumerV3();
        wethOracleInstance.setPrice(2500e8); // $2500 per ETH

        // Deploy RWA token for isolation mode tests
        rwaToken = new TokenMock("RWA Token", "RWA");
        rwaOracleInstance = new RWAPriceConsumerV3();
        rwaOracleInstance.setPrice(1000e8); // $1000 per RWA token

        // TGE setup
        vm.prank(guardian);
        tokenInstance.initializeTGE(address(ecoInstance), address(treasuryInstance));

        // Deploy Lendefi
        bytes memory data = abi.encodeCall(
            Lendefi.initialize,
            (
                address(usdcInstance),
                address(tokenInstance),
                address(ecoInstance),
                address(treasuryInstance),
                address(timelockInstance),
                guardian
            )
        );

        address payable proxy = payable(Upgrades.deployUUPSProxy("Lendefi.sol", data));
        LendefiInstance = Lendefi(proxy);

        // Setup roles
        vm.prank(guardian);
        ecoInstance.grantRole(REWARDER_ROLE, address(LendefiInstance));

        _setupAssets();
        _setupLiquidity();
    }

    function _setupAssets() internal {
        vm.startPrank(address(timelockInstance));

        // Configure WETH as a cross collateral asset
        LendefiInstance.updateAssetConfig(
            address(wethInstance),
            address(wethOracleInstance),
            8,
            18,
            1,
            800, // 80% borrow threshold
            850, // 85% liquidation threshold
            1_000_000 ether,
            IPROTOCOL.CollateralTier.CROSS_A,
            0
        );

        // Configure RWA token as isolation-eligible
        LendefiInstance.updateAssetConfig(
            address(rwaToken),
            address(rwaOracleInstance),
            8,
            18,
            1,
            650, // 65% borrow threshold
            750, // 75% liquidation threshold
            1_000_000 ether,
            IPROTOCOL.CollateralTier.ISOLATED,
            100_000e6 // $100k max borrow cap
        );
        vm.stopPrank();
    }

    // Updated helper to create positions with the right asset for isolation mode
    function _createPosition(address user, bool isIsolated) internal returns (uint256) {
        vm.startPrank(user);
        // Use RWA token for isolated positions, WETH for non-isolated
        address asset = isIsolated ? address(rwaToken) : address(wethInstance);
        LendefiInstance.createPosition(asset, isIsolated);
        uint256 positionId = LendefiInstance.getUserPositionsCount(user) - 1;
        vm.stopPrank();
        return positionId;
    }

    function _setupLiquidity() internal {
        // Provide liquidity to the protocol for tests that need it
        usdcInstance.mint(alice, 1_000_000e6);
        vm.startPrank(alice);
        usdcInstance.approve(address(LendefiInstance), 1_000_000e6);
        LendefiInstance.supplyLiquidity(1_000_000e6);
        vm.stopPrank();
    }

    // Test 1: Initial positions count should be zero
    function test_InitialPositionsCount() public {
        uint256 count = LendefiInstance.getUserPositionsCount(bob);
        assertEq(count, 0, "Initial positions count should be zero");
    }

    // Test 2: Count increases when creating positions
    function test_CountIncreasesWithNewPositions() public {
        // Create first position
        _createPosition(bob, false);
        assertEq(LendefiInstance.getUserPositionsCount(bob), 1, "Count should be 1 after first position");

        // Create second position
        _createPosition(bob, true);
        assertEq(LendefiInstance.getUserPositionsCount(bob), 2, "Count should be 2 after second position");
    }

    // Test 3: Count decreases when closing positions
    function test_CountDecreasesWhenClosingPositions() public {
        // Create  positions
        _createPosition(bob, false);
        _createPosition(bob, true);
        assertEq(LendefiInstance.getUserPositionsCount(bob), 2, "Should have 2 positions");

        // Close one position
        vm.startPrank(bob);
        LendefiInstance.exitPosition(0);
        vm.stopPrank();

        assertEq(LendefiInstance.getUserPositionsCount(bob), 1, "Should have 1 position after closing");

        // Close second position
        vm.startPrank(bob);
        LendefiInstance.exitPosition(0);
        vm.stopPrank();

        assertEq(LendefiInstance.getUserPositionsCount(bob), 0, "Should have 0 positions after closing all");
    }

    // Test 4: Count for different users
    function test_CountForDifferentUsers() public {
        // Bob creates positions
        _createPosition(bob, false);
        _createPosition(bob, true);

        // Alice creates position
        _createPosition(alice, false);

        // Check counts
        assertEq(LendefiInstance.getUserPositionsCount(bob), 2, "Bob should have 2 positions");
        assertEq(LendefiInstance.getUserPositionsCount(alice), 1, "Alice should have 1 position");
        assertEq(LendefiInstance.getUserPositionsCount(charlie), 0, "Charlie should have 0 positions");
    }

    // Test 5: Count with zero address
    function test_CountForZeroAddress() public {
        uint256 count = LendefiInstance.getUserPositionsCount(address(0));
        assertEq(count, 0, "Zero address should have 0 positions");
    }

    // Test 6: Count after complex operations
    function test_CountAfterComplexOperations() public {
        // Create multiple positions
        for (uint256 i = 0; i < 3; i++) {
            _createPosition(bob, false);
        }
        assertEq(LendefiInstance.getUserPositionsCount(bob), 3, "Should have 3 positions");

        // Close middle position
        vm.startPrank(bob);
        LendefiInstance.exitPosition(1);
        vm.stopPrank();

        assertEq(LendefiInstance.getUserPositionsCount(bob), 2, "Should have 2 positions after closing one");

        // Create new position
        _createPosition(bob, true);
        assertEq(LendefiInstance.getUserPositionsCount(bob), 3, "Should be back to 3 positions");
    }

    // Test 7: Count remains consistent after position swapping
    function test_CountAfterPositionSwapping() public {
        // Create 3 positions
        _createPosition(bob, false);
        _createPosition(bob, false);
        _createPosition(bob, false);
        assertEq(LendefiInstance.getUserPositionsCount(bob), 3, "Should have 3 positions");

        // Close position 0, which swaps with the last position
        vm.startPrank(bob);
        LendefiInstance.exitPosition(0);
        vm.stopPrank();

        assertEq(LendefiInstance.getUserPositionsCount(bob), 2, "Should have 2 positions after swap-and-close");
    }

    // Fuzz test 1: Create varying numbers of positions
    function testFuzz_CreateMultiplePositions(uint256 numPositions) public {
        // Bound number of positions to reasonable range
        numPositions = bound(numPositions, 0, 10);

        for (uint256 i = 0; i < numPositions; i++) {
            _createPosition(bob, false);
        }

        assertEq(
            LendefiInstance.getUserPositionsCount(bob), numPositions, "Position count should match created positions"
        );
    }

    // Fuzz test 2: Create and close positions in random order
    function testFuzz_CreateAndClosePositions(uint256 seed) public {
        vm.assume(seed > 0);
        uint256 numToCreate = (seed % 5) + 2; // 2-6 positions
        uint256 numToClose = seed % numToCreate; // 0 to numToCreate-1 positions to close

        // Create positions
        for (uint256 i = 0; i < numToCreate; i++) {
            _createPosition(bob, false);
        }

        assertEq(LendefiInstance.getUserPositionsCount(bob), numToCreate, "Should match created positions");

        // Close positions
        vm.startPrank(bob);
        for (uint256 i = 0; i < numToClose; i++) {
            // Always close position 0 to handle reordering
            LendefiInstance.exitPosition(0);
        }
        vm.stopPrank();

        assertEq(
            LendefiInstance.getUserPositionsCount(bob), numToCreate - numToClose, "Should match remaining positions"
        );
    }

    // Test 8: Array boundaries - try to access beyond count
    function test_AccessBeyondCount() public {
        _createPosition(bob, false);
        uint256 count = LendefiInstance.getUserPositionsCount(bob);
        assertEq(count, 1, "Count should be 1");

        // Try to access position at count (should revert)
        vm.startPrank(bob);
        vm.expectRevert(abi.encodeWithSelector(Lendefi.InvalidPosition.selector, bob, count));
        LendefiInstance.exitPosition(count);
        vm.stopPrank();
    }
}
