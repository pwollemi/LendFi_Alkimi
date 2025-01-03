// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../BasicDeploy.sol";
import {console2} from "forge-std/console2.sol";
import {IPROTOCOL} from "../../contracts/interfaces/IProtocol.sol";
import {Lendefi} from "../../contracts/lender/Lendefi.sol";
import {WETHPriceConsumerV3} from "../../contracts/mock/WETHOracle.sol";
import {StablePriceConsumerV3} from "../../contracts/mock/StableOracle.sol";
import {TokenMock} from "../../contracts/mock/TokenMock.sol";

contract GetAssetDetailsTest is BasicDeploy {
    // Protocol instance

    WETHPriceConsumerV3 internal wethOracleInstance;
    StablePriceConsumerV3 internal stableOracleInstance;

    // Mock tokens for different tiers
    TokenMock internal linkInstance; // For ISOLATED tier
    TokenMock internal uniInstance; // For CROSS_B tier

    // Constants
    uint256 constant INITIAL_LIQUIDITY = 1_000_000e6; // 1M USDC
    uint256 constant ETH_PRICE = 2500e8; // $2500 per ETH
    uint256 constant LINK_PRICE = 15e8; // $15 per LINK
    uint256 constant UNI_PRICE = 8e8; // $8 per UNI

    function setUp() public {
        // Use deployCompleteWithOracle() instead of deployComplete()
        deployCompleteWithOracle();

        // TGE setup
        vm.prank(guardian);
        tokenInstance.initializeTGE(address(ecoInstance), address(treasuryInstance));
        vm.warp(block.timestamp + 90 days);

        // Deploy mock tokens (USDC already deployed by deployCompleteWithOracle())
        wethInstance = new WETH9();
        linkInstance = new TokenMock("Chainlink", "LINK");
        uniInstance = new TokenMock("Uniswap", "UNI");

        // Deploy oracles
        wethOracleInstance = new WETHPriceConsumerV3();
        stableOracleInstance = new StablePriceConsumerV3();

        // Create a custom oracle for Link and UNI
        WETHPriceConsumerV3 linkOracleInstance = new WETHPriceConsumerV3();
        WETHPriceConsumerV3 uniOracleInstance = new WETHPriceConsumerV3();

        // Set prices
        wethOracleInstance.setPrice(int256(ETH_PRICE)); // $2500 per ETH
        stableOracleInstance.setPrice(1e8); // $1 per stable
        linkOracleInstance.setPrice(int256(LINK_PRICE)); // $15 per LINK
        uniOracleInstance.setPrice(int256(UNI_PRICE)); // $8 per UNI

        // Register oracles with Oracle module
        vm.startPrank(address(timelockInstance));
        oracleInstance.addOracle(address(wethInstance), address(wethOracleInstance), 8);
        oracleInstance.setPrimaryOracle(address(wethInstance), address(wethOracleInstance));

        oracleInstance.addOracle(address(linkInstance), address(linkOracleInstance), 8);
        oracleInstance.setPrimaryOracle(address(linkInstance), address(linkOracleInstance));

        oracleInstance.addOracle(address(uniInstance), address(uniOracleInstance), 8);
        oracleInstance.setPrimaryOracle(address(uniInstance), address(uniOracleInstance));

        oracleInstance.addOracle(address(usdcInstance), address(stableOracleInstance), 8);
        oracleInstance.setPrimaryOracle(address(usdcInstance), address(stableOracleInstance));
        vm.stopPrank();

        // Setup roles
        vm.prank(guardian);
        ecoInstance.grantRole(REWARDER_ROLE, address(LendefiInstance));

        _setupAssets(linkOracleInstance, uniOracleInstance);
        _addLiquidity(INITIAL_LIQUIDITY);
    }

    function _setupAssets(WETHPriceConsumerV3 linkOracle, WETHPriceConsumerV3 uniOracle) internal {
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
            10_000e6 // Isolation debt cap
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
            address(linkOracle),
            8, // Oracle decimals
            18, // Asset decimals
            1, // Active
            700, // 70% borrow threshold
            750, // 75% liquidation threshold
            100_000 ether, // Supply limit
            IPROTOCOL.CollateralTier.ISOLATED,
            5_000e6 // Isolation debt cap
        );

        // Configure UNI as CROSS_B tier
        LendefiInstance.updateAssetConfig(
            address(uniInstance),
            address(uniOracle),
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

    function _addLiquidity(uint256 amount) internal {
        usdcInstance.mint(guardian, amount);
        vm.startPrank(guardian);
        usdcInstance.approve(address(LendefiInstance), amount);
        LendefiInstance.supplyLiquidity(amount);
        vm.stopPrank();
    }

    function _addCollateralSupply(address token, uint256 amount, address user, bool isIsolated) internal {
        // Create a position
        vm.startPrank(user);

        // Create position - set isolation mode based on parameter
        LendefiInstance.createPosition(token, isIsolated);
        uint256 positionId = LendefiInstance.getUserPositionsCount(user) - 1;

        // Add collateral
        if (token == address(wethInstance)) {
            vm.deal(user, amount);
            wethInstance.deposit{value: amount}();
            wethInstance.approve(address(LendefiInstance), amount);
        } else if (token == address(linkInstance)) {
            linkInstance.mint(user, amount);
            linkInstance.approve(address(LendefiInstance), amount);
        } else if (token == address(uniInstance)) {
            uniInstance.mint(user, amount);
            uniInstance.approve(address(LendefiInstance), amount);
        } else {
            usdcInstance.mint(user, amount);
            usdcInstance.approve(address(LendefiInstance), amount);
        }

        LendefiInstance.supplyCollateral(token, amount, positionId);
        vm.stopPrank();
    }

    function test_GetAssetDetails_Basic() public {
        // Test basic details for WETH
        (
            uint256 price,
            uint256 totalSupplied,
            uint256 maxSupply,
            uint256 borrowRate,
            uint256 liquidationBonus,
            IPROTOCOL.CollateralTier tier
        ) = LendefiInstance.getAssetDetails(address(wethInstance));

        // Log values for debugging
        console2.log("WETH Price:", price);
        console2.log("WETH Total Supplied:", totalSupplied);
        console2.log("WETH Max Supply:", maxSupply);
        console2.log("WETH Borrow Rate:", borrowRate);
        console2.log("WETH Liquidation Bonus:", liquidationBonus);
        console2.log("WETH Tier:", uint256(tier));

        // Verify returned values
        assertEq(price, ETH_PRICE, "WETH price should match oracle price");
        assertEq(totalSupplied, 0, "WETH total supplied should be 0");
        assertEq(maxSupply, 1_000_000 ether, "WETH max supply incorrect");

        // FIX: Get rates directly from contract
        uint256 expectedBorrowRate = LendefiInstance.getBorrowRate(IPROTOCOL.CollateralTier.CROSS_A);
        uint256 expectedLiquidationBonus = LendefiInstance.getTierLiquidationFee(IPROTOCOL.CollateralTier.CROSS_A);

        assertEq(borrowRate, expectedBorrowRate, "WETH borrow rate should match expected rate");
        assertEq(liquidationBonus, expectedLiquidationBonus, "WETH liquidation bonus should match expected bonus");
        assertEq(uint256(tier), uint256(IPROTOCOL.CollateralTier.CROSS_A), "WETH tier should be CROSS_A");
    }

    function test_GetAssetDetails_AllTiers() public {
        // Test that each asset returns the correct tier
        (,,,, uint256 wethLiquidationBonus, IPROTOCOL.CollateralTier wethTier) =
            LendefiInstance.getAssetDetails(address(wethInstance));

        (,,,, uint256 usdcLiquidationBonus, IPROTOCOL.CollateralTier usdcTier) =
            LendefiInstance.getAssetDetails(address(usdcInstance));

        (,,,, uint256 linkLiquidationBonus, IPROTOCOL.CollateralTier linkTier) =
            LendefiInstance.getAssetDetails(address(linkInstance));

        (,,,, uint256 uniLiquidationBonus, IPROTOCOL.CollateralTier uniTier) =
            LendefiInstance.getAssetDetails(address(uniInstance));

        // FIX: Get liquidation bonuses directly without uint8 casts
        uint256 expectedWethLiquidationBonus = LendefiInstance.getTierLiquidationFee(IPROTOCOL.CollateralTier.CROSS_A);
        uint256 expectedUsdcLiquidationBonus = LendefiInstance.getTierLiquidationFee(IPROTOCOL.CollateralTier.STABLE);
        uint256 expectedLinkLiquidationBonus = LendefiInstance.getTierLiquidationFee(IPROTOCOL.CollateralTier.ISOLATED);
        uint256 expectedUniLiquidationBonus = LendefiInstance.getTierLiquidationFee(IPROTOCOL.CollateralTier.CROSS_B);

        // Verify tiers
        assertEq(uint256(wethTier), uint256(IPROTOCOL.CollateralTier.CROSS_A), "WETH tier should be CROSS_A");
        assertEq(uint256(usdcTier), uint256(IPROTOCOL.CollateralTier.STABLE), "USDC tier should be STABLE");
        assertEq(uint256(linkTier), uint256(IPROTOCOL.CollateralTier.ISOLATED), "LINK tier should be ISOLATED");
        assertEq(uint256(uniTier), uint256(IPROTOCOL.CollateralTier.CROSS_B), "UNI tier should be CROSS_B");

        // Verify liquidation bonuses match the tier
        assertEq(wethLiquidationBonus, expectedWethLiquidationBonus, "WETH liquidation bonus incorrect");
        assertEq(usdcLiquidationBonus, expectedUsdcLiquidationBonus, "USDC liquidation bonus incorrect");
        assertEq(linkLiquidationBonus, expectedLinkLiquidationBonus, "LINK liquidation bonus incorrect");
        assertEq(uniLiquidationBonus, expectedUniLiquidationBonus, "UNI liquidation bonus incorrect");
    }

    function test_GetAssetDetails_WithCollateralSupplied() public {
        // FIX: Use isolated mode for LINK since it's required
        _addCollateralSupply(address(wethInstance), 10 ether, bob, false); // WETH can be non-isolated
        _addCollateralSupply(address(linkInstance), 100 ether, alice, true); // LINK requires isolation mode

        // Get asset details
        (, uint256 wethSupplied,,,,) = LendefiInstance.getAssetDetails(address(wethInstance));
        (, uint256 linkSupplied,,,,) = LendefiInstance.getAssetDetails(address(linkInstance));

        // Verify supplied amounts
        assertEq(wethSupplied, 10 ether, "WETH supplied amount incorrect");
        assertEq(linkSupplied, 100 ether, "LINK supplied amount incorrect");
    }

    function test_GetAssetDetails_AfterPriceChange() public {
        // Get initial details
        (, uint256 initialSupplied, uint256 initialMaxSupply, uint256 initialBorrowRate,,) =
            LendefiInstance.getAssetDetails(address(wethInstance));

        // Change ETH price to $3000
        wethOracleInstance.setPrice(int256(3000e8));

        // Get updated details
        (uint256 newPrice, uint256 newSupplied, uint256 newMaxSupply, uint256 newBorrowRate,,) =
            LendefiInstance.getAssetDetails(address(wethInstance));

        // Verify price changed but other values remain the same
        assertEq(newPrice, 3000e8, "Price should update to new oracle value");
        assertEq(newSupplied, initialSupplied, "Supplied amount shouldn't change with price");
        assertEq(newMaxSupply, initialMaxSupply, "Max supply shouldn't change with price");

        // Borrow rate might change if utilization is affected by price
        if (initialBorrowRate != newBorrowRate) {
            console2.log("Note: Borrow rate changed from", initialBorrowRate, "to", newBorrowRate);
        }
    }

    function test_GetAssetDetails_AfterTierUpdate() public {
        // Get initial details for WETH (CROSS_A tier)
        (,,, uint256 initialBorrowRate, uint256 initialLiquidationBonus, IPROTOCOL.CollateralTier initialTier) =
            LendefiInstance.getAssetDetails(address(wethInstance));

        // Get expected rates based on what's in the contract
        uint256 expectedInitialBorrowRate = LendefiInstance.getBorrowRate(IPROTOCOL.CollateralTier.CROSS_A);
        uint256 expectedInitialLiquidationBonus =
            LendefiInstance.getTierLiquidationFee(IPROTOCOL.CollateralTier.CROSS_A);

        // Update WETH to CROSS_B tier
        vm.prank(address(timelockInstance));
        LendefiInstance.updateAssetTier(address(wethInstance), IPROTOCOL.CollateralTier.CROSS_B);

        // Get updated details
        (,,, uint256 newBorrowRate, uint256 newLiquidationBonus, IPROTOCOL.CollateralTier newTier) =
            LendefiInstance.getAssetDetails(address(wethInstance));

        // Get expected new rates
        uint256 expectedNewBorrowRate = LendefiInstance.getBorrowRate(IPROTOCOL.CollateralTier.CROSS_B);
        uint256 expectedNewLiquidationBonus = LendefiInstance.getTierLiquidationFee(IPROTOCOL.CollateralTier.CROSS_B);

        // Verify tier changed
        assertEq(uint256(initialTier), uint256(IPROTOCOL.CollateralTier.CROSS_A), "Initial tier should be CROSS_A");
        assertEq(uint256(newTier), uint256(IPROTOCOL.CollateralTier.CROSS_B), "New tier should be CROSS_B");

        // Verify rates updated
        assertEq(initialBorrowRate, expectedInitialBorrowRate, "Initial borrow rate should match CROSS_A");
        assertEq(newBorrowRate, expectedNewBorrowRate, "New borrow rate should match CROSS_B");
        assertEq(
            initialLiquidationBonus, expectedInitialLiquidationBonus, "Initial liquidation bonus should match CROSS_A"
        );
        assertEq(newLiquidationBonus, expectedNewLiquidationBonus, "New liquidation bonus should match CROSS_B");
    }

    function test_GetAssetDetails_MaxSupply() public {
        // Get current max supply
        (,, uint256 initialMaxSupply,,,) = LendefiInstance.getAssetDetails(address(wethInstance));
        uint256 newMaxSupply = 500_000 ether;

        // Update max supply threshold
        vm.startPrank(address(timelockInstance));
        LendefiInstance.updateAssetConfig(
            address(wethInstance),
            address(wethOracleInstance),
            8,
            18,
            1,
            800,
            850,
            newMaxSupply, // New max supply
            IPROTOCOL.CollateralTier.CROSS_A,
            10_000e6
        );
        vm.stopPrank();

        // Verify max supply updated
        (,, uint256 updatedMaxSupply,,,) = LendefiInstance.getAssetDetails(address(wethInstance));
        assertEq(initialMaxSupply, 1_000_000 ether, "Initial max supply incorrect");
        assertEq(updatedMaxSupply, newMaxSupply, "Updated max supply incorrect");
    }
}
