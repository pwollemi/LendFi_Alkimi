// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title IPROTOCOL
 * @notice Interface for the Lendefi Protocol
 * @dev Defines the core functionality and state variables of the Lendefi lending protocol
 */
interface IPROTOCOL is IERC20 {
    /**
     * @dev Risk categorizations for different asset types
     */
    enum CollateralTier {
        STABLE, // Low risk assets like USDC, DAI
        CROSS_A, // Blue chip assets like ETH, BTC
        CROSS_B, // Mid-tier assets with moderate risk
        ISOLATED // High risk assets that can only be used in isolation mode

    }

    /**
     * @dev Configuration for an asset in the protocol
     */
    struct Asset {
        uint8 active; // 1 if asset is active, 0 if disabled
        uint8 decimals; // Asset token decimals
        uint8 oracleDecimals; // Number of decimals in oracle price feed
        uint32 borrowThreshold; // LTV ratio for borrowing (e.g. 800 = 80%)
        uint32 liquidationThreshold; // LTV ratio for liquidation (e.g. 850 = 85%)
        address oracleUSD; // Address of price oracle for asset/USD
        uint256 maxSupplyThreshold; // Maximum amount of asset allowed in protocol
        CollateralTier tier; // Risk category of the asset
        uint256 isolationDebtCap; // Maximum debt allowed in isolation mode
    }

    /**
     * @dev Represents a user's borrowing position
     */
    struct UserPosition {
        bool isIsolated; // Whether position is in isolation mode
        address isolatedAsset; // Asset used in isolation mode (if applicable)
        uint256 debtAmount; // Amount of USDC borrowed
        uint256 lastInterestAccrual; // Timestamp of last interest calculation
    }

    /**
     * @dev Overview of protocol state
     */
    struct ProtocolSnapshot {
        uint256 utilization; // Current utilization ratio
        uint256 borrowRate; // Current base borrow rate
        uint256 supplyRate; // Current supply rate
        uint256 totalBorrow; // Total amount borrowed from protocol
        uint256 totalSuppliedLiquidity; // Total base amount in protocol
        uint256 targetReward; // Target reward amount
        uint256 rewardInterval; // Interval for reward distribution
        uint256 rewardableSupply; // Minimum supply to be eligible for rewards
        uint256 baseProfitTarget; // Base profit target rate
        uint256 liquidatorThreshold; // Minimum governance tokens required for liquidation
        uint256 flashLoanFee; // Fee for flash loans (basis points)
    }

    // Events
    event FlashLoan(address indexed initiator, address indexed receiver, address token, uint256 amount, uint256 fee);
    event Reward(address indexed to, uint256 amount);
    event Exchange(address indexed src, uint256 amountIn, uint256 amountOut);
    event Initialized(address indexed src);
    event SupplyCollateral(address indexed user, uint256 indexed positionId, address indexed asset, uint256 amount);
    event WithdrawCollateral(address indexed user, uint256 indexed positionId, address indexed asset, uint256 amount);
    event Borrow(address indexed user, uint256 indexed positionId, uint256 amount);
    event Liquidated(address indexed user, uint256 indexed positionId, uint256 amount);
    event EnteredIsolationMode(address indexed user, uint256 indexed positionId, address indexed asset);
    event ExitedIsolationMode(address indexed user, uint256 indexed positionId);
    event TierParametersUpdated(CollateralTier indexed tier, uint256 borrowRate, uint256 liquidationBonus);
    event AssetTierUpdated(address indexed asset, CollateralTier tier);
    event UpdateAssetConfig(address indexed asset);
    event Upgrade(address indexed src, address indexed implementation);
    event Repay(address indexed user, uint256 indexed positionId, uint256 amount);
    event PositionClosed(address indexed user, uint256 indexed positionId);
    event SupplyLiquidity(address indexed user, uint256 amount);
    event PositionCreated(address indexed user, uint256 indexed positionId, bool isIsolated);
    event UpdateBaseProfitTarget(uint256 rate);
    event UpdateBaseBorrowRate(uint256 rate);
    event UpdateTargetReward(uint256 amount);
    event UpdateRewardInterval(uint256 interval);
    event UpdateRewardableSupply(uint256 amount);
    event UpdateLiquidatorThreshold(uint256 amount);
    event UtilizationUpdated(uint256 newUtilization);
    event SupplyRateUpdated(uint256 newRate);
    event CollateralValueChanged(address user, uint256 positionId, uint256 newValue);
    event InterestAccrued(address indexed user, uint256 indexed positionId, uint256 interestAccrued);
    event TVLUpdated(address indexed asset, uint256 newTVL);
    event UpdateFlashLoanFee(uint256 newFee);

