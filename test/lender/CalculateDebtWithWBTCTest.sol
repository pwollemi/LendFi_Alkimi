// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../BasicDeploy.sol";
import {console2} from "forge-std/console2.sol";
import {IPROTOCOL} from "../../contracts/interfaces/IProtocol.sol";
import {WETHPriceConsumerV3} from "../../contracts/mock/WETHOracle.sol";
import {StablePriceConsumerV3} from "../../contracts/mock/StableOracle.sol";
import {MockWBTC} from "../../contracts/mock/MockWBTC.sol";
import {Lendefi} from "../../contracts/lender/Lendefi.sol";

contract WBTCInterestTest is BasicDeploy {
    // Token instances
    MockWBTC internal wbtcIsolatedToken;
    MockWBTC internal wbtcCrossToken;

    // Oracle instances
    WETHPriceConsumerV3 internal wbtcOracleInstance;
    WETHPriceConsumerV3 internal wethOracleInstance;
    StablePriceConsumerV3 internal stableOracleInstance;

    function setUp() public {
        deployComplete();

        // TGE setup
        vm.prank(guardian);
        tokenInstance.initializeTGE(address(ecoInstance), address(treasuryInstance));
        vm.warp(block.timestamp + 90 days);

        // Deploy tokens
        usdcInstance = new USDC();
        wethInstance = new WETH9();
        wbtcIsolatedToken = new MockWBTC();
        wbtcCrossToken = new MockWBTC();

        // Deploy oracles
        wethOracleInstance = new WETHPriceConsumerV3();
        wbtcOracleInstance = new WETHPriceConsumerV3();
        stableOracleInstance = new StablePriceConsumerV3();

        // Set prices
        wethOracleInstance.setPrice(2500e8); // $2500 per ETH
        wbtcOracleInstance.setPrice(60000e8); // $60,000 per BTC
        stableOracleInstance.setPrice(1e8); // $1 per stable

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
            8, // Oracle decimals
            18, // Asset decimals
            1, // Active
            800, // 80% borrow threshold
            850, // 85% liquidation threshold
            1_000_000 ether, // Supply limit
            IPROTOCOL.CollateralTier.CROSS_A,
            0 // No isolation debt cap for CROSS assets
        );

        // Configure first WBTC token as ISOLATED tier
        LendefiInstance.updateAssetConfig(
            address(wbtcIsolatedToken),
            address(wbtcOracleInstance),
            8, // Oracle decimals
            8, // Asset decimals
            1, // Active
            800, // 80% borrow threshold
            850, // 85% liquidation threshold
            1_000 * 1e8, // Supply limit
            IPROTOCOL.CollateralTier.ISOLATED,
            1_000_000e6 // isolation debt cap
        );

        // Configure second WBTC token as CROSS_A tier
        LendefiInstance.updateAssetConfig(
            address(wbtcCrossToken),
            address(wbtcOracleInstance),
            8, // Oracle decimals
            8, // Asset decimals
            1, // Active
            800, // 80% borrow threshold
            850, // 85% liquidation threshold
            1_000 * 1e8, // Supply limit
            IPROTOCOL.CollateralTier.CROSS_A,
            0 // No isolation debt cap for CROSS assets
        );

        // Configure USDC as STABLE tier
        LendefiInstance.updateAssetConfig(
            address(usdcInstance),
            address(stableOracleInstance),
            8, // Oracle decimals
            6, // USDC decimals
            1, // Active
            900, // 90% borrow threshold
            950, // 95% liquidation threshold
            1_000_000e6, // Supply limit
            IPROTOCOL.CollateralTier.STABLE,
            0 // No isolation debt cap for STABLE assets
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

    // Helper to borrow
    function _borrowFromPosition(address user, uint256 positionId, uint256 amount) internal {
        vm.startPrank(user);
        LendefiInstance.borrow(positionId, amount);
        vm.stopPrank();
    }

    // Test: WBTC Isolated Position
    function test_WBTCIsolatedPositionInterest() public {
        // Create isolated position with ISOLATED tier WBTC
        uint256 positionId = _createPosition(alice, address(wbtcIsolatedToken), true);

        // Supply 1 BTC as collateral
        uint256 btcAmount = 1e8; // 1 BTC
        wbtcIsolatedToken.mint(alice, btcAmount);

        vm.startPrank(alice);
        wbtcIsolatedToken.approve(address(LendefiInstance), btcAmount);
        LendefiInstance.supplyCollateral(address(wbtcIsolatedToken), btcAmount, positionId);
        vm.stopPrank();

        // Borrow some USDC
        uint256 borrowAmount = 20_000e6; // 20,000 USDC
        _borrowFromPosition(alice, positionId, borrowAmount);

        // Move forward in time (60 days)
        vm.warp(block.timestamp + 60 days);

        // Get position data
        IPROTOCOL.UserPosition memory position = LendefiInstance.getUserPosition(alice, positionId);

        // Check debt with interest
        uint256 debtWithInterest = LendefiInstance.calculateDebtWithInterest(alice, positionId);

        // Calculate expected debt
        uint256 tierRate = LendefiInstance.getBorrowRate(IPROTOCOL.CollateralTier.ISOLATED);
        uint256 timeElapsed = block.timestamp - position.lastInterestAccrual;
        uint256 annualRateRay = LendefiInstance.annualRateToRay(tierRate);
        uint256 expectedDebt = LendefiInstance.accrueInterest(position.debtAmount, annualRateRay, timeElapsed);

        // Check deviation
        uint256 deviation =
            debtWithInterest > expectedDebt ? debtWithInterest - expectedDebt : expectedDebt - debtWithInterest;

        assertEq(deviation, 0, "Interest calculation should match exactly");
    }

    // Test: WBTC + ETH Multi-Asset Position
    function test_WBTCAndETHCollateralInterestCalculation() public {
        // Create cross-collateral position
        uint256 positionId = _createPosition(alice, address(wethInstance), false);

        // Supply WETH (10 ETH)
        uint256 ethAmount = 10 ether;
        vm.deal(alice, ethAmount);
        vm.startPrank(alice);
        wethInstance.deposit{value: ethAmount}();
        wethInstance.approve(address(LendefiInstance), ethAmount);
        LendefiInstance.supplyCollateral(address(wethInstance), ethAmount, positionId);
        vm.stopPrank();

        // Supply WBTC (1 BTC)
        uint256 btcAmount = 1e8;
        wbtcCrossToken.mint(alice, btcAmount);
        vm.startPrank(alice);
        wbtcCrossToken.approve(address(LendefiInstance), btcAmount);
        LendefiInstance.supplyCollateral(address(wbtcCrossToken), btcAmount, positionId);
        vm.stopPrank();

        // Borrow against multi-asset collateral
        uint256 borrowAmount = 30_000e6; // 30,000 USDC
        _borrowFromPosition(alice, positionId, borrowAmount);

        // Move forward 150 days
        vm.warp(block.timestamp + 150 days);

        // Get position data
        IPROTOCOL.UserPosition memory position = LendefiInstance.getUserPosition(alice, positionId);

        // Check debt with interest
        uint256 debtWithInterest = LendefiInstance.calculateDebtWithInterest(alice, positionId);

        // Get the highest tier (should be CROSS_A)
        IPROTOCOL.CollateralTier highestTier = LendefiInstance.getHighestTier(alice, positionId);
        assertEq(uint256(highestTier), uint256(IPROTOCOL.CollateralTier.CROSS_A), "Highest tier should be CROSS_A");

        // Calculate expected debt
        uint256 tierRate = LendefiInstance.getBorrowRate(highestTier);
        uint256 timeElapsed = block.timestamp - position.lastInterestAccrual;
        uint256 annualRateRay = LendefiInstance.annualRateToRay(tierRate);
        uint256 expectedDebt = LendefiInstance.accrueInterest(position.debtAmount, annualRateRay, timeElapsed);

        // Check deviation
        uint256 deviation =
            debtWithInterest > expectedDebt ? debtWithInterest - expectedDebt : expectedDebt - debtWithInterest;

        assertEq(deviation, 0, "Interest calculation should match exactly");
    }

    // Test: WBTC + ETH + USDC (all three decimals: 8, 18, 6)
    function test_TripleAssetInterestCalculation() public {
        // Create position
        uint256 positionId = _createPosition(alice, address(wethInstance), false);

        // Supply WETH (5 ETH)
        uint256 ethAmount = 5 ether;
        vm.deal(alice, ethAmount);
        vm.startPrank(alice);
        wethInstance.deposit{value: ethAmount}();
        wethInstance.approve(address(LendefiInstance), ethAmount);
        LendefiInstance.supplyCollateral(address(wethInstance), ethAmount, positionId);
        vm.stopPrank();

        // Supply WBTC Cross Token (1 BTC)
        uint256 btcAmount = 1e8;
        wbtcCrossToken.mint(alice, btcAmount);
        vm.startPrank(alice);
        wbtcCrossToken.approve(address(LendefiInstance), btcAmount);
        LendefiInstance.supplyCollateral(address(wbtcCrossToken), btcAmount, positionId);
        vm.stopPrank();

        // Supply USDC (20,000 USDC)
        uint256 usdcAmount = 20_000e6;
        usdcInstance.mint(alice, usdcAmount);
        vm.startPrank(alice);
        usdcInstance.approve(address(LendefiInstance), usdcAmount);
        LendefiInstance.supplyCollateral(address(usdcInstance), usdcAmount, positionId);
        vm.stopPrank();

        // Calculate credit limit
        uint256 creditLimit = LendefiInstance.calculateCreditLimit(alice, positionId);

        // Borrow 95% of the credit limit
        uint256 borrowAmount = (creditLimit * 95) / 100;
        _borrowFromPosition(alice, positionId, borrowAmount);

        // Move forward in time (120 days)
        vm.warp(block.timestamp + 120 days);

        // Get highest tier
        IPROTOCOL.CollateralTier highestTier = LendefiInstance.getHighestTier(alice, positionId);
        assertEq(uint256(highestTier), uint256(IPROTOCOL.CollateralTier.CROSS_A), "Highest tier should be CROSS_A");

        // Get position data
        IPROTOCOL.UserPosition memory position = LendefiInstance.getUserPosition(alice, positionId);

        // Calculate debt with interest
        uint256 debtWithInterest = LendefiInstance.calculateDebtWithInterest(alice, positionId);

        // Calculate expected debt
        uint256 tierRate = LendefiInstance.getBorrowRate(highestTier);
        uint256 timeElapsed = block.timestamp - position.lastInterestAccrual;
        uint256 annualRateRay = LendefiInstance.annualRateToRay(tierRate);
        uint256 expectedDebt = LendefiInstance.accrueInterest(position.debtAmount, annualRateRay, timeElapsed);

        // Check deviation
        uint256 deviation =
            debtWithInterest > expectedDebt ? debtWithInterest - expectedDebt : expectedDebt - debtWithInterest;

        // Allow small tolerance for rounding
        uint256 maxAcceptableDeviation = position.debtAmount / 10000; // 0.01% tolerance
        assertTrue(deviation <= maxAcceptableDeviation, "Interest calculation deviation too high");
    }
}
