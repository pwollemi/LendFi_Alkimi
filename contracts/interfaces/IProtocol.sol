// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IPROTOCOL is IERC20 {
    // Enums
    /**
     * @notice Classification of collateral assets by risk profile
     * @dev Used to determine borrowing parameters and liquidation thresholds
     */
    enum CollateralTier {
        STABLE, // Most stable assets (e.g., stablecoins)
        CROSS_A, // High-quality volatile assets (e.g., ETH, BTC)
        CROSS_B, // Medium-quality volatile assets
        ISOLATED // High-risk assets that require isolation mode

    }

    /**
     * @notice Current status of a borrowing position
     * @dev Used to track position lifecycle and determine valid operations
     */
    enum PositionStatus {
        LIQUIDATED, // Position has been liquidated
        ACTIVE, // Position is active and can be modified
        CLOSED // Position has been voluntarily closed by the user

    }

    // Structs
    /**
     * @notice Configuration parameters for a collateral asset
     * @dev Contains all settings that define how an asset behaves within the protocol
     */
    struct Asset {
        uint8 active; // 1 = enabled, 0 = disabled
        uint8 oracleDecimals; // Decimal precision of the price oracle (e.g., 8 for Chainlink)
        uint8 decimals; // Decimal precision of the asset itself
        uint32 borrowThreshold; // LTV ratio for borrowing (scaled by 1000, e.g., 800 = 80%)
        uint32 liquidationThreshold; // LTV ratio for liquidation (scaled by 1000, e.g., 850 = 85%)
        address oracleUSD; // Price oracle address for USD value
        uint256 maxSupplyThreshold; // Maximum amount of asset that can be supplied as collateral
        uint256 isolationDebtCap; // Maximum debt allowed when used in isolation mode
        CollateralTier tier; // Risk classification of the asset
    }

    /**
     * @notice User borrowing position data
     * @dev Core data structure tracking user's debt and position configuration
     */
    struct UserPosition {
        bool isIsolated; // Whether position uses isolation mode
        uint256 debtAmount; // Current debt principal without interest
        uint256 lastInterestAccrual; // Timestamp of last interest accrual
        PositionStatus status; // Current lifecycle status of the position
    }

    /**
     * @notice Global protocol state variables
     * @dev Used for reporting and governance decisions
     */
    struct ProtocolSnapshot {
        uint256 utilization; // Current utilization ratio (scaled by WAD)
        uint256 borrowRate; // Current borrow interest rate (scaled by RAY)
        uint256 supplyRate; // Current supply interest rate (scaled by RAY)
        uint256 totalBorrow; // Total outstanding borrowed amount
        uint256 totalSuppliedLiquidity; // Total liquidity supplied to protocol
        uint256 targetReward; // Target amount of rewards per interval
        uint256 rewardInterval; // Time between reward distributions
        uint256 rewardableSupply; // Minimum liquidity to qualify for rewards
        uint256 baseProfitTarget; // Target profit rate (scaled by RAY)
        uint256 liquidatorThreshold; // Governance token threshold for liquidators
        uint256 flashLoanFee; // Fee charged on flash loans (scaled by 1000)
    }

    // Events
    /**
     * @notice Emitted when protocol is initialized
     * @param admin Address of the admin who initialized the contract
     */
    event Initialized(address indexed admin);

    /**
     * @notice Emitted when implementation contract is upgraded
     * @param admin Address of the admin who performed the upgrade
     * @param implementation Address of the new implementation
     */
    event Upgrade(address indexed admin, address indexed implementation);

    /**
     * @notice Emitted when a user supplies liquidity to the protocol
     * @param supplier Address of the liquidity supplier
     * @param amount Amount of USDC supplied
     */
    event SupplyLiquidity(address indexed supplier, uint256 amount);

    /**
     * @notice Emitted when LP tokens are exchanged for underlying assets
     * @param exchanger Address of the user exchanging tokens
     * @param amount Amount of LP tokens exchanged
     * @param value Value received in exchange
     */
    event Exchange(address indexed exchanger, uint256 amount, uint256 value);

    /**
     * @notice Emitted when collateral is supplied to a position
     * @param user Address of the position owner
     * @param positionId ID of the position
     * @param asset Address of the supplied collateral asset
     * @param amount Amount of collateral supplied
     */
    event SupplyCollateral(address indexed user, uint256 indexed positionId, address indexed asset, uint256 amount);

    /**
     * @notice Emitted when collateral is withdrawn from a position
     * @param user Address of the position owner
     * @param positionId ID of the position
     * @param asset Address of the withdrawn collateral asset
     * @param amount Amount of collateral withdrawn
     */
    event WithdrawCollateral(address indexed user, uint256 indexed positionId, address indexed asset, uint256 amount);

    /**
     * @notice Emitted when a new borrowing position is created
     * @param user Address of the position owner
     * @param positionId ID of the newly created position
     * @param isIsolated Whether the position was created in isolation mode
     */
    event PositionCreated(address indexed user, uint256 indexed positionId, bool isIsolated);

    /**
     * @notice Emitted when a position is closed
     * @param user Address of the position owner
     * @param positionId ID of the closed position
     */
    event PositionClosed(address indexed user, uint256 indexed positionId);

    /**
     * @notice Emitted when a user borrows from a position
     * @param user Address of the position owner
     * @param positionId ID of the position
     * @param amount Amount borrowed
     */
    event Borrow(address indexed user, uint256 indexed positionId, uint256 amount);

    /**
     * @notice Emitted when debt is repaid
     * @param user Address of the position owner
     * @param positionId ID of the position
     * @param amount Amount repaid
     */
    event Repay(address indexed user, uint256 indexed positionId, uint256 amount);

    /**
     * @notice Emitted when interest is accrued on a position
     * @param user Address of the position owner
     * @param positionId ID of the position
     * @param amount Interest amount accrued
     */
    event InterestAccrued(address indexed user, uint256 indexed positionId, uint256 amount);

    /**
     * @notice Emitted when rewards are distributed
     * @param user Address of the reward recipient
     * @param amount Reward amount distributed
     */
    event Reward(address indexed user, uint256 amount);

    /**
     * @notice Emitted when a flash loan is executed
     * @param initiator Address that initiated the flash loan
     * @param receiver Contract receiving the flash loan
     * @param token Address of the borrowed token
     * @param amount Amount borrowed
     * @param fee Fee charged for the flash loan
     */
    event FlashLoan(
        address indexed initiator, address indexed receiver, address indexed token, uint256 amount, uint256 fee
    );

    /**
     * @notice Emitted when the base profit target is updated
     * @param rate New base profit target rate
     */
    event UpdateBaseProfitTarget(uint256 rate);

    /**
     * @notice Emitted when the base borrow rate is updated
     * @param rate New base borrow rate
     */
    event UpdateBaseBorrowRate(uint256 rate);

    /**
     * @notice Emitted when the target reward amount is updated
     * @param amount New target reward amount
     */
    event UpdateTargetReward(uint256 amount);

    /**
     * @notice Emitted when the reward interval is updated
     * @param interval New reward interval in seconds
     */
    event UpdateRewardInterval(uint256 interval);

    /**
     * @notice Emitted when the rewardable supply threshold is updated
     * @param amount New rewardable supply threshold
     */
    event UpdateRewardableSupply(uint256 amount);

    /**
     * @notice Emitted when the liquidator governance token threshold is updated
     * @param amount New liquidator threshold
     */
    event UpdateLiquidatorThreshold(uint256 amount);

    /**
     * @notice Emitted when the flash loan fee is updated
     * @param fee New flash loan fee (scaled by 1000)
     */
    event UpdateFlashLoanFee(uint256 fee);

    /**
     * @notice Emitted when tier parameters are updated
     * @param tier Collateral tier being updated
     * @param borrowRate New borrow rate for the tier
     * @param liquidationFee New liquidation bonus for the tier
     */
    event TierParametersUpdated(CollateralTier tier, uint256 borrowRate, uint256 liquidationFee);

    /**
     * @notice Emitted when an asset's tier classification is updated
     * @param asset Address of the asset being updated
     * @param newTier New collateral tier assigned to the asset
     */
    event AssetTierUpdated(address indexed asset, CollateralTier indexed newTier);

    /**
     * @notice Emitted when an asset's configuration is updated
     * @param asset Address of the updated asset
     */
    event UpdateAssetConfig(address indexed asset);

    /**
     * @notice Emitted when an asset's TVL is updated
     * @param asset Address of the asset
     * @param amount New TVL amount
     */
    event TVLUpdated(address indexed asset, uint256 amount);

    /**
     * @notice Emitted when an additional oracle is added for an asset
     * @param asset Address of the asset
     * @param oracle Address of the oracle being added
     * @param decimals Number of decimals in the oracle price feed
     */
    event OracleAdded(address indexed asset, address indexed oracle, uint8 decimals);

    /**
     * @notice Emitted when an oracle is removed from an asset
     * @param asset Address of the asset
     * @param oracle Address of the oracle being removed
     */
    event OracleRemoved(address indexed asset, address indexed oracle);

    /**
     * @notice Emitted when a new primary oracle is set for an asset
     * @param asset Address of the asset
     * @param oracle Address of the oracle set as primary
     */
    event PrimaryOracleSet(address indexed asset, address indexed oracle);

    /**
     * @notice Emitted when oracle time thresholds are updated
     * @param freshness New maximum age for all price data (in seconds)
     * @param volatility New maximum age for volatile price data (in seconds)
     */
    event OracleThresholdsUpdated(uint256 freshness, uint256 volatility);

    /**
     * @notice Emitted when a position is liquidated
     * @param user The address of the position owner
     * @param positionId The ID of the inactive position
     * @param liquidator The address of the liquidator
     */
    event Liquidated(address indexed user, uint256 indexed positionId, address liquidator);

    /**
     * @notice Emitted when a position is liquidated
     * @param user The address of the position owner
     * @param positionId The ID of the inactive position
     * @param debtAmount Debt amount
     * @param bonusAmount Bonus Amount
     * @param collateralValue Collateral value
     * @param healthFactor Health Factor
     */
    event LiquidationMetrics(
        address indexed user,
        uint256 indexed positionId,
        uint256 debtAmount,
        uint256 bonusAmount,
        uint256 collateralValue,
        uint256 healthFactor
    );

    /**
     * @notice Thrown when a position ID is invalid for a user
     * @param user The address of the position owner
     * @param positionId The invalid position ID
     */
    error InvalidPosition(address user, uint256 positionId);
    /**
     * @notice Thrown when a liquidator has insufficient governance tokens
     * @param liquidator The address attempting to liquidate
     * @param required The required amount of governance tokens
     * @param balance The liquidator's actual balance
     */
    error InsufficientGovTokens(address liquidator, uint256 required, uint256 balance);

    /**
     * @notice Thrown when attempting to liquidate a healthy position
     * @param user The address of the position owner
     * @param positionId The ID of the position that can't be liquidated
     */
    error NotLiquidatable(address user, uint256 positionId);

    /**
     * @notice Thrown when there's insufficient liquidity for a flash loan
     * @param token The address of the requested token
     * @param requested The amount requested
     * @param available The actual available liquidity
     */
    error InsufficientFlashLoanLiquidity(address token, uint256 requested, uint256 available);

    /**
     * @notice Thrown when a flash loan execution fails
     */
    error FlashLoanFailed();

    /**
     * @notice Thrown when flash loan funds aren't fully returned with fees
     * @param expected The expected amount to be returned
     * @param actual The actual amount returned
     */
    error FlashLoanFundsNotReturned(uint256 expected, uint256 actual);

    /**
     * @notice Thrown when attempting flash loan with unsupported token
     * @param token The address of the unsupported token
     */
    error OnlyUsdcSupported(address token);

    /**
     * @notice Thrown when attempting to set a fee higher than allowed
     * @param requested The requested fee
     * @param max The maximum allowed fee
     */
    error FeeTooHigh(uint256 requested, uint256 max);

    /**
     * @notice Thrown when attempting to set a fee higher than allowed
     * @param requested The requested fee
     * @param min The minimum allowed fee
     */
    error FeeTooLow(uint256 requested, uint256 min);
    /**
     * @notice Thrown when a user has insufficient token balance
     * @param token The address of the token
     * @param user The address of the user
     * @param available The user's actual balance
     */
    error InsufficientTokenBalance(address token, address user, uint256 available);

    /**
     * @notice Thrown when attempting to use an asset not listed in the protocol
     * @param asset The address of the unlisted asset
     */
    error AssetNotListed(address asset);

    /**
     * @notice Thrown when protocol has insufficient liquidity for borrowing
     * @param requested The requested amount
     * @param available The actual available liquidity
     */
    error InsufficientLiquidity(uint256 requested, uint256 available);

    /**
     * @notice Thrown when attempting to exceed isolation debt cap
     * @param asset The isolated asset address
     * @param requested The requested debt amount
     * @param cap The maximum allowed debt in isolation mode
     */
    error IsolationDebtCapExceeded(address asset, uint256 requested, uint256 cap);

    /**
     * @notice Thrown when no collateral is provided for isolated asset
     * @param user The address of the position owner
     * @param positionId The ID of the position
     * @param isolatedAsset The address of the isolated asset
     */
    error NoIsolatedCollateral(address user, uint256 positionId, address isolatedAsset);

    /**
     * @notice Thrown when attempting to borrow beyond credit limit
     * @param requested The requested borrow amount
     * @param creditLimit The maximum allowed borrow amount
     */
    error ExceedsCreditLimit(uint256 requested, uint256 creditLimit);

    /**
     * @notice Thrown when attempting to repay a position with no debt
     * @param user The address of the position owner
     * @param positionId The ID of the position with no debt
     */
    error NoDebtToRepay(address user, uint256 positionId);

    /**
     * @notice Thrown when asset doesn't match isolation mode settings
     * @param user The address of the position owner
     * @param positionId The ID of the position
     * @param requestedAsset The asset being added/withdrawn
     * @param isolatedAsset The current isolated asset
     */
    error InvalidPositionAsset(address user, uint256 positionId, address requestedAsset, address isolatedAsset);

    /**
     * @notice Thrown when user has insufficient collateral in position
     * @param user The address of the position owner
     * @param positionId The ID of the position
     * @param asset The address of the collateral asset
     * @param requested The requested withdrawal amount
     * @param available The actual available collateral
     */
    error InsufficientCollateralBalance(
        address user, uint256 positionId, address asset, uint256 requested, uint256 available
    );

    /**
     * @notice Thrown when withdrawal would make position undercollateralized
     * @param user The address of the position owner
     * @param positionId The ID of the position
     * @param debtAmount The position's current debt
     * @param creditLimit The position's new credit limit after withdrawal
     */
    error WithdrawalExceedsCreditLimit(address user, uint256 positionId, uint256 debtAmount, uint256 creditLimit);

    /**
     * @notice Thrown when attempting to use a disabled asset
     * @param asset The address of the disabled asset
     */
    error AssetDisabled(address asset);

    /**
     * @notice Thrown when attempting to use asset that requires isolation mode
     * @param asset The address of the asset that requires isolation
     */
    error IsolationModeRequired(address asset);

    /**
     * @notice Thrown when attempting to exceed asset supply cap
     * @param asset The address of the asset
     * @param requested The requested supply amount
     * @param cap The maximum allowed supply
     */
    error SupplyCapExceeded(address asset, uint256 requested, uint256 cap);

    /**
     * @notice Thrown when oracle returns invalid price data
     * @param oracle The address of the price oracle
     * @param price The invalid price value
     */
    error OracleInvalidPrice(address oracle, int256 price);

    /**
     * @notice Thrown when oracle round is incomplete
     * @param oracle The address of the price oracle
     * @param roundId The current round ID
     * @param answeredInRound The round when answer was computed
     */
    error OracleStalePrice(address oracle, uint80 roundId, uint80 answeredInRound);

    /**
     * @notice Thrown when oracle data is too old
     * @param oracle The address of the price oracle
     * @param timestamp The timestamp of the oracle data
     * @param currentTimestamp The current block timestamp
     * @param maxAge The maximum allowed age for oracle data
     */
    error OracleTimeout(address oracle, uint256 timestamp, uint256 currentTimestamp, uint256 maxAge);

    /**
     * @notice Thrown when price has excessive volatility with stale data
     * @param oracle The address of the price oracle
     * @param price The current price
     * @param volatility The calculated price change percentage
     */
    error OracleInvalidPriceVolatility(address oracle, int256 price, uint256 volatility);
    /// @notice Thrown when trying to add more than 20 different assets to a position
    /// @param user The position owner
    /// @param positionId The position ID
    error TooManyAssets(address user, uint256 positionId);
    /// @notice Thrown when trying to set a rate below minimum allowed
    /// @param requested The requested rate
    /// @param minimum The minimum allowed rate
    error RateTooLow(uint256 requested, uint256 minimum);
    error RewardTooHigh(uint256 requested, uint256 max);
    /// @notice Thrown when trying to set a reward interval below minimum allowed
    /// @param requested The requested interval in seconds
    /// @param minimum The minimum allowed interval in seconds
    error RewardIntervalTooShort(uint256 requested, uint256 minimum);
    /// @notice Thrown when trying to set rewardable supply below minimum allowed
    /// @param requested The requested supply amount
    /// @param minimum The minimum allowed supply amount
    error RewardableSupplyTooLow(uint256 requested, uint256 minimum);
    /// @notice Thrown when trying to set liquidator threshold below minimum allowed
    /// @param requested The requested threshold amount
    /// @param minimum The minimum allowed threshold amount
    error LiquidatorThresholdTooLow(uint256 requested, uint256 minimum);
    /// @notice Thrown when trying to set a rate above maximum allowed
    /// @param requested The requested rate
    /// @param maximum The maximum allowed rate
    error RateTooHigh(uint256 requested, uint256 maximum);

    /**
     * @notice Thrown when attempting to interact with an inactive position
     * @param user The address of the position owner
     * @param positionId The ID of the inactive position
     */
    error InactivePosition(address user, uint256 positionId);
    /**
     * @notice Thrown when multiple oracles report widely divergent prices
     * @param asset The address of the asset
     * @param minPrice The lowest reported price
     * @param maxPrice The highest reported price
     * @param threshold The maximum allowed divergence
     */
    error OraclePriceDivergence(address asset, uint256 minPrice, uint256 maxPrice, uint256 threshold);
    /**
     * @notice Thrown when a circuit breaker has been triggered due to extreme price movements
     * @param asset The address of the asset
     * @param currentPrice The current price that triggered the circuit breaker
     * @param previousPrice The previous valid price
     * @param changePercent The percentage change that triggered the breaker
     */
    error CircuitBreakerTriggered(address asset, uint256 currentPrice, uint256 previousPrice, uint256 changePercent);

    //////////////////////////////////////////////////
    // ---------------Core functions---------------//
    /////////////////////////////////////////////////

    /**
     * @notice Initializes the protocol with core dependencies and parameters
     * @param usdc The address of the USDC stablecoin used for borrowing and liquidity
     * @param govToken The address of the governance token used for liquidator eligibility
     * @param ecosystem The address of the ecosystem contract that manages rewards
     * @param treasury_ The address of the treasury that collects protocol fees
     * @param timelock_ The address of the timelock contract for governance actions
     * @param guardian The address of the initial admin with pausing capability
     * @param oracle_ The address of the oracle module for price feeds
     * @dev Sets up ERC20 token details, access control roles, and default protocol parameters
     */
    function initialize(
        address usdc,
        address govToken,
        address ecosystem,
        address treasury_,
        address timelock_,
        address guardian,
        address oracle_
    ) external;

    /**
     * @notice Pauses all protocol operations in case of emergency
     * @dev Can only be called by authorized governance roles
     */
    function pause() external;

    /**
     * @notice Unpauses the protocol to resume normal operations
     * @dev Can only be called by authorized governance roles
     */
    function unpause() external;

    // Flash loan function
    /**
     * @notice Executes a flash loan, allowing borrowing without collateral if repaid in same transaction
     * @param receiver The contract address that will receive the flash loaned tokens
     * @param token The address of the token to borrow (currently only supports USDC)
     * @param amount The amount of tokens to flash loan
     * @param params Arbitrary data to pass to the receiver contract
     * @dev Receiver must implement IFlashLoanReceiver interface
     */
    function flashLoan(address receiver, address token, uint256 amount, bytes calldata params) external;

    // Configuration functions
    /**
     * @notice Updates the fee charged for flash loans
     * @param newFee The new flash loan fee (scaled by 1000, e.g., 5 = 0.5%)
     * @dev Can only be called by authorized governance roles
     */
    function updateFlashLoanFee(uint256 newFee) external;

    /**
     * @notice Updates the target profit rate for the protocol
     * @param rate The new base profit target rate (scaled by RAY)
     * @dev Can only be called by authorized governance roles
     */
    function updateBaseProfitTarget(uint256 rate) external;

    /**
     * @notice Updates the base interest rate charged on borrowing
     * @param rate The new base borrow rate (scaled by RAY)
     * @dev Can only be called by authorized governance roles
     */
    function updateBaseBorrowRate(uint256 rate) external;

    /**
     * @notice Updates the target reward amount for liquidity providers
     * @param amount The new target reward amount per distribution interval
     * @dev Can only be called by authorized governance roles
     */
    function updateTargetReward(uint256 amount) external;

    /**
     * @notice Updates the time interval between reward distributions
     * @param interval The new reward interval in seconds
     * @dev Can only be called by authorized governance roles
     */
    function updateRewardInterval(uint256 interval) external;

    /**
     * @notice Updates the minimum liquidity threshold required to be eligible for rewards
     * @param amount The new minimum liquidity threshold
     * @dev Can only be called by authorized governance roles
     */
    function updateRewardableSupply(uint256 amount) external;

    /**
     * @notice Updates the minimum governance token threshold required to be a liquidator
     * @param amount The new liquidator threshold amount
     * @dev Can only be called by authorized governance roles
     */
    function updateLiquidatorThreshold(uint256 amount) external;

    /**
     * @notice Updates the borrowing rate and liquidation bonus parameters for a collateral tier
     * @param tier The collateral tier to update
     * @param borrowRate The new borrow rate multiplier (scaled by RAY)
     * @param liquidationFee The new liquidation bonus percentage (scaled by 1000)
     * @dev Can only be called by authorized governance roles
     */
    function updateTierParameters(CollateralTier tier, uint256 borrowRate, uint256 liquidationFee) external;

    /**
     * @notice Updates the risk classification tier of an asset
     * @param asset The address of the asset to update
     * @param newTier The new collateral tier to assign to the asset
     * @dev Can only be called by authorized governance roles
     */
    function updateAssetTier(address asset, CollateralTier newTier) external;

    /**
     * @notice Updates or adds a new collateral asset with all configuration parameters
     * @param asset The address of the asset to configure
     * @param oracle_ The address of the price oracle for this asset
     * @param oracleDecimals The decimal precision of the price oracle
     * @param assetDecimals The decimal precision of the asset token
     * @param active Whether the asset is active (1) or disabled (0)
     * @param borrowThreshold The LTV ratio for borrowing (scaled by 1000)
     * @param liquidationThreshold The LTV ratio for liquidation (scaled by 1000)
     * @param maxSupplyLimit The maximum amount that can be supplied as collateral
     * @param tier The risk classification tier of the asset
     * @param isolationDebtCap The maximum debt allowed when used in isolation mode
     * @dev Can only be called by authorized governance roles
     */
    function updateAssetConfig(
        address asset,
        address oracle_,
        uint8 oracleDecimals,
        uint8 assetDecimals,
        uint8 active,
        uint32 borrowThreshold,
        uint32 liquidationThreshold,
        uint256 maxSupplyLimit,
        CollateralTier tier,
        uint256 isolationDebtCap
    ) external;

    // Position management functions
    /**
     * @notice Allows users to supply liquidity (USDC) to the protocol
     * @param amount The amount of USDC to supply
     * @dev Mints LP tokens representing the user's share of the liquidity pool
     */
    function supplyLiquidity(uint256 amount) external;

    /**
     * @notice Allows users to withdraw liquidity by burning LP tokens
     * @param amount The amount of LP tokens to burn
     */
    function exchange(uint256 amount) external;

    /**
     * @notice Allows users to supply collateral assets to a borrowing position
     * @param asset The address of the collateral asset to supply
     * @param amount The amount of the asset to supply
     * @param positionId The ID of the position to supply collateral to
     */
    function supplyCollateral(address asset, uint256 amount, uint256 positionId) external;

    /**
     * @notice Allows users to withdraw collateral assets from a borrowing position
     * @param asset The address of the collateral asset to withdraw
     * @param amount The amount of the asset to withdraw
     * @param positionId The ID of the position to withdraw from
     * @dev Will revert if withdrawal would make position undercollateralized
     */
    function withdrawCollateral(address asset, uint256 amount, uint256 positionId) external;

    /**
     * @notice Creates a new borrowing position for the caller
     * @param asset The address of the initial collateral asset
     * @param isIsolated Whether to create the position in isolation mode
     */
    function createPosition(address asset, bool isIsolated) external;

    /**
     * @notice Allows borrowing stablecoins against collateral in a position
     * @param positionId The ID of the position to borrow against
     * @param amount The amount of stablecoins to borrow
     * @dev Will revert if borrowing would exceed the position's credit limit
     */
    function borrow(uint256 positionId, uint256 amount) external;

    /**
     * @notice Allows users to repay debt on a borrowing position
     * @param positionId The ID of the position to repay debt for
     * @param amount The amount of debt to repay
     */
    function repay(uint256 positionId, uint256 amount) external;

    /**
     * @notice Closes a position after all debt is repaid and withdraws remaining collateral
     * @param positionId The ID of the position to close
     * @dev Position must have zero debt to be closed
     */
    function exitPosition(uint256 positionId) external;

    /**
     * @notice Liquidates an undercollateralized position
     * @param user The address of the position owner
     * @param positionId The ID of the position to liquidate
     * @dev Caller must hold sufficient governance tokens to be eligible as a liquidator
     */
    function liquidate(address user, uint256 positionId) external;

    // View functions - Asset & Position information
    /**
     * @notice Retrieves the configuration data for a collateral asset
     * @param asset The address of the asset
     * @return Asset struct containing all configuration parameters
     */
    function getAssetInfo(address asset) external view returns (Asset memory);

    /**
     * @notice Gets the current USD price of an asset
     * @param asset The address of the asset
     * @return The asset price in USD (scaled by the asset's oracle decimals)
     */
    function getAssetPrice(address asset) external returns (uint256);

    /**
     * @notice Gets the total number of positions created by a user
     * @param user The address of the user
     * @return The number of positions the user has created
     */
    function getUserPositionsCount(address user) external view returns (uint256);

    /**
     * @notice Gets all positions created by a user
     * @param user The address of the user
     * @return An array of UserPosition structs
     */
    function getUserPositions(address user) external view returns (UserPosition[] memory);

    /**
     * @notice Gets a specific position's data
     * @param user The address of the position owner
     * @param positionId The ID of the position
     * @return UserPosition struct containing position data
     */
    function getUserPosition(address user, uint256 positionId) external view returns (UserPosition memory);

    /**
     * @notice Gets the amount of a specific asset in a position
     * @param user The address of the position owner
     * @param positionId The ID of the position
     * @param asset The address of the collateral asset
     * @return The amount of the asset in the position
     */
    function getUserCollateralAmount(address user, uint256 positionId, address asset) external view returns (uint256);

    /**
     * @notice Gets the current state of all protocol parameters
     * @return ProtocolSnapshot struct with current protocol state
     */
    function getProtocolSnapshot() external view returns (ProtocolSnapshot memory);

    /**
     * @notice Calculates the current debt amount including accrued interest
     * @param user The address of the position owner
     * @param positionId The ID of the position
     * @return The total debt amount with interest
     */
    function calculateDebtWithInterest(address user, uint256 positionId) external view returns (uint256);

    /**
     * @notice Calculates the liquidation fee for a position
     * @param user The address of the position owner
     * @param positionId The ID of the position
     * @return The liquidation fee amount
     */
    function getPositionLiquidationFee(address user, uint256 positionId) external view returns (uint256);

    /**
     * @notice Calculates the maximum amount a user can borrow against their position
     * @param user The address of the position owner
     * @param positionId The ID of the position
     * @return The maximum borrowing capacity (credit limit)
     */
    function calculateCreditLimit(address user, uint256 positionId) external view returns (uint256);

    /**
     * @notice Checks if a position is eligible for liquidation
     * @param user The address of the position owner
     * @param positionId The ID of the position
     * @return True if the position can be liquidated, false otherwise
     */
    function isLiquidatable(address user, uint256 positionId) external view returns (bool);

    /**
     * @notice Gets detailed information about an asset
     * @param asset The address of the asset
     * @return price The current USD price
     * @return totalSupplied The total amount supplied as collateral
     * @return maxSupply The maximum supply threshold
     * @return borrowRate The current borrow interest rate
     * @return liquidationFee The liquidation bonus percentage
     * @return tier The collateral tier classification
     */
    function getAssetDetails(address asset)
        external
        view
        returns (
            uint256 price,
            uint256 totalSupplied,
            uint256 maxSupply,
            uint256 borrowRate,
            uint256 liquidationFee,
            CollateralTier tier
        );

    /**
     * @notice Gets information about a user's LP token position
     * @param user The address of the user
     * @return lpTokenBalance The user's LP token balance
     * @return usdcValue The USDC value of the LP tokens
     * @return lastAccrualTime The timestamp of last interest accrual
     * @return isRewardEligible Whether the user is eligible for rewards
     * @return pendingRewards The pending reward amount
     */
    function getLPInfo(address user)
        external
        view
        returns (
            uint256 lpTokenBalance,
            uint256 usdcValue,
            uint256 lastAccrualTime,
            bool isRewardEligible,
            uint256 pendingRewards
        );

    /**
     * @notice Calculates the health factor of a borrowing position
     * @param user The address of the position owner
     * @param positionId The ID of the position
     * @return The position's health factor (scaled by WAD)
     * @dev Health factor > 1 means position is healthy, < 1 means liquidatable
     */
    function healthFactor(address user, uint256 positionId) external view returns (uint256);

    /**
     * @notice Gets all collateral assets in a position
     * @param user The address of the position owner
     * @param positionId The ID of the position
     * @return An array of asset addresses in the position
     */
    function getPositionCollateralAssets(address user, uint256 positionId) external view returns (address[] memory);

    /**
     * @notice Gets the current debt amount for a position
     * @param user The address of the position owner
     * @param positionId The ID of the position
     * @return The current debt amount including interest
     */
    function getPositionDebt(address user, uint256 positionId) external view returns (uint256);

    /**
     * @notice Calculates the current utilization rate of the protocol
     * @return u The utilization rate (scaled by WAD)
     * @dev Utilization = totalBorrow / totalSuppliedLiquidity
     */
    function getUtilization() external view returns (uint256 u);

    /**
     * @notice Gets the current supply interest rate
     * @return The supply interest rate (scaled by RAY)
     */
    function getSupplyRate() external view returns (uint256);

    /**
     * @notice Gets the current borrow interest rate for a specific tier
     * @param tier The collateral tier to query
     * @return The borrow interest rate (scaled by RAY)
     */
    function getBorrowRate(CollateralTier tier) external view returns (uint256);

    /**
     * @notice Checks if a user is eligible for rewards
     * @param user The address of the user
     * @return True if user is eligible for rewards, false otherwise
     */
    function isRewardable(address user) external view returns (bool);

    /**
     * @notice Gets the liquidation fee percentage for a collateral tier
     * @param tier The collateral tier to query
     * @return The liquidation fee percentage (scaled by 1000)
     */
    function getTierLiquidationFee(CollateralTier tier) external view returns (uint256);

    /**
     * @notice Gets the price from a specific oracle
     * @param oracle The address of the price oracle
     * @return The price returned by the oracle
     * @dev Validates the oracle data is fresh and within expected range
     */
    function getAssetPriceOracle(address oracle) external view returns (uint256);

    /**
     * @notice Determines the highest risk tier among collateral assets in a position
     * @param user The address of the position owner
     * @param positionId The ID of the position
     * @return The highest risk CollateralTier in the position
     */
    function getHighestTier(address user, uint256 positionId) external view returns (CollateralTier);

    /**
     * @notice Gets all configured rates for each collateral tier
     * @return borrowRates Array of borrow rates for each tier (scaled by RAY)
     * @return liquidationFeees Array of liquidation bonuses for each tier (scaled by 1000)
     */
    function getTierRates() external view returns (uint256[4] memory borrowRates, uint256[4] memory liquidationFeees);

    /**
     * @notice Gets all assets listed in the protocol
     * @return An array of asset addresses
     */
    function getListedAssets() external view returns (address[] memory);

    /**
     * @notice Gets the current protocol version
     * @return The protocol version number
     */
    function version() external view returns (uint8);

    // State view functions
    /**
     * @notice Gets the total amount borrowed from the protocol
     * @return The total borrowed amount
     */
    function totalBorrow() external view returns (uint256);

    /**
     * @notice Gets the total liquidity supplied to the protocol
     * @return The total supplied liquidity
     */
    function totalSuppliedLiquidity() external view returns (uint256);

    /**
     * @notice Gets the total interest accrued by borrowers
     * @return The total accrued borrower interest
     */
    function totalAccruedBorrowerInterest() external view returns (uint256);

    /**
     * @notice Gets the total interest accrued by suppliers
     * @return The total accrued supplier interest
     */
    function totalAccruedSupplierInterest() external view returns (uint256);

    /**
     * @notice Gets the total liquidity withdrawn from the protocol
     * @return The total withdrawn liquidity
     */
    function withdrawnLiquidity() external view returns (uint256);

    /**
     * @notice Gets the target reward amount per distribution interval
     * @return The target reward amount
     */
    function targetReward() external view returns (uint256);

    /**
     * @notice Gets the time interval between reward distributions
     * @return The reward interval in seconds
     */
    function rewardInterval() external view returns (uint256);

    /**
     * @notice Gets the minimum liquidity threshold required to be eligible for rewards
     * @return The rewardable supply threshold
     */
    function rewardableSupply() external view returns (uint256);

    /**
     * @notice Gets the base interest rate charged on borrowing
     * @return The base borrow rate (scaled by RAY)
     */
    function baseBorrowRate() external view returns (uint256);

    /**
     * @notice Gets the target profit rate for the protocol
     * @return The base profit target (scaled by RAY)
     */
    function baseProfitTarget() external view returns (uint256);

    /**
     * @notice Gets the minimum governance token threshold required to be a liquidator
     * @return The liquidator threshold amount
     */
    function liquidatorThreshold() external view returns (uint256);

    /**
     * @notice Gets the current fee charged for flash loans
     * @return The flash loan fee (scaled by 1000)
     */
    function flashLoanFee() external view returns (uint256);

    /**
     * @notice Gets the total fees collected from flash loans
     * @return The total flash loan fees collected
     */
    function totalFlashLoanFees() external view returns (uint256);

    /**
     * @notice Gets the address of the treasury contract
     * @return The treasury contract address
     */
    function treasury() external view returns (address);

    /**
     * @notice Gets the total value locked for a specific asset
     * @param asset The address of the asset
     * @return The total value locked (TVL) amount
     */
    function assetTVL(address asset) external view returns (uint256);

    /**
     * @notice Adds an additional oracle data source for an asset
     * @param asset Address of the asset
     * @param oracle Address of the Chainlink price feed to add
     * @param decimals Number of decimals in the oracle price feed
     * @dev Allows adding secondary or backup oracles to enhance price reliability
     */
    function addAssetOracle(address asset, address oracle, uint8 decimals) external;

    /**
     * @notice Removes an oracle data source for an asset
     * @param asset Address of the asset
     * @param oracle Address of the Chainlink price feed to remove
     * @dev Allows removing unreliable or deprecated oracles
     */
    function removeAssetOracle(address asset, address oracle) external;

    /**
     * @notice Sets the primary oracle for an asset
     * @param asset Address of the asset
     * @param oracle Address of the Chainlink price feed to set as primary
     * @dev The primary oracle is used as a fallback when median calculation fails
     */
    function setPrimaryAssetOracle(address asset, address oracle) external;

    /**
     * @notice Updates oracle time thresholds
     * @param freshness Maximum age for all price data (in seconds)
     * @param volatility Maximum age for volatile price data (in seconds)
     * @dev Controls how old price data can be before rejection
     */
    function updateOracleTimeThresholds(uint256 freshness, uint256 volatility) external;
}
