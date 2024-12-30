// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../BasicDeploy.sol";
import {console2} from "forge-std/console2.sol";
import {IPROTOCOL} from "../../contracts/interfaces/IProtocol.sol";
import {Lendefi} from "../../contracts/lender/Lendefi.sol";

contract IsRewardableTest is BasicDeploy {
    // Test user accounts
    address internal user1;
    address internal user2;
    address internal user3;

    // Constants for test parameters
    uint256 constant LARGE_SUPPLY = 1_000_000e6; // 1 million USDC
    uint256 constant MEDIUM_SUPPLY = 100_000e6; // 100k USDC
    uint256 constant SMALL_SUPPLY = 10_000e6; // 10k USDC

    function setUp() public {
        deployComplete();

        // TGE setup
        vm.prank(guardian);
        tokenInstance.initializeTGE(address(ecoInstance), address(treasuryInstance));

        // Deploy USDC and WETH
        usdcInstance = new USDC();
        wethInstance = new WETH9();

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

        // Create test user accounts
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        user3 = makeAddr("user3");

        // Initialize reward parameters via timelock
        vm.startPrank(address(timelockInstance));
        LendefiInstance.updateRewardInterval(180 days);
        LendefiInstance.updateRewardableSupply(100_000e6); // 100k USDC threshold
        LendefiInstance.updateTargetReward(1_000e18); // 1000 tokens reward
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

    // Test 1: User with no liquidity supplied should not be eligible
    function test_NoLiquidityNotRewardable() public {
        bool isEligible = LendefiInstance.isRewardable(user1);
        assertFalse(isEligible, "User with no liquidity should not be rewardable");
    }

    // Test 2: User with insufficient balance should not be eligible
    function test_InsufficientBalanceNotRewardable() public {
        // Supply amount less than threshold
        uint256 smallSupply = 50_000e6; // 50k USDC (less than 100k threshold)
        _supplyLiquidity(user1, smallSupply);

        // Fast-forward beyond reward interval
        vm.warp(block.timestamp + 181 days);

        bool isEligible = LendefiInstance.isRewardable(user1);
        assertFalse(isEligible, "User with insufficient balance should not be rewardable");
    }

    // Test 3: User with sufficient balance but insufficient time should not be eligible
    function test_InsufficientTimeNotRewardable() public {
        // Supply above threshold
        _supplyLiquidity(user1, LARGE_SUPPLY);

        // Fast-forward but not enough time
        vm.warp(block.timestamp + 179 days);

        bool isEligible = LendefiInstance.isRewardable(user1);
        assertFalse(isEligible, "User with insufficient time should not be rewardable");
    }

    // Test 4: User meets all criteria and should be eligible
    function test_UserIsRewardable() public {
        // Supply above threshold
        _supplyLiquidity(user1, LARGE_SUPPLY);

        // Fast-forward beyond reward interval
        vm.warp(block.timestamp + 181 days);

        bool isEligible = LendefiInstance.isRewardable(user1);
        assertTrue(isEligible, "User with sufficient balance and time should be rewardable");
    }

    // Test 5: Edge case - User exactly at the reward threshold
    function test_ExactThresholdRewardable() public {
        uint256 thresholdAmount = LendefiInstance.rewardableSupply();
        _supplyLiquidity(user1, thresholdAmount);

        // Fast-forward beyond reward interval
        vm.warp(block.timestamp + 180 days + 1);

        bool isEligible = LendefiInstance.isRewardable(user1);
        assertTrue(isEligible, "User with exact threshold balance should be rewardable");
    }

    // Test 6: Edge case - User exactly at the time threshold
    function test_ExactTimeThresholdRewardable() public {
        _supplyLiquidity(user1, LARGE_SUPPLY);

        // Fast-forward to exactly the reward interval
        vm.warp(block.timestamp + 180 days);

        bool isEligible = LendefiInstance.isRewardable(user1);
        assertTrue(isEligible, "User at exact time threshold should be rewardable");
    }

    // Test 7: User becomes ineligible after exchanging/withdrawing
    function test_BecomesIneligibleAfterWithdrawal() public {
        // Supply above threshold
        _supplyLiquidity(user1, LARGE_SUPPLY);

        // Fast-forward beyond reward interval
        vm.warp(block.timestamp + 181 days);

        // Verify initially eligible
        bool initialEligibility = LendefiInstance.isRewardable(user1);
        assertTrue(initialEligibility, "User should initially be eligible");

        // Exchange half of tokens
        uint256 userBalance = LendefiInstance.balanceOf(user1);
        vm.prank(user1);
        LendefiInstance.exchange(userBalance / 2);

        // Verify now ineligible due to reduced balance
        bool finalEligibility = LendefiInstance.isRewardable(user1);
        assertFalse(finalEligibility, "User should be ineligible after withdrawal");
    }

    // Test 8: Multiple users with different eligibility
    function test_MultipleUsersDifferentEligibility() public {
        // User1: Enough balance, enough time
        _supplyLiquidity(user1, LARGE_SUPPLY);

        // User2: Enough balance, not enough time
        _supplyLiquidity(user2, LARGE_SUPPLY);

        // User3: Not enough balance, enough time
        _supplyLiquidity(user3, SMALL_SUPPLY);

        // Fast-forward beyond reward interval for User1 and User3
        vm.warp(block.timestamp + 181 days);

        assertTrue(LendefiInstance.isRewardable(user1), "User1 should be eligible");
        assertTrue(LendefiInstance.isRewardable(user2), "User2 should be ineligible due to time");
        assertFalse(LendefiInstance.isRewardable(user3), "User3 should be ineligible due to balance");
    }

    // Test 9: Changing protocol parameters affects eligibility
    function test_ParameterChangesAffectEligibility() public {
        // Supply near the threshold
        _supplyLiquidity(user1, 110_000e6); // 110k USDC

        // Fast-forward beyond reward interval
        vm.warp(block.timestamp + 181 days);

        // Initially eligible
        assertTrue(LendefiInstance.isRewardable(user1), "User should initially be eligible");

        // Increase the threshold
        vm.prank(address(timelockInstance));
        LendefiInstance.updateRewardableSupply(150_000e6); // Increase to 150k

        // Should no longer be eligible
        assertFalse(LendefiInstance.isRewardable(user1), "User should be ineligible after threshold increase");
    }

    // Test 10: Protocol actions reset the timer
    function test_SupplyResetsRewardTimer() public {
        // Initial supply
        _supplyLiquidity(user1, LARGE_SUPPLY);

        // Fast-forward almost to eligibility
        vm.warp(block.timestamp + 179 days);

        // Supply more, which should reset the timer
        _supplyLiquidity(user1, MEDIUM_SUPPLY);

        // Fast-forward just a bit more (would have been eligible without the reset)
        vm.warp(block.timestamp + 2 days);

        // Should not be eligible due to reset timer
        assertFalse(LendefiInstance.isRewardable(user1), "User should not be eligible after timer reset");

        // Fast-forward the full interval after the second supply
        vm.warp(block.timestamp + 180 days);

        // Now should be eligible
        assertTrue(LendefiInstance.isRewardable(user1), "User should be eligible after full interval");
    }

    // Test 12: Zero totalSupply edge case
    function test_ZeroTotalSupplyEdgeCase() public {
        // Edge case: check isRewardable when totalSupply is 0
        // This should never happen in production, but testing for robustness

        // Verify the initial state
        assertEq(LendefiInstance.totalSupply(), 0, "Initial totalSupply should be zero");

        // This shouldn't revert
        bool result = LendefiInstance.isRewardable(user1);
        assertFalse(result, "User should not be rewardable with zero totalSupply");
    }
}
