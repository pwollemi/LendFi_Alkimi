// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;
/**
 * @title Bridge Interface
 * @author Alkimi Finance Org LLC
 * @custom:security-contact security@alkimi.org
 * @custom:copyright Copyright (c) 2025 Alkimi Finance Org. All rights reserved.
 */

interface IBRIDGE {
    // ============ Structs & Enums ============

    /**
     * @dev Token information struct.
     * @param name Token name
     * @param symbol Token symbol
     * @param tokenAddress Token contract address
     */
    struct Token {
        string name;
        string symbol;
        address tokenAddress;
    }

    /**
     * @dev Chain information struct.
     * @param name Chain name
     * @param chainId Chain ID
     */
    struct Chain {
        string name;
        uint256 chainId;
    }

    /**
     * @dev Transaction status enum.
     */
    enum TransactionStatus {
        Pending,
        Completed,
        Failed,
        Expired
    }

    /**
     * @dev Transaction details struct for external viewing.
     * @notice Contains all transaction data including confirmations
     */
    struct TransactionDetails {
        address sender;
        address recipient;
        address token;
        uint256 amount;
        uint256 timestamp;
        uint256 destChainId;
        TransactionStatus status;
        uint256 expiresAt;
        uint256 fee;
        uint8 confirmCount;
    }
    /**
     * @dev Extended transaction details struct with additional chain information.
     * @notice Contains all transaction data including source chain and inbound flag
     */

    struct ExtendedTransactionDetails {
        address sender;
        address recipient;
        address token;
        uint256 amount;
        uint256 timestamp;
        uint256 destChainId;
        uint256 sourceChainId;
        TransactionStatus status;
        uint256 expiresAt;
        uint256 fee;
        bool isInbound;
        uint8 confirmCount;
    }
    // ============ Events ============

    /**
     * @dev Emitted when contract is initialized.
     * @param src Initializer address
     */
    event Initialized(address indexed src);

    /**
     * @dev Emitted when contract is upgraded.
     * @param src Upgrader address
     * @param implementation New implementation address
     */
    event Upgrade(address indexed src, address indexed implementation);

    /**
     * @dev Emitted when a token is listed.
     * @param token Listed token address
     */
    event ListToken(address indexed token);

    /**
     * @dev Emitted when a token is delisted.
     * @param token Delisted token address
     */
    event DelistToken(address indexed token);

    /**
     * @dev Emitted when tokens are bridged to another chain.
     * @param id Transaction ID
     * @param sender Source address
     * @param recipient Destination address
     * @param token Token address
     * @param amount Amount of tokens (after fee)
     * @param fee Fee amount
     * @param destChainId Destination chain ID
     */
    event BridgeOutbound(
        uint256 indexed id,
        address indexed sender,
        address indexed recipient,
        address token,
        uint256 amount,
        uint256 fee,
        uint256 destChainId
    );

    /**
     * @dev Emitted when tokens are received from another chain.
     * @param id Transaction ID
     * @param sourceChainId Source chain ID
     * @param sender Source address
     * @param recipient Destination address
     * @param token Token address
     * @param amount Amount of tokens
     */
    event BridgeInbound(
        uint256 indexed id,
        uint256 indexed sourceChainId,
        address indexed sender,
        address recipient,
        address token,
        uint256 amount
    );

    /**
     * @dev Emitted when a transaction status is updated.
     * @param id Transaction ID
     * @param status New transaction status
     */
    event TransactionStatusUpdated(uint256 indexed id, TransactionStatus status);

    /**
     * @dev Emitted when a transaction is confirmed by a relayer.
     * @param id Transaction ID
     * @param relayer Relayer address
     * @param sourceChainId Origin chain ID (for inbound transactions)
     * @param confirmationsCount Current confirmation count
     * @param requiredConfirmations Required confirmation count
     */
    event TransactionConfirmed(
        uint256 indexed id,
        address indexed relayer,
        uint256 indexed sourceChainId,
        uint8 confirmationsCount,
        uint8 requiredConfirmations
    );

    /**
     * @dev Emitted when fees are collected.
     * @param token Token address
     * @param amount Fee amount
     * @param recipient Fee recipient
     */
    event FeesCollected(address indexed token, uint256 amount, address indexed recipient);

    /**
     * @dev Emitted when a bridge parameter is updated.
     * @param param Parameter name
     * @param value New value
     */
    event BridgeParameterUpdated(string indexed param, uint256 value);

    /**
     * @dev Emitted when the fee collector is updated.
     * @param oldCollector Previous fee collector
     * @param newCollector New fee collector
     */
    event FeeCollectorUpdated(address indexed oldCollector, address indexed newCollector);

    /**
     * @dev Emitted when a chain is added to supported chains.
     * @param chainId Added chain ID
     */
    event AddChain(uint256 chainId);

    /**
     * @dev Emitted when a chain is removed from supported chains.
     * @param chainId Removed chain ID
     */
    event RemoveChain(uint256 chainId);

    // ============ Errors ============

    /**
     * @dev Error for generic errors with custom message.
     * @param msg Error message
     */
    error CustomError(string msg);

    /**
     * @dev Error for zero address inputs.
     */
    error ZeroAddress();

    /**
     * @dev Error for zero amount inputs.
     */
    error ZeroAmount();

    /**
     * @dev Error when token is not listed.
     */
    error TokenNotListed();

    /**
     * @dev Error when chain is not supported.
     */
    error ChainNotSupported();

    /**
     * @dev Error when sender has insufficient balance.
     */
    error InsufficientBalance();

    /**
     * @dev Error when hourly transaction limit is exceeded.
     */
    error RateLimitExceeded();

    /**
     * @dev Error when transaction requires more confirmations.
     */
    error PendingConfirmations();

