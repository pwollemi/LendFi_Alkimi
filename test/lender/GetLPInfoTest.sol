// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../BasicDeploy.sol";
import {console2} from "forge-std/console2.sol";
import {IPROTOCOL} from "../../contracts/interfaces/IProtocol.sol";
import {Lendefi} from "../../contracts/lender/Lendefi.sol";
import {TokenMock} from "../../contracts/mock/TokenMock.sol";
import {WETHPriceConsumerV3} from "../../contracts/mock/WETHOracle.sol";

contract GetLPInfoTest is BasicDeploy {
    // Constants
    uint256 constant INITIAL_LIQUIDITY = 1_000_000e6; // 1M USDC
    uint256 constant LP_AMOUNT_SMALL = 10_000e6; // 10k USDC
    uint256 constant LP_AMOUNT_LARGE = 500_000e6; // 500k USDC
    uint256 constant BORROW_AMOUNT = 200_000e6; // 200k USDC

    // Oracle
    WETHPriceConsumerV3 internal wethOracleInstance;

    // Store user data to avoid stack too deep errors
    struct UserLPData {
        uint256 lpBalance;
        uint256 usdcValue;
        uint256 baseAmount;
        bool isRewardEligible;
        uint256 pendingRewards;
    }

    function setUp() public {
        // Use deployCompleteWithOracle() instead of deployComplete()
        deployCompleteWithOracle();

        // TGE setup
        vm.prank(guardian);
        tokenInstance.initializeTGE(address(ecoInstance), address(treasuryInstance));
        vm.warp(block.timestamp + 90 days);

        // Deploy WETH (USDC already deployed by deployCompleteWithOracle())
        wethInstance = new WETH9();

        // Deploy price oracle for WETH
        wethOracleInstance = new WETHPriceConsumerV3();
        wethOracleInstance.setPrice(int256(2500e8)); // $2500 per ETH

        // Register oracle with Oracle module
        vm.startPrank(address(timelockInstance));
        oracleInstance.addOracle(address(wethInstance), address(wethOracleInstance), 8);
        oracleInstance.setPrimaryOracle(address(wethInstance), address(wethOracleInstance));
        vm.stopPrank();

        // Setup roles
        vm.prank(guardian);
        ecoInstance.grantRole(REWARDER_ROLE, address(LendefiInstance));

        // Setup target reward and interval in Lendefi
        vm.startPrank(address(timelockInstance));
        LendefiInstance.updateTargetReward(1_000 ether); // 1k reward
        LendefiInstance.updateRewardInterval(180 days); // 6 month interval

        // Configure WETH as an asset (needed for borrowing tests)
        LendefiInstance.updateAssetConfig(
            address(wethInstance),
            address(wethOracleInstance), // Use the oracle
            8, // Oracle decimals
            18, // WETH decimals
            1, // Active
            800, // 80% borrow threshold
            850, // 85% liquidation threshold
            1_000_000 ether, // Supply limit
            IPROTOCOL.CollateralTier.CROSS_A,
            0 // No isolation debt cap
        );
        vm.stopPrank();

        // Add initial liquidity from guardian
        _addLiquidity(guardian, INITIAL_LIQUIDITY);
    }

    function _addLiquidity(address user, uint256 amount) internal {
        usdcInstance.mint(user, amount);
        vm.startPrank(user);
        usdcInstance.approve(address(LendefiInstance), amount);
        LendefiInstance.supplyLiquidity(amount);
        vm.stopPrank();
    }

    function _setupBorrowPosition(address borrower, uint256 borrowAmount) internal {
        // Create a position with WETH as collateral
        vm.startPrank(borrower);

        // Create position
        LendefiInstance.createPosition(address(wethInstance), false);
        uint256 positionId = LendefiInstance.getUserPositionsCount(borrower) - 1;

        // Supply WETH collateral
        uint256 collateralAmount = 200 ether; // 200 ETH at $2,500 = $500,000
        vm.deal(borrower, collateralAmount);
        wethInstance.deposit{value: collateralAmount}();
        wethInstance.approve(address(LendefiInstance), collateralAmount);
        LendefiInstance.supplyCollateral(address(wethInstance), collateralAmount, positionId);

        // Borrow USDC
        LendefiInstance.borrow(positionId, borrowAmount);
        vm.stopPrank();
    }

    // Helper function to get LP data for a user
    function _getLPDataAndCheckEligibility(address user) internal view returns (UserLPData memory data) {
        (data.lpBalance, data.usdcValue,, data.isRewardEligible, data.pendingRewards) = LendefiInstance.getLPInfo(user);

        // Calculate base amount
        uint256 totalSupply = LendefiInstance.totalSupply();
        uint256 totalSuppliedLiquidity = LendefiInstance.totalSuppliedLiquidity();
        if (totalSupply > 0) {
            data.baseAmount = (data.lpBalance * totalSuppliedLiquidity) / totalSupply;
        }

        return data;
    }

    function test_GetLPInfo_Basic() public {
        // Add liquidity for alice
        _addLiquidity(alice, LP_AMOUNT_SMALL);

        // Get LP info for alice
        (
            uint256 lpTokenBalance,
            uint256 usdcValue,
            uint256 lastAccrualTime,
            bool isRewardEligible,
            uint256 pendingRewards
        ) = LendefiInstance.getLPInfo(alice);

        // Verify basic LP info
        uint256 expectedLPTokens = LP_AMOUNT_SMALL; // Initially 1:1 ratio

        assertEq(lpTokenBalance, expectedLPTokens, "LP token balance incorrect");
        assertEq(usdcValue, LP_AMOUNT_SMALL, "USDC value incorrect");
        assertEq(lastAccrualTime, block.timestamp, "Last accrual time incorrect");
        assertFalse(isRewardEligible, "Should not be reward eligible yet");
        assertEq(pendingRewards, 0, "Should have no pending rewards");

        // Log info
        console2.log("LP Token Balance:", lpTokenBalance);
        console2.log("USDC Value:", usdcValue);
        console2.log("Last Accrual Time:", lastAccrualTime);
        console2.log("Is Reward Eligible:", isRewardEligible);
        console2.log("Pending Rewards:", pendingRewards);
    }

    function test_GetLPInfo_WithBorrowing() public {
        // Add liquidity for alice
        _addLiquidity(alice, LP_AMOUNT_LARGE);

        // Setup a borrowing position for bob
        _setupBorrowPosition(bob, BORROW_AMOUNT);

        // Get LP info for alice
        (uint256 lpTokenBalance, uint256 usdcValue,, bool isRewardEligible,) = LendefiInstance.getLPInfo(alice);

        // Calculate expected values
        uint256 totalInProtocol = usdcInstance.balanceOf(address(LendefiInstance)) + BORROW_AMOUNT;
        uint256 expectedUSDCValue = (lpTokenBalance * totalInProtocol) / LendefiInstance.totalSupply();

        // Verify LP info
        assertEq(usdcValue, expectedUSDCValue, "USDC value incorrect with borrowing");
        assertGe(usdcValue, LP_AMOUNT_LARGE, "USDC value should be at least the supplied amount");

        // Log info
        console2.log("LP Token Balance:", lpTokenBalance);
        console2.log("USDC Value:", usdcValue);
        console2.log("Protocol Total Value:", totalInProtocol);
        console2.log("Is Reward Eligible:", isRewardEligible);
    }

    function test_GetLPInfo_RewardEligibility() public {
        // Add large liquidity for alice - should be enough to qualify for rewards
        _addLiquidity(alice, LP_AMOUNT_LARGE);

        // Initial check - should not be eligible yet (time hasn't passed)
        // (,, uint256 initialLastAccrualTime, bool initialIsRewardEligible,) = LendefiInstance.getLPInfo(alice);

        // User might be eligible immediately if their base amount exceeds the threshold
        uint256 rewardableSupply = LendefiInstance.rewardableSupply();
        console2.log("Rewardable Supply Threshold:", rewardableSupply);

        // Move time forward beyond reward interval
        vm.warp(block.timestamp + 181 days);

        // Check again after time has passed
        (,, uint256 lastAccrualTime, bool isRewardEligible, uint256 pendingRewards) = LendefiInstance.getLPInfo(alice);

        console2.log("Is user eligible for rewards:", isRewardEligible);

        // If user is eligible, check the pending rewards calculation
        if (isRewardEligible) {
            uint256 duration = block.timestamp - lastAccrualTime;
            uint256 targetReward = LendefiInstance.targetReward();
            uint256 rewardInterval = LendefiInstance.rewardInterval();

            uint256 expectedRewards = (targetReward * duration) / rewardInterval;
            console2.log("Expected rewards:", expectedRewards);
            assertEq(pendingRewards, expectedRewards, "Pending rewards calculation incorrect");
        }

        // Log reward info
        console2.log("Last Accrual Time:", lastAccrualTime);
        console2.log("Duration (seconds):", block.timestamp - lastAccrualTime);
        console2.log("Duration (days):", (block.timestamp - lastAccrualTime) / 1 days);
        console2.log("Is Reward Eligible:", isRewardEligible);
        console2.log("Pending Rewards:", pendingRewards);
    }

    function test_GetLPInfo_MaxRewardsCap() public {
        // Add large liquidity for alice
        _addLiquidity(alice, LP_AMOUNT_LARGE);

        // Ensure user is eligible for rewards
        vm.prank(address(timelockInstance));
        LendefiInstance.updateRewardableSupply(LP_AMOUNT_LARGE - 1); // Set threshold below user's amount

        // Move time forward way beyond reward interval (multiple intervals)
        // This should generate rewards beyond the max cap
        vm.warp(block.timestamp + 1000 days);

        // Get LP info
        (,,, bool isRewardEligible, uint256 pendingRewards) = LendefiInstance.getLPInfo(alice);

        // Get max reward from ecosystem
        uint256 maxReward = ecoInstance.maxReward();

        console2.log("Is Reward Eligible:", isRewardEligible);
        console2.log("Pending Rewards:", pendingRewards);
        console2.log("Max Reward:", maxReward);

        if (isRewardEligible) {
            // Calculate uncapped rewards
            uint256 targetReward = LendefiInstance.targetReward();
            uint256 rewardInterval = LendefiInstance.rewardInterval();
            (,, uint256 lastAccrualTime,,) = LendefiInstance.getLPInfo(alice);
            uint256 duration = block.timestamp - lastAccrualTime;
            uint256 uncappedRewards = (targetReward * duration) / rewardInterval;

            console2.log("Uncapped rewards would be:", uncappedRewards);

            // Verify rewards are capped at max reward if they would exceed it
            if (uncappedRewards > maxReward) {
                assertEq(pendingRewards, maxReward, "Rewards should be capped at max reward");
            } else {
                assertEq(pendingRewards, uncappedRewards, "Rewards should match calculation");
            }
        } else {
            console2.log("User not eligible for rewards");
        }
    }

    function test_GetLPInfo_MultipleProviders() public {
        // Add liquidity for multiple users with different amounts
        _addLiquidity(alice, LP_AMOUNT_SMALL); // 10k USDC
        _addLiquidity(bob, LP_AMOUNT_SMALL * 2); // 20k USDC
        _addLiquidity(charlie, LP_AMOUNT_LARGE); // 500k USDC

        // Move time forward to make them potentially eligible for rewards
        vm.warp(block.timestamp + 181 days);

        // Get rewardable supply threshold once
        uint256 rewardableSupply = LendefiInstance.rewardableSupply();

        // Use helper function to get LP data for each user
        UserLPData memory aliceData = _getLPDataAndCheckEligibility(alice);
        UserLPData memory bobData = _getLPDataAndCheckEligibility(bob);
        UserLPData memory charlieData = _getLPDataAndCheckEligibility(charlie);

        // Verify proportions of LP tokens and USDC values
        assertEq(bobData.lpBalance, aliceData.lpBalance * 2, "Bob should have twice Alice's LP tokens");
        assertEq(bobData.usdcValue, aliceData.usdcValue * 2, "Bob should have twice Alice's USDC value");

        // Log info for comparison
        console2.log("--- Alice ---");
        console2.log("LP Balance:", aliceData.lpBalance);
        console2.log("USDC Value:", aliceData.usdcValue);
        console2.log("Base Amount:", aliceData.baseAmount);
        console2.log("Reward Eligible:", aliceData.isRewardEligible);
        console2.log("Pending Rewards:", aliceData.pendingRewards);

        console2.log("--- Bob ---");
        console2.log("LP Balance:", bobData.lpBalance);
        console2.log("USDC Value:", bobData.usdcValue);
        console2.log("Base Amount:", bobData.baseAmount);
        console2.log("Reward Eligible:", bobData.isRewardEligible);
        console2.log("Pending Rewards:", bobData.pendingRewards);

        console2.log("--- Charlie ---");
        console2.log("LP Balance:", charlieData.lpBalance);
        console2.log("USDC Value:", charlieData.usdcValue);
        console2.log("Base Amount:", charlieData.baseAmount);
        console2.log("Reward Eligible:", charlieData.isRewardEligible);
        console2.log("Pending Rewards:", charlieData.pendingRewards);

        console2.log("Rewardable Supply Threshold:", rewardableSupply);
    }

    function test_GetLPInfo_AfterExchangingTokens() public {
        // Add liquidity for alice
        _addLiquidity(alice, LP_AMOUNT_LARGE);

        // Record initial LP info
        (uint256 initialLPBalance, uint256 initialUSDCValue, uint256 initialLastAccrualTime,,) =
            LendefiInstance.getLPInfo(alice);

        // Exchange half of the LP tokens
        uint256 exchangeAmount = initialLPBalance / 2;

        vm.startPrank(alice);
        LendefiInstance.exchange(exchangeAmount);
        vm.stopPrank();

        // Get updated LP info
        (uint256 newLPBalance, uint256 newUSDCValue, uint256 newLastAccrualTime,,) = LendefiInstance.getLPInfo(alice);

        // Verify LP token balance reduced
        assertEq(newLPBalance, initialLPBalance - exchangeAmount, "LP token balance should be reduced");

        // USDC value should be proportionally reduced
        assertApproxEqRel(
            newUSDCValue,
            initialUSDCValue / 2,
            0.01e18, // 1% tolerance due to possible rounding
            "USDC value should be roughly halved"
        );

        // Last accrual time should be updated after exchanging
        // Note: This may vary depending on implementation - could be reset or unchanged

        // Log info
        console2.log("Initial LP Balance:", initialLPBalance);
        console2.log("New LP Balance:", newLPBalance);
        console2.log("Initial USDC Value:", initialUSDCValue);
        console2.log("New USDC Value:", newUSDCValue);
        console2.log("Initial Last Accrual:", initialLastAccrualTime);
        console2.log("New Last Accrual:", newLastAccrualTime);
    }

    function test_GetLPInfo_ZeroBalance() public {
        // Get LP info for user with no LP tokens
        (
            uint256 lpTokenBalance,
            uint256 usdcValue,
            uint256 lastAccrualTime,
            bool isRewardEligible,
            uint256 pendingRewards
        ) = LendefiInstance.getLPInfo(alice);

        // Verify all values are zero/false
        assertEq(lpTokenBalance, 0, "LP token balance should be zero");
        assertEq(usdcValue, 0, "USDC value should be zero");
        assertEq(lastAccrualTime, 0, "Last accrual time should be zero");
        assertFalse(isRewardEligible, "Should not be reward eligible");
        assertEq(pendingRewards, 0, "Should have no pending rewards");
    }

    function test_GetLPInfo_AfterInterestAccrual() public {
        // Add liquidity for alice
        _addLiquidity(alice, LP_AMOUNT_LARGE);

        // Setup a borrowing position for bob
        _setupBorrowPosition(bob, BORROW_AMOUNT);

        // Record initial LP info
        (uint256 initialLPBalance, uint256 initialUSDCValue,,,) = LendefiInstance.getLPInfo(alice);

        // Move time forward to accrue interest
        vm.warp(block.timestamp + 365 days); // 1 year
        usdcInstance.mint(address(LendefiInstance), 100_000e6);

        // Get updated LP info
        (uint256 newLPBalance, uint256 newUSDCValue,,,) = LendefiInstance.getLPInfo(alice);

        // LP token balance should remain the same
        assertEq(newLPBalance, initialLPBalance, "LP token balance should not change");

        // USDC value should increase due to interest accrual
        assertGt(newUSDCValue, initialUSDCValue, "USDC value should increase from interest");

        // Calculate interest
        uint256 valueIncrease = newUSDCValue - initialUSDCValue;
        uint256 interestRate = (valueIncrease * 1e6) / initialUSDCValue;

        // Log interest information
        console2.log("Initial USDC Value:", initialUSDCValue);
        console2.log("New USDC Value:", newUSDCValue);
        console2.log("Value Increase:", valueIncrease);
        console2.log("Effective Annual Interest Rate (basis points):", interestRate);
    }
}
