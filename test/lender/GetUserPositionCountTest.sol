// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../BasicDeploy.sol";
import {console2} from "forge-std/console2.sol";
import {IPROTOCOL} from "../../contracts/interfaces/IProtocol.sol";
import {Lendefi} from "../../contracts/lender/Lendefi.sol";
import {MockPriceOracle} from "../../contracts/mock/MockPriceOracle.sol";
import {MockRWA} from "../../contracts/mock/MockRWA.sol";

contract GetUserPositionsCountTest is BasicDeploy {
    MockPriceOracle internal ethOracle;
    MockPriceOracle internal rwaOracle;
    MockRWA internal rwaToken;

    function setUp() public {
        // Use deployCompleteWithOracle() instead of deployComplete()
        deployCompleteWithOracle();

        // TGE setup
        vm.prank(guardian);
        tokenInstance.initializeTGE(address(ecoInstance), address(treasuryInstance));

        // Deploy mock tokens (USDC already deployed by deployCompleteWithOracle())
        wethInstance = new WETH9();
        rwaToken = new MockRWA("Real World Asset", "RWA");

        // Deploy mock oracles with proper implementation
        ethOracle = new MockPriceOracle();
        rwaOracle = new MockPriceOracle();

        // Set prices with valid round data
        ethOracle.setPrice(int256(2500e8)); // $2500 per ETH
        ethOracle.setTimestamp(block.timestamp);
        ethOracle.setRoundId(1);
        ethOracle.setAnsweredInRound(1);

        rwaOracle.setPrice(int256(1000e8)); // $1000 per RWA token
        rwaOracle.setTimestamp(block.timestamp);
        rwaOracle.setRoundId(1);
        rwaOracle.setAnsweredInRound(1);

        // Register oracles with Oracle module
        vm.startPrank(address(timelockInstance));
        oracleInstance.addOracle(address(wethInstance), address(ethOracle), 8);
        oracleInstance.setPrimaryOracle(address(wethInstance), address(ethOracle));

        oracleInstance.addOracle(address(rwaToken), address(rwaOracle), 8);
        oracleInstance.setPrimaryOracle(address(rwaToken), address(rwaOracle));
        vm.stopPrank();

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
            address(ethOracle),
            8, // oracle decimals
            18, // asset decimals
            1, // active
            800, // 80% borrow threshold
            850, // 85% liquidation threshold
            1_000_000 ether, // max supply
            IPROTOCOL.CollateralTier.CROSS_A,
            0 // no isolation debt cap
        );

        // Configure RWA token as isolation-eligible
        LendefiInstance.updateAssetConfig(
            address(rwaToken),
            address(rwaOracle),
            8, // oracle decimals
            18, // asset decimals
            1, // active
            650, // 65% borrow threshold
            750, // 75% liquidation threshold
            1_000_000 ether, // max supply
            IPROTOCOL.CollateralTier.ISOLATED,
            100_000e6 // $100k max borrow cap
        );
        vm.stopPrank();
    }

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

    // Test 3: Count remains the same after closing positions (updated behavior)
    function test_CountUnchangedWhenClosingPositions() public {
        // Create positions
        _createPosition(bob, false);
        _createPosition(bob, true);
        assertEq(LendefiInstance.getUserPositionsCount(bob), 2, "Should have 2 positions");

        // Close one position
        vm.startPrank(bob);
        LendefiInstance.exitPosition(0);
        vm.stopPrank();

        // Count should remain the same
        assertEq(LendefiInstance.getUserPositionsCount(bob), 2, "Count should still be 2 after closing 1 position");

        // Verify position status is CLOSED
        IPROTOCOL.UserPosition memory position = LendefiInstance.getUserPosition(bob, 0);
        assertEq(
            uint256(position.status), uint256(IPROTOCOL.PositionStatus.CLOSED), "Position should be marked as CLOSED"
        );

        // Close second position
        vm.startPrank(bob);
        LendefiInstance.exitPosition(1);
        vm.stopPrank();

        // Count should still remain the same
        assertEq(LendefiInstance.getUserPositionsCount(bob), 2, "Count should still be 2 after closing all positions");

        // Verify second position status is also CLOSED
        position = LendefiInstance.getUserPosition(bob, 1);
        assertEq(
            uint256(position.status), uint256(IPROTOCOL.PositionStatus.CLOSED), "Position should be marked as CLOSED"
        );
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

        // Close middle position - count should remain the same
        vm.startPrank(bob);
        LendefiInstance.exitPosition(1);
        vm.stopPrank();

        assertEq(LendefiInstance.getUserPositionsCount(bob), 3, "Should still have 3 positions after closing one");

        // Create new position
        _createPosition(bob, true);
        assertEq(LendefiInstance.getUserPositionsCount(bob), 4, "Should have 4 positions after adding one more");
    }

    // Test 7: Active positions versus total positions count
    function test_ActivePositionsCount() public {
        // Create 3 positions
        _createPosition(bob, false);
        _createPosition(bob, false);
        _createPosition(bob, true);

        // Total count should be 3
        assertEq(LendefiInstance.getUserPositionsCount(bob), 3, "Should have 3 total positions");

        // Close one position
        vm.startPrank(bob);
        LendefiInstance.exitPosition(1);
        vm.stopPrank();

        // Total count still 3, but only 2 are active
        uint256 activeCount = 0;
        for (uint256 i = 0; i < LendefiInstance.getUserPositionsCount(bob); i++) {
            IPROTOCOL.UserPosition memory position = LendefiInstance.getUserPosition(bob, i);
            if (position.status == IPROTOCOL.PositionStatus.ACTIVE) {
                activeCount++;
            }
        }

        assertEq(LendefiInstance.getUserPositionsCount(bob), 3, "Should still have 3 total positions");
        assertEq(activeCount, 2, "Should have 2 active positions");
    }

    // Test 8: Verify position status after liquidation
    function test_PositionStatusAfterLiquidation() public {
        // Setup a liquidatable position
        uint256 collateralAmount = 1 ether;
        uint256 borrowAmount = 2000e6; // Close to max borrow capacity

        vm.deal(bob, collateralAmount);
        vm.startPrank(bob);
        wethInstance.deposit{value: collateralAmount}();

        // Create position
        LendefiInstance.createPosition(address(wethInstance), false);
        uint256 positionId = 0;

        // Supply collateral
        wethInstance.approve(address(LendefiInstance), collateralAmount);
        LendefiInstance.supplyCollateral(address(wethInstance), collateralAmount, positionId);

        // Borrow near max capacity
        LendefiInstance.borrow(positionId, borrowAmount);
        vm.stopPrank();

        // Drop ETH price to trigger liquidation condition
        ethOracle.setPrice(int256(2500e8 * 84 / 100)); // Liquidation threshold is 85%
        ethOracle.setTimestamp(block.timestamp);

        // Verify position is now liquidatable
        assertTrue(LendefiInstance.isLiquidatable(bob, positionId), "Position should be liquidatable");

        // Setup Charlie as liquidator
        vm.prank(address(timelockInstance));
        treasuryInstance.release(address(tokenInstance), charlie, 50_000 ether); // Give enough gov tokens
        usdcInstance.mint(charlie, 100_000e6); // Give enough USDC

        // Perform liquidation
        vm.startPrank(charlie);
        usdcInstance.approve(address(LendefiInstance), 100_000e6);
        LendefiInstance.liquidate(bob, positionId);
        vm.stopPrank();

        // Count should remain the same
        assertEq(LendefiInstance.getUserPositionsCount(bob), 1, "User should still have 1 position");

        // Verify position is marked as liquidated
        IPROTOCOL.UserPosition memory position = LendefiInstance.getUserPosition(bob, positionId);
        assertEq(
            uint256(position.status),
            uint256(IPROTOCOL.PositionStatus.LIQUIDATED),
            "Position should be marked as LIQUIDATED"
        );
    }

    // Test 9: Array boundaries - try to access beyond count
    function test_AccessBeyondCount() public {
        _createPosition(bob, false);
        uint256 count = LendefiInstance.getUserPositionsCount(bob);
        assertEq(count, 1, "Count should be 1");

        // Try to access position at count (should revert)
        vm.startPrank(bob);
        vm.expectRevert(abi.encodeWithSelector(IPROTOCOL.InvalidPosition.selector, bob, count));
        LendefiInstance.exitPosition(count);
        vm.stopPrank();
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

    // Fuzz test 2: Create and close positions in varying patterns
    function testFuzz_CreateAndClosePositions(uint256 seed) public {
        vm.assume(seed > 0);
        uint256 numToCreate = (seed % 5) + 2; // 2-6 positions
        uint256 numToClose = seed % numToCreate; // 0 to numToCreate-1 positions to close

        // Create positions
        for (uint256 i = 0; i < numToCreate; i++) {
            _createPosition(bob, false);
        }

        assertEq(LendefiInstance.getUserPositionsCount(bob), numToCreate, "Should match created positions");

        // Close some positions
        vm.startPrank(bob);
        for (uint256 i = 0; i < numToClose; i++) {
            uint256 positionToClose = i % numToCreate; // Close positions in a pattern
            LendefiInstance.exitPosition(positionToClose);

            // Verify the position is now closed
            IPROTOCOL.UserPosition memory position = LendefiInstance.getUserPosition(bob, positionToClose);
            assertEq(
                uint256(position.status),
                uint256(IPROTOCOL.PositionStatus.CLOSED),
                "Position should be marked as CLOSED"
            );
        }
        vm.stopPrank();

        // Count should remain the same
        assertEq(
            LendefiInstance.getUserPositionsCount(bob),
            numToCreate,
            "Position count should remain the same after closing"
        );

        // Count active positions
        uint256 activeCount = 0;
        for (uint256 i = 0; i < LendefiInstance.getUserPositionsCount(bob); i++) {
            IPROTOCOL.UserPosition memory position = LendefiInstance.getUserPosition(bob, i);
            if (position.status == IPROTOCOL.PositionStatus.ACTIVE) {
                activeCount++;
            }
        }

        // Verify active positions count
        assertEq(activeCount, numToCreate - numToClose, "Active positions should match (created - closed)");
    }

    // Test 10: Get active positions count
    function test_GetActivePositionsCount() public {
        // Create positions
        uint256 pos1 = _createPosition(bob, false); // Position 0
        uint256 pos2 = _createPosition(bob, false); // Position 1
        _createPosition(bob, true); // Position 2

        // All are active initially
        uint256 initialActive = _countActivePositions(bob);
        assertEq(initialActive, 3, "Should have 3 active positions initially");

        // Close position 1
        vm.prank(bob);
        LendefiInstance.exitPosition(pos2);

        uint256 afterFirstClose = _countActivePositions(bob);
        assertEq(afterFirstClose, 2, "Should have 2 active positions after first closure");

        // Close position 0
        vm.prank(bob);
        LendefiInstance.exitPosition(pos1);

        uint256 afterSecondClose = _countActivePositions(bob);
        assertEq(afterSecondClose, 1, "Should have 1 active position after second closure");

        // Total count remains at 3
        assertEq(LendefiInstance.getUserPositionsCount(bob), 3, "Total count should remain at 3");
    }

    // Helper function to count active positions
    function _countActivePositions(address user) internal view returns (uint256) {
        uint256 activeCount = 0;
        uint256 total = LendefiInstance.getUserPositionsCount(user);

        for (uint256 i = 0; i < total; i++) {
            IPROTOCOL.UserPosition memory position = LendefiInstance.getUserPosition(user, i);
            if (position.status == IPROTOCOL.PositionStatus.ACTIVE) {
                activeCount++;
            }
        }

        return activeCount;
    }
}
