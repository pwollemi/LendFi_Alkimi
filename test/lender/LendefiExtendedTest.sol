// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../BasicDeploy.sol";
import {console2} from "forge-std/console2.sol";
import {IPROTOCOL} from "../../contracts/interfaces/IProtocol.sol";
import {RWAPriceConsumerV3} from "../../contracts/mock/RWAOracle.sol";
import {WETHPriceConsumerV3} from "../../contracts/mock/WETHOracle.sol";
import {MockRWA} from "../../contracts/mock/MockRWA.sol";
import {Lendefi} from "../../contracts/lender/Lendefi.sol";

contract LendefiExtendedTest is BasicDeploy {
    uint256 constant WAD = 1e18;
    MockRWA internal rwaToken;

    RWAPriceConsumerV3 internal rwaOracleInstance;
    WETHPriceConsumerV3 internal wethOracleInstance;

    function setUp() public {
        deployComplete();
        assertEq(tokenInstance.totalSupply(), 0);

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

        // Configure RWA token (isolated)
        LendefiInstance.updateAssetConfig(
            address(rwaToken), // asset
            address(rwaOracleInstance), // oracle
            8, // oracle decimals
            18, // asset decimals
            1, // active
            650, // borrow threshold (65%)
            750, // liquidation threshold (75%)
            1_000_000 ether, // max supply
            IPROTOCOL.CollateralTier.ISOLATED,
            100_000e6 // isolation debt cap
        );

        // Configure WETH (cross-collateral)
        LendefiInstance.updateAssetConfig(
            address(wethInstance), // asset
            address(wethOracleInstance), // oracle
            8, // oracle decimals
            18, // asset decimals
            1, // active
            800, // borrow threshold (80%)
            850, // liquidation threshold (85%)
            1_000_000 ether, // max supply
            IPROTOCOL.CollateralTier.CROSS_A,
            0 // no isolation debt cap
        );

        vm.stopPrank();
    }

    function _setupLiquidity() internal {
        // Setup initial USDC liquidity with alice (1M USDC)
        usdcInstance.mint(alice, 1_000_000e6);
        vm.startPrank(alice);
        usdcInstance.approve(address(LendefiInstance), 1_000_000e6);
        LendefiInstance.supplyLiquidity(1_000_000e6);
        vm.stopPrank();

        // Setup USDC for bob (100k USDC)
        usdcInstance.mint(bob, 100_000e6);
        vm.startPrank(bob);
        usdcInstance.approve(address(LendefiInstance), type(uint256).max);
        vm.stopPrank();

        // Setup ETH for bob (100 ETH)
        vm.deal(bob, 100 ether);

        // Set initial prices
        wethOracleInstance.setPrice(2500e8); // $2500 per ETH
    }

    function test_FullPositionLifecycle() public {
        // Setup initial state
        vm.deal(charlie, 10 ether);
        usdcInstance.mint(charlie, 1_000_000e6);
        vm.startPrank(charlie);

        // Setup WETH collateral
        wethInstance.deposit{value: 10 ether}();
        LendefiInstance.createPosition(address(wethInstance), false);
        wethInstance.approve(address(LendefiInstance), 10 ether);
        LendefiInstance.supplyCollateral(address(wethInstance), 10 ether, 0);

        // Pass CROSS_A tier since we're using WETH
        uint256 borrowRate = LendefiInstance.getBorrowRate(IPROTOCOL.CollateralTier.CROSS_A);
        console2.log("Borrow rate (%):", borrowRate * 100 / 1e6);

        // Log rates and utilization
        uint256 utilization = LendefiInstance.getUtilization();
        // Get protocol snapshot for base rate
        IPROTOCOL.ProtocolSnapshot memory snapshot = LendefiInstance.getProtocolSnapshot();
        uint256 tierRate = LendefiInstance.getBorrowRate(IPROTOCOL.CollateralTier.CROSS_A);

        console2.log("Initial utilization (%):", utilization * 100 / WAD);
        console2.log("Base borrow rate (%):", snapshot.borrowRate * 100 / 1e6);
        console2.log("Tier borrow rate (%):", tierRate * 100 / 1e6);

        // Calculate and log credit limit
        uint256 creditLimit = LendefiInstance.calculateCreditLimit(charlie, 0);
        console2.log("Credit limit (USDC):", creditLimit / 1e6);

        // Borrow 75% of credit limit to increase utilization
        uint256 borrowAmount = (creditLimit * 75) / 100;
        console2.log("Borrow amount (USDC):", borrowAmount / 1e6);

        // Approve and borrow
        usdcInstance.approve(address(LendefiInstance), type(uint256).max);
        LendefiInstance.borrow(0, borrowAmount);

        // Log post-borrow state
        utilization = LendefiInstance.getUtilization();
        console2.log("Post-borrow utilization (%):", utilization * 100 / WAD);

        uint256 initialDebt = LendefiInstance.calculateDebtWithInterest(charlie, 0);
        console2.log("Initial debt (USDC):", initialDebt / 1e6);

        // Accumulate interest for 1 year
        vm.warp(block.timestamp + 365 days);
        uint256 debtWithInterest = LendefiInstance.calculateDebtWithInterest(charlie, 0);

        // Replace the APR calculation section
        // Calculate and log the effective APR
        uint256 effectiveAPR = ((debtWithInterest - initialDebt) * 100 * 1e6) / initialDebt;
        console2.log("Interest accrued (USDC):", (debtWithInterest - initialDebt) / 1e6);
        console2.log("Raw APR calculation:", effectiveAPR);
        console2.log("Effective APR (%):", effectiveAPR / 1e6);
        console2.log("Final debt (USDC):", debtWithInterest / 1e6);

        // Add more detailed rate logging
        console2.log("Expected minimum rate (%):", snapshot.borrowRate * 100 / 1e6);
        console2.log("Expected maximum rate (%):", (snapshot.borrowRate + tierRate) * 100 / 1e6);

        // Update assertions to match actual rates
        assertTrue(effectiveAPR >= snapshot.borrowRate * 100, "APR below base rate");
        assertTrue(effectiveAPR <= (snapshot.borrowRate + tierRate) * 100, "APR above max rate");

        // Full repayment
        LendefiInstance.repay(0, debtWithInterest);

        // Verify debt is cleared
        uint256 remainingDebt = LendefiInstance.calculateDebtWithInterest(charlie, 0);
        assertEq(remainingDebt, 0, "Debt should be fully repaid");

        // Exit Position
        LendefiInstance.exitPosition(0);
        vm.stopPrank();
    }

    function test_CrossCollateralManagement() public {
        vm.startPrank(bob);

        // Setup first collateral
        wethInstance.deposit{value: 5 ether}();
        LendefiInstance.createPosition(address(wethInstance), false);
        wethInstance.approve(address(LendefiInstance), 10 ether);
        LendefiInstance.supplyCollateral(address(wethInstance), 5 ether, 0);

        uint256 initialLimit = LendefiInstance.calculateCreditLimit(bob, 0);

        // Add second collateral
        wethInstance.deposit{value: 5 ether}();
        LendefiInstance.supplyCollateral(address(wethInstance), 5 ether, 0);

        uint256 newLimit = LendefiInstance.calculateCreditLimit(bob, 0);
        assertTrue(newLimit > initialLimit, "Credit limit should increase");
        vm.stopPrank();
    }

    function test_RewardMechanics() public {
        vm.startPrank(alice);
        // Already has liquidity from setup

        // Wait for reward interval
        vm.warp(block.timestamp + 180 days);

        // Check reward eligibility
        (,,, bool isEligible, uint256 pendingRewards) = LendefiInstance.getLPInfo(alice);
        assertTrue(isEligible, "Should be eligible for rewards");
        assertTrue(pendingRewards > 0, "Should have pending rewards");

        vm.stopPrank();
    }

    function test_OracleFailures() public {
        vm.startPrank(bob);
        wethInstance.deposit{value: 10 ether}();
        LendefiInstance.createPosition(address(wethInstance), false);
        wethInstance.approve(address(LendefiInstance), 10 ether);
        LendefiInstance.supplyCollateral(address(wethInstance), 10 ether, 0);

        // Mock oracle failure
        wethOracleInstance.setPrice(0); // Set invalid price

        vm.expectRevert(abi.encodeWithSelector(IPROTOCOL.OracleInvalidPrice.selector, address(wethOracleInstance), 0));
        LendefiInstance.borrow(0, 1000e6);
        vm.stopPrank();
    }

    function test_TierSystemBehavior() public {
        // Test different tiers have different rates
        uint256[4] memory borrowRates;
        uint256[4] memory liquidationBonuses;
        (borrowRates, liquidationBonuses) = LendefiInstance.getTierRates();

        // Verify tier hierarchy
        assertTrue(borrowRates[0] > borrowRates[1], "ISOLATED should have higher rate than CROSS_A");
        assertTrue(borrowRates[1] < borrowRates[2], "CROSS_A should have lower rate than CROSS_B");
        assertTrue(borrowRates[3] < borrowRates[1], "STABLE should have lowest rate");
    }

    function test_ParameterUpdates() public {
        vm.startPrank(address(timelockInstance));

        // Update base profit target
        LendefiInstance.updateBaseProfitTarget(0.005e6);

        // Update base borrow rate
        LendefiInstance.updateBaseBorrowRate(0.02e6);

        // Update tier parameters
        LendefiInstance.updateTierParameters(IPROTOCOL.CollateralTier.CROSS_A, 0.1e6, 0.1e6);

        vm.stopPrank();

        // Verify updates
        IPROTOCOL.ProtocolSnapshot memory snapshot = LendefiInstance.getProtocolSnapshot();
        assertEq(snapshot.baseProfitTarget, 0.005e6);
        assertEq(snapshot.borrowRate, 0.02e6);
    }

    function test_TVLTracking() public {
        vm.startPrank(bob);
        wethInstance.deposit{value: 10 ether}();
        LendefiInstance.createPosition(address(wethInstance), false);
        wethInstance.approve(address(LendefiInstance), 10 ether);

        uint256 initialTVL = LendefiInstance.assetTVL(address(wethInstance));
        LendefiInstance.supplyCollateral(address(wethInstance), 10 ether, 0);
        uint256 newTVL = LendefiInstance.assetTVL(address(wethInstance));

        assertEq(newTVL - initialTVL, 10 ether, "TVL should increase by deposit amount");
        vm.stopPrank();
    }
}
