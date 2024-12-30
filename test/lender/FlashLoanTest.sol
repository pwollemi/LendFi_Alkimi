// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../BasicDeploy.sol";
import {console2} from "forge-std/console2.sol";
import {IPROTOCOL} from "../../contracts/interfaces/IProtocol.sol";
import {IFlashLoanReceiver} from "../../contracts/interfaces/IFlashLoanReceiver.sol";
import {Lendefi} from "../../contracts/lender/Lendefi.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20 as TH} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract FlashLoanTest is BasicDeploy {
    // Events to verify
    event FlashLoan(address indexed initiator, address indexed receiver, address token, uint256 amount, uint256 fee);
    event UpdateFlashLoanFee(uint256 newFee);

    MockFlashLoanReceiver internal flashLoanReceiver;

    function setUp() public {
        deployComplete();
        usdcInstance = new USDC();

        // TGE setup
        vm.prank(guardian);
        tokenInstance.initializeTGE(address(ecoInstance), address(treasuryInstance));

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

        // Set up flash loan fee
        vm.prank(address(timelockInstance));
        LendefiInstance.updateFlashLoanFee(9); // 9 basis points = 0.09%

        // Deploy flash loan receiver
        flashLoanReceiver = new MockFlashLoanReceiver();

        // Setup liquidity
        _setupLiquidity();
    }

    function _setupLiquidity() internal {
        // Provide liquidity to the protocol
        usdcInstance.mint(alice, 1_000_000e6);
        vm.startPrank(alice);
        usdcInstance.approve(address(LendefiInstance), 1_000_000e6);
        LendefiInstance.supplyLiquidity(1_000_000e6);
        vm.stopPrank();
    }

    // Test successful flash loan
    function test_SuccessfulFlashLoan() public {
        uint256 flashLoanAmount = 100_000e6;
        uint256 flashLoanFee = (flashLoanAmount * 9) / 10000; // 9 bps fee

        // Fund the receiver to repay loan + fee
        usdcInstance.mint(address(this), flashLoanFee);
        usdcInstance.approve(address(flashLoanReceiver), flashLoanFee);
        flashLoanReceiver.fundReceiver(address(usdcInstance), flashLoanFee);

        // Check initial balances
        uint256 initialReceiverBalance = usdcInstance.balanceOf(address(flashLoanReceiver));
        uint256 initialProtocolBalance = usdcInstance.balanceOf(address(LendefiInstance));
        uint256 initialTotalFlashLoanFees = LendefiInstance.totalFlashLoanFees();

        // Expect the FlashLoan event
        vm.expectEmit(true, true, true, true);
        emit FlashLoan(address(this), address(flashLoanReceiver), address(usdcInstance), flashLoanAmount, flashLoanFee);

        // Execute flash loan
        LendefiInstance.flashLoan(address(flashLoanReceiver), address(usdcInstance), flashLoanAmount, "");

        // Verify final balances
        uint256 finalReceiverBalance = usdcInstance.balanceOf(address(flashLoanReceiver));
        uint256 finalProtocolBalance = usdcInstance.balanceOf(address(LendefiInstance));
        uint256 finalTotalFlashLoanFees = LendefiInstance.totalFlashLoanFees();

        assertEq(finalReceiverBalance, initialReceiverBalance - flashLoanFee, "Receiver should pay the fee");
        assertEq(finalProtocolBalance, initialProtocolBalance + flashLoanFee, "Protocol should receive the fee");
        assertEq(finalTotalFlashLoanFees, initialTotalFlashLoanFees + flashLoanFee, "Total fees should increase");
    }

    // Test flash loan when receiver doesn't return funds
    // Test flash loan when receiver doesn't return funds
    function test_FlashLoanWithoutFundReturn() public {
        uint256 flashLoanAmount = 100_000e6;

        // Calculate expected values for the error
        uint256 availableLiquidity = usdcInstance.balanceOf(address(LendefiInstance));
        uint256 fee = (flashLoanAmount * LendefiInstance.flashLoanFee()) / 10000;
        uint256 requiredBalance = availableLiquidity + fee;

        // When funds aren't returned, the balance decreases by the flash loan amount
        uint256 expectedBalanceAfterLoan = availableLiquidity - flashLoanAmount;

        // Configure receiver to not repay
        flashLoanReceiver.setShouldRepay(false);

        // Expect revert with FlashLoanFundsNotReturned error
        vm.expectRevert(
            abi.encodeWithSelector(
                Lendefi.FlashLoanFundsNotReturned.selector, requiredBalance, expectedBalanceAfterLoan
            )
        );

        // Attempt flash loan
        LendefiInstance.flashLoan(address(flashLoanReceiver), address(usdcInstance), flashLoanAmount, "");
    }

    // Test flash loan with non-USDC token
    function test_FlashLoanWithNonUSDCToken() public {
        // Create a mock token
        address mockToken = address(100);

        // Expect revert with OnlyUsdcSupported error
        vm.expectRevert(abi.encodeWithSelector(Lendefi.OnlyUsdcSupported.selector, mockToken));

        // Attempt flash loan with non-USDC token
        LendefiInstance.flashLoan(address(flashLoanReceiver), mockToken, 100e6, "");
    }

    // Test updating flash loan fee beyond max allowed
    function test_UpdateFlashLoanFeeBeyondMax() public {
        uint256 newFee = 101; // 1.01% (beyond max 1%)

        vm.startPrank(address(timelockInstance));

        // Expect revert with FeeTooHigh error
        vm.expectRevert(abi.encodeWithSelector(Lendefi.FeeTooHigh.selector, newFee, 100));

        // Attempt to update fee beyond max
        LendefiInstance.updateFlashLoanFee(newFee);
        vm.stopPrank();
    }

    // Test flash loan with insufficient liquidity
    function test_FlashLoanWithInsufficientLiquidity() public {
        uint256 totalLiquidity = usdcInstance.balanceOf(address(LendefiInstance));
        uint256 flashLoanAmount = totalLiquidity + 1e6; // More than available

        // Expect revert with InsufficientFlashLoanLiquidity error
        vm.expectRevert(
            abi.encodeWithSelector(
                Lendefi.InsufficientFlashLoanLiquidity.selector, address(usdcInstance), flashLoanAmount, totalLiquidity
            )
        );

        // Attempt flash loan with too much amount
        LendefiInstance.flashLoan(address(flashLoanReceiver), address(usdcInstance), flashLoanAmount, "");
    }

    // Test flash loan when receiver fails to execute operation
    function test_FlashLoanWithFailedOperation() public {
        uint256 flashLoanAmount = 100_000e6;

        // Configure receiver to fail operation
        flashLoanReceiver.setShouldFail(true);

        // Expect revert with FlashLoanFailed error
        vm.expectRevert(abi.encodeWithSelector(Lendefi.FlashLoanFailed.selector));

        // Attempt flash loan
        LendefiInstance.flashLoan(address(flashLoanReceiver), address(usdcInstance), flashLoanAmount, "");
    }

    // Test updating flash loan fee
    function test_UpdateFlashLoanFee() public {
        uint256 newFee = 15; // 0.15%

        vm.startPrank(address(timelockInstance));

        // Expect the UpdateFlashLoanFee event
        vm.expectEmit(true, false, false, true);
        emit UpdateFlashLoanFee(newFee);

        // Update fee
        LendefiInstance.updateFlashLoanFee(newFee);
        vm.stopPrank();

        // Verify fee was updated
        assertEq(LendefiInstance.flashLoanFee(), newFee, "Flash loan fee should be updated");

        // Test flash loan with new fee
        uint256 flashLoanAmount = 100_000e6;
        uint256 flashLoanFee = (flashLoanAmount * newFee) / 10000;

        // Fund the receiver
        usdcInstance.mint(address(this), flashLoanFee);
        usdcInstance.approve(address(flashLoanReceiver), flashLoanFee);
        flashLoanReceiver.fundReceiver(address(usdcInstance), flashLoanFee);

        // Execute flash loan with new fee
        LendefiInstance.flashLoan(address(flashLoanReceiver), address(usdcInstance), flashLoanAmount, "");
    }

    // Test updating flash loan fee with non-manager
    function test_UpdateFlashLoanFeeWithNonManager() public {
        uint256 newFee = 15; // 0.15%

        vm.startPrank(bob);

        // Expect revert with AccessControl error
        bytes memory expectedError =
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", bob, keccak256("MANAGER_ROLE"));
        vm.expectRevert(expectedError);

        // Attempt to update fee as non-manager
        LendefiInstance.updateFlashLoanFee(newFee);
        vm.stopPrank();
    }

    // Test flash loan when protocol is paused
    function test_FlashLoanWhenPaused() public {
        uint256 flashLoanAmount = 100_000e6;

        // Pause the protocol
        vm.prank(guardian);
        LendefiInstance.pause();

        // Expect revert with EnforcedPause error
        bytes memory expectedError = abi.encodeWithSignature("EnforcedPause()");
        vm.expectRevert(expectedError);

        // Attempt flash loan while paused
        LendefiInstance.flashLoan(address(flashLoanReceiver), address(usdcInstance), flashLoanAmount, "");
    }

    // Test multiple flash loans to verify tracking of fees
    function test_MultipleFlashLoans() public {
        uint256 flashLoanAmount = 50_000e6;
        uint256 flashLoanFee = (flashLoanAmount * 9) / 10000; // 9 bps fee
        uint256 totalFee = flashLoanFee * 3; // For 3 flash loans

        // Fund the receiver
        usdcInstance.mint(address(this), totalFee);
        usdcInstance.approve(address(flashLoanReceiver), totalFee);
        flashLoanReceiver.fundReceiver(address(usdcInstance), totalFee);

        uint256 initialTotalFees = LendefiInstance.totalFlashLoanFees();

        // Execute 3 flash loans
        for (uint256 i = 0; i < 3; i++) {
            LendefiInstance.flashLoan(address(flashLoanReceiver), address(usdcInstance), flashLoanAmount, "");
        }

        // Verify total fees accumulated
        uint256 finalTotalFees = LendefiInstance.totalFlashLoanFees();
        assertEq(finalTotalFees, initialTotalFees + totalFee, "Total fees should accumulate correctly");
    }

    // Fuzz test for different flash loan amounts
    function testFuzz_FlashLoanWithVaryingAmounts(uint256 amount) public {
        // Bound the amount to reasonable values (100 to 500,000 USDC)
        amount = bound(amount, 100e6, 500_000e6);

        // Skip if amount is too large for available liquidity
        uint256 availableLiquidity = usdcInstance.balanceOf(address(LendefiInstance));
        vm.assume(amount <= availableLiquidity);

        uint256 flashLoanFee = (amount * LendefiInstance.flashLoanFee()) / 10000;

        // Fund the receiver
        usdcInstance.mint(address(this), flashLoanFee);
        usdcInstance.approve(address(flashLoanReceiver), flashLoanFee);
        flashLoanReceiver.fundReceiver(address(usdcInstance), flashLoanFee);

        uint256 initialTotalFees = LendefiInstance.totalFlashLoanFees();

        // Execute flash loan with fuzzed amount
        LendefiInstance.flashLoan(address(flashLoanReceiver), address(usdcInstance), amount, "");

        // Verify fee calculation and tracking
        uint256 finalTotalFees = LendefiInstance.totalFlashLoanFees();
        assertEq(finalTotalFees, initialTotalFees + flashLoanFee, "Fees should be calculated correctly");
    }
}

// Mock Flash Loan Receiver Contract
contract MockFlashLoanReceiver is IFlashLoanReceiver {
    using TH for IERC20;

    bool public shouldRepay;
    bool public shouldFail;

    constructor() {
        shouldRepay = true;
        shouldFail = false;
    }

    function executeOperation(
        address token,
        uint256 amount,
        uint256 fee,
        address, /* initiator */
        bytes calldata /* params */
    ) external override returns (bool) {
        if (shouldFail) {
            return false;
        }

        if (shouldRepay) {
            // We need to transfer the funds back, not just approve
            // Approving doesn't automatically transfer tokens
            IERC20 tokenInstance = IERC20(token);
            TH.safeTransfer(tokenInstance, msg.sender, amount + fee);
        }

        return true;
    }

    function setShouldRepay(bool _shouldRepay) external {
        shouldRepay = _shouldRepay;
    }

    function setShouldFail(bool _shouldFail) external {
        shouldFail = _shouldFail;
    }

    function fundReceiver(address token, uint256 amount) external {
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
    }
}
