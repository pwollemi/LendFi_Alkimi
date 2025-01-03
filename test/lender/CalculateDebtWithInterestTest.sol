// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../BasicDeploy.sol";
import {console2} from "forge-std/console2.sol";
import {IPROTOCOL} from "../../contracts/interfaces/IProtocol.sol";
import {RWAPriceConsumerV3} from "../../contracts/mock/RWAOracle.sol";
import {WETHPriceConsumerV3} from "../../contracts/mock/WETHOracle.sol";
import {StablePriceConsumerV3} from "../../contracts/mock/StableOracle.sol";
import {MockRWA} from "../../contracts/mock/MockRWA.sol";
import {Lendefi} from "../../contracts/lender/Lendefi.sol";

contract CalculateDebtWithInterestTest is BasicDeploy {
    MockRWA internal rwaToken;

    RWAPriceConsumerV3 internal rwaOracleInstance;
    WETHPriceConsumerV3 internal wethOracleInstance;
    StablePriceConsumerV3 internal stableOracleInstance;

    function setUp() public {
        deployCompleteWithOracle();

        // TGE setup
        vm.prank(guardian);
        tokenInstance.initializeTGE(address(ecoInstance), address(treasuryInstance));
        vm.warp(block.timestamp + 90 days);
        // Deploy mock tokens

        wethInstance = new WETH9();
        rwaToken = new MockRWA("Ondo Finance", "ONDO");

        // Deploy oracles
        wethOracleInstance = new WETHPriceConsumerV3();
        rwaOracleInstance = new RWAPriceConsumerV3();
        stableOracleInstance = new StablePriceConsumerV3();

        // Set prices
        wethOracleInstance.setPrice(2500e8); // $2500 per ETH
        rwaOracleInstance.setPrice(1000e8); // $1000 per RWA token
        stableOracleInstance.setPrice(1e8); // $1 per stable token
        // Register oracles with Oracle module
        vm.startPrank(address(timelockInstance));
        oracleInstance.addOracle(address(wethInstance), address(wethOracleInstance), 8);
        oracleInstance.setPrimaryOracle(address(wethInstance), address(wethOracleInstance));

        oracleInstance.addOracle(address(rwaToken), address(rwaOracleInstance), 8);
        oracleInstance.setPrimaryOracle(address(rwaToken), address(rwaOracleInstance));

        oracleInstance.addOracle(address(usdcInstance), address(stableOracleInstance), 8);
        oracleInstance.setPrimaryOracle(address(usdcInstance), address(stableOracleInstance));
        vm.stopPrank();
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

        // Configure stable token as STABLE tier
        LendefiInstance.updateAssetConfig(
            address(usdcInstance),
            address(stableOracleInstance),
            8,
            6,
            1,
            900, // 90% borrow threshold
            950, // 95% liquidation threshold
            1_000_000 ether,
            IPROTOCOL.CollateralTier.STABLE,
            0
        );

        vm.stopPrank();
    }

    function _setupLiquidity() internal {
        // Add liquidity to the protocol to enable borrowing
        usdcInstance.mint(guardian, 1_000_000e6);
        vm.startPrank(guardian);
        usdcInstance.approve(address(LendefiInstance), 1_000_000e6);
        LendefiInstance.supplyLiquidity(1_000_000e6);
        vm.stopPrank();
    }

    // Helper function to create position
    function _createPosition(address user, address asset, bool isIsolated) internal returns (uint256) {
        vm.prank(user);
        LendefiInstance.createPosition(asset, isIsolated);
        return LendefiInstance.getUserPositionsCount(user) - 1;
    }

    // Helper to mint and supply collateral
    function _mintAndSupplyCollateral(address user, address asset, uint256 amount, uint256 positionId) internal {
        // Mint tokens to user
        if (asset == address(wethInstance)) {
            vm.deal(user, amount);
            vm.prank(user);
            wethInstance.deposit{value: amount}();
        } else if (asset == address(rwaToken)) {
            rwaToken.mint(user, amount);
        } else if (asset == address(usdcInstance)) {
            usdcInstance.mint(user, amount);
        }

        // Supply collateral
        vm.startPrank(user);
        IERC20(asset).approve(address(LendefiInstance), amount);
        LendefiInstance.supplyCollateral(asset, amount, positionId);
        vm.stopPrank();
    }

    // Helper to borrow
    function _borrowFromPosition(address user, uint256 positionId, uint256 amount) internal {
        vm.startPrank(user);
        LendefiInstance.borrow(positionId, amount);
        vm.stopPrank();
    }

    // Test 1: Zero debt returns zero
    function test_ZeroDebtReturnsZero() public {
        // Create a position
        uint256 positionId = _createPosition(alice, address(wethInstance), false);

        // Supply collateral but don't borrow
        _mintAndSupplyCollateral(alice, address(wethInstance), 10 ether, positionId);

        // Check that debt with interest is zero
        uint256 debtWithInterest = LendefiInstance.calculateDebtWithInterest(alice, positionId);
        assertEq(debtWithInterest, 0, "Zero debt should return zero interest");
    }

    // Test 2: Interest calculation for isolated position
    function test_IsolatedPositionInterestCalculation() public {
        // Create isolated position
        uint256 positionId = _createPosition(alice, address(rwaToken), true);

        // Supply collateral and borrow
        _mintAndSupplyCollateral(alice, address(rwaToken), 100 ether, positionId);
        uint256 borrowAmount = 10_000e6; // 10,000 USDC
        _borrowFromPosition(alice, positionId, borrowAmount);

        // Get initial debt
        uint256 initialDebt = LendefiInstance.getPositionDebt(alice, positionId);
        assertEq(initialDebt, borrowAmount, "Initial debt should match borrowed amount");

        // Move forward in time (30 days)
        vm.warp(block.timestamp + 30 days);

        // Check that debt has increased due to interest
        uint256 debtWithInterest = LendefiInstance.calculateDebtWithInterest(alice, positionId);
        assertTrue(debtWithInterest > borrowAmount, "Debt should increase due to interest");

        // Get isolated tier rate for verification
        uint256 isolatedRate = LendefiInstance.getBorrowRate(IPROTOCOL.CollateralTier.ISOLATED);

        // Calculate expected interest manually
        uint256 timeElapsed = 30 days;
        uint256 annualRateRay = LendefiInstance.annualRateToRay(isolatedRate);
        uint256 expectedDebt = LendefiInstance.accrueInterest(borrowAmount, annualRateRay, timeElapsed);

        // Allow small deviation (1 wei) due to potential rounding differences
        uint256 deviation =
            debtWithInterest > expectedDebt ? debtWithInterest - expectedDebt : expectedDebt - debtWithInterest;

        assertLe(deviation, 1, "Interest calculation should match expected value");
    }

    function test_CrossPositionInterestCalculation() public {
        // Create cross-collateral position
        uint256 positionId = _createPosition(alice, address(wethInstance), false);

        // Supply collateral and borrow
        _mintAndSupplyCollateral(alice, address(wethInstance), 10 ether, positionId);
        uint256 borrowAmount = 10_000e6; // 10,000 USDC
        _borrowFromPosition(alice, positionId, borrowAmount);

        // Move forward in time (90 days)
        vm.warp(block.timestamp + 180 days);

        // Get position data
        IPROTOCOL.UserPosition memory position = LendefiInstance.getUserPosition(alice, positionId);

        // Use the EXACT same logic as calculateDebtWithInterest
        IPROTOCOL.CollateralTier tier = LendefiInstance.getHighestTier(alice, positionId);
        uint256 actualTierRate = LendefiInstance.getBorrowRate(tier);

        console2.log("Highest tier detected:", uint256(tier));
        console2.log("CROSS_A tier value:", uint256(IPROTOCOL.CollateralTier.CROSS_A));

        // Calculate using the same tier determined by the contract
        uint256 timeElapsed = block.timestamp - position.lastInterestAccrual;
        uint256 annualRateRay = LendefiInstance.annualRateToRay(actualTierRate);
        uint256 expectedDebt = LendefiInstance.accrueInterest(position.debtAmount, annualRateRay, timeElapsed);

        // Check debt with interest
        uint256 debtWithInterest = LendefiInstance.calculateDebtWithInterest(alice, positionId);

        uint256 deviation =
            debtWithInterest > expectedDebt ? debtWithInterest - expectedDebt : expectedDebt - debtWithInterest;

        // Debug logging
        console2.log("Position debt amount:", position.debtAmount / 1e6);
        console2.log("Expected debt:", expectedDebt / 1e6);
        console2.log("Actual debt with interest:", debtWithInterest / 1e6);
        console2.log("Deviation:", deviation);

        // The deviation should now be zero or very small
        assertEq(deviation, 0, "Interest calculation should match exactly");
    }

    function test_MultiTierPositionInterestCalculation() public {
        // Create cross-collateral position
        uint256 positionId = _createPosition(alice, address(wethInstance), false);

        // Supply WETH (CROSS_A tier)
        _mintAndSupplyCollateral(alice, address(wethInstance), 10 ether, positionId);

        // Add STABLE tier collateral to the same position
        _mintAndSupplyCollateral(alice, address(usdcInstance), 10_000e6, positionId);

        uint256 borrowAmount = 15_000e6; // 15,000 USDC
        _borrowFromPosition(alice, positionId, borrowAmount);

        // Move forward in time (180 days), 90 days beyond the setUp warp
        vm.warp(block.timestamp + 180 days);

        // Get position data first - this is crucial
        IPROTOCOL.UserPosition memory position = LendefiInstance.getUserPosition(alice, positionId);

        // Check debt with interest
        uint256 debtWithInterest = LendefiInstance.calculateDebtWithInterest(alice, positionId);

        // The highest tier should be CROSS_A (not STABLE)
        // This is because numerically CROSS_A (1) > STABLE (0)
        IPROTOCOL.CollateralTier highestTier = LendefiInstance.getHighestTier(alice, positionId);

        // Debug information
        console2.log("Highest tier value:", uint256(highestTier));
        console2.log("STABLE tier value:", uint256(IPROTOCOL.CollateralTier.STABLE));
        console2.log("CROSS_A tier value:", uint256(IPROTOCOL.CollateralTier.CROSS_A));

        assertEq(
            uint256(highestTier),
            uint256(IPROTOCOL.CollateralTier.CROSS_A),
            "Highest tier should be CROSS_A (numerically higher than STABLE)"
        );

        // Get CROSS_A tier rate (not STABLE)
        uint256 crossATierRate = LendefiInstance.getBorrowRate(highestTier);

        // Calculate expected debt with EXACT same values used in contract
        uint256 timeElapsed = block.timestamp - position.lastInterestAccrual;
        uint256 annualRateRay = LendefiInstance.annualRateToRay(crossATierRate);
        uint256 expectedDebt = LendefiInstance.accrueInterest(position.debtAmount, annualRateRay, timeElapsed);

        // Verify interest calculation
        uint256 deviation =
            debtWithInterest > expectedDebt ? debtWithInterest - expectedDebt : expectedDebt - debtWithInterest;

        // Add debug logs
        console2.log("Position debt amount:", position.debtAmount / 1e6);
        console2.log("Time elapsed (days):", timeElapsed / 1 days);
        console2.log("Expected debt:", expectedDebt / 1e6);
        console2.log("Actual debt with interest:", debtWithInterest / 1e6);
        console2.log("Deviation:", deviation);

        assertLe(deviation, 1, "Multi-tier interest calculation should use highest tier rate");
    }

    function test_LongTermInterestCalculation() public {
        // Create position
        uint256 positionId = _createPosition(alice, address(wethInstance), false);

        // Supply collateral and borrow
        _mintAndSupplyCollateral(alice, address(wethInstance), 20 ether, positionId);
        uint256 borrowAmount = 5_000e6; // 5,000 USDC
        _borrowFromPosition(alice, positionId, borrowAmount);

        // Move forward 1 year
        vm.warp(block.timestamp + 365 days);

        // Check debt with interest
        uint256 debtWithInterest = LendefiInstance.calculateDebtWithInterest(alice, positionId);

        // Get rate
        uint256 tierRate = LendefiInstance.getBorrowRate(IPROTOCOL.CollateralTier.CROSS_A);

        // For a full year, interest should be approximately borrowAmount * rate
        uint256 expectedInterest = (borrowAmount * tierRate) / 1e6;
        uint256 expectedDebt = borrowAmount + expectedInterest;

        // Use a slightly larger tolerance for longer periods due to compounding effects
        uint256 tolerance = (expectedDebt * 1) / 100; // 1% tolerance

        assertTrue(
            debtWithInterest >= expectedDebt - tolerance && debtWithInterest <= expectedDebt + tolerance,
            "Long-term interest calculation should be approximately correct"
        );
    }

    function test_InvalidPositionReverts() public {
        // Try to calculate debt for a position that doesn't exist
        vm.expectRevert();
        LendefiInstance.calculateDebtWithInterest(alice, 999);
    }
}
