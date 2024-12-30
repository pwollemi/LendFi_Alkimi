// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;
/**
 * @title Flash Loan Interface
 * @custom:security-contact security@alkimi.org
 */

interface IFlashLoanReceiver {
    function executeOperation(address token, uint256 amount, uint256 fee, address initiator, bytes calldata params)
        external
        returns (bool);
}