    // ------------ Core User Functions ------------

    /**
     * @notice Creates a new borrowing position
     * @param asset The initial collateral asset type for the position
     * @param isIsolated Whether the position should use isolation mode
     * @dev Initializes a new position that can hold collateral and debt
     */
    function createPosition(address asset, bool isIsolated) external;

    /**
     * @notice Adds collateral to a position
     * @param asset The collateral asset to supply
     * @param amount The amount of the asset to supply
     * @param positionId The ID of the position to add collateral to
     * @dev The user must have approved the contract to transfer the asset
     */
    function supplyCollateral(address asset, uint256 amount, uint256 positionId) external;

    /**
     * @notice Withdraws collateral from a position
     * @param asset The collateral asset to withdraw
     * @param amount The amount of the asset to withdraw
     * @param positionId The ID of the position to withdraw from
     * @dev The withdrawal must not cause the position to become undercollateralized
     */
    function withdrawCollateral(address asset, uint256 amount, uint256 positionId) external;

    /**
     * @notice Borrow USDC against a position's collateral
     * @param positionId The ID of the position to borrow against
     * @param amount The amount of USDC to borrow
     * @dev The borrow must not exceed the position's credit limit
     */
    function borrow(uint256 positionId, uint256 amount) external;

    /**
     * @notice Liquidates an undercollateralized position
     * @param user The owner of the position to liquidate
     * @param positionId The ID of the position to liquidate
     * @dev Liquidator must have sufficient governance tokens
     */
    function liquidate(address user, uint256 positionId) external;

    /**
     * @notice Repays part or all of a position's debt
     * @param positionId The ID of the position to repay
     * @param amount The amount of USDC to repay
     * @dev Repays interest first, then principal
     */
    function repay(uint256 positionId, uint256 amount) external;

    /**
     * @notice Closes a position and withdraws all collateral after repaying any debt
     * @param positionId The ID of the position to exit
     * @dev All debt must be repaid before position can be closed
     */
    function exitPosition(uint256 positionId) external;

    /**
     * @notice Supplies USDC liquidity to the protocol and receives LP tokens
     * @param amount The amount of USDC to supply
     * @dev Mints LYT tokens representing share of the lending pool
     */
    function supplyLiquidity(uint256 amount) external;

    /**
     * @notice Exchanges LP tokens for underlying USDC
     * @param amount The amount of LP tokens to exchange
     * @dev Burns LYT tokens and returns USDC plus accrued interest
     */
    function exchange(uint256 amount) external;

    /**
     * @notice Executes a flash loan
     * @param receiver The contract that will receive the flash loan
     * @param token The token to flash loan (currently only USDC)
     * @param amount The amount to flash loan
     * @param params Additional data to pass to the receiver
     * @dev Receiver must implement IFlashLoanReceiver interface
     */
    function flashLoan(address receiver, address token, uint256 amount, bytes calldata params) external;

    // ------------ Admin Functions ------------

    /**
     * @notice Updates the base profit target rate
     * @param rate The new base profit target rate (scaled by 1e6)
     * @dev Minimum allowed rate is 0.25%
     */
    function updateBaseProfitTarget(uint256 rate) external;

    /**
     * @notice Updates the base borrow rate
     * @param rate The new base borrow rate (scaled by 1e6)
     * @dev Minimum allowed rate is 1%
     */
    function updateBaseBorrowRate(uint256 rate) external;

    /**
     * @notice Updates the target reward amount
     * @param amount The new target reward amount
     * @dev Used for LP reward calculations
     */
    function updateTargetReward(uint256 amount) external;

    /**
     * @notice Updates the reward interval
     * @param interval The new reward interval in seconds
     * @dev Minimum allowed interval is 90 days
     */
    function updateRewardInterval(uint256 interval) external;

    /**
     * @notice Updates the minimum supply required to be eligible for rewards
     * @param amount The new minimum supply amount
     * @dev Minimum allowed value is 20,000 WAD
     */
    function updateRewardableSupply(uint256 amount) external;

    /**
     * @notice Updates the minimum governance tokens required to perform liquidations
     * @param amount The new liquidator threshold
     * @dev Minimum allowed value is 10 tokens
     */
    function updateLiquidatorThreshold(uint256 amount) external;

