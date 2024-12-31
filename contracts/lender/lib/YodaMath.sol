// SPDX-License-Identifier: GPL-v3.0
// Derived from https://github.com/dapphub/ds-math/
pragma solidity 0.8.23;
/**
 * @title Yoda Math Contract
 * @notice Compunding and beyond
 * @author Alkimi Finance Org
 * @custom:security-contact security@alkimi.org
 */

import {IYODAMATH} from "../../interfaces/IYodaMath.sol";

contract YodaMath is IYODAMATH {
    /// @dev base scale
    uint256 internal constant WAD = 1e6;
    /// @dev ray scale
    uint256 internal constant RAY = 1e27;
    /// @dev seconds per year on ray scale
    uint256 internal constant SECONDS_PER_YEAR_RAY = 365 * 86400 * RAY;

    /**
     * @dev rmul function
     * @param x amount
     * @param y amount
     * @return z value
     */
    function rmul(uint256 x, uint256 y) public pure returns (uint256 z) {
        z = ((x * y) + RAY / 2) / RAY;
    }

    /**
     * @dev rdiv function
     * @param x amount
     * @param y amount
     * @return z value
     */
    function rdiv(uint256 x, uint256 y) public pure returns (uint256 z) {
        z = ((x * RAY) + y / 2) / y;
    }

    /**
     * @dev rpow function - Calculates x raised to the power of n with RAY precision
     * @param x base value (in RAY precision)
     * @param n exponent
     * @return z result (in RAY precision)
     */
    function rpow(uint256 x, uint256 n) public pure returns (uint256 z) {
        // Initialize result to RAY (1.0 in ray precision)
        z = RAY;

        // Early return for x^0 = 1 and x^1 = x cases
        if (n == 0) {
            return z;
        }
        if (n == 1) {
            return x;
        }

        // Binary exponentiation algorithm
        while (n > 0) {
            // If the lowest bit of n is 1, multiply result by x
            if (n & 1 == 1) {
                z = rmul(z, x);
            }
            // Square the base
            x = rmul(x, x);
            // Shift n right by one bit (divide by 2)
            n = n >> 1;
        }
    }

    /**
     * @dev Converts rate to rateRay
     * @param rate rate
     * @return r rateRay
     */
    function annualRateToRay(uint256 rate) public pure returns (uint256 r) {
        r = RAY + rdiv((rate * RAY) / WAD, SECONDS_PER_YEAR_RAY);
    }

    /**
     * @dev Accrues compounded interest
     * @param principal amount
     * @param rateRay rateray
     * @param time duration
     * @return amount (pricipal + compounded interest)
     */
    function accrueInterest(uint256 principal, uint256 rateRay, uint256 time) public pure returns (uint256) {
        return rmul(principal, rpow(rateRay, time));
    }

    /**
     * @dev Calculates compounded interest
     * @param principal amount
     * @param rateRay rateray
     * @param time duration
     * @return amount (compounded interest)
     */
    function getInterest(uint256 principal, uint256 rateRay, uint256 time) public pure returns (uint256) {
        return rmul(principal, rpow(rateRay, time)) - principal;
    }

    /**
     * @dev Calculates breakeven borrow rate
     * @param loan amount
     * @param supplyInterest amount
     * @return breakeven borrow rate
     */
    function breakEvenRate(uint256 loan, uint256 supplyInterest) public pure returns (uint256) {
        return ((WAD * (loan + supplyInterest)) / loan) - WAD;
    }
}
