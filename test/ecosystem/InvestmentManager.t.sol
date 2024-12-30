// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

import "../BasicDeploy.sol"; // solhint-disable-line
// import {console2} from "forge-std/console2.sol";
import {InvestmentManager} from "../../contracts/ecosystem/InvestmentManager.sol";
import {IINVMANAGER} from "../../contracts/interfaces/IInvestmentManager.sol";
import {InvestorVesting} from "../../contracts/ecosystem/InvestorVesting.sol";

contract InvestmentManagerTest is BasicDeploy {
    // Constants
    address private constant ADMIN = address(0x1);
    address private constant MANAGER = address(0x2);
    address private constant TREASURY = address(0x3);
    address private constant TIMELOCK = address(0x4);

    uint256 private constant MIN_DURATION = 5 days;
    uint256 private constant MAX_DURATION = 90 days;
    uint256 private constant TEST_SUPPLY = 1_000_000e18;
    uint256 private constant INVESTMENT_AMOUNT = 5 ether;
    uint256 private constant TOKEN_ALLOCATION = 100e18;

    address private constant INVESTOR = address(0x123);
    address private constant NON_PAUSER = address(0x456);

    InvestmentManager private manager;

    event Received(address indexed src, uint256 amount);
    event Paused(address account);
    event Unpaused(address account);
    event Invest(uint32 indexed roundId, address indexed investor, uint256 amount);
    event CreateRound(uint32 indexed roundId, uint64 start, uint64 duration, uint256 ethTarget, uint256 tokenAlloc);
    event RoundStatusUpdated(uint32 indexed roundId, IINVMANAGER.RoundStatus status);
    event CancelInvestment(uint32 indexed roundId, address indexed investor, uint256 amount);
    event InvestorAllocated(uint32 indexed roundId, address indexed investor, uint256 ethAmount, uint256 tokenAmount);
    event InvestorAllocationRemoved(
        uint32 indexed roundId, address indexed investor, uint256 ethAmount, uint256 tokenAmount
    );
    event RoundCancelled(uint32 indexed roundId);
    event RefundClaimed(uint32 indexed roundId, address indexed investor, uint256 amount);
    event DeployVesting(uint32 indexed roundId, address indexed investor, address vestingContract, uint256 amount);
    event RoundFinalized(
        address indexed caller, uint32 indexed roundId, uint256 totalEthRaised, uint256 totalTokensDistributed
    );

    receive() external payable {
        if (msg.sender == address(manager)) {
            uint32 roundId = manager.getCurrentRound();
            bytes memory expError = abi.encodeWithSignature("ReentrancyGuardReentrantCall()");
            vm.prank(managerAdmin);
            vm.expectRevert(expError);
            manager.cancelInvestment(roundId);
        }
    }

    function setUp() public {
        deployComplete();
        _setupToken();
        _deployManager();
    }
    // ============ Reetrancy Test ============

    function testRevertReentrancyOnCancelInvestment() public {
        address investor = address(this);
        vm.deal(investor, INVESTMENT_AMOUNT);
        uint32 roundId = _setupActiveRound();
        vm.prank(guardian);
        manager.addInvestorAllocation(roundId, investor, INVESTMENT_AMOUNT, 100e18);

        vm.prank(investor);
        manager.investEther{value: INVESTMENT_AMOUNT}(roundId);

        vm.expectEmit(true, true, false, true);
        emit CancelInvestment(roundId, investor, INVESTMENT_AMOUNT);

        uint256 balanceBefore = investor.balance;

        vm.prank(investor);
        manager.cancelInvestment(roundId);

        assertEq(investor.balance, balanceBefore + INVESTMENT_AMOUNT);
        (,, uint256 amount,) = manager.getInvestorDetails(roundId, investor);
        assertEq(amount, 0);
    }
    // ============ Basic Functionality Tests ============

    function testPauseByPauser() public {
        vm.startPrank(guardian);

        // Expect Paused event
        vm.expectEmit(true, false, false, true);
        emit Paused(guardian);

        manager.pause();
        assertTrue(manager.paused());
        vm.stopPrank();
    }

    function testUnpauseByPauser() public {
        vm.startPrank(guardian);
        manager.pause();
        assertTrue(manager.paused());

        // Expect Unpaused event
        vm.expectEmit(true, false, false, true);
        emit Unpaused(guardian);

        manager.unpause();
        assertFalse(manager.paused());
        vm.stopPrank();
    }

    function testRevertPauseByNonPauser() public {
        vm.prank(INVESTOR);
        bytes memory expError =
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", INVESTOR, PAUSER_ROLE);
        vm.expectRevert(expError);
        manager.pause();
    }

    function testRevertUnpauseByNonPauser() public {
        vm.prank(guardian);
        manager.pause();

        vm.prank(INVESTOR);
        bytes memory expError =
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", INVESTOR, PAUSER_ROLE);
        vm.expectRevert(expError);
        manager.unpause();
    }

    function testInvestmentWhilePaused() public {
        // Setup round and allocation
        uint32 roundId = _setupActiveRound();
        vm.prank(guardian);
        manager.addInvestorAllocation(roundId, INVESTOR, INVESTMENT_AMOUNT, 100e18);

        // Pause contract
        vm.prank(guardian);
        manager.pause();

        // Try to invest while paused
        vm.deal(INVESTOR, INVESTMENT_AMOUNT);

        bytes memory expError = abi.encodeWithSignature("EnforcedPause()");
        vm.prank(INVESTOR);
        vm.expectRevert(expError); // contract paused
        manager.investEther{value: INVESTMENT_AMOUNT}(roundId);
    }

    function testInvestmentAfterUnpause() public {
        // Setup round and allocation
        uint32 roundId = _setupActiveRound();
        vm.prank(guardian);
        manager.addInvestorAllocation(roundId, INVESTOR, INVESTMENT_AMOUNT, 100e18);

        // Pause and then unpause
        vm.startPrank(guardian);
        manager.pause();
        manager.unpause();
        vm.stopPrank();

        // Investment should succeed
        vm.deal(INVESTOR, INVESTMENT_AMOUNT);
        vm.prank(INVESTOR);
        manager.investEther{value: INVESTMENT_AMOUNT}(roundId);

        // Verify investment
        (,, uint256 invested,) = manager.getInvestorDetails(roundId, INVESTOR);
        assertEq(invested, INVESTMENT_AMOUNT);
    }

    function testCreateRound() public {
        uint64 start = uint64(block.timestamp + 1 days);
        uint64 duration = uint64(7 days);
        uint256 ethTarget = 100 ether;
        uint256 tokenAlloc = 1000e18;
        uint32 roundId = _createTestRound(start, duration, ethTarget, tokenAlloc);

        IINVMANAGER.Round memory round = manager.getRoundInfo(roundId);
        assertEq(round.etherTarget, ethTarget);
        assertEq(round.tokenAllocation, tokenAlloc);
        assertEq(round.startTime, start);
        assertEq(round.endTime, start + duration);
        assertEq(round.etherInvested, 0);
        assertEq(round.tokenDistributed, 0);
        assertEq(round.participants, 0);
        assertEq(uint8(round.status), uint8(IINVMANAGER.RoundStatus.PENDING));
    }

    // ============ Access Control Tests ============

    function testOnlyManagerCanCreateRound() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                bytes4(keccak256("AccessControlUnauthorizedAccount(address,bytes32)")), address(this), DAO_ROLE
            )
        );
        manager.createRound(uint64(block.timestamp + 1 days), uint64(7 days), 100 ether, 1000e18, 365 days, 730 days);
    }

    // ============ Input Validation Tests ============

    function testCannotCreateRoundWithPastStartTime() public {
        vm.prank(address(timelockInstance));
        vm.expectRevert("INVALID_START_TIME");
        manager.createRound(uint64(block.timestamp - 1), uint64(7 days), 100 ether, 1000e18, 365 days, 730 days);
    }

    function testCannotCreateRoundWithShortDuration() public {
        vm.prank(address(timelockInstance));
        vm.expectRevert("INVALID_DURATION");
        manager.createRound(
            uint64(block.timestamp + 1 days), uint64(MIN_DURATION - 1), 100 ether, 1000e18, 365 days, 730 days
        );
    }

    function testCannotCreateRoundWithZeroTarget() public {
        vm.prank(address(timelockInstance));
        vm.expectRevert("INVALID_ETH_TARGET");
        manager.createRound(uint64(block.timestamp + 1 days), uint64(7 days), 0, 1000e18, 365 days, 730 days);
    }

    function testCannotCreateRoundWithZeroAllocation() public {
        vm.prank(address(timelockInstance));
        vm.expectRevert("INVALID_TOKEN_ALLOCATION");
        manager.createRound(uint64(block.timestamp + 1 days), uint64(7 days), 100 ether, 0, 365 days, 730 days);
    }

    function testCannotCreateRoundWithInsufficientSupply() public {
        vm.prank(address(timelockInstance));
        vm.expectRevert("INSUFFICIENT_SUPPLY");
        manager.createRound(
            uint64(block.timestamp + 1 days), uint64(7 days), 100 ether, TEST_SUPPLY + 1, 365 days, 730 days
        );
    }

    // ============ Fuzz Tests ============

    function testFuzz_CreateRound(uint64 startOffset, uint64 duration, uint256 ethTarget, uint256 tokenAlloc) public {
        // Bound inputs to reasonable ranges
        startOffset = uint64(bound(startOffset, 1 hours, 365 days));
        duration = uint64(bound(duration, MIN_DURATION, MAX_DURATION));
        ethTarget = bound(ethTarget, 0.1 ether, 100_000 ether);
        tokenAlloc = bound(tokenAlloc, 1e18, TEST_SUPPLY);

        uint64 start = uint64(block.timestamp) + startOffset;

        vm.startPrank(address(timelockInstance));
        treasuryInstance.release(address(tokenInstance), address(manager), tokenAlloc);
        manager.createRound(start, duration, ethTarget, tokenAlloc, 365 days, 730 days);

        IINVMANAGER.Round memory round = manager.getRoundInfo(0);

        assertEq(round.etherTarget, ethTarget);
        assertEq(round.tokenAllocation, tokenAlloc);
        assertEq(round.startTime, start);
        assertEq(round.endTime, start + duration);
        assertEq(uint8(round.status), uint8(IINVMANAGER.RoundStatus.PENDING));
    }

    // ============ Property-Based Tests ============

    function testProperty_RoundInvariants(uint64 startOffset, uint64 duration, uint256 ethTarget, uint256 tokenAlloc)
        public
    {
        // Bound inputs
        startOffset = uint64(bound(startOffset, 1 hours, 365 days));
        duration = uint64(bound(duration, MIN_DURATION, MAX_DURATION));
        ethTarget = bound(ethTarget, 0.1 ether, 100_000 ether);
        tokenAlloc = bound(tokenAlloc, 1e18, TEST_SUPPLY);

        uint64 start = uint64(block.timestamp) + startOffset;

        vm.startPrank(address(timelockInstance));
        treasuryInstance.release(address(tokenInstance), address(manager), tokenAlloc);
        manager.createRound(start, duration, ethTarget, tokenAlloc, 365 days, 730 days);

        IINVMANAGER.Round memory round = manager.getRoundInfo(0);

        // Property: Round should always have valid timestamps
        assertTrue(round.endTime > round.startTime);
        assertTrue(round.startTime >= block.timestamp);

        // Property: Round should have non-zero targets
        assertTrue(round.etherTarget > 0);
        assertTrue(round.tokenAllocation > 0);

        // Property: Initial state should be empty
        assertEq(round.etherInvested, 0);
        assertEq(round.tokenDistributed, 0);
        assertEq(round.participants, 0);

        // Property: Status should be PENDING
        assertEq(uint8(round.status), uint8(IINVMANAGER.RoundStatus.PENDING));

        // Property: Supply tracking should be correct
        assertTrue(manager.supply() >= tokenAlloc);
        assertTrue(tokenInstance.balanceOf(address(manager)) >= manager.supply());
    }

    // ============ Multiple Rounds Tests ============

    function testCreateMultipleRounds() public {
        uint64 baseStart = uint64(block.timestamp + 1 days);
        vm.startPrank(address(timelockInstance));

        for (uint32 i = 0; i < 5; i++) {
            treasuryInstance.release(address(tokenInstance), address(manager), 1000 ether);
            manager.createRound(baseStart + uint64(i * 30 days), uint64(7 days), 100 ether, 1000e18, 365 days, 730 days);

            IINVMANAGER.Round memory round = manager.getRoundInfo(i);
            assertEq(uint8(round.status), uint8(IINVMANAGER.RoundStatus.PENDING));
        }
    }

    // ============ Activation Tests ============

    function testActivateRound() public {
        uint32 roundId = _createTestRound(uint64(block.timestamp + 1 days), 7 days, 100 ether, 1000e18);

        vm.warp(block.timestamp + 1 days);

        vm.expectEmit(true, false, false, true);
        emit RoundStatusUpdated(roundId, IINVMANAGER.RoundStatus.ACTIVE);

        vm.prank(guardian);
        manager.activateRound(roundId);

        IINVMANAGER.Round memory round = manager.getRoundInfo(roundId);
        assertEq(uint8(round.status), uint8(IINVMANAGER.RoundStatus.ACTIVE));
    }

    function testOnlyManagerCanActivate() public {
        uint32 roundId = _createTestRound(uint64(block.timestamp + 1 days), 7 days, 100 ether, 1000e18);

        vm.warp(block.timestamp + 1 days);

        vm.expectRevert(
            abi.encodeWithSelector(
                bytes4(keccak256("AccessControlUnauthorizedAccount(address,bytes32)")), address(this), MANAGER_ROLE
            )
        );
        manager.activateRound(roundId);
    }

    function testCannotActivateNonPendingRound() public {
        uint32 roundId = _createTestRound(uint64(block.timestamp + 1 days), 7 days, 100 ether, 1000e18);

        vm.warp(block.timestamp + 1 days);

        vm.startPrank(guardian);
        manager.activateRound(roundId);

        vm.expectRevert("INVALID_ROUND_STATUS");
        manager.activateRound(roundId);
        vm.stopPrank();
    }

    function testCannotActivateBeforeStartTime() public {
        uint32 roundId = _createTestRound(uint64(block.timestamp + 1 days), 7 days, 100 ether, 1000e18);

        vm.prank(guardian);
        vm.expectRevert("ROUND_START_TIME_NOT_REACHED");
        manager.activateRound(roundId);
    }

    function testCannotActivateAfterEndTime() public {
        uint32 roundId = _createTestRound(uint64(block.timestamp + 1 days), 7 days, 100 ether, 1000e18);

        vm.warp(block.timestamp + 9 days);

        vm.prank(guardian);
        vm.expectRevert("ROUND_END_TIME_REACHED");
        manager.activateRound(roundId);
    }

    // ============ Fuzz Tests ============

    function testFuzz_ActivateRound(
        uint64 startOffset,
        uint64 duration,
        uint256 ethTarget,
        uint256 tokenAlloc,
        uint64 activationDelay
    ) public {
        startOffset = uint64(bound(startOffset, 1 hours, 30 days));
        duration = uint64(bound(duration, MIN_DURATION, 90 days));
        ethTarget = bound(ethTarget, 0.1 ether, 10000 ether);
        tokenAlloc = bound(tokenAlloc, 1e18, TEST_SUPPLY);
        activationDelay = uint64(bound(activationDelay, 0, duration));

        uint32 roundId = _createTestRound(uint64(block.timestamp + startOffset), duration, ethTarget, tokenAlloc);

        vm.warp(block.timestamp + startOffset + activationDelay);

        if (activationDelay < duration) {
            vm.prank(guardian);
            manager.activateRound(roundId);

            IINVMANAGER.Round memory round = manager.getRoundInfo(roundId);
            assertEq(uint8(round.status), uint8(IINVMANAGER.RoundStatus.ACTIVE));
        } else {
            vm.expectRevert("ROUND_END_TIME_REACHED");
            vm.prank(guardian);
            manager.activateRound(roundId);
        }
    }

    // ============ Property-Based Tests ============

    function testProperty_ActivationTimeWindow(uint64 activationTime) public {
        uint64 startTime = uint64(block.timestamp + 1 days);
        uint64 duration = 7 days;
        uint32 roundId = _createTestRound(startTime, duration, 100 ether, 1000e18);

        activationTime = uint64(bound(activationTime, block.timestamp, block.timestamp + 30 days));
        vm.warp(activationTime);

        vm.startPrank(guardian);
        if (activationTime >= startTime && activationTime < startTime + duration) {
            manager.activateRound(roundId);
            IINVMANAGER.Round memory round = manager.getRoundInfo(roundId);
            assertEq(uint8(round.status), uint8(IINVMANAGER.RoundStatus.ACTIVE));
        } else if (activationTime < startTime) {
            vm.expectRevert("ROUND_START_TIME_NOT_REACHED");
            manager.activateRound(roundId);
        } else {
            vm.expectRevert("ROUND_END_TIME_REACHED");
            manager.activateRound(roundId);
        }
        vm.stopPrank();
    }

    // ============ Add Investor Allocation Tests ============

    function testAddInvestorAllocation() public {
        uint32 roundId = _createTestRound(uint64(block.timestamp + 1 days), 7 days, 100 ether, 1000e18);

        address investor = address(0x123);
        uint256 ethAmount = 10 ether;
        uint256 tokenAmount = 100e18;

        vm.expectEmit(true, true, false, true);
        emit InvestorAllocated(roundId, investor, ethAmount, tokenAmount);

        vm.prank(guardian);
        manager.addInvestorAllocation(roundId, investor, ethAmount, tokenAmount);

        (uint256 allocatedEth, uint256 allocatedTokens,,) = manager.getInvestorDetails(roundId, investor);
        assertEq(allocatedEth, ethAmount);
        assertEq(allocatedTokens, tokenAmount);
    }

    function testOnlyAllocatorCanAddAllocation() public {
        uint32 roundId = _createTestRound(uint64(block.timestamp + 1 days), 7 days, 100 ether, 1000e18);

        vm.expectRevert(
            abi.encodeWithSelector(
                bytes4(keccak256("AccessControlUnauthorizedAccount(address,bytes32)")), address(this), MANAGER_ROLE
            )
        );
        manager.addInvestorAllocation(roundId, address(0x123), 1 ether, 10e18);
    }

    function testCannotAddAllocationToInvalidRound() public {
        uint32 invalidRoundId = 999;

        vm.prank(guardian);
        vm.expectRevert("INVALID_ROUND");
        manager.addInvestorAllocation(invalidRoundId, address(0x123), 1 ether, 10e18);
    }

    function testCannotAddAllocationToCompletedRound() public {
        uint32 roundId = _createTestRound(uint64(block.timestamp + 1 days), 7 days, 100 ether, 1000e18);

        // Activate the round
        vm.warp(block.timestamp + 1 days);
        vm.startPrank(guardian);
        manager.activateRound(roundId);
        manager.addInvestorAllocation(roundId, alice, 100 ether, 10e18);
        vm.stopPrank();
        //complete the round
        vm.deal(alice, 101 ether);
        vm.prank(alice);
        manager.investEther{value: 100 ether}(roundId);

        vm.prank(guardian);
        vm.expectRevert("INVALID_ROUND_STATUS");
        manager.addInvestorAllocation(roundId, address(0x123), 1 ether, 10e18);
    }

    function testCannotAddAllocationWithZeroAddress() public {
        uint32 roundId = _createTestRound(uint64(block.timestamp + 1 days), 7 days, 100 ether, 1000e18);

        vm.prank(guardian);
        vm.expectRevert("INVALID_INVESTOR");
        manager.addInvestorAllocation(roundId, address(0), 1 ether, 10e18);
    }

    function testCannotAddZeroAllocation() public {
        uint32 roundId = _createTestRound(uint64(block.timestamp + 1 days), 7 days, 100 ether, 1000e18);

        vm.startPrank(guardian);
        vm.expectRevert("INVALID_ETH_AMOUNT");
        manager.addInvestorAllocation(roundId, address(0x123), 0, 10e18);

        vm.expectRevert("INVALID_TOKEN_AMOUNT");
        manager.addInvestorAllocation(roundId, address(0x123), 1 ether, 0);
        vm.stopPrank();
    }

    function testCannotExceedRoundAllocation() public {
        uint32 roundId = _createTestRound(uint64(block.timestamp + 1 days), 7 days, 100 ether, 1000e18);

        vm.startPrank(guardian);
        // Try to allocate more than the round's total allocation
        vm.expectRevert("EXCEEDS_ROUND_ALLOCATION");
        manager.addInvestorAllocation(roundId, address(0x123), 101 ether, 1001e18);
        vm.stopPrank();
    }

    function testAddInvestorAllocationRevertsForExistingAllocation() public {
        uint32 roundId = _createTestRound(uint64(block.timestamp + 1 days), 7 days, 100 ether, 1000e18);
        vm.startPrank(guardian);

        // First allocation
        manager.addInvestorAllocation(roundId, alice, 1 ether, 1000e18);

        // Attempt second allocation
        vm.expectRevert("ALLOCATION_EXISTS");
        manager.addInvestorAllocation(roundId, alice, 2 ether, 2000e18);

        vm.stopPrank();
    }

    // ============ Fuzz Tests ============

    function testFuzz_AddInvestorAllocation(address investor, uint256 ethAmount, uint256 tokenAmount) public {
        // Bound inputs to reasonable ranges and exclude zero address
        vm.assume(investor != address(0));
        ethAmount = bound(ethAmount, 0.1 ether, 100 ether);
        tokenAmount = bound(tokenAmount, 1e18, 1000e18);

        uint32 roundId = _createTestRound(uint64(block.timestamp + 1 days), 7 days, 1000 ether, 10000e18);

        vm.prank(guardian);
        manager.addInvestorAllocation(roundId, investor, ethAmount, tokenAmount);

        (uint256 allocatedEth, uint256 allocatedTokens,,) = manager.getInvestorDetails(roundId, investor);
        assertEq(allocatedEth, ethAmount);
        assertEq(allocatedTokens, tokenAmount);
    }

    // ============ Property-Based Tests ============

    function testProperty_AllocationInvariants(uint256 seed, uint256 numInvestors) public {
        // Bound number of investors to a reasonable range
        numInvestors = bound(numInvestors, 1, 5);

        // Create round with sufficient capacity
        uint32 roundId = _createTestRound(uint64(block.timestamp + 1 days), 7 days, 1000 ether, 10000e18);

        uint256 totalEthAllocated;
        uint256 totalTokensAllocated;

        // Use seed to generate deterministic but pseudo-random values
        uint256 currentSeed = seed;

        vm.startPrank(guardian);
        for (uint256 i = 0; i < numInvestors; i++) {
            // Generate pseudo-random investor address (avoiding address(0))
            address investor = address(uint160(uint256(keccak256(abi.encode(currentSeed, "investor"))) | 0x10));

            // Generate bounded allocation amounts
            uint256 ethAmount = bound(uint256(keccak256(abi.encode(currentSeed, "eth"))), 0.1 ether, 10 ether);
            uint256 tokenAmount = bound(uint256(keccak256(abi.encode(currentSeed, "token"))), 1e18, 100e18);

            // Update seed for next iteration
            currentSeed = uint256(keccak256(abi.encode(currentSeed, "next")));

            // Skip if allocation would exceed round limits
            if (totalEthAllocated + ethAmount > 1000 ether || totalTokensAllocated + tokenAmount > 10000e18) {
                continue;
            }

            // Add allocation
            manager.addInvestorAllocation(roundId, investor, ethAmount, tokenAmount);

            totalEthAllocated += ethAmount;
            totalTokensAllocated += tokenAmount;

            // Verify individual allocation
            (uint256 allocatedEth, uint256 allocatedTokens,,) = manager.getInvestorDetails(roundId, investor);
            assertEq(allocatedEth, ethAmount);
            assertEq(allocatedTokens, tokenAmount);
        }
        vm.stopPrank();

        // Verify round totals and invariants
        IINVMANAGER.Round memory round = manager.getRoundInfo(roundId);
        assertTrue(totalEthAllocated <= round.etherTarget);
        assertTrue(totalTokensAllocated <= round.tokenAllocation);
        assertTrue(round.participants <= numInvestors);
        assertEq(uint8(round.status), uint8(IINVMANAGER.RoundStatus.PENDING));
    }

    // ============ Invest Ether Tests ============

    function testInvestEther() public {
        address investor = address(0x123);
        vm.deal(investor, 100 ether);

        uint32 roundId = _createTestRound(uint64(block.timestamp + 1 days), 7 days, 100 ether, 1000e18);

        // Add allocation
        vm.prank(guardian);
        manager.addInvestorAllocation(roundId, investor, 10 ether, 100e18);

        // Activate round
        vm.warp(block.timestamp + 1 days);
        vm.prank(guardian);
        manager.activateRound(roundId);

        vm.expectEmit(true, true, false, true);
        emit Invest(roundId, investor, 10 ether);

        vm.prank(investor);
        manager.investEther{value: 10 ether}(roundId);

        (uint256 allocatedEth, uint256 allocatedTokens, uint256 invested,) =
            manager.getInvestorDetails(roundId, investor);
        assertEq(allocatedEth, 10 ether);
        assertEq(allocatedTokens, 100e18);
        assertEq(invested, 10 ether);
    }

    function testCannotInvestWithoutAllocation() public {
        address investor = address(0x123);
        vm.deal(investor, 5 ether);

        uint32 roundId = _createTestRound(uint64(block.timestamp + 1 days), 7 days, 100 ether, 1000e18);

        vm.warp(block.timestamp + 1 days);
        vm.prank(guardian);
        manager.activateRound(roundId);

        vm.prank(investor);
        vm.expectRevert("NO_ALLOCATION");
        manager.investEther{value: 1 ether}(roundId);
    }

    function testCannotInvestBeforeActivation() public {
        address investor = address(0x123);
        vm.deal(investor, 5 ether);

        uint32 roundId = _createTestRound(uint64(block.timestamp + 1 days), 7 days, 100 ether, 1000e18);

        vm.prank(guardian);
        manager.addInvestorAllocation(roundId, investor, 10 ether, 100e18);

        vm.warp(block.timestamp + 1 days);

        vm.prank(investor);
        vm.expectRevert("ROUND_NOT_ACTIVE");
        manager.investEther{value: 1 ether}(roundId);
    }

    function testCannotInvestAfterEnd() public {
        address investor = address(0x123);
        vm.deal(investor, 5 ether);

        uint32 roundId = _createTestRound(uint64(block.timestamp + 1 days), 7 days, 100 ether, 1000e18);

        vm.prank(guardian);
        manager.addInvestorAllocation(roundId, investor, 10 ether, 100e18);

        vm.warp(block.timestamp + 1 days);
        vm.prank(guardian);
        manager.activateRound(roundId);

        vm.warp(block.timestamp + 8 days);

        vm.prank(investor);
        vm.expectRevert("ROUND_ENDED");
        manager.investEther{value: 1 ether}(roundId);
    }

    function testCannotExceedInvestmentAllocation() public {
        address investor = address(0x123);
        vm.deal(investor, 15 ether);

        uint32 roundId = _createTestRound(uint64(block.timestamp + 1 days), 7 days, 100 ether, 1000e18);

        vm.prank(guardian);
        manager.addInvestorAllocation(roundId, investor, 10 ether, 100e18);

        vm.warp(block.timestamp + 1 days);
        vm.prank(guardian);
        manager.activateRound(roundId);

        vm.prank(investor);
        vm.expectRevert("AMOUNT_ALLOCATION_MISMATCH");
        manager.investEther{value: 11 ether}(roundId);
    }

    function testInvestEtherRevertsForInvalidRound() public {
        // Setup
        uint64 start = uint64(block.timestamp + 1 days);
        uint64 duration = 30 days;
        uint256 ethTarget = 100 ether;
        uint256 tokenAlloc = 1000 ether;
        uint64 vestingCliff = 90 days;
        uint64 vestingDuration = 365 days;

        vm.startPrank(address(timelockInstance));
        treasuryInstance.release(address(tokenInstance), address(manager), tokenAlloc);
        manager.createRound(start, duration, ethTarget, tokenAlloc, vestingCliff, vestingDuration);
        vm.stopPrank();

        // Test invalid round ID
        vm.deal(alice, 1 ether);
        vm.startPrank(alice);
        vm.expectRevert("INVALID_ROUND");
        manager.investEther{value: 1 ether}(999);
        vm.stopPrank();
    }

    function testFuzz_InvestEther(uint256 investAmount) public {
        address investor = address(0x123);
        vm.deal(investor, 100 ether);

        uint32 roundId = _createTestRound(uint64(block.timestamp + 1 days), 7 days, 100 ether, 1000e18);
        investAmount = bound(investAmount, 0.1 ether, 10 ether);
        vm.prank(guardian);
        manager.addInvestorAllocation(roundId, investor, investAmount, 100e18);

        vm.warp(block.timestamp + 1 days);
        vm.prank(guardian);
        manager.activateRound(roundId);

        if (investAmount <= 10 ether) {
            vm.prank(investor);
            manager.investEther{value: investAmount}(roundId);

            (,, uint256 invested,) = manager.getInvestorDetails(roundId, investor);
            assertEq(invested, investAmount);
        } else {
            vm.prank(investor);
            vm.expectRevert("AMOUNT_ALLOCATION_MISMATCH");
            manager.investEther{value: investAmount}(roundId);
        }
    }

    function testProperty_InvestmentInvariants() public {
        // Setup
        uint32 roundId = _setupActiveRound();
        vm.prank(guardian);
        manager.addInvestorAllocation(roundId, INVESTOR, INVESTMENT_AMOUNT, TOKEN_ALLOCATION);
        vm.deal(INVESTOR, INVESTMENT_AMOUNT);

        // Initial state check
        IINVMANAGER.Round memory roundBefore = manager.getRoundInfo(roundId);
        uint256 investorBalanceBefore = INVESTOR.balance;

        // Make investment
        vm.prank(INVESTOR);
        manager.investEther{value: INVESTMENT_AMOUNT}(roundId);

        // Cancel investment
        vm.prank(INVESTOR);
        manager.cancelInvestment(roundId);

        // Post-state checks
        IINVMANAGER.Round memory roundAfter = manager.getRoundInfo(roundId);
        (,, uint256 invested,) = manager.getInvestorDetails(roundId, INVESTOR);

        // Verify invariants
        assertEq(invested, 0, "Investment position should be zero after cancellation");
        assertEq(roundAfter.etherInvested, 0, "Round ETH total should be zero after cancellation");
        assertEq(roundAfter.participants, 0, "Participant count should be zero after cancellation");
        assertEq(INVESTOR.balance, investorBalanceBefore, "Investor balance should be restored");
        assertEq(roundAfter.tokenDistributed, 0, "No tokens should be distributed");
        assertEq(uint8(roundAfter.status), uint8(roundBefore.status), "Round status should not change");
    }

    // ============ Cancel Investment Tests ============

    function testCancelInvestment() public {
        address investor = address(0x123);
        vm.deal(investor, 10 ether);

        uint32 roundId = _createTestRound(uint64(block.timestamp + 1 days), 7 days, 100 ether, 1000e18);

        // Setup allocation and investment
        vm.prank(guardian);
        manager.addInvestorAllocation(roundId, investor, 10 ether, 100e18);

        vm.warp(block.timestamp + 1 days);
        vm.prank(guardian);
        manager.activateRound(roundId);

        vm.prank(investor);
        manager.investEther{value: 10 ether}(roundId);

        // Test cancellation
        vm.expectEmit(true, true, false, true);
        emit CancelInvestment(roundId, investor, 10 ether);

        uint256 balanceBefore = investor.balance;

        vm.prank(investor);
        manager.cancelInvestment(roundId);

        assertEq(investor.balance, balanceBefore + 10 ether);

        (,, uint256 invested,) = manager.getInvestorDetails(roundId, investor);
        assertEq(invested, 0);
    }

    function testCancelInvestmentRevertsForInvalidRound() public {
        // Setup
        uint64 start = uint64(block.timestamp + 1 days);
        uint64 duration = 30 days;
        uint256 ethTarget = 100 ether;
        uint256 tokenAlloc = 1000 ether;
        uint64 vestingCliff = 90 days;
        uint64 vestingDuration = 365 days;

        vm.startPrank(address(timelockInstance));
        treasuryInstance.release(address(tokenInstance), address(manager), tokenAlloc);
        manager.createRound(start, duration, ethTarget, tokenAlloc, vestingCliff, vestingDuration);
        vm.stopPrank();

        // Test invalid round ID
        vm.expectRevert("INVALID_ROUND");
        manager.cancelInvestment(999);
    }

    function testCannotCancelWithoutInvestment() public {
        address investor = address(0x123);

        uint32 roundId = _setupActiveRound();

        vm.prank(investor);
        vm.expectRevert("NO_INVESTMENT");
        manager.cancelInvestment(roundId);
    }

    function testCannotCancelWhenRoundNotActive() public {
        address investor = address(0x123);
        vm.deal(investor, 10 ether);

        uint32 roundId = _createTestRound(uint64(block.timestamp + 1 days), 7 days, 100 ether, 1000e18);

        vm.prank(guardian);
        manager.addInvestorAllocation(roundId, investor, 10 ether, 100e18);

        vm.warp(block.timestamp + 1 days);
        vm.prank(guardian);
        manager.activateRound(roundId);

        vm.prank(investor);
        manager.investEther{value: 10 ether}(roundId);

        vm.warp(block.timestamp + 8 days);
        vm.prank(guardian);
        manager.cancelRound(roundId);

        vm.prank(investor);
        vm.expectRevert("ROUND_NOT_ACTIVE");
        manager.cancelInvestment(roundId);
    }

    function testFuzz_CancelInvestment(uint256 investAmount) public {
        address investor = address(0x123);
        vm.deal(investor, 100 ether);

        uint32 roundId = _createTestRound(uint64(block.timestamp + 1 days), 7 days, 100 ether, 1000e18);

        investAmount = bound(investAmount, 0.1 ether, 10 ether);
        vm.prank(guardian);
        manager.addInvestorAllocation(roundId, investor, investAmount, 100e18);

        vm.warp(block.timestamp + 1 days);
        vm.prank(guardian);
        manager.activateRound(roundId);

        vm.startPrank(investor);
        manager.investEther{value: investAmount}(roundId);

        uint256 balanceBefore = investor.balance;
        manager.cancelInvestment(roundId);
        vm.stopPrank();

        assertEq(investor.balance, balanceBefore + investAmount);

        (,, uint256 invested,) = manager.getInvestorDetails(roundId, investor);
        assertEq(invested, 0);
    }

    // ============ Finalize Round Tests ============

    function testFinalizeRound() public {
        address investor = address(0x123);
        vm.deal(investor, 10 ether);

        uint32 roundId = _createTestRound(uint64(block.timestamp + 1 days), 7 days, 10 ether, 100e18);

        // Setup and complete round
        vm.prank(guardian);
        manager.addInvestorAllocation(roundId, investor, 10 ether, 100e18);

        vm.warp(block.timestamp + 1 days);
        vm.prank(guardian);
        manager.activateRound(roundId);

        vm.prank(investor);
        manager.investEther{value: 10 ether}(roundId);

        vm.warp(block.timestamp + 8 days);

        uint256 treasuryBalanceBefore = address(treasuryInstance).balance;

        vm.prank(guardian);
        manager.finalizeRound(roundId);

        // Verify round status
        IINVMANAGER.Round memory round = manager.getRoundInfo(roundId);
        assertEq(uint8(round.status), uint8(IINVMANAGER.RoundStatus.FINALIZED));

        // Verify token distribution
        (,, uint256 invested, address vestingContract) = manager.getInvestorDetails(roundId, investor);
        assertNotEq(vestingContract, address(0));
        assertEq(tokenInstance.balanceOf(vestingContract), 100e18);
        assertEq(invested, 10 ether);

        // Verify ETH transfer to treasury
        assertEq(address(treasuryInstance).balance, treasuryBalanceBefore + 10 ether);
    }

    // [Rest of the test functions remain the same, just update any vestingContract checks to use getInvestorDetails]

    function testCannotFinalizeInvalidRound() public {
        vm.prank(guardian);
        vm.expectRevert("INVALID_ROUND");
        manager.finalizeRound(999);
    }

    function testCannotFinalizeNonCompletedRound() public {
        uint32 roundId = _createTestRound(uint64(block.timestamp + 1 days), 7 days, 10 ether, 100e18);

        vm.prank(guardian);
        vm.expectRevert("INVALID_ROUND_STATUS");
        manager.finalizeRound(roundId);
    }

    function testCannotFinalizeTwice() public {
        address investor = address(0x123);
        vm.deal(investor, 10 ether);

        uint32 roundId = _createTestRound(uint64(block.timestamp + 1 days), 7 days, 10 ether, 100e18);

        // Setup and complete round
        vm.prank(guardian);
        manager.addInvestorAllocation(roundId, investor, 10 ether, 100e18);

        vm.warp(block.timestamp + 1 days);
        vm.prank(guardian);
        manager.activateRound(roundId);

        vm.prank(investor);
        manager.investEther{value: 10 ether}(roundId);

        vm.warp(block.timestamp + 8 days);

        vm.startPrank(guardian);
        manager.finalizeRound(roundId);

        vm.expectRevert("INVALID_ROUND_STATUS");
        manager.finalizeRound(roundId);
        vm.stopPrank();
    }

    function testFuzz_FinalizeRound(uint256 ethTarget, uint256 tokenAlloc, uint256 investAmount) public {
        // Bound inputs to reasonable ranges
        ethTarget = bound(ethTarget, 1 ether, 1000 ether);
        tokenAlloc = bound(tokenAlloc, 10e18, 10000e18);
        investAmount = ethTarget;

        address investor = address(0x123);
        vm.deal(investor, ethTarget);

        uint32 roundId = _createTestRound(uint64(block.timestamp + 1 days), 7 days, ethTarget, tokenAlloc);

        vm.prank(guardian);
        manager.addInvestorAllocation(roundId, investor, ethTarget, tokenAlloc);

        vm.warp(block.timestamp + 1 days);
        vm.prank(guardian);
        manager.activateRound(roundId);

        vm.prank(investor);
        manager.investEther{value: investAmount}(roundId);

        vm.warp(block.timestamp + 8 days);

        uint256 treasuryBalanceBefore = address(treasuryInstance).balance;

        vm.prank(guardian);
        manager.finalizeRound(roundId);

        IINVMANAGER.Round memory round = manager.getRoundInfo(roundId);
        assertEq(uint8(round.status), uint8(IINVMANAGER.RoundStatus.FINALIZED));
        assertEq(address(treasuryInstance).balance, treasuryBalanceBefore + investAmount);
    }
    // ============ Cancel Round Tests ============

    function testCancelRound() public {
        uint32 roundId = _createTestRound(uint64(block.timestamp + 1 days), 7 days, 100 ether, 1000e18);

        uint256 supplyBefore = manager.supply();

        vm.expectEmit(true, false, false, false);
        emit RoundStatusUpdated(roundId, IINVMANAGER.RoundStatus.CANCELLED);

        vm.expectEmit(true, false, false, false);
        emit RoundCancelled(roundId);

        vm.prank(guardian);
        manager.cancelRound(roundId);

        IINVMANAGER.Round memory round = manager.getRoundInfo(roundId);
        assertEq(uint8(round.status), uint8(IINVMANAGER.RoundStatus.CANCELLED));
        assertEq(manager.supply(), supplyBefore - 1000e18);
    }

    function testCancelActiveRound() public {
        uint32 roundId = _createTestRound(uint64(block.timestamp + 1 days), 7 days, 100 ether, 1000e18);

        vm.warp(block.timestamp + 1 days);
        vm.prank(guardian);
        manager.activateRound(roundId);

        uint256 supplyBefore = manager.supply();

        vm.prank(guardian);
        manager.cancelRound(roundId);

        IINVMANAGER.Round memory round = manager.getRoundInfo(roundId);
        assertEq(uint8(round.status), uint8(IINVMANAGER.RoundStatus.CANCELLED));
        assertEq(manager.supply(), supplyBefore - 1000e18);
    }

    function testCannotCancelInvalidRound() public {
        vm.prank(guardian);
        vm.expectRevert("INVALID_ROUND");
        manager.cancelRound(999);
    }

    function testOnlyManagerCanCancel() public {
        uint32 roundId = _createTestRound(uint64(block.timestamp + 1 days), 7 days, 100 ether, 1000e18);

        vm.expectRevert(
            abi.encodeWithSelector(
                bytes4(keccak256("AccessControlUnauthorizedAccount(address,bytes32)")), address(this), MANAGER_ROLE
            )
        );
        manager.cancelRound(roundId);
    }

    function testCannotCancelCompletedRound() public {
        uint32 roundId = _createTestRound(uint64(block.timestamp + 1 days), 7 days, 100 ether, 1000e18);

        // Complete the round
        vm.warp(block.timestamp + 1 days);
        vm.prank(guardian);
        manager.activateRound(roundId);

        address investor = address(0x123);
        vm.deal(investor, 100 ether);
        vm.prank(guardian);
        manager.addInvestorAllocation(roundId, investor, 100 ether, 1000e18);

        vm.prank(investor);
        manager.investEther{value: 100 ether}(roundId);

        vm.prank(guardian);
        vm.expectRevert("INVALID_STATUS_TRANSITION");
        manager.cancelRound(roundId);
    }

    function testCannotCancelFinalizedRound() public {
        uint32 roundId = _createTestRound(uint64(block.timestamp + 1 days), 7 days, 100 ether, 1000e18);

        // Complete and finalize the round
        vm.warp(block.timestamp + 1 days);
        vm.prank(guardian);
        manager.activateRound(roundId);

        address investor = address(0x123);
        vm.deal(investor, 100 ether);
        vm.prank(guardian);
        manager.addInvestorAllocation(roundId, investor, 100 ether, 1000e18);

        vm.prank(investor);
        manager.investEther{value: 100 ether}(roundId);

        vm.warp(block.timestamp + 8 days);
        vm.startPrank(guardian);
        manager.finalizeRound(roundId);

        vm.expectRevert("INVALID_STATUS_TRANSITION");
        manager.cancelRound(roundId);
        vm.stopPrank();
    }

    function testCannotCancelCancelledRound() public {
        uint32 roundId = _createTestRound(uint64(block.timestamp + 1 days), 7 days, 100 ether, 1000e18);

        vm.startPrank(guardian);
        manager.cancelRound(roundId);

        vm.expectRevert("INVALID_STATUS_TRANSITION");
        manager.cancelRound(roundId);
        vm.stopPrank();
    }

    function testFuzz_CancelRound(uint256 ethTarget, uint256 tokenAlloc) public {
        ethTarget = bound(ethTarget, 1 ether, 1000 ether);
        tokenAlloc = bound(tokenAlloc, 10e18, 10000e18);

        uint32 roundId = _createTestRound(uint64(block.timestamp + 1 days), 7 days, ethTarget, tokenAlloc);

        uint256 supplyBefore = manager.supply();

        vm.prank(guardian);
        manager.cancelRound(roundId);

        IINVMANAGER.Round memory round = manager.getRoundInfo(roundId);
        assertEq(uint8(round.status), uint8(IINVMANAGER.RoundStatus.CANCELLED));
        assertEq(manager.supply(), supplyBefore - tokenAlloc);
    }

    // ============ Claim Refund Tests ============

    function testClaimRefund() public {
        address investor = address(0x123);
        vm.deal(investor, 10 ether);

        uint32 roundId = _createTestRound(uint64(block.timestamp + 1 days), 7 days, 100 ether, 1000e18);

        // Setup allocation and investment
        vm.prank(guardian);
        manager.addInvestorAllocation(roundId, investor, 10 ether, 100e18);

        vm.warp(block.timestamp + 1 days);
        vm.prank(guardian);
        manager.activateRound(roundId);

        vm.prank(investor);
        manager.investEther{value: 10 ether}(roundId);

        // Cancel round
        vm.prank(guardian);
        manager.cancelRound(roundId);

        // Test refund claim
        uint256 balanceBefore = investor.balance;

        vm.expectEmit(true, true, false, true);
        emit RefundClaimed(roundId, investor, 10 ether);

        vm.prank(investor);
        manager.claimRefund(roundId);

        assertEq(investor.balance, balanceBefore + 10 ether);

        IINVMANAGER.Round memory round = manager.getRoundInfo(roundId);
        assertEq(round.etherInvested, 0);
        assertEq(round.participants, 0);
    }

    function testClaimRefundRevertsForInvalidRound() public {
        // Test invalid round ID
        vm.expectRevert("INVALID_ROUND");
        manager.claimRefund(999);
    }

    function testCannotClaimRefundTwice() public {
        address investor = address(0x123);
        vm.deal(investor, 10 ether);

        uint32 roundId = _createTestRound(uint64(block.timestamp + 1 days), 7 days, 100 ether, 1000e18);

        vm.prank(guardian);
        manager.addInvestorAllocation(roundId, investor, 10 ether, 100e18);

        vm.warp(block.timestamp + 1 days);
        vm.prank(guardian);
        manager.activateRound(roundId);

        vm.prank(investor);
        manager.investEther{value: 10 ether}(roundId);

        vm.prank(guardian);
        manager.cancelRound(roundId);

        vm.startPrank(investor);
        manager.claimRefund(roundId);

        vm.expectRevert("NO_REFUND_AVAILABLE");
        manager.claimRefund(roundId);
        vm.stopPrank();
    }

    function testCannotClaimRefundFromNonCancelledRound() public {
        address investor = address(0x123);
        vm.deal(investor, 10 ether);

        uint32 roundId = _createTestRound(uint64(block.timestamp + 1 days), 7 days, 100 ether, 1000e18);

        vm.prank(guardian);
        manager.addInvestorAllocation(roundId, investor, 10 ether, 100e18);

        vm.warp(block.timestamp + 1 days);
        vm.prank(guardian);
        manager.activateRound(roundId);

        vm.prank(investor);
        manager.investEther{value: 10 ether}(roundId);

        vm.prank(investor);
        vm.expectRevert("ROUND_NOT_CANCELLED");
        manager.claimRefund(roundId);
    }

    function testCannotClaimRefundWithoutInvestment() public {
        address investor = address(0x123);

        uint32 roundId = _createTestRound(uint64(block.timestamp + 1 days), 7 days, 100 ether, 1000e18);

        vm.prank(guardian);
        manager.cancelRound(roundId);

        vm.prank(investor);
        vm.expectRevert("NO_REFUND_AVAILABLE");
        manager.claimRefund(roundId);
    }

    function testFuzz_ClaimRefund(uint256 investAmount) public {
        address investor = address(0x123);
        vm.deal(investor, 100 ether);

        uint32 roundId = _createTestRound(uint64(block.timestamp + 1 days), 7 days, 100 ether, 1000e18);
        // Bound investment amount
        investAmount = bound(investAmount, 0.1 ether, 10 ether);
        vm.prank(guardian);
        manager.addInvestorAllocation(roundId, investor, investAmount, 100e18);

        vm.warp(block.timestamp + 1 days);
        vm.prank(guardian);
        manager.activateRound(roundId);

        vm.prank(investor);
        manager.investEther{value: investAmount}(roundId);

        vm.prank(guardian);
        manager.cancelRound(roundId);

        uint256 balanceBefore = investor.balance;

        vm.prank(investor);
        manager.claimRefund(roundId);

        assertEq(investor.balance, balanceBefore + investAmount);

        IINVMANAGER.Round memory round = manager.getRoundInfo(roundId);
        assertEq(round.etherInvested, 0);
    }

    // ============ Get Refund Amount Tests ============

    function testGetRefundAmount() public {
        address investor = address(0x123);
        vm.deal(investor, 10 ether);

        uint32 roundId = _createTestRound(uint64(block.timestamp + 1 days), 7 days, 100 ether, 1000e18);

        // Setup allocation and investment
        vm.prank(guardian);
        manager.addInvestorAllocation(roundId, investor, 10 ether, 100e18);

        vm.warp(block.timestamp + 1 days);
        vm.prank(guardian);
        manager.activateRound(roundId);

        vm.prank(investor);
        manager.investEther{value: 10 ether}(roundId);

        // Check refund amount before cancellation
        assertEq(manager.getRefundAmount(roundId, investor), 0);

        // Cancel round and check refund amount
        vm.prank(guardian);
        manager.cancelRound(roundId);

        assertEq(manager.getRefundAmount(roundId, investor), 10 ether);
    }

    function testGetRefundAmountAfterClaim() public {
        address investor = address(0x123);
        vm.deal(investor, 10 ether);

        uint32 roundId = _createTestRound(uint64(block.timestamp + 1 days), 7 days, 100 ether, 1000e18);

        vm.prank(guardian);
        manager.addInvestorAllocation(roundId, investor, 10 ether, 100e18);

        vm.warp(block.timestamp + 1 days);
        vm.prank(guardian);
        manager.activateRound(roundId);

        vm.prank(investor);
        manager.investEther{value: 10 ether}(roundId);

        vm.prank(guardian);
        manager.cancelRound(roundId);

        vm.prank(investor);
        manager.claimRefund(roundId);

        assertEq(manager.getRefundAmount(roundId, investor), 0);
    }

    function testGetRefundAmountNonInvestor() public {
        uint32 roundId = _createTestRound(uint64(block.timestamp + 1 days), 7 days, 100 ether, 1000e18);

        vm.prank(guardian);
        manager.cancelRound(roundId);

        assertEq(manager.getRefundAmount(roundId, address(0x123)), 0);
    }

    function testFuzz_GetRefundAmount(uint256 investAmount) public {
        address investor = address(0x123);
        vm.deal(investor, 100 ether);

        uint32 roundId = _createTestRound(uint64(block.timestamp + 1 days), 7 days, 100 ether, 1000e18);
        investAmount = bound(investAmount, 0.1 ether, 10 ether);
        vm.prank(guardian);
        manager.addInvestorAllocation(roundId, investor, investAmount, 100e18);

        vm.warp(block.timestamp + 1 days);
        vm.prank(guardian);
        manager.activateRound(roundId);

        vm.prank(investor);
        manager.investEther{value: investAmount}(roundId);

        vm.prank(guardian);
        manager.cancelRound(roundId);

        assertEq(manager.getRefundAmount(roundId, investor), investAmount);
    }

    // ============ Get Current Round Tests ============

    function testGetCurrentRound() public {
        // Create multiple rounds
        uint32 round0 = _createTestRound(uint64(block.timestamp + 1 days), 7 days, 100 ether, 1000e18);

        uint32 round1 = _createTestRound(uint64(block.timestamp + 1 days), 7 days, 200 ether, 2000e18);

        uint32 round2 = _createTestRound(uint64(block.timestamp + 1 days), 7 days, 300 ether, 3000e18);

        // Initially no active rounds
        assertEq(manager.getCurrentRound(), type(uint32).max);

        // Activate middle round
        vm.warp(block.timestamp + 1 days);
        vm.startPrank(guardian);
        manager.activateRound(round1);

        assertEq(manager.getCurrentRound(), 1);
        manager.activateRound(round0);
        manager.activateRound(round2);
        assertEq(manager.getCurrentRound(), 0);
        vm.stopPrank();
    }

    function testGetCurrentRoundWithMultipleActive() public {
        // Create and activate multiple rounds
        uint32 round0 = _createTestRound(uint64(block.timestamp + 1 days), 7 days, 100 ether, 1000e18);

        uint32 round1 = _createTestRound(uint64(block.timestamp + 2 days), 7 days, 200 ether, 2000e18);

        // Activate both rounds
        vm.warp(block.timestamp + 2 days);
        vm.startPrank(guardian);
        manager.activateRound(round0);
        manager.activateRound(round1);
        vm.stopPrank();

        // Should return first active round
        assertEq(manager.getCurrentRound(), 0);
    }

    function testGetCurrentRoundWithNoRounds() public {
        assertEq(manager.getCurrentRound(), type(uint32).max);
    }

    function testGetCurrentRoundAfterCompletion() public {
        uint32 roundId = _createTestRound(uint64(block.timestamp + 1 days), 7 days, 100 ether, 1000e18);

        // Activate round
        vm.warp(block.timestamp + 1 days);
        vm.startPrank(guardian);
        manager.activateRound(roundId);
        manager.addInvestorAllocation(roundId, alice, 100 ether, 10e18);
        assertEq(manager.getCurrentRound(), 0);
        vm.stopPrank();
        //complete the round
        vm.deal(alice, 101 ether);
        vm.prank(alice);
        manager.investEther{value: 100 ether}(roundId);
        // Check round complete status
        IINVMANAGER.Round memory round = manager.getRoundInfo(roundId);
        assertEq(uint8(round.status), uint8(IINVMANAGER.RoundStatus.COMPLETED));
        // Finalize round
        // vm.warp(block.timestamp + 8 days);
        manager.finalizeRound(roundId);

        // No active rounds after completion
        assertEq(manager.getCurrentRound(), type(uint32).max);
    }

    function testGetCurrentRoundAfterCancellation() public {
        uint32 roundId = _createTestRound(uint64(block.timestamp + 1 days), 7 days, 100 ether, 1000e18);

        // Activate round
        vm.warp(block.timestamp + 1 days);
        vm.prank(guardian);
        manager.activateRound(roundId);

        assertEq(manager.getCurrentRound(), 0);

        // Cancel round
        vm.prank(guardian);
        manager.cancelRound(roundId);

        // No active rounds after cancellation
        assertEq(manager.getCurrentRound(), type(uint32).max);
    }

    // ============ Get Investor Details Tests ============

    function testGetInvestorDetails() public {
        address investor = address(0x123);
        vm.deal(investor, 10 ether);

        uint32 roundId = _createTestRound(
            uint64(block.timestamp + 1 days),
            7 days,
            10 ether, // Set target equal to allocation
            100e18
        );

        // Check initial state
        (uint256 allocatedEth, uint256 allocatedTokens, uint256 invested, address vestingContract) =
            manager.getInvestorDetails(roundId, investor);
        assertEq(allocatedEth, 0);
        assertEq(allocatedTokens, 0);
        assertEq(invested, 0);
        assertEq(vestingContract, address(0));

        // Add allocation
        vm.prank(guardian);
        manager.addInvestorAllocation(roundId, investor, 10 ether, 100e18);

        (allocatedEth, allocatedTokens, invested, vestingContract) = manager.getInvestorDetails(roundId, investor);
        assertEq(allocatedEth, 10 ether);
        assertEq(allocatedTokens, 100e18);
        assertEq(invested, 0);
        assertEq(vestingContract, address(0));

        // Make investment
        vm.warp(block.timestamp + 1 days);
        vm.prank(guardian);
        manager.activateRound(roundId);

        vm.prank(investor);
        manager.investEther{value: 10 ether}(roundId); // Invest full amount to complete round

        (allocatedEth, allocatedTokens, invested, vestingContract) = manager.getInvestorDetails(roundId, investor);
        assertEq(allocatedEth, 10 ether);
        assertEq(allocatedTokens, 100e18);
        assertEq(invested, 10 ether);
        assertEq(vestingContract, address(0));

        // Finalize round
        vm.warp(block.timestamp + 8 days);
        vm.prank(guardian);
        manager.finalizeRound(roundId);

        (allocatedEth, allocatedTokens, invested, vestingContract) = manager.getInvestorDetails(roundId, investor);
        assertEq(allocatedEth, 10 ether);
        assertEq(allocatedTokens, 100e18);
        assertEq(invested, 10 ether);
        assertNotEq(vestingContract, address(0));
    }

    function testGetInvestorDetailsAfterCancellation() public {
        address investor = address(0x123);
        vm.deal(investor, 10 ether);

        uint32 roundId = _createTestRound(uint64(block.timestamp + 1 days), 7 days, 100 ether, 1000e18);

        // Setup and invest
        vm.prank(guardian);
        manager.addInvestorAllocation(roundId, investor, 10 ether, 100e18);

        vm.warp(block.timestamp + 1 days);
        vm.prank(guardian);
        manager.activateRound(roundId);

        vm.prank(investor);
        manager.investEther{value: 10 ether}(roundId);

        // Cancel round
        vm.prank(guardian);
        manager.cancelRound(roundId);

        (uint256 allocatedEth, uint256 allocatedTokens, uint256 invested, address vestingContract) =
            manager.getInvestorDetails(roundId, investor);
        assertEq(allocatedEth, 10 ether);
        assertEq(allocatedTokens, 100e18);
        assertEq(invested, 10 ether);
        assertEq(vestingContract, address(0));

        // Claim refund
        vm.prank(investor);
        manager.claimRefund(roundId);

        (allocatedEth, allocatedTokens, invested, vestingContract) = manager.getInvestorDetails(roundId, investor);
        assertEq(allocatedEth, 10 ether);
        assertEq(allocatedTokens, 100e18);
        assertEq(invested, 0);
        assertEq(vestingContract, address(0));
    }

    function testFuzz_GetInvestorDetails(uint256 ethAllocation, uint256 tokenAllocation, uint256 investAmount) public {
        address investor = address(0x123);

        // Bound inputs
        ethAllocation = 100 ether;
        tokenAllocation = bound(tokenAllocation, 1e18, 1000e18);
        investAmount = bound(investAmount, 0.1 ether, ethAllocation - 1 ether);

        vm.deal(investor, ethAllocation);

        uint32 roundId = _createTestRound(uint64(block.timestamp + 1 days), 7 days, ethAllocation, tokenAllocation);

        vm.prank(guardian);
        manager.addInvestorAllocation(roundId, investor, investAmount, tokenAllocation);

        vm.warp(block.timestamp + 1 days);
        vm.prank(guardian);
        manager.activateRound(roundId);

        vm.prank(investor);
        manager.investEther{value: investAmount}(roundId);

        (uint256 allocatedEth, uint256 allocatedTokens, uint256 invested,) =
            manager.getInvestorDetails(roundId, investor);
        assertEq(allocatedEth, investAmount);
        assertEq(allocatedTokens, tokenAllocation);
        assertEq(invested, investAmount);
    }

    // ============ Get Round Info Tests ============

    function testGetRoundInfo() public {
        uint32 roundId = _createTestRound(uint64(block.timestamp + 1 days), 7 days, 100 ether, 1000e18);

        IINVMANAGER.Round memory round = manager.getRoundInfo(roundId);

        assertEq(round.etherTarget, 100 ether);
        assertEq(round.etherInvested, 0);
        assertEq(round.tokenAllocation, 1000e18);
        assertEq(round.tokenDistributed, 0);
        assertEq(round.startTime, block.timestamp + 1 days);
        assertEq(round.endTime, block.timestamp + 8 days);
        assertEq(round.participants, 0);
        assertEq(uint8(round.status), uint8(IINVMANAGER.RoundStatus.PENDING));
    }

    function testGetRoundInfoNonExistentRound() public {
        vm.expectRevert(stdError.indexOOBError);
        manager.getRoundInfo(999);
    }

    // ============ Get Round Investors Tests ============

    function testGetRoundInvestors() public {
        address[] memory testInvestors = new address[](3);
        testInvestors[0] = address(0x123);
        testInvestors[1] = address(0x456);
        testInvestors[2] = address(0x789);

        uint32 roundId = _createTestRound(uint64(block.timestamp + 1 days), 7 days, 100 ether, 1000e18);

        // Add allocations and investments
        vm.warp(block.timestamp + 1 days);
        vm.startPrank(guardian);
        manager.activateRound(roundId);

        for (uint256 i = 0; i < testInvestors.length; i++) {
            vm.deal(testInvestors[i], 10 ether);
            manager.addInvestorAllocation(roundId, testInvestors[i], 10 ether, 100e18);

            vm.stopPrank();
            vm.prank(testInvestors[i]);
            manager.investEther{value: 10 ether}(roundId);
            vm.startPrank(guardian);
        }
        vm.stopPrank();

        address[] memory roundInvestors = manager.getRoundInvestors(roundId);
        assertEq(roundInvestors.length, testInvestors.length);

        for (uint256 i = 0; i < testInvestors.length; i++) {
            assertEq(roundInvestors[i], testInvestors[i]);
        }
    }

    function testGetRoundInvestorsEmptyRound() public {
        uint32 roundId = _createTestRound(uint64(block.timestamp + 1 days), 7 days, 100 ether, 1000e18);

        address[] memory roundInvestors = manager.getRoundInvestors(roundId);
        assertEq(roundInvestors.length, 0);
    }

    function testGetRoundInvestorsAfterCancellation() public {
        address investor = address(0x123);
        vm.deal(investor, 10 ether);

        uint32 roundId = _createTestRound(uint64(block.timestamp + 1 days), 7 days, 100 ether, 1000e18);

        vm.prank(guardian);
        manager.addInvestorAllocation(roundId, investor, 10 ether, 100e18);

        vm.warp(block.timestamp + 1 days);
        vm.prank(guardian);
        manager.activateRound(roundId);

        vm.prank(investor);
        manager.investEther{value: 10 ether}(roundId);

        address[] memory investorsBefore = manager.getRoundInvestors(roundId);
        assertEq(investorsBefore.length, 1);
        assertEq(investorsBefore[0], investor);

        vm.prank(guardian);
        manager.cancelRound(roundId);

        address[] memory investorsAfter = manager.getRoundInvestors(roundId);
        assertEq(investorsAfter.length, 1);
        assertEq(investorsAfter[0], investor);
    }

    // ============ Receive Function Tests ============

    function testReceiveFunction() public {
        address investor = address(0x123);
        vm.deal(investor, 10 ether);

        uint32 roundId = _createTestRound(uint64(block.timestamp + 1 days), 7 days, 100 ether, 1000e18);

        // Setup allocation
        vm.prank(guardian);
        manager.addInvestorAllocation(roundId, investor, 10 ether, 100e18);

        // Activate round
        vm.warp(block.timestamp + 1 days);
        vm.prank(guardian);
        manager.activateRound(roundId);

        // Send ETH directly to contract
        vm.prank(investor);
        (bool success,) = address(manager).call{value: 10 ether}("");
        require(success, "ETH transfer failed");

        // Verify investment was processed
        (uint256 etherAmount,, uint256 invested,) = manager.getInvestorDetails(roundId, investor);
        assertEq(etherAmount, invested);
    }

    function testReceiveFailsWithNoActiveRound() public {
        address investor = address(0x123);
        vm.deal(investor, 1 ether);

        vm.prank(investor);
        vm.expectRevert("NO_ACTIVE_ROUND");
        (bool success,) = address(manager).call{value: 1 ether}("");
        require(success, "ETH transfer failed");
    }

    // ============ Upgrade Tests ============

    function testAuthorizeUpgrade() public {
        deployIMUpgrade();
    }

    // ============ Initialization Tests ============

    function testCannotInitializeTwice() public {
        bytes memory expError = abi.encodeWithSignature("InvalidInitialization()");
        vm.prank(guardian);
        vm.expectRevert(expError); // contract already initialized
        manager.initialize(address(tokenInstance), address(timelockInstance), address(treasuryInstance), guardian);
    }

    // ============ Pausing Tests ============

    function test_PausedCreateRound() public {
        vm.startPrank(guardian);
        manager.pause();
        vm.stopPrank();

        vm.startPrank(address(timelockInstance));
        bytes memory expError = abi.encodeWithSignature("EnforcedPause()");
        vm.expectRevert(expError);
        manager.createRound(uint64(block.timestamp + 1 days), 7 days, 100 ether, 1000e18, 365 days, 730 days);
        vm.stopPrank();
    }

    function test_PausedActivateRound() public {
        uint32 roundId = _createTestRound(uint64(block.timestamp + 1 days), 7 days, 100 ether, 1000e18);

        vm.prank(guardian);
        manager.pause();

        vm.warp(block.timestamp + 1 days);
        vm.prank(guardian);
        bytes memory expError = abi.encodeWithSignature("EnforcedPause()");
        vm.expectRevert(expError);
        manager.activateRound(roundId);
    }

    function test_PausedInvestEther() public {
        uint32 roundId = _setupActiveRound();
        vm.prank(guardian);
        manager.addInvestorAllocation(roundId, INVESTOR, INVESTMENT_AMOUNT, TOKEN_ALLOCATION);

        vm.prank(guardian);
        manager.pause();

        vm.deal(INVESTOR, INVESTMENT_AMOUNT);
        vm.prank(INVESTOR);
        bytes memory expError = abi.encodeWithSignature("EnforcedPause()");
        vm.expectRevert(expError);
        manager.investEther{value: INVESTMENT_AMOUNT}(roundId);
    }

    function test_PausedAddInvestorAllocation() public {
        uint32 roundId = _createTestRound(uint64(block.timestamp + 1 days), 7 days, 100 ether, 1000e18);

        vm.prank(guardian);
        manager.pause();

        vm.prank(guardian);
        bytes memory expError = abi.encodeWithSignature("EnforcedPause()");
        vm.expectRevert(expError);
        manager.addInvestorAllocation(roundId, INVESTOR, INVESTMENT_AMOUNT, TOKEN_ALLOCATION);
    }

    function test_PausedFinalizeRound() public {
        // Setup active round
        uint32 roundId = _setupActiveRound();

        // Add investor allocation
        vm.prank(guardian);
        manager.addInvestorAllocation(roundId, INVESTOR, 100 ether, TOKEN_ALLOCATION);

        // Make investment to complete the round
        vm.deal(INVESTOR, 100 ether);
        vm.prank(INVESTOR);
        manager.investEther{value: 100 ether}(roundId);

        // Wait for round to end
        vm.warp(block.timestamp + 16 days);

        // Pause the contract
        vm.prank(guardian);
        manager.pause();

        // Attempt to finalize while paused
        bytes memory expError = abi.encodeWithSignature("EnforcedPause()");
        vm.expectRevert(expError);
        manager.finalizeRound(roundId);

        // Verify round status hasn't changed
        IINVMANAGER.Round memory round = manager.getRoundInfo(roundId);
        assertEq(uint8(round.status), uint8(IINVMANAGER.RoundStatus.COMPLETED));
    }

    function test_PausedCancelRound() public {
        uint32 roundId = _createTestRound(uint64(block.timestamp + 1 days), 7 days, 100 ether, 1000e18);

        vm.prank(guardian);
        manager.pause();

        vm.prank(guardian);
        bytes memory expError = abi.encodeWithSignature("EnforcedPause()");
        vm.expectRevert(expError);
        manager.cancelRound(roundId);
    }

    function test_EmergencyFunctionsWorkWhenPaused() public {
        // Setup first round and investment before pausing
        uint32 roundId1 = _setupActiveRound();
        vm.prank(guardian);
        manager.addInvestorAllocation(roundId1, INVESTOR, INVESTMENT_AMOUNT, TOKEN_ALLOCATION);

        vm.deal(INVESTOR, INVESTMENT_AMOUNT);
        vm.prank(INVESTOR);
        manager.investEther{value: INVESTMENT_AMOUNT}(roundId1);

        // Setup second round and investment before pausing
        uint32 roundId2 = _setupActiveRound();
        vm.prank(guardian);
        manager.addInvestorAllocation(roundId2, INVESTOR, INVESTMENT_AMOUNT, TOKEN_ALLOCATION);

        vm.deal(INVESTOR, INVESTMENT_AMOUNT);
        vm.prank(INVESTOR);
        manager.investEther{value: INVESTMENT_AMOUNT}(roundId2);

        // Cancel second round for refund test
        vm.prank(guardian);
        manager.cancelRound(roundId2);

        // Now pause the contract
        vm.prank(guardian);
        manager.pause();

        // Test 1: Verify cancelInvestment works while paused
        vm.prank(INVESTOR);
        manager.cancelInvestment(roundId1);

        (,, uint256 invested,) = manager.getInvestorDetails(roundId1, INVESTOR);
        assertEq(invested, 0);

        // Test 2: Verify claimRefund works while paused
        vm.prank(INVESTOR);
        manager.claimRefund(roundId2);

        (,, invested,) = manager.getInvestorDetails(roundId2, INVESTOR);
        assertEq(invested, 0);
    }

    // ============ Modifiers ============
    function test_InvestEtherBranches() public {
        uint32 roundId = _setupActiveRound();
        vm.prank(guardian);
        manager.addInvestorAllocation(roundId, INVESTOR, INVESTMENT_AMOUNT, TOKEN_ALLOCATION);
        vm.deal(INVESTOR, INVESTMENT_AMOUNT * 10); // Sufficient ETH for all tests

        // Test 1: validRound modifier
        vm.prank(INVESTOR);
        vm.expectRevert("INVALID_ROUND");
        manager.investEther{value: INVESTMENT_AMOUNT}(999); // Invalid roundId

        // Test 2: notClosed modifier
        vm.startPrank(INVESTOR);
        manager.investEther{value: INVESTMENT_AMOUNT}(roundId); // First investment
        vm.expectRevert("AMOUNT_ALLOCATION_MISMATCH");
        manager.investEther{value: INVESTMENT_AMOUNT / 2}(roundId); // Should fail as amount doesn't match allocation
        vm.stopPrank();

        // Test 3: whenNotPaused modifier
        uint32 newRoundId = _setupActiveRound(); // Create new round for pause test
        vm.prank(guardian);
        manager.addInvestorAllocation(newRoundId, INVESTOR, INVESTMENT_AMOUNT, TOKEN_ALLOCATION);

        vm.prank(guardian);
        manager.pause();

        vm.prank(INVESTOR);
        bytes memory expError = abi.encodeWithSignature("EnforcedPause()");
        vm.expectRevert(expError);
        manager.investEther{value: INVESTMENT_AMOUNT}(newRoundId);
    }

    function test_ActivateRoundModifiers() public {
        uint32 roundId = _createTestRound(uint64(block.timestamp + 1 days), 7 days, 100 ether, 1000e18);

        // Test onlyRole modifier
        vm.prank(INVESTOR);
        bytes memory expError = abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)", INVESTOR, keccak256("MANAGER_ROLE")
        );
        vm.expectRevert(expError);
        manager.activateRound(roundId);

        // Test validRound modifier
        vm.prank(guardian);
        vm.expectRevert("INVALID_ROUND");
        manager.activateRound(999); // Invalid roundId

        // Test correctStatus modifier
        vm.warp(block.timestamp + 1 days);
        vm.startPrank(guardian);
        manager.activateRound(roundId); // First activation
        vm.expectRevert("INVALID_ROUND_STATUS");
        manager.activateRound(roundId); // Should fail as round is already active
        vm.stopPrank();
    }

    function test_FinalizeRoundModifiers() public {
        uint32 roundId = _setupActiveRound();
        vm.prank(guardian);
        manager.addInvestorAllocation(roundId, INVESTOR, INVESTMENT_AMOUNT, TOKEN_ALLOCATION);

        // Test validRound modifier
        vm.expectRevert("INVALID_ROUND");
        manager.finalizeRound(999); // Invalid roundId

        // Test round status requirement
        vm.expectRevert("INVALID_ROUND_STATUS");
        manager.finalizeRound(roundId); // Should fail as round is not completed

        // Make investment to complete round
        vm.deal(INVESTOR, INVESTMENT_AMOUNT);
        vm.prank(INVESTOR);
        manager.investEther{value: INVESTMENT_AMOUNT}(roundId);
    }

    function test_AddInvestorAllocationModifiers() public {
        uint32 roundId = _createTestRound(uint64(block.timestamp + 1 days), 7 days, 100 ether, 1000e18);

        // Test onlyRole modifier
        vm.prank(INVESTOR);
        bytes memory expError = abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)", INVESTOR, keccak256("MANAGER_ROLE")
        );
        vm.expectRevert(expError);
        manager.addInvestorAllocation(roundId, INVESTOR, INVESTMENT_AMOUNT, TOKEN_ALLOCATION);

        // Test validRound modifier
        vm.prank(guardian);
        vm.expectRevert("INVALID_ROUND");
        manager.addInvestorAllocation(999, INVESTOR, INVESTMENT_AMOUNT, TOKEN_ALLOCATION); // Invalid roundId
    }

    // Test each revert condition separately
    function test_InvestEther_WhenRoundNotActive() public {
        uint32 roundId = _createTestRound(uint64(block.timestamp + 1 days), 7 days, 100 ether, 1000e18);
        vm.prank(guardian);
        manager.addInvestorAllocation(roundId, INVESTOR, INVESTMENT_AMOUNT, TOKEN_ALLOCATION);
        vm.deal(INVESTOR, INVESTMENT_AMOUNT);

        vm.prank(INVESTOR);
        vm.expectRevert("ROUND_NOT_ACTIVE");
        manager.investEther{value: INVESTMENT_AMOUNT}(roundId);
    }

    function test_InvestEther_WhenRoundEnded() public {
        uint32 roundId = _setupActiveRound();
        vm.prank(guardian);
        manager.addInvestorAllocation(roundId, INVESTOR, INVESTMENT_AMOUNT, TOKEN_ALLOCATION);
        vm.deal(INVESTOR, INVESTMENT_AMOUNT);

        vm.warp(block.timestamp + 16 days); // Move past end time

        vm.prank(INVESTOR);
        vm.expectRevert("ROUND_ENDED");
        manager.investEther{value: INVESTMENT_AMOUNT}(roundId);
    }

    function test_InvestEther_WhenRoundOversubscribed() public {
        // Create round with sufficient capacity for all investors
        vm.startPrank(address(timelockInstance));
        treasuryInstance.release(address(tokenInstance), address(manager), TOKEN_ALLOCATION * 100);
        uint32 roundId = manager.createRound(
            uint64(block.timestamp + 1 days), 7 days, 100 ether, TOKEN_ALLOCATION * 100, 365 days, 730 days
        );
        vm.stopPrank();

        // Activate round
        vm.warp(block.timestamp + 1 days);
        vm.prank(guardian);
        manager.activateRound(roundId);

        // Fill round with maximum participants
        for (uint256 i = 1; i <= 50; i++) {
            address investor = address(uint160(i));
            vm.prank(guardian);
            manager.addInvestorAllocation(roundId, investor, 1 ether, TOKEN_ALLOCATION);

            vm.deal(investor, 1 ether);
            vm.prank(investor);
            manager.investEther{value: 1 ether}(roundId);
        }

        // Try to invest with one more participant
        address extraInvestor = address(uint160(51));
        vm.prank(guardian);
        manager.addInvestorAllocation(roundId, extraInvestor, 1 ether, TOKEN_ALLOCATION);
        vm.deal(extraInvestor, 1 ether);

        vm.prank(extraInvestor);
        vm.expectRevert("ROUND_OVERSUBSCRIBED");
        manager.investEther{value: 1 ether}(roundId);
    }

    function test_InvestEther_WhenNoAllocation() public {
        uint32 roundId = _setupActiveRound();
        vm.deal(INVESTOR, INVESTMENT_AMOUNT);

        vm.prank(INVESTOR);
        vm.expectRevert("NO_ALLOCATION");
        manager.investEther{value: INVESTMENT_AMOUNT}(roundId);
    }

    function test_InvestEther_WhenAmountMismatch() public {
        uint32 roundId = _setupActiveRound();
        vm.prank(guardian);
        manager.addInvestorAllocation(roundId, INVESTOR, INVESTMENT_AMOUNT, TOKEN_ALLOCATION);
        vm.deal(INVESTOR, INVESTMENT_AMOUNT);

        vm.prank(INVESTOR);
        vm.expectRevert("AMOUNT_ALLOCATION_MISMATCH");
        manager.investEther{value: INVESTMENT_AMOUNT / 2}(roundId);
    }

    function test_InvestEther_WhenInvalidRound() public {
        vm.deal(INVESTOR, INVESTMENT_AMOUNT);

        vm.prank(INVESTOR);
        vm.expectRevert("INVALID_ROUND");
        manager.investEther{value: INVESTMENT_AMOUNT}(999); // Non-existent round
    }

    function test_InvestEther_WhenPaused() public {
        uint32 roundId = _setupActiveRound();
        vm.prank(guardian);
        manager.addInvestorAllocation(roundId, INVESTOR, INVESTMENT_AMOUNT, TOKEN_ALLOCATION);
        vm.deal(INVESTOR, INVESTMENT_AMOUNT);

        vm.prank(guardian);
        manager.pause();

        vm.prank(INVESTOR);
        bytes memory expError = abi.encodeWithSignature("EnforcedPause()");
        vm.expectRevert(expError);
        manager.investEther{value: INVESTMENT_AMOUNT}(roundId);
    }

    function test_InvestEther_SuccessfulInvestment() public {
        uint32 roundId = _setupActiveRound();
        vm.prank(guardian);
        manager.addInvestorAllocation(roundId, INVESTOR, INVESTMENT_AMOUNT, TOKEN_ALLOCATION);
        vm.deal(INVESTOR, INVESTMENT_AMOUNT);

        uint256 balanceBefore = INVESTOR.balance;

        vm.prank(INVESTOR);
        manager.investEther{value: INVESTMENT_AMOUNT}(roundId);

        // Verify state changes
        (,, uint256 invested,) = manager.getInvestorDetails(roundId, INVESTOR);
        IINVMANAGER.Round memory round = manager.getRoundInfo(roundId);

        assertEq(invested, INVESTMENT_AMOUNT);
        assertEq(round.etherInvested, INVESTMENT_AMOUNT);
        assertEq(round.participants, 1);
        assertEq(INVESTOR.balance, balanceBefore - INVESTMENT_AMOUNT);
    }

    function test_RemoveInvestorOperation() public {
        // Setup round with multiple investors
        uint32 roundId = _setupActiveRound();
        address[] memory testInvestors = new address[](5);

        // Create and track test investors
        for (uint256 i = 0; i < 5; i++) {
            testInvestors[i] = address(uint160(i + 1));
            vm.prank(guardian);
            manager.addInvestorAllocation(roundId, testInvestors[i], INVESTMENT_AMOUNT, TOKEN_ALLOCATION);

            vm.deal(testInvestors[i], INVESTMENT_AMOUNT);
            vm.prank(testInvestors[i]);
            manager.investEther{value: INVESTMENT_AMOUNT}(roundId);
        }

        // Verify initial state
        address[] memory initialInvestors = manager.getRoundInvestors(roundId);
        assertEq(initialInvestors.length, 5, "Should have 5 investors initially");

        // Test Case 1: Remove first investor
        vm.prank(testInvestors[0]);
        manager.cancelInvestment(roundId);

        address[] memory afterFirstRemoval = manager.getRoundInvestors(roundId);
        assertEq(afterFirstRemoval.length, 4, "Should have 4 investors after first removal");
        assertFalse(_containsAddress(afterFirstRemoval, testInvestors[0]), "Removed investor should not be in array");

        // Test Case 2: Remove last investor
        vm.prank(testInvestors[4]);
        manager.cancelInvestment(roundId);

        address[] memory afterLastRemoval = manager.getRoundInvestors(roundId);
        assertEq(afterLastRemoval.length, 3, "Should have 3 investors after last removal");
        assertFalse(_containsAddress(afterLastRemoval, testInvestors[4]), "Removed investor should not be in array");

        // Test Case 3: Remove middle investor
        vm.prank(testInvestors[2]);
        manager.cancelInvestment(roundId);

        address[] memory afterMiddleRemoval = manager.getRoundInvestors(roundId);
        assertEq(afterMiddleRemoval.length, 2, "Should have 2 investors after middle removal");
        assertFalse(_containsAddress(afterMiddleRemoval, testInvestors[2]), "Removed investor should not be in array");

        // Verify remaining investors can still cancel
        for (uint256 i = 0; i < 5; i++) {
            if (i != 0 && i != 2 && i != 4) {
                // Skip already removed investors
                vm.prank(testInvestors[i]);
                manager.cancelInvestment(roundId);
            }
        }

        // Verify final state
        address[] memory finalInvestors = manager.getRoundInvestors(roundId);
        assertEq(finalInvestors.length, 0, "Should have no investors at the end");

        // Verify round state
        IINVMANAGER.Round memory round = manager.getRoundInfo(roundId);
        assertEq(round.participants, 0, "Should have no participants");
        assertEq(round.etherInvested, 0, "Should have no ETH invested");
    }

    function testDeployVestingContract() public {
        // Setup initial state
        uint64 start = uint64(block.timestamp + 1 days);
        uint64 duration = 30 days;
        uint256 ethTarget = 100 ether;
        uint256 tokenAlloc = 1000 ether;
        uint64 vestingCliff = 90 days;
        uint64 vestingDuration = 365 days;

        // Release tokens to manager first
        vm.startPrank(address(timelockInstance));
        treasuryInstance.release(address(tokenInstance), address(manager), tokenAlloc);

        // Expect CreateRound and RoundStatusUpdated events
        vm.expectEmit(true, false, false, true);
        emit CreateRound(0, start, duration, ethTarget, tokenAlloc);
        vm.expectEmit(true, false, false, true);
        emit RoundStatusUpdated(0, IINVMANAGER.RoundStatus.PENDING);

        // Create round
        uint32 roundId = manager.createRound(start, duration, ethTarget, tokenAlloc, vestingCliff, vestingDuration);
        vm.stopPrank();

        // Expect InvestorAllocated event
        vm.expectEmit(true, true, false, true);
        emit InvestorAllocated(roundId, alice, 100 ether, 1000 ether);

        // Add investor allocation for full round amount
        vm.startPrank(guardian);
        manager.addInvestorAllocation(roundId, alice, 100 ether, 1000 ether);
        vm.stopPrank();

        // Expect RoundStatusUpdated event
        vm.expectEmit(true, false, false, true);
        emit RoundStatusUpdated(roundId, IINVMANAGER.RoundStatus.ACTIVE);

        // Activate round
        vm.warp(start);
        vm.startPrank(guardian);
        manager.activateRound(roundId);
        vm.stopPrank();

        // Expect Invest event
        vm.expectEmit(true, true, false, true);
        emit Invest(roundId, alice, 100 ether);

        // Invest full amount to complete the round
        vm.deal(alice, 100 ether);
        vm.startPrank(alice);
        manager.investEther{value: 100 ether}(roundId);
        vm.stopPrank();

        // Wait for round to end
        vm.warp(start + duration + 1);

        // Complete round
        vm.startPrank(guardian);
        manager.finalizeRound(roundId);
        vm.stopPrank();

        // Get vesting contract address
        (,,, address vestingAddress) = manager.getInvestorDetails(roundId, alice);

        // Verify vesting contract
        InvestorVesting vestingContract = InvestorVesting(vestingAddress);

        // Verify core parameters
        assertEq(vestingContract.owner(), alice);

        // Verify vesting schedule
        assertEq(vestingContract.start(), block.timestamp + vestingCliff);
        assertEq(vestingContract.duration(), vestingDuration);
        assertEq(vestingContract.end(), block.timestamp + vestingCliff + vestingDuration);

        // Verify initial vesting state
        assertEq(vestingContract.released(), 0);
        assertEq(vestingContract.releasable(), 0);

        // Verify token balance
        assertEq(tokenInstance.balanceOf(vestingAddress), 1000 ether);
    }

    function testFinalizeRoundMultipleInvestors() public {
        // Setup initial state
        uint64 start = uint64(block.timestamp + 1 days);
        uint64 duration = 30 days;
        uint256 ethTarget = 100 ether;
        uint256 tokenAlloc = 1000 ether;
        uint64 vestingCliff = 90 days;
        uint64 vestingDuration = 365 days;

        // Release tokens to manager
        vm.startPrank(address(timelockInstance));
        treasuryInstance.release(address(tokenInstance), address(manager), tokenAlloc);

        // Create round
        uint32 roundId = manager.createRound(start, duration, ethTarget, tokenAlloc, vestingCliff, vestingDuration);
        vm.stopPrank();

        // Setup multiple investors
        address[] memory investors = new address[](3);
        investors[0] = alice;
        investors[1] = bob;
        investors[2] = charlie;

        uint256[] memory ethAmounts = new uint256[](3);
        ethAmounts[0] = 40 ether;
        ethAmounts[1] = 35 ether;
        ethAmounts[2] = 25 ether;

        uint256[] memory tokenAmounts = new uint256[](3);
        tokenAmounts[0] = 400 ether;
        tokenAmounts[1] = 350 ether;
        tokenAmounts[2] = 250 ether;

        // Add allocations for all investors
        vm.startPrank(guardian);
        for (uint256 i = 0; i < investors.length; i++) {
            manager.addInvestorAllocation(roundId, investors[i], ethAmounts[i], tokenAmounts[i]);
        }

        // Activate round
        vm.warp(start);
        manager.activateRound(roundId);
        vm.stopPrank();

        // Investors make investments
        for (uint256 i = 0; i < investors.length; i++) {
            vm.deal(investors[i], ethAmounts[i]);
            vm.prank(investors[i]);
            manager.investEther{value: ethAmounts[i]}(roundId);
        }

        // Wait for round to end
        vm.warp(start + duration + 1);

        // Finalize round
        vm.startPrank(guardian);
        manager.finalizeRound(roundId);
        vm.stopPrank();

        // Verify final state
        for (uint256 i = 0; i < investors.length; i++) {
            (,,, address vestingAddress) = manager.getInvestorDetails(roundId, investors[i]);
            InvestorVesting vestingContract = InvestorVesting(vestingAddress);

            assertEq(vestingContract.owner(), investors[i]);
            assertEq(vestingContract.start(), block.timestamp + vestingCliff);
            assertEq(vestingContract.duration(), vestingDuration);
            assertEq(vestingContract.end(), block.timestamp + vestingCliff + vestingDuration);
            assertEq(vestingContract.released(), 0);
            assertEq(tokenInstance.balanceOf(vestingAddress), tokenAmounts[i]);
        }

        // Verify treasury received ETH
        assertEq(address(treasuryInstance).balance, ethTarget);
    }

    function testRemoveInvestorAllocationRevertsForZeroAddress() public {
        uint32 roundId = _setupActiveRound();

        vm.startPrank(guardian);
        vm.expectRevert("INVALID_INVESTOR");
        manager.removeInvestorAllocation(roundId, address(0));
        vm.stopPrank();
    }

    function testRemoveInvestorAllocationRevertsForUnauthorized() public {
        uint32 roundId = _setupActiveRound();

        bytes memory expError =
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", alice, MANAGER_ROLE);
        vm.prank(alice);
        vm.expectRevert(expError);
        manager.removeInvestorAllocation(roundId, bob);
    }

    function testRemoveInvestorAllocationRevertsForNoAllocation() public {
        uint32 roundId = _setupActiveRound();

        vm.startPrank(guardian);
        vm.expectRevert("NO_ALLOCATION_EXISTS");
        manager.removeInvestorAllocation(roundId, alice);
        vm.stopPrank();
    }

    function testRemoveInvestorAllocationRevertsForActivePosition() public {
        uint32 roundId = _setupActiveRound();

        vm.startPrank(guardian);
        manager.addInvestorAllocation(roundId, alice, INVESTMENT_AMOUNT, TOKEN_ALLOCATION);
        vm.stopPrank();

        vm.deal(alice, INVESTMENT_AMOUNT);
        vm.prank(alice);
        manager.investEther{value: INVESTMENT_AMOUNT}(roundId);

        vm.startPrank(guardian);
        vm.expectRevert("INVESTOR_HAS_ACTIVE_POSITION");
        manager.removeInvestorAllocation(roundId, alice);
        vm.stopPrank();
    }

    function testRemoveInvestorAllocationRevertsForCompletedRound() public {
        uint32 roundId = _setupActiveRound();

        // Add allocation for alice who will complete the round
        vm.startPrank(guardian);
        manager.addInvestorAllocation(roundId, alice, 100 ether, TOKEN_ALLOCATION);

        // Add another allocation for bob that we'll try to remove later
        manager.addInvestorAllocation(roundId, bob, INVESTMENT_AMOUNT, TOKEN_ALLOCATION);
        vm.stopPrank();

        // Complete the round by having alice invest the full amount
        vm.deal(alice, 100 ether);
        vm.prank(alice);
        manager.investEther{value: 100 ether}(roundId);

        // Verify round is completed
        IINVMANAGER.Round memory round = manager.getRoundInfo(roundId);
        assertEq(uint8(round.status), uint8(IINVMANAGER.RoundStatus.COMPLETED));

        // Now try to remove bob's allocation - should fail because round is completed
        vm.startPrank(guardian);
        vm.expectRevert("INVALID_ROUND_STATUS");
        manager.removeInvestorAllocation(roundId, bob);
        vm.stopPrank();
    }

    function testRemoveInvestorAllocationRevertsWhenPaused() public {
        uint32 roundId = _setupActiveRound();

        vm.startPrank(guardian);
        manager.addInvestorAllocation(roundId, alice, INVESTMENT_AMOUNT, TOKEN_ALLOCATION);
        manager.pause();

        bytes memory expError = abi.encodeWithSignature("EnforcedPause()");
        vm.expectRevert(expError);
        manager.removeInvestorAllocation(roundId, alice);
        vm.stopPrank();
    }

    function testRemoveInvestorAllocationRevertsForInvalidRound() public {
        vm.startPrank(guardian);
        vm.expectRevert("INVALID_ROUND");
        manager.removeInvestorAllocation(999, alice);
        vm.stopPrank();
    }

    function testRoundStatusTransitions() public {
        uint32 roundId = _createTestRound(uint64(block.timestamp + 1 days), 7 days, 100 ether, 1000e18);

        IINVMANAGER.Round memory round = manager.getRoundInfo(roundId);
        assertEq(uint8(round.status), uint8(IINVMANAGER.RoundStatus.PENDING));

        vm.warp(block.timestamp + 1 days);
        vm.prank(guardian);
        manager.activateRound(roundId);
        round = manager.getRoundInfo(roundId);
        assertEq(uint8(round.status), uint8(IINVMANAGER.RoundStatus.ACTIVE));

        vm.prank(guardian);
        manager.addInvestorAllocation(roundId, alice, 100 ether, 1000e18);
        vm.deal(alice, 100 ether);
        vm.prank(alice);
        manager.investEther{value: 100 ether}(roundId);
        round = manager.getRoundInfo(roundId);
        assertEq(uint8(round.status), uint8(IINVMANAGER.RoundStatus.COMPLETED));

        vm.warp(block.timestamp + 8 days);
        vm.prank(guardian);
        manager.finalizeRound(roundId);
        round = manager.getRoundInfo(roundId);
        assertEq(uint8(round.status), uint8(IINVMANAGER.RoundStatus.FINALIZED));
    }

    function testMaximumParticipantsLimit() public {
        // Create round with sufficient capacity for all investors
        vm.startPrank(address(timelockInstance));
        treasuryInstance.release(address(tokenInstance), address(manager), TOKEN_ALLOCATION * 100);
        uint32 roundId = manager.createRound(
            uint64(block.timestamp + 1 days), 7 days, 100 ether, TOKEN_ALLOCATION * 100, 365 days, 730 days
        );
        vm.stopPrank();

        // Activate round
        vm.warp(block.timestamp + 1 days);
        vm.prank(guardian);
        manager.activateRound(roundId);

        // Fill round with maximum participants
        for (uint256 i = 1; i <= 50; i++) {
            address investor = address(uint160(i));
            vm.prank(guardian);
            manager.addInvestorAllocation(roundId, investor, 1 ether, TOKEN_ALLOCATION);

            vm.deal(investor, 1 ether);
            vm.prank(investor);
            manager.investEther{value: 1 ether}(roundId);
        }

        // Try to invest with one more participant
        address extraInvestor = address(uint160(51));
        vm.prank(guardian);
        manager.addInvestorAllocation(roundId, extraInvestor, 1 ether, TOKEN_ALLOCATION);
        vm.deal(extraInvestor, 1 ether);

        vm.prank(extraInvestor);
        vm.expectRevert("ROUND_OVERSUBSCRIBED");
        manager.investEther{value: 1 ether}(roundId);
    }

    function testVestingScheduleCalculation() public {
        // Setup vesting parameters
        uint64 vestingCliff = 365 days;
        uint64 vestingDuration = 730 days;
        uint256 investAmount = 10 ether;
        uint256 tokenAmount = 1000e18;

        // Create and setup round
        uint32 roundId = _createTestRound(uint64(block.timestamp + 1 days), 7 days, investAmount, tokenAmount);

        // Add investor allocation
        vm.startPrank(guardian);
        manager.addInvestorAllocation(roundId, alice, investAmount, tokenAmount);
        vm.stopPrank();

        // Activate round and make investment
        vm.warp(block.timestamp + 1 days);
        vm.prank(guardian);
        manager.activateRound(roundId);

        vm.deal(alice, investAmount);
        vm.prank(alice);
        manager.investEther{value: investAmount}(roundId);

        // Finalize round to deploy vesting contract
        vm.warp(block.timestamp + 8 days);
        vm.prank(guardian);
        manager.finalizeRound(roundId);

        // Get vesting contract
        (,,, address vestingAddress) = manager.getInvestorDetails(roundId, alice);
        InvestorVesting vestingContract = InvestorVesting(vestingAddress);

        // Verify initial vesting parameters
        uint256 expectedStart = block.timestamp + vestingCliff;
        assertEq(vestingContract.start(), expectedStart);
        assertEq(vestingContract.duration(), vestingDuration);
        assertEq(vestingContract.end(), expectedStart + vestingDuration);

        // Test before cliff
        vm.warp(expectedStart - 1);
        // Try to release tokens
        vestingContract.release();
        uint256 vested = vestingContract.releasable();
        assertEq(0, vested);
        assertEq(0, tokenInstance.balanceOf(alice));

        // Test at 50% vesting duration
        vm.warp(expectedStart + vestingDuration / 2);
        uint256 expectedHalf = tokenAmount / 2;
        assertApproxEqRel(vestingContract.releasable(), expectedHalf, 0.01e18);

        // Test at full vesting
        vm.warp(expectedStart + vestingDuration);
        assertEq(vestingContract.releasable(), tokenAmount);
    }

    function testInitializeZeroAddressCombinations() public {
        InvestmentManager item = new InvestmentManager();
        // Deploy new proxy instance
        bytes memory data = abi.encodeCall(
            InvestmentManager.initialize, (address(0), address(timelockInstance), address(treasuryInstance), guardian)
        );

        vm.expectRevert("ZERO_ADDRESS_DETECTED");
        ERC1967Proxy proxy = new ERC1967Proxy(address(item), data);
        InvestmentManager(payable(address(proxy)));

        // Test: valid token, valid timelock, zero treasury, valid guardian
        data = abi.encodeCall(
            InvestmentManager.initialize, (address(tokenInstance), address(0), address(treasuryInstance), guardian)
        );
        vm.expectRevert("ZERO_ADDRESS_DETECTED");
        ERC1967Proxy proxy1 = new ERC1967Proxy(address(item), data);
        InvestmentManager(payable(address(proxy1)));

        // Test: valid token, valid timelock, valid treasury, zero guardian
        data = abi.encodeCall(
            InvestmentManager.initialize, (address(tokenInstance), address(timelockInstance), address(0), guardian)
        );
        vm.expectRevert("ZERO_ADDRESS_DETECTED");
        ERC1967Proxy proxy2 = new ERC1967Proxy(address(item), data);
        InvestmentManager(payable(address(proxy2)));
    }

    function testActivateRoundInvalidStatus() public {
        uint32 roundId = _createTestRound(uint64(block.timestamp + 1 days), 7 days, 100 ether, 1000e18);

        // Activate the round
        vm.warp(block.timestamp + 1 days);
        vm.prank(guardian);
        manager.activateRound(roundId);

        // Try to activate again
        vm.prank(guardian);
        vm.expectRevert("INVALID_ROUND_STATUS");
        manager.activateRound(roundId);
    }

    function testAddInvestorAllocationInvalidParameters() public {
        uint32 roundId = _createTestRound(uint64(block.timestamp + 1 days), 7 days, 100 ether, 1000e18);

        // Activate the round
        vm.warp(block.timestamp + 1 days);
        vm.prank(guardian);
        manager.activateRound(roundId);

        // Test invalid investor address (zero)
        vm.prank(guardian);
        vm.expectRevert("INVALID_INVESTOR");
        manager.addInvestorAllocation(roundId, address(0), 1 ether, 10e18);

        // Test invalid ETH amount (zero)
        vm.prank(guardian);
        vm.expectRevert("INVALID_ETH_AMOUNT");
        manager.addInvestorAllocation(roundId, address(0x123), 0, 10e18);

        // Test invalid token amount (zero)
        vm.prank(guardian);
        vm.expectRevert("INVALID_TOKEN_AMOUNT");
        manager.addInvestorAllocation(roundId, address(0x123), 1 ether, 0);

        // Test invalid round status (completed or cancelled)
        vm.prank(guardian);
        manager.cancelRound(roundId);
        vm.prank(guardian);
        vm.expectRevert("INVALID_ROUND_STATUS");
        manager.addInvestorAllocation(roundId, address(0x123), 1 ether, 10e18);

        // Test exceeds round allocation
        uint32 newRoundId = _createTestRound(uint64(block.timestamp + 1 days), 7 days, 100 ether, 1000e18);
        vm.warp(block.timestamp + 1 days);
        vm.prank(guardian);
        manager.activateRound(newRoundId);
        vm.prank(guardian);
        vm.expectRevert("EXCEEDS_ROUND_ALLOCATION");
        manager.addInvestorAllocation(newRoundId, address(0x123), 101 ether, 1001e18);

        // Test allocation already exists
        vm.prank(guardian);
        manager.addInvestorAllocation(newRoundId, address(0x123), 1 ether, 10e18);
        vm.prank(guardian);
        vm.expectRevert("ALLOCATION_EXISTS");
        manager.addInvestorAllocation(newRoundId, address(0x123), 2 ether, 20e18);
    }

    function testRemoveInvestorAllocation() public {
        uint32 roundId = _createTestRound(uint64(block.timestamp + 1 days), 7 days, 100 ether, 1000e18);

        // Warp to start time
        vm.warp(block.timestamp + 1 days);

        // Activate the round
        vm.prank(guardian);
        manager.activateRound(roundId);

        vm.startPrank(guardian);
        manager.addInvestorAllocation(roundId, alice, INVESTMENT_AMOUNT, TOKEN_ALLOCATION);

        // Expect InvestorAllocationRemoved event with correct parameters
        vm.expectEmit(true, true, false, true);
        emit InvestorAllocationRemoved(roundId, alice, INVESTMENT_AMOUNT, TOKEN_ALLOCATION);

        manager.removeInvestorAllocation(roundId, alice);
        vm.stopPrank();

        // Verify allocation was removed
        (uint256 allocEth, uint256 allocToken,,) = manager.getInvestorDetails(roundId, alice);
        assertEq(allocEth, 0, "ETH allocation should be zero");
        assertEq(allocToken, 0, "Token allocation should be zero");
    }

    function testCancelInvestmentInvalidParameters() public {
        uint32 roundId = _createTestRound(uint64(block.timestamp + 1 days), 7 days, 100 ether, 1000e18);

        // Activate the round
        vm.warp(block.timestamp + 1 days);
        vm.prank(guardian);
        manager.activateRound(roundId);
        // Test no active investment
        vm.prank(address(0x123));
        vm.expectRevert("NO_INVESTMENT");
        manager.cancelInvestment(roundId);

        // Test invalid round status (not ACTIVE)
        vm.prank(guardian);
        manager.cancelRound(roundId);
        vm.prank(address(0x123));
        vm.expectRevert("ROUND_NOT_ACTIVE");
        manager.cancelInvestment(roundId);
    }

    function testFinalizeRoundInvalidParameters() public {
        uint32 roundId = _createTestRound(uint64(block.timestamp + 1 days), 7 days, 100 ether, 1000e18);

        // Test invalid round status (not COMPLETED)
        vm.prank(guardian);
        vm.expectRevert("INVALID_ROUND_STATUS");
        manager.finalizeRound(roundId);

        // Warp to start time and activate round
        vm.warp(block.timestamp + 1 days);
        vm.prank(guardian);
        manager.activateRound(roundId);

        // Add investor allocation
        vm.prank(guardian);
        manager.addInvestorAllocation(roundId, address(0x123), 50 ether, 1000e18);

        // Make investment
        vm.deal(address(0x123), 50 ether);
        vm.prank(address(0x123));
        manager.investEther{value: 50 ether}(roundId);

        vm.prank(guardian);
        vm.expectRevert("INVALID_ROUND_STATUS");
        manager.finalizeRound(roundId);
        // Wait for round to end and complete it
        vm.warp(block.timestamp + 8 days);

        // Empty the contract's ETH balance
        vm.prank(address(0x123));
        manager.cancelInvestment(roundId);
        assertEq(address(0x123).balance, 50 ether);
    }

    function testClaimRefundInvalidParameters() public {
        uint32 roundId = _createTestRound(uint64(block.timestamp + 1 days), 7 days, 100 ether, 1000e18);

        // Test invalid round status (not CANCELLED)
        vm.prank(guardian);
        vm.expectRevert("ROUND_NOT_CANCELLED");
        manager.claimRefund(roundId);

        // Test no refund available
        vm.prank(guardian);
        manager.cancelRound(roundId);
        vm.prank(address(0x123));
        vm.expectRevert("NO_REFUND_AVAILABLE");
        manager.claimRefund(roundId);
    }

    function testGetRefundAmountInvalidParameters() public {
        uint32 roundId = _createTestRound(uint64(block.timestamp + 1 days), 7 days, 100 ether, 1000e18);

        // Test invalid round status (not CANCELLED)
        assertEq(manager.getRefundAmount(roundId, address(0x123)), 0);

        // Test no refund available
        vm.prank(guardian);
        manager.cancelRound(roundId);
        assertEq(manager.getRefundAmount(roundId, address(0x123)), 0);
    }

    function testGetCurrentRoundInvalidParameters() public {
        // Test no active round
        assertEq(manager.getCurrentRound(), type(uint32).max);
    }

    function testReceiveFunctionInvalidParameters() public {
        // Test no active round
        vm.deal(address(0x123), 1 ether);
        vm.prank(address(0x123));
        vm.expectRevert("NO_ACTIVE_ROUND");
        (bool success,) = address(manager).call{value: 1 ether}("");
        require(success, "ETH transfer failed");
    }

    function _setupToken() private {
        assertEq(tokenInstance.totalSupply(), 0);
        vm.startPrank(guardian);
        tokenInstance.initializeTGE(address(ecoInstance), address(treasuryInstance));
        uint256 ecoBal = tokenInstance.balanceOf(address(ecoInstance));
        uint256 treasuryBal = tokenInstance.balanceOf(address(treasuryInstance));

        assertEq(ecoBal, 22_000_000 ether);
        assertEq(treasuryBal, 28_000_000 ether);
        assertEq(tokenInstance.totalSupply(), ecoBal + treasuryBal);
        vm.stopPrank();
    }

    function _deployManager() private {
        bytes memory data = abi.encodeCall(
            InvestmentManager.initialize,
            (address(tokenInstance), address(timelockInstance), address(treasuryInstance), guardian)
        );
        address payable proxy = payable(Upgrades.deployUUPSProxy("InvestmentManager.sol", data));
        manager = InvestmentManager(proxy);
        address implementation = Upgrades.getImplementationAddress(proxy);
        assertFalse(address(manager) == implementation);

        vm.prank(guardian);
        treasuryInstance.grantRole(MANAGER_ROLE, address(timelockInstance));
    }

    function _createTestRound(uint64 start, uint64 duration, uint256 ethTarget, uint256 tokenAlloc)
        private
        returns (uint32 roundId)
    {
        vm.startPrank(address(timelockInstance));
        treasuryInstance.release(address(tokenInstance), address(manager), tokenAlloc);
        roundId = manager.createRound(start, duration, ethTarget, tokenAlloc, 365 days, 730 days);
        vm.stopPrank();
    }

    function _setupActiveRound() private returns (uint32) {
        vm.startPrank(address(timelockInstance));
        treasuryInstance.release(address(tokenInstance), address(manager), 1000e18);
        uint32 roundId =
            manager.createRound(uint64(block.timestamp + 1 days), 7 days, 100 ether, 1000e18, 365 days, 730 days);
        vm.stopPrank();

        vm.warp(block.timestamp + 1 days);
        vm.prank(guardian);
        manager.activateRound(roundId);

        return roundId;
    }

    function _containsAddress(address[] memory addresses, address target) private pure returns (bool) {
        for (uint256 i = 0; i < addresses.length; i++) {
            if (addresses[i] == target) {
                return true;
            }
        }
        return false;
    }
}
