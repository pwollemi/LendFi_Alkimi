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

    function setUp() public {
        // Use deployCompleteWithOracle() instead of deployComplete()
        deployCompleteWithOracle();

        // TGE setup
        vm.prank(guardian);
        tokenInstance.initializeTGE(address(ecoInstance), address(treasuryInstance));
        vm.warp(block.timestamp + 90 days);

        // Deploy mock tokens (USDC already deployed by deployCompleteWithOracle())
        wethInstance = new WETH9();
        linkInstance = new LINK();
        uniInstance = new TokenMock("Uniswap", "UNI");

        // Deploy oracles
        wethOracleInstance = new WETHPriceConsumerV3();
        stableOracleInstance = new StablePriceConsumerV3();

        // Set prices
        wethOracleInstance.setPrice(2500e8); // $2500 per ETH
        stableOracleInstance.setPrice(1e8); // $1 per stable

        // Register oracles with Oracle module
        vm.startPrank(address(timelockInstance));
        oracleInstance.addOracle(address(wethInstance), address(wethOracleInstance), 8);
        oracleInstance.setPrimaryOracle(address(wethInstance), address(wethOracleInstance));

        oracleInstance.addOracle(address(linkInstance), address(wethOracleInstance), 8); // Reusing oracle for simplicity
        oracleInstance.setPrimaryOracle(address(linkInstance), address(wethOracleInstance));

        oracleInstance.addOracle(address(uniInstance), address(wethOracleInstance), 8); // Reusing oracle for simplicity
        oracleInstance.setPrimaryOracle(address(uniInstance), address(wethOracleInstance));

        oracleInstance.addOracle(address(usdcInstance), address(stableOracleInstance), 8);
        oracleInstance.setPrimaryOracle(address(usdcInstance), address(stableOracleInstance));
        vm.stopPrank();

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
        (, uint256[4] memory liquidationFees) = LendefiInstance.getTierRates();

        // CROSS_B bonus should be at index 2
        assertEq(newBonus, liquidationFees[1], "Bonus should match CROSS_B tier bonus after asset tier change");
    }

    function test_getPositionLiquidationFee_NonIsolatedPosition() public {
        // Create a non-isolated position with WETH
        vm.startPrank(alice);
        LendefiInstance.createPosition(address(wethInstance), false); // Non-isolated
        uint256 positionId = LendefiInstance.getUserPositionsCount(alice) - 1;
        vm.stopPrank();

        // Get the liquidation fee
        uint256 fee = LendefiInstance.getPositionLiquidationFee(alice, positionId);
        IPROTOCOL.CollateralTier tier = LendefiInstance.getHighestTier(alice, positionId);

        // Get the base liquidation fee for comparison
        uint256 baseFee = LendefiInstance.getTierLiquidationFee(tier);

        // Verify non-isolated position uses base fee
        assertEq(fee, baseFee, "Non-isolated position should use base liquidation fee");
        console2.log("Non-isolated position fee:", fee);
    }

    function test_getPositionLiquidationFee_IsolatedPosition() public {
        // Create an isolated position with LINK (ISOLATED tier)
        vm.startPrank(alice);
        LendefiInstance.createPosition(address(linkInstance), true); // Isolated
        uint256 positionId = LendefiInstance.getUserPositionsCount(alice) - 1;
        vm.stopPrank();

        // Get the liquidation fee
        uint256 fee = LendefiInstance.getPositionLiquidationFee(alice, positionId);

        // Get the tier liquidation fee for ISOLATED tier
        (, uint256[4] memory liquidationFees) = LendefiInstance.getTierRates();
        uint256 isolatedTierFee = liquidationFees[0]; // ISOLATED is at index 0

        // Verify isolated position uses tier-specific fee
        assertEq(fee, isolatedTierFee, "ISOLATED position should use ISOLATED tier fee");
        console2.log("ISOLATED tier position fee:", fee);
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

        // Get liquidation fees for each position
        uint256 isolatedFee = LendefiInstance.getPositionLiquidationFee(alice, isolatedPositionId);
        uint256 crossBFee = LendefiInstance.getPositionLiquidationFee(alice, crossBPositionId);
        uint256 crossAFee = LendefiInstance.getPositionLiquidationFee(alice, crossAPositionId);
        uint256 stableFee = LendefiInstance.getPositionLiquidationFee(alice, stablePositionId);

        // Get all tier rates from contract
        (, uint256[4] memory liquidationFees) = LendefiInstance.getTierRates();

        // Log all fees
        console2.log("ISOLATED tier liquidation fee:", isolatedFee);
        console2.log("CROSS_A tier liquidation fee:", crossAFee);
        console2.log("CROSS_B tier liquidation fee:", crossBFee);
        console2.log("STABLE tier liquidation fee:", stableFee);

        // Verify each position returns the correct tier fee
        assertEq(isolatedFee, liquidationFees[0], "ISOLATED position fee incorrect");
        assertEq(crossBFee, liquidationFees[1], "CROSS_B position fee incorrect");
        assertEq(crossAFee, liquidationFees[2], "CROSS_A position fee incorrect");
        assertEq(stableFee, liquidationFees[3], "STABLE position fee incorrect");
    }

    function test_getPositionLiquidationFee_AfterUpdate() public {
        // Create an isolated position with LINK
        vm.startPrank(alice);
        LendefiInstance.createPosition(address(linkInstance), true);
        uint256 positionId = LendefiInstance.getUserPositionsCount(alice) - 1;
        vm.stopPrank();

        // Get initial liquidation fee
        uint256 initialFee = LendefiInstance.getPositionLiquidationFee(alice, positionId);
        console2.log("Initial ISOLATED liquidation fee:", initialFee);

        // Update the ISOLATED tier liquidation fee (stay under 10% max)
        uint256 newFee = 0.09e6; // 9% fee - under the 10% maximum
        vm.startPrank(address(timelockInstance));

        // Get current borrow rate for ISOLATED tier
        (uint256[4] memory borrowRates,) = LendefiInstance.getTierRates();
        uint256 currentBorrowRate = borrowRates[0]; // ISOLATED tier

        // Update tier parameters (borrow rate and liquidation fee)
        LendefiInstance.updateTierParameters(
            IPROTOCOL.CollateralTier.ISOLATED,
            currentBorrowRate, // Keep same borrow rate
            newFee // Update liquidation fee
        );
        vm.stopPrank();

        // Get updated liquidation fee
        uint256 updatedFee = LendefiInstance.getPositionLiquidationFee(alice, positionId);
        console2.log("Updated ISOLATED liquidation fee:", updatedFee);

        // Verify the liquidation fee was updated
        assertEq(updatedFee, newFee, "Liquidation fee should be updated");
        assertGt(updatedFee, initialFee, "New fee should be higher than initial fee");
    }
}
