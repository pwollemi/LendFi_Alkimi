// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../BasicDeploy.sol";
import {console2} from "forge-std/console2.sol";
import {IPROTOCOL} from "../../contracts/interfaces/IProtocol.sol";
import {RWAPriceConsumerV3} from "../../contracts/mock/RWAOracle.sol";
import {WETHPriceConsumerV3} from "../../contracts/mock/WETHOracle.sol";
import {MockRWA} from "../../contracts/mock/MockRWA.sol";
import {Lendefi} from "../../contracts/lender/Lendefi.sol";

contract ExchangeTest is BasicDeploy {
    // Events to verify
    event Exchange(address indexed user, uint256 amount, uint256 value);
    event SupplyLiquidity(address indexed user, uint256 amount);
    event Reward(address indexed user, uint256 amount);

    MockRWA internal rwaToken;
    RWAPriceConsumerV3 internal rwaOracleInstance;
    WETHPriceConsumerV3 internal wethOracleInstance;

    function setUp() public {
        deployComplete();

        // TGE setup
        vm.prank(guardian);
        tokenInstance.initializeTGE(address(ecoInstance), address(treasuryInstance));

        // Deploy mock tokens
        usdcInstance = new USDC();
        wethInstance = new WETH9();
        rwaToken = new MockRWA("Ondo Finance", "ONDO");

        // Deploy oracles
        wethOracleInstance = new WETHPriceConsumerV3();
        rwaOracleInstance = new RWAPriceConsumerV3();

        // Set prices
        wethOracleInstance.setPrice(2500e8); // $2500 per ETH
        rwaOracleInstance.setPrice(1000e8); // $1000 per RWA token

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

        vm.stopPrank();
    }

    // Helper function to supply liquidity
    function _supplyLiquidity(address user, uint256 amount) internal {
        usdcInstance.mint(user, amount);
        vm.startPrank(user);
        usdcInstance.approve(address(LendefiInstance), amount);
        LendefiInstance.supplyLiquidity(amount);
        vm.stopPrank();
    }

    // Helper function to generate protocol profit
    function _generateProfit(uint256 amount) internal {
        usdcInstance.mint(address(LendefiInstance), amount);
    }

    // Test 1: Basic exchange functionality
    function test_BasicExchange() public {
        uint256 supplyAmount = 10_000e6;
        uint256 exchangeAmount = 5_000e6;

        // First supply liquidity
        _supplyLiquidity(alice, supplyAmount);

        // Capture initial state
        uint256 initialAliceUsdcBalance = usdcInstance.balanceOf(alice);
        uint256 initialAliceTokens = LendefiInstance.balanceOf(alice);
        uint256 initialProtocolUsdcBalance = usdcInstance.balanceOf(address(LendefiInstance));
        uint256 initialtotalSuppliedLiquidity = LendefiInstance.totalSuppliedLiquidity();
        uint256 initialTotalSupply = LendefiInstance.totalSupply();

        // Calculate expected values
        uint256 expectedtotalSuppliedLiquidity =
            initialtotalSuppliedLiquidity - (exchangeAmount * initialtotalSuppliedLiquidity) / initialTotalSupply;
        uint256 expectedUsdcReceived = (exchangeAmount * initialProtocolUsdcBalance) / initialTotalSupply;

        vm.startPrank(alice);

        // Expect Exchange event
        vm.expectEmit(true, false, false, true);
        emit Exchange(alice, exchangeAmount, expectedUsdcReceived);

        // Exchange tokens
        LendefiInstance.exchange(exchangeAmount);
        vm.stopPrank();

        // Verify state changes
        uint256 finalAliceUsdcBalance = usdcInstance.balanceOf(alice);
        uint256 finalAliceTokens = LendefiInstance.balanceOf(alice);
        uint256 finalProtocolUsdcBalance = usdcInstance.balanceOf(address(LendefiInstance));
        uint256 finaltotalSuppliedLiquidity = LendefiInstance.totalSuppliedLiquidity();

        assertEq(
            finalAliceTokens, initialAliceTokens - exchangeAmount, "Token balance should decrease by exchanged amount"
        );
        assertEq(finalAliceUsdcBalance, initialAliceUsdcBalance + expectedUsdcReceived, "USDC balance should increase");
        assertEq(
            finalProtocolUsdcBalance, initialProtocolUsdcBalance - expectedUsdcReceived, "Protocol USDC should decrease"
        );
        assertApproxEqAbs(
            finaltotalSuppliedLiquidity, expectedtotalSuppliedLiquidity, 1, "Total base should decrease proportionally"
        );
    }

    // Test 2: Exchange with insufficient balance
    function test_ExchangeInsufficientBalance() public {
        uint256 supplyAmount = 5_000e6;
        uint256 exchangeAmount = 10_000e6; // More than supplied

        // Supply liquidity
        _supplyLiquidity(alice, supplyAmount);

        vm.startPrank(alice);
        // Attempt to exchange more than balance
        vm.expectRevert(
            abi.encodeWithSelector(
                IPROTOCOL.InsufficientTokenBalance.selector, address(LendefiInstance), alice, supplyAmount
            )
        );
        LendefiInstance.exchange(exchangeAmount);
        vm.stopPrank();
    }

    // Test 3: Exchange entire balance
    function test_ExchangeEntireBalance() public {
        uint256 supplyAmount = 10_000e6;

        // Supply liquidity
        _supplyLiquidity(alice, supplyAmount);

        // Capture initial state
        uint256 initialAliceUsdcBalance = usdcInstance.balanceOf(alice);
        uint256 initialAliceTokens = LendefiInstance.balanceOf(alice);
        uint256 initialProtocolUsdcBalance = usdcInstance.balanceOf(address(LendefiInstance));

        vm.startPrank(alice);
        // Exchange entire balance
        LendefiInstance.exchange(initialAliceTokens);
        vm.stopPrank();

        // Verify state changes
        uint256 finalAliceUsdcBalance = usdcInstance.balanceOf(alice);
        uint256 finalAliceTokens = LendefiInstance.balanceOf(alice);

        assertEq(finalAliceTokens, 0, "Token balance should be zero after exchanging entire balance");
        assertTrue(finalAliceUsdcBalance > initialAliceUsdcBalance, "USDC balance should increase");
        assertTrue(
            usdcInstance.balanceOf(address(LendefiInstance)) < initialProtocolUsdcBalance,
            "Protocol USDC should decrease"
        );
    }

    // Test 4: Exchange with fees (when protocol has profit)
    function test_ExchangeWithFees() public {
        uint256 supplyAmount = 10_000e6;
        uint256 profitAmount = 1_000e6; // 10% profit
        uint256 exchangeAmount = 5_000e6;

        // Supply liquidity
        _supplyLiquidity(alice, supplyAmount);

        // Generate profit for the protocol
        _generateProfit(profitAmount);

        // Capture initial state
        uint256 initialTreasuryTokens = LendefiInstance.balanceOf(address(treasuryInstance));

        vm.startPrank(alice);
        // Exchange tokens
        LendefiInstance.exchange(exchangeAmount);
        vm.stopPrank();

        // Verify fee was charged
        uint256 finalTreasuryTokens = LendefiInstance.balanceOf(address(treasuryInstance));
        assertTrue(finalTreasuryTokens > initialTreasuryTokens, "Treasury should receive fee tokens");
    }

    // Test 5: Exchange without fees (when protocol doesn't have enough profit)
    function test_ExchangeWithoutFees() public {
        uint256 supplyAmount = 10_000e6;
        uint256 exchangeAmount = 5_000e6;

        // Supply liquidity (no profit generated)
        _supplyLiquidity(alice, supplyAmount);

        // Capture initial state
        uint256 initialTreasuryTokens = LendefiInstance.balanceOf(address(treasuryInstance));

        vm.startPrank(alice);
        // Exchange tokens
        LendefiInstance.exchange(exchangeAmount);
        vm.stopPrank();

        // Verify no fee was charged
        uint256 finalTreasuryTokens = LendefiInstance.balanceOf(address(treasuryInstance));
        assertEq(finalTreasuryTokens, initialTreasuryTokens, "Treasury should not receive fee tokens");
    }

    // Test 6: Exchange when paused
    function test_ExchangeWhenPaused() public {
        uint256 supplyAmount = 10_000e6;
        uint256 exchangeAmount = 5_000e6;

        // Supply liquidity
        _supplyLiquidity(alice, supplyAmount);

        // Pause protocol
        vm.prank(guardian);
        LendefiInstance.pause();

        vm.startPrank(alice);
        // Attempt to exchange when paused
        bytes memory expectedError = abi.encodeWithSignature("EnforcedPause()");
        vm.expectRevert(expectedError);
        LendefiInstance.exchange(exchangeAmount);
        vm.stopPrank();
    }

    // Test 7: Exchange with zero amount
    function test_ExchangeZeroAmount() public {
        uint256 supplyAmount = 10_000e6;
        uint256 exchangeAmount = 0;

        // Supply liquidity
        _supplyLiquidity(alice, supplyAmount);

        vm.startPrank(alice);
        // Exchange zero tokens
        LendefiInstance.exchange(exchangeAmount);
        vm.stopPrank();

        // Verify state remains unchanged
        uint256 aliceTokens = LendefiInstance.balanceOf(alice);
        assertEq(aliceTokens, supplyAmount, "Token balance should remain unchanged");
    }

    // Test 8: Multiple exchanges from same user
    function test_MultipleExchanges() public {
        uint256 supplyAmount = 10_000e6;
        uint256 firstExchange = 3_000e6;
        uint256 secondExchange = 2_000e6;

        // Supply liquidity
        _supplyLiquidity(alice, supplyAmount);

        // First exchange
        vm.startPrank(alice);
        LendefiInstance.exchange(firstExchange);
        uint256 tokensAfterFirst = LendefiInstance.balanceOf(alice);

        // Second exchange
        LendefiInstance.exchange(secondExchange);
        uint256 tokensAfterSecond = LendefiInstance.balanceOf(alice);
        vm.stopPrank();

        // Verify tokens decreased correctly
        assertEq(tokensAfterFirst, supplyAmount - firstExchange, "Token balance after first exchange is incorrect");
        assertEq(
            tokensAfterSecond,
            supplyAmount - firstExchange - secondExchange,
            "Token balance after second exchange is incorrect"
        );
    }

    // Test 9: Multiple users exchanging
    function test_MultipleUsersExchanging() public {
        uint256 aliceSupply = 10_000e6;
        uint256 bobSupply = 20_000e6;
        uint256 aliceExchange = 5_000e6;
        uint256 bobExchange = 10_000e6;

        // Supply liquidity
        _supplyLiquidity(alice, aliceSupply);
        _supplyLiquidity(bob, bobSupply);

        // Capture initial state
        uint256 initialAliceTokens = LendefiInstance.balanceOf(alice);
        uint256 initialBobTokens = LendefiInstance.balanceOf(bob);
        uint256 initialtotalSuppliedLiquidity = LendefiInstance.totalSuppliedLiquidity();

        // Alice exchanges
        vm.prank(alice);
        LendefiInstance.exchange(aliceExchange);

        // Bob exchanges
        vm.prank(bob);
        LendefiInstance.exchange(bobExchange);

        // Verify state changes
        uint256 finalAliceTokens = LendefiInstance.balanceOf(alice);
        uint256 finalBobTokens = LendefiInstance.balanceOf(bob);
        uint256 finaltotalSuppliedLiquidity = LendefiInstance.totalSuppliedLiquidity();

        assertEq(
            finalAliceTokens, initialAliceTokens - aliceExchange, "Alice's token balance should decrease correctly"
        );
        assertEq(finalBobTokens, initialBobTokens - bobExchange, "Bob's token balance should decrease correctly");
        assertTrue(
            finaltotalSuppliedLiquidity < initialtotalSuppliedLiquidity, "Total base should decrease after exchanges"
        );
    }

    // Test 10: Exchange with rewards (when user is eligible)// Test 10: Exchange with rewards (when user is eligible)
    function test_ExchangeWithRewards() public {
        // Setup reward parameters correctly
        vm.startPrank(address(timelockInstance));
        LendefiInstance.updateRewardableSupply(100_000e6); // Lower reward threshold
        LendefiInstance.updateTargetReward(1_000e18); // Set target reward
        vm.stopPrank();

        uint256 supplyAmount = 100_000e6;

        // Supply liquidity
        _supplyLiquidity(alice, supplyAmount);

        // Fast forward time to be eligible for rewards
        vm.warp(block.timestamp + LendefiInstance.rewardInterval() + 1);

        // Verify Alice is now eligible for rewards
        bool isEligible = LendefiInstance.isRewardable(alice);
        assertTrue(isEligible, "Alice should be eligible for rewards");

        // Exchange all tokens to trigger reward
        vm.prank(alice);
        LendefiInstance.exchange(supplyAmount);

        // Verify Alice received rewards
        uint256 aliceGovTokens = tokenInstance.balanceOf(alice);
        assertTrue(aliceGovTokens > 0, "Alice should receive governance tokens as rewards");
    }

    // Test 11: Exchange with large amounts
    function test_ExchangeLargeAmount() public {
        uint256 largeSupply = 1_000_000_000e6; // 1 billion USDC

        // Supply large amount
        _supplyLiquidity(alice, largeSupply);

        vm.startPrank(alice);
        // Exchange large amount
        LendefiInstance.exchange(largeSupply);
        vm.stopPrank();

        // Verify state
        uint256 aliceTokens = LendefiInstance.balanceOf(alice);
        assertEq(aliceTokens, 0, "Alice should have zero tokens after exchange");
        assertApproxEqAbs(
            usdcInstance.balanceOf(alice),
            largeSupply,
            100,
            "Alice should receive approximately the supplied amount back"
        );
    }

    // Test 12: End-to-end exchange with real interest
    function test_ExchangeWithRealInterest() public {
        uint256 supplyAmount = 100_000e6;
        uint256 collateralAmount = 50 ether;
        uint256 borrowAmount = 50_000e6;

        // Supply liquidity
        _supplyLiquidity(alice, supplyAmount);

        // Setup collateral and borrow to generate interest
        vm.deal(bob, collateralAmount);
        vm.startPrank(bob);
        wethInstance.deposit{value: collateralAmount}();
        wethInstance.approve(address(LendefiInstance), collateralAmount);
        LendefiInstance.createPosition(address(wethInstance), false);
        LendefiInstance.supplyCollateral(address(wethInstance), collateralAmount, 0);
        LendefiInstance.borrow(0, borrowAmount);
        vm.stopPrank();

        // Fast forward time to accrue interest
        vm.warp(block.timestamp + 730 days);
        // Repay loan with interest
        uint256 debtWithInterest = LendefiInstance.calculateDebtWithInterest(bob, 0);
        usdcInstance.mint(bob, debtWithInterest * 2); // Give enough to repay
        vm.startPrank(bob);
        usdcInstance.approve(address(LendefiInstance), debtWithInterest);
        LendefiInstance.repay(0, debtWithInterest);
        vm.stopPrank();

        // Verify loan is repaid
        assertEq(LendefiInstance.totalBorrow(), 0, "Total borrow should be zero");

        // Get expected exchange value using supply rate
        vm.startPrank(alice);
        uint256 aliceTokens = LendefiInstance.balanceOf(alice);

        // Exchange tokens
        uint256 supplyRate = LendefiInstance.getSupplyRate();
        LendefiInstance.exchange(aliceTokens);
        vm.stopPrank();

        uint256 balanceAfter = usdcInstance.balanceOf(alice);
        uint256 expBal = 100_000e6 + (100_000e6 * supplyRate) / 1e6;
        assertEq(balanceAfter / 1e6, expBal / 1e6);
    }

    // Test 13: Exchange slightly more than balance should use exact balance
    function test_ExchangeExactBalance() public {
        uint256 supplyAmount = 10_000e6;

        // Supply liquidity
        _supplyLiquidity(alice, supplyAmount);

        // Capture initial state
        uint256 initialAliceUsdcBalance = usdcInstance.balanceOf(alice);
        uint256 initialtotalSuppliedLiquidity = LendefiInstance.totalSuppliedLiquidity();
        uint256 initialAliceTokens = LendefiInstance.balanceOf(alice);

        vm.startPrank(alice);
        // This should work, using alice's exact balance
        LendefiInstance.exchange(supplyAmount); // Using exact amount
        vm.stopPrank();

        // Verify state changes
        uint256 finalAliceUsdcBalance = usdcInstance.balanceOf(alice);
        uint256 finalAliceTokens = LendefiInstance.balanceOf(alice);
        uint256 finaltotalSuppliedLiquidity = LendefiInstance.totalSuppliedLiquidity();

        assertEq(finalAliceTokens, 0, "Token balance should be zero");
        assertTrue(finalAliceUsdcBalance > initialAliceUsdcBalance, "USDC balance should increase");
        assertTrue(finaltotalSuppliedLiquidity < initialtotalSuppliedLiquidity, "Total base should decrease");

        // Verify entire balance was used
        assertEq(initialAliceTokens, supplyAmount, "Initial balance should match supply");
    }

    // Fuzz Test 1: Exchange random amounts
    function testFuzz_ExchangeRandomAmount(uint256 amount) public {
        // Bound to reasonable values
        uint256 supplyAmount = 100_000e6;
        amount = bound(amount, 1e6, supplyAmount); // 1 to full supply amount

        // Supply liquidity first
        _supplyLiquidity(alice, supplyAmount);

        vm.startPrank(alice);
        // Exchange random amount
        LendefiInstance.exchange(amount);
        vm.stopPrank();

        // Verify basic state
        uint256 aliceTokens = LendefiInstance.balanceOf(alice);
        assertEq(aliceTokens, supplyAmount - amount, "Token balance should decrease by exchanged amount");
    }

    // Fuzz Test 2: Multiple users with random exchange amounts
    function testFuzz_MultipleUsersRandomExchanges(uint256 amount1, uint256 amount2) public {
        // Bound to reasonable values
        uint256 supplyAmount1 = 100_000e6;
        uint256 supplyAmount2 = 200_000e6;
        amount1 = bound(amount1, 1e6, supplyAmount1);
        amount2 = bound(amount2, 1e6, supplyAmount2);

        // Supply liquidity
        _supplyLiquidity(alice, supplyAmount1);
        _supplyLiquidity(bob, supplyAmount2);

        // Alice exchanges
        vm.prank(alice);
        LendefiInstance.exchange(amount1);

        // Bob exchanges
        vm.prank(bob);
        LendefiInstance.exchange(amount2);

        // Verify balances
        assertEq(LendefiInstance.balanceOf(alice), supplyAmount1 - amount1, "Alice's token balance incorrect");
        assertEq(LendefiInstance.balanceOf(bob), supplyAmount2 - amount2, "Bob's token balance incorrect");
    }
}
