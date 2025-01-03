// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../BasicDeploy.sol";
import {console2} from "forge-std/console2.sol";
import {IPROTOCOL} from "../../contracts/interfaces/IProtocol.sol";
import {Lendefi} from "../../contracts/lender/Lendefi.sol";
import {MockPriceOracle} from "../../contracts/mock/MockPriceOracle.sol";

contract PositionStatusTest is BasicDeploy {
    // Oracle instance
    MockPriceOracle internal wethOracle;

    // Constants
    uint256 constant INITIAL_LIQUIDITY = 1_000_000e6; // 1M USDC

    function setUp() public {
        // Use deployCompleteWithOracle() instead of deployComplete()
        deployCompleteWithOracle();

        // TGE setup
        vm.prank(guardian);
        tokenInstance.initializeTGE(address(ecoInstance), address(treasuryInstance));

        // Deploy WETH (USDC already deployed by deployCompleteWithOracle())
        wethInstance = new WETH9();

        // Deploy price oracle with proper implementation
        wethOracle = new MockPriceOracle();
        wethOracle.setPrice(int256(2500e8)); // $2500 per ETH
        wethOracle.setTimestamp(block.timestamp);
        wethOracle.setRoundId(1);
        wethOracle.setAnsweredInRound(1);

        // Setup roles
        vm.prank(guardian);
        ecoInstance.grantRole(REWARDER_ROLE, address(LendefiInstance));
        // Register the oracle with the Oracle module
        vm.startPrank(address(timelockInstance));
        oracleInstance.addOracle(address(wethInstance), address(wethOracle), 8);
        oracleInstance.setPrimaryOracle(address(wethInstance), address(wethOracle));
        // Update asset config for WETH
        LendefiInstance.updateAssetConfig(
            address(wethInstance),
            address(wethOracle),
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

        // Add initial liquidity
        usdcInstance.mint(guardian, INITIAL_LIQUIDITY);
        vm.startPrank(guardian);
        usdcInstance.approve(address(LendefiInstance), INITIAL_LIQUIDITY);
        LendefiInstance.supplyLiquidity(INITIAL_LIQUIDITY);
        vm.stopPrank();

        // Mint WETH to guardian for distribution
        vm.deal(address(this), 100 ether);
        wethInstance.deposit{value: 100 ether}();
        wethInstance.transfer(guardian, 100 ether);
    }

    function test_InitialPositionStatus() public {
        // Create a new position
        uint256 positionId = _createPosition(bob, address(wethInstance), false);

        // Verify initial status is ACTIVE
        IPROTOCOL.UserPosition memory position = LendefiInstance.getUserPosition(bob, positionId);
        assertEq(uint256(position.status), uint256(IPROTOCOL.PositionStatus.ACTIVE), "New position should be ACTIVE");
    }

    function test_LiquidatedPositionStatus() public {
        // Setup a position that can be liquidated
        uint256 positionId = _setupLiquidatablePosition(bob, address(wethInstance), false);

        // Verify status is ACTIVE before liquidation
        IPROTOCOL.UserPosition memory positionBefore = LendefiInstance.getUserPosition(bob, positionId);
        assertEq(
            uint256(positionBefore.status),
            uint256(IPROTOCOL.PositionStatus.ACTIVE),
            "Position should be ACTIVE before liquidation"
        );

        // Perform liquidation
        _setupLiquidatorAndExecute(bob, positionId, charlie);

        // Verify status is now LIQUIDATED
        IPROTOCOL.UserPosition memory positionAfter = LendefiInstance.getUserPosition(bob, positionId);
        assertEq(
            uint256(positionAfter.status),
            uint256(IPROTOCOL.PositionStatus.LIQUIDATED),
            "Position should be LIQUIDATED after liquidation"
        );
    }

    function test_ClosedPositionStatus() public {
        // Create a new position
        uint256 positionId = _createPosition(bob, address(wethInstance), false);

        // Supply some collateral
        uint256 collateralAmount = 1 ether;
        _mintTokens(bob, address(wethInstance), collateralAmount);

        vm.startPrank(bob);
        wethInstance.approve(address(LendefiInstance), collateralAmount);
        LendefiInstance.supplyCollateral(address(wethInstance), collateralAmount, positionId);

        // Exit position without borrowing
        LendefiInstance.exitPosition(positionId);
        vm.stopPrank();

        // Position should still exist but be marked as CLOSED
        IPROTOCOL.UserPosition memory position = LendefiInstance.getUserPosition(bob, positionId);
        assertEq(
            uint256(position.status),
            uint256(IPROTOCOL.PositionStatus.CLOSED),
            "Position should be marked as CLOSED after exit"
        );

        // Verify no collateral remains
        address[] memory assets = LendefiInstance.getPositionCollateralAssets(bob, positionId);
        assertEq(assets.length, 0, "Position should have no collateral assets after exit");

        // Verify no debt remains
        assertEq(position.debtAmount, 0, "Position should have no debt after exit");
    }

    function test_InvalidOperationsOnClosedPosition() public {
        // Create a position
        uint256 positionId = _createPosition(bob, address(wethInstance), false);

        // Supply collateral
        uint256 collateralAmount = 1 ether;
        _mintTokens(bob, address(wethInstance), collateralAmount);

        vm.startPrank(bob);
        wethInstance.approve(address(LendefiInstance), collateralAmount);
        LendefiInstance.supplyCollateral(address(wethInstance), collateralAmount, positionId);

        // Exit position
        LendefiInstance.exitPosition(positionId);

        // Verify position is actually closed
        IPROTOCOL.UserPosition memory position = LendefiInstance.getUserPosition(bob, positionId);
        assertEq(uint256(position.status), uint256(IPROTOCOL.PositionStatus.CLOSED), "Position should be CLOSED");

        // For borrow, we need to handle the validation in a different way
        // First, borrow amount must be non-zero, otherwise we'll get InvalidBorrowAmount error
        uint256 borrowAmount = 100e6;

        vm.expectRevert(abi.encodeWithSelector(IPROTOCOL.InactivePosition.selector, bob, positionId));
        LendefiInstance.borrow(positionId, borrowAmount);

        // For supply collateral
        vm.expectRevert(abi.encodeWithSelector(IPROTOCOL.InactivePosition.selector, bob, positionId));
        LendefiInstance.supplyCollateral(address(wethInstance), 1 ether, positionId);

        // For withdraw collateral
        vm.expectRevert(abi.encodeWithSelector(IPROTOCOL.InactivePosition.selector, bob, positionId));
        LendefiInstance.withdrawCollateral(address(wethInstance), 0.1 ether, positionId);

        vm.stopPrank();
    }

    function test_InvalidOperationsOnLiquidatedPosition() public {
        // Setup a liquidatable position
        uint256 positionId = _setupLiquidatablePosition(bob, address(wethInstance), false);

        // Liquidate the position
        _setupLiquidatorAndExecute(bob, positionId, charlie);

        // Attempt operations on liquidated position
        vm.startPrank(bob);

        vm.expectRevert(abi.encodeWithSelector(IPROTOCOL.InactivePosition.selector, bob, positionId));
        LendefiInstance.borrow(positionId, 100e6);

        vm.expectRevert(abi.encodeWithSelector(IPROTOCOL.InactivePosition.selector, bob, positionId));
        LendefiInstance.supplyCollateral(address(wethInstance), 1 ether, positionId);

        vm.expectRevert(abi.encodeWithSelector(IPROTOCOL.InactivePosition.selector, bob, positionId));
        LendefiInstance.withdrawCollateral(address(wethInstance), 0.1 ether, positionId);

        vm.expectRevert(abi.encodeWithSelector(IPROTOCOL.InactivePosition.selector, bob, positionId));
        LendefiInstance.exitPosition(positionId);

        vm.stopPrank();
    }

    function test_PositionCountAfterStatusChange() public {
        // Create multiple positions
        uint256 pos1 = _createPosition(bob, address(wethInstance), false);
        uint256 pos2 = _createPosition(bob, address(wethInstance), false);
        uint256 pos3 = _createPosition(bob, address(wethInstance), false);

        // Verify initial count
        uint256 initialCount = LendefiInstance.getUserPositionsCount(bob);
        assertEq(initialCount, 3, "Should have 3 positions initially");

        // Setup and liquidate position 1
        _setupAndLiquidatePosition(bob, pos1, charlie);

        // Close position 2
        _setupAndClosePosition(bob, pos2);

        // Verify count remains unchanged
        uint256 finalCount = LendefiInstance.getUserPositionsCount(bob);
        assertEq(finalCount, initialCount, "Position count should remain unchanged after status changes");

        // Verify individual position statuses
        IPROTOCOL.UserPosition memory position1 = LendefiInstance.getUserPosition(bob, pos1);
        IPROTOCOL.UserPosition memory position2 = LendefiInstance.getUserPosition(bob, pos2);
        IPROTOCOL.UserPosition memory position3 = LendefiInstance.getUserPosition(bob, pos3);

        assertEq(
            uint256(position1.status), uint256(IPROTOCOL.PositionStatus.LIQUIDATED), "Position 1 should be LIQUIDATED"
        );
        assertEq(uint256(position2.status), uint256(IPROTOCOL.PositionStatus.CLOSED), "Position 2 should be CLOSED");
        assertEq(uint256(position3.status), uint256(IPROTOCOL.PositionStatus.ACTIVE), "Position 3 should be ACTIVE");
    }

    function test_GetPositionStatus() public {
        // Create a new position
        uint256 positionId = _createPosition(bob, address(wethInstance), false);

        // Check status in the UserPosition struct
        IPROTOCOL.UserPosition memory position = LendefiInstance.getUserPosition(bob, positionId);
        assertEq(uint256(position.status), uint256(IPROTOCOL.PositionStatus.ACTIVE), "Position status should be ACTIVE");

        // Create another position for liquidation
        uint256 positionId2 = _setupLiquidatablePosition(bob, address(wethInstance), false);
        _setupLiquidatorAndExecute(bob, positionId2, charlie);

        // Check liquidated status
        IPROTOCOL.UserPosition memory liquidatedPosition = LendefiInstance.getUserPosition(bob, positionId2);
        assertEq(
            uint256(liquidatedPosition.status),
            uint256(IPROTOCOL.PositionStatus.LIQUIDATED),
            "Position status should be LIQUIDATED"
        );

        // Close the active position
        _setupAndClosePosition(bob, positionId);

        // Check closed status
        IPROTOCOL.UserPosition memory closedPosition = LendefiInstance.getUserPosition(bob, positionId);
        assertEq(
            uint256(closedPosition.status), uint256(IPROTOCOL.PositionStatus.CLOSED), "Position status should be CLOSED"
        );
    }

    // Helper function to create a position
    function _createPosition(address user, address asset, bool isIsolated) internal returns (uint256) {
        vm.prank(user);
        LendefiInstance.createPosition(asset, isIsolated);
        return LendefiInstance.getUserPositionsCount(user) - 1;
    }

    // Helper function to setup and liquidate a position
    function _setupAndLiquidatePosition(address user, uint256 positionId, address liquidator) internal {
        // Setup a liquidatable position
        _mintTokens(user, address(wethInstance), 5 ether);

        vm.startPrank(user);
        wethInstance.approve(address(LendefiInstance), 5 ether);
        LendefiInstance.supplyCollateral(address(wethInstance), 5 ether, positionId);

        // Calculate credit limit and borrow close to maximum
        uint256 creditLimit = LendefiInstance.calculateCreditLimit(user, positionId);
        uint256 borrowAmount = (creditLimit * 90) / 100; // 90% of credit limit
        LendefiInstance.borrow(positionId, borrowAmount);
        vm.stopPrank();

        // Crash the price significantly
        wethOracle.setPrice(int256(1000e8)); // $1000 per ETH (60% drop)

        // Make sure position is liquidatable
        require(LendefiInstance.isLiquidatable(user, positionId), "Position should be liquidatable");

        // Liquidate position
        _setupLiquidatorAndExecute(user, positionId, liquidator);
    }

    // Helper function to setup and close a position
    function _setupAndClosePosition(address user, uint256 positionId) internal {
        _mintTokens(user, address(wethInstance), 1 ether);

        vm.startPrank(user);
        wethInstance.approve(address(LendefiInstance), 1 ether);
        LendefiInstance.supplyCollateral(address(wethInstance), 1 ether, positionId);
        LendefiInstance.exitPosition(positionId);
        vm.stopPrank();
    }

    // Helper to setup a liquidatable position and return its ID
    function _setupLiquidatablePosition(address user, address asset, bool isIsolated) internal returns (uint256) {
        uint256 positionId = _createPosition(user, asset, isIsolated);

        // Supply collateral
        uint256 collateralAmount = 5 ether; // Substantial collateral
        _mintTokens(user, asset, collateralAmount);

        vm.startPrank(user);
        IERC20(asset).approve(address(LendefiInstance), collateralAmount);
        LendefiInstance.supplyCollateral(asset, collateralAmount, positionId);

        // Calculate safe borrow amount - borrow very close to the limit
        uint256 creditLimit = LendefiInstance.calculateCreditLimit(user, positionId);
        uint256 availableLiquidity = LendefiInstance.totalSuppliedLiquidity() - LendefiInstance.totalBorrow();

        // Take 99% of credit limit or 50% of available liquidity (whichever is less)
        uint256 maxFromCredit = (creditLimit * 99) / 100; // 99% of credit limit
        uint256 maxFromLiquidity = (availableLiquidity * 50) / 100;
        uint256 borrowAmount = maxFromCredit < maxFromLiquidity ? maxFromCredit : maxFromLiquidity;

        // Debug logs
        console2.log("Initial credit limit:", creditLimit);
        console2.log("Borrowing amount:", borrowAmount);

        LendefiInstance.borrow(positionId, borrowAmount);
        vm.stopPrank();

        // Crash the price significantly - from $2500 to $1000 (60% drop)
        wethOracle.setPrice(int256(1000e8));

        // Debug output after price drop
        uint256 debtWithInterest = LendefiInstance.calculateDebtWithInterest(user, positionId);
        uint256 newCreditLimit = LendefiInstance.calculateCreditLimit(user, positionId);
        console2.log("After price drop - debt:", debtWithInterest);
        console2.log("After price drop - credit limit:", newCreditLimit);

        // Verify position is now liquidatable
        bool isLiquidatable = LendefiInstance.isLiquidatable(user, positionId);

        if (!isLiquidatable) {
            // If still not liquidatable, force an even bigger price drop
            wethOracle.setPrice(int256(500e8)); // 80% price drop
            console2.log("Dropping price further to $500");
            isLiquidatable = LendefiInstance.isLiquidatable(user, positionId);

            // Still not liquidatable? Try minimal price
            if (!isLiquidatable) {
                wethOracle.setPrice(int256(100e8)); // 96% price drop
                console2.log("Dropping price further to $100");
                isLiquidatable = LendefiInstance.isLiquidatable(user, positionId);
            }
        }

        require(isLiquidatable, "Position should be liquidatable after price drop");

        return positionId;
    }

    // Helper to mint tokens for testing
    function _mintTokens(address user, address token, uint256 amount) internal {
        if (token == address(wethInstance)) {
            vm.prank(guardian);
            wethInstance.transfer(user, amount);
        } else {
            // Generic ERC20 minting if needed
            vm.prank(guardian);
            IERC20(token).transfer(user, amount);
        }
    }

    // Helper to setup liquidator and execute liquidation
    function _setupLiquidatorAndExecute(address user, uint256 positionId, address liquidator) internal {
        // Give liquidator enough governance tokens
        uint256 liquidatorThreshold = LendefiInstance.liquidatorThreshold();

        vm.prank(address(timelockInstance));
        treasuryInstance.release(address(tokenInstance), liquidator, liquidatorThreshold); // Give enough gov tokens

        // Calculate debt with interest
        uint256 debtWithInterest = LendefiInstance.calculateDebtWithInterest(user, positionId);

        // Get liquidation bonus percentage
        uint256 liquidationBonus = LendefiInstance.getPositionLiquidationFee(user, positionId);

        // Calculate total debt including bonus
        uint256 totalDebtWithBonus = debtWithInterest + ((debtWithInterest * liquidationBonus) / 1e6);

        // Give liquidator enough USDC to cover the debt with bonus
        usdcInstance.mint(liquidator, totalDebtWithBonus * 2); // Extra buffer just to be safe

        // Execute liquidation
        vm.startPrank(liquidator);
        usdcInstance.approve(address(LendefiInstance), totalDebtWithBonus * 2);
        LendefiInstance.liquidate(user, positionId);
        vm.stopPrank();
    }
}