    /**
     * @notice Updates the flash loan fee
     * @param newFee The new fee in basis points (1 = 0.01%)
     * @dev Maximum allowed fee is 1% (100 basis points)
     */
    function updateFlashLoanFee(uint256 newFee) external;

    /**
     * @notice Updates the configuration for an asset
     * @param asset Address of the asset to configure
     * @param oracle_ Address of the price oracle
     * @param oracleDecimals Number of decimals in the oracle price feed
     * @param assetDecimals Number of decimals in the asset token
     * @param active Whether the asset is active (1) or disabled (0)
     * @param borrowThreshold LTV ratio for borrowing (e.g. 800 = 80%)
     * @param liquidationThreshold LTV ratio for liquidation (e.g. 850 = 85%)
     * @param maxSupplyLimit Maximum amount of this asset allowed in protocol
     * @param tier Risk category of the asset
     * @param isolationDebtCap Maximum debt allowed when used in isolation mode
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

    /**
     * @notice Updates the risk parameters for a collateral tier
     * @param tier The tier to update
     * @param borrowRate The new base borrow rate for the tier
     * @param liquidationBonus The new liquidation bonus for the tier
     * @dev Maximum allowed rate is 25%, maximum bonus is 20%
     */
    function updateTierParameters(CollateralTier tier, uint256 borrowRate, uint256 liquidationBonus) external;

    /**
     * @notice Updates the risk tier of an asset
     * @param asset The asset to update
     * @param newTier The new tier to assign to the asset
     * @dev Asset must already be listed in the protocol
     */
    function updateAssetTier(address asset, CollateralTier newTier) external;

    /**
     * @notice Pauses protocol operations
     * @dev Can only be called by addresses with PAUSER_ROLE
     */
    function pause() external;

    /**
     * @notice Unpauses protocol operations
     * @dev Can only be called by addresses with PAUSER_ROLE
     */
    function unpause() external;

    // ------------ View Functions: Protocol State ------------

    /**
     * @notice Returns a snapshot of the protocol's current state
     * @return A struct containing key protocol metrics
     * @dev Aggregates various protocol metrics into a single struct
     */
    function getProtocolSnapshot() external view returns (ProtocolSnapshot memory);

    /**
     * @notice Returns tier-specific interest rates and liquidation bonuses
     * @return borrowRates Array of borrow rates for each tier
     * @return liquidationBonuses Array of liquidation bonuses for each tier
     * @dev Returns rates for all tiers in a single call
     */
    function getTierRates()
        external
        view
        returns (uint256[4] memory borrowRates, uint256[4] memory liquidationBonuses);

    /**
     * @notice Returns information about a liquidity provider
     * @param user The address of the liquidity provider
     * @return lpTokenBalance The user's LP token balance
     * @return usdcValue The USDC value of the user's LP tokens
     * @return lastAccrualTime The timestamp of the last reward accrual
     * @return isRewardEligible Whether the user is eligible for rewards
     * @return pendingRewards The amount of pending rewards
     * @dev Calculates current LP token value and reward eligibility
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
     * @notice Returns the current utilization ratio of the protocol
     * @return The utilization ratio scaled by 1e18
     * @dev Calculated as totalBorrow / totalSuppliedLiquidity
     */
    function getUtilization() external view returns (uint256);

    /**
     * @notice Returns the current supply interest rate
     * @return The supply rate scaled by 1e18
     * @dev Based on protocol profit and utilization
     */
    function getSupplyRate() external view returns (uint256);

    /**
     * @notice Returns the borrow interest rate for a specific collateral tier
     * @param tier The collateral tier to query
     * @return The borrow rate for the tier scaled by 1e18
     * @dev Includes tier-specific premium over base rate
     */
    function getBorrowRate(CollateralTier tier) external view returns (uint256);

    /**
     * @notice Returns the liquidation bonus percentage for a position
     * @param user The owner of the position
     * @param positionId The ID of the position
     * @return The liquidation bonus percentage scaled by 1e18
     * @dev Based on the position's collateral tier
     */
    function getPositionLiquidationFee(address user, uint256 positionId) external view returns (uint256);

    /**
     * @notice Returns the base liquidation fee percentage for a tier
     * @param tier The collateral tier to query
     * @return The base liquidation fee percentage for the specified tier
     * @dev Direct accessor for tierLiquidationBonus mapping
     */
    function getTierLiquidationFee(CollateralTier tier) external view returns (uint256);

