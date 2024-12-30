// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../BasicDeploy.sol";
import {IPROTOCOL} from "../../contracts/interfaces/IProtocol.sol";
import {Lendefi} from "../../contracts/lender/Lendefi.sol";
import {console2} from "forge-std/console2.sol";
import {MockPriceOracle} from "../../contracts/mock/MockPriceOracle.sol";

contract UpdateProtocolParametersTest is BasicDeploy {
    // Events
    event UpdateBaseProfitTarget(uint256 rate);
    event UpdateBaseBorrowRate(uint256 rate);
    event UpdateTargetReward(uint256 amount);
    event UpdateRewardInterval(uint256 interval);
    event UpdateRewardableSupply(uint256 amount);
    event UpdateLiquidatorThreshold(uint256 amount);

    // Default values from initialize()
    uint256 constant DEFAULT_BASE_PROFIT_TARGET = 0.01e6; // 1%
    uint256 constant DEFAULT_BASE_BORROW_RATE = 0.06e6; // 6%
    uint256 constant DEFAULT_TARGET_REWARD = 2_000 ether;
    uint256 constant DEFAULT_REWARD_INTERVAL = 180 days;
    uint256 constant DEFAULT_REWARDABLE_SUPPLY = 100_000 * 1e6;
    uint256 constant DEFAULT_LIQUIDATOR_THRESHOLD = 20_000 ether;

    // New values for testing
    uint256 constant NEW_BASE_PROFIT_TARGET = 0.02e6; // 2%
    uint256 constant NEW_BASE_BORROW_RATE = 0.08e6; // 8%
    uint256 constant NEW_TARGET_REWARD = 3_000 ether;
    uint256 constant NEW_REWARD_INTERVAL = 365 days;
    uint256 constant NEW_REWARDABLE_SUPPLY = 150_000 * 1e6;
    uint256 constant NEW_LIQUIDATOR_THRESHOLD = 30_000 ether;

    // Minimum values for testing
    uint256 constant MIN_BASE_PROFIT_TARGET = 0.0025e6; // 0.25%
    uint256 constant MIN_BASE_BORROW_RATE = 0.01e6; // 1%
    uint256 constant MIN_REWARD_INTERVAL = 90 days;
    uint256 constant MIN_REWARDABLE_SUPPLY = 20_000 * 1e6;
    uint256 constant MIN_LIQUIDATOR_THRESHOLD = 10 ether;

    function setUp() public {
        deployComplete();

        // TGE setup
        vm.prank(guardian);
        tokenInstance.initializeTGE(address(ecoInstance), address(treasuryInstance));

        // Deploy USDC
        usdcInstance = new USDC();

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
    }

    /* --------------- updateBaseProfitTarget Tests --------------- */

    function test_UpdateBaseProfitTarget_AccessControl() public {
        // Regular user should not be able to update
        vm.prank(alice);
        vm.expectRevert();
        LendefiInstance.updateBaseProfitTarget(NEW_BASE_PROFIT_TARGET);

        // Manager should be able to update
        vm.prank(address(timelockInstance));
        LendefiInstance.updateBaseProfitTarget(NEW_BASE_PROFIT_TARGET);
    }

    function test_UpdateBaseProfitTarget_StateChange() public {
        // Verify initial value
        assertEq(LendefiInstance.baseProfitTarget(), DEFAULT_BASE_PROFIT_TARGET);

        // Update value
        vm.prank(address(timelockInstance));
        LendefiInstance.updateBaseProfitTarget(NEW_BASE_PROFIT_TARGET);

        // Verify updated value
        assertEq(LendefiInstance.baseProfitTarget(), NEW_BASE_PROFIT_TARGET);
    }

    function test_UpdateBaseProfitTarget_EventEmission() public {
        vm.expectEmit(false, false, false, true);
        emit UpdateBaseProfitTarget(NEW_BASE_PROFIT_TARGET);

        vm.prank(address(timelockInstance));
        LendefiInstance.updateBaseProfitTarget(NEW_BASE_PROFIT_TARGET);
    }

    function test_UpdateBaseProfitTarget_EffectOnSupplyRate() public {
        // Setup protocol with supply and borrow
        _setupProtocolWithSupplyAndBorrow();

        // Generate protocol profit by minting additional USDC directly to the contract
        // This simulates profit from interest accrual or other sources
        usdcInstance.mint(address(LendefiInstance), 5_000e6); // Add 5,000 USDC as profit

        // Now with added profit, total (balance + totalBorrow) > totalBase
        // So the baseProfitTarget will affect the supply rate

        // Get initial supply rate
        uint256 initialSupplyRate = LendefiInstance.getSupplyRate();

        // Update profit target (double it)
        vm.prank(address(timelockInstance));
        LendefiInstance.updateBaseProfitTarget(DEFAULT_BASE_PROFIT_TARGET * 2);

        // Get new supply rate
        uint256 newSupplyRate = LendefiInstance.getSupplyRate();

        // Supply rate should change when profit target changes
        assertNotEq(initialSupplyRate, newSupplyRate, "Supply rate should change when profit target changes");

        // Optional: Add these to verify rates are non-zero
        assertGt(initialSupplyRate, 0, "Initial supply rate should be greater than 0");
        assertGt(newSupplyRate, 0, "New supply rate should be greater than 0");
    }

    /* --------------- updateBaseBorrowRate Tests --------------- */

    function test_UpdateBaseBorrowRate_AccessControl() public {
        // Regular user should not be able to update
        vm.prank(alice);
        vm.expectRevert();
        LendefiInstance.updateBaseBorrowRate(NEW_BASE_BORROW_RATE);

        // Manager should be able to update
        vm.prank(address(timelockInstance));
        LendefiInstance.updateBaseBorrowRate(NEW_BASE_BORROW_RATE);
    }

    function test_UpdateBaseBorrowRate_StateChange() public {
        // Verify initial value
        assertEq(LendefiInstance.baseBorrowRate(), DEFAULT_BASE_BORROW_RATE);

        // Update value
        vm.prank(address(timelockInstance));
        LendefiInstance.updateBaseBorrowRate(NEW_BASE_BORROW_RATE);

        // Verify updated value
        assertEq(LendefiInstance.baseBorrowRate(), NEW_BASE_BORROW_RATE);
    }

    function test_UpdateBaseBorrowRate_EventEmission() public {
        vm.expectEmit(false, false, false, true);
        emit UpdateBaseBorrowRate(NEW_BASE_BORROW_RATE);

        vm.prank(address(timelockInstance));
        LendefiInstance.updateBaseBorrowRate(NEW_BASE_BORROW_RATE);
    }

    function test_UpdateBaseBorrowRate_EffectOnBorrowRate() public {
        // Setup protocol with supply and borrow
        _setupProtocolWithSupplyAndBorrow();

        // Get initial borrow rate
        uint256 initialBorrowRate = LendefiInstance.getBorrowRate(IPROTOCOL.CollateralTier.STABLE);

        // Update base borrow rate (double it)
        vm.prank(address(timelockInstance));
        LendefiInstance.updateBaseBorrowRate(DEFAULT_BASE_BORROW_RATE * 2);

        // Get new borrow rate
        uint256 newBorrowRate = LendefiInstance.getBorrowRate(IPROTOCOL.CollateralTier.STABLE);

        // Borrow rate should be higher after increase to base
        assertGt(newBorrowRate, initialBorrowRate, "Borrow rate should increase when base borrow rate increases");
    }

    /* --------------- updateTargetReward Tests --------------- */

    function test_UpdateTargetReward_AccessControl() public {
        // Regular user should not be able to update
        vm.prank(alice);
        vm.expectRevert();
        LendefiInstance.updateTargetReward(NEW_TARGET_REWARD);

        // Manager should be able to update
        vm.prank(address(timelockInstance));
        LendefiInstance.updateTargetReward(NEW_TARGET_REWARD);
    }

    function test_UpdateTargetReward_StateChange() public {
        // Verify initial value
        assertEq(LendefiInstance.targetReward(), DEFAULT_TARGET_REWARD);

        // Update value
        vm.prank(address(timelockInstance));
        LendefiInstance.updateTargetReward(NEW_TARGET_REWARD);

        // Verify updated value
        assertEq(LendefiInstance.targetReward(), NEW_TARGET_REWARD);
    }

    function test_UpdateTargetReward_EventEmission() public {
        vm.expectEmit(false, false, false, true);
        emit UpdateTargetReward(NEW_TARGET_REWARD);

        vm.prank(address(timelockInstance));
        LendefiInstance.updateTargetReward(NEW_TARGET_REWARD);
    }

    /* --------------- updateRewardInterval Tests --------------- */

    function test_UpdateRewardInterval_AccessControl() public {
        // Regular user should not be able to update
        vm.prank(alice);
        vm.expectRevert();
        LendefiInstance.updateRewardInterval(NEW_REWARD_INTERVAL);

        // Manager should be able to update
        vm.prank(address(timelockInstance));
        LendefiInstance.updateRewardInterval(NEW_REWARD_INTERVAL);
    }

    function test_UpdateRewardInterval_StateChange() public {
        // Verify initial value
        assertEq(LendefiInstance.rewardInterval(), DEFAULT_REWARD_INTERVAL);

        // Update value
        vm.prank(address(timelockInstance));
        LendefiInstance.updateRewardInterval(NEW_REWARD_INTERVAL);

        // Verify updated value
        assertEq(LendefiInstance.rewardInterval(), NEW_REWARD_INTERVAL);
    }

    function test_UpdateRewardInterval_EventEmission() public {
        vm.expectEmit(false, false, false, true);
        emit UpdateRewardInterval(NEW_REWARD_INTERVAL);

        vm.prank(address(timelockInstance));
        LendefiInstance.updateRewardInterval(NEW_REWARD_INTERVAL);
    }

    /* --------------- updateRewardableSupply Tests --------------- */

    function test_UpdateRewardableSupply_AccessControl() public {
        // Regular user should not be able to update
        vm.prank(alice);
        vm.expectRevert();
        LendefiInstance.updateRewardableSupply(NEW_REWARDABLE_SUPPLY);

        // Manager should be able to update
        vm.prank(address(timelockInstance));
        LendefiInstance.updateRewardableSupply(NEW_REWARDABLE_SUPPLY);
    }

    function test_UpdateRewardableSupply_StateChange() public {
        // Verify initial value
        assertEq(LendefiInstance.rewardableSupply(), DEFAULT_REWARDABLE_SUPPLY);

        // Update value
        vm.prank(address(timelockInstance));
        LendefiInstance.updateRewardableSupply(NEW_REWARDABLE_SUPPLY);

        // Verify updated value
        assertEq(LendefiInstance.rewardableSupply(), NEW_REWARDABLE_SUPPLY);
    }

    function test_UpdateRewardableSupply_EventEmission() public {
        vm.expectEmit(false, false, false, true);
        emit UpdateRewardableSupply(NEW_REWARDABLE_SUPPLY);

        vm.prank(address(timelockInstance));
        LendefiInstance.updateRewardableSupply(NEW_REWARDABLE_SUPPLY);
    }

    /* --------------- updateLiquidatorThreshold Tests --------------- */

    function test_UpdateLiquidatorThreshold_AccessControl() public {
        // Regular user should not be able to update
        vm.prank(alice);
        vm.expectRevert();
        LendefiInstance.updateLiquidatorThreshold(NEW_LIQUIDATOR_THRESHOLD);

        // Manager should be able to update
        vm.prank(address(timelockInstance));
        LendefiInstance.updateLiquidatorThreshold(NEW_LIQUIDATOR_THRESHOLD);
    }

    function test_UpdateLiquidatorThreshold_StateChange() public {
        // Verify initial value
        assertEq(LendefiInstance.liquidatorThreshold(), DEFAULT_LIQUIDATOR_THRESHOLD);

        // Update value
        vm.prank(address(timelockInstance));
        LendefiInstance.updateLiquidatorThreshold(NEW_LIQUIDATOR_THRESHOLD);

        // Verify updated value
        assertEq(LendefiInstance.liquidatorThreshold(), NEW_LIQUIDATOR_THRESHOLD);
    }

    function test_UpdateLiquidatorThreshold_EventEmission() public {
        vm.expectEmit(false, false, false, true);
        emit UpdateLiquidatorThreshold(NEW_LIQUIDATOR_THRESHOLD);

        vm.prank(address(timelockInstance));
        LendefiInstance.updateLiquidatorThreshold(NEW_LIQUIDATOR_THRESHOLD);
    }

    /* --------------- Comprehensive Tests --------------- */

    function test_UpdateMultipleParameters_StateChange() public {
        // Update all parameters at once
        vm.startPrank(address(timelockInstance));
        LendefiInstance.updateBaseProfitTarget(NEW_BASE_PROFIT_TARGET);
        LendefiInstance.updateBaseBorrowRate(NEW_BASE_BORROW_RATE);
        LendefiInstance.updateTargetReward(NEW_TARGET_REWARD);
        LendefiInstance.updateRewardInterval(NEW_REWARD_INTERVAL);
        LendefiInstance.updateRewardableSupply(NEW_REWARDABLE_SUPPLY);
        LendefiInstance.updateLiquidatorThreshold(NEW_LIQUIDATOR_THRESHOLD);
        vm.stopPrank();

        // Verify all parameters were updated
        assertEq(LendefiInstance.baseProfitTarget(), NEW_BASE_PROFIT_TARGET, "Base profit target not updated");
        assertEq(LendefiInstance.baseBorrowRate(), NEW_BASE_BORROW_RATE, "Base borrow rate not updated");
        assertEq(LendefiInstance.targetReward(), NEW_TARGET_REWARD, "Target reward not updated");
        assertEq(LendefiInstance.rewardInterval(), NEW_REWARD_INTERVAL, "Reward interval not updated");
        assertEq(LendefiInstance.rewardableSupply(), NEW_REWARDABLE_SUPPLY, "Rewardable supply not updated");
        assertEq(LendefiInstance.liquidatorThreshold(), NEW_LIQUIDATOR_THRESHOLD, "Liquidator threshold not updated");
    }

    function test_UpdateBaseProfitTarget_MinimumValue() public {
        // Should revert if rate is too low
        vm.prank(address(timelockInstance));
        vm.expectRevert(abi.encodeWithSelector(Lendefi.RateTooLow.selector, MIN_BASE_PROFIT_TARGET - 1, 0.0025e6));
        LendefiInstance.updateBaseProfitTarget(MIN_BASE_PROFIT_TARGET - 1);

        // Should succeed with minimum value
        vm.prank(address(timelockInstance));
        LendefiInstance.updateBaseProfitTarget(MIN_BASE_PROFIT_TARGET);
    }

    function test_UpdateBaseBorrowRate_MinimumValue() public {
        // Should revert if rate is too low
        vm.prank(address(timelockInstance));
        vm.expectRevert(abi.encodeWithSelector(Lendefi.RateTooLow.selector, MIN_BASE_BORROW_RATE - 1, 0.01e6));
        LendefiInstance.updateBaseBorrowRate(MIN_BASE_BORROW_RATE - 1);

        // Should succeed with minimum value
        vm.prank(address(timelockInstance));
        LendefiInstance.updateBaseBorrowRate(MIN_BASE_BORROW_RATE);
    }

    function test_UpdateRewardInterval_MinimumValue() public {
        // Should revert if interval is too short
        vm.prank(address(timelockInstance));
        vm.expectRevert(
            abi.encodeWithSelector(Lendefi.RewardIntervalTooShort.selector, MIN_REWARD_INTERVAL - 1, 90 days)
        );
        LendefiInstance.updateRewardInterval(MIN_REWARD_INTERVAL - 1);

        // Should succeed with minimum value
        vm.prank(address(timelockInstance));
        LendefiInstance.updateRewardInterval(MIN_REWARD_INTERVAL);
    }

    function test_UpdateRewardableSupply_MinimumValue() public {
        // Should revert if amount is too low
        vm.prank(address(timelockInstance));

        // Fix: Update expected error parameter to match the constant MIN_REWARDABLE_SUPPLY
        vm.expectRevert(
            abi.encodeWithSelector(
                Lendefi.RateTooLow.selector,
                MIN_REWARDABLE_SUPPLY - 1, // The attempted value
                20_000e6 // The minimum required value
            )
        );

        LendefiInstance.updateRewardableSupply(MIN_REWARDABLE_SUPPLY - 1);

        // Should succeed with minimum value
        vm.prank(address(timelockInstance));
        LendefiInstance.updateRewardableSupply(MIN_REWARDABLE_SUPPLY);
    }

    function test_UpdateLiquidatorThreshold_MinimumValue() public {
        // Should revert if amount is too low
        vm.prank(address(timelockInstance));
        vm.expectRevert(
            abi.encodeWithSelector(Lendefi.LiquidatorThresholdTooLow.selector, MIN_LIQUIDATOR_THRESHOLD - 1, 10 ether)
        );
        LendefiInstance.updateLiquidatorThreshold(MIN_LIQUIDATOR_THRESHOLD - 1);

        // Should succeed with minimum value
        vm.prank(address(timelockInstance));
        LendefiInstance.updateLiquidatorThreshold(MIN_LIQUIDATOR_THRESHOLD);
    }
    /* --------------- Helper Functions --------------- */

    function _setupProtocolWithSupplyAndBorrow() internal {
        // Mint USDC to alice and supply liquidity
        usdcInstance.mint(alice, 100_000e6);
        vm.startPrank(alice);
        usdcInstance.approve(address(LendefiInstance), 100_000e6);
        LendefiInstance.supplyLiquidity(100_000e6);
        vm.stopPrank();

        // Set up a mock price oracle for WETH
        wethInstance = new WETH9();
        MockPriceOracle wethOracle = new MockPriceOracle();
        wethOracle.setPrice(2500e8);
        wethOracle.setTimestamp(block.timestamp);
        wethOracle.setRoundId(1);
        wethOracle.setAnsweredInRound(1);

        // Configure WETH as CROSS_A tier asset
        vm.startPrank(address(timelockInstance));
        LendefiInstance.updateAssetConfig(
            address(wethInstance),
            address(wethOracle),
            8, // oracle decimals
            18, // asset decimals
            1, // active
            800, // 80% borrow threshold
            850, // 85% liquidation threshold
            1_000_000 ether, // max supply
            IPROTOCOL.CollateralTier.CROSS_A,
            0 // no isolation debt cap
        );
        vm.stopPrank();

        // Bob supplies collateral and borrows
        vm.deal(bob, 10 ether);
        vm.startPrank(bob);
        wethInstance.deposit{value: 10 ether}();
        wethInstance.approve(address(LendefiInstance), 10 ether);
        LendefiInstance.createPosition(address(wethInstance), false);
        LendefiInstance.supplyCollateral(address(wethInstance), 10 ether, 0);
        LendefiInstance.borrow(0, 10_000e6); // Borrow 10k USDC
        vm.stopPrank();
    }
}