    /**
     * @dev Error when transaction status is invalid for the operation.
     */
    error InvalidTransactionStatus();

    /**
     * @dev Error when transaction has expired.
     */
    error TransactionExpired();

    /**
     * @dev Error when relayer has already confirmed a transaction.
     */
    error AlreadyConfirmed();

    /**
     * @dev Error when parameter value is invalid.
     */
    error InvalidParameter();

    // ============ Functions ============

    /**
     * @dev Initializes the bridge contract.
     * @param guardian Admin address
     * @param timelock Governance timelock address
     * @param feeRecipient Address to collect fees
     */
    function initialize(address guardian, address timelock, address feeRecipient) external;

    /**
     * @dev Pauses the contract.
     */
    function pause() external;

    /**
     * @dev Unpauses the contract.
     */
    function unpause() external;

    /**
     * @dev Lists a token for bridging.
     * @param name Token name
     * @param symbol Token symbol
     * @param token Token address
     */
    function listToken(string calldata name, string calldata symbol, address token) external;

    /**
     * @dev Removes a token from bridging.
     * @param token Token address
     */
    function removeToken(address token) external;

    /**
     * @dev Bridge tokens to another chain.
     * @param token Token address
     * @param to Recipient address
     * @param amount Amount to bridge
     * @param destChainId Destination chain ID
     * @return id Transaction ID
     */
    function bridgeTokens(address token, address to, uint256 amount, uint256 destChainId)
        external
        returns (uint256 id);

    /**
     * @dev Process an inbound bridge request.
     * @param sourceChainId Source chain ID
     * @param sourceTxId Original transaction ID on source chain
     * @param sender Sender on source chain
     * @param recipient Recipient on this chain
     * @param token Token address
     * @param amount Amount to mint
     * @return success Whether the operation succeeded
     */
    function processBridgeInbound(
        uint256 sourceChainId,
        uint256 sourceTxId,
        address sender,
        address recipient,
        address token,
        uint256 amount
    ) external returns (bool success);

    /**
     * @dev Collects accumulated fees for a token.
     * @param token Token address
     */
    function collectFees(address token) external;

    /**
     * @dev Confirms a pending transaction.
     * @param txId Transaction ID
     */
    function confirmTransaction(uint256 txId) external;

    /**
     * @dev Marks a transaction as expired if its timeout has passed.
     * @param txId Transaction ID
     */
    function expireTransaction(uint256 txId) external;

    /**
     * @dev Updates bridge parameters.
     * @param paramName Name of the parameter to update
     * @param value New value
     */
    function updateBridgeParameter(string calldata paramName, uint256 value) external;

    /**
     * @dev Updates the fee collector address.
     * @param newCollector New fee collector address
     */
    function updateFeeCollector(address newCollector) external;

    /**
     * @dev Adds a supported chain.
     * @param name Chain name
     * @param chainId Chain ID
     */
    function addChain(string calldata name, uint256 chainId) external;

    /**
     * @dev Removes a supported chain.
     * @param chainId Chain ID
     */
    function removeChain(uint256 chainId) external;

    /**
     * @dev Gets transaction details by ID.
     * @param txId Transaction ID
     * @return details Complete transaction details
     */
    function getTransaction(uint256 txId) external view returns (TransactionDetails memory details);

    /**
     * @dev Checks if a relayer has confirmed a transaction.
     * @param txId Transaction ID
     * @param relayer Relayer address
     * @return Whether the relayer has confirmed
     */
    function hasRelayerConfirmed(uint256 txId, address relayer) external view returns (bool);

    /**
     * @dev Gets token information.
     * @param token Token address
     * @return Token info object
     */
    function getToken(address token) external view returns (Token memory);

    /**
     * @dev Gets list of supported tokens.
     * @return Array of listed token addresses
     */
    function getListings() external view returns (address[] memory);

    /**
     * @dev Checks if a token is listed.
     * @param token Token address
     * @return Whether the token is listed
     */
    function isListed(address token) external view returns (bool);

    /**
     * @dev Gets number of listed tokens.
     * @return Number of listed tokens
     */
    function getListedCount() external view returns (uint256);

    /**
     * @dev Gets transaction count for a chain.
     * @param chainId Chain ID
     * @return Number of transactions for this chain
     */
    function getChainTransactionCount(uint256 chainId) external view returns (uint256);

    /**
     * @dev Gets chain information.
     * @param chainId Chain ID
     * @return Chain information
     */
    function getChain(uint256 chainId) external view returns (Chain memory);

    /**
     * @dev Gets list of supported chains.
     * @return Array of chain IDs
     */
    function getSupportedChains() external view returns (uint256[] memory);

    /**
     * @dev Gets accumulated fees for a token.
     * @param token Token address
     * @return Amount of accumulated fees
     */
    function accumulatedFees(address token) external view returns (uint256);

    /**
     * @dev Gets required confirmations for large transactions.
     * @return Number of required confirmations
     */
    function requiredConfirmations() external view returns (uint8);

    /**
     * @dev Gets fee basis points.
     * @return Fee in basis points (1 = 0.01%)
     */
    function feeBasisPoints() external view returns (uint16);

    /**
     * @dev Gets challenge threshold for large transactions.
     * @return Amount threshold for requiring confirmations
     */
    function challengeThreshold() external view returns (uint256);

    /**
     * @dev Gets extended transaction details by ID including source chain ID.
     * @param txId Transaction ID
     * @return details Extended transaction details including source chain and inbound status
     */
    function getExtendedTransaction(uint256 txId) external view returns (ExtendedTransactionDetails memory details);

    /**
     * @dev Gets contract version.
     * @return Contract version number
     */
    function version() external view returns (uint32);
}
