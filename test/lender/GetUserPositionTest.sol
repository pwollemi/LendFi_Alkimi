// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../BasicDeploy.sol";
import {console2} from "forge-std/console2.sol";
import {IPROTOCOL} from "../../contracts/interfaces/IProtocol.sol";
import {Lendefi} from "../../contracts/lender/Lendefi.sol";
import {WETHPriceConsumerV3} from "../../contracts/mock/WETHOracle.sol";
import {StablePriceConsumerV3} from "../../contracts/mock/StableOracle.sol";

contract GetUserPositionTest is BasicDeploy {
    WETHPriceConsumerV3 internal wethOracleInstance;
    StablePriceConsumerV3 internal stableOracleInstance;

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
        _addLiquidity(1_000_000e6); // 1M USDC
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

        vm.stopPrank();
    }

    function _addLiquidity(uint256 amount) internal {
        usdcInstance.mint(guardian, amount);
        vm.startPrank(guardian);
        usdcInstance.approve(address(LendefiInstance), amount);
        LendefiInstance.supplyLiquidity(amount);
        vm.stopPrank();
    }

    function test_GetUserPosition_Empty() public {
        // Create a position without any collateral or debt
        vm.startPrank(alice);
        LendefiInstance.createPosition(address(wethInstance), false); // Non-isolated position
        uint256 positionId = LendefiInstance.getUserPositionsCount(alice) - 1;
        vm.stopPrank();

        // Get the position
        IPROTOCOL.UserPosition memory position = LendefiInstance.getUserPosition(alice, positionId);
        address[] memory assets = LendefiInstance.getPositionCollateralAssets(alice, positionId);

        // Verify initial state
        assertEq(position.isIsolated, false, "Position should not be isolated");
        assertEq(assets.length, 0, "Non Isolated asset should be zero address");
        assertEq(position.debtAmount, 0, "Debt amount should be zero");
        assertEq(position.lastInterestAccrual, 0, "Last interest accrual should be zero");
    }

    function test_GetUserPosition_WithCollateral() public {
        // Create a position and add collateral
        vm.startPrank(alice);
        LendefiInstance.createPosition(address(wethInstance), false);
        uint256 positionId = LendefiInstance.getUserPositionsCount(alice) - 1;
        vm.stopPrank();

        // Add ETH collateral
        uint256 collateralAmount = 5 ether;
        vm.deal(alice, collateralAmount);
        vm.startPrank(alice);
        wethInstance.deposit{value: collateralAmount}();
        wethInstance.approve(address(LendefiInstance), collateralAmount);
        LendefiInstance.supplyCollateral(address(wethInstance), collateralAmount, positionId);
        vm.stopPrank();

        // Get the position
        IPROTOCOL.UserPosition memory position = LendefiInstance.getUserPosition(alice, positionId);
        address[] memory assets = LendefiInstance.getPositionCollateralAssets(alice, positionId);

        // Verify state after adding collateral
        assertEq(position.isIsolated, false, "Position should not be isolated");
        assertEq(assets[0], address(wethInstance), "Non Isolated asset should not be zero address");
        assertEq(position.debtAmount, 0, "Debt amount should be zero");
        assertEq(position.lastInterestAccrual, 0, "Last interest accrual should be zero");

        // Verify collateral was added (need separate function call to check this)
        uint256 collateralBalance = LendefiInstance.getUserCollateralAmount(alice, positionId, address(wethInstance));
        assertEq(collateralBalance, collateralAmount, "Collateral balance incorrect");
    }

    function test_GetUserPosition_WithDebt() public {
        // Create a position, add collateral and borrow
        vm.startPrank(alice);
        LendefiInstance.createPosition(address(wethInstance), false);
        uint256 positionId = LendefiInstance.getUserPositionsCount(alice) - 1;
        vm.stopPrank();

        // Add ETH collateral
        uint256 collateralAmount = 10 ether; // Worth $25,000
        vm.deal(alice, collateralAmount);
        vm.startPrank(alice);
        wethInstance.deposit{value: collateralAmount}();
        wethInstance.approve(address(LendefiInstance), collateralAmount);
        LendefiInstance.supplyCollateral(address(wethInstance), collateralAmount, positionId);

        // Borrow USDC
        uint256 borrowAmount = 10_000e6; // $10,000
        LendefiInstance.borrow(positionId, borrowAmount);

        // Store current timestamp for verification
        uint256 currentTimestamp = block.timestamp;
        vm.stopPrank();

        // Get the position
        IPROTOCOL.UserPosition memory position = LendefiInstance.getUserPosition(alice, positionId);
        address[] memory assets = LendefiInstance.getPositionCollateralAssets(alice, positionId);

        // Verify state after borrowing
        assertEq(position.isIsolated, false, "Position should not be isolated");
        assertEq(assets[0], address(wethInstance), "Non Isolated asset should be weth address");
        assertEq(position.debtAmount, borrowAmount, "Debt amount should match borrowed amount");
        assertEq(position.lastInterestAccrual, currentTimestamp, "Last interest accrual should be current timestamp");
    }

    function test_GetUserPosition_IsolatedMode() public {
        // Create an isolated position
        vm.startPrank(alice);
        LendefiInstance.createPosition(address(wethInstance), true); // Isolated position
        uint256 positionId = LendefiInstance.getUserPositionsCount(alice) - 1;
        vm.stopPrank();

        // Get the position
        IPROTOCOL.UserPosition memory position = LendefiInstance.getUserPosition(alice, positionId);
        address[] memory assets = LendefiInstance.getPositionCollateralAssets(alice, positionId);

        // Verify isolated position state
        assertEq(position.isIsolated, true, "Position should be isolated");
        assertEq(assets[0], address(wethInstance), "Isolated asset should be WETH");
        assertEq(position.debtAmount, 0, "Debt amount should be zero");
        assertEq(position.lastInterestAccrual, 0, "Last interest accrual should be zero");
    }

    function test_GetUserPosition_MultiplePositions() public {
        // Create  different positions
        vm.startPrank(alice);

        // Position 1: Non-isolated with WETH
        LendefiInstance.createPosition(address(wethInstance), false);
        uint256 positionId1 = LendefiInstance.getUserPositionsCount(alice) - 1;

        // Position 2: Isolated with USDC
        LendefiInstance.createPosition(address(usdcInstance), true);
        uint256 positionId2 = LendefiInstance.getUserPositionsCount(alice) - 1;
        vm.stopPrank();

        // Get both positions
        IPROTOCOL.UserPosition memory position1 = LendefiInstance.getUserPosition(alice, positionId1);
        IPROTOCOL.UserPosition memory position2 = LendefiInstance.getUserPosition(alice, positionId2);
        address[] memory assets1 = LendefiInstance.getPositionCollateralAssets(alice, positionId1);
        address[] memory assets2 = LendefiInstance.getPositionCollateralAssets(alice, positionId2);

        // Verify position 1
        assertEq(position1.isIsolated, false, "Position 1 should not be isolated");
        assertEq(assets1.length, 0, "Position 1 isolated asset should be zero address");

        // Verify position 2
        assertEq(position2.isIsolated, true, "Position 2 should be isolated");
        assertEq(assets2[0], address(usdcInstance), "Position 2 isolated asset should be USDC");
    }

    function test_GetUserPosition_InvalidPosition() public {
        // Try to get a position that doesn't exist
        vm.expectRevert(abi.encodeWithSelector(IPROTOCOL.InvalidPosition.selector, alice, 0));
        LendefiInstance.getUserPosition(alice, 0);

        // Create a position
        vm.startPrank(alice);
        LendefiInstance.createPosition(address(wethInstance), false);
        vm.stopPrank();

        // Should work now
        LendefiInstance.getUserPosition(alice, 0);

        // But invalid with position ID 1
        vm.expectRevert(abi.encodeWithSelector(IPROTOCOL.InvalidPosition.selector, alice, 1));
        LendefiInstance.getUserPosition(alice, 1);
    }

    function test_GetUserPosition_AfterModification() public {
        // Create a position and add collateral
        vm.startPrank(alice);
        LendefiInstance.createPosition(address(wethInstance), false);
        uint256 positionId = LendefiInstance.getUserPositionsCount(alice) - 1;

        uint256 collateralAmount = 10 ether;
        vm.deal(alice, collateralAmount);
        wethInstance.deposit{value: collateralAmount}();
        wethInstance.approve(address(LendefiInstance), collateralAmount);
        LendefiInstance.supplyCollateral(address(wethInstance), collateralAmount, positionId);

        // Borrow USDC
        uint256 borrowAmount = 10_000e6;
        LendefiInstance.borrow(positionId, borrowAmount);

        // Store current timestamp
        uint256 borrowTimestamp = block.timestamp;

        // Warp time forward
        vm.warp(block.timestamp + 30 days);

        // Repay half the loan
        uint256 repayAmount = 5_000e6;
        usdcInstance.approve(address(LendefiInstance), repayAmount);
        LendefiInstance.repay(positionId, repayAmount);

        // Store new timestamp
        uint256 repayTimestamp = block.timestamp;
        vm.stopPrank();

        // Get the position
        IPROTOCOL.UserPosition memory position = LendefiInstance.getUserPosition(alice, positionId);

        // Verify updated state
        assertEq(position.debtAmount, borrowAmount - repayAmount, "Debt amount should be reduced");
        assertEq(position.lastInterestAccrual, repayTimestamp, "Last interest accrual should be updated");
        assertTrue(position.lastInterestAccrual > borrowTimestamp, "Interest accrual timestamp should increase");
    }
}
