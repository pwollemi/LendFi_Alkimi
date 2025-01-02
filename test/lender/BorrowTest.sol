// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../BasicDeploy.sol";
import {console2} from "forge-std/console2.sol";
import {IPROTOCOL} from "../../contracts/interfaces/IProtocol.sol";
import {RWAPriceConsumerV3} from "../../contracts/mock/RWAOracle.sol";
import {WETHPriceConsumerV3} from "../../contracts/mock/WETHOracle.sol";
import {MockRWA} from "../../contracts/mock/MockRWA.sol";
import {Lendefi} from "../../contracts/lender/Lendefi.sol";

contract BorrowTest is BasicDeploy {
    // Events to verify
    event Borrow(address indexed user, uint256 indexed positionId, uint256 amount);

    uint256 constant WAD = 1e18;
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
            800,
            850,
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
            650,
            750,
            1_000_000 ether,
            IPROTOCOL.CollateralTier.ISOLATED,
            100_000e6 // Isolation debt cap of 100,000 USDC
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

        // Set asset prices
        wethOracleInstance.setPrice(2500e8); // $2500 per ETH
        rwaOracleInstance.setPrice(1000e8); // $1000 per RWA token
    }

    // Helper function to setup a position with collateral
    function _setupPosition(address user, address collateralAsset, uint256 collateralAmount, bool isIsolated)
        internal
        returns (uint256)
    {
        // Give user ETH if needed
        if (collateralAsset == address(wethInstance)) {
            vm.deal(user, collateralAmount);
        }

        vm.startPrank(user);

        // Mint collateral tokens
        if (collateralAsset == address(wethInstance)) {
            wethInstance.deposit{value: collateralAmount}();
        } else if (collateralAsset == address(rwaToken)) {
            rwaToken.mint(user, collateralAmount);
        } else {
            // Handle any other token (like crossBToken)
            MockRWA(collateralAsset).mint(user, collateralAmount);
        }

        // Create position
        LendefiInstance.createPosition(collateralAsset, isIsolated);
        uint256 positionId = LendefiInstance.getUserPositionsCount(user) - 1;

        // Supply collateral
        IERC20(collateralAsset).approve(address(LendefiInstance), collateralAmount);
        LendefiInstance.supplyCollateral(collateralAsset, collateralAmount, positionId);

        vm.stopPrank();
        return positionId;
    }

    // Test 1: Basic borrow with non-isolated position
    function test_BasicBorrow() public {
        uint256 collateralAmount = 10 ether; // 10 ETH worth $25,000
        uint256 borrowAmount = 10_000e6; // $10,000 USDC

        // Setup position with collateral
        uint256 positionId = _setupPosition(bob, address(wethInstance), collateralAmount, false);

        uint256 initialTotalBorrow = LendefiInstance.totalBorrow();
        uint256 bobInitialBalance = usdcInstance.balanceOf(bob);

        vm.startPrank(bob);

        // Check credit limit before borrowing
        uint256 creditLimit = LendefiInstance.calculateCreditLimit(bob, positionId);
        console2.log("Credit limit (USDC):", creditLimit / 1e6);
        require(creditLimit >= borrowAmount, "Credit limit too low for test");

        // Borrow
        vm.expectEmit(true, true, false, true);
        emit Borrow(bob, positionId, borrowAmount);
        LendefiInstance.borrow(positionId, borrowAmount);
        vm.stopPrank();

        // Verify state changes
        uint256 finalTotalBorrow = LendefiInstance.totalBorrow();
        uint256 bobFinalBalance = usdcInstance.balanceOf(bob);
        IPROTOCOL.UserPosition memory position = LendefiInstance.getUserPosition(bob, positionId);
        uint256 positionDebt = position.debtAmount;

        assertEq(finalTotalBorrow, initialTotalBorrow + borrowAmount, "Total borrow should increase");
        assertEq(bobFinalBalance, bobInitialBalance + borrowAmount, "User should receive USDC");
        assertEq(positionDebt, borrowAmount, "Position debt should be updated");

        // Verify interest accrual timestamp
        // IPROTOCOL.UserPosition memory position = LendefiInstance.getUserPosition(bob, positionId);
        assertEq(position.lastInterestAccrual, block.timestamp, "Interest accrual timestamp should be updated");
    }

    // Test 2: Borrow with isolated position
    function test_IsolatedBorrow() public {
        uint256 collateralAmount = 100 ether; // 100 RWA tokens worth $100,000
        uint256 borrowAmount = 50_000e6; // $50,000 USDC

        // Setup isolated position with RWA token
        uint256 positionId = _setupPosition(bob, address(rwaToken), collateralAmount, true);

        uint256 initialTotalBorrow = LendefiInstance.totalBorrow();
        uint256 bobInitialBalance = usdcInstance.balanceOf(bob);

        vm.startPrank(bob);

        // Check credit limit before borrowing
        uint256 creditLimit = LendefiInstance.calculateCreditLimit(bob, positionId);
        console2.log("Isolated position credit limit (USDC):", creditLimit / 1e6);
        require(creditLimit >= borrowAmount, "Credit limit too low for test");

        // Borrow
        vm.expectEmit(true, true, false, true);
        emit Borrow(bob, positionId, borrowAmount);
        LendefiInstance.borrow(positionId, borrowAmount);
        vm.stopPrank();

        // Verify state changes
        uint256 finalTotalBorrow = LendefiInstance.totalBorrow();
        uint256 bobFinalBalance = usdcInstance.balanceOf(bob);
        IPROTOCOL.UserPosition memory position = LendefiInstance.getUserPosition(bob, positionId);
        uint256 positionDebt = position.debtAmount;

        assertEq(finalTotalBorrow, initialTotalBorrow + borrowAmount, "Total borrow should increase");
        assertEq(bobFinalBalance, bobInitialBalance + borrowAmount, "User should receive USDC");
        assertEq(positionDebt, borrowAmount, "Position debt should be updated");

        // Verify the position is still in isolation mode
        address[] memory positionAssets = LendefiInstance.getPositionCollateralAssets(bob, positionId);
        assertTrue(position.isIsolated, "Position should remain isolated");
        assertEq(positionAssets[0], address(rwaToken), "Isolated asset should be unchanged");
    }

    // Test 3: Borrow fails with invalid position ID
    function test_BorrowInvalidPosition() public {
        uint256 invalidPositionId = 999;
        uint256 borrowAmount = 10_000e6;

        vm.startPrank(bob);
        vm.expectRevert(abi.encodeWithSelector(IPROTOCOL.InvalidPosition.selector, bob, invalidPositionId));
        LendefiInstance.borrow(invalidPositionId, borrowAmount);
        vm.stopPrank();
    }

    // Test 4: Borrow fails when protocol paused
    function test_BorrowWhenPaused() public {
        uint256 collateralAmount = 10 ether;
        uint256 borrowAmount = 10_000e6;

        // Setup position
        uint256 positionId = _setupPosition(bob, address(wethInstance), collateralAmount, false);

        // Pause protocol
        vm.startPrank(guardian);
        LendefiInstance.pause();
        vm.stopPrank();

        // Attempt to borrow
        vm.startPrank(bob);
        bytes memory expError = abi.encodeWithSignature("EnforcedPause()");
        vm.expectRevert(expError);
        LendefiInstance.borrow(positionId, borrowAmount);
        vm.stopPrank();
    }

    // Test 5: Borrow fails when exceeding credit limit
    function test_BorrowExceedsCreditLimit() public {
        uint256 collateralAmount = 10 ether; // 10 ETH worth $25,000

        // Setup position
        uint256 positionId = _setupPosition(bob, address(wethInstance), collateralAmount, false);

        vm.startPrank(bob);

        // Get credit limit
        uint256 creditLimit = LendefiInstance.calculateCreditLimit(bob, positionId);
        uint256 excessiveAmount = creditLimit + 1e6; // Exceed by 1 USDC

        // Attempt to borrow more than credit limit
        vm.expectRevert(abi.encodeWithSelector(IPROTOCOL.ExceedsCreditLimit.selector, excessiveAmount, creditLimit));
        LendefiInstance.borrow(positionId, excessiveAmount);
        vm.stopPrank();
    }

    // Test 6: Borrow fails when insufficient protocol liquidity
    function test_BorrowInsufficientLiquidity() public {
        uint256 collateralAmount = 20 ether; // For Bob

        // Setup position for Bob with enough collateral for 2000+ USDC credit
        uint256 positionId = _setupPosition(bob, address(wethInstance), collateralAmount, false);

        // Verify Bob has enough credit limit for the test
        uint256 bobCreditLimit = LendefiInstance.calculateCreditLimit(bob, positionId);
        console2.log("Bob's credit limit (USDC):", bobCreditLimit / 1e6);
        require(bobCreditLimit >= 2000e6, "Bob's credit limit too low for test");

        // Store initial liquidity
        uint256 totalSuppliedLiquidity = LendefiInstance.totalSuppliedLiquidity();
        console2.log("Total protocol liquidity:", totalSuppliedLiquidity / 1e6);

        // Leave only 1000 USDC in liquidity (less than Bob will try to borrow)
        uint256 initialBorrowAmount = totalSuppliedLiquidity - 1000e6;

        // Create a position for Alice with MUCH more collateral
        uint256 alicePositionId = _setupPosition(alice, address(wethInstance), 500 ether, false);
        uint256 aliceCreditLimit = LendefiInstance.calculateCreditLimit(alice, alicePositionId);
        console2.log("Alice's credit limit (USDC):", aliceCreditLimit / 1e6);

        // Make sure Alice has enough credit to drain liquidity
        if (aliceCreditLimit < initialBorrowAmount) {
            console2.log("Test skipped: Alice's credit limit too low to drain liquidity");
            return;
        }

        // Now borrow as Alice to drain liquidity
        vm.startPrank(alice);
        LendefiInstance.borrow(alicePositionId, initialBorrowAmount);
        vm.stopPrank();

        // Verify there's not enough liquidity left
        uint256 remainingLiquidity = LendefiInstance.totalSuppliedLiquidity() - LendefiInstance.totalBorrow();
        console2.log("Remaining liquidity (USDC):", remainingLiquidity / 1e6);
        require(remainingLiquidity < 2000e6, "Too much liquidity remains");

        // Now try to borrow more than what's available as Bob
        vm.startPrank(bob);
        uint256 borrowAmount = 2000e6;

        vm.expectRevert(
            abi.encodeWithSelector(IPROTOCOL.InsufficientLiquidity.selector, borrowAmount, remainingLiquidity)
        );
        LendefiInstance.borrow(positionId, borrowAmount);
        vm.stopPrank();
    }

    // Test 7: Borrow with isolated position hits isolation debt cap
    function test_BorrowIsolationDebtCap() public {
        uint256 collateralAmount = 200 ether; // Very high collateral to ensure credit limit isn't the constraint

        // Setup isolated position
        uint256 positionId = _setupPosition(bob, address(rwaToken), collateralAmount, true);

        vm.startPrank(bob);

        // Get isolation debt cap from asset config
        IPROTOCOL.Asset memory asset = LendefiInstance.getAssetInfo(address(rwaToken));
        uint256 isolationDebtCap = asset.isolationDebtCap;
        console2.log("Isolation debt cap (USDC):", isolationDebtCap / 1e6);

        // Try to borrow slightly more than the isolation debt cap
        vm.expectRevert(
            abi.encodeWithSelector(
                IPROTOCOL.IsolationDebtCapExceeded.selector, address(rwaToken), isolationDebtCap + 1, isolationDebtCap
            )
        );
        LendefiInstance.borrow(positionId, isolationDebtCap + 1);

        // Borrow exactly at the isolation debt cap
        LendefiInstance.borrow(positionId, isolationDebtCap);

        // Verify borrow succeeded at the cap
        IPROTOCOL.UserPosition memory position = LendefiInstance.getUserPosition(bob, positionId);
        uint256 positionDebt = position.debtAmount;
        assertEq(positionDebt, isolationDebtCap, "Should borrow exactly at the isolation cap");

        vm.stopPrank();
    }

    // Test 8: Borrow with isolated position requires collateral
    function test_BorrowIsolatedNeedsCollateral() public {
        // Create isolated position without supplying collateral
        vm.startPrank(bob);
        rwaToken.mint(bob, 100 ether);
        LendefiInstance.createPosition(address(rwaToken), true);
        uint256 positionId = 0;

        // Try to borrow without collateral
        vm.expectRevert(
            abi.encodeWithSelector(IPROTOCOL.NoIsolatedCollateral.selector, bob, positionId, address(rwaToken))
        );
        LendefiInstance.borrow(positionId, 1000e6);
        vm.stopPrank();

        // Now add collateral and verify borrow works
        vm.startPrank(bob);
        rwaToken.approve(address(LendefiInstance), 1 ether);
        LendefiInstance.supplyCollateral(address(rwaToken), 1 ether, positionId);

        // Should now succeed
        LendefiInstance.borrow(positionId, 100e6); // Small amount
        vm.stopPrank();

        // Verify borrow succeeded
        IPROTOCOL.UserPosition memory position = LendefiInstance.getUserPosition(bob, positionId);
        uint256 positionDebt = position.debtAmount;
        assertEq(positionDebt, 100e6, "Borrow should succeed after adding collateral");
    }

    // Test 9: Multiple borrows against the same position
    function test_MultipleBorrows() public {
        uint256 collateralAmount = 10 ether;

        // Setup position
        uint256 positionId = _setupPosition(bob, address(wethInstance), collateralAmount, false);

        // Get credit limit
        uint256 creditLimit = LendefiInstance.calculateCreditLimit(bob, positionId);
        uint256 borrowPerTx = creditLimit / 4; // Borrow in 4 installments

        vm.startPrank(bob);

        // Borrow multiple times
        for (uint256 i = 0; i < 4; i++) {
            LendefiInstance.borrow(positionId, borrowPerTx);

            // Verify state after each borrow
            IPROTOCOL.UserPosition memory position = LendefiInstance.getUserPosition(bob, positionId);
            uint256 positionDebt = position.debtAmount;
            assertEq(positionDebt, borrowPerTx * (i + 1), "Position debt should accumulate");
        }

        // Try to borrow once more (should fail)
        uint256 currentDebt = LendefiInstance.getPositionDebt(bob, positionId);
        vm.expectRevert(
            abi.encodeWithSelector(IPROTOCOL.ExceedsCreditLimit.selector, currentDebt + borrowPerTx, creditLimit)
        );
        LendefiInstance.borrow(positionId, borrowPerTx);

        vm.stopPrank();
    }

    // Test 10: Borrow from multiple positions by the same user
    function test_BorrowMultiplePositions() public {
        // Setup  positions
        uint256 position1 = _setupPosition(bob, address(wethInstance), 5 ether, false);
        uint256 position2 = _setupPosition(bob, address(wethInstance), 5 ether, false);

        vm.startPrank(bob);

        // Borrow from position 1
        uint256 creditLimit1 = LendefiInstance.calculateCreditLimit(bob, position1);
        uint256 borrow1 = creditLimit1 / 2;
        LendefiInstance.borrow(position1, borrow1);

        // Borrow from position 2
        uint256 creditLimit2 = LendefiInstance.calculateCreditLimit(bob, position2);
        uint256 borrow2 = creditLimit2 / 2;
        LendefiInstance.borrow(position2, borrow2);

        // Get positions using the view function instead of non-existent getPositionDebt
        IPROTOCOL.UserPosition memory position1View = LendefiInstance.getUserPosition(bob, position1);
        IPROTOCOL.UserPosition memory position2View = LendefiInstance.getUserPosition(bob, position2);

        // Verify each position's debt by checking the debtAmount field
        assertEq(position1View.debtAmount, borrow1, "Position 1 debt should match");
        assertEq(position2View.debtAmount, borrow2, "Position 2 debt should match");

        vm.stopPrank();
    }

    // Test 11: Borrow with zero amount (edge case)
    function test_BorrowZeroAmount() public {
        uint256 collateralAmount = 10 ether;

        // Setup position
        uint256 positionId = _setupPosition(bob, address(wethInstance), collateralAmount, false);

        uint256 initialTotalBorrow = LendefiInstance.totalBorrow();

        vm.startPrank(bob);

        // Borrow zero amount
        vm.expectEmit(true, true, false, true);
        emit Borrow(bob, positionId, 0);
        LendefiInstance.borrow(positionId, 0);

        // Verify no state change
        uint256 finalTotalBorrow = LendefiInstance.totalBorrow();
        IPROTOCOL.UserPosition memory position = LendefiInstance.getUserPosition(bob, positionId);
        uint256 positionDebt = position.debtAmount;

        assertEq(finalTotalBorrow, initialTotalBorrow, "Total borrow should not change");
        assertEq(positionDebt, 0, "Position debt should remain zero");

        vm.stopPrank();
    }

    // Test 12a: Borrow with ISOLATED tier
    function test_BorrowIsolatedTier() public {
        // Configure tier rates
        vm.startPrank(address(timelockInstance));

        // Set base rate and isolated tier rate
        LendefiInstance.updateBaseBorrowRate(0.01e6); // 1% base rate
        LendefiInstance.updateTierParameters(
            IPROTOCOL.CollateralTier.ISOLATED,
            0.25e6, // 25% for isolated assets - maximum allowed
            0.1e6 // 10% liquidation bonus
        );
        vm.stopPrank();

        // Create utilization
        uint256 setupPositionId = _setupPosition(charlie, address(wethInstance), 100 ether, false);
        vm.startPrank(charlie);
        LendefiInstance.borrow(setupPositionId, 100_000e6);
        vm.stopPrank();

        // Setup isolated position
        uint256 isolatedPosition = _setupPosition(bob, address(rwaToken), 10 ether, true);

        vm.startPrank(bob);

        // Small borrow amount
        uint256 borrowAmount = 10e6; // 10 USDC

        // Check credit limit
        uint256 creditLimit = LendefiInstance.calculateCreditLimit(bob, isolatedPosition);
        require(creditLimit >= borrowAmount, "Credit limit too low for test");

        // Get isolated rate
        uint256 isolatedRate = LendefiInstance.getBorrowRate(IPROTOCOL.CollateralTier.ISOLATED);
        console2.log("ISOLATED tier rate (%):", isolatedRate * 100 / 1e6);

        // Borrow
        LendefiInstance.borrow(isolatedPosition, borrowAmount);

        // Fast forward 1 year
        vm.warp(block.timestamp + 365 days);

        // Check accrued interest
        uint256 isolatedDebt = LendefiInstance.calculateDebtWithInterest(bob, isolatedPosition);
        console2.log("ISOLATED debt after 1 year:", isolatedDebt);

        // Verify interest is greater than principal
        assertTrue(isolatedDebt > borrowAmount, "ISOLATED should accrue interest");

        vm.stopPrank();
    }

    // Test 12b: Borrow with CROSS_B tier
    function test_BorrowCrossBTier() public {
        // Create token with CROSS_B tier
        MockRWA crossBToken = new MockRWA("Cross B Token", "CROSSB");
        RWAPriceConsumerV3 crossBOracleInstance = new RWAPriceConsumerV3();
        crossBOracleInstance.setPrice(500e8); // $500 per token

        // Configure tier rates
        vm.startPrank(address(timelockInstance));

        // Set base rate and Cross B tier rate
        LendefiInstance.updateBaseBorrowRate(0.01e6); // 1% base rate
        LendefiInstance.updateTierParameters(
            IPROTOCOL.CollateralTier.CROSS_B,
            0.15e6, // 15% for CROSS_B tier
            0.09e6 // 9% liquidation bonus
        );

        // Configure token as CROSS_B tier
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

        // Create utilization
        uint256 setupPositionId = _setupPosition(charlie, address(wethInstance), 100 ether, false);
        vm.startPrank(charlie);
        LendefiInstance.borrow(setupPositionId, 100_000e6);
        vm.stopPrank();

        // Setup cross B position
        uint256 crossBPosition = _setupPosition(bob, address(crossBToken), 10 ether, false);

        vm.startPrank(bob);

        // Small borrow amount
        uint256 borrowAmount = 10e6; // 10 USDC

        // Check credit limit
        uint256 creditLimit = LendefiInstance.calculateCreditLimit(bob, crossBPosition);
        require(creditLimit >= borrowAmount, "Credit limit too low for test");

        // Get cross B rate
        uint256 crossBRate = LendefiInstance.getBorrowRate(IPROTOCOL.CollateralTier.CROSS_B);
        console2.log("CROSS_B tier rate (%):", crossBRate * 100 / 1e6);

        // Borrow
        LendefiInstance.borrow(crossBPosition, borrowAmount);

        // Fast forward 1 year
        vm.warp(block.timestamp + 365 days);

        // Check accrued interest
        uint256 crossBDebt = LendefiInstance.calculateDebtWithInterest(bob, crossBPosition);
        console2.log("CROSS_B debt after 1 year:", crossBDebt);

        // Verify interest is greater than principal
        assertTrue(crossBDebt > borrowAmount, "CROSS_B should accrue interest");

        vm.stopPrank();
    }

    // Test 12c: Borrow with CROSS_A tier
    function test_BorrowCrossATier() public {
        // Configure tier rates
        vm.startPrank(address(timelockInstance));

        // Set base rate and Cross A tier rate
        LendefiInstance.updateBaseBorrowRate(0.01e6); // 1% base rate
        LendefiInstance.updateTierParameters(
            IPROTOCOL.CollateralTier.CROSS_A,
            0.05e6, // 5% for CROSS_A tier
            0.08e6 // 8% liquidation bonus
        );
        vm.stopPrank();

        // Create utilization
        uint256 setupPositionId = _setupPosition(charlie, address(wethInstance), 100 ether, false);
        vm.startPrank(charlie);
        LendefiInstance.borrow(setupPositionId, 100_000e6);
        vm.stopPrank();

        // Setup cross A position with WETH (which is already set as CROSS_A in setup)
        uint256 crossAPosition = _setupPosition(bob, address(wethInstance), 5 ether, false);

        vm.startPrank(bob);

        // Small borrow amount
        uint256 borrowAmount = 10e6; // 10 USDC

        // Check credit limit
        uint256 creditLimit = LendefiInstance.calculateCreditLimit(bob, crossAPosition);
        require(creditLimit >= borrowAmount, "Credit limit too low for test");

        // Get cross A rate
        uint256 crossARate = LendefiInstance.getBorrowRate(IPROTOCOL.CollateralTier.CROSS_A);
        console2.log("CROSS_A tier rate (%):", crossARate * 100 / 1e6);

        // Borrow
        LendefiInstance.borrow(crossAPosition, borrowAmount);

        // Fast forward 1 year
        vm.warp(block.timestamp + 365 days);

        // Check accrued interest
        uint256 crossADebt = LendefiInstance.calculateDebtWithInterest(bob, crossAPosition);
        console2.log("CROSS_A debt after 1 year:", crossADebt);

        // Verify interest is greater than principal
        assertTrue(crossADebt > borrowAmount, "CROSS_A should accrue interest");

        vm.stopPrank();
    }

    // Fuzz test 1: Borrow different amounts up to credit limit
    function testFuzz_BorrowAmounts(uint256 borrowPct) public {
        // Constrain inputs to reasonable ranges
        borrowPct = bound(borrowPct, 1, 99); // 1-99% of credit limit

        uint256 collateralAmount = 10 ether;

        // Setup position
        uint256 positionId = _setupPosition(bob, address(wethInstance), collateralAmount, false);

        vm.startPrank(bob);

        // Get credit limit
        uint256 creditLimit = LendefiInstance.calculateCreditLimit(bob, positionId);
        uint256 borrowAmount = (creditLimit * borrowPct) / 100;

        // Ensure minimum meaningful amount
        borrowAmount = borrowAmount > 100 ? borrowAmount : 100;

        // Borrow scaled amount
        LendefiInstance.borrow(positionId, borrowAmount);

        // Verify state
        IPROTOCOL.UserPosition memory position = LendefiInstance.getUserPosition(bob, positionId);
        uint256 positionDebt = position.debtAmount;
        assertEq(positionDebt, borrowAmount, "Position debt should match borrow amount");

        vm.stopPrank();
    }

    // Fuzz test 2: Multiple borrow transactions
    function testFuzz_MultipleBorrows(uint256 numBorrows, uint256 initialBorrowPct) public {
        // Constrain inputs to reasonable ranges
        numBorrows = bound(numBorrows, 1, 10); // 1-10 borrow transactions
        initialBorrowPct = bound(initialBorrowPct, 10, 70); // Initial borrow 10-70% of credit limit

        uint256 collateralAmount = 10 ether;

        // Setup position
        uint256 positionId = _setupPosition(bob, address(wethInstance), collateralAmount, false);

        vm.startPrank(bob);

        // Get credit limit
        uint256 creditLimit = LendefiInstance.calculateCreditLimit(bob, positionId);
        uint256 initialBorrow = (creditLimit * initialBorrowPct) / 100;

        // Initial borrow
        LendefiInstance.borrow(positionId, initialBorrow);

        // Track total borrowed
        uint256 totalBorrowed = initialBorrow;

        // Multiple additional borrows
        for (uint256 i = 1; i < numBorrows; i++) {
            // Calculate remaining credit
            uint256 remainingCredit = creditLimit - totalBorrowed;
            if (remainingCredit == 0) break;

            // Borrow a decreasing portion of remaining credit
            uint256 nextBorrow = remainingCredit / (numBorrows - i + 1);
            if (nextBorrow == 0) break;

            LendefiInstance.borrow(positionId, nextBorrow);
            totalBorrowed += nextBorrow;
        }

        // Verify total borrowed is within credit limit
        uint256 finalDebt = LendefiInstance.getPositionDebt(bob, positionId);
        assertEq(finalDebt, totalBorrowed, "Final debt should equal total borrowed");
        assertTrue(finalDebt <= creditLimit, "Should not exceed credit limit");

        vm.stopPrank();
    }

    // Fuzz test 3: Borrow with varying collateral amounts
    function testFuzz_CollateralAmount(uint256 collateralEth) public {
        // Constrain inputs to reasonable ranges
        collateralEth = bound(collateralEth, 1, 100); // 1-100 ETH

        uint256 collateralAmount = collateralEth * 1 ether;

        // Setup position
        uint256 positionId = _setupPosition(bob, address(wethInstance), collateralAmount, false);

        vm.startPrank(bob);

        // Get credit limit
        uint256 creditLimit = LendefiInstance.calculateCreditLimit(bob, positionId);
        console2.log(collateralEth, creditLimit / 1e6);

        // Borrow 75% of credit limit
        uint256 borrowAmount = (creditLimit * 75) / 100;

        // Ensure minimum meaningful amount
        borrowAmount = borrowAmount > 100 ? borrowAmount : 100;

        // Borrow
        LendefiInstance.borrow(positionId, borrowAmount);

        // Verify borrowed amount
        IPROTOCOL.UserPosition memory position = LendefiInstance.getUserPosition(bob, positionId);
        uint256 positionDebt = position.debtAmount;
        assertEq(positionDebt, borrowAmount, "Position debt should match borrow amount");

        vm.stopPrank();
    }
}
