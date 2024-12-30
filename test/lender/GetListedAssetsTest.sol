// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../BasicDeploy.sol";
import {console2} from "forge-std/console2.sol";
import {IPROTOCOL} from "../../contracts/interfaces/IProtocol.sol";
import {Lendefi} from "../../contracts/lender/Lendefi.sol";
import {WETHPriceConsumerV3} from "../../contracts/mock/WETHOracle.sol";
import {LINKPriceConsumerV3} from "../../contracts/mock/LINKOracle.sol";
import {StablePriceConsumerV3} from "../../contracts/mock/StableOracle.sol";
import {TokenMock} from "../../contracts/mock/TokenMock.sol";
import {LINK} from "../../contracts/mock/LINK.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract GetListedAssetsTest is BasicDeploy {
    WETHPriceConsumerV3 internal wethOracleInstance;
    StablePriceConsumerV3 internal stableOracleInstance;
    LINKPriceConsumerV3 internal linkOracleInstance;

    // Mock tokens
    IERC20 internal daiInstance;
    IERC20 internal linkInstance;

    function setUp() public {
        deployComplete();

        // TGE setup
        vm.prank(guardian);
        tokenInstance.initializeTGE(address(ecoInstance), address(treasuryInstance));
        vm.warp(block.timestamp + 90 days);

        // Deploy mock tokens
        usdcInstance = new USDC();
        wethInstance = new WETH9();

        // Create additional mock tokens for testing
        daiInstance = new TokenMock("DAI", "DAI");
        linkInstance = new LINK();

        // Deploy oracles
        wethOracleInstance = new WETHPriceConsumerV3();
        stableOracleInstance = new StablePriceConsumerV3();
        linkOracleInstance = new LINKPriceConsumerV3();

        // Set prices
        wethOracleInstance.setPrice(2500e8); // $2500 per ETH
        stableOracleInstance.setPrice(1e8); // $1 per stable
        linkOracleInstance.setPrice(14e8); // $14 Link

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
    }

    function test_GetListedAssets_Initial() public {
        // Check initially listed assets
        address[] memory initialAssets = LendefiInstance.getListedAssets();
        assertEq(initialAssets.length, 0, "Initial assets array should be empty");
    }

    function test_GetListedAssets_AfterAddingAssets() public {
        // Configure WETH as listed asset
        vm.startPrank(address(timelockInstance));
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

        // Configure USDC as listed asset
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
        vm.stopPrank();

        // Get assets after listing 2 assets
        address[] memory assetsAfterListing = LendefiInstance.getListedAssets();

        // Verify array length
        assertEq(assetsAfterListing.length, 2, "Listed assets array should have 2 elements");

        // Verify array contents
        bool foundWeth = false;
        bool foundUsdc = false;

        for (uint256 i = 0; i < assetsAfterListing.length; i++) {
            if (assetsAfterListing[i] == address(wethInstance)) {
                foundWeth = true;
            }
            if (assetsAfterListing[i] == address(usdcInstance)) {
                foundUsdc = true;
            }
        }

        assertTrue(foundWeth, "WETH should be in listed assets");
        assertTrue(foundUsdc, "USDC should be in listed assets");
    }

    function test_GetListedAssets_MultipleAddsAndOrder() public {
        // Add multiple assets
        vm.startPrank(address(timelockInstance));

        // Add WETH
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

        // Add USDC
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

        // Add DAI
        LendefiInstance.updateAssetConfig(
            address(daiInstance),
            address(stableOracleInstance), // Use same oracle for simplicity
            8, // Oracle decimals
            18, // DAI decimals
            1, // Active
            850, // 85% borrow threshold
            900, // 90% liquidation threshold
            1_000_000 ether, // Supply limit
            IPROTOCOL.CollateralTier.STABLE,
            0 // No isolation debt cap
        );

        // Add LINK
        LendefiInstance.updateAssetConfig(
            address(linkInstance),
            address(linkOracleInstance), // Use same oracle for simplicity
            8, // Oracle decimals
            18, // LINK decimals
            1, // Active
            700, // 70% borrow threshold
            750, // 75% liquidation threshold
            500_000 ether, // Supply limit
            IPROTOCOL.CollateralTier.CROSS_B,
            0 // No isolation debt cap
        );
        vm.stopPrank();

        // Get assets after listing 4 assets
        address[] memory listedAssets = LendefiInstance.getListedAssets();

        // Verify array length
        assertEq(listedAssets.length, 4, "Listed assets array should have 4 elements");

        // Log all assets for clarity
        console2.log("Listed assets:");
        for (uint256 i = 0; i < listedAssets.length; i++) {
            console2.log("Asset", i, ":", listedAssets[i]);
        }

        // Verify all assets are included
        bool foundWeth = false;
        bool foundUsdc = false;
        bool foundDai = false;
        bool foundLink = false;

        for (uint256 i = 0; i < listedAssets.length; i++) {
            if (listedAssets[i] == address(wethInstance)) foundWeth = true;
            if (listedAssets[i] == address(usdcInstance)) foundUsdc = true;
            if (listedAssets[i] == address(daiInstance)) foundDai = true;
            if (listedAssets[i] == address(linkInstance)) foundLink = true;
        }

        assertTrue(foundWeth, "WETH should be in listed assets");
        assertTrue(foundUsdc, "USDC should be in listed assets");
        assertTrue(foundDai, "DAI should be in listed assets");
        assertTrue(foundLink, "LINK should be in listed assets");
    }

    function test_GetListedAssets_UpdateInactiveAsset() public {
        // Add an asset as active
        vm.startPrank(address(timelockInstance));
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

        // Verify it's in the list
        address[] memory assetsActive = LendefiInstance.getListedAssets();
        assertEq(assetsActive.length, 1, "Should have 1 listed asset");
        assertEq(assetsActive[0], address(wethInstance), "Listed asset should be WETH");

        // Update the asset to inactive
        vm.startPrank(address(timelockInstance));
        LendefiInstance.updateAssetConfig(
            address(wethInstance),
            address(wethOracleInstance),
            8, // Oracle decimals
            18, // Asset decimals
            0, // Inactive
            800, // 80% borrow threshold
            850, // 85% liquidation threshold
            1_000_000 ether, // Supply limit
            IPROTOCOL.CollateralTier.CROSS_A,
            0 // No isolation debt cap
        );
        vm.stopPrank();

        // Verify it's still in the list (inactive assets remain listed)
        address[] memory assetsInactive = LendefiInstance.getListedAssets();
        assertEq(assetsInactive.length, 1, "Should still have 1 listed asset even when inactive");
        assertEq(assetsInactive[0], address(wethInstance), "Listed asset should still be WETH");
    }
}
