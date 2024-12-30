// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../BasicDeploy.sol";
import {console2} from "forge-std/console2.sol";
import {IPROTOCOL} from "../../contracts/interfaces/IProtocol.sol";
import {RWAPriceConsumerV3} from "../../contracts/mock/RWAOracle.sol";
import {WETHPriceConsumerV3} from "../../contracts/mock/WETHOracle.sol";
import {MockRWA} from "../../contracts/mock/MockRWA.sol";
import {Lendefi} from "../../contracts/lender/Lendefi.sol";

contract SupplyLiquidityTest is BasicDeploy {
    // Events to verify
    event SupplyLiquidity(address indexed user, uint256 amount);

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

    // Test 1: Basic supply liquidity
    function test_BasicSupplyLiquidity() public {
        uint256 amount = 10_000e6; // 10,000 USDC

        // Mint USDC to alice
        usdcInstance.mint(alice, amount);

        vm.startPrank(alice);
        // Approve USDC spending
        usdcInstance.approve(address(LendefiInstance), amount);

        // Check initial state
        uint256 initialAliceUsdcBalance = usdcInstance.balanceOf(alice);
        uint256 initialProtocolUsdcBalance = usdcInstance.balanceOf(address(LendefiInstance));
        uint256 initialtotalSuppliedLiquidity = LendefiInstance.totalSuppliedLiquidity();
        uint256 initialTokenSupply = LendefiInstance.totalSupply();

        // Expect SupplyLiquidity event
        vm.expectEmit(true, false, false, true);
        emit SupplyLiquidity(alice, amount);

        // Supply liquidity
        LendefiInstance.supplyLiquidity(amount);
        vm.stopPrank();

        // Check final state
        uint256 finalAliceUsdcBalance = usdcInstance.balanceOf(alice);
        uint256 finalProtocolUsdcBalance = usdcInstance.balanceOf(address(LendefiInstance));
        uint256 finaltotalSuppliedLiquidity = LendefiInstance.totalSuppliedLiquidity();
        uint256 finalTokenSupply = LendefiInstance.totalSupply();
        uint256 aliceTokenBalance = LendefiInstance.balanceOf(alice);

        // Verify state changes
        assertEq(finalAliceUsdcBalance, initialAliceUsdcBalance - amount, "USDC balance of alice should decrease");
        assertEq(
            finalProtocolUsdcBalance, initialProtocolUsdcBalance + amount, "USDC balance of protocol should increase"
        );
        assertEq(
            finaltotalSuppliedLiquidity,
            initialtotalSuppliedLiquidity + amount,
            "totalSuppliedLiquidity should increase by supply amount"
        );
        assertTrue(finalTokenSupply > initialTokenSupply, "Token supply should increase");

        // For first supply when totalSupply is 0, token amount = USDC amount
        assertEq(aliceTokenBalance, amount, "Alice should receive tokens equal to amount");
    }

    // Test 2: Supply with insufficient balance
    function test_SupplyInsufficientBalance() public {
        uint256 userBalance = 5_000e6; // 5,000 USDC
        uint256 supplyAmount = 10_000e6; // 10,000 USDC

        // Mint USDC to bob (less than he wants to supply)
        usdcInstance.mint(bob, userBalance);

        vm.startPrank(bob);
        usdcInstance.approve(address(LendefiInstance), supplyAmount);

        // Attempt to supply more than balance
        vm.expectRevert(
            abi.encodeWithSelector(Lendefi.InsufficientTokenBalance.selector, address(usdcInstance), bob, userBalance)
        );
        LendefiInstance.supplyLiquidity(supplyAmount);
        vm.stopPrank();
    }

    // Test 3: Supply with zero amount
    function test_SupplyZeroAmount() public {
        uint256 amount = 0;

        vm.startPrank(alice);
        // Approve USDC spending
        usdcInstance.approve(address(LendefiInstance), amount);

        // Supply zero liquidity (should work, but do nothing)
        LendefiInstance.supplyLiquidity(amount);
        vm.stopPrank();

        // Verify alice got no tokens
        uint256 aliceTokenBalance = LendefiInstance.balanceOf(alice);
        assertEq(aliceTokenBalance, 0, "Alice should receive no tokens");
    }

    // Test 4: Supply after initial supply (with non-zero totalSupply)
    function test_SupplyAfterInitialSupply() public {
        uint256 firstAmount = 10_000e6;
        uint256 secondAmount = 5_000e6;

        // First supply by alice
        usdcInstance.mint(alice, firstAmount);
        vm.startPrank(alice);
        usdcInstance.approve(address(LendefiInstance), firstAmount);
        LendefiInstance.supplyLiquidity(firstAmount);
        vm.stopPrank();

        // Capture state after first supply
        uint256 aliceTokens = LendefiInstance.balanceOf(alice);
        uint256 totalSupplyAfterFirst = LendefiInstance.totalSupply();

        // Second supply by bob
        usdcInstance.mint(bob, secondAmount);
        vm.startPrank(bob);
        usdcInstance.approve(address(LendefiInstance), secondAmount);
        LendefiInstance.supplyLiquidity(secondAmount);
        vm.stopPrank();

        uint256 bobTokens = LendefiInstance.balanceOf(bob);
        uint256 totalSupplyAfterSecond = LendefiInstance.totalSupply();

        // Verify tokens were minted proportionally
        assertTrue(totalSupplyAfterSecond > totalSupplyAfterFirst, "Total supply should increase");

        // For second deposit, calculate expected tokens
        uint256 total = usdcInstance.balanceOf(address(LendefiInstance)) + LendefiInstance.totalBorrow() - secondAmount;
        uint256 expectedTokens = (secondAmount * aliceTokens) / total;

        // Should be close to expected amount (minor rounding errors may occur)
        assertApproxEqRel(bobTokens, expectedTokens, 0.001e18); // 0.1% tolerance
    }

    // Test 5: Supply when protocol has borrow (utilization > 0)
    function test_SupplyWithBorrow() public {
        uint256 initialSupply = 50_000e6;
        uint256 borrowAmount = 10_000e6;
        uint256 secondSupplyAmount = 20_000e6;

        // Initial supply by alice
        usdcInstance.mint(alice, initialSupply);
        vm.startPrank(alice);
        usdcInstance.approve(address(LendefiInstance), initialSupply);
        LendefiInstance.supplyLiquidity(initialSupply);
        vm.stopPrank();

        // Setup for borrow
        vm.deal(bob, 10 ether);
        vm.startPrank(bob);
        wethInstance.deposit{value: 10 ether}();
        LendefiInstance.createPosition(address(wethInstance), false);
        uint256 positionId = 0;
        wethInstance.approve(address(LendefiInstance), 10 ether);
        LendefiInstance.supplyCollateral(address(wethInstance), 10 ether, positionId);

        // Borrow USDC
        LendefiInstance.borrow(positionId, borrowAmount);
        vm.stopPrank();

        // Check utilization
        uint256 utilization = LendefiInstance.getUtilization();
        assertTrue(utilization > 0, "Utilization should be non-zero after borrowing");

        // Second supply by charlie
        usdcInstance.mint(charlie, secondSupplyAmount);
        vm.startPrank(charlie);
        usdcInstance.approve(address(LendefiInstance), secondSupplyAmount);

        // Capture state before supply
        uint256 totalSupplyBefore = LendefiInstance.totalSupply();

        // Supply with non-zero utilization
        LendefiInstance.supplyLiquidity(secondSupplyAmount);
        vm.stopPrank();

        // Verify token minting with utilization
        uint256 charlieTokens = LendefiInstance.balanceOf(charlie);
        uint256 totalSupplyAfter = LendefiInstance.totalSupply();

        assertTrue(totalSupplyAfter > totalSupplyBefore, "Total supply should increase");
        assertTrue(charlieTokens > 0, "Charlie should receive tokens");

        // Token amount should be proportional to supply and totalSuppliedLiquidity
        uint256 total =
            usdcInstance.balanceOf(address(LendefiInstance)) + LendefiInstance.totalBorrow() - secondSupplyAmount;
        uint256 expectedTokens = (secondSupplyAmount * totalSupplyBefore) / total;

        assertApproxEqRel(charlieTokens, expectedTokens, 0.001e18); // 0.1% tolerance
    }

    // Test 6: Cannot Supply when paused should fail
    function test_CannotSupplyWhenPaused() public {
        uint256 amount = 10_000e6;

        // Pause the protocol
        vm.prank(guardian);
        LendefiInstance.pause();

        // Mint USDC to alice
        usdcInstance.mint(alice, amount);

        vm.startPrank(alice);
        usdcInstance.approve(address(LendefiInstance), amount);

        // Supply liquidity when paused should fail
        bytes memory expectedError = abi.encodeWithSignature("EnforcedPause()");
        vm.expectRevert(expectedError);
        LendefiInstance.supplyLiquidity(amount);
        vm.stopPrank();
    }

    // Test 7: Supply with very large amounts
    function test_SupplyLargeAmount() public {
        uint256 largeAmount = 1_000_000_000e6; // 1 billion USDC

        // Mint large amount to alice
        usdcInstance.mint(alice, largeAmount);

        vm.startPrank(alice);
        usdcInstance.approve(address(LendefiInstance), largeAmount);

        // Supply large amount
        LendefiInstance.supplyLiquidity(largeAmount);
        vm.stopPrank();

        // Verify liquidity was added
        uint256 aliceTokens = LendefiInstance.balanceOf(alice);
        assertEq(aliceTokens, largeAmount, "Alice should receive tokens equal to large amount");
        assertEq(
            LendefiInstance.totalSuppliedLiquidity(),
            largeAmount,
            "totalSuppliedLiquidity should be updated with large amount"
        );
    }

    // Test 8: Verify liquidityAccrueTimeIndex is updated
    function test_LiquidityAccrueTimeIndexUpdated() public {
        uint256 amount = 10_000e6;

        // Mint USDC to alice
        usdcInstance.mint(alice, amount);

        // Get timestamp before supplying
        uint256 timestampBefore = block.timestamp;

        vm.startPrank(alice);
        usdcInstance.approve(address(LendefiInstance), amount);

        // Supply liquidity
        LendefiInstance.supplyLiquidity(amount);
        vm.stopPrank();

        // Use getLPInfo to check lastAccrualTime
        (,, uint256 lastAccrualTime,,) = LendefiInstance.getLPInfo(alice);

        assertEq(lastAccrualTime, timestampBefore, "lastAccrualTime should be updated to block.timestamp");
    }

    // Test 9: Multiple supplies from same user
    function test_MultipleSuppliesFromSameUser() public {
        uint256 firstAmount = 10_000e6;
        uint256 secondAmount = 15_000e6;

        usdcInstance.mint(alice, firstAmount + secondAmount);

        vm.startPrank(alice);
        usdcInstance.approve(address(LendefiInstance), firstAmount + secondAmount);

        // First supply
        LendefiInstance.supplyLiquidity(firstAmount);
        uint256 tokensAfterFirst = LendefiInstance.balanceOf(alice);

        // Second supply
        LendefiInstance.supplyLiquidity(secondAmount);
        uint256 tokensAfterSecond = LendefiInstance.balanceOf(alice);
        vm.stopPrank();

        // Verify tokens increased
        assertTrue(tokensAfterSecond > tokensAfterFirst, "Token balance should increase after second supply");
    }

    // Test 10: Multiple users supply
    function test_MultipleUsers() public {
        uint256 aliceAmount = 10_000e6;
        uint256 bobAmount = 20_000e6;
        uint256 charlieAmount = 15_000e6;

        // Mint tokens to users
        usdcInstance.mint(alice, aliceAmount);
        usdcInstance.mint(bob, bobAmount);
        usdcInstance.mint(charlie, charlieAmount);

        // Alice supplies
        vm.startPrank(alice);
        usdcInstance.approve(address(LendefiInstance), aliceAmount);
        LendefiInstance.supplyLiquidity(aliceAmount);
        vm.stopPrank();

        // Bob supplies
        vm.startPrank(bob);
        usdcInstance.approve(address(LendefiInstance), bobAmount);
        LendefiInstance.supplyLiquidity(bobAmount);
        vm.stopPrank();

        // Charlie supplies
        vm.startPrank(charlie);
        usdcInstance.approve(address(LendefiInstance), charlieAmount);
        LendefiInstance.supplyLiquidity(charlieAmount);
        vm.stopPrank();

        // Verify total liquidity
        uint256 totalSuppliedLiquidity = LendefiInstance.totalSuppliedLiquidity();
        assertEq(
            totalSuppliedLiquidity,
            aliceAmount + bobAmount + charlieAmount,
            "totalSuppliedLiquidity should equal sum of all supplies"
        );

        // Verify individual balances
        uint256 aliceTokens = LendefiInstance.balanceOf(alice);
        uint256 bobTokens = LendefiInstance.balanceOf(bob);
        uint256 charlieTokens = LendefiInstance.balanceOf(charlie);

        assertTrue(aliceTokens > 0, "Alice should have tokens");
        assertTrue(bobTokens > 0, "Bob should have tokens");
        assertTrue(charlieTokens > 0, "Charlie should have tokens");

        // Token proportions should roughly match supply proportions
        assertApproxEqRel(
            aliceTokens * (bobAmount + charlieAmount),
            (bobTokens + charlieTokens) * aliceAmount,
            0.01e18 // 1% tolerance for rounding
        );
    }

    // Test 11: Reward eligibility after supply
    function test_RewardEligibilityAfterSupply() public {
        // Set rewardableSupply to a lower amount for testing
        uint256 rewardableAmount = 100_000e6;

        // Mint USDC to alice
        usdcInstance.mint(alice, rewardableAmount);

        vm.startPrank(alice);
        usdcInstance.approve(address(LendefiInstance), rewardableAmount);

        // Supply large amount that exceeds rewardableSupply
        LendefiInstance.supplyLiquidity(rewardableAmount);
        vm.stopPrank();

        // Fast forward time beyond rewardInterval
        uint256 rewardInterval = LendefiInstance.rewardInterval();
        vm.warp(block.timestamp + rewardInterval + 1);

        // Check if alice is now reward eligible
        bool isEligible = LendefiInstance.isRewardable(alice);
        assertTrue(isEligible, "Alice should be reward eligible");

        // Check pending rewards through LP info
        (,,,, uint256 pendingRewards) = LendefiInstance.getLPInfo(alice);
        assertTrue(pendingRewards > 0, "Should have pending rewards");
    }

    // Fuzz Test 1: Supply random amounts
    function testFuzz_SupplyRandomAmount(uint256 amount) public {
        // Bound to reasonable values
        amount = bound(amount, 1e6, 1_000_000e6); // 1 to 1 million USDC

        // Mint tokens
        usdcInstance.mint(alice, amount);

        vm.startPrank(alice);
        usdcInstance.approve(address(LendefiInstance), amount);

        // Supply liquidity
        LendefiInstance.supplyLiquidity(amount);
        vm.stopPrank();

        // Verify basic state
        uint256 aliceTokens = LendefiInstance.balanceOf(alice);
        uint256 totalSuppliedLiquidity = LendefiInstance.totalSuppliedLiquidity();

        assertEq(totalSuppliedLiquidity, amount, "totalSuppliedLiquidity should equal supply amount");
        assertEq(aliceTokens, amount, "Alice should receive tokens equal to amount");
    }

    // Fuzz Test 2: Multiple users with random amounts
    function testFuzz_MultipleUsersRandomAmounts(uint256 amount1, uint256 amount2) public {
        // Bound to reasonable values
        amount1 = bound(amount1, 1e6, 1_000_000e6);
        amount2 = bound(amount2, 1e6, 1_000_000e6);

        // Mint tokens
        usdcInstance.mint(alice, amount1);
        usdcInstance.mint(bob, amount2);

        // Alice supplies
        vm.startPrank(alice);
        usdcInstance.approve(address(LendefiInstance), amount1);
        LendefiInstance.supplyLiquidity(amount1);
        vm.stopPrank();

        uint256 aliceTokens = LendefiInstance.balanceOf(alice);

        // Bob supplies
        vm.startPrank(bob);
        usdcInstance.approve(address(LendefiInstance), amount2);
        LendefiInstance.supplyLiquidity(amount2);
        vm.stopPrank();

        uint256 bobTokens = LendefiInstance.balanceOf(bob);
        uint256 totalSuppliedLiquidity = LendefiInstance.totalSuppliedLiquidity();

        // Verify total state
        assertEq(totalSuppliedLiquidity, amount1 + amount2, "totalSuppliedLiquidity should equal sum of supplies");

        // Calculate expected tokens for bob
        uint256 totalBeforeBob =
            usdcInstance.balanceOf(address(LendefiInstance)) + LendefiInstance.totalBorrow() - amount2;
        uint256 expectedTokens = (amount2 * aliceTokens) / totalBeforeBob;

        // Allow for minor rounding differences
        assertApproxEqRel(bobTokens, expectedTokens, 0.001e18); // 0.1% tolerance
    }
}
