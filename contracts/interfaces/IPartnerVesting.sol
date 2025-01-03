// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

/**
 * @title Partner Vesting Interface
 * @notice Interface for partner vesting contracts with cancellation capabilities
 */
interface IPARTNERVESTING {
    /**
     * @notice Emitted when the vesting contract is initialized
     * @param token Address of the ERC20 token being vested
     * @param beneficiary Address that will receive the vested tokens
     * @param timelock Address of the governance timelock
     * @param startTimestamp When the vesting schedule starts
     * @param duration Length of the vesting period in seconds
     */
    event VestingInitialized(
        address indexed token,
        address indexed beneficiary,
        address indexed timelock,
        uint64 startTimestamp,
        uint64 duration
    );

    /**
     * @notice Emitted when the vesting contract is cancelled
     * @param remainingTokens Amount of unvested tokens returned to the creator
     */
    event Cancelled(uint256 remainingTokens);

    /**
     * @notice Emitted when tokens are released to the beneficiary
     * @param token Address of the ERC20 token being released
     * @param amount Amount of tokens released
     */
    event ERC20Released(address indexed token, uint256 amount);

    /**
     * @notice Unauthorized access attempt
     * @dev Thrown when a function restricted to the creator is called by someone else
     */
    error Unauthorized();

    /**
     * @notice Zero address provided for a critical parameter
     * @dev Thrown when token, timelock, or beneficiary address is zero
     */
    error ZeroAddress();

    /**
     * @notice Cancels the vesting contract and returns unvested funds to timelock
     * @dev Only callable by timelock
     */
    function cancelContract() external returns (uint256);

    /**
     * @notice Releases vested tokens to the beneficiary (partner)
     */
    function release() external;

    /**
     * @notice Returns the amount of tokens that can be released at the current time
     * @return The amount of releasable tokens
     */
    function releasable() external view returns (uint256);

    /**
     * @notice Returns the start time of the vesting period
     * @return The start timestamp
     */
    function start() external view returns (uint256);

    /**
     * @notice Returns the duration of the vesting period in seconds
     * @return The duration in seconds
     */
    function duration() external view returns (uint256);

    /**
     * @notice Returns the end time of the vesting period
     * @return The end timestamp
     */
    function end() external view returns (uint256);

    /**
     * @notice Returns the amount of tokens already released
     * @return The amount of tokens released
     */
    function released() external view returns (uint256);
}
