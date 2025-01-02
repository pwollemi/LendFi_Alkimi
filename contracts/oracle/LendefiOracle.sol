// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

import {AggregatorV3Interface} from "../vendor/@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

/**
 * @title Lendefi Oracle
 * @notice Secure price feed provider for Lendefi Protocol with robust validation
 * @dev Implements multi-oracle architecture with multiple security features:
 *      - Multiple price sources with median calculation
 *      - Configurable freshness thresholds
 *      - Volatility detection and protection
 *      - Circuit breakers for extreme price movements
 */
contract LendefiOracle is AccessControlUpgradeable, ReentrancyGuardUpgradeable, UUPSUpgradeable {
    // Roles
    bytes32 public constant ORACLE_MANAGER_ROLE = keccak256("ORACLE_MANAGER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant CIRCUIT_BREAKER_ROLE = keccak256("CIRCUIT_BREAKER_ROLE");

    // Time threshold configurations
    uint256 public freshnessThreshold; // Maximum age of price data (default: 8 hours)
    uint256 public volatilityThreshold; // Stricter freshness for volatile prices (default: 1 hour)

    // Percentage thresholds
    uint256 public volatilityPercentage; // Price change % that triggers volatility check (default: 20%)
    uint256 public circuitBreakerThreshold; // Price change % that triggers circuit breaker (default: 50%)

    // Oracle data structures
    mapping(address asset => address[] oracles) private assetOracles;
    mapping(address asset => address primary) public primaryOracle;
    mapping(address oracle => uint8 decimals) public oracleDecimals;

    // Circuit breaker and price history
    mapping(address asset => bool broken) public circuitBroken;
    mapping(address asset => uint256 price) public lastValidPrice;
    mapping(address asset => uint256 timestamp) public lastUpdateTimestamp;

    // Minimum oracle requirements
    uint256 public minimumOraclesRequired; // Minimum oracles required for reliable price (default: 2)
    mapping(address asset => uint256 minOraclesForAsset) public assetMinimumOracles;

    // Events
    event OracleAdded(address indexed asset, address indexed oracle);
    event OracleRemoved(address indexed asset, address indexed oracle);
    event PrimaryOracleSet(address indexed asset, address indexed oracle);
    event FreshnessThresholdUpdated(uint256 oldValue, uint256 newValue);
    event VolatilityThresholdUpdated(uint256 oldValue, uint256 newValue);
    event VolatilityPercentageUpdated(uint256 oldValue, uint256 newValue);
    event CircuitBreakerThresholdUpdated(uint256 oldValue, uint256 newValue);
    event CircuitBreakerTriggered(address indexed asset, uint256 currentPrice, uint256 previousPrice);
    event CircuitBreakerReset(address indexed asset);
    event PriceUpdated(address indexed asset, uint256 price, uint256 median, uint256 numOracles);
    event MinimumOraclesUpdated(uint256 oldValue, uint256 newValue);
    event AssetMinimumOraclesUpdated(address indexed asset, uint256 oldValue, uint256 newValue);
    event NotEnoughOraclesWarning(address indexed asset, uint256 required, uint256 actual);

    // Errors
    error OracleInvalidPrice(address oracle, int256 price);
    error OracleStalePrice(address oracle, uint80 roundId, uint80 answeredInRound);
    error OracleTimeout(address oracle, uint256 timestamp, uint256 currentTimestamp, uint256 maxAge);
    error OracleInvalidPriceVolatility(address oracle, int256 price, uint256 volatility);
    error OracleNotFound(address asset);
    error PrimaryOracleNotSet(address asset);
    error CircuitBreakerActive(address asset);
    error InvalidThreshold(string name, uint256 value, uint256 minValue, uint256 maxValue);
    error NotEnoughOracles(address asset, uint256 required, uint256 actual);
    error OracleAlreadyAdded(address asset, address oracle);
    error InvalidOracle(address oracle);
    error CircuitBreakerCooldown(address asset, uint256 remainingTime);
    error LargeDeviation(address asset, uint256 price, uint256 previousPrice, uint256 deviationPct);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the oracle module with default parameters
     * @param admin Address that will have DEFAULT_ADMIN_ROLE
     * @param manager Address that will have ORACLE_MANAGER_ROLE
     */
    function initialize(address admin, address manager) external initializer {
        __AccessControl_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ORACLE_MANAGER_ROLE, manager);
        _grantRole(UPGRADER_ROLE, admin);
        _grantRole(CIRCUIT_BREAKER_ROLE, manager);

        // Set default thresholds
        freshnessThreshold = 28800; // Maximum age of price data (8 hours)
        volatilityThreshold = 3600; // Stricter freshness for volatile prices (1 hour)
        volatilityPercentage = 20; // Price change % that triggers volatility check
        circuitBreakerThreshold = 50; // Price change % that triggers circuit breaker
        minimumOraclesRequired = 2; // Minimum 2 oracles for reliable price
    }

    /**
     * @notice Adds a new oracle for an asset
     * @param asset Address of the asset
     * @param oracle Address of the Chainlink price feed
     * @param oracleDecimalsValue Number of decimals in oracle price feed
     * @dev Adds a new price oracle to the array of oracles for the asset
     * @custom:access Restricted to ORACLE_MANAGER_ROLE
     */
    function addOracle(address asset, address oracle, uint8 oracleDecimalsValue)
        external
        onlyRole(ORACLE_MANAGER_ROLE)
    {
        if (oracle == address(0)) revert InvalidOracle(oracle);

        // Check if oracle is already added for this asset
        address[] storage oracles = assetOracles[asset];
        for (uint256 i = 0; i < oracles.length; i++) {
            if (oracles[i] == oracle) {
                revert OracleAlreadyAdded(asset, oracle);
            }
        }

        // Add the oracle
        oracles.push(oracle);
        oracleDecimals[oracle] = oracleDecimalsValue;

        // If this is the first oracle, set it as primary
        if (oracles.length == 1) {
            primaryOracle[asset] = oracle;
            emit PrimaryOracleSet(asset, oracle);
        }

        emit OracleAdded(asset, oracle);
    }

    /**
     * @notice Removes an oracle for an asset
     * @param asset Address of the asset
     * @param oracle Address of the Chainlink price feed to remove
     * @dev Removes oracle from the array of oracles for the asset
     * @custom:access Restricted to ORACLE_MANAGER_ROLE
     */
    function removeOracle(address asset, address oracle) external onlyRole(ORACLE_MANAGER_ROLE) {
        address[] storage oracles = assetOracles[asset];
        uint256 length = oracles.length;
        bool found = false;
        uint256 index = 0;

        // Find the oracle to remove
        for (uint256 i = 0; i < length; i++) {
            if (oracles[i] == oracle) {
                found = true;
                index = i;
                break;
            }
        }

        if (!found) revert OracleNotFound(asset);

        // If removing the primary oracle, set a new primary
        if (primaryOracle[asset] == oracle) {
            if (length > 1) {
                // Set the next oracle as primary, or the previous if removing the last one
                address newPrimary = index < length - 1 ? oracles[index + 1] : oracles[0];
                primaryOracle[asset] = newPrimary;
                emit PrimaryOracleSet(asset, newPrimary);
            } else {
                // If it's the only oracle, clear the primary
                delete primaryOracle[asset];
            }
        }

        // Remove the oracle by swapping with the last element and popping
        if (index < length - 1) {
            oracles[index] = oracles[length - 1];
        }
        oracles.pop();

        // Check if remaining oracles are sufficient
        uint256 minRequired = assetMinimumOracles[asset] > 0 ? assetMinimumOracles[asset] : minimumOraclesRequired;
        if (oracles.length < minRequired) {
            // Log a warning but allow the operation to complete
            emit NotEnoughOraclesWarning(asset, minRequired, oracles.length);
        }

        emit OracleRemoved(asset, oracle);
    }

    /**
     * @notice Sets the primary oracle for an asset
     * @param asset Address of the asset
     * @param oracle Address of the oracle to set as primary
     * @dev The primary oracle is used as a fallback when median calculation fails
     * @custom:access Restricted to ORACLE_MANAGER_ROLE
     */
    function setPrimaryOracle(address asset, address oracle) external onlyRole(ORACLE_MANAGER_ROLE) {
        address[] storage oracles = assetOracles[asset];
        bool found = false;

        for (uint256 i = 0; i < oracles.length; i++) {
            if (oracles[i] == oracle) {
                found = true;
                break;
            }
        }

        if (!found) revert OracleNotFound(asset);

        primaryOracle[asset] = oracle;
        emit PrimaryOracleSet(asset, oracle);
    }

    /**
     * @notice Updates the global minimum number of oracles required for reliable price
     * @param minimum New minimum number of oracles
     * @dev Minimum value is 1, applies to all assets unless overridden
     * @custom:access Restricted to ORACLE_MANAGER_ROLE
     */
    function updateMinimumOracles(uint256 minimum) external onlyRole(ORACLE_MANAGER_ROLE) {
        if (minimum < 1) {
            revert InvalidThreshold("minimumOracles", minimum, 1, type(uint256).max);
        }

        uint256 oldValue = minimumOraclesRequired;
        minimumOraclesRequired = minimum;
        emit MinimumOraclesUpdated(oldValue, minimum);
    }

    /**
     * @notice Updates the minimum number of oracles required for a specific asset
     * @param asset Address of the asset
     * @param minimum New minimum number of oracles for this asset
     * @dev Set to 0 to use the global default
     * @custom:access Restricted to ORACLE_MANAGER_ROLE
     */
    function updateAssetMinimumOracles(address asset, uint256 minimum) external onlyRole(ORACLE_MANAGER_ROLE) {
        uint256 oldValue = assetMinimumOracles[asset];
        assetMinimumOracles[asset] = minimum;
        emit AssetMinimumOraclesUpdated(asset, oldValue, minimum);
    }

    /**
     * @notice Updates the freshness threshold for price feeds
     * @param threshold New maximum age of price data in seconds
     * @dev Controls how old price data can be before rejection
     * @custom:access Restricted to ORACLE_MANAGER_ROLE
     */
    function updateFreshnessThreshold(uint256 threshold) external onlyRole(ORACLE_MANAGER_ROLE) {
        if (threshold < 15 minutes || threshold > 24 hours) {
            revert InvalidThreshold("freshness", threshold, 15 minutes, 24 hours);
        }

        uint256 oldValue = freshnessThreshold;
        freshnessThreshold = threshold;
        emit FreshnessThresholdUpdated(oldValue, threshold);
    }

    /**
     * @notice Updates the volatility time threshold
     * @param threshold New threshold for volatile asset prices in seconds
     * @dev Controls how old price data can be during high volatility
     * @custom:access Restricted to ORACLE_MANAGER_ROLE
     */
    function updateVolatilityThreshold(uint256 threshold) external onlyRole(ORACLE_MANAGER_ROLE) {
        if (threshold < 5 minutes || threshold > 4 hours) {
            revert InvalidThreshold("volatility", threshold, 5 minutes, 4 hours);
        }

        uint256 oldValue = volatilityThreshold;
        volatilityThreshold = threshold;
        emit VolatilityThresholdUpdated(oldValue, threshold);
    }

    /**
     * @notice Updates the volatility percentage threshold
     * @param percentage New percentage that triggers the volatility check
     * @dev Price changes above this percentage require fresher data
     * @custom:access Restricted to ORACLE_MANAGER_ROLE
     */
    function updateVolatilityPercentage(uint256 percentage) external onlyRole(ORACLE_MANAGER_ROLE) {
        if (percentage < 5 || percentage > 30) {
            revert InvalidThreshold("volatilityPercentage", percentage, 5, 30);
        }

        uint256 oldValue = volatilityPercentage;
        volatilityPercentage = percentage;
        emit VolatilityPercentageUpdated(oldValue, percentage);
    }

    /**
     * @notice Updates the circuit breaker threshold
     * @param percentage New percentage that triggers the circuit breaker
     * @dev Price changes above this percentage halt trading for the asset
     * @custom:access Restricted to ORACLE_MANAGER_ROLE
     */
    function updateCircuitBreakerThreshold(uint256 percentage) external onlyRole(ORACLE_MANAGER_ROLE) {
        if (percentage < 25 || percentage > 70) {
            revert InvalidThreshold("circuitBreaker", percentage, 25, 70);
        }

        uint256 oldValue = circuitBreakerThreshold;
        circuitBreakerThreshold = percentage;
        emit CircuitBreakerThresholdUpdated(oldValue, percentage);
    }

    /**
     * @notice Gets the median price from multiple oracles for an asset
     * @param asset Address of the asset
     * @return uint256 Median price in USD with 8 decimals
     * @dev Main function for external protocols to get verified asset prices
     * @custom:security Implements comprehensive validation and multiple oracle sources
     */
    function getAssetPrice(address asset) external returns (uint256) {
        return _getMedianPrice(asset);
    }

    /**
     * @notice Gets the number of oracles for an asset
     * @param asset Address of the asset
     * @return uint256 Number of oracles configured for the asset
     */
    function getOracleCount(address asset) external view returns (uint256) {
        return assetOracles[asset].length;
    }

    /**
     * @notice Gets all oracles for an asset
     * @param asset Address of the asset
     * @return address[] Array of oracle addresses for the asset
     */
    function getAssetOracles(address asset) external view returns (address[] memory) {
        return assetOracles[asset];
    }

    /**
     * @notice Manually triggers the circuit breaker for an asset
     * @param asset Address of the asset
     * @dev Used in emergency situations to pause asset trading
     * @custom:access Restricted to CIRCUIT_BREAKER_ROLE
     */
    function triggerCircuitBreaker(address asset) external onlyRole(CIRCUIT_BREAKER_ROLE) {
        circuitBroken[asset] = true;
        emit CircuitBreakerTriggered(asset, 0, 0);
    }

    /**
     * @notice Resets the circuit breaker for an asset
     * @param asset Address of the asset
     * @dev Allows trading to resume after manual review
     * @custom:access Restricted to CIRCUIT_BREAKER_ROLE
     */
    function resetCircuitBreaker(address asset) external onlyRole(CIRCUIT_BREAKER_ROLE) {
        circuitBroken[asset] = false;
        emit CircuitBreakerReset(asset);
    }

    /**
     * @notice Gets the price from a single oracle with safety validations
     * @param oracleAddress Address of the Chainlink price feed
     * @return uint256 Price in USD with oracle's native decimal precision
     * @dev Internal function with extensive validation
     */
    function _getSingleOraclePrice(address oracleAddress) internal view returns (uint256) {
        // Fetch latest data from Chainlink oracle
        (uint80 roundId, int256 price,, uint256 timestamp, uint80 answeredInRound) =
            AggregatorV3Interface(oracleAddress).latestRoundData();

        // Core validations - price must be positive
        if (price <= 0) {
            revert OracleInvalidPrice(oracleAddress, price);
        }

        // Ensure round is complete and answered
        if (answeredInRound < roundId) {
            revert OracleStalePrice(oracleAddress, roundId, answeredInRound);
        }

        // Verify price data freshness - must be less than configured threshold
        uint256 age = block.timestamp - timestamp;
        if (age > freshnessThreshold) {
            revert OracleTimeout(oracleAddress, timestamp, block.timestamp, freshnessThreshold);
        }

        // Volatility protection - for significant price movements, enforce stricter freshness
        if (roundId > 1) {
            // Fetch previous round data to compare
            (, int256 previousPrice,, uint256 previousTimestamp,) =
                AggregatorV3Interface(oracleAddress).getRoundData(roundId - 1);

            // Only evaluate valid historical data points
            if (previousPrice > 0 && previousTimestamp > 0) {
                uint256 currentPrice = uint256(price);
                uint256 prevPrice = uint256(previousPrice);

                // Calculate price change percentage
                uint256 priceDelta = currentPrice > prevPrice ? currentPrice - prevPrice : prevPrice - currentPrice;
                uint256 changePercent = (priceDelta * 100) / prevPrice;

                // For high volatility, require fresher data
                if (changePercent >= volatilityPercentage && age >= volatilityThreshold) {
                    revert OracleInvalidPriceVolatility(oracleAddress, price, changePercent);
                }
            }
        }

        return uint256(price);
    }

    /**
     * @notice Calculates the median price from multiple oracles
     * @param asset Address of the asset
     * @return median Median price in USD with 8 decimals
     * @dev Uses multiple oracles and fallback mechanisms
     */
    function _getMedianPrice(address asset) internal returns (uint256 median) {
        address[] storage oracles = assetOracles[asset];
        uint256 length = oracles.length;

        // Check if circuit breaker is active
        if (circuitBroken[asset]) {
            revert CircuitBreakerActive(asset);
        }

        // Check minimum oracle requirements
        uint256 minRequired = assetMinimumOracles[asset] > 0 ? assetMinimumOracles[asset] : minimumOraclesRequired;
        if (length < minRequired) {
            revert NotEnoughOracles(asset, minRequired, length);
        }

        // For a single oracle, just return its price
        if (length == 1) {
            return _getSingleOraclePrice(oracles[0]);
        }

        // For multiple oracles, collect valid prices
        uint256[] memory prices = new uint256[](length);
        uint256 validCount = 0;

        for (uint256 i = 0; i < length; i++) {
            try this.getSingleOraclePrice(oracles[i]) returns (uint256 price) {
                prices[validCount] = price;
                validCount++;
            } catch {
                // Skip invalid oracles - they'll be excluded from the median
            }
        }

        // Check if we have enough valid prices
        if (validCount < minRequired) {
            // If primary oracle is set and valid, use it as fallback
            if (primaryOracle[asset] != address(0)) {
                try this.getSingleOraclePrice(primaryOracle[asset]) returns (uint256 price) {
                    return price;
                } catch {
                    // Primary oracle also failed
                }
            }

            // If we have a last valid price and it's recent enough, use it
            if (lastValidPrice[asset] > 0 && block.timestamp - lastUpdateTimestamp[asset] <= freshnessThreshold) {
                return lastValidPrice[asset];
            }

            revert NotEnoughOracles(asset, minRequired, validCount);
        }

        // Sort prices to find median
        _sortPrices(prices, 0, int256(validCount) - 1);

        // Calculate median
        if (validCount % 2 == 0) {
            // Even number - average the middle two
            uint256 mid1 = prices[validCount / 2 - 1];
            uint256 mid2 = prices[validCount / 2];
            median = (mid1 + mid2) / 2;
        } else {
            // Odd number - use middle value
            median = prices[validCount / 2];
        }

        // Circuit breaker check against last valid price
        if (lastValidPrice[asset] > 0) {
            uint256 priceDelta =
                median > lastValidPrice[asset] ? median - lastValidPrice[asset] : lastValidPrice[asset] - median;
            uint256 changePercent = (priceDelta * 100) / lastValidPrice[asset];

            if (changePercent >= circuitBreakerThreshold) {
                circuitBroken[asset] = true;
                emit CircuitBreakerTriggered(asset, median, lastValidPrice[asset]);
                revert LargeDeviation(asset, median, lastValidPrice[asset], changePercent);
            }
        }

        // Update last valid price
        lastValidPrice[asset] = median;
        lastUpdateTimestamp[asset] = block.timestamp;

        return median;
    }

    /**
     * @notice QuickSort implementation to sort price array
     * @param arr Array of prices to sort
     * @param left Starting index
     * @param right Ending index
     * @dev Recursive quicksort used for finding median price
     */
    function _sortPrices(uint256[] memory arr, int256 left, int256 right) internal pure {
        if (left >= right) return;

        uint256 pivot = arr[uint256(left + (right - left) / 2)];
        int256 i = left;
        int256 j = right;

        while (i <= j) {
            while (arr[uint256(i)] < pivot) i++;
            while (pivot < arr[uint256(j)]) j--;

            if (i <= j) {
                (arr[uint256(i)], arr[uint256(j)]) = (arr[uint256(j)], arr[uint256(i)]);
                i++;
                j--;
            }
        }

        if (left < j) _sortPrices(arr, left, j);
        if (i < right) _sortPrices(arr, i, right);
    }

    /**
     * @notice External function to call internal methods for testing
     * @dev This is only used for try/catch operations within the contract
     */
    function getSingleOraclePrice(address oracle) external view returns (uint256) {
        return _getSingleOraclePrice(oracle);
    }

    /**
     * @notice Authorizes contract upgrades
     * @param newImplementation Address of the new implementation
     * @custom:security Restricted to UPGRADER_ROLE
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}
}
