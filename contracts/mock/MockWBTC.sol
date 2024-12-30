// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title MockWBTC
 * @notice A mock WBTC token with 8 decimals for testing purposes
 */
contract MockWBTC is ERC20 {
    constructor() ERC20("Wrapped Bitcoin", "WBTC") {}

    /**
     * @dev Override to return 8 decimals instead of the default 18
     */
    function decimals() public pure override returns (uint8) {
        return 8;
    }

    /**
     * @dev Mint tokens for testing
     */
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
