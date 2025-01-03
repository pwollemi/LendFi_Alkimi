// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IPARTNERVESTING} from "../interfaces/IPartnerVesting.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Context} from "@openzeppelin/contracts/utils/Context.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title PartnerVesting
 * @notice A contract for managing token vesting schedules for partners and strategic allies
 * @dev Implements a linear vesting schedule with provisions for cancellation by the creator
 * The ownership of the contract is set to the beneficiary (partner) who can claim vested tokens
 * The contract can be cancelled by the creator (typically the Ecosystem contract)
 */
contract PartnerVesting is IPARTNERVESTING, Context, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice The timestamp when the vesting begins
    /// @dev Stored as uint64 to save gas
    uint64 private immutable _start;

    /// @notice The duration of the vesting period in seconds
    /// @dev Stored as uint64 to save gas
    uint64 private immutable _duration;

    /// @notice Address of the ERC20 token being vested
    /// @dev Set at construction and cannot be changed
    address private immutable _token;

    /// @notice Address of the timelock contract that can execute administrative functions
    /// @dev Set at construction and cannot be changed
    address public immutable _timelock;

    /// @notice Address of the contract that created this vesting instance (usually Ecosystem)
    /// @dev The creator has the authority to cancel the contract
    address public immutable _creator;

    /// @notice Running total of tokens that have been released to the beneficiary
    /// @dev Updated each time tokens are released
    uint256 private _tokensReleased;

    /**
     * @notice Restricts function access to authorized parties (creator)
     * @dev Reverts with Unauthorized if the caller is not the creator
     */
    modifier onlyAuthorized() {
        _checkAuthorized();
        _;
    }

    /**
     * @notice Creates a new vesting contract for a partner
     * @dev Sets up the vesting schedule and transfers ownership to the beneficiary
     * @param token Address of the ERC20 token to be vested
     * @param timelock Address of the governance timelock
     * @param beneficiary Address that will receive the vested tokens
     * @param startTimestamp When the vesting schedule starts
     * @param durationSeconds Length of the vesting period in seconds
     */
    constructor(address token, address timelock, address beneficiary, uint64 startTimestamp, uint64 durationSeconds)
        Ownable(beneficiary)
    {
        if (token == address(0) || timelock == address(0) || beneficiary == address(0)) {
            revert ZeroAddress();
        }

        _token = token;
        _timelock = timelock;
        _creator = msg.sender; // Store the creator (Ecosystem contract)
        _start = startTimestamp;
        _duration = durationSeconds;

        emit VestingInitialized(token, beneficiary, timelock, startTimestamp, durationSeconds);
    }

    /**
     * @notice Allows the creator to cancel the vesting contract
     * @dev Releases any vested tokens to the beneficiary first, then returns remaining tokens to the creator
     * @return remainder The amount of tokens returned to the creator
     */
    function cancelContract() external nonReentrant onlyAuthorized returns (uint256) {
        // Release vested tokens to beneficiary first
        if (releasable() > 0) {
            release();
        }

        // Get current balance
        IERC20 tokenInstance = IERC20(_token);
        uint256 remainder = tokenInstance.balanceOf(address(this));

        // Only emit event and transfer if there are tokens to transfer
        if (remainder > 0) {
            emit Cancelled(remainder);
            tokenInstance.safeTransfer(_creator, remainder);
        }

        return remainder;
    }

    /**
     * @notice Releases vested tokens to the beneficiary
     * @dev Anyone can call this function, but tokens are always sent to the owner (beneficiary)
     * No tokens are released if the amount releasable is 0
     */
    function release() public virtual {
        uint256 amount = releasable();
        if (amount == 0) return;

        _tokensReleased += amount;
        emit ERC20Released(_token, amount);
        IERC20(_token).safeTransfer(owner(), amount);
    }

    /**
     * @notice Returns the start timestamp of the vesting schedule
     * @return The unix timestamp when vesting begins
     */
    function start() public view virtual returns (uint256) {
        return _start;
    }

    /**
     * @notice Returns the duration of the vesting period in seconds
     * @return The vesting duration in seconds
     */
    function duration() public view virtual returns (uint256) {
        return _duration;
    }

    /**
     * @notice Returns the end timestamp of the vesting schedule
     * @return The unix timestamp when vesting ends
     */
    function end() public view virtual returns (uint256) {
        return start() + duration();
    }

    /**
     * @notice Returns the total amount of tokens already released
     * @return The amount of tokens released so far
     */
    function released() public view virtual returns (uint256) {
        return _tokensReleased;
    }

    /**
     * @notice Returns the amount of tokens that can be released at the current time
     * @return The amount of tokens available for release
     */
    function releasable() public view virtual returns (uint256) {
        return vestedAmount(SafeCast.toUint64(block.timestamp)) - released();
    }

    /**
     * @notice Calculates the amount of tokens vested at a specific timestamp
     * @dev Internal function used to determine how many tokens have vested
     * @param timestamp The timestamp to calculate vested tokens at
     * @return The amount of tokens vested at the given timestamp
     */
    function vestedAmount(uint64 timestamp) internal view virtual returns (uint256) {
        return _vestingSchedule(IERC20(_token).balanceOf(address(this)) + released(), timestamp);
    }

    /**
     * @notice Calculates the vesting schedule based on timestamp
     * @dev Implements a linear vesting schedule
     * @param totalAllocation The total number of tokens allocated for vesting
     * @param timestamp The timestamp to calculate vested tokens at
     * @return The amount of tokens vested by the given timestamp
     */
    function _vestingSchedule(uint256 totalAllocation, uint64 timestamp) internal view virtual returns (uint256) {
        if (timestamp < start()) {
            return 0;
        } else if (timestamp >= end()) {
            return totalAllocation;
        }
        return (totalAllocation * (timestamp - start())) / duration();
    }

    /**
     * @notice Verifies that the caller is authorized to cancel the contract
     * @dev Only the creator (Ecosystem contract) is authorized to cancel
     */
    function _checkAuthorized() internal view virtual {
        if (_creator != _msgSender()) {
            revert Unauthorized();
        }
    }
}
