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
    event ExitedIsolationMode(address indexed user, uint256 indexed positionId);
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

        assertEq(finalBobWeth, initialBobWeth + collateralAmount, "Collateral should be returned to user");
        assertEq(finalPositionsCount, initialPositionsCount - 1, "Position should be closed");
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

        // Check position is gone
        uint256 finalPositionsCount = LendefiInstance.getUserPositionsCount(bob);
        assertEq(finalPositionsCount, 0, "Position should be closed");
    }

    // Test 3: Exit isolated position
    function test_ExitIsolatedPosition() public {
        // Setup - Create isolated position
        uint256 collateralAmount = 10 ether;
        uint256 positionId = _createPosition(bob, address(rwaToken), true);
        _supplyCollateral(bob, address(rwaToken), collateralAmount, positionId);

        vm.startPrank(bob);

        // Expect exit isolation mode event
        vm.expectEmit(true, true, false, false);
        emit ExitedIsolationMode(bob, positionId);

        // Exit position
        LendefiInstance.exitPosition(positionId);
        vm.stopPrank();

        // Verify position is gone and isolation mode is exited
        uint256 finalPositionsCount = LendefiInstance.getUserPositionsCount(bob);
        assertEq(finalPositionsCount, 0, "Position should be closed");
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
    }

    // Test 5: Exit position with insufficient USDC for debt repayment
    // Fix the test to ensure bob has no USDC balance
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
                Lendefi.InsufficientTokenBalance.selector,
                address(usdcInstance),
                bob,
                0 // Bob's USDC balance is 0
            )
        );
        LendefiInstance.exitPosition(positionId);
        vm.stopPrank();
    }

    // Test 6: Exit position when it's not the last position (test position swap logic)
    function test_ExitPositionNotLast() public {
        // Create multiple positions
        uint256 position1 = _createPosition(bob, address(wethInstance), false);
        uint256 position2 = _createPosition(bob, address(stableToken), false);

        // Supply collateral to both positions
        _supplyCollateral(bob, address(wethInstance), 5 ether, position1);
        _supplyCollateral(bob, address(stableToken), 1000 ether, position2);

        // Borrow with position2
        _borrowUSDC(bob, position2, 200e6);

        // Remember position2 details for verification
        IPROTOCOL.UserPosition memory position2View = LendefiInstance.getUserPosition(bob, position2);
        uint256 position2Debt = position2View.debtAmount;
        uint256 position2Collateral = LendefiInstance.getUserCollateralAmount(bob, position2, address(stableToken));

        // Exit position1 (not the last)
        vm.startPrank(bob);
        LendefiInstance.exitPosition(position1);
        vm.stopPrank();

        // Verify position1 is now replaced by what was position2
        IPROTOCOL.UserPosition memory swappedPosition = LendefiInstance.getUserPosition(bob, position1);
        uint256 swappedCollateral = LendefiInstance.getUserCollateralAmount(bob, position1, address(stableToken));

        // Check position data was correctly swapped
        assertEq(swappedPosition.debtAmount, position2Debt, "Debt should match position 2");
        assertEq(swappedCollateral, position2Collateral, "Collateral should match position 2");

        // Verify there's now only one position
        uint256 finalPositionsCount = LendefiInstance.getUserPositionsCount(bob);
        assertEq(finalPositionsCount, 1, "Should have only one position left");
    }

    // Test 7: Exit position when it's the last position
    function test_ExitPositionLast() public {
        // Create multiple positions
        uint256 position1 = _createPosition(bob, address(wethInstance), false);
        uint256 position2 = _createPosition(bob, address(stableToken), false);

        // Supply collateral to both
        _supplyCollateral(bob, address(wethInstance), 5 ether, position1);
        _supplyCollateral(bob, address(stableToken), 1000 ether, position2);

        // Exit position2 (the last one)
        vm.startPrank(bob);
        LendefiInstance.exitPosition(position2);
        vm.stopPrank();

        // Verify there's only position1 left
        uint256 finalPositionsCount = LendefiInstance.getUserPositionsCount(bob);
        assertEq(finalPositionsCount, 1, "Should have only one position left");

        // Position1 should still have its original data
        uint256 position1Collateral = LendefiInstance.getUserCollateralAmount(bob, position1, address(wethInstance));
        assertEq(position1Collateral, 5 ether, "Position 1 collateral should be unchanged");
    }

    // Test 8: Exit position with zero collateral
    function test_ExitPositionZeroCollateral() public {
        // Create position without adding collateral
        uint256 positionId = _createPosition(bob, address(wethInstance), false);

        vm.startPrank(bob);

        // Exit empty position
        LendefiInstance.exitPosition(positionId);
        vm.stopPrank();

        // Verify position is gone
        uint256 finalPositionsCount = LendefiInstance.getUserPositionsCount(bob);
        assertEq(finalPositionsCount, 0, "Position should be closed");
    }

    // Test 9: Exit invalid position
    function test_ExitInvalidPosition() public {
        vm.startPrank(bob);

        uint256 invalidPositionId = 999;

        // Try to exit a non-existent position
        vm.expectRevert(abi.encodeWithSelector(Lendefi.InvalidPosition.selector, bob, invalidPositionId));
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

        // Expect events for debt repayment, collateral withdrawal, and isolation exit
        uint256 debtWithInterest = LendefiInstance.calculateDebtWithInterest(bob, positionId);

        vm.expectEmit(true, true, false, true);
        emit Repay(bob, positionId, debtWithInterest);

        vm.expectEmit(true, true, false, false);
        emit ExitedIsolationMode(bob, positionId);

        // Exit position
        LendefiInstance.exitPosition(positionId);
        vm.stopPrank();

        // Verify position is gone and tokens were correctly transferred
        uint256 finalPositionsCount = LendefiInstance.getUserPositionsCount(bob);
        assertEq(finalPositionsCount, 0, "Position should be closed");
    }

    // Fix the array out-of-bounds access in the fuzz test
    function testFuzz_ExitMultiplePositions(uint256 seed) public {
        // Assume reasonable seed values to avoid excessive iteration
        vm.assume(seed > 0);
        vm.assume(seed <= type(uint64).max);

        // Calculate number of positions (1-3)
        uint256 numPositions = (seed % 3) + 1;

        // Setup available assets
        address[] memory availableAssets = new address[](3);
        availableAssets[0] = address(wethInstance);
        availableAssets[1] = address(stableToken);
        availableAssets[2] = address(crossBToken);

        // Track initial balances
        uint256[] memory initialBalances = new uint256[](3);
        initialBalances[0] = wethInstance.balanceOf(bob);
        initialBalances[1] = stableToken.balanceOf(bob);
        initialBalances[2] = crossBToken.balanceOf(bob);

        // Store amounts for later verification
        uint256[] memory suppliedAmounts = new uint256[](numPositions);
        address[] memory usedAssets = new address[](numPositions);

        // Create positions and supply collateral
        for (uint256 i = 0; i < numPositions; i++) {
            // Select asset deterministically but with good distribution
            uint256 assetIndex = uint256(keccak256(abi.encode(seed, i))) % 3;
            address asset = availableAssets[assetIndex];
            usedAssets[i] = asset;

            // Create position
            uint256 positionId = _createPosition(bob, asset, false);

            // Calculate collateral amount (1-10 ETH equivalent)
            uint256 amount = 1 ether + (uint256(keccak256(abi.encode(seed, i, "amount"))) % 9 ether);
            suppliedAmounts[i] = amount;

            // Supply collateral
            _supplyCollateral(bob, asset, amount, positionId);
        }

        // Exit all positions using position 0
        uint256 remainingPositions = LendefiInstance.getUserPositionsCount(bob);
        for (uint256 i = 0; i < remainingPositions; i++) {
            vm.startPrank(bob);
            LendefiInstance.exitPosition(0);
            vm.stopPrank();
        }

        // Verify all positions closed
        assertEq(LendefiInstance.getUserPositionsCount(bob), 0, "All positions should be closed");

        // Verify balances increased appropriately
        bool someTokensReturned = false;
        for (uint256 i = 0; i < 3; i++) {
            uint256 finalBalance;
            if (i == 0) finalBalance = wethInstance.balanceOf(bob);
            else if (i == 1) finalBalance = stableToken.balanceOf(bob);
            else finalBalance = crossBToken.balanceOf(bob);

            // Check if this asset was used
            for (uint256 j = 0; j < numPositions; j++) {
                if (usedAssets[j] == availableAssets[i]) {
                    assertTrue(finalBalance > initialBalances[i], "Balance should increase for used assets");
                    someTokensReturned = true;
                }
            }
        }

        assertTrue(someTokensReturned, "At least one asset should be returned");
    }

    // Fuzz Test 2: Exit positions with varying debt amounts
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

        // Verify position is closed
        uint256 finalPositionsCount = LendefiInstance.getUserPositionsCount(bob);
        assertEq(finalPositionsCount, 0, "Position should be closed");

        // Verify collateral returned
        uint256 finalBobWeth = wethInstance.balanceOf(bob);
        assertTrue(finalBobWeth >= collateralAmount, "Collateral should be returned to user");
    }
}
