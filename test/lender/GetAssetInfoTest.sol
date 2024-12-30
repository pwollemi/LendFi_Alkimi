// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../BasicDeploy.sol";
import {console2} from "forge-std/console2.sol";
import {IPROTOCOL} from "../../contracts/interfaces/IProtocol.sol";
import {Lendefi} from "../../contracts/lender/Lendefi.sol";
import {WETHPriceConsumerV3} from "../../contracts/mock/WETHOracle.sol";
import {StablePriceConsumerV3} from "../../contracts/mock/StableOracle.sol";

contract GetAssetInfoTest is BasicDeploy {
    // Oracle instances
    WETHPriceConsumerV3 internal wethOracleInstance;
    StablePriceConsumerV3 internal stableOracleInstance;

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
            0 // No isolation debt cap for STABLE assets
        );

        vm.stopPrank();
    }

    function test_GetAssetInfo_WETH() public {
        IPROTOCOL.Asset memory asset = LendefiInstance.getAssetInfo(address(wethInstance));

        assertEq(asset.active, 1, "WETH should be active");
        assertEq(asset.oracleUSD, address(wethOracleInstance), "Oracle address mismatch");
        assertEq(asset.oracleDecimals, 8, "Oracle decimals mismatch");
        assertEq(asset.decimals, 18, "Asset decimals mismatch");
        assertEq(asset.borrowThreshold, 800, "Borrow threshold mismatch");
        assertEq(asset.liquidationThreshold, 850, "Liquidation threshold mismatch");
        assertEq(asset.maxSupplyThreshold, 1_000_000 ether, "Supply limit mismatch");
        assertEq(uint8(asset.tier), uint8(IPROTOCOL.CollateralTier.CROSS_A), "Tier mismatch");
        assertEq(asset.isolationDebtCap, 0, "Isolation debt cap should be 0 for non-isolated assets");
    }

    function test_GetAssetInfo_USDC() public {
        IPROTOCOL.Asset memory asset = LendefiInstance.getAssetInfo(address(usdcInstance));

        assertEq(asset.active, 1, "USDC should be active");
        assertEq(asset.oracleUSD, address(stableOracleInstance), "Oracle address mismatch");
        assertEq(asset.oracleDecimals, 8, "Oracle decimals mismatch");
        assertEq(asset.decimals, 6, "Asset decimals mismatch");
        assertEq(asset.borrowThreshold, 900, "Borrow threshold mismatch");
        assertEq(asset.liquidationThreshold, 950, "Liquidation threshold mismatch");
        assertEq(asset.maxSupplyThreshold, 1_000_000e6, "Supply limit mismatch");
        assertEq(uint8(asset.tier), uint8(IPROTOCOL.CollateralTier.STABLE), "Tier mismatch");
        assertEq(asset.isolationDebtCap, 0, "Isolation debt cap should be 0 for STABLE assets");
    }

    function test_GetAssetInfo_Unlisted() public {
        // Using an address that's not configured as an asset
        address randomAddress = address(0x123);

        IPROTOCOL.Asset memory asset = LendefiInstance.getAssetInfo(randomAddress);

        assertEq(asset.active, 0, "Unlisted asset should not be active");
        assertEq(asset.oracleUSD, address(0), "Oracle address should be zero");
        assertEq(asset.oracleDecimals, 0, "Oracle decimals should be zero");
        assertEq(asset.decimals, 0, "Asset decimals should be zero");
        assertEq(asset.borrowThreshold, 0, "Borrow threshold should be zero");
        assertEq(asset.liquidationThreshold, 0, "Liquidation threshold should be zero");
        assertEq(asset.maxSupplyThreshold, 0, "Supply limit should be zero");
        assertEq(uint8(asset.tier), 0, "Tier should be zero (STABLE)");
        assertEq(asset.isolationDebtCap, 0, "Isolation debt cap should be zero");
    }

    function test_GetAssetInfo_AfterUpdate() public {
        vm.startPrank(address(timelockInstance));

        // Update WETH configuration
        LendefiInstance.updateAssetConfig(
            address(wethInstance),
            address(wethOracleInstance),
            8, // Oracle decimals
            18, // Asset decimals
            0, // Set to inactive
            750, // Change borrow threshold
            800, // Change liquidation threshold
            500_000 ether, // Lower supply limit
            IPROTOCOL.CollateralTier.CROSS_B, // Change tier
            1_000_000e6 // Add isolation debt cap
        );

        vm.stopPrank();

        IPROTOCOL.Asset memory asset = LendefiInstance.getAssetInfo(address(wethInstance));

        assertEq(asset.active, 0, "WETH should be inactive after update");
        assertEq(asset.borrowThreshold, 750, "Borrow threshold should be updated");
        assertEq(asset.liquidationThreshold, 800, "Liquidation threshold should be updated");
        assertEq(asset.maxSupplyThreshold, 500_000 ether, "Supply limit should be updated");
        assertEq(uint8(asset.tier), uint8(IPROTOCOL.CollateralTier.CROSS_B), "Tier should be updated");
        assertEq(asset.isolationDebtCap, 1_000_000e6, "Isolation debt cap should be updated");
    }
}
