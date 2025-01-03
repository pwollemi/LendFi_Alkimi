// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../BasicDeploy.sol";
import {console2} from "forge-std/console2.sol";
import {IPROTOCOL} from "../../contracts/interfaces/IProtocol.sol";
import {Lendefi} from "../../contracts/lender/Lendefi.sol";

contract GetTierRatesTest is BasicDeploy {
    function setUp() public {
        // Use deployCompleteWithOracle() instead of deployComplete()
        deployCompleteWithOracle();

        // TGE setup
        vm.prank(guardian);
        tokenInstance.initializeTGE(address(ecoInstance), address(treasuryInstance));
        vm.warp(block.timestamp + 90 days);
    }

    function test_GetTierRates_InitialRates() public {
        // Call the getTierRates function
        (uint256[4] memory jumpRates, uint256[4] memory liquidationBonuses) = LendefiInstance.getTierRates();

        // Verify the initial borrow rates match what's set in the initialize function
        assertEq(jumpRates[0], 0.15e6, "ISOLATED borrow rate should be 15%");
        assertEq(jumpRates[1], 0.08e6, "CROSS_A borrow rate should be 8%");
        assertEq(jumpRates[2], 0.12e6, "CROSS_B borrow rate should be 12%");
        assertEq(jumpRates[3], 0.05e6, "STABLE borrow rate should be 5%");

        // Verify the initial liquidation bonuses match what's set in the initialize function
        assertEq(liquidationBonuses[0], 0.06e6, "ISOLATED liquidation bonus should be 6%");
        assertEq(liquidationBonuses[1], 0.04e6, "CROSS_A liquidation bonus should be 8%");
        assertEq(liquidationBonuses[2], 0.05e6, "CROSS_B liquidation bonus should be 10%");
        assertEq(liquidationBonuses[3], 0.02e6, "STABLE liquidation bonus should be 5%");
    }

    function test_GetTierRates_AfterUpdate() public {
        // Get initial rates for comparison
        (uint256[4] memory initialjumpRates, uint256[4] memory initialLiquidationBonuses) =
            LendefiInstance.getTierRates();

        // Update some tier parameters
        vm.startPrank(address(timelockInstance));

        // Update ISOLATED tier (index 0)
        LendefiInstance.updateTierParameters(
            IPROTOCOL.CollateralTier.ISOLATED,
            0.2e6, // Change from 15% to 20%
            0.18e6 // Change from 15% to 18%
        );

        // Update STABLE tier (index 3)
        LendefiInstance.updateTierParameters(
            IPROTOCOL.CollateralTier.STABLE,
            0.06e6, // Change from 5% to 6%
            0.07e6 // Change from 5% to 7%
        );

        vm.stopPrank();

        // Call getTierRates again to get the updated rates
        (uint256[4] memory newjumpRates, uint256[4] memory newLiquidationBonuses) = LendefiInstance.getTierRates();

        // Verify updated rates for ISOLATED tier
        assertEq(newjumpRates[0], 0.2e6, "ISOLATED borrow rate should be updated to 20%");
        assertEq(newLiquidationBonuses[0], 0.18e6, "ISOLATED liquidation bonus should be updated to 18%");

        // Verify updated rates for STABLE tier
        assertEq(newjumpRates[3], 0.06e6, "STABLE borrow rate should be updated to 6%");
        assertEq(newLiquidationBonuses[3], 0.07e6, "STABLE liquidation bonus should be updated to 7%");

        // Verify rates for tiers we didn't update remain the same
        assertEq(newjumpRates[1], initialjumpRates[1], "CROSS_A borrow rate should remain unchanged");
        assertEq(newjumpRates[2], initialjumpRates[2], "CROSS_B borrow rate should remain unchanged");
        assertEq(
            newLiquidationBonuses[1], initialLiquidationBonuses[1], "CROSS_A liquidation bonus should remain unchanged"
        );
        assertEq(
            newLiquidationBonuses[2], initialLiquidationBonuses[2], "CROSS_B liquidation bonus should remain unchanged"
        );
    }

    function test_GetTierRates_CorrectMapping() public {
        // We'll update each tier with unique values and then check the array positions
        vm.startPrank(address(timelockInstance));

        LendefiInstance.updateTierParameters(
            IPROTOCOL.CollateralTier.ISOLATED,
            0.1e6, // Unique value for ISOLATED
            0.11e6
        );

        LendefiInstance.updateTierParameters(
            IPROTOCOL.CollateralTier.CROSS_A,
            0.12e6, // Unique value for CROSS_A
            0.13e6
        );

        LendefiInstance.updateTierParameters(
            IPROTOCOL.CollateralTier.CROSS_B,
            0.14e6, // Unique value for CROSS_B
            0.15e6
        );

        LendefiInstance.updateTierParameters(
            IPROTOCOL.CollateralTier.STABLE,
            0.16e6, // Unique value for STABLE
            0.17e6
        );

        vm.stopPrank();

        // Get updated rates
        (uint256[4] memory updatedjumpRates, uint256[4] memory updatedLiquidationBonuses) =
            LendefiInstance.getTierRates();

        // Verify the mapping of tiers to array indices is correct
        assertEq(updatedjumpRates[0], 0.1e6, "ISOLATED should be at index 0");
        assertEq(updatedjumpRates[1], 0.12e6, "CROSS_A should be at index 1");
        assertEq(updatedjumpRates[2], 0.14e6, "CROSS_B should be at index 2");
        assertEq(updatedjumpRates[3], 0.16e6, "STABLE should be at index 3");

        assertEq(updatedLiquidationBonuses[0], 0.11e6, "ISOLATED liquidation bonus should be at index 0");
        assertEq(updatedLiquidationBonuses[1], 0.13e6, "CROSS_A liquidation bonus should be at index 1");
        assertEq(updatedLiquidationBonuses[2], 0.15e6, "CROSS_B liquidation bonus should be at index 2");
        assertEq(updatedLiquidationBonuses[3], 0.17e6, "STABLE liquidation bonus should be at index 3");
    }
}
