// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../BasicDeploy.sol";
import {console2} from "forge-std/console2.sol";
import {IPROTOCOL} from "../../contracts/interfaces/IProtocol.sol";
import {RWAPriceConsumerV3} from "../../contracts/mock/RWAOracle.sol";
import {WETHPriceConsumerV3} from "../../contracts/mock/WETHOracle.sol";
import {TokenMock} from "../../contracts/mock/TokenMock.sol";
import {Lendefi} from "../../contracts/lender/Lendefi.sol";

contract ExitPositionTest is BasicDeploy {
    // Events to verify
    event Repay(address indexed user, uint256 indexed positionId, uint256 amount);
    event WithdrawCollateral(address indexed user, uint256 indexed positionId, address indexed asset, uint256 amount);
    event PositionClosed(address indexed user, uint256 indexed positionId);

    TokenMock internal rwaToken;
    TokenMock internal stableToken;
    TokenMock internal crossBToken;

    RWAPriceConsumerV3 internal rwaOracleInstance;
    RWAPriceConsumerV3 internal stableOracleInstance;
    RWAPriceConsumerV3 internal crossBOracleInstance;
    WETHPriceConsumerV3 internal wethOracleInstance;

    function setUp() public {
        deployComplete();

        // TGE setup
        vm.prank(guardian);
        tokenInstance.initializeTGE(address(ecoInstance), address(treasuryInstance));

        // Deploy mock tokens
        usdcInstance = new USDC();
        wethInstance = new WETH9();
        rwaToken = new TokenMock("Ondo Finance", "ONDO");
        stableToken = new TokenMock("USDT", "USDT");
        crossBToken = new TokenMock("Cross B Token", "CROSSB");

        // Deploy oracles
        wethOracleInstance = new WETHPriceConsumerV3();
        rwaOracleInstance = new RWAPriceConsumerV3();
        stableOracleInstance = new RWAPriceConsumerV3();
        crossBOracleInstance = new RWAPriceConsumerV3();

        // Set prices
        wethOracleInstance.setPrice(2500e8); // $2500 per ETH
        rwaOracleInstance.setPrice(1000e8); // $1000 per RWA token
        stableOracleInstance.setPrice(1e8); // $1 per USDT
        crossBOracleInstance.setPrice(500e8); // $500 per CROSSB token

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
            8,
            18,
            1,
            800, // 80% borrow threshold
            850, // 85% liquidation threshold
            1_000_000 ether,
            IPROTOCOL.CollateralTier.CROSS_A,
            0
        );

        // Configure RWA token as ISOLATED tier
        LendefiInstance.updateAssetConfig(
            address(rwaToken),
            address(rwaOracleInstance),
            8,
            18,
            1,
            650, // 65% borrow threshold
            750, // 75% liquidation threshold
            1_000_000 ether,
            IPROTOCOL.CollateralTier.ISOLATED,
            100_000e6 // Isolation debt cap of 100,000 USDC
        );

        // Configure USDT as STABLE tier
        LendefiInstance.updateAssetConfig(
            address(stableToken),
            address(stableOracleInstance),
            8,
            18,
            1,
            900, // 90% borrow threshold
            950, // 95% liquidation threshold
            1_000_000 ether,
            IPROTOCOL.CollateralTier.STABLE,
            0
        );

        // Configure Cross B token
        LendefiInstance.updateAssetConfig(
            address(crossBToken),
            address(crossBOracleInstance),
            8,
            18,
            1,
            700, // 70% borrow threshold
            800, // 80% liquidation threshold
            1_000_000 ether,
            IPROTOCOL.CollateralTier.CROSS_B,
            0
        );

        vm.stopPrank();
    }

    function _setupLiquidity() internal {
        // Provide liquidity to the protocol
        usdcInstance.mint(alice, 1_000_000e6);
        vm.startPrank(alice);
        usdcInstance.approve(address(LendefiInstance), 1_000_000e6);
        LendefiInstance.supplyLiquidity(1_000_000e6);
        vm.stopPrank();
    }

    function _createPosition(address user, address asset, bool isIsolated) internal returns (uint256) {
        vm.startPrank(user);
        LendefiInstance.createPosition(asset, isIsolated);
        uint256 positionId = LendefiInstance.getUserPositionsCount(user) - 1;
        vm.stopPrank();
        return positionId;
    }

    function _mintTokens(address user, address token, uint256 amount) internal {
        if (token == address(wethInstance)) {
            vm.deal(user, amount);
            vm.prank(user);
            wethInstance.deposit{value: amount}();
        } else {
            TokenMock(token).mint(user, amount);
        }
    }

    function _supplyCollateral(address user, address token, uint256 amount, uint256 positionId) internal {
        _mintTokens(user, token, amount);
        vm.startPrank(user);
        IERC20(token).approve(address(LendefiInstance), amount);
        LendefiInstance.supplyCollateral(token, amount, positionId);
        vm.stopPrank();
    }

    function _borrowUSDC(address user, uint256 positionId, uint256 amount) internal {
        vm.startPrank(user);
        LendefiInstance.borrow(positionId, amount);
        vm.stopPrank();
    }

    // Test 1: Exit position with no debt and single asset
    function test_ExitPositionNoDebtSingleAsset() public {
        // Setup - Create position with collateral but no debt
        uint256 collateralAmount = 10 ether;
        uint256 positionId = _createPosition(bob, address(wethInstance), false);
        _supplyCollateral(bob, address(wethInstance), collateralAmount, positionId);

        uint256 initialBobWeth = wethInstance.balanceOf(bob);
        uint256 initialPositionsCount = LendefiInstance.getUserPositionsCount(bob);

        vm.startPrank(bob);

        // Expect events
        vm.expectEmit(true, true, true, true);
        emit WithdrawCollateral(bob, positionId, address(wethInstance), collateralAmount);

        vm.expectEmit(true, true, false, false);
        emit PositionClosed(bob, positionId);

        // Exit position
        LendefiInstance.exitPosition(positionId);
        vm.stopPrank();

        // Verify state changes
        uint256 finalBobWeth = wethInstance.balanceOf(bob);
        uint256 finalPositionsCount = LendefiInstance.getUserPositionsCount(bob);

        // Check collateral is returned
        assertEq(finalBobWeth, initialBobWeth + collateralAmount, "Collateral should be returned to user");

        // Position count remains the same since we now mark as closed instead of deleting
        assertEq(finalPositionsCount, initialPositionsCount, "Position count should remain the same");

        // Check position is marked as closed
        IPROTOCOL.UserPosition memory position = LendefiInstance.getUserPosition(bob, positionId);
        assertEq(
            uint256(position.status), uint256(IPROTOCOL.PositionStatus.CLOSED), "Position should be marked as CLOSED"
        );
    }

    // Test 2: Exit position with debt
    function test_ExitPositionWithDebt() public {
        // Setup - Create position with collateral and debt
        uint256 collateralAmount = 10 ether;
        uint256 borrowAmount = 5000e6;

        uint256 positionId = _createPosition(bob, address(wethInstance), false);
        _supplyCollateral(bob, address(wethInstance), collateralAmount, positionId);
        _borrowUSDC(bob, positionId, borrowAmount);

        // Mint USDC for repayment
        usdcInstance.mint(bob, borrowAmount * 2); // Extra for interest

        uint256 initialBobWeth = wethInstance.balanceOf(bob);
        uint256 initialBobUSDC = usdcInstance.balanceOf(bob);
        uint256 initialTotalBorrow = LendefiInstance.totalBorrow();

        vm.startPrank(bob);
        usdcInstance.approve(address(LendefiInstance), type(uint256).max);

        // Calculate actual debt with interest
        uint256 debtWithInterest = LendefiInstance.calculateDebtWithInterest(bob, positionId);

        // Expect events for repayment and collateral withdrawal
        vm.expectEmit(true, true, false, true);
        emit Repay(bob, positionId, debtWithInterest);

        vm.expectEmit(true, true, true, true);
        emit WithdrawCollateral(bob, positionId, address(wethInstance), collateralAmount);

        // Exit position
        LendefiInstance.exitPosition(positionId);
        vm.stopPrank();

        // Verify state changes
        uint256 finalBobWeth = wethInstance.balanceOf(bob);
        uint256 finalBobUSDC = usdcInstance.balanceOf(bob);
        uint256 finalTotalBorrow = LendefiInstance.totalBorrow();

        assertEq(finalBobWeth, initialBobWeth + collateralAmount, "Collateral should be returned to user");
        assertEq(finalBobUSDC, initialBobUSDC - debtWithInterest, "USDC should be used for repayment");
        assertEq(finalTotalBorrow, initialTotalBorrow - debtWithInterest, "Total borrow should decrease");

        // Check position is marked as closed
        IPROTOCOL.UserPosition memory position = LendefiInstance.getUserPosition(bob, positionId);
        assertEq(
            uint256(position.status), uint256(IPROTOCOL.PositionStatus.CLOSED), "Position should be marked as CLOSED"
        );

        // Verify position debt is cleared
        assertEq(position.debtAmount, 0, "Position debt should be cleared");
    }

    // Test 3: Exit isolated position
    function test_ExitIsolatedPosition() public {
        // Setup - Create isolated position
        uint256 collateralAmount = 10 ether;
        uint256 positionId = _createPosition(bob, address(rwaToken), true);
        _supplyCollateral(bob, address(rwaToken), collateralAmount, positionId);

        vm.startPrank(bob);

        // Exit position
        LendefiInstance.exitPosition(positionId);
        vm.stopPrank();

        // Verify position is marked as closed
        IPROTOCOL.UserPosition memory position = LendefiInstance.getUserPosition(bob, positionId);
        assertEq(
            uint256(position.status), uint256(IPROTOCOL.PositionStatus.CLOSED), "Position should be marked as CLOSED"
        );

        // Verify isolated flag is preserved but no collateral remains
        assertTrue(position.isIsolated, "Position should still have isIsolated flag");

        // Check collateral is returned
        uint256 remainingCollateral = LendefiInstance.getUserCollateralAmount(bob, positionId, address(rwaToken));
        assertEq(remainingCollateral, 0, "No collateral should remain in position");
    }

    // Test 4: Exit position with multiple assets
    function test_ExitPositionMultipleAssets() public {
        // Setup position with multiple assets
        uint256 wethAmount = 5 ether;
        uint256 stableAmount = 1000 ether;

        uint256 positionId = _createPosition(bob, address(wethInstance), false);
        _supplyCollateral(bob, address(wethInstance), wethAmount, positionId);
        _supplyCollateral(bob, address(stableToken), stableAmount, positionId);

        uint256 initialBobWeth = wethInstance.balanceOf(bob);
        uint256 initialBobStable = stableToken.balanceOf(bob);

        vm.startPrank(bob);

        // Exit position
        LendefiInstance.exitPosition(positionId);
        vm.stopPrank();

        // Verify all collateral returned
        uint256 finalBobWeth = wethInstance.balanceOf(bob);
        uint256 finalBobStable = stableToken.balanceOf(bob);

        assertEq(finalBobWeth, initialBobWeth + wethAmount, "WETH should be returned to user");
        assertEq(finalBobStable, initialBobStable + stableAmount, "Stable tokens should be returned to user");

        // Verify position is marked as closed
        IPROTOCOL.UserPosition memory position = LendefiInstance.getUserPosition(bob, positionId);
        assertEq(
            uint256(position.status), uint256(IPROTOCOL.PositionStatus.CLOSED), "Position should be marked as CLOSED"
        );

        // Check no collateral remains
        uint256 remainingWeth = LendefiInstance.getUserCollateralAmount(bob, positionId, address(wethInstance));
        uint256 remainingStable = LendefiInstance.getUserCollateralAmount(bob, positionId, address(stableToken));

        assertEq(remainingWeth, 0, "No WETH collateral should remain");
        assertEq(remainingStable, 0, "No stable collateral should remain");
    }

    // Test 5: Exit position with insufficient USDC for debt repayment
    function test_ExitPositionInsufficientUSDC() public {
        // Setup position with debt
        uint256 collateralAmount = 10 ether;
        uint256 borrowAmount = 5000e6;

        uint256 positionId = _createPosition(bob, address(wethInstance), false);
        _supplyCollateral(bob, address(wethInstance), collateralAmount, positionId);
        _borrowUSDC(bob, positionId, borrowAmount);

        // Ensure bob has zero USDC balance
        vm.startPrank(bob);
        uint256 bobUsdcBalance = usdcInstance.balanceOf(bob);
        if (bobUsdcBalance > 0) {
            usdcInstance.transfer(address(0x1), bobUsdcBalance);
        }

        // Verify bob has no USDC
        assertEq(usdcInstance.balanceOf(bob), 0, "Bob should have zero USDC balance");

        // Approve spending (even with 0 balance)
        usdcInstance.approve(address(LendefiInstance), type(uint256).max);

        // Calculate debt with interest to verify it's greater than zero
        uint256 debtWithInterest = LendefiInstance.calculateDebtWithInterest(bob, positionId);
        assertTrue(debtWithInterest > 0, "Position should have debt");

        // Try to exit position without enough USDC
        vm.expectRevert(
            abi.encodeWithSelector(
                IPROTOCOL.InsufficientTokenBalance.selector,
                address(usdcInstance),
                bob,
                0 // Bob's USDC balance is 0
            )
        );
        LendefiInstance.exitPosition(positionId);
        vm.stopPrank();

        // Verify position is still active
        IPROTOCOL.UserPosition memory position = LendefiInstance.getUserPosition(bob, positionId);
        assertEq(uint256(position.status), uint256(IPROTOCOL.PositionStatus.ACTIVE), "Position should remain ACTIVE");
    }

    // Test 6: Check multiple positions remain with correct status after exiting one
    function test_MultiplePositionsStatuses() public {
        // Create multiple positions
        uint256 position0 = _createPosition(bob, address(wethInstance), false);
        uint256 position1 = _createPosition(bob, address(stableToken), false);

        // Supply collateral to both positions
        _supplyCollateral(bob, address(wethInstance), 5 ether, position0);
        _supplyCollateral(bob, address(stableToken), 1000 ether, position1);

        // Borrow with position1
        _borrowUSDC(bob, position1, 200e6);

        // Exit position0
        vm.startPrank(bob);
        LendefiInstance.exitPosition(position0);
        vm.stopPrank();

        // Verify position0 is marked as closed
        IPROTOCOL.UserPosition memory position0View = LendefiInstance.getUserPosition(bob, position0);
        assertEq(
            uint256(position0View.status),
            uint256(IPROTOCOL.PositionStatus.CLOSED),
            "Position 0 should be marked as CLOSED"
        );

        // Verify position1 remains active
        IPROTOCOL.UserPosition memory position1View = LendefiInstance.getUserPosition(bob, position1);
        assertEq(
            uint256(position1View.status), uint256(IPROTOCOL.PositionStatus.ACTIVE), "Position 1 should remain ACTIVE"
        );

        // Verify position count remains the same
        uint256 positionsCount = LendefiInstance.getUserPositionsCount(bob);
        assertEq(positionsCount, 2, "Position count should remain 2");
    }

    // Test 7: Exit and reuse position ID
    function test_ExitAndReusePosition() public {
        // Create and exit a position
        uint256 positionId = _createPosition(bob, address(wethInstance), false);
        _supplyCollateral(bob, address(wethInstance), 5 ether, positionId);

        vm.startPrank(bob);
        LendefiInstance.exitPosition(positionId);

        // Position is now closed
        IPROTOCOL.UserPosition memory closedPosition = LendefiInstance.getUserPosition(bob, positionId);
        assertEq(
            uint256(closedPosition.status),
            uint256(IPROTOCOL.PositionStatus.CLOSED),
            "Position should be marked as CLOSED"
        );

        // Cannot supply collateral to closed position
        _mintTokens(bob, address(stableToken), 1000 ether);
        IERC20(address(stableToken)).approve(address(LendefiInstance), 1000 ether);

        vm.expectRevert(abi.encodeWithSelector(IPROTOCOL.InactivePosition.selector, bob, positionId));
        LendefiInstance.supplyCollateral(address(stableToken), 1000 ether, positionId);
        vm.stopPrank();

        // Create new position - should have different ID
        uint256 newPositionId = _createPosition(bob, address(stableToken), false);
        assertEq(newPositionId, 1, "New position should have ID 1");

        // New position should be active
        IPROTOCOL.UserPosition memory newPosition = LendefiInstance.getUserPosition(bob, newPositionId);
        assertEq(uint256(newPosition.status), uint256(IPROTOCOL.PositionStatus.ACTIVE), "New position should be ACTIVE");
    }

    // Test 8: Exit position with zero collateral
    function test_ExitPositionZeroCollateral() public {
        // Create position without adding collateral
        uint256 positionId = _createPosition(bob, address(wethInstance), false);

        vm.startPrank(bob);

        // Exit empty position
        LendefiInstance.exitPosition(positionId);
        vm.stopPrank();

        // Verify position is closed
        IPROTOCOL.UserPosition memory position = LendefiInstance.getUserPosition(bob, positionId);
        assertEq(
            uint256(position.status), uint256(IPROTOCOL.PositionStatus.CLOSED), "Position should be marked as CLOSED"
        );
    }

    // Test 9: Exit invalid position
    function test_ExitInvalidPosition() public {
        vm.startPrank(bob);

        uint256 invalidPositionId = 999;

        // Try to exit a non-existent position
        vm.expectRevert(abi.encodeWithSelector(IPROTOCOL.InvalidPosition.selector, bob, invalidPositionId));
        LendefiInstance.exitPosition(invalidPositionId);
        vm.stopPrank();
    }

    // Test 10: Exit position when protocol is paused
    function test_ExitPositionWhenPaused() public {
        // Create position
        uint256 positionId = _createPosition(bob, address(wethInstance), false);
        _supplyCollateral(bob, address(wethInstance), 5 ether, positionId);

        // Pause protocol
        vm.prank(guardian);
        LendefiInstance.pause();

        vm.startPrank(bob);

        // Try to exit when paused
        bytes memory expError = abi.encodeWithSignature("EnforcedPause()");
        vm.expectRevert(expError);
        LendefiInstance.exitPosition(positionId);
        vm.stopPrank();

        // Verify position remains active
        IPROTOCOL.UserPosition memory position = LendefiInstance.getUserPosition(bob, positionId);
        assertEq(uint256(position.status), uint256(IPROTOCOL.PositionStatus.ACTIVE), "Position should remain ACTIVE");
    }

    // Test 11: Exit isolated position with debt
    function test_ExitIsolatedPositionWithDebt() public {
        // Create isolated position
        uint256 positionId = _createPosition(bob, address(rwaToken), true);
        _supplyCollateral(bob, address(rwaToken), 10 ether, positionId);

        // Borrow against isolated position
        _borrowUSDC(bob, positionId, 1000e6);

        // Mint USDC for repayment
        usdcInstance.mint(bob, 2000e6);

        vm.startPrank(bob);
        usdcInstance.approve(address(LendefiInstance), type(uint256).max);

        // Calculate debt with interest
        // uint256 debtWithInterest = LendefiInstance.calculateDebtWithInterest(bob, positionId);

        // Exit position
        LendefiInstance.exitPosition(positionId);
        vm.stopPrank();

        // Verify position is closed and debt cleared
        IPROTOCOL.UserPosition memory position = LendefiInstance.getUserPosition(bob, positionId);
        assertEq(
            uint256(position.status), uint256(IPROTOCOL.PositionStatus.CLOSED), "Position should be marked as CLOSED"
        );
        assertEq(position.debtAmount, 0, "Position debt should be cleared");
    }

    // Test 12: Check storage slots after exit
    function test_StorageSlotsAfterExit() public {
        // Create position with collateral
        uint256 positionId = _createPosition(bob, address(wethInstance), false);
        _supplyCollateral(bob, address(wethInstance), 5 ether, positionId);
        _supplyCollateral(bob, address(stableToken), 1000 ether, positionId);

        // Exit position
        vm.startPrank(bob);
        LendefiInstance.exitPosition(positionId);
        vm.stopPrank();

        // Check position's collateral arrays are empty
        address[] memory collateralAssets = LendefiInstance.getPositionCollateralAssets(bob, positionId);
        assertEq(collateralAssets.length, 0, "Position's collateral assets array should be empty");

        // Ensure collateral storage is properly cleared
        uint256 wethAmount = LendefiInstance.getUserCollateralAmount(bob, positionId, address(wethInstance));
        uint256 stableAmount = LendefiInstance.getUserCollateralAmount(bob, positionId, address(stableToken));

        assertEq(wethAmount, 0, "WETH collateral amount should be zero");
        assertEq(stableAmount, 0, "Stable collateral amount should be zero");
    }

    // Test 13: Verify position summary after exit
    function test_PositionSummaryAfterExit() public {
        // Create position with collateral and debt
        uint256 positionId = _createPosition(bob, address(wethInstance), false);
        _supplyCollateral(bob, address(wethInstance), 5 ether, positionId);
        _borrowUSDC(bob, positionId, 1000e6);

        // Mint USDC for repayment
        usdcInstance.mint(bob, 2000e6);

        // Exit position
        vm.startPrank(bob);
        usdcInstance.approve(address(LendefiInstance), type(uint256).max);
        LendefiInstance.exitPosition(positionId);
        vm.stopPrank();

        // Get position summary
        (
            uint256 totalCollateralValue,
            uint256 currentDebt,
            uint256 availableCredit,
            bool isIsolated,
            IPROTOCOL.PositionStatus status
        ) = LendefiInstance.getPositionSummary(bob, positionId);

        // Verify summary values
        assertEq(totalCollateralValue, 0, "Collateral value should be zero");
        assertEq(currentDebt, 0, "Debt should be zero");
        assertEq(availableCredit, 0, "Available credit should be zero");
        assertFalse(isIsolated, "Position should not be isolated");
        assertEq(uint256(status), uint256(IPROTOCOL.PositionStatus.CLOSED), "Status should be CLOSED");
    }

    // Fuzz Test: Exit positions with varying debt amounts
    function testFuzz_ExitPositionsWithVaryingDebt(uint256 debtPct) public {
        // Bound debt percentage to reasonable values (1-50%)
        debtPct = bound(debtPct, 1, 50);

        // Create position with collateral
        uint256 collateralAmount = 10 ether;
        uint256 positionId = _createPosition(bob, address(wethInstance), false);
        _supplyCollateral(bob, address(wethInstance), collateralAmount, positionId);

        // Calculate max possible debt based on credit limit
        uint256 maxCredit = LendefiInstance.calculateCreditLimit(bob, positionId);
        uint256 borrowAmount = (maxCredit * debtPct) / 100;

        // Ensure minimum borrowAmount
        if (borrowAmount < 100e6) {
            borrowAmount = 100e6;
        }

        // Borrow
        _borrowUSDC(bob, positionId, borrowAmount);

        // Mint USDC for repayment (with extra for interest)
        uint256 debtWithInterest = LendefiInstance.calculateDebtWithInterest(bob, positionId);
        usdcInstance.mint(bob, debtWithInterest * 2);

        vm.startPrank(bob);
        usdcInstance.approve(address(LendefiInstance), type(uint256).max);

        // Exit position
        LendefiInstance.exitPosition(positionId);
        vm.stopPrank();

        // Verify position is closed with proper status
        IPROTOCOL.UserPosition memory position = LendefiInstance.getUserPosition(bob, positionId);
        assertEq(
            uint256(position.status), uint256(IPROTOCOL.PositionStatus.CLOSED), "Position should be marked as CLOSED"
        );

        // Verify debt and collateral are cleared
        assertEq(position.debtAmount, 0, "Position debt should be cleared");
        uint256 remainingCollateral = LendefiInstance.getUserCollateralAmount(bob, positionId, address(wethInstance));
        assertEq(remainingCollateral, 0, "No collateral should remain");
    }
}
