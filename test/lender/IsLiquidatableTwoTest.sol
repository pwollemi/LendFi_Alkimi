// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../BasicDeploy.sol";
import {console2} from "forge-std/console2.sol";
import {IPROTOCOL} from "../../contracts/interfaces/IProtocol.sol";
import {Lendefi} from "../../contracts/lender/Lendefi.sol";
import {WETHPriceConsumerV3} from "../../contracts/mock/WETHOracle.sol";
import {StablePriceConsumerV3} from "../../contracts/mock/StableOracle.sol";
import {RWAPriceConsumerV3} from "../../contracts/mock/RWAOracle.sol";
import {MockRWA} from "../../contracts/mock/MockRWA.sol";

contract IsLiquidatableComprehensiveTest is BasicDeploy {
    WETHPriceConsumerV3 internal wethOracleInstance;
    StablePriceConsumerV3 internal stableOracleInstance;
    RWAPriceConsumerV3 internal rwaOracleInstance;
    RWAPriceConsumerV3 internal crossBOracleInstance;

    MockRWA internal stableToken;
    MockRWA internal rwaToken;
    MockRWA internal crossBToken;

    uint256 constant INITIAL_LIQUIDITY = 1_000_000e6; // 1M USDC
    uint256 constant ETH_PRICE = 2500e8; // $2500 per ETH

    function setUp() public {
        // Use deployCompleteWithOracle() instead of deployComplete()
        deployCompleteWithOracle();

        // TGE setup
        vm.prank(guardian);
        tokenInstance.initializeTGE(address(ecoInstance), address(treasuryInstance));
        vm.warp(block.timestamp + 90 days);

        // Deploy tokens
        wethInstance = new WETH9();
        stableToken = new MockRWA("USDT", "USDT");
        rwaToken = new MockRWA("Ondo Finance", "ONDO");
        crossBToken = new MockRWA("Cross B Token", "CROSSB");

        // Deploy oracles
        wethOracleInstance = new WETHPriceConsumerV3();
        stableOracleInstance = new StablePriceConsumerV3();
        rwaOracleInstance = new RWAPriceConsumerV3();
        crossBOracleInstance = new RWAPriceConsumerV3();

        // Set prices
        wethOracleInstance.setPrice(int256(ETH_PRICE)); // $2500 per ETH
        stableOracleInstance.setPrice(1e8); // $1 per stable
        rwaOracleInstance.setPrice(1000e8); // $1000 per RWA token
        crossBOracleInstance.setPrice(500e8); // $500 per CROSSB token

        // Register oracles with Oracle module
        vm.startPrank(address(timelockInstance));
        oracleInstance.addOracle(address(wethInstance), address(wethOracleInstance), 8);
        oracleInstance.setPrimaryOracle(address(wethInstance), address(wethOracleInstance));

        // Register USDC oracle
        oracleInstance.addOracle(address(usdcInstance), address(stableOracleInstance), 8);
        oracleInstance.setPrimaryOracle(address(usdcInstance), address(stableOracleInstance));

        // Register other token oracles
        oracleInstance.addOracle(address(stableToken), address(stableOracleInstance), 8);
        oracleInstance.setPrimaryOracle(address(stableToken), address(stableOracleInstance));

        oracleInstance.addOracle(address(rwaToken), address(rwaOracleInstance), 8);
        oracleInstance.setPrimaryOracle(address(rwaToken), address(rwaOracleInstance));

        oracleInstance.addOracle(address(crossBToken), address(crossBOracleInstance), 8);
        oracleInstance.setPrimaryOracle(address(crossBToken), address(crossBOracleInstance));
        vm.stopPrank();

        // Setup roles
        vm.prank(guardian);
        ecoInstance.grantRole(REWARDER_ROLE, address(LendefiInstance));

        _setupAssets();
        _addLiquidity(INITIAL_LIQUIDITY);
    }

    function _setupAssets() internal {
        vm.startPrank(address(timelockInstance));

        // Configure WETH as CROSS_A tier
        LendefiInstance.updateAssetConfig(
            address(wethInstance),
            address(wethOracleInstance),
            8, // Oracle decimals
            18, // Asset decimals
            1, // Active
            800, // 80% borrow threshold
            850, // 85% liquidation threshold
            1_000_000 ether, // Supply limit
            IPROTOCOL.CollateralTier.CROSS_A,
            0 // No isolation debt cap
        );

        // Configure Stable token as STABLE tier
        LendefiInstance.updateAssetConfig(
            address(stableToken),
            address(stableOracleInstance),
            8, // Oracle decimals
            18, // Asset decimals
            1, // Active
            900, // 90% borrow threshold
            950, // 95% liquidation threshold
            1_000_000 ether, // Supply limit
            IPROTOCOL.CollateralTier.STABLE,
            0 // No isolation debt cap
        );

        // Configure RWA token as ISOLATED tier
        LendefiInstance.updateAssetConfig(
            address(rwaToken),
            address(rwaOracleInstance),
            8, // Oracle decimals
            18, // Asset decimals
            1, // Active
            650, // 65% borrow threshold
            750, // 75% liquidation threshold
            1_000_000 ether, // Supply limit
            IPROTOCOL.CollateralTier.ISOLATED,
            100_000e6 // Isolation debt cap
        );

        // Configure CROSS_B token
        LendefiInstance.updateAssetConfig(
            address(crossBToken),
            address(crossBOracleInstance),
            8, // Oracle decimals
            18, // Asset decimals
            1, // Active
            700, // 70% borrow threshold
            800, // 80% liquidation threshold
            1_000_000 ether, // Supply limit
            IPROTOCOL.CollateralTier.CROSS_B,
            0 // No isolation debt cap
        );

        vm.stopPrank();
    }

    function _addLiquidity(uint256 amount) internal {
        usdcInstance.mint(guardian, amount);
        vm.startPrank(guardian);
        usdcInstance.approve(address(LendefiInstance), amount);
        LendefiInstance.supplyLiquidity(amount);
        vm.stopPrank();
    }

    function _createPositionWithCollateral(address user, uint256 collateralEth) internal returns (uint256 positionId) {
        vm.startPrank(user);

        // Create position
        LendefiInstance.createPosition(address(wethInstance), false);
        positionId = LendefiInstance.getUserPositionsCount(user) - 1;

        // Provide ETH collateral
        vm.deal(user, collateralEth);
        wethInstance.deposit{value: collateralEth}();
        wethInstance.approve(address(LendefiInstance), collateralEth);
        LendefiInstance.supplyCollateral(address(wethInstance), collateralEth, positionId);

        vm.stopPrank();
        return positionId;
    }

    function _createPositionWithAsset(address user, address asset, uint256 amount, bool isIsolated)
        internal
        returns (uint256 positionId)
    {
        vm.startPrank(user);

        // Create position
        LendefiInstance.createPosition(asset, isIsolated);
        positionId = LendefiInstance.getUserPositionsCount(user) - 1;

        // Mint and provide collateral
        if (asset == address(stableToken) || asset == address(rwaToken) || asset == address(crossBToken)) {
            MockRWA(asset).mint(user, amount);
            MockRWA(asset).approve(address(LendefiInstance), amount);
        } else if (asset == address(wethInstance)) {
            vm.deal(user, amount);
            wethInstance.deposit{value: amount}();
            wethInstance.approve(address(LendefiInstance), amount);
        }

        LendefiInstance.supplyCollateral(asset, amount, positionId);

        vm.stopPrank();
        return positionId;
    }

    function _borrowUSDC(address user, uint256 positionId, uint256 amount) internal {
        vm.startPrank(user);
        LendefiInstance.borrow(positionId, amount);
        vm.stopPrank();
    }

    // Test 1: Zero debt position should never be liquidatable
    function test_IsLiquidatable_ZeroDebt() public {
        // Create a position with collateral but no debt
        uint256 positionId = _createPositionWithCollateral(alice, 1 ether);

        // Check isLiquidatable - should be false with no debt
        bool liquidatable = LendefiInstance.isLiquidatable(alice, positionId);
        assertFalse(liquidatable, "Position with zero debt should not be liquidatable");
    }

    // Test 2: Well-collateralized position should not be liquidatable
    function test_IsLiquidatable_SafePosition() public {
        // Create a position with 10 ETH collateral (worth $25,000)
        uint256 positionId = _createPositionWithCollateral(alice, 10 ether);

        // For CROSS_A tier with 80% borrow threshold, credit limit is $20,000
        uint256 borrowAmount = 15_000e6; // $15,000 - well under the limit
        _borrowUSDC(alice, positionId, borrowAmount);

        // Check isLiquidatable - should be false (safe position)
        bool liquidatable = LendefiInstance.isLiquidatable(alice, positionId);
        assertFalse(liquidatable, "Position with debt under credit limit should not be liquidatable");

        // Get position details for logging
        uint256 debt = LendefiInstance.calculateDebtWithInterest(alice, positionId);
        uint256 creditLimit = LendefiInstance.calculateCreditLimit(alice, positionId);

        console2.log("Debt for safe position:", debt);
        console2.log("Credit limit for safe position:", creditLimit);
        console2.log("Safety margin:", creditLimit - debt);
    }

    // Test 3: Position becomes liquidatable after interest accrual
    function test_IsLiquidatable_BorderlinePosition() public {
        // Create a position with 1 ETH collateral (worth $2,500)
        uint256 positionId = _createPositionWithCollateral(alice, 1 ether);

        // For CROSS_A tier with 80% borrow threshold, credit limit is $2,000
        uint256 borrowAmount = 1_999e6; // $1,999 - just below the limit
        _borrowUSDC(alice, positionId, borrowAmount);

        // Should not be liquidatable at this point
        assertFalse(
            LendefiInstance.isLiquidatable(alice, positionId),
            "Position just below credit limit should not be liquidatable"
        );

        // Time passes, interest accrues
        vm.roll(block.number + 10000); // Some blocks pass
        vm.warp(block.timestamp + 400 days); // 400 days pass

        // Update the oracle after time warp to prevent timeout
        // The oracle must be updated with a fresh timestamp after time warping
        wethOracleInstance.setPrice(int256(ETH_PRICE)); // Same price, but updated timestamp

        // Now with accrued interest, it might be liquidatable
        bool liquidatable = LendefiInstance.isLiquidatable(alice, positionId);

        // Get position details for logging
        uint256 debt = LendefiInstance.calculateDebtWithInterest(alice, positionId);
        uint256 liqLevel = LendefiInstance.calculateCollateralValue(alice, positionId) * 850 / 1000;

        console2.log("Debt after interest accrual:", debt);
        console2.log("Liquidation threshold:", liqLevel);

        if (debt > liqLevel) {
            assertTrue(liquidatable, "Position should be liquidatable after interest accrual");
        } else {
            assertFalse(liquidatable, "Position still not liquidatable after interest accrual");
        }
    }

    // Test 4: Position becomes liquidatable after price drop
    function test_IsLiquidatable_PriceDropLiquidation() public {
        // Create a position with 1 ETH collateral (worth $2,500)
        uint256 positionId = _createPositionWithCollateral(alice, 1 ether);

        // For CROSS_A tier with 80% borrow threshold, credit limit is $2,000
        uint256 borrowAmount = 1_800e6; // $1,800 - safe initially
        _borrowUSDC(alice, positionId, borrowAmount);

        // Initially not liquidatable
        assertFalse(LendefiInstance.isLiquidatable(alice, positionId), "Position should not be liquidatable initially");

        // ETH price drops 20% from $2500 to $2000
        wethOracleInstance.setPrice(2000e8);

        // Check if liquidatable now
        bool liquidatable = LendefiInstance.isLiquidatable(alice, positionId);

        // Get updated position details
        uint256 debt = LendefiInstance.calculateDebtWithInterest(alice, positionId);
        uint256 creditLimit = LendefiInstance.calculateCreditLimit(alice, positionId);

        console2.log("Debt after price drop:", debt);
        console2.log("Credit limit after price drop:", creditLimit);

        // Now credit limit should be $1,600 (80% of $2,000), which is less than $1,800 debt
        assertTrue(liquidatable, "Position should be liquidatable after price drop");
        assertGt(debt, creditLimit, "Debt should exceed credit limit after price drop");
    }

    // Test 5: Position exactly at liquidation threshold
    function test_IsLiquidatable_ExactlyAtCreditLimit() public {
        // Create a position with 1 ETH collateral (worth $2,500)
        uint256 positionId = _createPositionWithCollateral(alice, 1 ether);

        // For CROSS_A tier with 80% borrow threshold, credit limit is $2,000
        uint256 borrowAmount = 1_900e6; // $1,900 - within the limit
        _borrowUSDC(alice, positionId, borrowAmount);
        bool liquidatable = LendefiInstance.isLiquidatable(alice, positionId);
        assertFalse(liquidatable, "Position should not be liquidatable initially");

        // Drop ETH price to make position liquidatable
        wethOracleInstance.setPrice(2250e8); // Drop from $2500 to $2250
        liquidatable = LendefiInstance.isLiquidatable(alice, positionId);
        assertFalse(liquidatable, "Position should not be liquidatable after price drop");
        uint256 healthFactorValue = LendefiInstance.healthFactor(alice, positionId);
        console2.log("Health factor at 2250:", healthFactorValue);
        console2.log("Liquidatable at 2250:", liquidatable);

        // Should be liquidatable after price drop
        // For CROSS_A tier with 80% borrow threshold, credit limit is exactly $2,000, and an 85% liquidation threshold
        wethOracleInstance.setPrice(2225e8); // Which means that with 1900 borrowed, the position is liquidatable at 2235 (1900/85*100=2235)
        healthFactorValue = LendefiInstance.healthFactor(alice, positionId);
        assertTrue(healthFactorValue < 1e6, "Health factor should be less than 1");
        liquidatable = LendefiInstance.isLiquidatable(alice, positionId);
        assertTrue(liquidatable, "Position should be liquidatable after price drop");
        console2.log("Health factor at 2225:", healthFactorValue);
        console2.log("Liquidatable at 2225:", liquidatable);

        wethOracleInstance.setPrice(2300e8); // Set price back above liquidation zone
        liquidatable = LendefiInstance.isLiquidatable(alice, positionId);
        healthFactorValue = LendefiInstance.healthFactor(alice, positionId);
        assertFalse(liquidatable, "Position should not be liquidatable after price drop");
        assertTrue(healthFactorValue > 1e6, "Health factor should be greater than 1");
        console2.log("Health factor at 2300:", healthFactorValue);
        console2.log("Liquidatable at 2300:", liquidatable);
    }

    // Test 6: Position becomes safe after partial repayment
    function test_IsLiquidatable_AfterPartialRepayment() public {
        // Create a position with 1 ETH collateral (worth $2,500)
        uint256 positionId = _createPositionWithCollateral(alice, 1 ether);

        // For CROSS_A tier with 80% borrow threshold, credit limit is $2,000
        uint256 borrowAmount = 1_900e6; // $1,900 - within the limit
        _borrowUSDC(alice, positionId, borrowAmount);

        // Not liquidatable yet
        assertFalse(LendefiInstance.isLiquidatable(alice, positionId), "Position should not be liquidatable initially");

        // Drop ETH price to make position liquidatable
        wethOracleInstance.setPrice(2100e8); // Drop from $2500 to $2100

        // Credit limit is now $2100 * 0.8 = $1,680, which is less than $1,900 borrowed

        // Should be liquidatable after price drop
        bool liquidatable = LendefiInstance.isLiquidatable(alice, positionId);
        assertTrue(liquidatable, "Position should be liquidatable after price drop");

        // Now partially repay the loan
        usdcInstance.mint(alice, 300e6); // Give Alice some USDC
        vm.startPrank(alice);
        usdcInstance.approve(address(LendefiInstance), 300e6);
        LendefiInstance.repay(positionId, 300e6); // Repay $300
        vm.stopPrank();

        // Check if still liquidatable
        liquidatable = LendefiInstance.isLiquidatable(alice, positionId);

        // Get updated position details
        uint256 debt = LendefiInstance.calculateDebtWithInterest(alice, positionId);
        uint256 creditLimit = LendefiInstance.calculateCreditLimit(alice, positionId);

        console2.log("Debt after partial repayment:", debt);
        console2.log("Credit limit:", creditLimit);

        // Now the position should be safe ($1,900 - $300 = $1,600 debt, which is less than $1,680 credit limit)
        assertFalse(liquidatable, "Position should not be liquidatable after partial repayment");
        assertLe(debt, creditLimit, "Debt should be less than or equal to credit limit after repayment");
    }

    // Test 8: Multi-collateral position liquidation check
    function test_IsLiquidatable_MultipleCollateralAssets() public {
        // Create position with ETH
        vm.startPrank(alice);
        LendefiInstance.createPosition(address(wethInstance), false);
        uint256 positionId = LendefiInstance.getUserPositionsCount(alice) - 1;

        // Add ETH collateral
        vm.deal(alice, 1 ether);
        wethInstance.deposit{value: 1 ether}();
        wethInstance.approve(address(LendefiInstance), 1 ether);
        LendefiInstance.supplyCollateral(address(wethInstance), 1 ether, positionId);

        // Add CROSSB collateral
        crossBToken.mint(alice, 2e18);
        crossBToken.approve(address(LendefiInstance), 2e18);
        LendefiInstance.supplyCollateral(address(crossBToken), 2e18, positionId);
        vm.stopPrank();

        // Calculate total collateral value
        // ETH: 1 ETH * $2500 = $2500
        // CROSSB: 2 tokens * $500 = $1000
        // Total: $3500
        // With CROSS_A tier (ETH at 80%) and CROSS_B tier (70%), weighted credit limit should be calculated

        // Borrow close to the limit
        _borrowUSDC(alice, positionId, 2600e6);

        // Initially not liquidatable
        assertFalse(
            LendefiInstance.isLiquidatable(alice, positionId),
            "Multi-collateral position should not be liquidatable initially"
        );

        // Drop ETH price by 10%
        wethOracleInstance.setPrice(2250e8); // $2250 per ETH

        // Position may still be safe
        bool liquidatable = LendefiInstance.isLiquidatable(alice, positionId);
        uint256 healthFactorValue = LendefiInstance.healthFactor(alice, positionId);
        console2.log("Health factor after ETH price drop:", healthFactorValue);

        // Now drop both asset prices
        wethOracleInstance.setPrice(2250e8); // $2250 per ETH (-10%)
        crossBOracleInstance.setPrice(450e8); // $450 per CROSSB token (-10%)

        healthFactorValue = LendefiInstance.healthFactor(alice, positionId);
        liquidatable = LendefiInstance.isLiquidatable(alice, positionId);
        console2.log("Health factor after both price drops:", healthFactorValue);
        console2.log("Liquidatable after both price drops:", liquidatable);

        if (healthFactorValue < 1e6) {
            assertTrue(liquidatable, "Position should be liquidatable after both prices drop");
        } else {
            // If not liquidatable, drop prices more
            wethOracleInstance.setPrice(2000e8); // $2000 per ETH (-20%)
            crossBOracleInstance.setPrice(400e8); // $400 per CROSSB token (-20%)

            healthFactorValue = LendefiInstance.healthFactor(alice, positionId);
            liquidatable = LendefiInstance.isLiquidatable(alice, positionId);
            console2.log("Health factor after larger price drops:", healthFactorValue);
            console2.log("Liquidatable after larger price drops:", liquidatable);
            assertTrue(liquidatable, "Position should be liquidatable after larger price drops");
            assertTrue(healthFactorValue < 1e6, "Health factor should be less than 1e6");
        }
    }

    // Test 9: Fuzz test for health factor calculation and liquidation threshold
    function testFuzz_IsLiquidatable_HealthFactorThreshold(uint256 pricePercent) public {
        // Bound the price percentage between 70% and 100% of the original
        pricePercent = bound(pricePercent, 70, 100);

        // Create position with 1 ETH
        uint256 positionId = _createPositionWithCollateral(alice, 1 ether);

        // Borrow 1900e6 (below the credit limit)
        _borrowUSDC(alice, positionId, 1900e6);

        // Calculate new price based on percentage
        uint256 newPrice = (ETH_PRICE * pricePercent) / 100;
        wethOracleInstance.setPrice(int256(newPrice));

        // Check health factor and liquidation status
        uint256 healthFactorValue = LendefiInstance.healthFactor(alice, positionId);
        bool liquidatable = LendefiInstance.isLiquidatable(alice, positionId);

        // Log values for analysis
        console2.log("Price percent:", pricePercent);
        console2.log("New price:", newPrice);
        console2.log("Health factor:", healthFactorValue);
        console2.log("Liquidatable:", liquidatable);
    }
}
