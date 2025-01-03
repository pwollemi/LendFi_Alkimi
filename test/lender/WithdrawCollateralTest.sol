// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../BasicDeploy.sol";
import {console2} from "forge-std/console2.sol";
import {IPROTOCOL} from "../../contracts/interfaces/IProtocol.sol";
import {RWAPriceConsumerV3} from "../../contracts/mock/RWAOracle.sol";
import {WETHPriceConsumerV3} from "../../contracts/mock/WETHOracle.sol";
import {TokenMock} from "../../contracts/mock/TokenMock.sol";
import {Lendefi} from "../../contracts/lender/Lendefi.sol";

contract WithdrawCollateralTest is BasicDeploy {
    // Events to verify
    event WithdrawCollateral(address indexed user, uint256 indexed positionId, address indexed asset, uint256 amount);
    event TVLUpdated(address indexed asset, uint256 amount);

    TokenMock internal rwaToken;
    TokenMock internal stableToken;
    TokenMock internal crossBToken;

    RWAPriceConsumerV3 internal rwaOracleInstance;
    RWAPriceConsumerV3 internal stableOracleInstance;
    RWAPriceConsumerV3 internal crossBOracleInstance;
    WETHPriceConsumerV3 internal wethOracleInstance;

    function setUp() public {
        // Use deployCompleteWithOracle() which sets up all core contracts including the Oracle module
        deployCompleteWithOracle();

        // TGE setup
        vm.prank(guardian);
        tokenInstance.initializeTGE(address(ecoInstance), address(treasuryInstance));

        // Deploy mock tokens (USDC already deployed by deployCompleteWithOracle)
        // Keep existing mock WETH and other token instances
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

        // Register oracles with Oracle module
        vm.startPrank(address(timelockInstance));
        oracleInstance.addOracle(address(wethInstance), address(wethOracleInstance), 8);
        oracleInstance.setPrimaryOracle(address(wethInstance), address(wethOracleInstance));

        oracleInstance.addOracle(address(rwaToken), address(rwaOracleInstance), 8);
        oracleInstance.setPrimaryOracle(address(rwaToken), address(rwaOracleInstance));

        oracleInstance.addOracle(address(stableToken), address(stableOracleInstance), 8);
        oracleInstance.setPrimaryOracle(address(stableToken), address(stableOracleInstance));

        oracleInstance.addOracle(address(crossBToken), address(crossBOracleInstance), 8);
        oracleInstance.setPrimaryOracle(address(crossBToken), address(crossBOracleInstance));
        vm.stopPrank();

        // Setup roles
        vm.prank(guardian);
        ecoInstance.grantRole(REWARDER_ROLE, address(LendefiInstance));

        // No need to manually deploy Lendefi as it's already deployed by deployCompleteWithOracle()
        // Continue with asset setup and liquidity provision
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

    // Test 1: Basic withdrawal of collateral from a non-isolated position
    function test_BasicWithdrawCollateral() public {
        uint256 collateralAmount = 10 ether;
        uint256 withdrawAmount = 5 ether;

        // Create position and supply collateral
        uint256 positionId = _createPosition(bob, address(wethInstance), false);
        _supplyCollateral(bob, address(wethInstance), collateralAmount, positionId);

        uint256 initialTVL = LendefiInstance.assetTVL(address(wethInstance));
        uint256 initialTotalCollateral = LendefiInstance.totalCollateral(address(wethInstance));
        uint256 initialBobBalance = wethInstance.balanceOf(bob);

        vm.startPrank(bob);

        // Expect events
        vm.expectEmit(true, false, false, true);
        emit TVLUpdated(address(wethInstance), initialTVL - withdrawAmount);

        vm.expectEmit(true, true, true, true);
        emit WithdrawCollateral(bob, positionId, address(wethInstance), withdrawAmount);

        // Withdraw some collateral
        LendefiInstance.withdrawCollateral(address(wethInstance), withdrawAmount, positionId);
        vm.stopPrank();

        // Verify state changes
        uint256 finalTVL = LendefiInstance.assetTVL(address(wethInstance));
        uint256 finalTotalCollateral = LendefiInstance.totalCollateral(address(wethInstance));
        uint256 positionCollateral = LendefiInstance.getUserCollateralAmount(bob, positionId, address(wethInstance));
        uint256 finalBobBalance = wethInstance.balanceOf(bob);

        assertEq(finalTVL, initialTVL - withdrawAmount, "TVL should decrease");
        assertEq(finalTotalCollateral, initialTotalCollateral - withdrawAmount, "Total collateral should decrease");
        assertEq(positionCollateral, collateralAmount - withdrawAmount, "Position collateral should be reduced");
        assertEq(finalBobBalance, initialBobBalance + withdrawAmount, "Bob's balance should increase");
    }

    // Test 2: Withdraw all collateral from a position with no debt
    function test_WithdrawAllCollateral() public {
        uint256 collateralAmount = 10 ether;

        // Create position and supply collateral
        uint256 positionId = _createPosition(bob, address(wethInstance), false);
        _supplyCollateral(bob, address(wethInstance), collateralAmount, positionId);

        vm.startPrank(bob);
        // Withdraw all collateral
        LendefiInstance.withdrawCollateral(address(wethInstance), collateralAmount, positionId);
        vm.stopPrank();

        // Verify state changes
        uint256 positionCollateral = LendefiInstance.getUserCollateralAmount(bob, positionId, address(wethInstance));
        assertEq(positionCollateral, 0, "Position collateral should be zero");

        // Check position assets array is empty
        address[] memory posAssets = LendefiInstance.getPositionCollateralAssets(bob, positionId);
        assertEq(posAssets.length, 0, "Position should have no assets");
    }

    // Test 3: Withdraw from isolated position
    function test_WithdrawFromIsolatedPosition() public {
        uint256 collateralAmount = 10 ether;
        uint256 withdrawAmount = 5 ether;

        // Create isolated position
        uint256 positionId = _createPosition(bob, address(rwaToken), true);
        _supplyCollateral(bob, address(rwaToken), collateralAmount, positionId);

        vm.startPrank(bob);
        // Withdraw collateral from isolated position
        LendefiInstance.withdrawCollateral(address(rwaToken), withdrawAmount, positionId);
        vm.stopPrank();

        // Verify state changes
        uint256 positionCollateral = LendefiInstance.getUserCollateralAmount(bob, positionId, address(rwaToken));
        assertEq(positionCollateral, collateralAmount - withdrawAmount, "Position collateral should be reduced");

        // Check position is still in isolation mode
        IPROTOCOL.UserPosition memory position = LendefiInstance.getUserPosition(bob, positionId);
        address[] memory assets = LendefiInstance.getPositionCollateralAssets(bob, positionId);
        assertTrue(position.isIsolated, "Position should remain isolated");
        assertEq(assets[0], address(rwaToken), "Isolated asset should be RWA token");
    }

    // Test 4: Withdraw non-isolated asset from an isolated position should fail
    function test_WithdrawIsolatedAssetFromIsolatedPosition() public {
        // Create isolated position with RWA token
        uint256 positionId = _createPosition(bob, address(rwaToken), true);
        _supplyCollateral(bob, address(rwaToken), 10 ether, positionId);

        vm.startPrank(bob);
        // Try to withdraw an asset that's not in the position
        vm.expectRevert(
            abi.encodeWithSelector(
                IPROTOCOL.InsufficientCollateralBalance.selector, bob, positionId, address(rwaToken), 11 ether, 10 ether
            )
        );
        LendefiInstance.withdrawCollateral(address(rwaToken), 11 ether, positionId);
        vm.stopPrank();
    }

    // Test 6: Withdraw from position with debt
    function test_WithdrawWithDebt() public {
        uint256 collateralAmount = 10 ether;
        uint256 borrowAmount = 5000e6; // $5000 USDC
        uint256 withdrawAmount = 2 ether; // Safe withdrawal amount

        // Create position and supply collateral
        uint256 positionId = _createPosition(bob, address(wethInstance), false);
        _supplyCollateral(bob, address(wethInstance), collateralAmount, positionId);

        // Borrow against the position
        vm.startPrank(bob);
        LendefiInstance.borrow(positionId, borrowAmount);

        // Withdraw some collateral - should succeed as long as it doesn't exceed credit limit
        LendefiInstance.withdrawCollateral(address(wethInstance), withdrawAmount, positionId);
        vm.stopPrank();

        // Verify state changes
        uint256 positionCollateral = LendefiInstance.getUserCollateralAmount(bob, positionId, address(wethInstance));
        assertEq(positionCollateral, collateralAmount - withdrawAmount, "Position collateral should be reduced");

        IPROTOCOL.UserPosition memory position = LendefiInstance.getUserPosition(bob, positionId);
        assertEq(position.debtAmount, borrowAmount, "Debt should remain unchanged");
    }

    // Test 7: Withdraw too much collateral with debt should fail
    function test_WithdrawExceedingCreditLimitWithDebt() public {
        uint256 collateralAmount = 10 ether;
        uint256 borrowAmount = 5000e6; // $5000 USDC
        uint256 tooMuchWithdraw = 8 ether; // Would reduce collateral too much

        // Create position and supply collateral
        uint256 positionId = _createPosition(bob, address(wethInstance), false);
        _supplyCollateral(bob, address(wethInstance), collateralAmount, positionId);

        // Borrow against the position
        vm.startPrank(bob);
        LendefiInstance.borrow(positionId, borrowAmount);
        // Calculate what the credit limit would be after withdrawal
        uint256 newCreditLimit = LendefiInstance.calculateCreditLimit(bob, positionId)
            * (collateralAmount - tooMuchWithdraw) / collateralAmount;

        // Try to withdraw too much collateral
        vm.expectRevert(
            abi.encodeWithSelector(
                IPROTOCOL.WithdrawalExceedsCreditLimit.selector, bob, positionId, borrowAmount, newCreditLimit
            )
        );
        LendefiInstance.withdrawCollateral(address(wethInstance), tooMuchWithdraw, positionId);
        vm.stopPrank();

        // Verify nothing changed
        uint256 positionCollateral = LendefiInstance.getUserCollateralAmount(bob, positionId, address(wethInstance));
        assertEq(positionCollateral, collateralAmount, "Position collateral should remain unchanged");
    }

    // Test 8: Withdraw from a position with multiple assets
    function test_WithdrawFromMultiAssetPosition() public {
        uint256 wethAmount = 5 ether;
        uint256 stableAmount = 1000 ether;
        uint256 withdrawAmount = 2 ether;

        // Create cross position with multiple assets
        uint256 positionId = _createPosition(bob, address(wethInstance), false);
        _supplyCollateral(bob, address(wethInstance), wethAmount, positionId);
        _supplyCollateral(bob, address(stableToken), stableAmount, positionId);

        // Check position has both assets
        address[] memory posAssets = LendefiInstance.getPositionCollateralAssets(bob, positionId);
        assertEq(posAssets.length, 2, "Position should have 2 assets");

        vm.startPrank(bob);
        // Withdraw some WETH
        LendefiInstance.withdrawCollateral(address(wethInstance), withdrawAmount, positionId);
        vm.stopPrank();

        // Verify WETH reduced but position still has both assets
        uint256 wethCollateral = LendefiInstance.getUserCollateralAmount(bob, positionId, address(wethInstance));
        uint256 stableCollateral = LendefiInstance.getUserCollateralAmount(bob, positionId, address(stableToken));

        assertEq(wethCollateral, wethAmount - withdrawAmount, "WETH collateral should be reduced");
        assertEq(stableCollateral, stableAmount, "Stable collateral should remain unchanged");

        // Verify position assets still has both
        posAssets = LendefiInstance.getPositionCollateralAssets(bob, positionId);
        assertEq(posAssets.length, 2, "Position should still have 2 assets");
    }

    // Test 9: Withdraw all of one asset from a multi-asset position
    function test_WithdrawAllOfOneAssetFromMultiAssetPosition() public {
        uint256 wethAmount = 5 ether;
        uint256 stableAmount = 1000 ether;

        // Create cross position with multiple assets
        uint256 positionId = _createPosition(bob, address(wethInstance), false);
        _supplyCollateral(bob, address(wethInstance), wethAmount, positionId);
        _supplyCollateral(bob, address(stableToken), stableAmount, positionId);

        vm.startPrank(bob);
        // Withdraw all WETH
        LendefiInstance.withdrawCollateral(address(wethInstance), wethAmount, positionId);
        vm.stopPrank();

        // Verify WETH is gone but stableToken remains
        uint256 wethCollateral = LendefiInstance.getUserCollateralAmount(bob, positionId, address(wethInstance));
        uint256 stableCollateral = LendefiInstance.getUserCollateralAmount(bob, positionId, address(stableToken));

        assertEq(wethCollateral, 0, "WETH collateral should be zero");
        assertEq(stableCollateral, stableAmount, "Stable collateral should remain unchanged");

        // Verify position assets only contains stableToken now
        address[] memory posAssets = LendefiInstance.getPositionCollateralAssets(bob, positionId);
        assertEq(posAssets.length, 1, "Position should have 1 asset");
        assertEq(posAssets[0], address(stableToken), "Remaining asset should be stableToken");
    }

    // Test 10: Withdraw more than available balance should fail
    function test_WithdrawExceedingBalance() public {
        uint256 collateralAmount = 10 ether;
        uint256 withdrawAmount = 15 ether; // More than supplied

        // Create position and supply collateral
        uint256 positionId = _createPosition(bob, address(wethInstance), false);
        _supplyCollateral(bob, address(wethInstance), collateralAmount, positionId);

        vm.startPrank(bob);
        // Try to withdraw more than available
        vm.expectRevert(
            abi.encodeWithSelector(
                IPROTOCOL.InsufficientCollateralBalance.selector,
                bob,
                positionId,
                address(wethInstance),
                withdrawAmount,
                collateralAmount
            )
        );
        LendefiInstance.withdrawCollateral(address(wethInstance), withdrawAmount, positionId);
        vm.stopPrank();

        // Verify nothing changed
        uint256 positionCollateral = LendefiInstance.getUserCollateralAmount(bob, positionId, address(wethInstance));
        assertEq(positionCollateral, collateralAmount, "Position collateral should remain unchanged");
    }

    // Test 11: Withdraw from invalid position
    function test_WithdrawFromInvalidPosition() public {
        uint256 invalidPositionId = 999;
        vm.startPrank(bob);
        // Try to withdraw from nonexistent position
        vm.expectRevert(abi.encodeWithSelector(IPROTOCOL.InvalidPosition.selector, bob, invalidPositionId));
        LendefiInstance.withdrawCollateral(address(wethInstance), 1 ether, invalidPositionId);
        vm.stopPrank();
    }

    // Test 12: Withdraw when protocol is paused should fail
    function test_WithdrawWhenPaused() public {
        uint256 collateralAmount = 10 ether;

        // Create position and supply collateral
        uint256 positionId = _createPosition(bob, address(wethInstance), false);
        _supplyCollateral(bob, address(wethInstance), collateralAmount, positionId);

        // Pause the protocol
        vm.prank(guardian);
        LendefiInstance.pause();

        vm.startPrank(bob);
        // Try to withdraw when paused
        bytes memory expError = abi.encodeWithSignature("EnforcedPause()");
        vm.expectRevert(expError);
        LendefiInstance.withdrawCollateral(address(wethInstance), 1 ether, positionId);
        vm.stopPrank();
    }

    // Test 13: Withdraw zero amount
    function test_WithdrawZeroAmount() public {
        uint256 collateralAmount = 10 ether;

        // Create position and supply collateral
        uint256 positionId = _createPosition(bob, address(wethInstance), false);
        _supplyCollateral(bob, address(wethInstance), collateralAmount, positionId);

        uint256 initialCollateral = LendefiInstance.getUserCollateralAmount(bob, positionId, address(wethInstance));

        vm.startPrank(bob);
        // Withdraw zero amount
        LendefiInstance.withdrawCollateral(address(wethInstance), 0, positionId);
        vm.stopPrank();

        // Verify nothing changed
        uint256 finalCollateral = LendefiInstance.getUserCollateralAmount(bob, positionId, address(wethInstance));
        assertEq(finalCollateral, initialCollateral, "Position collateral should remain unchanged");
    }

    // Test 14: Withdraw from another user's position should fail
    function test_WithdrawFromAnotherUserPosition() public {
        uint256 collateralAmount = 10 ether;

        // Alice creates and supplies to her position
        uint256 alicePositionId = _createPosition(alice, address(wethInstance), false);
        _supplyCollateral(alice, address(wethInstance), collateralAmount, alicePositionId);

        // Bob tries to withdraw from Alice's position
        vm.startPrank(bob);
        vm.expectRevert(abi.encodeWithSelector(IPROTOCOL.InvalidPosition.selector, bob, alicePositionId));
        LendefiInstance.withdrawCollateral(address(wethInstance), 1 ether, alicePositionId);
        vm.stopPrank();
    }

    // Fuzz Test 1: Withdraw varying amounts from a position with no debt
    function testFuzz_WithdrawVaryingAmounts(uint256 withdrawPct) public {
        uint256 collateralAmount = 10 ether;

        // Bound withdrawal percentage to 0-100%
        withdrawPct = bound(withdrawPct, 0, 100);
        uint256 withdrawAmount = (collateralAmount * withdrawPct) / 100;

        // Create position and supply collateral
        uint256 positionId = _createPosition(bob, address(wethInstance), false);
        _supplyCollateral(bob, address(wethInstance), collateralAmount, positionId);

        vm.startPrank(bob);
        // Withdraw percentage of collateral
        LendefiInstance.withdrawCollateral(address(wethInstance), withdrawAmount, positionId);
        vm.stopPrank();

        // Verify state changes
        uint256 positionCollateral = LendefiInstance.getUserCollateralAmount(bob, positionId, address(wethInstance));
        assertEq(positionCollateral, collateralAmount - withdrawAmount, "Position collateral should be reduced");
    }

    // Fuzz Test 2: Withdraw varying amounts with debt (ensuring within credit limit)
    function testFuzz_WithdrawWithDebt(uint256 withdrawPct) public {
        uint256 collateralAmount = 10 ether; // Worth ~$25,000
        uint256 borrowAmount = 5000e6; // $5,000 USDC

        // Bound withdrawal percentage to a safe range (0-50%), since we need to maintain collateral for the debt
        withdrawPct = bound(withdrawPct, 0, 50);
        uint256 withdrawAmount = (collateralAmount * withdrawPct) / 100;

        // Create position and supply collateral
        uint256 positionId = _createPosition(bob, address(wethInstance), false);
        _supplyCollateral(bob, address(wethInstance), collateralAmount, positionId);

        // Borrow against the position
        vm.startPrank(bob);
        LendefiInstance.borrow(positionId, borrowAmount);

        // Calculate credit limit after potential withdrawal
        uint256 remainingCollateral = collateralAmount - withdrawAmount;
        uint256 remainingValue = (remainingCollateral * 2500e8 * 800) / (1000 * 10 ** 18); // Simplified calculation

        // Skip test if withdrawal would exceed credit limit
        if (remainingValue < borrowAmount) {
            vm.stopPrank();
            return;
        }

        // Withdraw collateral
        LendefiInstance.withdrawCollateral(address(wethInstance), withdrawAmount, positionId);
        vm.stopPrank();

        // Verify state changes
        uint256 positionCollateral = LendefiInstance.getUserCollateralAmount(bob, positionId, address(wethInstance));
        assertEq(positionCollateral, collateralAmount - withdrawAmount, "Position collateral should be reduced");

        // Verify debt remained unchanged
        IPROTOCOL.UserPosition memory position = LendefiInstance.getUserPosition(bob, positionId);
        assertEq(position.debtAmount, borrowAmount, "Debt should remain unchanged");
    }

    // Fuzz Test 3: Multiple withdrawals from multiple assets
    function testFuzz_MultipleWithdrawals(uint256 wethPct, uint256 stablePct) public {
        uint256 wethAmount = 5 ether;
        uint256 stableAmount = 1000 ether;

        // Bound withdrawal percentages to 0-100%
        wethPct = bound(wethPct, 0, 100);
        stablePct = bound(stablePct, 0, 100);

        uint256 wethWithdraw = (wethAmount * wethPct) / 100;
        uint256 stableWithdraw = (stableAmount * stablePct) / 100;

        // Create position with multiple assets
        uint256 positionId = _createPosition(bob, address(wethInstance), false);
        _supplyCollateral(bob, address(wethInstance), wethAmount, positionId);
        _supplyCollateral(bob, address(stableToken), stableAmount, positionId);

        vm.startPrank(bob);
        // Withdraw from both assets
        LendefiInstance.withdrawCollateral(address(wethInstance), wethWithdraw, positionId);
        LendefiInstance.withdrawCollateral(address(stableToken), stableWithdraw, positionId);
        vm.stopPrank();

        // Verify state changes
        uint256 wethCollateral = LendefiInstance.getUserCollateralAmount(bob, positionId, address(wethInstance));
        uint256 stableCollateral = LendefiInstance.getUserCollateralAmount(bob, positionId, address(stableToken));

        assertEq(wethCollateral, wethAmount - wethWithdraw, "WETH collateral should be reduced");
        assertEq(stableCollateral, stableAmount - stableWithdraw, "Stable collateral should be reduced");

        // Verify position assets array is correct
        address[] memory posAssets = LendefiInstance.getPositionCollateralAssets(bob, positionId);
        uint256 expectedLength = 0;
        if (wethCollateral > 0) expectedLength++;
        if (stableCollateral > 0) expectedLength++;
        assertEq(posAssets.length, expectedLength, "Position should have correct number of assets");
    }
}
