// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {IERC20Bridgable} from "../../contracts/interfaces/IERC20Bridgable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title MockBridgeableToken
 * @notice Mock token that implements IERC20Bridgable interface for testing
 */
contract MockBridgeableToken is ERC20, IERC20Bridgable {
    // Bridge role
    bytes32 public constant BRIDGE_ROLE = keccak256("BRIDGE_ROLE");

    // Role assignments
    mapping(address => bool) public bridges;

    // Bridge mint events
    event BridgeMint(address indexed src, address indexed to, uint256 amount);

    /**
     * @dev Constructor
     * @param name Token name
     * @param symbol Token symbol
     */
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    /**
     * @dev Mints tokens (for testing only)
     * @param to Address to mint tokens to
     * @param amount Amount of tokens to mint
     */
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /**
     * @dev Burns tokens
     * @param amount Amount of tokens to burn
     */
    function burn(uint256 amount) external override {
        _burn(msg.sender, amount);
    }

    /**
     * @dev Mints tokens from a bridge operation
     * @param to Recipient of the tokens
     * @param amount Amount to mint
     */
    function bridgeMint(address to, uint256 amount) external override {
        // In a real contract, we would check that msg.sender has BRIDGE_ROLE
        // For this mock, we'll just emit the event and mint
        emit BridgeMint(msg.sender, to, amount);
        _mint(to, amount);
    }

    /**
     * @dev Adds a bridge address
     * @param bridge Address to add as bridge
     */
    function addBridge(address bridge) external {
        bridges[bridge] = true;
    }

    /**
     * @dev Removes a bridge address
     * @param bridge Address to remove as bridge
     */
    function removeBridge(address bridge) external {
        bridges[bridge] = false;
    }
}
