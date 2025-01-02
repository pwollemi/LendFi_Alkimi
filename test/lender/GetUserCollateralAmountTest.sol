// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../BasicDeploy.sol";
import {console2} from "forge-std/console2.sol";
import {IPROTOCOL} from "../../contracts/interfaces/IProtocol.sol";
import {Lendefi} from "../../contracts/lender/Lendefi.sol";
import {MockWBTC} from "../../contracts/mock/MockWBTC.sol";
import {WETHPriceConsumerV3} from "../../contracts/mock/WETHOracle.sol";
import {StablePriceConsumerV3} from "../../contracts/mock/StableOracle.sol";

contract GetUserCollateralAmountTest is BasicDeploy {
    // Token instances
    MockWBTC internal mockWbtc;

    // Oracle instances
    WETHPriceConsumerV3 internal wbtcOracleInstance;
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
        mockWbtc = new MockWBTC();

        // Deploy oracles
        wethOracleInstance = new WETHPriceConsumerV3();
        wbtcOracleInstance = new WETHPriceConsumerV3();
        stableOracleInstance = new StablePriceConsumerV3();

        // Set prices
        wethOracleInstance.setPrice(2500e8); // $2500 per ETH
        wbtcOracleInstance.setPrice(60000e8); // $60,000 per BTC
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
        _setupLiquidity();
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

        // Configure WBTC as both ISOLATED and CROSS_A tier
        LendefiInstance.updateAssetConfig(
            address(mockWbtc),
            address(wbtcOracleInstance),
            8, // Oracle decimals
            8, // Asset decimals
            1, // Active
            800, // 80% borrow threshold
            850, // 85% liquidation threshold
            1_000 * 1e8, // Supply limit
            IPROTOCOL.CollateralTier.ISOLATED,
            1_000_000e6 // Isolation debt cap
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

    function _setupLiquidity() internal {
        // Add liquidity to the protocol
        usdcInstance.mint(guardian, 1_000_000e6);
        vm.startPrank(guardian);
        usdcInstance.approve(address(LendefiInstance), 1_000_000e6);
        LendefiInstance.supplyLiquidity(1_000_000e6);
        vm.stopPrank();
    }

    // Test 1: Get collateral amount for an asset that has been supplied
    function test_GetUserCollateralAmount_Supplied() public {
        // Create a position
        vm.startPrank(alice);
        LendefiInstance.createPosition(address(wethInstance), false);
        uint256 positionId = LendefiInstance.getUserPositionsCount(alice) - 1;
        vm.stopPrank();

        // Supply WETH collateral
        uint256 ethAmount = 5 ether;
        vm.deal(alice, ethAmount);
        vm.startPrank(alice);
        wethInstance.deposit{value: ethAmount}();
        wethInstance.approve(address(LendefiInstance), ethAmount);
        LendefiInstance.supplyCollateral(address(wethInstance), ethAmount, positionId);
        vm.stopPrank();

        // Check collateral amount
        uint256 collateral = LendefiInstance.getUserCollateralAmount(alice, positionId, address(wethInstance));
        assertEq(collateral, ethAmount, "Collateral amount should match supplied amount");
    }

    // Test 2: Get collateral amount for an asset that hasn't been supplied
    function test_GetUserCollateralAmount_NotSupplied() public {
        // Create a position
        vm.startPrank(alice);
        LendefiInstance.createPosition(address(wethInstance), false);
        uint256 positionId = LendefiInstance.getUserPositionsCount(alice) - 1;
        vm.stopPrank();

        // Check collateral amount for an asset that hasn't been supplied
        uint256 collateral = LendefiInstance.getUserCollateralAmount(alice, positionId, address(mockWbtc));
        assertEq(collateral, 0, "Collateral amount should be 0 for unsupplied asset");
    }

    // Test 3: Try to get collateral for an invalid position
    function test_GetUserCollateralAmount_InvalidPosition() public {
        // Try to access an invalid position
        vm.expectRevert(abi.encodeWithSelector(IPROTOCOL.InvalidPosition.selector, alice, 0));
        LendefiInstance.getUserCollateralAmount(alice, 0, address(wethInstance));
    }

    // Test 4: Check after supplying and withdrawing collateral
    function test_GetUserCollateralAmount_AfterWithdrawal() public {
        // Create a position
        vm.startPrank(alice);
        LendefiInstance.createPosition(address(wethInstance), false);
        uint256 positionId = LendefiInstance.getUserPositionsCount(alice) - 1;
        vm.stopPrank();

        // Supply WETH collateral
        uint256 ethAmount = 5 ether;
        vm.deal(alice, ethAmount);
        vm.startPrank(alice);
        wethInstance.deposit{value: ethAmount}();
        wethInstance.approve(address(LendefiInstance), ethAmount);
        LendefiInstance.supplyCollateral(address(wethInstance), ethAmount, positionId);

        // Withdraw part of the collateral
        uint256 withdrawAmount = 2 ether;
        LendefiInstance.withdrawCollateral(address(wethInstance), withdrawAmount, positionId);
        vm.stopPrank();

        // Check remaining collateral amount
        uint256 collateral = LendefiInstance.getUserCollateralAmount(alice, positionId, address(wethInstance));
        assertEq(collateral, ethAmount - withdrawAmount, "Collateral amount should be reduced after withdrawal");
    }

    // Test 5: Check collateral amount in an isolated position
    function test_GetUserCollateralAmount_IsolatedPosition() public {
        // Create an isolated position with WBTC
        vm.startPrank(alice);
        LendefiInstance.createPosition(address(mockWbtc), true);
        uint256 positionId = LendefiInstance.getUserPositionsCount(alice) - 1;
        vm.stopPrank();

        // Supply WBTC collateral
        uint256 btcAmount = 0.5 * 1e8; // 0.5 BTC
        mockWbtc.mint(alice, btcAmount);
        vm.startPrank(alice);
        mockWbtc.approve(address(LendefiInstance), btcAmount);
        LendefiInstance.supplyCollateral(address(mockWbtc), btcAmount, positionId);
        vm.stopPrank();

        // Check collateral amount
        uint256 collateral = LendefiInstance.getUserCollateralAmount(alice, positionId, address(mockWbtc));
        assertEq(collateral, btcAmount, "Collateral amount should match supplied amount in isolated position");

        // Double check that the internal accounting of getUserCollateralAmount for isolated positions works correctly
        IPROTOCOL.UserPosition memory position = LendefiInstance.getUserPosition(alice, positionId);
        address[] memory assets = LendefiInstance.getPositionCollateralAssets(alice, positionId);
        assertTrue(position.isIsolated, "Position should be isolated");
        assertEq(assets[0], address(mockWbtc), "Isolated asset should be WBTC");

        // Calculate credit limit and verify it makes sense based on the collateral
        uint256 creditLimit = LendefiInstance.calculateCreditLimit(alice, positionId);
        uint256 expectedCreditLimit = (btcAmount * 60000e8 * 800 * 1e6) / 1e8 / 1000 / 1e8; //because asset decimals and oracle decimals are 1e8

        assertEq(creditLimit, expectedCreditLimit, "Credit limit calculation should match expected value");
    }
}
