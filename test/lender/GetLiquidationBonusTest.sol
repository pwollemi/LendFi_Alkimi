// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../BasicDeploy.sol";
import {console2} from "forge-std/console2.sol";
import {IPROTOCOL} from "../../contracts/interfaces/IProtocol.sol";
import {Lendefi} from "../../contracts/lender/Lendefi.sol";
import {WETHPriceConsumerV3} from "../../contracts/mock/WETHOracle.sol";
import {StablePriceConsumerV3} from "../../contracts/mock/StableOracle.sol";
import {TokenMock} from "../../contracts/mock/TokenMock.sol";
import {LINK} from "../../contracts/mock/LINK.sol";

contract getPositionLiquidationFeeTest is BasicDeploy {
    WETHPriceConsumerV3 internal wethOracleInstance;
    StablePriceConsumerV3 internal stableOracleInstance;

    // Mock tokens for different tiers
    IERC20 internal linkInstance; // For ISOLATED tier
    IERC20 internal uniInstance; // For CROSS_B tier

    // Constants
    uint256 constant WAD = 1e18;

    function setUp() public {
        deployComplete();

        // TGE setup
        vm.prank(guardian);
        tokenInstance.initializeTGE(address(ecoInstance), address(treasuryInstance));
        vm.warp(block.timestamp + 90 days);

        // Deploy mock tokens
        usdcInstance = new USDC();
        wethInstance = new WETH9();
        linkInstance = new LINK();
        uniInstance = new TokenMock("Uniswap", "UNI");

        // Deploy oracles
        wethOracleInstance = new WETHPriceConsumerV3();
        stableOracleInstance = new StablePriceConsumerV3();

        // Set prices
        wethOracleInstance.setPrice(2500e8); // $2500 per ETH
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

        // Configure USDC as STABLE tier
        LendefiInstance.updateAssetConfig(
            address(usdcInstance),
            address(stableOracleInstance),
            8, // Oracle decimals
            6, // USDC decimals
            1, // Active
            900, // 90% borrow threshold
            950, // 95% liquidation threshold
            1_000_000e6, // Supply limit
            IPROTOCOL.CollateralTier.STABLE,
            0 // No isolation debt cap
        );

        // Configure LINK as ISOLATED tier
        LendefiInstance.updateAssetConfig(
            address(linkInstance),
            address(wethOracleInstance), // Reuse oracle for simplicity
            8, // Oracle decimals
            18, // Asset decimals
            1, // Active
            700, // 70% borrow threshold
            750, // 75% liquidation threshold
            100_000 ether, // Supply limit
            IPROTOCOL.CollateralTier.ISOLATED,
            10_000e6 // Isolation debt cap
        );

        // Configure UNI as CROSS_B tier
        LendefiInstance.updateAssetConfig(
            address(uniInstance),
            address(wethOracleInstance), // Reuse oracle for simplicity
            8, // Oracle decimals
            18, // Asset decimals
            1, // Active
            750, // 75% borrow threshold
            800, // 80% liquidation threshold
            200_000 ether, // Supply limit
            IPROTOCOL.CollateralTier.CROSS_B,
            0 // No isolation debt cap
        );

        vm.stopPrank();
    }

    function test_getPositionLiquidationFee_NonIsolatedPosition() public {
        // Create a non-isolated position with WETH
        vm.startPrank(alice);
        LendefiInstance.createPosition(address(wethInstance), false); // Non-isolated
        uint256 positionId = LendefiInstance.getUserPositionsCount(alice) - 1;
        vm.stopPrank();

        // Get the liquidation bonus
        uint256 bonus = LendefiInstance.getPositionLiquidationFee(alice, positionId);
        IPROTOCOL.CollateralTier tier = LendefiInstance.getHighestTier(alice, positionId);

        // Get the base liquidation fee for comparison
        uint256 baseFee = LendefiInstance.getTierLiquidationFee(tier);

        // Verify non-isolated position uses base fee
        assertEq(bonus, baseFee, "Non-isolated position should use base liquidation fee");
        console2.log("Non-isolated position bonus:", bonus);
    }

    function test_getPositionLiquidationFee_IsolatedPosition() public {
        // Create an isolated position with LINK (ISOLATED tier)
        vm.startPrank(alice);
        LendefiInstance.createPosition(address(linkInstance), true); // Isolated
        uint256 positionId = LendefiInstance.getUserPositionsCount(alice) - 1;
        vm.stopPrank();

        // Get the liquidation bonus
        uint256 bonus = LendefiInstance.getPositionLiquidationFee(alice, positionId);

        // Get the tier liquidation bonus for ISOLATED tier
        (, uint256[4] memory liquidationBonuses) = LendefiInstance.getTierRates();
        uint256 isolatedTierBonus = liquidationBonuses[0]; // ISOLATED is at index 0

        // Verify isolated position uses tier-specific bonus
        assertEq(bonus, isolatedTierBonus, "ISOLATED position should use ISOLATED tier bonus");
        console2.log("ISOLATED tier position bonus:", bonus);
    }

    function test_getPositionLiquidationFee_DifferentTiers() public {
        // Create positions for each tier type
        vm.startPrank(alice);

        // ISOLATED position (LINK)
        LendefiInstance.createPosition(address(linkInstance), true);
        uint256 isolatedPositionId = LendefiInstance.getUserPositionsCount(alice) - 1;

        // CROSS_A position (WETH)
        LendefiInstance.createPosition(address(wethInstance), true);
        uint256 crossAPositionId = LendefiInstance.getUserPositionsCount(alice) - 1;

        // CROSS_B position (UNI)
        LendefiInstance.createPosition(address(uniInstance), true);
        uint256 crossBPositionId = LendefiInstance.getUserPositionsCount(alice) - 1;

        // STABLE position (USDC)
        LendefiInstance.createPosition(address(usdcInstance), true);
        uint256 stablePositionId = LendefiInstance.getUserPositionsCount(alice) - 1;
        vm.stopPrank();

        // Get liquidation bonuses for each position
        uint256 isolatedBonus = LendefiInstance.getPositionLiquidationFee(alice, isolatedPositionId);
        uint256 crossABonus = LendefiInstance.getPositionLiquidationFee(alice, crossAPositionId);
        uint256 crossBBonus = LendefiInstance.getPositionLiquidationFee(alice, crossBPositionId);
        uint256 stableBonus = LendefiInstance.getPositionLiquidationFee(alice, stablePositionId);

        // Get all tier rates from contract
        (, uint256[4] memory liquidationBonuses) = LendefiInstance.getTierRates();

        // Log all bonuses
        console2.log("ISOLATED tier liquidation bonus:", isolatedBonus);
        console2.log("CROSS_A tier liquidation bonus:", crossABonus);
        console2.log("CROSS_B tier liquidation bonus:", crossBBonus);
        console2.log("STABLE tier liquidation bonus:", stableBonus);

        // Verify each position returns the correct tier bonus
        assertEq(isolatedBonus, liquidationBonuses[0], "ISOLATED position bonus incorrect");
        assertEq(crossABonus, liquidationBonuses[1], "CROSS_A position bonus incorrect");
        assertEq(crossBBonus, liquidationBonuses[2], "CROSS_B position bonus incorrect");
        assertEq(stableBonus, liquidationBonuses[3], "STABLE position bonus incorrect");
    }

    function test_getPositionLiquidationFee_AfterUpdate() public {
        // Create an isolated position with LINK
        vm.startPrank(alice);
        LendefiInstance.createPosition(address(linkInstance), true);
        uint256 positionId = LendefiInstance.getUserPositionsCount(alice) - 1;
        vm.stopPrank();

        // Get initial liquidation bonus
        uint256 initialBonus = LendefiInstance.getPositionLiquidationFee(alice, positionId);
        console2.log("Initial ISOLATED liquidation bonus:", initialBonus);

        // Update the ISOLATED tier liquidation bonus
        uint256 newBonus = 0.18e6; // Increase from 15% to 18%
        vm.startPrank(address(timelockInstance));

        // Get current borrow rate for ISOLATED tier
        (uint256[4] memory borrowRates,) = LendefiInstance.getTierRates();
        uint256 currentBorrowRate = borrowRates[0]; // ISOLATED tier

        // Update tier parameters (borrow rate and liquidation bonus)
        LendefiInstance.updateTierParameters(
            IPROTOCOL.CollateralTier.ISOLATED,
            currentBorrowRate, // Keep same borrow rate
            newBonus // Update liquidation bonus
        );
        vm.stopPrank();

        // Get updated liquidation bonus
        uint256 updatedBonus = LendefiInstance.getPositionLiquidationFee(alice, positionId);
        console2.log("Updated ISOLATED liquidation bonus:", updatedBonus);

        // Verify the liquidation bonus was updated
        assertEq(updatedBonus, newBonus, "Liquidation bonus should be updated");
        assertGt(updatedBonus, initialBonus, "New bonus should be higher than initial bonus");
    }

    function test_getPositionLiquidationFee_InvalidPosition() public {
        // Try to get liquidation bonus for a non-existent position
        vm.expectRevert(abi.encodeWithSelector(IPROTOCOL.InvalidPosition.selector, alice, 0));
        LendefiInstance.getPositionLiquidationFee(alice, 0);

        // Create a position
        vm.startPrank(alice);
        LendefiInstance.createPosition(address(wethInstance), false);
        vm.stopPrank();

        // Now it should work for position 0
        LendefiInstance.getPositionLiquidationFee(alice, 0);

        // But should still fail for position 1 which doesn't exist
        vm.expectRevert(abi.encodeWithSelector(IPROTOCOL.InvalidPosition.selector, alice, 1));
        LendefiInstance.getPositionLiquidationFee(alice, 1);
    }

    function test_getPositionLiquidationFee_AssetTierChange() public {
        // Create an isolated position with LINK
        vm.startPrank(alice);
        LendefiInstance.createPosition(address(linkInstance), true);
        uint256 positionId = LendefiInstance.getUserPositionsCount(alice) - 1;
        vm.stopPrank();

        // Get initial liquidation bonus (ISOLATED tier)
        uint256 initialBonus = LendefiInstance.getPositionLiquidationFee(alice, positionId);
        console2.log("Initial bonus with LINK as ISOLATED tier:", initialBonus);

        // Change LINK from ISOLATED to CROSS_B tier
        vm.startPrank(address(timelockInstance));
        LendefiInstance.updateAssetConfig(
            address(linkInstance),
            address(wethOracleInstance),
            8, // Oracle decimals
            18, // Asset decimals
            1, // Active
            750, // 75% borrow threshold
            800, // 80% liquidation threshold
            100_000 ether, // Supply limit
            IPROTOCOL.CollateralTier.CROSS_B, // Change tier
            0 // No isolation debt cap
        );
        vm.stopPrank();

        // Get the updated liquidation bonus
        uint256 newBonus = LendefiInstance.getPositionLiquidationFee(alice, positionId);
        console2.log("Updated bonus after LINK changed to CROSS_B tier:", newBonus);

        // Get tier rates for verification
        (, uint256[4] memory liquidationBonuses) = LendefiInstance.getTierRates();

        // CROSS_B bonus should be at index 2
        assertEq(newBonus, liquidationBonuses[2], "Bonus should match CROSS_B tier bonus after asset tier change");
    }
}
