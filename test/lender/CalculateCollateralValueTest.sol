// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../BasicDeploy.sol";
import {console2} from "forge-std/console2.sol";
import {IPROTOCOL} from "../../contracts/interfaces/IProtocol.sol";
import {MockPriceOracle} from "../../contracts/mock/MockPriceOracle.sol";
import {MockRWA} from "../../contracts/mock/MockRWA.sol";
import {Lendefi} from "../../contracts/lender/Lendefi.sol";

contract CalculateCollateralValueTest is BasicDeploy {
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
        deployCompleteWithOracle();

        // TGE setup
        vm.prank(guardian);
        tokenInstance.initializeTGE(address(ecoInstance), address(treasuryInstance));

        // Deploy mock tokens (USDC already deployed by deployCompleteWithOracle())
        // DO NOT redeploy USDC - it causes issues
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

        // Register oracles with Oracle module - use guardian for registration
        vm.startPrank(address(timelockInstance));
        oracleInstance.addOracle(address(wethInstance), address(ethOracle), 8);
        oracleInstance.setPrimaryOracle(address(wethInstance), address(ethOracle));

        oracleInstance.addOracle(address(rwaToken), address(rwaOracle), 8);
        oracleInstance.setPrimaryOracle(address(rwaToken), address(rwaOracle));

        oracleInstance.addOracle(address(stableToken), address(stableOracle), 8);
        oracleInstance.setPrimaryOracle(address(stableToken), address(stableOracle));

        // Set minimum required oracles to 1 to avoid NotEnoughOracles errors
        oracleInstance.updateMinimumOracles(1);
        vm.stopPrank();

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
        // Use the USDC instance that was deployed by deployCompleteWithOracle()
        // Mint USDC to alice
        usdcInstance.mint(alice, INITIAL_LIQUIDITY);

        vm.startPrank(alice);
        // Approve USDC spending
        usdcInstance.approve(address(LendefiInstance), INITIAL_LIQUIDITY);
        // Supply liquidity
        LendefiInstance.supplyLiquidity(INITIAL_LIQUIDITY);
        vm.stopPrank();
    }

    // Test 1: Calculate collateral value for isolated position
    function test_CalculateCollateralValueIsolated() public {
        // Setup - create isolated position with RWA token
        uint256 collateralAmount = 10 ether; // 10 RWA tokens

        // Mint RWA tokens to bob
        rwaToken.mint(bob, collateralAmount);

        vm.startPrank(bob);

        // Create isolated position with RWA token
        LendefiInstance.createPosition(address(rwaToken), true);
        uint256 positionId = 0;

        // Supply collateral
        rwaToken.approve(address(LendefiInstance), collateralAmount);
        LendefiInstance.supplyCollateral(address(rwaToken), collateralAmount, positionId);
        vm.stopPrank();

        // Calculate expected value
        // 10 RWA @ $1000 = $10,000 (scaled by WAD)
        uint256 expectedValue = (collateralAmount * RWA_PRICE * WAD) / 10 ** 18 / 10 ** 8;

        // Get actual collateral value
        uint256 actualValue = LendefiInstance.calculateCollateralValue(bob, positionId);

        // Verify calculation
        assertEq(actualValue, expectedValue, "Incorrect collateral value for isolated position");
        assertEq(actualValue, 10_000e6, "Value should be 10,000 USD (scaled by WAD)");
    }

    // Test 2: Calculate collateral value for cross-collateral position
    function test_CalculateCollateralValueCrossCollateral() public {
        // Setup - create cross-collateral position with multiple assets
        uint256 ethAmount = 2 ether; // 2 ETH
        uint256 stableAmount = 1000 ether; // 1000 stable tokens

        vm.deal(bob, ethAmount);
        vm.startPrank(bob);
        wethInstance.deposit{value: ethAmount}();
        stableToken.mint(bob, stableAmount);

        // Create non-isolated position
        LendefiInstance.createPosition(address(wethInstance), false);
        uint256 positionId = 0;

        // Supply multiple collateral types
        wethInstance.approve(address(LendefiInstance), ethAmount);
        LendefiInstance.supplyCollateral(address(wethInstance), ethAmount, positionId);

        stableToken.approve(address(LendefiInstance), stableAmount);
        LendefiInstance.supplyCollateral(address(stableToken), stableAmount, positionId);
        vm.stopPrank();

        // Calculate expected value
        // 2 ETH @ $2500 = $5,000
        uint256 ethValue = (ethAmount * ETH_PRICE * WAD) / 10 ** 18 / 10 ** 8;
        // 1000 stable tokens @ $1 = $1,000
        uint256 stableValue = (stableAmount * STABLE_PRICE * WAD) / 10 ** 18 / 10 ** 8;
        uint256 expectedTotalValue = ethValue + stableValue; // $6,000 in total

        // Get actual collateral value
        uint256 actualValue = LendefiInstance.calculateCollateralValue(bob, positionId);

        // Verify calculation
        assertEq(actualValue, expectedTotalValue, "Incorrect collateral value for cross-collateral position");
        assertEq(actualValue, 6_000e6, "Value should be 6,000 USD (scaled by WAD)");
    }

    // Test 3: Calculate collateral value when some assets have zero amounts
    function test_CalculateCollateralValueWithZeroAmounts() public {
        // Setup - create position with some assets having zero amount
        uint256 ethAmount = 3 ether; // 3 ETH

        vm.deal(bob, ethAmount);
        vm.startPrank(bob);
        wethInstance.deposit{value: ethAmount}();

        // Also mint a small amount of stable token
        stableToken.mint(bob, 100 ether);

        // Create position
        LendefiInstance.createPosition(address(wethInstance), false);
        uint256 positionId = 0;

        // Supply ETH collateral
        wethInstance.approve(address(LendefiInstance), ethAmount);
        LendefiInstance.supplyCollateral(address(wethInstance), ethAmount, positionId);

        // Supply stable token and then withdraw it all (to test zero amount case)
        stableToken.approve(address(LendefiInstance), 100 ether);
        LendefiInstance.supplyCollateral(address(stableToken), 100 ether, positionId);
        LendefiInstance.withdrawCollateral(address(stableToken), 100 ether, positionId);
        vm.stopPrank();

        // Verify stable token amount is zero
        uint256 stableAmount = LendefiInstance.getUserCollateralAmount(bob, positionId, address(stableToken));
        assertEq(stableAmount, 0, "Stable token amount should be zero");

        // Calculate expected value - only ETH should be counted
        uint256 expectedValue = (ethAmount * ETH_PRICE * WAD) / 10 ** 18 / 10 ** 8;

        // Get actual collateral value
        uint256 actualValue = LendefiInstance.calculateCollateralValue(bob, positionId);

        // Verify calculation
        assertEq(actualValue, expectedValue, "Should only count non-zero collateral amounts");
        assertEq(actualValue, 7_500e6, "Value should be 7,500 USD (scaled by WAD)");
    }

    // Test 4: Calculate collateral value for empty position
    function test_CalculateCollateralValueEmptyPosition() public {
        // Create empty position
        vm.prank(bob);
        LendefiInstance.createPosition(address(wethInstance), false);
        uint256 positionId = 0;

        // Get collateral value
        uint256 collateralValue = LendefiInstance.calculateCollateralValue(bob, positionId);

        // Verify value is zero
        assertEq(collateralValue, 0, "Collateral value should be zero for empty position");
    }

    // Test 5: Calculate collateral value after price changes
    function test_CalculateCollateralValueAfterPriceChange() public {
        // Setup - create position with ETH collateral
        uint256 ethAmount = 2 ether; // 2 ETH

        vm.deal(bob, ethAmount);
        vm.startPrank(bob);
        wethInstance.deposit{value: ethAmount}();

        // Create position
        LendefiInstance.createPosition(address(wethInstance), false);
        uint256 positionId = 0;

        // Supply collateral
        wethInstance.approve(address(LendefiInstance), ethAmount);
        LendefiInstance.supplyCollateral(address(wethInstance), ethAmount, positionId);
        vm.stopPrank();

        // Calculate initial value
        uint256 initialValue = LendefiInstance.calculateCollateralValue(bob, positionId);
        assertEq(initialValue, 5_000e6, "Initial value should be 5,000 USD");

        // Update ETH price to $3000
        uint256 newETHPrice = 3000e8;
        ethOracle.setPrice(int256(newETHPrice));
        ethOracle.setTimestamp(block.timestamp); // Set fresh timestamp

        // Calculate new expected value
        uint256 expectedNewValue = (ethAmount * newETHPrice * WAD) / 10 ** 18 / 10 ** 8;

        // Get new collateral value
        uint256 newValue = LendefiInstance.calculateCollateralValue(bob, positionId);

        // Verify calculation reflects new price
        assertEq(newValue, expectedNewValue, "Collateral value should reflect updated price");
        assertEq(newValue, 6_000e6, "Value should be 6,000 USD after price increase");
    }

    // Test 6: Calculate value for multiple positions of the same user
    function test_CalculateCollateralValueMultiplePositions() public {
        // Setup - create two positions for the same user with different assets
        uint256 ethAmount = 1 ether;
        uint256 rwaAmount = 5 ether;

        // Prepare assets
        vm.deal(bob, ethAmount);
        vm.startPrank(bob);
        wethInstance.deposit{value: ethAmount}();
        rwaToken.mint(bob, rwaAmount);

        // Create first position with ETH
        LendefiInstance.createPosition(address(wethInstance), false);
        uint256 position1 = 0;
        wethInstance.approve(address(LendefiInstance), ethAmount);
        LendefiInstance.supplyCollateral(address(wethInstance), ethAmount, position1);

        // Create second position with RWA (isolated)
        LendefiInstance.createPosition(address(rwaToken), true);
        uint256 position2 = 1;
        rwaToken.approve(address(LendefiInstance), rwaAmount);
        LendefiInstance.supplyCollateral(address(rwaToken), rwaAmount, position2);
        vm.stopPrank();

        // Calculate expected values
        uint256 expectedValue1 = (ethAmount * ETH_PRICE * WAD) / 10 ** 18 / 10 ** 8;
        uint256 expectedValue2 = (rwaAmount * RWA_PRICE * WAD) / 10 ** 18 / 10 ** 8;

        // Get actual values
        uint256 value1 = LendefiInstance.calculateCollateralValue(bob, position1);
        uint256 value2 = LendefiInstance.calculateCollateralValue(bob, position2);

        // Verify calculations
        assertEq(value1, 2_500e6, "First position value should be 2,500 USD");
        assertEq(value2, 5_000e6, "Second position value should be 5,000 USD");
        assertEq(value1, expectedValue1, "Incorrect collateral value for first position");
        assertEq(value2, expectedValue2, "Incorrect collateral value for second position");
    }

    // Test 7: Invalid position reverts
    function test_CalculateCollateralValueInvalidPosition() public {
        // Try to calculate value for non-existent position
        vm.expectRevert(abi.encodeWithSelector(IPROTOCOL.InvalidPosition.selector, bob, 999));
        LendefiInstance.calculateCollateralValue(bob, 999);
    }

    // Test 8: Collateral value after partial withdrawal
    function test_CalculateCollateralValueAfterPartialWithdrawal() public {
        // Setup - create position with ETH collateral
        uint256 initialAmount = 4 ether;
        uint256 withdrawAmount = 1 ether;

        vm.deal(bob, initialAmount);
        vm.startPrank(bob);
        wethInstance.deposit{value: initialAmount}();

        // Create position
        LendefiInstance.createPosition(address(wethInstance), false);
        uint256 positionId = 0;

        // Supply collateral
        wethInstance.approve(address(LendefiInstance), initialAmount);
        LendefiInstance.supplyCollateral(address(wethInstance), initialAmount, positionId);

        // Get initial value
        uint256 initialValue = LendefiInstance.calculateCollateralValue(bob, positionId);
        assertEq(initialValue, 10_000e6, "Initial value should be 10,000 USD");

        // Withdraw part of collateral
        LendefiInstance.withdrawCollateral(address(wethInstance), withdrawAmount, positionId);
        vm.stopPrank();

        // Calculate expected new value
        uint256 remainingAmount = initialAmount - withdrawAmount;
        uint256 expectedNewValue = (remainingAmount * ETH_PRICE * WAD) / 10 ** 18 / 10 ** 8;

        // Get actual new value
        uint256 newValue = LendefiInstance.calculateCollateralValue(bob, positionId);

        // Verify calculation
        assertEq(newValue, expectedNewValue, "Value should be reduced after partial withdrawal");
        assertEq(newValue, 7_500e6, "Value should be 7,500 USD after withdrawal");
    }
}
