// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../BasicDeploy.sol";
import {console2} from "forge-std/console2.sol";
import {IPROTOCOL} from "../../contracts/interfaces/IProtocol.sol";
import {Lendefi} from "../../contracts/lender/Lendefi.sol";
import {WETHPriceConsumerV3} from "../../contracts/mock/WETHOracle.sol";
import {StablePriceConsumerV3} from "../../contracts/mock/StableOracle.sol";
import {MockWBTC} from "../../contracts/mock/MockWBTC.sol";

contract GetAssetPriceTest is BasicDeploy {
    // Token instances
    MockWBTC internal wbtcToken;

    // Oracle instances
    WETHPriceConsumerV3 internal wethOracleInstance;
    WETHPriceConsumerV3 internal wbtcOracleInstance;
    StablePriceConsumerV3 internal stableOracleInstance;

    function setUp() public {
        // Use deployCompleteWithOracle() instead of deployComplete()
        deployCompleteWithOracle();

        // TGE setup
        vm.prank(guardian);
        tokenInstance.initializeTGE(address(ecoInstance), address(treasuryInstance));
        vm.warp(block.timestamp + 90 days);

        // Deploy mock tokens (USDC already deployed by deployCompleteWithOracle())
        wethInstance = new WETH9();
        wbtcToken = new MockWBTC();

        // Deploy oracles
        wethOracleInstance = new WETHPriceConsumerV3();
        wbtcOracleInstance = new WETHPriceConsumerV3();
        stableOracleInstance = new StablePriceConsumerV3();

        // Set prices
        wethOracleInstance.setPrice(2500e8); // $2500 per ETH
        wbtcOracleInstance.setPrice(60000e8); // $60,000 per BTC
        stableOracleInstance.setPrice(1e8); // $1 per stable

        // Set minimumOraclesRequired to 1 in the Oracle module
        // This is critically important as the default is 2
        vm.startPrank(address(timelockInstance));
        oracleInstance.updateMinimumOracles(1);

        // Register oracles with Oracle module
        oracleInstance.addOracle(address(wethInstance), address(wethOracleInstance), 8);
        oracleInstance.setPrimaryOracle(address(wethInstance), address(wethOracleInstance));

        oracleInstance.addOracle(address(wbtcToken), address(wbtcOracleInstance), 8);
        oracleInstance.setPrimaryOracle(address(wbtcToken), address(wbtcOracleInstance));

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

        // Configure WBTC as CROSS_A tier
        LendefiInstance.updateAssetConfig(
            address(wbtcToken),
            address(wbtcOracleInstance),
            8, // Oracle decimals
            8, // Asset decimals
            1, // Active
            800, // 80% borrow threshold
            850, // 85% liquidation threshold
            1_000 * 1e8, // Supply limit
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

        vm.stopPrank();
    }

    function test_GetAssetPrice_WETH() public {
        uint256 price = LendefiInstance.getAssetPrice(address(wethInstance));
        assertEq(price, 2500e8, "WETH price should be $2500");
    }

    function test_GetAssetPrice_WBTC() public {
        uint256 price = LendefiInstance.getAssetPrice(address(wbtcToken));
        assertEq(price, 60000e8, "WBTC price should be $60,000");
    }

    function test_GetAssetPrice_USDC() public {
        uint256 price = LendefiInstance.getAssetPrice(address(usdcInstance));
        assertEq(price, 1e8, "USDC price should be $1");
    }

    function test_GetAssetPrice_AfterPriceChange() public {
        // Change the WETH price from $2500 to $3000
        wethOracleInstance.setPrice(3000e8);

        uint256 price = LendefiInstance.getAssetPrice(address(wethInstance));
        assertEq(price, 3000e8, "WETH price should be updated to $3000");
    }

    function test_GetAssetPrice_UnlistedAsset() public {
        // Using an address that's not configured as an asset should revert
        address randomAddress = address(0x123);

        vm.expectRevert();
        LendefiInstance.getAssetPrice(randomAddress);
    }

    function test_GetAssetPrice_MultipleAssets() public {
        uint256 wethPrice = LendefiInstance.getAssetPrice(address(wethInstance));
        uint256 wbtcPrice = LendefiInstance.getAssetPrice(address(wbtcToken));
        uint256 usdcPrice = LendefiInstance.getAssetPrice(address(usdcInstance));

        assertEq(wethPrice, 2500e8, "WETH price should be $2500");
        assertEq(wbtcPrice, 60000e8, "WBTC price should be $60,000");
        assertEq(usdcPrice, 1e8, "USDC price should be $1");

        // Check the ratio of BTC to ETH
        assertEq(wbtcPrice / wethPrice, 24, "WBTC should be worth 24 times more than WETH");
    }
}
