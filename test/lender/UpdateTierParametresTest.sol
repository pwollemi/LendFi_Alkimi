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
    uint256 constant DEFAULT_LIQUIDATION_BONUS = 0.08e6; // 8%

    // New parameter values
    uint256 constant NEW_BORROW_RATE = 0.1e6; // 10%
    uint256 constant NEW_LIQUIDATION_BONUS = 0.12e6; // 12%

    // Max allowed values
    uint256 constant MAX_BORROW_RATE = 0.25e6; // 25%
    uint256 constant MAX_LIQUIDATION_BONUS = 0.2e6; // 20%

    function setUp() public {
        // In your setUp() function, add:
        wethOracleInstance = new WETHPriceConsumerV3();
        wethOracleInstance.setPrice(2500e8); // $2500 per ETH
        deployComplete();

        // TGE setup
        vm.prank(guardian);
        tokenInstance.initializeTGE(address(ecoInstance), address(treasuryInstance));

        // Deploy USDC
        usdcInstance = new USDC();

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
    }

    // Test 1: Only manager can update tier parameters
    function test_OnlyManagerCanUpdateTierParameters() public {
        // Regular user should not be able to update tier parameters
        vm.startPrank(alice);
        vm.expectRevert(); // Should revert due to missing role
        LendefiInstance.updateTierParameters(IPROTOCOL.CollateralTier.CROSS_A, NEW_BORROW_RATE, NEW_LIQUIDATION_BONUS);
        vm.stopPrank();

        // Manager (timelock) should be able to update tier parameters
        vm.prank(address(timelockInstance));
        LendefiInstance.updateTierParameters(IPROTOCOL.CollateralTier.CROSS_A, NEW_BORROW_RATE, NEW_LIQUIDATION_BONUS);
    }

    // Test 2: Correctly updates tier parameters
    function test_CorrectlyUpdatesTierParameters() public {
        // Update CROSS_A tier parameters
        vm.prank(address(timelockInstance));
        LendefiInstance.updateTierParameters(IPROTOCOL.CollateralTier.CROSS_A, NEW_BORROW_RATE, NEW_LIQUIDATION_BONUS);

        // Get updated parameters
        (uint256[4] memory updatedBorrowRates, uint256[4] memory updatedLiquidationBonuses) =
            LendefiInstance.getTierRates();
        uint256 updatedBorrowRate = updatedBorrowRates[1];
        uint256 updatedLiquidationBonus = updatedLiquidationBonuses[1];

        // Verify parameters were updated
        assertEq(updatedBorrowRate, NEW_BORROW_RATE, "Borrow rate not updated correctly");
        assertEq(updatedLiquidationBonus, NEW_LIQUIDATION_BONUS, "Liquidation bonus not updated correctly");
    }

    // Test 3: Updates for each tier independently
    function test_UpdatesEachTierIndependently() public {
        // Update ISOLATED tier
        vm.startPrank(address(timelockInstance));
        LendefiInstance.updateTierParameters(
            IPROTOCOL.CollateralTier.ISOLATED,
            0.15e6, // 15%
            0.15e6 // 15%
        );

        // Update CROSS_A tier
        LendefiInstance.updateTierParameters(
            IPROTOCOL.CollateralTier.CROSS_A,
            0.08e6, // 8%
            0.08e6 // 8%
        );

        // Update CROSS_B tier
        LendefiInstance.updateTierParameters(
            IPROTOCOL.CollateralTier.CROSS_B,
            0.12e6, // 12%
            0.1e6 // 10%
        );

        // Update STABLE tier
        LendefiInstance.updateTierParameters(
            IPROTOCOL.CollateralTier.STABLE,
            0.05e6, // 5%
            0.05e6 // 5%
        );
        vm.stopPrank();

        // Get updated parameters for all tiers
        (uint256[4] memory borrowRates, uint256[4] memory liquidationBonuses) = LendefiInstance.getTierRates();

        // Verify each tier was updated correctly
        assertEq(borrowRates[0], 0.15e6, "ISOLATED borrow rate not correct");
        assertEq(borrowRates[1], 0.08e6, "CROSS_A borrow rate not correct");
        assertEq(borrowRates[2], 0.12e6, "CROSS_B borrow rate not correct");
        assertEq(borrowRates[3], 0.05e6, "STABLE borrow rate not correct");

        assertEq(liquidationBonuses[0], 0.15e6, "ISOLATED liquidation bonus not correct");
        assertEq(liquidationBonuses[1], 0.08e6, "CROSS_A liquidation bonus not correct");
        assertEq(liquidationBonuses[2], 0.1e6, "CROSS_B liquidation bonus not correct");
        assertEq(liquidationBonuses[3], 0.05e6, "STABLE liquidation bonus not correct");
    }

    // Test 4: Validates borrow rate maximum
    function test_ValidatesBorrowRateMaximum() public {
        // Should revert if borrow rate is too high
        vm.prank(address(timelockInstance));
        vm.expectRevert(
            abi.encodeWithSelector(
                Lendefi.RateTooHigh.selector,
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
    function test_ValidatesLiquidationBonusMaximum() public {
        // Should revert if liquidation bonus is too high
        vm.prank(address(timelockInstance));
        vm.expectRevert(
            abi.encodeWithSelector(
                Lendefi.BonusTooHigh.selector,
                200001, // requested (just above limit)
                200000 // maximum (0.2e6 = 20%)
            )
        );
        LendefiInstance.updateTierParameters(
            IPROTOCOL.CollateralTier.STABLE,
            100000, // 10% - valid rate
            200001 // 20.0001% - just above max
        );

        // Should succeed with maximum value
        vm.prank(address(timelockInstance));
        LendefiInstance.updateTierParameters(
            IPROTOCOL.CollateralTier.STABLE,
            100000, // 10% - valid rate
            200000 // 20% - exactly max
        );
    }

    // Test 6: Correct event emission
    function test_EventEmission() public {
        vm.expectEmit(true, true, false, true);
        emit IPROTOCOL.TierParametersUpdated(IPROTOCOL.CollateralTier.CROSS_A, NEW_BORROW_RATE, NEW_LIQUIDATION_BONUS);

        vm.prank(address(timelockInstance));
        LendefiInstance.updateTierParameters(IPROTOCOL.CollateralTier.CROSS_A, NEW_BORROW_RATE, NEW_LIQUIDATION_BONUS);
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
        LendefiInstance.updateTierParameters(IPROTOCOL.CollateralTier.CROSS_A, doubleBorrowRate, NEW_LIQUIDATION_BONUS);

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