    /**
     * @notice Returns all currently supported assets in the protocol
     * @return An array of asset addresses
     * @dev Assets that have been listed in the protocol
     */
    function getListedAssets() external view returns (address[] memory);

    // ------------ View Functions: Position Information ------------

    /**
     * @notice Returns detailed information about a user position
     * @param user The owner of the position
     * @param positionId The ID of the position
     * @return The position struct containing position details
     * @dev Returns the raw position struct data
     */
    function getUserPosition(address user, uint256 positionId) external view returns (UserPosition memory);

    /**
     * @notice Returns the amount of a specific collateral in a position
     * @param user The owner of the position
     * @param positionId The ID of the position
     * @param asset The collateral asset to query
     * @return The amount of the asset in the position
     * @dev Raw amount without any price calculations
     */
    function getUserCollateralAmount(address user, uint256 positionId, address asset) external view returns (uint256);

    /**
     * @notice Returns all positions for a user
     * @param user The address to query positions for
     * @return An array of user positions
     * @dev Returns the entire positions array for the user
     */
    function getUserPositions(address user) external view returns (UserPosition[] memory);

    /**
     * @notice Returns the number of positions a user has
     * @param user The address to query
     * @return The number of positions
     * @dev Count of positions in the user's array
     */
    function getUserPositionsCount(address user) external view returns (uint256);

    /**
     * @notice Returns all assets in a position
     * @param user The owner of the position
     * @param positionId The ID of the position
     * @return An array of asset addresses in the position
     * @dev List of all assets used as collateral in the position
     */
    function getPositionAssets(address user, uint256 positionId) external view returns (address[] memory);

    /**
     * @notice Returns the current debt of a position excluding interest
     * @param user The owner of the position
     * @param positionId The ID of the position
     * @return The raw debt amount in USDC
     * @dev Returns only principal without accrued interest
     */
    function getPositionDebt(address user, uint256 positionId) external view returns (uint256);

    /**
     * @notice Calculates the total debt with accrued interest for a position
     * @param user The owner of the position
     * @param positionId The ID of the position
     * @return The debt amount with interest in USDC
     * @dev Includes interest accrued since last update
     */
    function calculateDebtWithInterest(address user, uint256 positionId) external view returns (uint256);

    /**
     * @notice Calculates the available credit limit for a position
     * @param user The owner of the position
     * @param positionId The ID of the position
     * @return The maximum borrowable amount in USDC
     * @dev Based on collateral value and borrowing thresholds
     */
    function calculateCreditLimit(address user, uint256 positionId) external view returns (uint256);

    /**
     * @notice Calculates the health factor of a position
     * @param user The owner of the position
     * @param positionId The ID of the position
     * @return The health factor (scaled by 1e18, >1 is healthy)
     * @dev Higher values indicate a safer position
     */
    function healthFactor(address user, uint256 positionId) external view returns (uint256);

    /**
     * @notice Checks if a position is eligible for liquidation
     * @param user The owner of the position
     * @param positionId The ID of the position
     * @return Whether the position can be liquidated
     * @dev Position is liquidatable if health factor falls below 1
     */
    function isLiquidatable(address user, uint256 positionId) external view returns (bool);

    /**
     * @notice Returns a summary of a position's state
     * @param user The owner of the position
     * @param positionId The ID of the position
     * @return totalCollateralValue The total value of collateral in the position
     * @return currentDebt The current debt including interest
     * @return availableCredit The available credit to borrow
     * @return isIsolated Whether the position is in isolation mode
     * @return isolatedAsset The isolated asset (if applicable)
     * @dev Provides a complete overview of the position's status
     */
    function getPositionSummary(address user, uint256 positionId)
        external
        view
        returns (
            uint256 totalCollateralValue,
            uint256 currentDebt,
            uint256 availableCredit,
            bool isIsolated,
            address isolatedAsset
        );

    /**
     * @notice Returns the highest risk tier among a position's collateral assets
     * @param user The owner of the position
     * @param positionId The ID of the position
     * @return The highest risk tier in the position
     * @dev Used to determine applicable interest rates
     */
    function getHighestTier(address user, uint256 positionId) external view returns (CollateralTier);

    // ------------ View Functions: Asset Information ------------

    /**
     * @notice Returns the configuration for an asset
     * @param asset The asset address to query
     * @return The asset configuration
     * @dev Complete configuration struct for the asset
     */
    function getAssetInfo(address asset) external view returns (Asset memory);

