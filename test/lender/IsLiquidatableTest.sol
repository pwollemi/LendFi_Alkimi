// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../BasicDeploy.sol";
import {console2} from "forge-std/console2.sol";
import {IPROTOCOL} from "../../contracts/interfaces/IProtocol.sol";
import {Lendefi} from "../../contracts/lender/Lendefi.sol";
import {WETHPriceConsumerV3} from "../../contracts/mock/WETHOracle.sol";
import {StablePriceConsumerV3} from "../../contracts/mock/StableOracle.sol";

contract IsLiquidatableTest is BasicDeploy {
    WETHPriceConsumerV3 internal wethOracleInstance;
    StablePriceConsumerV3 internal stableOracleInstance;

    uint256 constant INITIAL_LIQUIDITY = 1_000_000e6; // 1M USDC
    int256 constant ETH_PRICE = 2500e8; // $2500 per ETH

    function setUp() public {
        deployComplete();

        // TGE setup
        vm.prank(guardian);
        tokenInstance.initializeTGE(address(ecoInstance), address(treasuryInstance));
        vm.warp(block.timestamp + 90 days);

        // Deploy mock tokens
        usdcInstance = new USDC();
        wethInstance = new WETH9();

        // Deploy oracles
        wethOracleInstance = new WETHPriceConsumerV3();
        stableOracleInstance = new StablePriceConsumerV3();

        // Set prices
        wethOracleInstance.setPrice(ETH_PRICE); // $2500 per ETH
        stableOracleInstance.setPrice(1e8); // $1 per stable

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

    function _borrowUSDC(address user, uint256 positionId, uint256 amount) internal {
        vm.startPrank(user);
        LendefiInstance.borrow(positionId, amount);
        vm.stopPrank();
    }

    function test_IsLiquidatable_ZeroDebt() public {
        // Create a position with collateral but no debt
        uint256 positionId = _createPositionWithCollateral(alice, 1 ether);

        // Check isLiquidatable - should be false with no debt
        bool liquidatable = LendefiInstance.isLiquidatable(alice, positionId);
        assertFalse(liquidatable, "Position with zero debt should not be liquidatable");
    }

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
        vm.warp(block.timestamp + 30 days); // 30 days pass

        // Update the oracle after time warp to prevent timeout
        // The oracle must be updated with a fresh timestamp after time warping
        wethOracleInstance.setPrice(ETH_PRICE); // Same price, but updated timestamp

        // Now with accrued interest, it might be liquidatable
        bool liquidatable = LendefiInstance.isLiquidatable(alice, positionId);

        // Get position details for logging
        uint256 debt = LendefiInstance.calculateDebtWithInterest(alice, positionId);
        uint256 creditLimit = LendefiInstance.calculateCreditLimit(alice, positionId);

        console2.log("Debt after interest accrual:", debt);
        console2.log("Credit limit:", creditLimit);
        console2.log("Difference:", debt > creditLimit ? debt - creditLimit : creditLimit - debt);

        if (debt > creditLimit) {
            assertTrue(liquidatable, "Position should be liquidatable after interest accrual");
        } else {
            assertFalse(liquidatable, "Position still not liquidatable after interest accrual");
        }
    }

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

    function test_IsLiquidatable_ExactlyAtCreditLimit() public {
        // Create a position with 1 ETH collateral (worth $2,500)
        uint256 positionId = _createPositionWithCollateral(alice, 1 ether);

        // For CROSS_A tier with 80% borrow threshold, credit limit is exactly $2,000
        uint256 borrowAmount = 2_000e6; // $2,000 - exactly at the limit
        _borrowUSDC(alice, positionId, borrowAmount);

        // Check if exactly at credit limit is liquidatable
        bool liquidatable = LendefiInstance.isLiquidatable(alice, positionId);

        // Get position details
        uint256 debt = LendefiInstance.calculateDebtWithInterest(alice, positionId);
        uint256 creditLimit = LendefiInstance.calculateCreditLimit(alice, positionId);

        console2.log("Debt at credit limit:", debt);
        console2.log("Credit limit:", creditLimit);

        // The isLiquidatable function checks if debt >= collateralValue
        // So if they're exactly equal, it should be liquidatable
        assertTrue(liquidatable, "Position exactly at credit limit should be liquidatable");
    }

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
}
