// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../BasicDeploy.sol";
import {IPROTOCOL} from "../../contracts/interfaces/IProtocol.sol";
import {Lendefi} from "../../contracts/lender/Lendefi.sol";
import {WETHPriceConsumerV3} from "../../contracts/mock/WETHOracle.sol";

contract UpdateTierParametersTest is BasicDeploy {
    // Add this to your contract's state variables
    WETHPriceConsumerV3 internal wethOracleInstance;

    // Default parameter values
    uint256 constant DEFAULT_BORROW_RATE = 0.08e6; // 8%
    uint256 constant DEFAULT_LIQUIDATION_FEE = 0.08e6; // 8% - Renamed from DEFAULT_LIQUIDATION_BONUS

    // New parameter values
    uint256 constant NEW_BORROW_RATE = 0.1e6; // 10%
    uint256 constant NEW_LIQUIDATION_FEE = 0.09e6; // 9% - Changed from 0.12e6 to be under max

    // Max allowed values
    uint256 constant MAX_BORROW_RATE = 0.25e6; // 25%
    uint256 constant MAX_LIQUIDATION_FEE = 0.1e6; // 10% - Changed from 0.2e6

    function setUp() public {
        // Create the mock WETH oracle first
        wethOracleInstance = new WETHPriceConsumerV3();
        wethOracleInstance.setPrice(2500e8); // $2500 per ETH

        // Deploy all contracts including the Oracle module
        deployCompleteWithOracle();

        // TGE setup
        vm.prank(guardian);
        tokenInstance.initializeTGE(address(ecoInstance), address(treasuryInstance));

        // Deploy WETH (already have usdcInstance from deployCompleteWithOracle)
        wethInstance = new WETH9();

        // Register the WETH oracle with the Oracle module
        vm.startPrank(address(timelockInstance));
        oracleInstance.addOracle(address(wethInstance), address(wethOracleInstance), 8);
        oracleInstance.setPrimaryOracle(address(wethInstance), address(wethOracleInstance));

        LendefiInstance.updateAssetConfig(
            address(wethInstance),
            address(wethOracleInstance),
            8, // oracle decimals
            18, // asset decimals
            1, // active
            800, // 80% borrow threshold
            850, // 85% liquidation threshold
            1_000_000 ether, // max supply
            IPROTOCOL.CollateralTier.CROSS_A,
            0 // no isolation debt cap
        );
        vm.stopPrank();
    }
    // Test 1: Only manager can update tier parameters

    function test_OnlyManagerCanUpdateTierParameters() public {
        // Regular user should not be able to update tier parameters
        vm.startPrank(alice);
        vm.expectRevert(); // Should revert due to missing role
        LendefiInstance.updateTierParameters(IPROTOCOL.CollateralTier.CROSS_A, NEW_BORROW_RATE, NEW_LIQUIDATION_FEE);
        vm.stopPrank();

        // Manager (timelock) should be able to update tier parameters
        vm.prank(address(timelockInstance));
        LendefiInstance.updateTierParameters(IPROTOCOL.CollateralTier.CROSS_A, NEW_BORROW_RATE, NEW_LIQUIDATION_FEE);
    }

    // Test 2: Correctly updates tier parameters
    function test_CorrectlyUpdatesTierParameters() public {
        // Update CROSS_A tier parameters
        vm.prank(address(timelockInstance));
        LendefiInstance.updateTierParameters(IPROTOCOL.CollateralTier.CROSS_A, NEW_BORROW_RATE, NEW_LIQUIDATION_FEE);

        // Get updated parameters
        (uint256[4] memory updatedjumpRates, uint256[4] memory updatedtierLiquidationFees) =
            LendefiInstance.getTierRates();

        // IMPORTANT CHANGE: CROSS_A is at index 2, not index 1
        uint256 updatedBorrowRate = updatedjumpRates[2];
        uint256 updatedLiquidationFee = updatedtierLiquidationFees[2];

        // Verify parameters were updated
        assertEq(updatedBorrowRate, NEW_BORROW_RATE, "Borrow rate not updated correctly");
        assertEq(updatedLiquidationFee, NEW_LIQUIDATION_FEE, "Liquidation fee not updated correctly");
    }

    // Test 3: Updates for each tier independently
    function test_UpdatesEachTierIndependently() public {
        // Update ISOLATED tier
        vm.startPrank(address(timelockInstance));
        LendefiInstance.updateTierParameters(
            IPROTOCOL.CollateralTier.ISOLATED,
            0.15e6, // 15%
            0.09e6 // 9% - CHANGED from 0.15e6 to be below the 10% limit
        );

        // Update CROSS_A tier
        LendefiInstance.updateTierParameters(
            IPROTOCOL.CollateralTier.CROSS_A,
            0.08e6, // 8%
            0.08e6 // 8% - Within the 10% limit
        );

        // Update CROSS_B tier
        LendefiInstance.updateTierParameters(
            IPROTOCOL.CollateralTier.CROSS_B,
            0.12e6, // 12%
            0.1e6 // 10% - Maximum allowed fee
        );

        // Update STABLE tier
        LendefiInstance.updateTierParameters(
            IPROTOCOL.CollateralTier.STABLE,
            0.05e6, // 5%
            0.05e6 // 5% - Within the 10% limit
        );
        vm.stopPrank();

        // Get updated parameters for all tiers
        (uint256[4] memory jumpRates, uint256[4] memory tierLiquidationFees) = LendefiInstance.getTierRates();

        // Verify each tier was updated correctly
        assertEq(jumpRates[0], 0.15e6, "ISOLATED borrow rate not correct");
        assertEq(jumpRates[1], 0.12e6, "CROSS_B borrow rate not correct");
        assertEq(jumpRates[2], 0.08e6, "CROSS_A borrow rate not correct");
        assertEq(jumpRates[3], 0.05e6, "STABLE borrow rate not correct");

        // IMPORTANT: Update expected values to match what we just set
        assertEq(tierLiquidationFees[0], 0.09e6, "ISOLATED liquidation fee not correct");
        assertEq(tierLiquidationFees[1], 0.1e6, "CROSS_B liquidation fee not correct");
        assertEq(tierLiquidationFees[2], 0.08e6, "CROSS_A liquidation fee not correct");
        assertEq(tierLiquidationFees[3], 0.05e6, "STABLE liquidation fee not correct");
    }

    // Test 4: Validates borrow rate maximum
    function test_ValidatesBorrowRateMaximum() public {
        // Should revert if borrow rate is too high
        vm.prank(address(timelockInstance));
        vm.expectRevert(
            abi.encodeWithSelector(
                IPROTOCOL.RateTooHigh.selector,
                250001, // requested (just above limit)
                250000 // maximum (0.25e6 = 25%)
            )
        );
        LendefiInstance.updateTierParameters(
            IPROTOCOL.CollateralTier.STABLE,
            250001, // 25.0001% - just above max
            100000 // 10% - valid bonus
        );

        // Should succeed with maximum value
        vm.prank(address(timelockInstance));
        LendefiInstance.updateTierParameters(
            IPROTOCOL.CollateralTier.STABLE,
            250000, // 25% - exactly max
            100000 // 10% - valid bonus
        );
    }

    // Test: Should revert if liquidation bonus is too high
    function test_ValidatesLiquidationFeeMaximum() public {
        // Should revert if liquidation fee is too high
        vm.prank(address(timelockInstance));
        vm.expectRevert(
            abi.encodeWithSelector(
                IPROTOCOL.FeeTooHigh.selector,
                100001, // requested (just above limit)
                100000 // maximum (0.1e6 = 10%)
            )
        );
        LendefiInstance.updateTierParameters(
            IPROTOCOL.CollateralTier.STABLE,
            100000, // 10% - valid rate
            100001 // 10.0001% - just above max
        );

        // Should succeed with maximum value
        vm.prank(address(timelockInstance));
        LendefiInstance.updateTierParameters(
            IPROTOCOL.CollateralTier.STABLE,
            100000, // 10% - valid rate
            100000 // 10% - exactly max
        );
    }

    // Test 6: Correct event emission
    function test_EventEmission() public {
        vm.expectEmit(true, true, false, true);
        emit IPROTOCOL.TierParametersUpdated(IPROTOCOL.CollateralTier.CROSS_A, NEW_BORROW_RATE, NEW_LIQUIDATION_FEE);

        vm.prank(address(timelockInstance));
        LendefiInstance.updateTierParameters(IPROTOCOL.CollateralTier.CROSS_A, NEW_BORROW_RATE, NEW_LIQUIDATION_FEE);
    }

    // Test 7: Effect on borrow rate calculation
    function test_EffectOnBorrowRateCalculation() public {
        // Setup protocol with supply
        usdcInstance.mint(alice, 100_000e6);
        vm.startPrank(alice);
        usdcInstance.approve(address(LendefiInstance), 100_000e6);
        LendefiInstance.supplyLiquidity(100_000e6);
        vm.stopPrank();

        // Setup collateral and create borrowing to generate utilization
        vm.deal(bob, 50 ether);
        vm.startPrank(bob);
        wethInstance = new WETH9(); // Make sure wethInstance is initialized
        wethInstance.deposit{value: 50 ether}();
        vm.stopPrank();

        // IMPORTANT CHANGE: Deploy a real mock oracle instead of using a fake address
        wethOracleInstance = new WETHPriceConsumerV3();
        wethOracleInstance.setPrice(2500e8); // $2500 per ETH

        // Configure WETH as CROSS_A tier asset
        vm.startPrank(address(timelockInstance));
        LendefiInstance.updateAssetConfig(
            address(wethInstance),
            address(wethOracleInstance), // Use the actual deployed mock oracle
            8, // oracle decimals
            18, // asset decimals
            1, // active
            800, // borrow threshold
            850, // liquidation threshold
            1_000_000 ether, // supply cap
            IPROTOCOL.CollateralTier.CROSS_A,
            0 // no isolation debt cap
        );
        vm.stopPrank();

        // Now borrow to create utilization
        vm.startPrank(bob);
        wethInstance.approve(address(LendefiInstance), 50 ether);
        LendefiInstance.createPosition(address(wethInstance), false);
        LendefiInstance.supplyCollateral(address(wethInstance), 20 ether, 0);
        LendefiInstance.borrow(0, 40_000e6); // Borrow 40k of the 100k liquidity (40% utilization)
        vm.stopPrank();

        // Verify we have non-zero utilization
        uint256 utilization = LendefiInstance.getUtilization();
        assertTrue(utilization > 0, "Test should have non-zero utilization");

        // Get initial borrow rate for CROSS_A tier
        uint256 initialBorrowRate = LendefiInstance.getBorrowRate(IPROTOCOL.CollateralTier.CROSS_A);

        // Update CROSS_A tier borrow rate to double
        uint256 doubleBorrowRate = 0.16e6; // 16% - double the default 8%

        vm.prank(address(timelockInstance));
        LendefiInstance.updateTierParameters(IPROTOCOL.CollateralTier.CROSS_A, doubleBorrowRate, NEW_LIQUIDATION_FEE);

        // Get new borrow rate
        uint256 newBorrowRate = LendefiInstance.getBorrowRate(IPROTOCOL.CollateralTier.CROSS_A);

        // Log values for debugging
        console2.log("Initial borrow rate:", initialBorrowRate);
        console2.log("New borrow rate:", newBorrowRate);
        console2.log("Utilization:", utilization);

        // The new rate should be higher with meaningful utilization
        assertGt(newBorrowRate, initialBorrowRate, "New borrow rate should be higher after parameter update");
    }
}
