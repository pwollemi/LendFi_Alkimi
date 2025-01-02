// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../BasicDeploy.sol";
import {console2} from "forge-std/console2.sol";
import {IPROTOCOL} from "../../contracts/interfaces/IProtocol.sol";
import {Lendefi} from "../../contracts/lender/Lendefi.sol";
import {WETHPriceConsumerV3} from "../../contracts/mock/WETHOracle.sol";
import {StablePriceConsumerV3} from "../../contracts/mock/StableOracle.sol";

contract GetPositionSummaryTest is BasicDeploy {
    WETHPriceConsumerV3 internal wethOracleInstance;
    StablePriceConsumerV3 internal stableOracleInstance;

    uint256 constant INITIAL_LIQUIDITY = 1_000_000e6; // 1M USDC
    uint256 constant ETH_PRICE = 2500e8; // $2500 per ETH

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
        wethOracleInstance.setPrice(int256(ETH_PRICE)); // $2500 per ETH
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
        _addLiquidity(INITIAL_LIQUIDITY);
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
            10_000e6 // Add isolation debt cap of 10,000 USDC
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

    function _createPositionWithCollateral(
        address user,
        address collateralAsset,
        uint256 collateralAmount,
        bool isIsolated
    ) internal returns (uint256 positionId) {
        vm.startPrank(user);

        // Create position
        LendefiInstance.createPosition(collateralAsset, isIsolated);
        positionId = LendefiInstance.getUserPositionsCount(user) - 1;

        // Provide collateral
        if (collateralAsset == address(wethInstance)) {
            vm.deal(user, collateralAmount);
            wethInstance.deposit{value: collateralAmount}();
            wethInstance.approve(address(LendefiInstance), collateralAmount);
        } else {
            usdcInstance.mint(user, collateralAmount);
            usdcInstance.approve(address(LendefiInstance), collateralAmount);
        }

        LendefiInstance.supplyCollateral(collateralAsset, collateralAmount, positionId);
        vm.stopPrank();

        return positionId;
    }

    function _borrowUSDC(address user, uint256 positionId, uint256 amount) internal {
        vm.startPrank(user);
        LendefiInstance.borrow(positionId, amount);
        vm.stopPrank();
    }

    function test_GetPositionSummary_NonIsolatedPosition() public {
        // Create a non-isolated position with WETH as collateral
        uint256 collateralAmount = 10 ether; // 10 ETH @ $2500 = $25,000
        uint256 positionId = _createPositionWithCollateral(alice, address(wethInstance), collateralAmount, false);

        // With 80% borrow threshold for CROSS_A tier, credit limit should be $20,000
        uint256 borrowAmount = 10_000e6; // $10,000
        _borrowUSDC(alice, positionId, borrowAmount);

        // Get position summary
        (
            uint256 totalCollateralValue,
            uint256 currentDebt,
            uint256 availableCredit,
            bool isIsolated,
            IPROTOCOL.PositionStatus status
        ) = LendefiInstance.getPositionSummary(alice, positionId);

        // Log results
        console2.log("Total collateral value:", totalCollateralValue);
        console2.log("Current debt:", currentDebt);
        console2.log("Available credit:", availableCredit);
        console2.log("Is isolated:", isIsolated ? "Yes" : "No");
        console2.log("Position status:", uint256(status));

        // Calculate expected collateral value
        // 10 ETH * $2500 * WAD / 1e18 / 1e8 = $25,000
        uint256 expectedCollateralValue = (10 ether * 2500e8 * 1e6) / 1e18 / 1e8;

        // Verify returned values
        assertEq(totalCollateralValue, expectedCollateralValue, "Total collateral value incorrect");
        assertEq(currentDebt, borrowAmount, "Current debt incorrect"); // No interest has accrued yet
        assertEq(availableCredit, (expectedCollateralValue * 800) / 1000, "Available credit incorrect");
        assertFalse(isIsolated, "Position should not be isolated");
        assertEq(uint256(status), uint256(IPROTOCOL.PositionStatus.ACTIVE), "Position should be active");
    }

    function test_GetPositionSummary_IsolatedPosition() public {
        // Create an isolated position with WETH as collateral
        uint256 collateralAmount = 5 ether; // 5 ETH @ $2500 = $12,500
        uint256 positionId = _createPositionWithCollateral(alice, address(wethInstance), collateralAmount, true);

        // With 80% borrow threshold for CROSS_A tier, credit limit should be $10,000
        // Isolation debt cap is 10,000 USDC so we stay under that limit
        uint256 borrowAmount = 5_000e6; // $5,000
        _borrowUSDC(alice, positionId, borrowAmount);

        // Get position summary
        (
            uint256 totalCollateralValue,
            uint256 currentDebt,
            uint256 availableCredit,
            bool isIsolated,
            IPROTOCOL.PositionStatus status
        ) = LendefiInstance.getPositionSummary(alice, positionId);

        // Log results
        console2.log("Total collateral value (isolated):", totalCollateralValue);
        console2.log("Current debt (isolated):", currentDebt);
        console2.log("Available credit (isolated):", availableCredit);
        console2.log("Is isolated:", isIsolated ? "Yes" : "No");
        console2.log("Position status:", uint256(status));

        // Calculate expected collateral value
        // 5 ETH * $2500 * WAD / 1e18 / 1e8 = $12,500
        uint256 expectedCollateralValue = (5 ether * 2500e8 * 1e6) / 1e18 / 1e8;

        // Verify returned values
        assertEq(totalCollateralValue, expectedCollateralValue, "Total collateral value incorrect");
        assertEq(currentDebt, borrowAmount, "Current debt incorrect"); // No interest has accrued yet
        assertEq(availableCredit, (expectedCollateralValue * 800) / 1000, "Available credit incorrect");
        assertTrue(isIsolated, "Position should be isolated");
        assertEq(uint256(status), uint256(IPROTOCOL.PositionStatus.ACTIVE), "Position should be active");
    }

    function test_GetPositionSummary_WithInterestAccrual() public {
        // Create a position with ETH collateral
        uint256 collateralAmount = 10 ether; // 10 ETH @ $2500 = $25,000
        uint256 positionId = _createPositionWithCollateral(alice, address(wethInstance), collateralAmount, false);

        // Borrow some USDC
        uint256 borrowAmount = 10_000e6; // $10,000
        _borrowUSDC(alice, positionId, borrowAmount);

        // Get position summary before time passes
        (uint256 initialCollateralValue, uint256 initialDebt, uint256 initialCreditLimit,,) =
            LendefiInstance.getPositionSummary(alice, positionId);

        // Calculate initial remaining credit (what can still be borrowed)
        uint256 initialRemainingCredit = initialCreditLimit - initialDebt;

        // Time passes, interest accrues
        vm.warp(block.timestamp + 365 days); // 1 year passes

        // Update oracle after time warp
        wethOracleInstance.setPrice(int256(ETH_PRICE)); // Same price, updated timestamp

        // Get position summary after time
        (
            uint256 finalCollateralValue,
            uint256 finalDebt,
            uint256 finalCreditLimit,
            ,
            IPROTOCOL.PositionStatus finalStatus
        ) = LendefiInstance.getPositionSummary(alice, positionId);

        // Calculate final remaining credit
        uint256 finalRemainingCredit = finalCreditLimit - finalDebt;

        // Log results
        console2.log("Initial debt:", initialDebt);
        console2.log("Debt after 1 year:", finalDebt);
        console2.log("Interest accrued:", finalDebt - initialDebt);
        console2.log("Initial remaining credit:", initialRemainingCredit);
        console2.log("Final remaining credit:", finalRemainingCredit);

        // Verify that debt has increased due to interest
        assertGt(finalDebt, initialDebt, "Debt should increase after time passes");

        // Collateral value should remain the same if price hasn't changed
        assertEq(
            finalCollateralValue, initialCollateralValue, "Collateral value shouldn't change if price is unchanged"
        );

        // Credit limit should remain the same since collateral value hasn't changed
        assertEq(finalCreditLimit, initialCreditLimit, "Credit limit should remain the same if collateral unchanged");

        // Status should remain ACTIVE
        assertEq(uint256(finalStatus), uint256(IPROTOCOL.PositionStatus.ACTIVE), "Position should remain active");

        // NEW: The remaining credit (credit limit - debt) should decrease as debt increases
        assertLt(
            finalRemainingCredit,
            initialRemainingCredit,
            "Remaining borrowable credit should decrease as debt increases"
        );
    }

    function test_GetPositionSummary_AfterPriceChange() public {
        // Create a position with ETH collateral
        uint256 collateralAmount = 10 ether; // 10 ETH @ $2500 = $25,000
        uint256 positionId = _createPositionWithCollateral(alice, address(wethInstance), collateralAmount, false);

        // Get position summary with initial price
        (uint256 initialCollateralValue,,,,) = LendefiInstance.getPositionSummary(alice, positionId);

        // ETH price increases to $3000
        wethOracleInstance.setPrice(int256(3000e8));

        // Get position summary after price increase
        (uint256 increasedCollateralValue,,,, IPROTOCOL.PositionStatus increasedStatus) =
            LendefiInstance.getPositionSummary(alice, positionId);

        // ETH price drops to $2000
        wethOracleInstance.setPrice(int256(2000e8));

        // Get position summary after price decrease
        (uint256 decreasedCollateralValue,,,, IPROTOCOL.PositionStatus decreasedStatus) =
            LendefiInstance.getPositionSummary(alice, positionId);

        // Log results
        console2.log("Collateral value at $2500:", initialCollateralValue);
        console2.log("Collateral value at $3000:", increasedCollateralValue);
        console2.log("Collateral value at $2000:", decreasedCollateralValue);

        // Verify changes in collateral value
        assertGt(increasedCollateralValue, initialCollateralValue, "Collateral value should increase with price");
        assertLt(decreasedCollateralValue, initialCollateralValue, "Collateral value should decrease with price");

        // Calculate expected values
        // 10 ETH * $3000 * 1e6 / 1e18 / 1e8 = $30,000
        uint256 expectedValueAt3000 = (10 ether * 3000e8 * 1e6) / 1e18 / 1e8;
        // 10 ETH * $2000 * 1e6 / 1e18 / 1e8 = $20,000
        uint256 expectedValueAt2000 = (10 ether * 2000e8 * 1e6) / 1e18 / 1e8;

        assertEq(increasedCollateralValue, expectedValueAt3000, "Collateral value at $3000 incorrect");
        assertEq(decreasedCollateralValue, expectedValueAt2000, "Collateral value at $2000 incorrect");

        // Status should remain ACTIVE regardless of price changes
        assertEq(
            uint256(increasedStatus),
            uint256(IPROTOCOL.PositionStatus.ACTIVE),
            "Position should remain active after price increase"
        );
        assertEq(
            uint256(decreasedStatus),
            uint256(IPROTOCOL.PositionStatus.ACTIVE),
            "Position should remain active after price decrease"
        );
    }

    function test_GetPositionSummary_EmptyPosition() public {
        // Create a position without adding collateral
        vm.startPrank(alice);
        LendefiInstance.createPosition(address(wethInstance), false);
        uint256 positionId = LendefiInstance.getUserPositionsCount(alice) - 1;
        vm.stopPrank();

        // Get position summary
        (
            uint256 totalCollateralValue,
            uint256 currentDebt,
            uint256 availableCredit,
            bool isIsolated,
            IPROTOCOL.PositionStatus status
        ) = LendefiInstance.getPositionSummary(alice, positionId);

        // Verify returned values for empty position
        assertEq(totalCollateralValue, 0, "Total collateral value should be 0");
        assertEq(currentDebt, 0, "Current debt should be 0");
        assertEq(availableCredit, 0, "Available credit should be 0");
        assertFalse(isIsolated, "Position should not be isolated");
        assertEq(uint256(status), uint256(IPROTOCOL.PositionStatus.ACTIVE), "New position should be ACTIVE");
    }

    function test_GetPositionSummary_MultipleAssets() public {
        // Create a non-isolated position with WETH as collateral
        vm.startPrank(alice);
        LendefiInstance.createPosition(address(wethInstance), false);
        uint256 positionId = LendefiInstance.getUserPositionsCount(alice) - 1;

        // Add WETH collateral
        uint256 wethAmount = 5 ether; // 5 ETH @ $2500 = $12,500
        vm.deal(alice, wethAmount);
        wethInstance.deposit{value: wethAmount}();
        wethInstance.approve(address(LendefiInstance), wethAmount);
        LendefiInstance.supplyCollateral(address(wethInstance), wethAmount, positionId);

        // Add USDC collateral
        uint256 usdcAmount = 10_000e6; // $10,000
        usdcInstance.mint(alice, usdcAmount);
        usdcInstance.approve(address(LendefiInstance), usdcAmount);
        LendefiInstance.supplyCollateral(address(usdcInstance), usdcAmount, positionId);
        vm.stopPrank();

        // Get position summary
        (
            uint256 totalCollateralValue,
            uint256 currentDebt,
            uint256 availableCredit,
            bool isIsolated,
            IPROTOCOL.PositionStatus status
        ) = LendefiInstance.getPositionSummary(alice, positionId);

        // Calculate expected collateral values
        // WETH: 5 ETH * $2500 * 1e6 / 1e18 / 1e8 = $12,500
        uint256 wethValue = (5 ether * 2500e8 * 1e6) / 1e18 / 1e8;
        // USDC: 10,000 USDC * 1e8 * 1e6 / 1e6 / 1e8 = $10,000
        uint256 usdcValue = (10_000e6 * 1e8 * 1e6) / 1e6 / 1e8;
        uint256 expectedTotalValue = wethValue + usdcValue;

        // Calculate expected credit limit
        // WETH: 5 ETH * $2500 * 800 / 1000 = $10,000
        uint256 wethCredit = (wethValue * 800) / 1000;
        // USDC: 10,000 USDC * 900 / 1000 = $9,000
        uint256 usdcCredit = (usdcValue * 900) / 1000;
        uint256 expectedTotalCredit = wethCredit + usdcCredit;

        // Log results
        console2.log("WETH collateral value:", wethValue);
        console2.log("USDC collateral value:", usdcValue);
        console2.log("Total collateral value:", totalCollateralValue);

        // Verify returned values
        assertEq(totalCollateralValue, expectedTotalValue, "Total collateral value incorrect");
        assertEq(currentDebt, 0, "Current debt should be 0");
        assertEq(availableCredit, expectedTotalCredit, "Available credit incorrect");
        assertFalse(isIsolated, "Position should not be isolated");
        assertEq(uint256(status), uint256(IPROTOCOL.PositionStatus.ACTIVE), "Position should be ACTIVE");
    }

    function test_GetPositionSummary_ClosedPosition() public {
        // Create a position with ETH collateral
        uint256 collateralAmount = 1 ether;
        uint256 positionId = _createPositionWithCollateral(alice, address(wethInstance), collateralAmount, false);

        // Close the position
        vm.startPrank(alice);
        LendefiInstance.exitPosition(positionId);
        vm.stopPrank();

        // Get position summary
        (
            uint256 totalCollateralValue,
            uint256 currentDebt,
            uint256 availableCredit,
            bool isIsolated,
            IPROTOCOL.PositionStatus status
        ) = LendefiInstance.getPositionSummary(alice, positionId);

        // Verify returned values for closed position
        assertEq(totalCollateralValue, 0, "Collateral value should be 0 after closing");
        assertEq(currentDebt, 0, "Debt should be 0 after closing");
        assertEq(availableCredit, 0, "Available credit should be 0 after closing");
        assertFalse(isIsolated, "Position should not be isolated");
        assertEq(uint256(status), uint256(IPROTOCOL.PositionStatus.CLOSED), "Position status should be CLOSED");
    }

    function test_GetPositionSummary_LiquidatedPosition() public {
        // Create a position with ETH collateral that we'll liquidate
        uint256 collateralAmount = 5 ether;
        uint256 positionId = _createPositionWithCollateral(alice, address(wethInstance), collateralAmount, false);

        // Borrow close to maximum
        uint256 creditLimit = (collateralAmount * 2500e8 * 800 * 1e6) / 1e18 / 1000 / 1e8; // ~$10,000
        uint256 borrowAmount = creditLimit * 90 / 100; // 90% of credit limit
        _borrowUSDC(alice, positionId, borrowAmount);

        // Crash ETH price to trigger liquidation
        wethOracleInstance.setPrice(int256(1000e8)); // $1000 per ETH (60% drop)

        // Setup liquidator
        uint256 liquidatorThreshold = LendefiInstance.liquidatorThreshold();
        vm.prank(address(timelockInstance));
        treasuryInstance.release(address(tokenInstance), bob, liquidatorThreshold);

        // Calculate liquidation cost
        uint256 debtWithInterest = LendefiInstance.calculateDebtWithInterest(alice, positionId);
        uint256 liquidationBonus = LendefiInstance.getPositionLiquidationFee(alice, positionId);
        uint256 totalCost = debtWithInterest + ((debtWithInterest * liquidationBonus) / 1e6);

        // Liquidate the position
        usdcInstance.mint(bob, totalCost * 2); // Extra buffer
        vm.startPrank(bob);
        usdcInstance.approve(address(LendefiInstance), totalCost * 2);
        LendefiInstance.liquidate(alice, positionId);
        vm.stopPrank();

        // Get position summary
        (
            uint256 totalCollateralValue,
            uint256 currentDebt,
            uint256 availableCredit,
            bool isIsolated,
            IPROTOCOL.PositionStatus status
        ) = LendefiInstance.getPositionSummary(alice, positionId);

        // Verify returned values for liquidated position
        assertEq(totalCollateralValue, 0, "Collateral value should be 0 after liquidation");
        assertEq(currentDebt, 0, "Debt should be 0 after liquidation");
        assertEq(availableCredit, 0, "Available credit should be 0 after liquidation");
        assertFalse(isIsolated, "Position should not be isolated after liquidation");
        assertEq(uint256(status), uint256(IPROTOCOL.PositionStatus.LIQUIDATED), "Position status should be LIQUIDATED");
    }
}
