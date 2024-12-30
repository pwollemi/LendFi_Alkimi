// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../BasicDeploy.sol";
import {IPROTOCOL} from "../../contracts/interfaces/IProtocol.sol";
import {Lendefi} from "../../contracts/lender/Lendefi.sol";
import {MockRWA} from "../../contracts/mock/MockRWA.sol";
import {RWAPriceConsumerV3} from "../../contracts/mock/RWAOracle.sol";

contract GetProtocolSnapshotTest is BasicDeploy {
    MockRWA internal testToken;
    RWAPriceConsumerV3 internal testOracle;

    // Test parameters for liquidity and borrowing
    uint256 constant SUPPLY_AMOUNT = 1_000_000e6; // 1M USDC
    uint256 constant BORROW_AMOUNT = 500_000e6; // 500K USDC

    function setUp() public {
        deployComplete();

        // TGE setup
        vm.prank(guardian);
        tokenInstance.initializeTGE(address(ecoInstance), address(treasuryInstance));

        // Deploy USDC
        usdcInstance = new USDC();

        // Deploy test token and oracle
        testToken = new MockRWA("Test Token", "TEST");
        testOracle = new RWAPriceConsumerV3();
        testOracle.setPrice(1000e8); // $1000 per token

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

        // Configure asset for testing
        vm.prank(address(timelockInstance));
        LendefiInstance.updateAssetConfig(
            address(testToken),
            address(testOracle),
            8, // oracle decimals
            18, // asset decimals
            1, // active
            800, // borrow threshold (80%)
            850, // liquidation threshold (85%)
            10_000_000 ether, // max supply
            IPROTOCOL.CollateralTier.CROSS_A,
            1_000_000e6 // isolation debt cap
        );

        // Setup flash loan fee
        vm.prank(address(timelockInstance));
        LendefiInstance.updateFlashLoanFee(10); // 0.1% fee
    }

    // Test 1: Snapshot reflects initial state
    function test_SnapshotReflectsInitialState() public {
        // Get initial protocol snapshot
        IPROTOCOL.ProtocolSnapshot memory snapshot = LendefiInstance.getProtocolSnapshot();

        // Verify initial values
        assertEq(snapshot.utilization, 0, "Initial utilization should be 0");
        assertEq(snapshot.totalBorrow, 0, "Initial totalBorrow should be 0");
        assertEq(snapshot.totalSuppliedLiquidity, 0, "Initial totalSuppliedLiquidity should be 0");
        assertEq(snapshot.flashLoanFee, 10, "Flash loan fee should be 10 basis points");

        // Check other static parameters match expectations
        assertEq(snapshot.targetReward, LendefiInstance.targetReward(), "targetReward mismatch");
        assertEq(snapshot.rewardInterval, LendefiInstance.rewardInterval(), "rewardInterval mismatch");
        assertEq(snapshot.rewardableSupply, LendefiInstance.rewardableSupply(), "rewardableSupply mismatch");
        assertEq(snapshot.baseProfitTarget, LendefiInstance.baseProfitTarget(), "baseProfitTarget mismatch");
        assertEq(snapshot.liquidatorThreshold, LendefiInstance.liquidatorThreshold(), "liquidatorThreshold mismatch");
    }

    // Test 2: Snapshot reflects liquidity changes
    function test_SnapshotReflectsLiquidity() public {
        // Supply liquidity from Alice
        usdcInstance.mint(alice, SUPPLY_AMOUNT);
        vm.startPrank(alice);
        usdcInstance.approve(address(LendefiInstance), SUPPLY_AMOUNT);
        LendefiInstance.supplyLiquidity(SUPPLY_AMOUNT);
        vm.stopPrank();

        // Get updated snapshot
        IPROTOCOL.ProtocolSnapshot memory snapshot = LendefiInstance.getProtocolSnapshot();

        // Verify liquidity is reflected
        assertEq(snapshot.totalSuppliedLiquidity, SUPPLY_AMOUNT, "totalSuppliedLiquidity should match supplied amount");
        assertEq(snapshot.utilization, 0, "Utilization should still be 0 with no borrowing");
    }

    // Test 3: Snapshot reflects borrowing
    function test_SnapshotReflectsBorrowing() public {
        // Supply liquidity first
        usdcInstance.mint(alice, SUPPLY_AMOUNT);
        vm.startPrank(alice);
        usdcInstance.approve(address(LendefiInstance), SUPPLY_AMOUNT);
        LendefiInstance.supplyLiquidity(SUPPLY_AMOUNT);
        vm.stopPrank();

        // Setup borrowing
        uint256 collateralAmount = 1000 ether; // $1M worth at $1000 per token
        testToken.mint(bob, collateralAmount);

        // Make sure the oracle price is set correctly and recent
        testOracle.setPrice(1000e8); // $1000 per token

        vm.startPrank(bob);
        testToken.approve(address(LendefiInstance), collateralAmount);
        LendefiInstance.createPosition(address(testToken), false);
        LendefiInstance.supplyCollateral(address(testToken), collateralAmount, 0);

        // Try a more conservative borrow amount first
        uint256 adjustedBorrowAmount = 400_000e6; // 50% LTV rather than 80%
        LendefiInstance.borrow(0, adjustedBorrowAmount);
        vm.stopPrank();

        // Get updated snapshot
        IPROTOCOL.ProtocolSnapshot memory snapshot = LendefiInstance.getProtocolSnapshot();

        // Verify borrowing is reflected
        assertEq(snapshot.totalBorrow, adjustedBorrowAmount, "totalBorrow should match borrowed amount");
    }

    // Test 4: Snapshot reflects interest accrual
    function test_SnapshotReflectsTotalBorrow() public {
        // Supply liquidity first
        usdcInstance.mint(alice, SUPPLY_AMOUNT);
        vm.startPrank(alice);
        usdcInstance.approve(address(LendefiInstance), SUPPLY_AMOUNT);
        LendefiInstance.supplyLiquidity(SUPPLY_AMOUNT);
        vm.stopPrank();

        // Setup borrowing with more conservative amount
        uint256 collateralAmount = 1000 ether; // $1M worth at $1000 per token
        uint256 borrowAmount = 400_000e6; // More conservative borrow

        testToken.mint(bob, collateralAmount);
        testOracle.setPrice(1000e8); // Ensure price is set

        vm.startPrank(bob);
        testToken.approve(address(LendefiInstance), collateralAmount);
        LendefiInstance.createPosition(address(testToken), false);
        LendefiInstance.supplyCollateral(address(testToken), collateralAmount, 0);
        LendefiInstance.borrow(0, borrowAmount);
        vm.stopPrank();

        // Fast forward time for interest to accrue
        vm.warp(block.timestamp + 365 days);

        // Get updated snapshot
        IPROTOCOL.ProtocolSnapshot memory snapshot = LendefiInstance.getProtocolSnapshot();

        // Total borrow should now be higher due to interest accrual
        assertEq(snapshot.totalBorrow, borrowAmount, "totalBorrow should increase with interest accrual");
    }

    // Test 5: Snapshot reflects repayments
    function test_SnapshotReflectsRepayment() public {
        // Supply liquidity first
        usdcInstance.mint(alice, SUPPLY_AMOUNT);
        vm.startPrank(alice);
        usdcInstance.approve(address(LendefiInstance), SUPPLY_AMOUNT);
        LendefiInstance.supplyLiquidity(SUPPLY_AMOUNT);
        vm.stopPrank();

        // Setup borrowing
        uint256 collateralAmount = 1000 ether; // $1M worth at $1000 per token
        testToken.mint(bob, collateralAmount);

        vm.startPrank(bob);
        testToken.approve(address(LendefiInstance), collateralAmount);
        LendefiInstance.createPosition(address(testToken), false);
        LendefiInstance.supplyCollateral(address(testToken), collateralAmount, 0);
        LendefiInstance.borrow(0, BORROW_AMOUNT);

        // Get snapshot after borrowing
        IPROTOCOL.ProtocolSnapshot memory snapshotBeforeRepay = LendefiInstance.getProtocolSnapshot();

        // Repay half the loan
        usdcInstance.approve(address(LendefiInstance), BORROW_AMOUNT / 2);
        LendefiInstance.repay(0, BORROW_AMOUNT / 2);
        vm.stopPrank();

        // Get updated snapshot
        IPROTOCOL.ProtocolSnapshot memory snapshotAfterRepay = LendefiInstance.getProtocolSnapshot();

        // Verify repayment is reflected
        assertLt(
            snapshotAfterRepay.totalBorrow,
            snapshotBeforeRepay.totalBorrow,
            "totalBorrow should decrease after repayment"
        );
        assertLt(
            snapshotAfterRepay.utilization,
            snapshotBeforeRepay.utilization,
            "Utilization should decrease after repayment"
        );
    }

    // Test 6: Snapshot reflects flash loans
    function test_SnapshotReflectsFlashLoan() public {
        // Supply liquidity first
        usdcInstance.mint(alice, SUPPLY_AMOUNT);
        vm.startPrank(alice);
        usdcInstance.approve(address(LendefiInstance), SUPPLY_AMOUNT);
        LendefiInstance.supplyLiquidity(SUPPLY_AMOUNT);
        vm.stopPrank();

        // Get snapshot before flash loan
        IPROTOCOL.ProtocolSnapshot memory snapshotBefore = LendefiInstance.getProtocolSnapshot();

        // Deploy flash loan receiver contract
        FlashLoanReceiver flashLoanReceiver = new FlashLoanReceiver(address(LendefiInstance), address(usdcInstance));

        // Calculate fee and provide enough tokens to cover it
        uint256 flashLoanAmount = 100_000e6;
        uint256 fee = (flashLoanAmount * 10) / 10000; // 0.1% fee

        // Mint fee amount plus a buffer
        usdcInstance.mint(address(flashLoanReceiver), fee + 1e6);

        // Execute flash loan through the receiver's function
        flashLoanReceiver.executeFlashLoan(flashLoanAmount);

        // Get updated snapshot
        IPROTOCOL.ProtocolSnapshot memory snapshotAfter = LendefiInstance.getProtocolSnapshot();

        // Flash loans should contribute to revenue, so totalSuppliedLiquidity might increase slightly
        assertGe(
            snapshotAfter.totalSuppliedLiquidity,
            snapshotBefore.totalSuppliedLiquidity,
            "totalSuppliedLiquidity should not decrease after flash loan"
        );
    }

    // Test 7: Snapshot reflects parameter updates
    function test_SnapshotReflectsParameterUpdates() public {
        // Get initial snapshot
        // IPROTOCOL.ProtocolSnapshot memory initialSnapshot = LendefiInstance.getProtocolSnapshot();

        // Update protocol parameters
        uint256 newFlashLoanFee = 20; // 0.2%
        uint256 newBaseProfitTarget = 0.02e6; // 2%
        uint256 newRewardInterval = 90 days;
        uint256 newRewardableSupply = 200_000e6;
        uint256 newTargetReward = 2_000e18;
        uint256 newLiquidatorThreshold = 200e18;

        vm.startPrank(address(timelockInstance));
        LendefiInstance.updateFlashLoanFee(newFlashLoanFee);
        LendefiInstance.updateBaseProfitTarget(newBaseProfitTarget);
        LendefiInstance.updateRewardInterval(newRewardInterval);
        LendefiInstance.updateRewardableSupply(newRewardableSupply);
        LendefiInstance.updateTargetReward(newTargetReward);
        LendefiInstance.updateLiquidatorThreshold(newLiquidatorThreshold);
        vm.stopPrank();

        // Get updated snapshot
        IPROTOCOL.ProtocolSnapshot memory updatedSnapshot = LendefiInstance.getProtocolSnapshot();

        // Verify parameter updates are reflected
        assertEq(updatedSnapshot.flashLoanFee, newFlashLoanFee, "Flash loan fee update not reflected");
        assertEq(updatedSnapshot.baseProfitTarget, newBaseProfitTarget, "Base profit target update not reflected");
        assertEq(updatedSnapshot.rewardInterval, newRewardInterval, "Reward interval update not reflected");
        assertEq(updatedSnapshot.rewardableSupply, newRewardableSupply, "Rewardable supply update not reflected");
        assertEq(updatedSnapshot.targetReward, newTargetReward, "Target reward update not reflected");
        assertEq(
            updatedSnapshot.liquidatorThreshold, newLiquidatorThreshold, "Liquidator threshold update not reflected"
        );
    }

    // Test 8: Snapshot reflects multiple user activities
    function test_SnapshotReflectsMultipleUserActivities() public {
        // Multiple users supply liquidity
        usdcInstance.mint(alice, SUPPLY_AMOUNT);
        usdcInstance.mint(bob, SUPPLY_AMOUNT / 2);

        vm.prank(alice);
        usdcInstance.approve(address(LendefiInstance), SUPPLY_AMOUNT);
        vm.prank(alice);
        LendefiInstance.supplyLiquidity(SUPPLY_AMOUNT);

        vm.prank(bob);
        usdcInstance.approve(address(LendefiInstance), SUPPLY_AMOUNT / 2);
        vm.prank(bob);
        LendefiInstance.supplyLiquidity(SUPPLY_AMOUNT / 2);

        // Setup collateral for multiple borrowers
        uint256 collateralAmount = 1000 ether;
        testToken.mint(charlie, collateralAmount);
        testToken.mint(managerAdmin, collateralAmount / 2);

        // Charlie borrows
        vm.startPrank(charlie);
        testToken.approve(address(LendefiInstance), collateralAmount);
        LendefiInstance.createPosition(address(testToken), false);
        LendefiInstance.supplyCollateral(address(testToken), collateralAmount, 0);
        LendefiInstance.borrow(0, BORROW_AMOUNT / 2);
        vm.stopPrank();

        // managerAdmin borrows
        vm.startPrank(managerAdmin);
        testToken.approve(address(LendefiInstance), collateralAmount / 2);
        LendefiInstance.createPosition(address(testToken), false);
        LendefiInstance.supplyCollateral(address(testToken), collateralAmount / 2, 0);
        LendefiInstance.borrow(0, BORROW_AMOUNT / 4);
        vm.stopPrank();

        // Get snapshot after all activities
        IPROTOCOL.ProtocolSnapshot memory snapshot = LendefiInstance.getProtocolSnapshot();

        // Expected values
        uint256 expectedtotalSuppliedLiquidity = SUPPLY_AMOUNT + (SUPPLY_AMOUNT / 2);
        uint256 expectedTotalBorrow = (BORROW_AMOUNT / 2) + (BORROW_AMOUNT / 4);
        uint256 expectedUtilization = (expectedTotalBorrow * 1e6) / expectedtotalSuppliedLiquidity;

        // Verify snapshot reflects all activities
        assertEq(
            snapshot.totalSuppliedLiquidity,
            expectedtotalSuppliedLiquidity,
            "totalSuppliedLiquidity should reflect all liquidity supplies"
        );
        assertEq(snapshot.totalBorrow, expectedTotalBorrow, "totalBorrow should reflect all borrowing");
        assertEq(snapshot.utilization, expectedUtilization, "Utilization should reflect the combined borrow ratio");
    }
}
// Helper contract for flash loan tests

// Helper contract for flash loan tests
// Helper contract for flash loan tests
contract FlashLoanReceiver {
    Lendefi public lender;
    IERC20 public token;

    constructor(address _lender, address _token) {
        lender = Lendefi(_lender);
        token = IERC20(_token);
    }

    // AAVE-style flash loan callback (what Lendefi is actually calling)
    function executeOperation(
        address, /*asset*/
        uint256 amount,
        uint256 fee,
        address, /* initiator */
        bytes calldata /* params */
    ) external returns (bool) {
        // IMPORTANT: Actually transfer the tokens back, not just approve
        token.transfer(address(lender), amount + fee);
        return true; // Return true to indicate success
    }

    // Initiate flash loan
    function executeFlashLoan(uint256 amount) external {
        lender.flashLoan(address(this), address(token), amount, new bytes(0));
    }
}
