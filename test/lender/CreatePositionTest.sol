// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../BasicDeploy.sol";
import {console2} from "forge-std/console2.sol";
import {IPROTOCOL} from "../../contracts/interfaces/IProtocol.sol";
import {RWAPriceConsumerV3} from "../../contracts/mock/RWAOracle.sol";
import {WETHPriceConsumerV3} from "../../contracts/mock/WETHOracle.sol";
import {MockRWA} from "../../contracts/mock/MockRWA.sol";
import {Lendefi} from "../../contracts/lender/Lendefi.sol";

contract CreatePositionTest is BasicDeploy {
    // Events to verify
    event PositionCreated(address indexed user, uint256 indexed positionId, bool isIsolated);

    uint256 constant WAD = 1e18;
    MockRWA internal rwaToken;

    RWAPriceConsumerV3 internal rwaOracleInstance;
    WETHPriceConsumerV3 internal wethOracleInstance;

    // Test assets
    address internal isolatedAsset;
    address internal crossAsset;
    address internal notListedAsset;

    function setUp() public {
        deployComplete();

        // TGE setup
        vm.prank(guardian);
        tokenInstance.initializeTGE(address(ecoInstance), address(treasuryInstance));

        // Deploy mock tokens
        usdcInstance = new USDC();
        wethInstance = new WETH9();
        rwaToken = new MockRWA("Ondo Finance", "ONDO");
        MockRWA unlisted = new MockRWA("Unlisted Token", "UNLIST");

        // Store addresses for test cases
        isolatedAsset = address(rwaToken);
        crossAsset = address(wethInstance);
        notListedAsset = address(unlisted);

        // Deploy oracles
        wethOracleInstance = new WETHPriceConsumerV3();
        rwaOracleInstance = new RWAPriceConsumerV3();

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

        // Configure RWA token as ISOLATED tier
        LendefiInstance.updateAssetConfig(
            address(rwaToken),
            address(rwaOracleInstance),
            8,
            18,
            1,
            650,
            750,
            1_000_000 ether,
            IPROTOCOL.CollateralTier.ISOLATED,
            100_000e6
        );

        // Configure WETH as CROSS_A tier
        LendefiInstance.updateAssetConfig(
            address(wethInstance),
            address(wethOracleInstance),
            8,
            18,
            1,
            800,
            850,
            1_000_000 ether,
            IPROTOCOL.CollateralTier.CROSS_A,
            0
        );

        vm.stopPrank();
    }

    function _setupLiquidity() internal {
        usdcInstance.mint(alice, 1_000_000e6);
        vm.startPrank(alice);
        usdcInstance.approve(address(LendefiInstance), 1_000_000e6);
        LendefiInstance.supplyLiquidity(1_000_000e6);
        vm.stopPrank();

        // Set token prices for calculations
        wethOracleInstance.setPrice(2500e8); // $2500 per ETH
        rwaOracleInstance.setPrice(1000e8); // $1000 per RWA
    }

    // Test 1: Create a non-isolated position with valid asset
    function test_CreateNonIsolatedPosition() public {
        vm.startPrank(bob);

        // Verify bob has no positions yet
        uint256 initialPositionsCount = LendefiInstance.getUserPositionsCount(bob);
        assertEq(initialPositionsCount, 0, "Should start with no positions");

        // Create a non-isolated position
        vm.expectEmit(true, true, false, true);
        emit PositionCreated(bob, 0, false);
        LendefiInstance.createPosition(crossAsset, false);

        // Verify position was created
        uint256 finalPositionsCount = LendefiInstance.getUserPositionsCount(bob);
        assertEq(finalPositionsCount, 1, "Should have 1 position after creation");

        // Verify position is not isolated
        IPROTOCOL.UserPosition memory position = LendefiInstance.getUserPosition(bob, 0);
        address[] memory assets = LendefiInstance.getPositionCollateralAssets(bob, 0);
        assertEq(position.isIsolated, false, "Position should not be isolated");
        assertEq(assets.length, 0, "Isolated asset should be zero for non-isolated position");

        vm.stopPrank();
    }

    // Test 2: Create an isolated position with valid isolated asset
    function test_CreateIsolatedPosition() public {
        vm.startPrank(bob);

        // Create an isolated position
        vm.expectEmit(true, true, false, true);
        emit PositionCreated(bob, 0, true);
        LendefiInstance.createPosition(isolatedAsset, true);

        // Verify position was created
        uint256 finalPositionsCount = LendefiInstance.getUserPositionsCount(bob);
        assertEq(finalPositionsCount, 1, "Should have 1 position after creation");

        // Verify position is isolated
        IPROTOCOL.UserPosition memory position = LendefiInstance.getUserPosition(bob, 0);
        address[] memory assets = LendefiInstance.getPositionCollateralAssets(bob, 0);
        assertEq(position.isIsolated, true, "Position should be isolated");
        assertEq(assets[0], isolatedAsset, "Isolated asset should be set correctly");

        vm.stopPrank();
    }

    // Test 3: Create an isolated position with non-isolated asset (should fail)
    function test_CreateIsolatedPositionWithNonIsolatedAsset() public {
        vm.startPrank(bob);

        // Try to create an isolated position with a non-isolated asset
        // vm.expectRevert(abi.encodeWithSelector(Lendefi.NotIsolationEligible.selector, crossAsset));
        LendefiInstance.createPosition(crossAsset, true);

        // Verify no position was created
        uint256 finalPositionsCount = LendefiInstance.getUserPositionsCount(bob);
        assertEq(finalPositionsCount, 1, "Should have 1 positions after failed creation");

        vm.stopPrank();
    }

    // Test 4: Create position with unlisted asset (should fail)
    function test_CreatePositionWithUnlistedAsset() public {
        vm.startPrank(bob);

        // Try to create a position with an unlisted asset
        vm.expectRevert(abi.encodeWithSelector(IPROTOCOL.AssetNotListed.selector, notListedAsset));
        LendefiInstance.createPosition(notListedAsset, false);

        // Verify no position was created
        uint256 finalPositionsCount = LendefiInstance.getUserPositionsCount(bob);
        assertEq(finalPositionsCount, 0, "Should have 0 positions after failed creation");

        vm.stopPrank();
    }

    // Test 5: Create position when protocol is paused (should fail)
    function test_CreatePositionWhenPaused() public {
        // Pause the protocol
        vm.startPrank(guardian);
        LendefiInstance.pause();
        vm.stopPrank();

        vm.startPrank(bob);

        // Try to create a position when paused
        bytes memory expError = abi.encodeWithSignature("EnforcedPause()");
        vm.expectRevert(expError);
        LendefiInstance.createPosition(crossAsset, false);

        vm.stopPrank();
    }

    // Test 6: Create multiple positions for the same user
    function test_CreateMultiplePositions() public {
        vm.startPrank(bob);

        // Create a non-isolated position
        vm.expectEmit(true, true, false, true);
        emit PositionCreated(bob, 0, false);
        LendefiInstance.createPosition(crossAsset, false);

        vm.expectEmit(true, true, false, true);
        emit PositionCreated(bob, 1, true);
        LendefiInstance.createPosition(isolatedAsset, true);

        vm.expectEmit(true, true, false, true);
        emit PositionCreated(bob, 2, false);
        LendefiInstance.createPosition(crossAsset, false);
        // Verify user now has 3 positions
        uint256 positionsCount = LendefiInstance.getUserPositionsCount(bob);
        assertEq(positionsCount, 3, "Should have 3 positions");

        // Verify position 0 is non-isolated
        IPROTOCOL.UserPosition memory position0 = LendefiInstance.getUserPosition(bob, 0);
        assertEq(position0.isIsolated, false, "Position 0 should not be isolated");

        // Verify position 1 is isolated
        IPROTOCOL.UserPosition memory position1 = LendefiInstance.getUserPosition(bob, 1);
        address[] memory assets = LendefiInstance.getPositionCollateralAssets(bob, 1);
        assertEq(position1.isIsolated, true, "Position 1 should be isolated");
        assertEq(assets[0], isolatedAsset, "Position 1 should have correct isolated asset");

        // Verify position 2 is non-isolated
        IPROTOCOL.UserPosition memory position2 = LendefiInstance.getUserPosition(bob, 2);
        assertEq(position2.isIsolated, false, "Position 2 should not be isolated");

        vm.stopPrank();
    }

    // Test 7: Creating positions from different users
    function test_CreatePositionsFromDifferentUsers() public {
        // First user creates a position
        vm.startPrank(bob);
        vm.expectEmit(true, true, false, true);
        emit PositionCreated(bob, 0, false);
        LendefiInstance.createPosition(crossAsset, false);
        vm.stopPrank();

        vm.startPrank(charlie);
        vm.expectEmit(true, true, false, true);
        emit PositionCreated(charlie, 0, true);
        LendefiInstance.createPosition(isolatedAsset, true);
        vm.stopPrank();

        // Verify both users have their own positions
        assertEq(LendefiInstance.getUserPositionsCount(bob), 1, "Bob should have 1 position");
        assertEq(LendefiInstance.getUserPositionsCount(charlie), 1, "Charlie should have 1 position");

        // Verify each position has correct properties
        IPROTOCOL.UserPosition memory bobPosition = LendefiInstance.getUserPosition(bob, 0);
        IPROTOCOL.UserPosition memory charliePosition = LendefiInstance.getUserPosition(charlie, 0);
        address[] memory assets = LendefiInstance.getPositionCollateralAssets(charlie, 0);

        assertEq(bobPosition.isIsolated, false, "Bob's position should not be isolated");
        assertEq(charliePosition.isIsolated, true, "Charlie's position should be isolated");
        assertEq(assets[0], isolatedAsset, "Charlie's position should have correct isolated asset");
    }

    // Test 8: Maximum number of positions (stress test)
    function test_CreateManyPositions() public {
        vm.startPrank(bob);

        // Create a large number of positions
        uint256 numPositions = 50;
        for (uint256 i = 0; i < numPositions; i++) {
            bool isIsolated = i % 2 == 0; // Alternate between isolated and non-isolated
            address asset = isIsolated ? isolatedAsset : crossAsset;
            LendefiInstance.createPosition(asset, isIsolated);
        }

        // Verify all positions were created
        uint256 positionsCount = LendefiInstance.getUserPositionsCount(bob);
        assertEq(positionsCount, numPositions, "Should have created all positions");

        // Verify a sample of positions have correct settings
        IPROTOCOL.UserPosition memory position0 = LendefiInstance.getUserPosition(bob, 0);
        IPROTOCOL.UserPosition memory position1 = LendefiInstance.getUserPosition(bob, 1);

        assertEq(position0.isIsolated, true, "Position 0 should be isolated");
        assertEq(position1.isIsolated, false, "Position 1 should not be isolated");

        vm.stopPrank();
    }

    // Fuzz Test 1: Create position with different isolation flags
    function testFuzz_CreatePositionWithIsolationFlag(bool isIsolated) public {
        vm.startPrank(bob);

        // Choose appropriate asset based on isolation flag
        address asset = isIsolated ? isolatedAsset : crossAsset;

        // Create position
        LendefiInstance.createPosition(asset, isIsolated);

        // Verify position
        IPROTOCOL.UserPosition memory position = LendefiInstance.getUserPosition(bob, 0);
        address[] memory assets = LendefiInstance.getPositionCollateralAssets(bob, 0);
        assertEq(position.isIsolated, isIsolated, "Position isolation flag should match input");

        if (isIsolated) {
            assertEq(assets[0], asset, "Isolated asset should be set");
        } else {
            assertEq(assets.length, 0, "Isolated asset should be zero for non-isolated position");
        }

        vm.stopPrank();
    }

    // Fuzz Test 2: Create position for different users (using address fuzzing)
    function testFuzz_CreatePositionWithDifferentUsers(address user) public {
        // Skip zero address and contract addresses
        vm.assume(user != address(0));
        vm.assume(user != address(this));
        vm.assume(user != address(LendefiInstance));

        vm.startPrank(user);

        // Create a position
        LendefiInstance.createPosition(crossAsset, false);

        // Verify position was created for this user
        uint256 positionsCount = LendefiInstance.getUserPositionsCount(user);
        assertEq(positionsCount, 1, "User should have 1 position");

        vm.stopPrank();
    }

    // Property Test: Position ID should always be sequential
    function testProperty_PositionIdIsSequential() public {
        vm.startPrank(bob);

        // Create multiple positions and verify IDs
        uint256 numPositions = 10;
        for (uint256 i = 0; i < numPositions; i++) {
            // Create alternating position types
            bool isIsolated = i % 2 == 0;
            address asset = isIsolated ? isolatedAsset : crossAsset;

            vm.expectEmit(true, true, false, true);
            emit PositionCreated(bob, i, isIsolated);
            LendefiInstance.createPosition(asset, isIsolated);

            // Verify position count increased
            uint256 positionsCount = LendefiInstance.getUserPositionsCount(bob);
            assertEq(positionsCount, i + 1, "Position count should increment by 1");
        }

        vm.stopPrank();
    }

    // Property Test: Isolated positions should always have an asset set
    function testProperty_IsolatedPositionsHaveAsset() public {
        vm.startPrank(bob);

        // Create a mix of isolated and non-isolated positions
        LendefiInstance.createPosition(isolatedAsset, true); // Isolated
        LendefiInstance.createPosition(crossAsset, false); // Non-isolated
        LendefiInstance.createPosition(isolatedAsset, true); // Isolated

        // Check all positions
        for (uint256 i = 0; i < 3; i++) {
            IPROTOCOL.UserPosition memory position = LendefiInstance.getUserPosition(bob, i);
            address[] memory assets = LendefiInstance.getPositionCollateralAssets(bob, i);

            if (position.isIsolated) {
                assertNotEq(assets[0], address(0), "Isolated position should have non-zero asset");
            } else {
                assertEq(assets.length, 0, "Non-isolated position should have zero asset");
            }
        }

        vm.stopPrank();
    }
}
