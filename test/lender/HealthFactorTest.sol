// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../BasicDeploy.sol";
import {console2} from "forge-std/console2.sol";
import {IPROTOCOL} from "../../contracts/interfaces/IProtocol.sol";
import {MockPriceOracle} from "../../contracts/mock/MockPriceOracle.sol";
import {MockRWA} from "../../contracts/mock/MockRWA.sol";
import {Lendefi} from "../../contracts/lender/Lendefi.sol";

contract HealthFactorTest is BasicDeploy {
    MockPriceOracle internal ethOracle;
    MockPriceOracle internal rwaOracle;
    MockPriceOracle internal stableOracle;
    MockRWA internal rwaToken;
    MockRWA internal stableToken;

    // Constants for test parameters
    uint256 constant WAD = 1e6;
    uint256 constant INITIAL_LIQUIDITY = 1_000_000e6; // 1M USDC
    uint256 constant ETH_PRICE = 2500e8; // $2500 per ETH
    uint256 constant RWA_PRICE = 1000e8; // $1000 per RWA token
    uint256 constant STABLE_PRICE = 1e8; // $1 per stable token

    function setUp() public {
        deployComplete();

        // TGE setup
        vm.prank(guardian);
        tokenInstance.initializeTGE(address(ecoInstance), address(treasuryInstance));

        // Deploy mock tokens
        usdcInstance = new USDC();
        wethInstance = new WETH9();
        rwaToken = new MockRWA("Real World Asset", "RWA");
        stableToken = new MockRWA("Stable Token", "STABLE");

        // Deploy mock oracles with proper implementation
        ethOracle = new MockPriceOracle();
        rwaOracle = new MockPriceOracle();
        stableOracle = new MockPriceOracle();

        // Set prices with valid round data
        ethOracle.setPrice(int256(ETH_PRICE));
        ethOracle.setTimestamp(block.timestamp);
        ethOracle.setRoundId(1);
        ethOracle.setAnsweredInRound(1);

        rwaOracle.setPrice(int256(RWA_PRICE));
        rwaOracle.setTimestamp(block.timestamp);
        rwaOracle.setRoundId(1);
        rwaOracle.setAnsweredInRound(1);

        stableOracle.setPrice(int256(STABLE_PRICE));
        stableOracle.setTimestamp(block.timestamp);
        stableOracle.setRoundId(1);
        stableOracle.setAnsweredInRound(1);

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

        _setupAssets();
        _supplyProtocolLiquidity();
    }

    function _setupAssets() internal {
        vm.startPrank(address(timelockInstance));

        // Configure WETH as CROSS_A tier
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

        // Configure RWA token as ISOLATED tier
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
            100_000e6 // isolation debt cap of 100,000 USDC
        );

        // Configure Stable token as STABLE tier
        LendefiInstance.updateAssetConfig(
            address(stableToken),
            address(stableOracle),
            8, // oracle decimals
            18, // asset decimals
            1, // active
            900, // 90% borrow threshold
            950, // 95% liquidation threshold
            1_000_000 ether, // max supply
            IPROTOCOL.CollateralTier.STABLE,
            0 // no isolation debt cap
        );

        vm.stopPrank();
    }

    function _supplyProtocolLiquidity() internal {
        // Mint USDC to alice
        usdcInstance.mint(alice, INITIAL_LIQUIDITY);

        vm.startPrank(alice);
        // Approve USDC spending
        usdcInstance.approve(address(LendefiInstance), INITIAL_LIQUIDITY);
        // Supply liquidity
        LendefiInstance.supplyLiquidity(INITIAL_LIQUIDITY);
        vm.stopPrank();
    }

    // Test 1: Invalid position ID reverts
    function test_HealthFactorInvalidPosition() public {
        // Try to get health factor for non-existent position
        vm.expectRevert(abi.encodeWithSelector(IPROTOCOL.InvalidPosition.selector, bob, 999));
        LendefiInstance.healthFactor(bob, 999);
    }

    // Test 2: Zero debt returns max uint
    function test_HealthFactorZeroDebt() public {
        // Setup - create position with collateral but no debt
        uint256 collateralAmount = 1 ether;

        vm.deal(bob, collateralAmount);
        vm.startPrank(bob);
        wethInstance.deposit{value: collateralAmount}();

        // Create position
        LendefiInstance.createPosition(address(wethInstance), false);
        uint256 positionId = 0;

        // Supply collateral but don't borrow
        wethInstance.approve(address(LendefiInstance), collateralAmount);
        LendefiInstance.supplyCollateral(address(wethInstance), collateralAmount, positionId);
        vm.stopPrank();

        // Check health factor
        uint256 healthFactor = LendefiInstance.healthFactor(bob, positionId);
        assertEq(healthFactor, type(uint256).max, "Health factor should be max for positions with no debt");
    }

    // Test 3: Empty position (position with no collateral)
    function test_HealthFactorEmptyPosition() public {
        // Create empty position
        vm.prank(bob);
        LendefiInstance.createPosition(address(wethInstance), false);
        uint256 positionId = 0;

        // Health factor should be max for position with no debt
        uint256 healthFactor = LendefiInstance.healthFactor(bob, positionId);
        assertEq(healthFactor, type(uint256).max, "Health factor should be max for positions with no debt");
    }

    // Test 4: Health factor with multiple assets but some have 0 amount
    function test_HealthFactorWithZeroAmountAssets() public {
        uint256 collateralAmount = 5 ether;
        uint256 borrowAmount = 3_000e6;

        // Setup position with multiple assets
        vm.deal(bob, collateralAmount);
        vm.startPrank(bob);
        wethInstance.deposit{value: collateralAmount}();

        // Create position
        LendefiInstance.createPosition(address(wethInstance), false);
        uint256 positionId = 0;

        // Supply collateral
        wethInstance.approve(address(LendefiInstance), collateralAmount);
        LendefiInstance.supplyCollateral(address(wethInstance), collateralAmount, positionId);

        // Add stable token with 0 balance to position assets array
        stableToken.mint(bob, 1 ether); // Small amount to add as collateral
        stableToken.approve(address(LendefiInstance), 1 ether);
        LendefiInstance.supplyCollateral(address(stableToken), 1 ether, positionId);

        // Now withdraw all of the stable token, leaving 0 balance but still in the array
        LendefiInstance.withdrawCollateral(address(stableToken), 1 ether, positionId);

        // Verify stable token amount is truly zero
        uint256 stableAmount = LendefiInstance.getUserCollateralAmount(bob, positionId, address(stableToken));
        assertEq(stableAmount, 0, "Stable token amount should be zero");

        // Borrow to create debt
        LendefiInstance.borrow(positionId, borrowAmount);
        vm.stopPrank();

        // Calculate expected health factor - using the liquidation threshold (85%)
        uint256 amount = 5 ether;
        uint256 price = ETH_PRICE; // 2500e8
        uint256 liquidationThreshold = 850; // 85%
        uint256 decimals = 18; // WETH decimals
        uint256 oracleDecimals = 8; // Price oracle decimals
        uint256 debt = LendefiInstance.calculateDebtWithInterest(bob, positionId);

        uint256 liqLevel = (amount * price * liquidationThreshold * WAD) / 10 ** decimals / 1000 / 10 ** oracleDecimals;
        uint256 expectedHealthFactor = (liqLevel * WAD) / debt;

        // Get actual health factor
        uint256 healthFactor = LendefiInstance.healthFactor(bob, positionId);

        console2.log("Health factor: %d", healthFactor);
        console2.log("Liquidation level: %d", liqLevel / 1e6);
        console2.log("Expected health factor: %d", expectedHealthFactor);

        // Health factor should match expected (only counting non-zero amounts)
        assertApproxEqRel(
            healthFactor, expectedHealthFactor, 0.01e18, "Health factor should only count non-zero amounts"
        );
    }

    // Test 5: Health factor when oracle gives invalid price
    function test_HealthFactorWithInvalidOraclePrice() public {
        // Setup position
        uint256 collateralAmount = 3 ether;
        uint256 borrowAmount = 2_000e6;

        vm.deal(bob, collateralAmount);
        vm.startPrank(bob);
        wethInstance.deposit{value: collateralAmount}();

        // Create position
        LendefiInstance.createPosition(address(wethInstance), false);
        uint256 positionId = 0;

        // Supply collateral
        wethInstance.approve(address(LendefiInstance), collateralAmount);
        LendefiInstance.supplyCollateral(address(wethInstance), collateralAmount, positionId);

        // Borrow
        LendefiInstance.borrow(positionId, borrowAmount);
        vm.stopPrank();

        // Try to set invalid price (0)
        ethOracle.setPrice(0);
        ethOracle.setTimestamp(block.timestamp);

        // Try to get health factor with zero price
        vm.expectRevert(abi.encodeWithSelector(IPROTOCOL.OracleInvalidPrice.selector, address(ethOracle), 0));
        LendefiInstance.healthFactor(bob, positionId);

        // Try negative price
        ethOracle.setPrice(-1000);
        vm.expectRevert(abi.encodeWithSelector(IPROTOCOL.OracleInvalidPrice.selector, address(ethOracle), -1000));
        LendefiInstance.healthFactor(bob, positionId);
    }

    // Test 6: Health factor when oracle data is stale
    function test_HealthFactorWithStaleOracle() public {
        // Setup position
        uint256 collateralAmount = 3 ether;
        uint256 borrowAmount = 2_000e6;

        vm.deal(bob, collateralAmount);
        vm.startPrank(bob);
        wethInstance.deposit{value: collateralAmount}();

        // Create position
        LendefiInstance.createPosition(address(wethInstance), false);
        uint256 positionId = 0;

        // Supply collateral
        wethInstance.approve(address(LendefiInstance), collateralAmount);
        LendefiInstance.supplyCollateral(address(wethInstance), collateralAmount, positionId);

        // Borrow
        LendefiInstance.borrow(positionId, borrowAmount);
        vm.stopPrank();

        // Set stale round data (answeredInRound < roundId)
        ethOracle.setRoundId(10);
        ethOracle.setAnsweredInRound(5); // Older round used for answer
        ethOracle.setTimestamp(block.timestamp); // Current timestamp

        // Try to get health factor with stale oracle data
        vm.expectRevert(abi.encodeWithSelector(IPROTOCOL.OracleStalePrice.selector, address(ethOracle), 10, 5));
        LendefiInstance.healthFactor(bob, positionId);
    }

    // Test 7: Health factor when oracle timestamp is outdated
    function test_HealthFactorWithOutdatedOracle() public {
        // Setup position
        uint256 collateralAmount = 3 ether;
        uint256 borrowAmount = 2_000e6;

        vm.deal(bob, collateralAmount);
        vm.startPrank(bob);
        wethInstance.deposit{value: collateralAmount}();

        // Create position
        LendefiInstance.createPosition(address(wethInstance), false);
        uint256 positionId = 0;

        // Supply collateral
        wethInstance.approve(address(LendefiInstance), collateralAmount);
        LendefiInstance.supplyCollateral(address(wethInstance), collateralAmount, positionId);

        // Borrow
        LendefiInstance.borrow(positionId, borrowAmount);
        vm.stopPrank();

        // Set outdated timestamp (> 24 hours old)
        uint256 oldTimestamp = block.timestamp - 25 hours;
        ethOracle.setTimestamp(oldTimestamp);
        ethOracle.setRoundId(1);
        ethOracle.setAnsweredInRound(1);

        // Try to get health factor with outdated oracle
        vm.expectRevert(
            abi.encodeWithSelector(
                IPROTOCOL.OracleTimeout.selector, address(ethOracle), oldTimestamp, block.timestamp, 8 hours
            )
        );
        LendefiInstance.healthFactor(bob, positionId);
    }

    // Test 8: Health factor calculation for isolated position
    function test_HealthFactorForIsolatedPosition() public {
        uint256 collateralAmount = 10 ether; // 10 RWA @ $1000 = $10,000
        uint256 borrowAmount = 5_000e6; // 5,000 USDC

        // Setup isolated position
        rwaToken.mint(bob, collateralAmount);

        vm.startPrank(bob);
        // Create isolated position - now correctly stores the isolated asset in collateralAssets array
        LendefiInstance.createPosition(address(rwaToken), true);
        uint256 positionId = 0;

        // Verify position was created with correct isolation flag
        IPROTOCOL.UserPosition memory pos = LendefiInstance.getUserPosition(bob, positionId);
        assertTrue(pos.isIsolated, "Position should be in isolation mode");

        // Supply collateral to the isolated position
        rwaToken.approve(address(LendefiInstance), collateralAmount);
        LendefiInstance.supplyCollateral(address(rwaToken), collateralAmount, positionId);

        // Verify collateral was added correctly
        address[] memory collateralAssets = LendefiInstance.getPositionCollateralAssets(bob, positionId);
        assertEq(collateralAssets.length, 1, "Isolated position should have exactly 1 asset");
        assertEq(collateralAssets[0], address(rwaToken), "Collateral asset should be RWA token");

        // Borrow against the isolated position
        LendefiInstance.borrow(positionId, borrowAmount);
        vm.stopPrank();

        // Get health factor
        uint256 healthFactor = LendefiInstance.healthFactor(bob, positionId);

        // Calculate expected health factor using liquidation threshold (75%)
        uint256 amount = 10 ether;
        uint256 price = RWA_PRICE; // 1000e8
        uint256 liquidationThreshold = 750; // 75%
        uint256 decimals = 18; // RWA decimals
        uint256 oracleDecimals = 8; // Oracle decimals
        uint256 debt = LendefiInstance.calculateDebtWithInterest(bob, positionId);

        uint256 liqLevel = (amount * price * liquidationThreshold * WAD) / 10 ** decimals / 1000 / 10 ** oracleDecimals;
        uint256 expectedHealthFactor = (liqLevel * WAD) / debt;

        console2.log("Health factor: %d", healthFactor);
        console2.log("RWA liquidation level: %d", liqLevel / 1e6);
        console2.log("Expected health factor: %d", expectedHealthFactor);

        assertApproxEqRel(
            healthFactor, expectedHealthFactor, 0.01e18, "Health factor for isolated position is incorrect"
        );
    }

    // Test 9: Health factor calculation for cross-collateral position
    function test_HealthFactorForCrossPosition() public {
        uint256 ethAmount = 2 ether; // 2 ETH @ $2500 = $5,000
        uint256 stableAmount = 1000 ether; // 1000 stable @ $1 = $1,000
        uint256 borrowAmount = 3_000e6; // 3,000 USDC

        // Setup cross-collateral position with multiple assets
        vm.deal(bob, ethAmount);
        vm.startPrank(bob);
        wethInstance.deposit{value: ethAmount}();

        stableToken.mint(bob, stableAmount);

        // Create position
        LendefiInstance.createPosition(address(wethInstance), false);
        uint256 positionId = 0;

        // Supply both asset types
        wethInstance.approve(address(LendefiInstance), ethAmount);
        LendefiInstance.supplyCollateral(address(wethInstance), ethAmount, positionId);

        stableToken.approve(address(LendefiInstance), stableAmount);
        LendefiInstance.supplyCollateral(address(stableToken), stableAmount, positionId);

        // Borrow
        LendefiInstance.borrow(positionId, borrowAmount);
        vm.stopPrank();

        // Get health factor
        uint256 healthFactor = LendefiInstance.healthFactor(bob, positionId);

        // Calculate expected liquidation level from ETH using liquidation threshold (85%)
        uint256 ethLiqLevel = (ethAmount * ETH_PRICE * 850 * WAD) / 10 ** 18 / 1000 / 10 ** 8;

        // Calculate expected liquidation level from stable token using liquidation threshold (95%)
        uint256 stableLiqLevel = (stableAmount * STABLE_PRICE * 950 * WAD) / 10 ** 18 / 1000 / 10 ** 8;
        uint256 debt = LendefiInstance.calculateDebtWithInterest(bob, positionId);

        // Calculate expected health factor (combined)
        uint256 expectedHealthFactor = ((ethLiqLevel + stableLiqLevel) * WAD) / debt;
        console2.log("Health factor: %d", healthFactor);
        console2.log("ETH liquidation level: %d", ethLiqLevel / 1e6);
        console2.log("Stable liquidation level: %d", stableLiqLevel / 1e6);
        console2.log("Expected health factor: %d", expectedHealthFactor);
        console2.log("Debt: %d", debt);

        assertEq(healthFactor, expectedHealthFactor, "Health factor for cross-position is incorrect");
    }

    // Test 10: Health factor for inactive position (CLOSED status)
    function test_HealthFactorForClosedPosition() public {
        // Setup position and then close it
        uint256 collateralAmount = 1 ether;

        vm.deal(bob, collateralAmount);
        vm.startPrank(bob);
        wethInstance.deposit{value: collateralAmount}();

        // Create position
        LendefiInstance.createPosition(address(wethInstance), false);
        uint256 positionId = 0;

        // Supply collateral
        wethInstance.approve(address(LendefiInstance), collateralAmount);
        LendefiInstance.supplyCollateral(address(wethInstance), collateralAmount, positionId);

        // Exit position (mark as CLOSED)
        LendefiInstance.exitPosition(positionId);
        vm.stopPrank();

        // Verify position is closed
        IPROTOCOL.UserPosition memory position = LendefiInstance.getUserPosition(bob, positionId);
        assertEq(uint256(position.status), uint256(IPROTOCOL.PositionStatus.CLOSED), "Position should be CLOSED");

        // Check health factor for closed position
        uint256 healthFactor = LendefiInstance.healthFactor(bob, positionId);
        assertEq(healthFactor, type(uint256).max, "Health factor should be max for closed positions");
    }

    // Test 11: Health factor for liquidated position
    function test_HealthFactorForLiquidatedPosition() public {
        uint256 collateralAmount = 1 ether;
        uint256 borrowAmount = 1500e6; // Close to max borrow capacity to make liquidation easy

        // Setup a position that can be liquidated
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
        ethOracle.setPrice(int256(ETH_PRICE / 2)); // Half the price
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

        // Verify position is now liquidated
        IPROTOCOL.UserPosition memory position = LendefiInstance.getUserPosition(bob, positionId);
        assertEq(
            uint256(position.status), uint256(IPROTOCOL.PositionStatus.LIQUIDATED), "Position should be LIQUIDATED"
        );

        // Check health factor for liquidated position
        uint256 healthFactor = LendefiInstance.healthFactor(bob, positionId);
        assertEq(healthFactor, type(uint256).max, "Health factor should be max for liquidated positions");
    }

    // Test 12: Health factor changes after partial repayment
    function test_HealthFactorAfterPartialRepay() public {
        uint256 collateralAmount = 5 ether;
        uint256 borrowAmount = 5_000e6;

        // Setup position
        vm.deal(bob, collateralAmount);
        vm.startPrank(bob);
        wethInstance.deposit{value: collateralAmount}();

        // Create position
        LendefiInstance.createPosition(address(wethInstance), false);
        uint256 positionId = 0;

        // Supply collateral
        wethInstance.approve(address(LendefiInstance), collateralAmount);
        LendefiInstance.supplyCollateral(address(wethInstance), collateralAmount, positionId);

        // Borrow
        LendefiInstance.borrow(positionId, borrowAmount);

        // Get initial health factor
        uint256 initialHealthFactor = LendefiInstance.healthFactor(bob, positionId);

        // Repay half of the debt
        uint256 repayAmount = borrowAmount / 2;
        usdcInstance.mint(bob, repayAmount);
        usdcInstance.approve(address(LendefiInstance), repayAmount);
        LendefiInstance.repay(positionId, repayAmount);
        vm.stopPrank();

        // Get new health factor
        uint256 newHealthFactor = LendefiInstance.healthFactor(bob, positionId);

        // Verify health factor improved (approximately doubled)
        assertTrue(newHealthFactor > initialHealthFactor, "Health factor should improve after partial repay");
        assertEq(newHealthFactor, initialHealthFactor * 2, "Health factor should approximately double"); // 1% tolerance
    }

    // Test 13: Health factor with mixed tier collateral
    // Test 13: Health factor with mixed tier collateral (using compatible tiers)
    function test_HealthFactorWithMixedTierCollateral() public {
        uint256 ethAmount = 2 ether; // CROSS_A tier
        uint256 stableAmount = 1000 ether; // STABLE tier
        uint256 borrowAmount = 3_000e6;

        // Setup position with mixed tier collateral
        vm.deal(bob, ethAmount);
        vm.startPrank(bob);
        wethInstance.deposit{value: ethAmount}();
        stableToken.mint(bob, stableAmount);

        // Create position (non-isolated) with ETH
        LendefiInstance.createPosition(address(wethInstance), false);
        uint256 positionId = 0;

        // Supply ETH collateral (CROSS_A tier)
        wethInstance.approve(address(LendefiInstance), ethAmount);
        LendefiInstance.supplyCollateral(address(wethInstance), ethAmount, positionId);

        // Supply stable token collateral (STABLE tier)
        stableToken.approve(address(LendefiInstance), stableAmount);
        LendefiInstance.supplyCollateral(address(stableToken), stableAmount, positionId);

        // Borrow
        LendefiInstance.borrow(positionId, borrowAmount);
        vm.stopPrank();

        // Get actual health factor
        uint256 healthFactor = LendefiInstance.healthFactor(bob, positionId);

        // Calculate expected health factor using liquidation thresholds
        // ETH: 85% liquidation threshold
        uint256 ethLiqLevel = (ethAmount * ETH_PRICE * 850 * WAD) / 10 ** 18 / 1000 / 10 ** 8;
        // Stable: 95% liquidation threshold
        uint256 stableLiqLevel = (stableAmount * STABLE_PRICE * 950 * WAD) / 10 ** 18 / 1000 / 10 ** 8;
        uint256 debt = LendefiInstance.calculateDebtWithInterest(bob, positionId);

        uint256 expectedHealthFactor = ((ethLiqLevel + stableLiqLevel) * WAD) / debt;

        console2.log("Health factor: %d", healthFactor);
        console2.log("ETH liquidation level: %d", ethLiqLevel / 1e6);
        console2.log("Stable liquidation level: %d", stableLiqLevel / 1e6);
        console2.log("Total liquidation level: %d", (ethLiqLevel + stableLiqLevel) / 1e6);
        console2.log("Expected health factor: %d", expectedHealthFactor);

        assertApproxEqRel(
            healthFactor,
            expectedHealthFactor,
            0.01e18,
            "Health factor should use each asset's individual liquidation threshold"
        );
    }
}