    /**
     * @notice Returns the current USD price of an asset
     * @param asset The asset address to query
     * @return The price in USD (scaled by oracle decimals)
     * @dev Fetches price from Chainlink oracle
     */
    function getAssetPrice(address asset) external view returns (uint256);

    /**
     * @notice Returns detailed information about an asset
     * @param asset The asset address to query
     * @return price The current USD price (scaled by oracle decimals)
     * @return totalSupplied The total amount supplied to the protocol
     * @return maxSupply The maximum supply threshold
     * @return borrowRate The current borrow rate for the asset
     * @return liquidationBonus The liquidation bonus for the asset
     * @return tier The risk tier of the asset
     * @dev Aggregates various asset metrics into a single call
     */
    function getAssetDetails(address asset)
        external
        view
        returns (
            uint256 price,
            uint256 totalSupplied,
            uint256 maxSupply,
            uint256 borrowRate,
            uint256 liquidationBonus,
            CollateralTier tier
        );

    /**
     * @notice Returns the raw price from an asset's oracle
     * @param oracle The address of the price oracle
     * @return The price from the oracle
     * @dev Validates oracle data for freshness and volatility
     */
    function getAssetPriceOracle(address oracle) external view returns (uint256);

    /**
     * @notice Checks if a user is eligible for rewards
     * @param user The address to check
     * @return Whether the user is eligible for rewards
     * @dev Based on time since last accrual and minimum supply
     */
    function isRewardable(address user) external view returns (bool);

    // ------------ Protocol State Variables ------------

    /**
     * @notice Total amount borrowed from the protocol
     * @return Current total borrow amount in USDC
     */
    function totalBorrow() external view returns (uint256);

    /**
     * @notice Total liquidity supplied to the protocol
     * @return Current total supply in USDC
     */
    function totalSuppliedLiquidity() external view returns (uint256);

    /**
     * @notice Total interest paid by borrowers
     * @return Accumulated borrower interest
     */
    function totalAccruedBorrowerInterest() external view returns (uint256);

    /**
     * @notice Total interest earned by suppliers
     * @return Accumulated supplier interest
     */
    function totalAccruedSupplierInterest() external view returns (uint256);

    /**
     * @notice Total liquidity withdrawn from the protocol
     * @return Cumulative withdrawn liquidity
     */
    function withdrawnLiquidity() external view returns (uint256);

    /**
     * @notice Target reward amount for eligible LPs
     * @return Maximum reward amount per full period
     */
    function targetReward() external view returns (uint256);

    /**
     * @notice Time interval for reward distribution
     * @return Reward period in seconds
     */
    function rewardInterval() external view returns (uint256);

    /**
     * @notice Minimum supply to be eligible for rewards
     * @return Minimum USDC equivalent required
     */
    function rewardableSupply() external view returns (uint256);

    /**
     * @notice Base interest rate for borrowing
     * @return Base rate in parts per million
     */
    function baseBorrowRate() external view returns (uint256);

    /**
     * @notice Target profit margin for the protocol
     * @return Profit target in parts per million
     */
    function baseProfitTarget() external view returns (uint256);

    /**
     * @notice Minimum governance tokens required for liquidation
     * @return Minimum token requirement
     */
    function liquidatorThreshold() external view returns (uint256);

    /**
     * @notice Current protocol version
     * @return Protocol version number
     */
    function version() external view returns (uint8);

    /**
     * @notice Treasury address for protocol fees
     * @return Treasury contract address
     */
    function treasury() external view returns (address);

    /**
     * @notice Fee charged for flash loans
     * @return Fee in basis points
     */
    function flashLoanFee() external view returns (uint256);

    /**
     * @notice Total fees collected from flash loans
     * @return Accumulated flash loan fees
     */
    function totalFlashLoanFees() external view returns (uint256);

    /**
     * @notice Base interest rate for a specific collateral tier
     * @param tier The tier to query
     * @return Base rate for the tier
     */
    function tierBaseBorrowRate(CollateralTier tier) external view returns (uint256);

    /**
     * @notice Liquidation bonus for a specific collateral tier
     * @param tier The tier to query
     * @return Liquidation bonus percentage
     */
    function tierLiquidationBonus(CollateralTier tier) external view returns (uint256);

    /**
     * @notice Total amount of an asset used as collateral
     * @param asset The asset to query
     * @return Total collateral amount
     */
    function totalCollateral(address asset) external view returns (uint256);

    /**
     * @notice Total value locked of an asset
     * @param asset The asset to query
     * @return TVL of the asset
     */
    function assetTVL(address asset) external view returns (uint256);
}
