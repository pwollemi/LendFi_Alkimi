// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;
/**
 * @title Lendefi DAO Cross-Chain Bridge
 * @notice Secure cross-chain token bridge with advanced security features
 * @dev Implements a secure, upgradeable bridge with transaction management
 * @custom:security-contact security@alkimi.org
 * @custom:copyright Copyright (c) 2025 Alkimi Finance Org. All rights reserved.
 */

import {IBRIDGE} from "../interfaces/IBridge.sol";
import {IERC20Bridgable} from "../interfaces/IERC20Bridgable.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

/// @custom:oz-upgrades
contract Bridge is
    IBRIDGE,
    Initializable,
    PausableUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableSet for EnumerableSet.UintSet;
    using SafeERC20 for IERC20Bridgable;

    // ============ Constants ============

    /// @dev AccessControl Pauser Role
    bytes32 internal constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    /// @dev AccessControl Manager Role
    bytes32 internal constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    /// @dev AccessControl Upgrader Role
    bytes32 internal constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    /// @dev AccessControl Relayer Role - for trusted cross-chain relayers
    bytes32 internal constant RELAYER_ROLE = keccak256("RELAYER_ROLE");
    /// @dev Fee basis points (10000 = 100%)
    uint16 internal constant BASIS_POINTS = 10000;
    /// @dev Default transaction timeout (7 days)
    uint256 internal constant DEFAULT_TIMEOUT = 7 days;
    /// @dev Default fee in basis points (0.1%)
    uint16 internal constant DEFAULT_FEE_BP = 10;
    /// @dev Default hourly transaction limit
    uint256 internal constant DEFAULT_HOURLY_LIMIT = 1000;
    /// @dev Default required confirmations
    uint8 internal constant DEFAULT_REQUIRED_CONFIRMATIONS = 3;
    /// @dev Default challenge threshold (1000 tokens)
    uint256 internal constant DEFAULT_CHALLENGE_THRESHOLD = 1000 ether;

    // ============ Structs ============

    /// @dev Extended Transaction struct with status and expiry
    struct ExtendedTransaction {
        address sender; // Source address
        address recipient; // Destination address
        address token; // Token address
        uint256 amount; // Amount of tokens
        uint256 timestamp; // Transaction timestamp
        uint256 destChainId; // Destination chain ID for outbound txs
        uint256 sourceChainId; // Source chain ID for inbound txs
        TransactionStatus status; // Transaction status
        uint256 expiresAt; // Expiration timestamp
        uint256 fee; // Fee amount
        bool isInbound; // Whether this is an inbound transaction
    }

    // ============ Storage Variables ============

    /// @dev EnumerableSet of supported tokens
    EnumerableSet.AddressSet internal tokenSet;

    /// @dev EnumerableSet of supported chains
    EnumerableSet.UintSet internal chainSet;

    /// @dev stores last transaction ID
    uint256 public transactionId;

    /// @dev chain transaction count, by chainId
    mapping(uint256 chainId => uint256 count) public chainCount;

    /// @dev Chain object by chainId mapping
    mapping(uint256 chainId => Chain) public chains;

    /// @dev supported tokens mapping
    mapping(address asset => Token) public tokens;

    /// @dev Transaction by ID mapping
    mapping(uint256 id => ExtendedTransaction) private transactions;

    /// @dev Number of UUPS upgrades
    uint32 public version;

    /// @dev Transaction timeout in seconds (default 7 days)
    uint256 public transactionTimeout;

    /// @dev Fee in basis points (default 0.1% = 10 basis points)
    uint16 public feeBasisPoints;

    /// @dev Rate limiting: max transactions per hour
    uint256 public hourlyTransactionLimit;

    /// @dev Rate limiting: transactions in the current hour
    uint256 public currentHourlyTransactions;

    /// @dev Rate limiting: current hour timestamp
    uint256 public currentHourTimestamp;

    /// @dev Fee collector address
    address public feeCollector;

    /// @dev Accumulated fees by token
    mapping(address token => uint256 amount) public accumulatedFees;

    /// @dev Required confirmations for large transactions
    uint8 public requiredConfirmations;

    /// @dev Challenge amount threshold - amounts above this require confirmations
    uint256 public challengeThreshold;

    /// @dev Challenge confirmations mapping
    mapping(uint256 txId => uint8 confirmations) public confirmations;

    /// @dev Challenge confirmation status mapping
    mapping(uint256 txId => mapping(address relayer => bool hasConfirmed)) public hasConfirmed;

    /// @dev Reserved space for future upgrades
    uint256[45] private __gap;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @dev Initializes the UUPS contract
     * @param guardian Admin address
     * @param timelock Governance timelock address
     * @param feeRecipient Address to collect fees
     */
    function initialize(address guardian, address timelock, address feeRecipient) external initializer {
        if (guardian == address(0)) revert ZeroAddress();
        if (timelock == address(0)) revert ZeroAddress();
        if (feeRecipient == address(0)) revert ZeroAddress();

        __Pausable_init();
        __AccessControl_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        _grantRole(DEFAULT_ADMIN_ROLE, guardian);
        _grantRole(MANAGER_ROLE, timelock);
        _grantRole(PAUSER_ROLE, guardian);

        // Initialize default settings
        transactionTimeout = DEFAULT_TIMEOUT;
        feeBasisPoints = DEFAULT_FEE_BP;
        hourlyTransactionLimit = DEFAULT_HOURLY_LIMIT;
        currentHourlyTransactions = 0;
        currentHourTimestamp = block.timestamp;
        feeCollector = feeRecipient;
        requiredConfirmations = DEFAULT_REQUIRED_CONFIRMATIONS;
        challengeThreshold = DEFAULT_CHALLENGE_THRESHOLD;

        ++version;
        emit Initialized(msg.sender);
    }

    /**
     * @dev Adds token to listed tokens.
     * @param name Token name
     * @param symbol Token symbol
     * @param token Token address
     */
    function listToken(string calldata name, string calldata symbol, address token)
        external
        whenNotPaused
        onlyRole(MANAGER_ROLE)
    {
        // Input validation
        if (token == address(0)) revert ZeroAddress();
        if (tokenSet.contains(token)) revert CustomError("TOKEN_ALREADY_LISTED");

        // Create token record
        Token storage item = tokens[token];
        item.name = name;
        item.symbol = symbol;
        item.tokenAddress = token;

        // Add to set
        if (!tokenSet.add(token)) revert CustomError("LISTING_FAILED");

        emit ListToken(token);
    }

    /**
     * @dev Removes token from listed tokens.
     * @param token Token address
     */
    function removeToken(address token) external whenNotPaused onlyRole(MANAGER_ROLE) {
        // Verify token is listed
        if (!tokenSet.contains(token)) revert TokenNotListed();

        // Remove token record
        delete tokens[token];

        // Remove from set
        if (!tokenSet.remove(token)) revert CustomError("REMOVAL_FAILED");

        emit DelistToken(token);
    }

    /**
     * @dev Bridge function for outbound token transfers.
     * @param token Token address
     * @param to Recipient address
     * @param amount Amount to bridge
     * @param destChainId Destination chain ID
     * @return id Transaction ID
     */
    function bridgeTokens(address token, address to, uint256 amount, uint256 destChainId)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 id)
    {
        // Input validation
        if (token == address(0)) revert ZeroAddress();
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        // Verify token and chain are supported
        if (!tokenSet.contains(token)) revert TokenNotListed();
        if (!chainSet.contains(destChainId)) revert ChainNotSupported();

        // Check rate limiting
        _checkAndUpdateRateLimit();

        // Ensure the sender has enough tokens
        IERC20Bridgable tokenContract = IERC20Bridgable(payable(token));
        if (tokenContract.balanceOf(msg.sender) < amount) revert InsufficientBalance();

        // Calculate fee
        uint256 fee = (amount * feeBasisPoints) / BASIS_POINTS;
        uint256 amountAfterFee = amount - fee;

        // Create transaction record
        id = ++transactionId;
        chainCount[destChainId]++;

        transactions[id] = ExtendedTransaction({
            sender: msg.sender,
            recipient: to,
            token: token,
            amount: amountAfterFee,
            timestamp: block.timestamp,
            destChainId: destChainId,
            sourceChainId: block.chainid, // Current chain is the source
            status: TransactionStatus.Pending,
            expiresAt: block.timestamp + transactionTimeout,
            fee: fee,
            isInbound: false
        });

        // Collect fee
        if (fee > 0) {
            accumulatedFees[token] += fee;
        }

        // Handle large transaction confirmations
        if (amount >= challengeThreshold) {
            confirmations[id] = 0;
            emit TransactionStatusUpdated(id, TransactionStatus.Pending);
        } else {
            // Automatically mark smaller transactions as completed
            transactions[id].status = TransactionStatus.Completed;
            emit TransactionStatusUpdated(id, TransactionStatus.Completed);
        }

        // Emit outbound event before token transfer to prevent reentrancy risk
        emit BridgeOutbound(id, msg.sender, to, token, amountAfterFee, fee, destChainId);

        // Transfer and burn tokens - do this last to follow CEI pattern
        tokenContract.safeTransferFrom(msg.sender, address(this), amount);
        tokenContract.burn(amountAfterFee);

        return id;
    }

    /**
     * @dev Processes an inbound bridge request (called by relayers).
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
    ) external nonReentrant whenNotPaused onlyRole(RELAYER_ROLE) returns (bool success) {
        // Input validation
        if (recipient == address(0)) revert ZeroAddress();
        if (token == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (!tokenSet.contains(token)) revert TokenNotListed();
        if (!chainSet.contains(sourceChainId)) revert ChainNotSupported();

        // Generate a deterministic transaction ID for the inbound transaction
        uint256 inboundTxId =
            uint256(keccak256(abi.encodePacked(sourceChainId, sourceTxId, sender, recipient, token, amount)));

        // Handle large amount confirmations
        if (amount >= challengeThreshold) {
            _processLargeInboundTransaction(inboundTxId, sender, recipient, token, amount, sourceChainId);

            // If not enough confirmations, return without minting
            if (confirmations[inboundTxId] < requiredConfirmations) {
                return true; // Success but pending more confirmations
            }
        }

        // Execute the token mint operation for the recipient
        IERC20Bridgable tokenContract = IERC20Bridgable(payable(token));
        tokenContract.bridgeMint(recipient, amount);

        // Update status if this was a large transaction
        if (amount >= challengeThreshold) {
            transactions[inboundTxId].status = TransactionStatus.Completed;
            emit TransactionStatusUpdated(inboundTxId, TransactionStatus.Completed);
        }

        // Emit event for the inbound bridge operation
        emit BridgeInbound(inboundTxId, sourceChainId, sender, recipient, token, amount);

        return true;
    }

    /**
     * @dev Internal function to handle large inbound transaction confirmations
     */
    function _processLargeInboundTransaction(
        uint256 inboundTxId,
        address sender,
        address recipient,
        address token,
        uint256 amount,
        uint256 sourceChainId
    ) internal {
        // If this is the first confirmation, initialize the transaction
        if (confirmations[inboundTxId] == 0) {
            transactions[inboundTxId] = ExtendedTransaction({
                sender: sender,
                recipient: recipient,
                token: token,
                amount: amount,
                timestamp: block.timestamp,
                destChainId: block.chainid, // Destination is current chain
                sourceChainId: sourceChainId, // Store the source chain ID
                status: TransactionStatus.Pending,
                expiresAt: block.timestamp + transactionTimeout,
                fee: 0,
                isInbound: true
            });
        }

        // Prevent double-confirmation
        if (hasConfirmed[inboundTxId][msg.sender]) revert AlreadyConfirmed();

        // Record confirmation
        hasConfirmed[inboundTxId][msg.sender] = true;
        confirmations[inboundTxId]++;

        // Emit confirmation event
        emit TransactionConfirmed(
            inboundTxId,
            msg.sender,
            sourceChainId, // Include the source chain ID
            confirmations[inboundTxId],
            requiredConfirmations
        );
    }

    /**
     * @dev Collects accumulated fees for a token.
     * @param token Token address
     */
    function collectFees(address token) external nonReentrant onlyRole(MANAGER_ROLE) {
        // Validate input
        if (!tokenSet.contains(token)) revert TokenNotListed();

        // Check fee amount
        uint256 amount = accumulatedFees[token];
        if (amount == 0) revert ZeroAmount();

        // Reset accumulated fees before transfer (CEI pattern)
        accumulatedFees[token] = 0;

        // Transfer fees to collector
        IERC20Bridgable tokenContract = IERC20Bridgable(payable(token));
        tokenContract.safeTransfer(feeCollector, amount);

        emit FeesCollected(token, amount, feeCollector);
    }

    /**
     * @dev Confirms a pending transaction (for large amounts).
     * @param txId Transaction ID
     */
    function confirmTransaction(uint256 txId) external nonReentrant onlyRole(RELAYER_ROLE) {
        ExtendedTransaction storage transaction = transactions[txId];

        // Validate transaction
        if (transaction.sender == address(0)) revert CustomError("TRANSACTION_NOT_FOUND");
        if (transaction.status != TransactionStatus.Pending) revert InvalidTransactionStatus();
        if (block.timestamp > transaction.expiresAt) revert TransactionExpired();
        if (hasConfirmed[txId][msg.sender]) revert AlreadyConfirmed();

        // Record confirmation
        hasConfirmed[txId][msg.sender] = true;
        confirmations[txId]++;

        // Use the appropriate chain ID for the event
        uint256 relevantChainId = transaction.isInbound ? transaction.sourceChainId : transaction.destChainId;

        emit TransactionConfirmed(txId, msg.sender, relevantChainId, confirmations[txId], requiredConfirmations);

        // If enough confirmations, mark as completed
        if (confirmations[txId] >= requiredConfirmations) {
            transaction.status = TransactionStatus.Completed;
            emit TransactionStatusUpdated(txId, TransactionStatus.Completed);
        }
    }

    /**
     * @dev Marks a transaction as expired if its timeout has passed.
     * @param txId Transaction ID
     */
    function expireTransaction(uint256 txId) external nonReentrant {
        ExtendedTransaction storage transaction = transactions[txId];

        // Validate transaction
        if (transaction.sender == address(0)) revert CustomError("TRANSACTION_NOT_FOUND");
        if (transaction.status != TransactionStatus.Pending) revert InvalidTransactionStatus();
        if (block.timestamp <= transaction.expiresAt) revert CustomError("NOT_EXPIRED_YET");

        // Update status
        transaction.status = TransactionStatus.Expired;
        emit TransactionStatusUpdated(txId, TransactionStatus.Expired);
    }

    /**
     * @dev Pause contract.
     */
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /**
     * @dev Unpause contract.
     */
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /**
     * @dev Updates bridge parameters.
     * @param paramName Name of the parameter to update
     * @param value New value
     */
    function updateBridgeParameter(string calldata paramName, uint256 value)
        external
        whenNotPaused
        onlyRole(MANAGER_ROLE)
    {
        bytes32 paramHash = keccak256(bytes(paramName));

        if (paramHash == keccak256(bytes("transactionTimeout"))) {
            // Minimum 1 hour, maximum 30 days
            if (value < 1 hours || value > 30 days) revert InvalidParameter();
            transactionTimeout = value;
        } else if (paramHash == keccak256(bytes("feeBasisPoints"))) {
            // Maximum fee 5%
            if (value > 500) revert InvalidParameter();
            feeBasisPoints = uint16(value);
        } else if (paramHash == keccak256(bytes("hourlyTransactionLimit"))) {
            if (value == 0) revert InvalidParameter();
            hourlyTransactionLimit = value;
        } else if (paramHash == keccak256(bytes("requiredConfirmations"))) {
            // At least 1, max 10 confirmations
            if (value < 1 || value > 10) revert InvalidParameter();
            requiredConfirmations = uint8(value);
        } else if (paramHash == keccak256(bytes("challengeThreshold"))) {
            challengeThreshold = value;
        } else {
            revert CustomError("UNKNOWN_PARAMETER");
        }

        emit BridgeParameterUpdated(paramName, value);
    }

    /**
     * @dev Updates the fee collector address.
     * @param newCollector New fee collector address
     */
    function updateFeeCollector(address newCollector) external whenNotPaused onlyRole(MANAGER_ROLE) {
        if (newCollector == address(0)) revert ZeroAddress();

        address oldCollector = feeCollector;
        feeCollector = newCollector;

        emit FeeCollectorUpdated(oldCollector, newCollector);
    }

    /**
     * @dev Add supported chain.
     * @param name Chain name
     * @param chainId Chain ID
     */
    function addChain(string calldata name, uint256 chainId) external whenNotPaused onlyRole(MANAGER_ROLE) {
        if (chainSet.contains(chainId)) revert CustomError("CHAIN_ALREADY_EXISTS");

        Chain storage item = chains[chainId];
        item.name = name;
        item.chainId = chainId;

        if (!chainSet.add(chainId)) revert CustomError("CHAIN_ADDITION_FAILED");

        emit AddChain(chainId);
    }

    /**
     * @dev Remove supported chain.
     * @param chainId Chain ID
     */
    function removeChain(uint256 chainId) external whenNotPaused onlyRole(MANAGER_ROLE) {
        if (!chainSet.contains(chainId)) revert ChainNotSupported();

        delete chains[chainId];

        if (!chainSet.remove(chainId)) revert CustomError("CHAIN_REMOVAL_FAILED");

        emit RemoveChain(chainId);
    }

    /**
     * @dev Get transaction details by ID
     * @param txId Transaction ID
     * @return details Complete transaction details including confirmation count
     */
    function getTransaction(uint256 txId) external view returns (TransactionDetails memory details) {
        ExtendedTransaction storage txn = transactions[txId];

        details.sender = txn.sender;
        details.recipient = txn.recipient;
        details.token = txn.token;
        details.amount = txn.amount;
        details.timestamp = txn.timestamp;
        details.destChainId = txn.destChainId;
        details.status = txn.status;
        details.expiresAt = txn.expiresAt;
        details.fee = txn.fee;
        details.confirmCount = confirmations[txId];

        return details;
    }

    /**
     * @dev Get extended transaction details by ID
     * @param txId Transaction ID
     * @return details Extended transaction details
     */
    function getExtendedTransaction(uint256 txId) external view returns (ExtendedTransactionDetails memory details) {
        ExtendedTransaction storage txn = transactions[txId];

        details.sender = txn.sender;
        details.recipient = txn.recipient;
        details.token = txn.token;
        details.amount = txn.amount;
        details.timestamp = txn.timestamp;
        details.destChainId = txn.destChainId;
        details.sourceChainId = txn.sourceChainId;
        details.status = txn.status;
        details.expiresAt = txn.expiresAt;
        details.fee = txn.fee;
        details.isInbound = txn.isInbound;
        details.confirmCount = confirmations[txId];

        return details;
    }

    /**
     * @dev Check if a relayer has confirmed a transaction.
     * @param txId Transaction ID
     * @param relayer Relayer address
     * @return Whether the relayer has confirmed
     */
    function hasRelayerConfirmed(uint256 txId, address relayer) external view returns (bool) {
        return hasConfirmed[txId][relayer];
    }

    /**
     * @dev Getter for the Token object.
     * @param token Token address
     * @return Token info object
     */
    function getToken(address token) external view returns (Token memory) {
        return tokens[token];
    }

    /**
     * @dev Getter for the supported token listings.
     * @return array of listed token addresses
     */
    function getListings() external view returns (address[] memory) {
        return tokenSet.values();
    }

    /**
     * @dev Getter returns true if token is listed.
     * @param token address
     * @return boolean value
     */
    function isListed(address token) external view returns (bool) {
        return tokenSet.contains(token);
    }

    /**
     * @dev Getter returns listed token count.
     * @return number of listed tokens
     */
    function getListedCount() external view returns (uint256) {
        return tokenSet.length();
    }

    /**
     * @dev Getter returns chain transaction count.
     * @param chainId Chain ID
     * @return number of transactions for this chain
     */
    function getChainTransactionCount(uint256 chainId) external view returns (uint256) {
        return chainCount[chainId];
    }

    /**
     * @dev Getter returns Chain object.
     * @param chainId Chain ID
     * @return Chain struct
     */
    function getChain(uint256 chainId) external view returns (Chain memory) {
        return chains[chainId];
    }

    /**
     * @dev Getter returns supported chain IDs.
     * @return Array of chain IDs
     */
    function getSupportedChains() external view returns (uint256[] memory) {
        return chainSet.values();
    }

    /**
     * @dev Internal function to check and update rate limits.
     */
    function _checkAndUpdateRateLimit() internal {
        // Reset counter if we're in a new hour
        if (block.timestamp >= currentHourTimestamp + 1 hours) {
            currentHourlyTransactions = 0;
            currentHourTimestamp = block.timestamp;
        }

        // Check if we've hit the rate limit
        if (currentHourlyTransactions >= hourlyTransactionLimit) {
            revert RateLimitExceeded();
        }

        // Increment transaction counter
        currentHourlyTransactions++;
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {
        if (newImplementation == address(0)) revert ZeroAddress();
        ++version;
        emit Upgrade(msg.sender, newImplementation);
    }
}
