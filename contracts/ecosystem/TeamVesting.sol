// SPDX-License-Identifier: MIT
// Derived from OpenZeppelin Contracts (last updated v5.0.0) (finance/VestingWallet.sol)
pragma solidity 0.8.23;
/**
 * @title Lendefi DAO Team Vesting Contract
 * @notice Cancellable Vesting contract
 * @notice Offers flexible withdrawal schedule (gas efficient)
 * @dev Implements secure linear vesting for the DAO team
 * @custom:security-contact security@alkimi.org
 */

import {ITEAMVESTING} from "../interfaces/ITeamVesting.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Context} from "@openzeppelin/contracts/utils/Context.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract TeamVesting is ITEAMVESTING, Context, Ownable2Step, ReentrancyGuard {
    /// @dev start timestamp
    uint64 private immutable _start;
    /// @dev duration seconds
    uint64 private immutable _duration;
    /// @dev token address
    address private immutable _token;
    /// @dev timelock address
    address public immutable _timelock;
    /// @dev amount of tokens released
    mapping(address token => uint256 amount) private _erc20Released;

    /**
     * @dev Throws if called by any account other than the owner.
     */
    modifier onlyTimelock() {
        _checkTimelock();
        _;
    }

    /**
     * @dev Sets the owner to beneficiary address, the start timestamp and the
     * vesting duration of the vesting contract.
     */
    constructor(address token, address timelock, address beneficiary, uint64 startTimestamp, uint64 durationSeconds)
        payable
        Ownable(beneficiary)
    {
        require(token != address(0x0) && timelock != address(0x0) && beneficiary != address(0x0), "ZERO_ADDRESS");
        _token = token;
        _timelock = timelock;
        _start = startTimestamp;
        _duration = durationSeconds;
    }

    /**
     * @dev Allows the DAO to cancel the contract in case the team member is fired.
     *      Release vested amount and refund the remainder to timelock.
     *      Can be called multiple times but will only transfer remaining balance.
     */
    function cancelContract() external nonReentrant onlyTimelock {
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
            SafeERC20.safeTransfer(tokenInstance, _timelock, remainder);
        }
    }

    /**
     * @dev Release the tokens that have already vested.
     *
     * Emits a {ERC20Released} event.
     */
    function release() public virtual {
        uint256 amount = releasable();
        _erc20Released[_token] += amount;
        emit ERC20Released(_token, amount);
        SafeERC20.safeTransfer(IERC20(_token), owner(), amount);
    }

    /**
     * @dev Getter for the start timestamp.
     * @return start timestamp
     */
    function start() public view virtual returns (uint256) {
        return _start;
    }

    /**
     * @dev Getter for the vesting duration.
     * @return duration seconds
     */
    function duration() public view virtual returns (uint256) {
        return _duration;
    }

    /**
     * @dev Getter for the end timestamp.
     * @return end timestamp
     */
    function end() public view virtual returns (uint256) {
        return start() + duration();
    }

    /**
     * @dev Getter for the amount of token already released
     * @return amount of tokens released so far
     */
    function released() public view virtual returns (uint256) {
        return _erc20Released[_token];
    }

    /**
     * @dev Getter for the amount of releasable `token` ERC20 tokens.
     * @return amount of vested tokens
     */
    function releasable() public view virtual returns (uint256) {
        return vestedAmount(SafeCast.toUint64(block.timestamp)) - released();
    }

    /**
     * @dev Throws if the sender is not the timelock.
     */
    function _checkTimelock() internal view virtual {
        if (_timelock != _msgSender()) {
            revert CustomError("UNAUTHORIZED");
        }
    }

    /**
     * @dev Calculates the amount of tokens that has already vested. Default implementation is a linear vesting curve.
     * @param timestamp current timestamp
     * @return amount vested
     */
    function vestedAmount(uint64 timestamp) internal view virtual returns (uint256) {
        return _vestingSchedule(IERC20(_token).balanceOf(address(this)) + released(), timestamp);
    }

    /**
     * @dev Virtual implementation of the vesting formula. This returns the amount vested, as a function of time, for
     * an asset given its total historical allocation.
     * @param totalAllocation initial amount
     * @param timestamp current timestamp
     * @return amount vested
     */
    function _vestingSchedule(uint256 totalAllocation, uint64 timestamp) internal view virtual returns (uint256) {
        if (timestamp < start()) {
            return 0;
        } else if (timestamp >= end()) {
            return totalAllocation;
        }
        return (totalAllocation * (timestamp - start())) / duration();
    }
}
