// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;
/**
 *      ,,       ,,  ,,    ,,,    ,,   ,,,      ,,,    ,,,   ,,,          ,,,
 *      ███▄     ██  ███▀▀▀███▄   ██▄██▀▀██▄    ██▌     ██▌  ██▌        ▄▄███▄▄
 *     █████,   ██  ██▌          ██▌     └██▌  ██▌     ██▌  ██▌        ╟█   ╙██
 *     ██ └███ ██  ██▌└██╟██   l███▀▄███╟█    ██      ╟██  ╟█i        ▐█▌█▀▄██╟
 *    ██   ╙████  ██▌          ██▌     ,██▀   ╙██    ▄█▀  ██▌        ▐█▌    ██
 *   ██     ╙██  █████▀▀▄██▀  ██▌██▌╙███▀`     ▀██▄██▌   █████▀▄██▀ ▐█▌    ██╟
 *  ¬─      ¬─   ¬─¬─  ¬─¬─'  ¬─¬─¬─¬ ¬─'       ¬─¬─    '¬─   '─¬   ¬─     ¬─'
 *
 *      ,,,          ,,     ,,,    ,,,      ,,   ,,,  ,,,      ,,,    ,,,   ,,,    ,,,   ,,,
 *      ██▌          ███▀▀▀███▄   ███▄     ██   ██▄██▀▀██▄     ███▀▀▀███▄   ██▄██▀▀██▄  ▄██╟
 *     ██▌          ██▌          █████,   ██   ██▌     └██▌   ██▌          ██▌          ██
 *    ╟█l          ███▀▄███     ██ └███  ██   l██       ██╟  ███▀▄███     ██▌└██╟██    ╟█i
 *    ██▌         ██▌          ██    ╙████    ██▌     ,██▀  ██▌          ██▌           ██
 *   █████▀▄██▀  █████▀▀▄██▀  ██      ╙██    ██▌██▌╙███▀`  █████▀▀▄██▀  ╙██           ╙██
 *  ¬─     ¬─   ¬─¬─  ¬─¬─'  ¬─¬─     ¬─'   ¬─¬─   '¬─    '─¬   ¬─      ¬─'           ¬─'
 * @title Lendefi Protocol
 * @notice An efficient monolithic lending protocol
 * @author alexei@nlkimi-labs(dot)xyz
 * @dev Implements a secure and upgradeable collateralized lending protocol with Yield Token
 * @custom:security-contact security@alkimi.org
 * @custom:copyright Copyright (c) 2025 Alkimi Finance Org. All rights reserved.
 *
 * Core Features:
 * - Lending and borrowing with multiple collateral tiers
 * - Isolated and cross-collateral positions
 * - Dynamic interest rates based on utilization
 * - Flash loans with configurable fees
 * - Liquidation mechanism with tier-based bonuses
 * - Liquidity provider rewards system
 * - Price oracle integration with safety checks
 *
 * Security Features:
 * - Role-based access control
 * - Pausable functionality
 * - Non-reentrant operations
 * - Upgradeable contract pattern
 * - Oracle price validation
 * - Supply and debt caps
 *
 * @custom:roles
 * - DEFAULT_ADMIN_ROLE: Contract administration
 * - PAUSER_ROLE: Emergency pause/unpause
 * - MANAGER_ROLE: Protocol parameter updates
 * - UPGRADER_ROLE: Contract upgrades
 *
 * @custom:tiers Collateral tiers in ascending order of risk:
 * - STABLE: Lowest risk, stablecoins (5% liquidation bonus)
 * - CROSS_A: Low risk assets (8% liquidation bonus)
 * - CROSS_B: Medium risk assets (10% liquidation bonus)
 * - ISOLATED: High risk assets (15% liquidation bonus)
 *
 * @custom:inheritance
 * - IPROTOCOL: Protocol interface
 * - ERC20Upgradeable: Base token functionality
 * - ERC20PausableUpgradeable: Pausable token operations
 * - AccessControlUpgradeable: Role-based access
 * - ReentrancyGuardUpgradeable: Reentrancy protection
 * - UUPSUpgradeable: Upgrade pattern
 * - YodaMath: Interest calculations
 */

import {YodaMath} from "./lib/YodaMath.sol";
import {IPROTOCOL} from "../interfaces/IProtocol.sol";
import {IECOSYSTEM} from "../interfaces/IEcosystem.sol";
import {IFlashLoanReceiver} from "../interfaces/IFlashLoanReceiver.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IERC20, SafeERC20 as TH} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {AggregatorV3Interface} from "../vendor/@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {ERC20PausableUpgradeable} from
    "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PausableUpgradeable.sol";

/// @custom:oz-upgrades
contract Lendefi is
    IPROTOCOL,
    ERC20Upgradeable,
    ERC20PausableUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable,
    YodaMath
{
    using EnumerableSet for EnumerableSet.AddressSet;

    // Constants
    bytes32 internal constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 internal constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    bytes32 internal constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    // State variables
    /// @dev USDC token instance
    IERC20 internal usdcInstance;
    /// @dev governance token instance
    IERC20 internal tokenInstance;
    /// @dev ecosystem contract instance
    IECOSYSTEM internal ecosystemInstance;

    EnumerableSet.AddressSet internal listedAsset;

    /// @notice Total amount of USDC borrowed from the protocol
    /// @dev Tracks the sum of all active borrowing positions' principal
    uint256 public totalBorrow;

    /// @notice Total liquidity supplied to the protocol by liquidity providers
    /// @dev Denominated in USDC with 6 decimals, used for utilization calculations
    uint256 public totalSuppliedLiquidity;

    /// @notice Total interest paid by borrowers over the protocol's lifetime
    /// @dev Accumulated separately from principal for accounting purposes
    uint256 public totalAccruedBorrowerInterest;

    /// @notice Total interest earned by liquidity providers
    /// @dev Includes all interest distributed to LPs since protocol inception
    uint256 public totalAccruedSupplierInterest;

    /// @notice Total liquidity withdrawn from the protocol
    /// @dev Cumulative tracking of all withdrawals, used for analytics
    uint256 public withdrawnLiquidity;

    /// @notice Target reward amount for eligible liquidity providers
    /// @dev Maximum reward amount achievable over a full reward interval
    uint256 public targetReward;

    /// @notice Time interval for calculating rewards (in seconds)
    /// @dev Typically set to 180 days, used as denominator in reward calculations
    uint256 public rewardInterval;

    /// @notice Minimum supply required to be eligible for rewards
    /// @dev Users must supply at least this amount to qualify for ecosystem rewards
    uint256 public rewardableSupply;

    /// @notice Base interest rate applied to all loans
    /// @dev Expressed in parts per million (e.g., 0.06e6 = 6%)
    uint256 public baseBorrowRate;

    /// @notice Target profit margin for the protocol
    /// @dev Used to calculate fees and maintain protocol sustainability
    uint256 public baseProfitTarget;

    /// @notice Minimum governance tokens required to perform liquidations
    /// @dev Ensures liquidators have skin in the game by requiring token holdings
    uint256 public liquidatorThreshold;

    /// @notice Fee charged for flash loans in basis points
    /// @dev 9 basis points = 0.09%, maximum allowed is 100 (1%)
    uint256 public flashLoanFee;

    /// @notice Total fees collected from flash loans
    /// @dev Accumulated since inception, part of protocol revenue
    uint256 public totalFlashLoanFees;

    /// @notice Current contract version, incremented on upgrades
    /// @dev Used to track implementation versions for transparent upgrades
    uint8 public version;

    /// @notice Address of the treasury that receives protocol fees
    /// @dev Fees are sent here for protocol sustainability and governance
    address public treasury;

    // Mappings
    /// @notice Asset configuration details for supported collateral types
    /// @dev Maps asset address to its full configuration struct
    mapping(address => Asset) internal assetInfo;

    /// @notice User borrowing positions by address
    /// @dev Maps user address to an array of all their positions
    mapping(address => UserPosition[]) internal positions;

    /// @notice Collateral amounts by position and asset
    /// @dev Maps user address, position ID, and asset address to collateral amount
    mapping(address => mapping(uint256 => mapping(address => uint256))) internal positionCollateralAmounts;
    /// @notice List of assets used as collateral in each position
    /// @dev Maps user address and position ID to array of collateral asset addresses
    mapping(address => mapping(uint256 => address[])) internal positionCollateralAssets;
    /// @dev borrower address position mapping used to remove positonCollateralAssets when needed
    mapping(address src => mapping(uint256 => mapping(address => uint256 pos))) internal pcaPos;

    /// @notice Total value locked of each supported asset
    /// @dev Tracks how much of each asset is held by the protocol
    mapping(address => uint256) public assetTVL;

    /// @notice Base borrow rate for each collateral risk tier
    /// @dev Higher tiers have higher interest rates due to increased risk
    mapping(CollateralTier => uint256) public tierBaseBorrowRate;

    /// @notice Liquidation bonus percentage for each collateral tier
    /// @dev Higher risk tiers have larger liquidation bonuses
    mapping(CollateralTier => uint256) public tierLiquidationBonus;

    /// @notice Total amount of each asset used as collateral
    /// @dev Used for tracking collateral usage and supply caps
    mapping(address => uint256) public totalCollateral;

    /// @notice Timestamp of last reward accrual for each liquidity provider
    /// @dev Used to calculate eligible rewards based on time elapsed
    mapping(address src => uint256 time) internal liquidityAccrueTimeIndex;
    uint256[50] private __gap;

    /**
     * @notice Validates that the provided position ID exists for the specified user
     * @param user The address of the user who owns the position
     * @param positionId The ID of the position to validate
     * @dev Reverts with InvalidPosition error if the position ID exceeds the user's positions array length
     * @custom:security Position IDs are zero-indexed and must be less than the total number of positions
     */
    modifier validPosition(address user, uint256 positionId) {
        if (positionId >= positions[user].length) {
            revert InvalidPosition(user, positionId);
        }
        _;
    }

    /**
     * @notice Validates that the given position is in ACTIVE status
     * @param user The address of the position owner
     * @param positionId The ID of the position to validate
     * @dev Reverts with InactivePosition error if the position status is not ACTIVE
     * @custom:security This ensures operations are only performed on active positions
     * @custom:error InactivePosition if position has been CLOSED or LIQUIDATED
     */
    modifier activePosition(address user, uint256 positionId) {
        // First ensure the position exists
        if (positionId >= positions[user].length) {
            revert InvalidPosition(user, positionId);
        }

        // Then check if it's active
        if (positions[user][positionId].status != PositionStatus.ACTIVE) {
            revert InactivePosition(user, positionId);
        }
        _;
    }
    /**
     * @notice Validates that the asset is listed in the protocol
     * @param asset The address of the asset to validate
     * @dev Reverts with AssetNotListed error if the asset is not in the listedAsset set
     */

    modifier validAsset(address asset) {
        if (!listedAsset.contains(asset)) {
            revert AssetNotListed(asset);
        }
        _;
    }
    /// @custom:oz-upgrades-unsafe-allow constructor

    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the contract with core dependencies and parameters
     * @param usdc The address of the USDC stablecoin used for borrowing and liquidity
     * @param govToken The address of the governance token used for liquidator eligibility
     * @param ecosystem The address of the ecosystem contract that manages rewards
     * @param treasury_ The address of the treasury that collects protocol fees
     * @param timelock_ The address of the timelock contract for governance actions
     * @param guardian The address of the initial admin with pausing capability
     * @dev Sets up ERC20 token details, access control roles, and default protocol parameters
     *      including interest rates and liquidation bonuses for each collateral tier
     * @custom:oz-upgrades-unsafe initializer is used instead of constructor for proxy pattern
     */
    function initialize(
        address usdc,
        address govToken,
        address ecosystem,
        address treasury_,
        address timelock_,
        address guardian
    ) external initializer {
        __ERC20_init("LENDEFI YIELD TOKEN", "LYT");
        __ERC20Pausable_init();
        __AccessControl_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        require(
            usdc != address(0) && govToken != address(0) && treasury_ != address(0) && timelock_ != address(0)
                && guardian != address(0),
            "ZERO_ADDRESS_DETECTED"
        );

        _grantRole(DEFAULT_ADMIN_ROLE, guardian);
        _grantRole(PAUSER_ROLE, guardian);
        _grantRole(MANAGER_ROLE, timelock_);
        _grantRole(UPGRADER_ROLE, timelock_);

        usdcInstance = IERC20(usdc);
        tokenInstance = IERC20(govToken);
        ecosystemInstance = IECOSYSTEM(payable(ecosystem));
        treasury = treasury_;

        // Initialize default parameters
        targetReward = 2_000 ether;
        rewardInterval = 180 days;
        rewardableSupply = 100_000 * WAD;
        baseBorrowRate = 0.06e6;
        baseProfitTarget = 0.01e6;
        liquidatorThreshold = 20_000 ether;

        // Initialize tier parameters
        tierBaseBorrowRate[CollateralTier.ISOLATED] = 0.15e6; // 15%
        tierBaseBorrowRate[CollateralTier.CROSS_A] = 0.08e6; // 8%
        tierBaseBorrowRate[CollateralTier.CROSS_B] = 0.12e6; // 12%
        tierBaseBorrowRate[CollateralTier.STABLE] = 0.05e6; // 5%

        tierLiquidationBonus[CollateralTier.ISOLATED] = 0.15e6; // 15%
        tierLiquidationBonus[CollateralTier.CROSS_A] = 0.08e6; // 8%
        tierLiquidationBonus[CollateralTier.CROSS_B] = 0.1e6; // 10%
        tierLiquidationBonus[CollateralTier.STABLE] = 0.05e6; // 5%

        ++version;
        emit Initialized(msg.sender);
    }

    /**
     * @notice Pauses all protocol operations in case of emergency
     * @dev Can only be called by accounts with PAUSER_ROLE
     * @custom:security This is a critical emergency function that should be carefully controlled
     * @custom:access Restricted to PAUSER_ROLE
     * @custom:events Emits a Paused event from ERC20Pausable
     */
    function pause() external override onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /**
     * @notice Unpauses protocol operations, returning to normal functioning
     * @dev Can only be called by accounts with PAUSER_ROLE
     * @custom:security Should only be called after thorough security verification
     * @custom:access Restricted to PAUSER_ROLE
     * @custom:events Emits an Unpaused event from ERC20Pausable
     */
    function unpause() external override onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /**
     * @notice Executes a flash loan of USDC tokens
     * @param receiver Address of the contract receiving the flash loan
     * @param token Token to be flash loaned (must be USDC)
     * @param amount Amount of tokens to flash loan
     * @param params Arbitrary data to be passed to the receiver's executeOperation function
     * @dev This function enables atomic flash loans with the following flow:
     *      1. Checks token is USDC and sufficient liquidity exists
     *      2. Transfers tokens to receiver
     *      3. Calls receiver's executeOperation function
     *      4. Verifies funds are returned with fee
     * @custom:security Non-reentrant and pausable to prevent attack vectors
     * @custom:fee Flash loan fee is configurable, default 9 basis points (0.09%)
     * @custom:events Emits FlashLoan event with loan details and fee
     */
    function flashLoan(address receiver, address token, uint256 amount, bytes calldata params)
        external
        nonReentrant
        whenNotPaused
    {
        // Replace require with if-revert pattern
        if (token != address(usdcInstance)) {
            revert OnlyUsdcSupported(token);
        }

        uint256 availableLiquidity = usdcInstance.balanceOf(address(this));
        if (amount > availableLiquidity) {
            revert InsufficientFlashLoanLiquidity(token, amount, availableLiquidity);
        }

        // Calculate fee
        uint256 fee = (amount * flashLoanFee) / 10000;

        // Transfer funds to receiver
        TH.safeTransfer(IERC20(token), receiver, amount);

        // Execute callback on receiver
        bool success = IFlashLoanReceiver(receiver).executeOperation(
            token,
            amount,
            fee,
            msg.sender, // initiator
            params
        );

        if (!success) {
            revert FlashLoanFailed();
        }

        // Replace require with if-revert pattern
        uint256 requiredBalance = availableLiquidity + fee;
        uint256 currentBalance = usdcInstance.balanceOf(address(this));

        if (currentBalance < requiredBalance) {
            revert FlashLoanFundsNotReturned(requiredBalance, currentBalance);
        }

        // Track flash loan fee
        totalFlashLoanFees += fee;

        emit FlashLoan(msg.sender, receiver, token, amount, fee);
    }

    /**
     * @notice Updates the flash loan fee percentage
     * @param newFee The new fee in basis points (1 = 0.01%)
     * @dev Can only be called by accounts with MANAGER_ROLE
     * @custom:security Maximum fee is capped at 100 basis points (1%) to protect users
     * @custom:access Restricted to MANAGER_ROLE
     * @custom:events Emits UpdateFlashLoanFee event with new fee value
     */
    function updateFlashLoanFee(uint256 newFee) external onlyRole(MANAGER_ROLE) {
        // Add minimum fee check
        if (newFee < 5) {
            revert FeeTooLow(newFee, 5); // Minimum 5 basis points (0.05%)
        }

        // Existing maximum check
        if (newFee > 100) {
            revert FeeTooHigh(newFee, 100);
        }

        flashLoanFee = newFee;
        emit UpdateFlashLoanFee(newFee);
    }

    /**
     * @notice Allows users to supply USDC liquidity to the protocol in exchange for LYT tokens
     * @param amount The amount of USDC to supply (in USDC decimals - 6)
     * @dev Mints LYT tokens representing share of the lending pool based on current exchange rate
     * @custom:security Non-reentrant to prevent reentrancy attacks
     * @custom:validation Checks:
     *      - User has sufficient USDC balance
     * @custom:calculations
     *      - If pool is empty: 1:1 mint ratio
     *      - Otherwise: amount * totalSupply / totalAssets
     *      - Special case for 0 utilization: 1:1 mint ratio
     * @custom:state Updates:
     *      - Increases totalSuppliedLiquidity
     *      - Updates liquidityAccrueTimeIndex for rewards
     *      - Mints LYT tokens to supplier
     * @custom:events Emits:
     *      - SupplyLiquidity with supplier address and amount
     */
    function supplyLiquidity(uint256 amount) external nonReentrant {
        uint256 userBalance = usdcInstance.balanceOf(msg.sender);
        if (userBalance < amount) {
            revert InsufficientTokenBalance(address(usdcInstance), msg.sender, userBalance);
        }

        uint256 total = usdcInstance.balanceOf(address(this)) + totalBorrow;
        if (total == 0) total = WAD;
        uint256 supply = totalSupply();
        uint256 value = (amount * supply) / total;
        uint256 utilization = getUtilization();
        if (supply == 0 || utilization == 0) value = amount;

        totalSuppliedLiquidity += amount;

        liquidityAccrueTimeIndex[msg.sender] = block.timestamp;
        _mint(msg.sender, value);

        emit SupplyLiquidity(msg.sender, amount);
        TH.safeTransferFrom(usdcInstance, msg.sender, address(this), amount);
    }

    /**
     * @notice Allows users to exchange LYT tokens for underlying USDC with accrued interest
     * @param amount The amount of LYT tokens to exchange
     * @dev Calculates redemption value based on current pool state and profit target
     * @custom:security Non-reentrant to prevent reentrancy attacks
     * @custom:validation Checks:
     *      - User has sufficient LYT token balance
     * @custom:calculations
     *      - Base amount = (amount * totalSuppliedLiquidity) / totalSupply
     *      - Protocol fee = baseAmount * baseProfitTarget if profitable
     *      - Redemption value = (amount * (USDC balance + totalBorrow)) / totalSupply
     * @custom:state Updates:
     *      - Decreases totalSuppliedLiquidity
     *      - Updates withdrawnLiquidity
     *      - Updates totalAccruedSupplierInterest
     *      - Burns user's LYT tokens
     *      - Mints fee to treasury if profitable
     * @custom:events Emits:
     *      - Exchange with sender address, LYT amount, and USDC value
     */
    function exchange(uint256 amount) external nonReentrant {
        uint256 userBal = balanceOf(msg.sender);
        if (userBal < amount) {
            revert InsufficientTokenBalance(address(this), msg.sender, userBal);
        }

        if (userBal <= amount) amount = userBal;

        uint256 fee;
        uint256 supply = totalSupply();
        uint256 baseAmount = (amount * totalSuppliedLiquidity) / supply;
        uint256 target = (baseAmount * baseProfitTarget) / WAD; // 1% commission
        uint256 total = usdcInstance.balanceOf(address(this)) + totalBorrow;

        if (total >= totalSuppliedLiquidity + target) {
            // Only charge fee when there's enough profit to sustain it
            fee = target;
            _mint(treasury, fee);
        }

        uint256 value = (amount * total) / totalSupply();

        totalSuppliedLiquidity -= baseAmount;
        withdrawnLiquidity += value;
        totalAccruedSupplierInterest += value - baseAmount;

        _rewardInternal(baseAmount);
        _burn(msg.sender, amount);

        emit Exchange(msg.sender, amount, value);
        TH.safeTransfer(usdcInstance, msg.sender, value);
    }

    /**
     * @notice Allows users to supply collateral assets to a borrowing position
     * @param asset The address of the collateral asset to supply
     * @param amount The amount of the asset to supply
     * @param positionId The ID of the position to supply collateral to
     * @dev Handles both isolated and cross-collateral positions with appropriate validations
     * @custom:security Non-reentrant and pausable to prevent attack vectors
     * @custom:validation Checks:
     *  - Asset is listed and active
     *  - Position exists
     *  - Isolation mode constraints
     *  - Supply cap limits
     *  - Maximum assets per position (20)
     * @custom:events Emits:
     *  - TVLUpdated with new total value locked
     *  - SupplyCollateral with supply details
     */
    function supplyCollateral(address asset, uint256 amount, uint256 positionId)
        external
        activePosition(msg.sender, positionId)
        validAsset(asset)
        nonReentrant
        whenNotPaused
    {
        Asset storage assetConfig = assetInfo[asset];
        if (assetConfig.active != 1) {
            revert AssetDisabled(asset);
        }

        if (totalCollateral[asset] + amount > assetConfig.maxSupplyThreshold) {
            revert SupplyCapExceeded(asset, totalCollateral[asset] + amount, assetConfig.maxSupplyThreshold);
        }

        UserPosition storage position = positions[msg.sender][positionId];
        address[] storage posAssets = positionCollateralAssets[msg.sender][positionId];

        // Verify position is active
        if (position.status != PositionStatus.ACTIVE) {
            revert InactivePosition(msg.sender, positionId);
        }

        // Check if this is an ISOLATED tier asset being added to a cross-collateral position
        if (assetConfig.tier == CollateralTier.ISOLATED && !position.isIsolated) {
            revert IsolationModeRequired(asset);
        }

        // Isolation mode checks
        if (position.isIsolated && posAssets.length > 0 && asset != posAssets[0]) {
            revert InvalidPositionAsset(msg.sender, positionId, asset, posAssets[0]);
        }

        // Check if asset needs to be added to the position's assets array
        bool assetAlreadyAdded = false;

        // For isolated positions created with this asset, it should already be in the array
        if (posAssets.length > 0) {
            // Check if the position of this asset in the array is valid
            uint256 assetPos = pcaPos[msg.sender][positionId][asset];
            if (assetPos < posAssets.length && posAssets[assetPos] == asset) {
                assetAlreadyAdded = true;
            }
        }

        // Add asset to positionCollateralAssets array if not already present
        if (!assetAlreadyAdded) {
            if (posAssets.length >= 20) {
                revert TooManyAssets(msg.sender, positionId);
            }
            pcaPos[msg.sender][positionId][asset] = posAssets.length;
            posAssets.push(asset);
        }

        positionCollateralAmounts[msg.sender][positionId][asset] += amount;
        totalCollateral[asset] += amount;
        assetTVL[asset] += amount;

        emit TVLUpdated(asset, assetTVL[asset]);
        emit SupplyCollateral(msg.sender, positionId, asset, amount);
        TH.safeTransferFrom(IERC20(asset), msg.sender, address(this), amount);
    }

    /**
     * @notice Allows users to withdraw collateral assets from their borrowing position
     * @param asset The address of the collateral asset to withdraw
     * @param amount The amount of the asset to withdraw
     * @param positionId The ID of the position to withdraw from
     * @dev Process:
     *      1. Validates position is active
     *      2. Validates isolation mode constraints
     *      3. Checks sufficient collateral balance
     *      4. Updates collateral state
     *      5. Verifies remaining collateral supports existing debt
     *      6. Removes asset from position if fully withdrawn
     * @custom:security Non-reentrant and pausable to prevent attack vectors
     */
    function withdrawCollateral(address asset, uint256 amount, uint256 positionId)
        external
        activePosition(msg.sender, positionId)
        nonReentrant
        whenNotPaused
    {
        UserPosition storage position = positions[msg.sender][positionId];

        // Verify position is active
        if (position.status != PositionStatus.ACTIVE) {
            revert InactivePosition(msg.sender, positionId);
        }

        address[] storage posAssets = positionCollateralAssets[msg.sender][positionId];

        // Check isolation mode constraints
        if (position.isIsolated && asset != posAssets[0]) {
            revert InvalidPositionAsset(msg.sender, positionId, asset, posAssets[0]);
        }

        uint256 currentBalance = positionCollateralAmounts[msg.sender][positionId][asset];
        if (currentBalance < amount) {
            revert InsufficientCollateralBalance(msg.sender, positionId, asset, amount, currentBalance);
        }

        // First reduce the collateral
        positionCollateralAmounts[msg.sender][positionId][asset] -= amount;
        totalCollateral[asset] -= amount;
        assetTVL[asset] -= amount;

        // Then check if remaining collateral supports existing debt
        uint256 creditLimit = calculateCreditLimit(msg.sender, positionId);
        if (creditLimit < position.debtAmount) {
            revert WithdrawalExceedsCreditLimit(msg.sender, positionId, position.debtAmount, creditLimit);
        }

        // Remove asset from position assets array if balance becomes 0
        if (positionCollateralAmounts[msg.sender][positionId][asset] == 0) {
            uint256 ipos = pcaPos[msg.sender][positionId][asset];
            uint256 len = posAssets.length;
            posAssets[ipos] = posAssets[len - 1];
            posAssets.pop();

            // Update the pcaPos mapping for the swapped asset
            if (ipos < len - 1) {
                pcaPos[msg.sender][positionId][posAssets[ipos]] = ipos;
            }
        }

        emit TVLUpdated(asset, assetTVL[asset]);
        emit WithdrawCollateral(msg.sender, positionId, asset, amount);
        TH.safeTransfer(IERC20(asset), msg.sender, amount);
    }

    /**
     * @notice Creates a new borrowing position for the caller
     * @param asset The initial collateral asset address for the position
     * @param isIsolated Whether the position should use isolation mode
     * @dev Creates a new position and optionally enables isolation mode with the specified asset
     * @custom:security Non-reentrant and pausable to prevent attack vectors
     * @custom:validation Checks:
     *  - Asset must be listed in the protocol
     *  - If isolation mode is enabled, asset must be eligible
     * @custom:events Emits:
     *  - PositionCreated with user address, position ID, and isolation mode status
     * @custom:access Public function, any user can create positions
     */
    function createPosition(address asset, bool isIsolated) external validAsset(asset) nonReentrant whenNotPaused {
        UserPosition storage newPosition = positions[msg.sender].push();
        newPosition.isIsolated = isIsolated;
        newPosition.status = PositionStatus.ACTIVE;
        if (isIsolated) {
            address[] storage assets = positionCollateralAssets[msg.sender][positions[msg.sender].length - 1];
            assets.push(asset);
        }

        emit PositionCreated(msg.sender, positions[msg.sender].length - 1, isIsolated);
    }

    /**
     * @notice Allows users to borrow USDC against their collateral position
     * @param positionId The ID of the borrower's position
     * @param amount The amount of USDC to borrow
     * @dev Process:
     *      1. Checks protocol liquidity
     *      2. Validates isolation mode constraints
     *      3. Verifies credit limit
     *      4. Updates position state and protocol metrics
     * @custom:security Non-reentrant and pausable to prevent attack vectors
     * @custom:validation Checks:
     *      - Position exists (via validPosition modifier)
     *      - Sufficient protocol liquidity
     *      - Isolation debt cap (if applicable)
     *      - Isolation collateral existence
     *      - Credit limit not exceeded
     * @custom:events Emits:
     *      - Borrow event with borrower address, position ID, and amount
     * @custom:state Updates:
     *      - Position debt amount
     *      - Last interest accrual timestamp
     *      - Total protocol borrow amount
     */
    function borrow(uint256 positionId, uint256 amount)
        external
        activePosition(msg.sender, positionId)
        nonReentrant
        whenNotPaused
    {
        if (totalBorrow + amount > totalSuppliedLiquidity) {
            revert InsufficientLiquidity(amount, totalSuppliedLiquidity - totalBorrow);
        }

        UserPosition storage position = positions[msg.sender][positionId];

        // Check isolation mode constraints if applicable
        if (position.isIsolated) {
            address posAsset = positionCollateralAssets[msg.sender][positionId][0];
            Asset memory asset = assetInfo[posAsset];

            // Check isolation debt cap
            if (position.debtAmount + amount > asset.isolationDebtCap) {
                revert IsolationDebtCapExceeded(posAsset, position.debtAmount + amount, asset.isolationDebtCap);
            }

            // Check that collateral exists for isolated asset
            if (positionCollateralAmounts[msg.sender][positionId][posAsset] == 0) {
                revert NoIsolatedCollateral(msg.sender, positionId, posAsset);
            }
        }

        // Check if borrow amount is within credit limit
        uint256 creditLimit = calculateCreditLimit(msg.sender, positionId);
        if (position.debtAmount + amount > creditLimit) {
            revert ExceedsCreditLimit(position.debtAmount + amount, creditLimit);
        }

        // Update state
        position.debtAmount += amount;
        position.lastInterestAccrual = block.timestamp;
        totalBorrow += amount;

        emit Borrow(msg.sender, positionId, amount);
        TH.safeTransfer(usdcInstance, msg.sender, amount);
    }

    /**
     * @notice Allows users to repay debt on their borrowing position
     * @param positionId The ID of the position to repay debt for
     * @param amount The amount of USDC to repay
     * @dev Handles both partial and full repayments, with interest paid first
     * @custom:security Non-reentrant and pausable to prevent attack vectors
     * @custom:validation Checks:
     *      - Position exists (via validPosition modifier)
     *      - Position has debt to repay
     * @custom:calculations
     *      - Calculates total debt with accrued interest
     *      - Caps repayment at total debt amount
     *      - Separates interest from principal repayment
     * @custom:events Emits:
     *      - Repay with amount repaid
     *      - InterestAccrued with interest amount
     * @custom:state Updates:
     *      - Position debt amount
     *      - Total protocol borrow amount
     *      - Total accrued borrower interest
     *      - Last interest accrual timestamp
     */
    function repay(uint256 positionId, uint256 amount)
        external
        activePosition(msg.sender, positionId)
        nonReentrant
        whenNotPaused
    {
        UserPosition storage position = positions[msg.sender][positionId];

        uint256 debt = calculateDebtWithInterest(msg.sender, positionId);
        if (debt == 0) {
            revert NoDebtToRepay(msg.sender, positionId);
        }

        uint256 repayAmount = amount > debt ? debt : amount;

        // Then update state
        uint256 loan = position.debtAmount;
        position.debtAmount = loan > repayAmount ? loan - repayAmount : 0;
        totalBorrow = totalBorrow > repayAmount ? totalBorrow - repayAmount : 0;

        // Calculate and track interest separately
        uint256 interestAccrued = debt - loan;
        if (interestAccrued > 0) {
            totalAccruedBorrowerInterest += interestAccrued;
        }

        position.lastInterestAccrual = block.timestamp;

        emit Repay(msg.sender, positionId, repayAmount);
        emit InterestAccrued(msg.sender, positionId, interestAccrued);

        TH.safeTransferFrom(usdcInstance, msg.sender, address(this), repayAmount);
    }

    /**
     * @notice Closes a borrowing position by repaying all debt and withdrawing collateral
     * @param positionId The ID of the position to close
     * @dev Process:
     *      1. Repays any outstanding debt with interest
     *      2. Withdraws all collateral assets
     *      3. Clears isolation mode settings if active
     *      4. Removes the position from user's positions array
     * @custom:security Non-reentrant and pausable to prevent attack vectors
     * @custom:validation Checks:
     *      - Position exists (via validPosition modifier)
     *      - User has sufficient USDC balance to repay debt
     * @custom:events Emits:
     *      - Repay when debt is repaid
     *      - WithdrawCollateral for each asset withdrawn
     *      - ExitedIsolationMode if position was in isolation mode
     *      - PositionClosed when position is fully closed
     * @custom:state Updates:
     *      - Clears position debt and collateral
     *      - Updates total protocol borrow amount
     *      - Updates total collateral amounts
     *      - Removes position from storage
     */
    function exitPosition(uint256 positionId)
        external
        activePosition(msg.sender, positionId)
        nonReentrant
        whenNotPaused
    {
        UserPosition storage position = positions[msg.sender][positionId];
        address[] storage posAssets = positionCollateralAssets[msg.sender][positionId];

        // If there's debt, repay it first
        if (position.debtAmount > 0) {
            uint256 debt = calculateDebtWithInterest(msg.sender, positionId);
            uint256 userBalance = usdcInstance.balanceOf(msg.sender);

            if (userBalance < debt) {
                revert InsufficientTokenBalance(address(usdcInstance), msg.sender, userBalance);
            }

            position.debtAmount = 0;
            position.lastInterestAccrual = 0;
            totalBorrow -= debt;

            TH.safeTransferFrom(usdcInstance, msg.sender, address(this), debt);
            emit Repay(msg.sender, positionId, debt);
        }

        // Withdraw all collateral
        for (uint256 i = 0; i < posAssets.length; i++) {
            address asset = posAssets[i];
            uint256 amount = positionCollateralAmounts[msg.sender][positionId][asset];
            if (amount > 0) {
                positionCollateralAmounts[msg.sender][positionId][asset] = 0;
                totalCollateral[asset] -= amount;
                TH.safeTransfer(IERC20(asset), msg.sender, amount);
                emit WithdrawCollateral(msg.sender, positionId, asset, amount);
            }
        }

        delete positions[msg.sender][positionId].debtAmount;
        delete positionCollateralAssets[msg.sender][positionId];
        positions[msg.sender][positionId].status = PositionStatus.CLOSED;

        emit PositionClosed(msg.sender, positionId);
    }

    /**
     * @notice Liquidates an undercollateralized borrowing position
     * @param user The address of the position owner to liquidate
     * @param positionId The ID of the position to liquidate
     * @dev Process:
     *      1. Verifies liquidator has sufficient governance tokens
     *      2. Confirms position is actually liquidatable (health factor < 1)
     *      3. Calculates total debt including accrued interest
     *      4. Determines liquidation bonus based on collateral tier
     *      5. Transfers required USDC from liquidator
     *      6. Transfers all position collateral to liquidator
     * @custom:security Non-reentrant and pausable to prevent attack vectors
     * @custom:validation Checks:
     *      - Position exists (via validPosition modifier)
     *      - Liquidator has sufficient governance tokens
     *      - Position is actually liquidatable
     *      - Liquidator has sufficient USDC to cover debt + bonus
     * @custom:rewards Liquidator receives:
     *      - All collateral in the position
     *      - Liquidation bonus (varies by tier)
     * @custom:events Emits:
     *      - Liquidated event with user, position ID, and debt amount
     *      - WithdrawCollateral events for each collateral asset transferred
     * @custom:state Updates:
     *      - Clears position debt
     *      - Updates total protocol borrow amount
     *      - Updates total accrued interest
     *      - Transfers all collateral to liquidator
     */
    function liquidate(address user, uint256 positionId)
        external
        activePosition(user, positionId)
        nonReentrant
        whenNotPaused
    {
        // Check if liquidator has enough governance tokens
        uint256 govTokenBalance = tokenInstance.balanceOf(msg.sender);
        if (govTokenBalance < liquidatorThreshold) {
            revert InsufficientGovTokens(msg.sender, liquidatorThreshold, govTokenBalance);
        }

        // Check if position is actually liquidatable
        if (!isLiquidatable(user, positionId)) {
            revert NotLiquidatable(user, positionId);
        }

        // Calculate debt and liquidation bonus
        UserPosition storage position = positions[user][positionId];
        uint256 debtWithInterest = calculateDebtWithInterest(user, positionId);

        uint256 interestAccrued = debtWithInterest - position.debtAmount;
        if (interestAccrued > 0) {
            totalAccruedBorrowerInterest += interestAccrued;
        }

        uint256 liquidationBonus;

        if (position.isIsolated) {
            Asset memory asset = assetInfo[positionCollateralAssets[user][positionId][0]];
            liquidationBonus = tierLiquidationBonus[asset.tier];
        } else {
            CollateralTier tier = getHighestTier(user, positionId);
            liquidationBonus = tierLiquidationBonus[tier];
        }

        // Calculate total debt including liquidation bonus
        uint256 totalDebt = debtWithInterest + (debtWithInterest * liquidationBonus / WAD);

        // Update position state
        position.isIsolated = false;
        position.debtAmount = 0;
        position.lastInterestAccrual = 0;
        position.status = PositionStatus.LIQUIDATED;
        totalBorrow -= debtWithInterest;

        emit Liquidated(user, positionId, debtWithInterest);

        // Transfer debt + bonus from liquidator
        TH.safeTransferFrom(usdcInstance, msg.sender, address(this), totalDebt);

        // Transfer all collateral to liquidator
        _transferCollateralToLiquidator(user, positionId, msg.sender);
    }

    /**
     * @notice Updates the base profit target rate for the protocol
     * @param rate The new base profit target rate in parts per million (e.g., 0.0025e6 = 0.25%)
     * @dev Updates the profit target used for calculating protocol fees and rewards
     * @custom:security Can only be called by accounts with MANAGER_ROLE
     * @custom:validation Checks:
     *      - Rate must be at least 0.25% (0.0025e6)
     * @custom:events Emits:
     *      - UpdateBaseProfitTarget with new rate value
     */
    function updateBaseProfitTarget(uint256 rate) external onlyRole(MANAGER_ROLE) {
        if (rate < 0.0025e6) {
            revert RateTooLow(rate, 0.0025e6);
        }
        baseProfitTarget = rate;
        emit UpdateBaseProfitTarget(rate);
    }

    /**
     * @notice Updates the base borrow interest rate for the protocol
     * @param rate The new base borrow rate in parts per million (e.g., 0.01e6 = 1%)
     * @dev Updates the minimum borrow rate applied to all loans
     * @custom:security Can only be called by accounts with MANAGER_ROLE
     * @custom:validation Checks:
     *      - Rate must be at least 1% (0.01e6)
     * @custom:events Emits:
     *      - UpdateBaseBorrowRate with new rate value
     */
    function updateBaseBorrowRate(uint256 rate) external onlyRole(MANAGER_ROLE) {
        if (rate < 0.01e6) {
            revert RateTooLow(rate, 0.01e6);
        }
        baseBorrowRate = rate;
        emit UpdateBaseBorrowRate(rate);
    }

    /**
     * @notice Updates the target reward amount for liquidity providers
     * @param amount The new target reward amount in LP tokens
     * @dev Updates the maximum reward amount achievable over a full reward interval
     * @custom:security Can only be called by accounts with MANAGER_ROLE
     * @custom:validation Checks:
     *      - Amount must not exceed 10,000 tokens
     * @custom:events Emits:
     *      - UpdateTargetReward with new amount
     */
    function updateTargetReward(uint256 amount) external onlyRole(MANAGER_ROLE) {
        if (amount > 10_000 ether) {
            revert RewardTooHigh(amount, 10_000 ether);
        }
        targetReward = amount;
        emit UpdateTargetReward(amount);
    }

    /**
     * @notice Updates the time interval for calculating liquidity provider rewards
     * @param interval The new reward interval in seconds
     * @dev Updates the duration over which max rewards can be earned
     * @custom:security Can only be called by accounts with MANAGER_ROLE
     * @custom:validation Checks:
     *      - Interval must be at least 90 days
     * @custom:events Emits:
     *      - UpdateRewardInterval with new interval value
     */
    function updateRewardInterval(uint256 interval) external onlyRole(MANAGER_ROLE) {
        if (interval < 90 days) {
            revert RewardIntervalTooShort(interval, 90 days);
        }
        rewardInterval = interval;
        emit UpdateRewardInterval(interval);
    }

    /**
     * @notice Updates the minimum supply required for reward eligibility
     * @param amount The new minimum supply amount (scaled by WAD)
     * @dev Updates the threshold for liquidity providers to be eligible for rewards
     * @custom:security Can only be called by accounts with MANAGER_ROLE
     * @custom:validation Checks:
     *      - Amount must be at least 20,000 WAD
     * @custom:events Emits:
     *      - UpdateRewardableSupply with new amount
     */
    function updateRewardableSupply(uint256 amount) external onlyRole(MANAGER_ROLE) {
        if (amount < 20_000 * WAD) {
            revert RewardableSupplyTooLow(amount, 20_000 * WAD);
        }
        rewardableSupply = amount;
        emit UpdateRewardableSupply(amount);
    }

    /**
     * @notice Updates the minimum governance tokens required to perform liquidations
     * @param amount The new threshold amount in governance tokens (18 decimals)
     * @dev Updates the minimum token requirement for liquidator eligibility
     * @custom:security Can only be called by accounts with MANAGER_ROLE
     * @custom:validation Checks:
     *      - Amount must be at least 10 tokens
     * @custom:events Emits:
     *      - UpdateLiquidatorThreshold with new amount
     */
    function updateLiquidatorThreshold(uint256 amount) external onlyRole(MANAGER_ROLE) {
        if (amount < 10 ether) {
            revert LiquidatorThresholdTooLow(amount, 10 ether);
        }
        liquidatorThreshold = amount;
        emit UpdateLiquidatorThreshold(amount);
    }

    /**
     * @notice Updates the risk parameters for a collateral tier
     * @param tier The collateral tier to update
     * @param borrowRate The new base borrow rate for the tier (in parts per million)
     * @param liquidationBonus The new liquidation bonus for the tier (in parts per million)
     * @dev Updates both interest rates and liquidation incentives for a specific risk tier
     * @custom:security Can only be called by accounts with MANAGER_ROLE
     * @custom:validation Checks:
     *      - Borrow rate must not exceed 25% (0.25e6)
     *      - Liquidation bonus must not exceed 20% (0.2e6)
     * @custom:events Emits:
     *      - TierParametersUpdated with tier, new borrow rate, and new liquidation bonus
     */
    function updateTierParameters(CollateralTier tier, uint256 borrowRate, uint256 liquidationBonus)
        external
        onlyRole(MANAGER_ROLE)
    {
        if (borrowRate > 0.25e6) {
            revert RateTooHigh(borrowRate, 0.25e6);
        }
        if (liquidationBonus > 0.2e6) {
            revert BonusTooHigh(liquidationBonus, 0.2e6);
        }

        tierBaseBorrowRate[tier] = borrowRate;
        tierLiquidationBonus[tier] = liquidationBonus;

        emit TierParametersUpdated(tier, borrowRate, liquidationBonus);
    }

    /**
     * @notice Updates the risk tier classification for a listed asset
     * @param asset The address of the asset to update
     * @param newTier The new CollateralTier to assign to the asset
     * @dev Changes the risk classification which affects interest rates and liquidation parameters
     * @custom:security Can only be called by accounts with MANAGER_ROLE
     * @custom:validation Checks:
     *      - Asset must be listed in the protocol
     * @custom:events Emits:
     *      - AssetTierUpdated with asset address and new tier
     * @custom:impact Changes:
     *      - Asset's borrow rate via tierBaseBorrowRate
     *      - Asset's liquidation bonus via tierLiquidationBonus
     */
    function updateAssetTier(address asset, CollateralTier newTier) external validAsset(asset) onlyRole(MANAGER_ROLE) {
        // if (!listedAsset.contains(asset)) {
        //     revert AssetNotListed(asset);
        // }

        assetInfo[asset].tier = newTier;

        emit AssetTierUpdated(asset, newTier);
    }

    /**
     * @notice Updates or adds a new asset configuration in the protocol
     * @param asset Address of the token to configure
     * @param oracle_ Address of the Chainlink price feed for asset/USD
     * @param oracleDecimals Number of decimals in the oracle price feed
     * @param assetDecimals Number of decimals in the asset token
     * @param active Whether the asset is enabled (1) or disabled (0)
     * @param borrowThreshold LTV ratio for borrowing (e.g., 870 = 87%)
     * @param liquidationThreshold LTV ratio for liquidation (e.g., 920 = 92%)
     * @param maxSupplyLimit Maximum amount of this asset allowed in protocol
     * @param tier Risk category of the asset (STABLE, CROSS_A, CROSS_B, ISOLATED)
     * @param isolationDebtCap Maximum debt allowed when used in isolation mode
     * @dev Manages all configuration parameters for an asset in a single function
     * @custom:security Can only be called by accounts with MANAGER_ROLE
     * @custom:validation Adds asset to listedAsset set if not already present
     * @custom:state Updates:
     *      - Asset configuration in assetInfo mapping
     *      - Listed assets enumerable set
     * @custom:events Emits:
     *      - UpdateAssetConfig with asset address
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
    ) external onlyRole(MANAGER_ROLE) {
        if (!listedAsset.contains(asset)) {
            require(listedAsset.add(asset), "ADDING_ASSET");
        }

        Asset storage item = assetInfo[asset];

        item.active = active;
        item.oracleUSD = oracle_;
        item.oracleDecimals = oracleDecimals;
        item.decimals = assetDecimals;
        item.borrowThreshold = borrowThreshold;
        item.liquidationThreshold = liquidationThreshold;
        item.maxSupplyThreshold = maxSupplyLimit;
        item.tier = tier;
        item.isolationDebtCap = isolationDebtCap;

        emit UpdateAssetConfig(asset);
    }

    /**
     * @notice Retrieves the current borrow rates and liquidation bonuses for all collateral tiers
     * @dev Returns two fixed arrays containing rates for ISOLATED, CROSS_A, CROSS_B, and STABLE tiers in that order
     * @return borrowRates Array of borrow rates for each tier [ISOLATED, CROSS_A, CROSS_B, STABLE]
     * @return liquidationBonuses Array of liquidation bonuses for each tier [ISOLATED, CROSS_A, CROSS_B, STABLE]
     * @custom:returns-description Index mapping:
     *      - [0] = ISOLATED tier rates
     *      - [1] = CROSS_A tier rates
     *      - [2] = CROSS_B tier rates
     *      - [3] = STABLE tier rates
     */
    function getTierRates()
        external
        view
        returns (uint256[4] memory borrowRates, uint256[4] memory liquidationBonuses)
    {
        borrowRates[0] = tierBaseBorrowRate[CollateralTier.ISOLATED];
        borrowRates[1] = tierBaseBorrowRate[CollateralTier.CROSS_A];
        borrowRates[2] = tierBaseBorrowRate[CollateralTier.CROSS_B];
        borrowRates[3] = tierBaseBorrowRate[CollateralTier.STABLE];

        liquidationBonuses[0] = tierLiquidationBonus[CollateralTier.ISOLATED];
        liquidationBonuses[1] = tierLiquidationBonus[CollateralTier.CROSS_A];
        liquidationBonuses[2] = tierLiquidationBonus[CollateralTier.CROSS_B];
        liquidationBonuses[3] = tierLiquidationBonus[CollateralTier.STABLE];
    }

    /**
     * @notice Returns an array of all listed asset addresses in the protocol
     * @dev Retrieves assets from the EnumerableSet storing listed assets
     * @return Array of addresses representing all listed assets
     * @custom:complexity O(n) where n is the number of listed assets
     * @custom:state-access Read-only function, no state modifications
     */
    function getListedAssets() external view returns (address[] memory) {
        uint256 length = listedAsset.length();
        address[] memory assets = new address[](length);
        for (uint256 i = 0; i < length; i++) {
            assets[i] = listedAsset.at(i);
        }
        return assets;
    }

    /**
     * @notice Retrieves a user's borrowing position details
     * @param user The address of the position owner
     * @param positionId The ID of the position to query
     * @dev Returns the full UserPosition struct containing position details
     * @return UserPosition struct containing:
     *      - isIsolated: Whether position is in isolation mode
     *      - isolatedAsset: Address of isolated asset (if applicable)
     *      - debtAmount: Current principal debt amount
     *      - lastInterestAccrual: Timestamp of last interest accrual
     * @custom:security Validates position exists via validPosition modifier
     * @custom:access Public view function, no state modifications
     */
    function getUserPosition(address user, uint256 positionId)
        external
        view
        validPosition(user, positionId)
        returns (UserPosition memory)
    {
        return positions[user][positionId];
    }

    /**
     * @notice Retrieves the amount of collateral asset a user has in a specific position
     * @param user The address of the position owner
     * @param positionId The ID of the position to query
     * @param asset The address of the collateral asset to check
     * @dev Checks the collateral amount mapping for a specific user's position
     * @return uint256 The amount of collateral asset in the position (in asset's native decimals)
     * @custom:security Validates position exists via validPosition modifier
     * @custom:access Public view function, no state modifications
     */
    function getUserCollateralAmount(address user, uint256 positionId, address asset)
        external
        view
        validPosition(user, positionId)
        returns (uint256)
    {
        return positionCollateralAmounts[user][positionId][asset];
    }

    /**
     * @notice Returns a comprehensive snapshot of the protocol's current state
     * @dev Aggregates key protocol metrics and parameters into a single struct
     * @return ProtocolSnapshot A struct containing:
     *      - utilization: Current protocol utilization rate
     *      - borrowRate: Base borrow rate (using STABLE tier as reference)
     *      - supplyRate: Current supply rate for liquidity providers
     *      - totalBorrow: Total amount borrowed from protocol
     *      - totalSuppliedLiquidity: Total USDC supplied to protocol
     *      - targetReward: Current target reward amount
     *      - rewardInterval: Duration of reward period
     *      - rewardableSupply: Minimum supply for reward eligibility
     *      - baseProfitTarget: Protocol's base profit margin
     *      - liquidatorThreshold: Required governance tokens for liquidators
     *      - flashLoanFee: Current flash loan fee rate
     * @custom:state-access Read-only view of protocol state
     * @custom:calculations Uses:
     *      - getUtilization() for usage metrics
     *      - getBorrowRate() for current rates
     *      - getSupplyRate() for LP returns
     */
    function getProtocolSnapshot() external view returns (ProtocolSnapshot memory) {
        uint256 utilization = getUtilization();
        uint256 borrowRate = getBorrowRate(CollateralTier.STABLE); // Use STABLE as base rate
        uint256 supplyRate = getSupplyRate();

        return ProtocolSnapshot({
            utilization: utilization,
            borrowRate: borrowRate,
            supplyRate: supplyRate,
            totalBorrow: totalBorrow,
            totalSuppliedLiquidity: totalSuppliedLiquidity,
            targetReward: targetReward,
            rewardInterval: rewardInterval,
            rewardableSupply: rewardableSupply,
            baseProfitTarget: baseProfitTarget,
            liquidatorThreshold: liquidatorThreshold,
            flashLoanFee: flashLoanFee
        });
    }

    /**
     * @notice Calculates the total debt amount including accrued interest for a position
     * @param user The address of the position owner
     * @param positionId The ID of the position to calculate debt for
     * @dev Process:
     *      1. Returns 0 if position has no debt
     *      2. Calculates elapsed time since last interest accrual
     *      3. Determines applicable interest rate based on collateral tier
     *      4. Compounds interest using ray math
     * @return uint256 Total debt including accrued interest
     * @custom:validation Checks:
     *      - Position exists (via validPosition modifier)
     * @custom:calculations Uses:
     *      - For isolated positions: uses isolated asset's tier rate
     *      - For cross-collateral: uses highest tier rate among assets
     *      - Compounds interest based on time elapsed
     */
    function calculateDebtWithInterest(address user, uint256 positionId)
        public
        view
        validPosition(user, positionId)
        returns (uint256)
    {
        UserPosition storage position = positions[user][positionId];
        if (position.debtAmount == 0) return 0;

        uint256 timeElapsed = block.timestamp - position.lastInterestAccrual;
        CollateralTier tier;

        if (position.isIsolated) {
            tier = assetInfo[positionCollateralAssets[user][positionId][0]].tier;
        } else {
            tier = getHighestTier(user, positionId);
        }

        uint256 rate = getBorrowRate(tier);
        return accrueInterest(position.debtAmount, annualRateToRay(rate), timeElapsed);
    }

    //////////////////////////////////////////////////
    // ---------getter functions--------------------//
    //////////////////////////////////////////////////
    /**
     * @notice Retrieves complete configuration details for a listed asset
     * @param asset The address of the asset to query
     * @return Asset struct containing all configuration parameters
     * @dev Returns the full Asset struct from assetInfo mapping
     */
    function getAssetInfo(address asset) public view returns (Asset memory) {
        return assetInfo[asset];
    }

    /**
     * @notice Gets the current USD price for an asset from its oracle
     * @param asset The address of the asset to price
     * @return uint256 The asset price in USD (scaled by oracle decimals)
     * @dev Fetches price from the asset's configured Chainlink oracle
     */
    function getAssetPrice(address asset) public view returns (uint256) {
        return getAssetPriceOracle(assetInfo[asset].oracleUSD);
    }

    /**
     * @notice Gets the total number of positions for a user
     * @param user The address of the user to query
     * @return uint256 The number of positions owned by the user
     */
    function getUserPositionsCount(address user) public view returns (uint256) {
        return positions[user].length;
    }

    /**
     * @notice Retrieves all positions for a user
     * @param user The address of the user to query
     * @return UserPosition[] Array of all user's positions
     * @dev Returns complete array of UserPosition structs
     */
    function getUserPositions(address user) public view returns (UserPosition[] memory) {
        return positions[user];
    }

    /**
     * @notice Gets the liquidation bonus percentage for a specific position
     * @param user The address of the position owner
     * @param positionId The ID of the position
     * @dev Returns tier-specific bonus for isolated positions, base fee for cross-collateral
     * @return uint256 The liquidation bonus percentage in parts per million (e.g., 0.05e6 = 5%)
     * @custom:security Validates position exists via validPosition modifier
     * @custom:calculations Uses:
     *      - For isolated positions: returns tier's liquidation bonus
     *      - For cross-collateral: returns base liquidation fee (1%)
     */
    function getPositionLiquidationFee(address user, uint256 positionId)
        public
        view
        validPosition(user, positionId)
        returns (uint256)
    {
        UserPosition storage position = positions[user][positionId];
        if (position.isIsolated) {
            Asset memory asset = assetInfo[positionCollateralAssets[user][positionId][0]];
            return tierLiquidationBonus[asset.tier];
        }
        CollateralTier tier = getHighestTier(user, positionId);
        return tierLiquidationBonus[tier];
    }

    /**
     * @notice Calculates the maximum allowed borrowing amount for a position
     * @param user The address of the position owner
     * @param positionId The ID of the position
     * @dev Considers collateral value, borrowing threshold, and isolation mode status
     * @return uint256 The maximum allowed borrowing amount in USDC
     * @custom:security Validates position exists via validPosition modifier
     * @custom:calculations
     *      - Isolated positions: uses single asset's value and threshold
     *      - Cross-collateral: sums all assets' weighted values
     *      - Formula: amount * price * borrowThreshold * WAD / decimals / 1000
     * @custom:oracle Uses Chainlink price feeds for asset valuations
     */
    function calculateCreditLimit(address user, uint256 positionId)
        public
        view
        validPosition(user, positionId)
        returns (uint256)
    {
        UserPosition memory position = positions[user][positionId];
        address[] memory assets = positionCollateralAssets[user][positionId];
        uint256 totalCredit;

        if (position.isIsolated) {
            Asset memory item = assetInfo[assets[0]];
            uint256 amount = positionCollateralAmounts[user][positionId][assets[0]];
            uint256 price = getAssetPriceOracle(item.oracleUSD);
            return
                (amount * price * item.borrowThreshold * WAD) / 10 ** item.decimals / 1000 / 10 ** item.oracleDecimals;
        }

        // For cross-collateral positions
        for (uint256 i = 0; i < assets.length; i++) {
            address asset = assets[i];
            uint256 amount = positionCollateralAmounts[user][positionId][asset];
            if (amount > 0) {
                Asset memory assetConfig = assetInfo[asset];
                uint256 price = getAssetPriceOracle(assetConfig.oracleUSD);
                totalCredit += (amount * price * assetConfig.borrowThreshold * WAD) / 10 ** assetConfig.decimals / 1000
                    / 10 ** assetConfig.oracleDecimals;
            }
        }

        return totalCredit;
    }

    /**
     * @notice Calculates the total USD value of all collateral assets in a position
     * @param user The address of the position owner
     * @param positionId The ID of the position to value
     * @dev Calculates raw collateral value without applying any risk parameters
     * @return uint256 The total USD value of all collateral assets (scaled by WAD)
     * @custom:security Validates position exists via validPosition modifier
     * @custom:calculations
     *      - For isolated positions: returns single asset's USD value
     *      - For cross-collateral: sums all assets' USD values
     *      - Formula: amount * price * WAD / 10^assetDecimals / 10^oracleDecimals
     * @custom:oracle Uses Chainlink price feeds for asset valuations
     * @custom:difference Unlike calculateCreditLimit, this returns raw value without applying
     *                    borrowThreshold or liquidationThreshold risk adjustments
     */
    function calculateCollateralValue(address user, uint256 positionId)
        public
        view
        validPosition(user, positionId)
        returns (uint256)
    {
        UserPosition memory position = positions[user][positionId];
        address[] memory assets = positionCollateralAssets[user][positionId];
        uint256 totalValue;

        if (position.isIsolated) {
            Asset memory item = assetInfo[assets[0]];
            uint256 amount = positionCollateralAmounts[user][positionId][assets[0]];
            uint256 price = getAssetPriceOracle(item.oracleUSD);
            return (amount * price * WAD) / 10 ** item.decimals / 10 ** item.oracleDecimals;
        }

        // For cross-collateral positions
        for (uint256 i = 0; i < assets.length; i++) {
            address asset = assets[i];
            uint256 amount = positionCollateralAmounts[user][positionId][asset];
            if (amount > 0) {
                Asset memory assetConfig = assetInfo[asset];
                uint256 price = getAssetPriceOracle(assetConfig.oracleUSD);
                totalValue += (amount * price * WAD) / 10 ** assetConfig.decimals / 10 ** assetConfig.oracleDecimals;
            }
        }

        return totalValue;
    }

    /**
     * @notice Determines if a position can be liquidated based on debt and collateral value
     * @param user The address of the position owner
     * @param positionId The ID of the position to check
     * @dev A position is liquidatable if debt with interest >= collateral value
     * @return bool True if position can be liquidated, false otherwise
     * @custom:validation Checks:
     *      - Position exists (via validPosition modifier)
     *      - Position has non-zero debt
     * @custom:calculations Uses:
     *      - calculateDebtWithInterest() for total debt
     *      - calculateCreditLimit() for collateral value
     */
    function isLiquidatable(address user, uint256 positionId)
        public
        view
        activePosition(user, positionId)
        returns (bool)
    {
        UserPosition storage position = positions[user][positionId];
        if (position.debtAmount == 0) return false;

        uint256 debtWithInterest = calculateDebtWithInterest(user, positionId);
        uint256 collateralValue = calculateCreditLimit(user, positionId);

        return debtWithInterest >= collateralValue;
    }

    /**
     * @notice Provides a comprehensive overview of a position's current state
     * @param user The address of the position owner
     * @param positionId The ID of the position to summarize
     * @return totalCollateralValue The total USD value of all collateral in the position
     * @return currentDebt The current debt including accrued interest
     * @return availableCredit The remaining borrowing capacity
     * @return isIsolated Whether the position is in isolation mode
     * @return status The current status of the position (ACTIVE, LIQUIDATED, or CLOSED)
     * @dev Aggregates key position metrics into a single view for frontend display and risk assessment
     * @custom:security Validates position exists via validPosition modifier
     * @custom:calculations Uses:
     *      - calculateCollateralValue() for total collateral valuation in USD
     *      - calculateDebtWithInterest() for current debt with accrued interest
     *      - calculateCreditLimit() for maximum borrowing capacity
     * @custom:position-status Returns one of the following status values:
     *      - ACTIVE (1): Position is operational and can be modified
     *      - LIQUIDATED (0): Position has been liquidated due to insufficient collateral
     *      - CLOSED (2): Position has been voluntarily closed by the user
     */
    function getPositionSummary(address user, uint256 positionId)
        public
        view
        validPosition(user, positionId)
        returns (
            uint256 totalCollateralValue,
            uint256 currentDebt,
            uint256 availableCredit,
            bool isIsolated,
            PositionStatus status
        )
    {
        UserPosition memory position = positions[user][positionId];

        totalCollateralValue = calculateCollateralValue(user, positionId);
        currentDebt = calculateDebtWithInterest(user, positionId);
        availableCredit = calculateCreditLimit(user, positionId);
        isIsolated = position.isIsolated;
        status = position.status;
    }

    /**
     * @notice Retrieves detailed information about a listed asset
     * @param asset The address of the asset to query
     * @return price Current USD price from oracle
     * @return totalSupplied Total amount of asset supplied as collateral
     * @return maxSupply Maximum supply threshold allowed
     * @return borrowRate Current borrow rate for the asset's tier
     * @return liquidationBonus Liquidation bonus percentage for the asset's tier
     * @return tier Risk classification tier of the asset
     * @dev Aggregates asset configuration and current state into a single view
     * @custom:calculations Uses:
     *      - getAssetPriceOracle() for current price
     *      - getBorrowRate() for tier-specific rates
     * @custom:state-access Read-only access to:
     *      - assetInfo mapping
     *      - totalCollateral mapping
     *      - tierBaseBorrowRate mapping
     *      - tierLiquidationBonus mapping
     */
    function getAssetDetails(address asset)
        public
        view
        returns (
            uint256 price,
            uint256 totalSupplied,
            uint256 maxSupply,
            uint256 borrowRate,
            uint256 liquidationBonus,
            CollateralTier tier
        )
    {
        Asset memory assetConfig = assetInfo[asset];
        price = getAssetPriceOracle(assetConfig.oracleUSD);
        totalSupplied = totalCollateral[asset];
        maxSupply = assetConfig.maxSupplyThreshold;
        borrowRate = getBorrowRate(assetConfig.tier);
        liquidationBonus = tierLiquidationBonus[assetConfig.tier];
        tier = assetConfig.tier;
    }

    /**
     * @notice Retrieves detailed information about a liquidity provider's position
     * @param user The address of the liquidity provider to query
     * @return lpTokenBalance The user's current balance of LP tokens
     * @return usdcValue The current value of LP tokens in USDC
     * @return lastAccrualTime Timestamp of last reward accrual
     * @return isRewardEligible Whether the user is eligible for rewards
     * @return pendingRewards Amount of rewards currently available to claim
     * @dev Calculates real-time LP token value and pending rewards
     * @custom:calculations
     *      - USDC value = (LP balance * total assets) / total supply
     *      - Pending rewards = (targetReward * duration) / rewardInterval
     *      - Rewards capped at ecosystem's maxReward
     * @custom:validation Checks:
     *      - User must meet minimum supply threshold
     *      - Sufficient time must have elapsed since last accrual
     */
    function getLPInfo(address user)
        public
        view
        returns (
            uint256 lpTokenBalance,
            uint256 usdcValue,
            uint256 lastAccrualTime,
            bool isRewardEligible,
            uint256 pendingRewards
        )
    {
        lpTokenBalance = balanceOf(user);
        uint256 total = usdcInstance.balanceOf(address(this)) + totalBorrow;
        usdcValue = (lpTokenBalance * total) / totalSupply();
        lastAccrualTime = liquidityAccrueTimeIndex[user];
        isRewardEligible = isRewardable(user);

        if (isRewardEligible) {
            uint256 duration = block.timestamp - lastAccrualTime;
            pendingRewards = (targetReward * duration) / rewardInterval;
            uint256 maxReward = ecosystemInstance.maxReward();
            pendingRewards = pendingRewards > maxReward ? maxReward : pendingRewards;
        }
    }

    /**
     * @notice Calculates the health factor of a borrowing position
     * @param user The address of the position owner
     * @param positionId The ID of the position to check
     * @dev The health factor represents the ratio of collateral value to debt
     *      - Health factor > 1: Position is healthy
     *      - Health factor < 1: Position can be liquidated
     *      - Health factor = ∞: Position has no debt
     * @return uint256 The position's health factor (scaled by WAD)
     * @custom:security Validates position exists via validPosition modifier
     * @custom:calculations
     *      - For positions with no debt: returns type(uint256).max
     *      - Otherwise: (collateral value * liquidation threshold) / total debt
     * @custom:formula
     *      healthFactor = (sum(asset amounts * prices * liquidation thresholds) * WAD) / debt
     */
    function healthFactor(address user, uint256 positionId)
        public
        view
        validPosition(user, positionId)
        returns (uint256)
    {
        uint256 debt = calculateDebtWithInterest(user, positionId);
        uint256 liqLevel = 0; //calculateCreditLimit(user, positionId);

        // If no debt, return maximum possible health factor
        if (debt == 0) {
            return type(uint256).max; // Return "infinite" health factor
        }

        address[] memory assets = positionCollateralAssets[user][positionId];

        uint256 len = assets.length;

        for (uint256 i; i < len; ++i) {
            uint256 amount = positionCollateralAmounts[user][positionId][assets[i]];
            if (amount != 0) {
                Asset memory item = assetInfo[assets[i]];
                uint256 price = getAssetPriceOracle(item.oracleUSD);
                liqLevel += (amount * price * item.liquidationThreshold * WAD) / 10 ** item.decimals / 1000
                    / 10 ** item.oracleDecimals;
            }
        }
        return (liqLevel * WAD) / debt;
    }

    /**
     * @notice Gets the list of collateral assets in a position
     * @param user The address of the position owner
     * @param positionId The ID of the position to query
     * @dev Retrieves the array of asset addresses used as collateral
     * @return Array of addresses representing collateral assets
     * @custom:security Validates position exists via validPosition modifier
     */
    function getPositionCollateralAssets(address user, uint256 positionId)
        public
        view
        validPosition(user, positionId)
        returns (address[] memory)
    {
        return positionCollateralAssets[user][positionId];
    }

    /**
     * @notice Gets the current debt amount for a position
     * @param user The address of the position owner
     * @param positionId The ID of the position to query
     * @dev Returns raw debt amount without accrued interest
     * @return uint256 The principal debt amount
     * @custom:security Validates position exists via validPosition modifier
     * @custom:note For debt including interest, use calculateDebtWithInterest()
     */
    function getPositionDebt(address user, uint256 positionId)
        public
        view
        validPosition(user, positionId)
        returns (uint256)
    {
        return positions[user][positionId].debtAmount;
    }

    /**
     * @notice Calculates the current protocol utilization rate
     * @dev Formula: utilization = (totalBorrow * WAD) / totalSuppliedLiquidity
     * @return u Current utilization rate scaled by WAD (1e18)
     * @custom:calculations
     *      - Returns 0 if totalSuppliedLiquidity is 0
     *      - Returns 0 if totalBorrow is 0
     *      - Otherwise: (totalBorrow * WAD) / totalSuppliedLiquidity
     * @custom:formula
     *      utilization = (totalBorrow * 1e18) / totalSuppliedLiquidity
     */
    function getUtilization() public view returns (uint256 u) {
        (totalSuppliedLiquidity == 0 || totalBorrow == 0) ? u = 0 : u = (WAD * totalBorrow) / totalSuppliedLiquidity;
    }

    /**
     * @notice Calculates the current supply rate for liquidity providers
     * @dev Determines the rate based on protocol utilization and profit target
     * @return uint256 The current supply rate in parts per million (e.g., 0.05e6 = 5%)
     * @custom:calculations
     *      - Returns 0 if totalSuppliedLiquidity is 0
     *      - Target fee = (totalSupply * baseProfitTarget) / WAD
     *      - Total value = USDC balance + totalBorrow
     *      - Fee applied if total >= suppliedLiquidity + target
     *      - Rate = ((WAD * total) / (totalSuppliedLiquidity + fee)) - WAD
     * @custom:formula
     *      supplyRate = ((totalAssets * WAD) / (totalSuppliedLiquidity + fee)) - WAD
     * @custom:state-access Read-only access to:
     *      - totalSuppliedLiquidity
     *      - totalSupply
     *      - baseProfitTarget
     *      - USDC balance
     *      - totalBorrow
     */
    function getSupplyRate() public view returns (uint256) {
        if (totalSuppliedLiquidity == 0) return 0;
        uint256 fee;
        uint256 supply = totalSupply();
        uint256 target = (supply * baseProfitTarget) / WAD; // 1% commission
        uint256 total = usdcInstance.balanceOf(address(this)) + totalBorrow;
        total >= totalSuppliedLiquidity + target ? fee = target : fee = 0;

        return ((WAD * total) / (totalSuppliedLiquidity + fee)) - WAD;
    }

    /**
     * @notice Calculates the current borrow rate for a specific collateral tier
     * @param tier The collateral tier to calculate the rate for
     * @dev Combines base rate, utilization rate, and tier-specific premium
     * @return uint256 The current borrow rate in parts per million (e.g., 0.05e6 = 5%)
     * @custom:calculations
     *      - If utilization is 0: returns baseBorrowRate
     *      - Otherwise calculates:
     *          1. Supply rate converted to RAY format
     *          2. Break-even rate based on supply interest
     *          3. Base rate = max(breakEven + baseProfitTarget, baseBorrowRate)
     *          4. Final rate = baseRate + (tierRate * utilization / WAD)
     * @custom:formula
     *      finalRate = baseRate + (tierBaseBorrowRate[tier] * utilization / WAD)
     * @custom:state-access Read-only access to:
     *      - baseBorrowRate
     *      - tierBaseBorrowRate mapping
     *      - utilization rate
     */
    function getBorrowRate(CollateralTier tier) public view returns (uint256) {
        uint256 utilization = getUtilization();
        if (utilization == 0) return baseBorrowRate;

        uint256 duration = 365 days;
        uint256 defaultSupply = WAD;
        uint256 loan = (defaultSupply * utilization) / WAD;

        // Calculate base rate from supply rate
        uint256 supplyRateRay = annualRateToRay(getSupplyRate());
        uint256 supplyInterest = getInterest(defaultSupply, supplyRateRay, duration);
        uint256 breakEven = breakEvenRate(loan, supplyInterest);

        // Calculate final rate with tier premium
        uint256 rate = breakEven + baseProfitTarget;
        uint256 baseRate = rate > baseBorrowRate ? rate : baseBorrowRate;

        // Add tier premium scaled by utilization
        return baseRate + (tierBaseBorrowRate[tier] * utilization / WAD);
    }

    /**
     * @notice Checks if a liquidity provider is eligible for rewards
     * @param user The address of the liquidity provider to check
     * @return bool True if the user is eligible for rewards, false otherwise
     * @dev Determines reward eligibility based on time elapsed and supply amount
     * @custom:validation Checks:
     *      - User has previously supplied liquidity (non-zero accrual time)
     *      - Minimum reward interval has elapsed
     *      - User meets minimum supply threshold
     * @custom:calculations
     *      - Base amount = (user LP balance * totalSuppliedLiquidity) / total supply
     *      - Time check = current time - interval >= last accrual
     */
    function isRewardable(address user) public view returns (bool) {
        if (liquidityAccrueTimeIndex[user] == 0) return false;
        uint256 supply = totalSupply();
        uint256 baseAmount = (balanceOf(user) * totalSuppliedLiquidity) / supply;

        return block.timestamp - rewardInterval >= liquidityAccrueTimeIndex[user] && baseAmount >= rewardableSupply;
    }

    /**
     * @notice Gets the base liquidation bonus percentage for a specific collateral tier
     * @param tier The collateral tier to query
     * @return uint256 The liquidation bonus rate in parts per million (e.g., 0.05e6 = 5%)
     * @dev Direct accessor for tierLiquidationBonus mapping without additional calculations
     * @custom:values Typical values:
     *      - STABLE: 5% (0.05e6)
     *      - CROSS_A: 8% (0.08e6)
     *      - CROSS_B: 10% (0.1e6)
     *      - ISOLATED: 15% (0.15e6)
     */
    function getTierLiquidationFee(CollateralTier tier) public view returns (uint256) {
        return tierLiquidationBonus[tier];
    }

    /**
     * @notice Retrieves a secure price feed from Chainlink oracle with multiple safety validations
     * @param oracle The address of the Chainlink price feed oracle
     * @return Price in USD with oracle's native decimal precision
     * @dev Implements comprehensive safety measures to ensure price reliability:
     *      1. Core validations:
     *         - Ensures reported price is positive
     *         - Verifies the oracle round is complete and answered
     *         - Checks price data freshness (< 8 hours old)
     *      2. Volatility protection:
     *         - For price changes > 20%, requires fresher data (< 1 hour old)
     *         - Compares current price against previous round data
     *         - Prevents manipulation through large short-term price movements
     * @custom:security-layer Designed as a critical security component for accurate asset valuation
     * @custom:error-cases
     *      - OracleInvalidPrice: Price must be > 0
     *      - OracleStalePrice: Oracle must have answered for the current round
     *      - OracleTimeout: Price timestamp must be recent (within 8 hours)
     *      - OracleInvalidPriceVolatility: High volatility prices must be fresh (within 1 hour)
     */
    function getAssetPriceOracle(address oracle) public view returns (uint256) {
        // Fetch latest data from Chainlink oracle
        (uint80 roundId, int256 price,, uint256 timestamp, uint80 answeredInRound) =
            AggregatorV3Interface(oracle).latestRoundData();

        // Core validations - price must be positive
        if (price <= 0) {
            revert OracleInvalidPrice(oracle, price);
        }

        // Ensure round is complete and answered
        if (answeredInRound < roundId) {
            revert OracleStalePrice(oracle, roundId, answeredInRound);
        }

        // Verify price data freshness - must be less than 8 hours old
        uint256 age = block.timestamp - timestamp;
        if (age > 8 hours) {
            revert OracleTimeout(oracle, timestamp, block.timestamp, 8 hours);
        }

        // Volatility protection - for significant price movements, enforce stricter freshness
        if (roundId > 1) {
            // Fetch previous round data to compare
            (, int256 previousPrice,, uint256 previousTimestamp,) =
                AggregatorV3Interface(oracle).getRoundData(roundId - 1);

            // Only evaluate valid historical data points
            if (previousPrice > 0 && previousTimestamp > 0) {
                // Calculate price change percentage
                uint256 priceDelta =
                    price > previousPrice ? uint256(price - previousPrice) : uint256(previousPrice - price);

                uint256 changePercent = (priceDelta * 100) / uint256(previousPrice);

                // For high volatility (>=20% change), require fresher data (< 1 hour old)
                if (changePercent >= 20 && age >= 1 hours) {
                    revert OracleInvalidPriceVolatility(oracle, price, changePercent);
                }
            }
        }

        return uint256(price);
    }

    /**
     * @notice Determines the highest risk tier among a position's collateral assets
     * @param user The address of the position owner
     * @param positionId The ID of the position to check
     * @dev Iterates through position's assets and compares their tiers
     * @return CollateralTier The highest risk tier found among active collateral
     * @custom:security Validates position exists via validPosition modifier
     * @custom:validation Checks:
     *      - Only considers assets with non-zero balances
     * @custom:calculations
     *      - Default tier is STABLE (lowest risk)
     *      - Compares tier enum values numerically
     *      - Higher enum value = higher risk tier
     * @custom:tiers Risk tiers in ascending order:
     *      - STABLE (0)
     *      - CROSS_A (1)
     *      - CROSS_B (2)
     *      - ISOLATED (3)
     */
    function getHighestTier(address user, uint256 positionId)
        public
        view
        validPosition(user, positionId)
        returns (CollateralTier)
    {
        CollateralTier tier = CollateralTier.STABLE;

        address[] storage assets = positionCollateralAssets[user][positionId];
        for (uint256 i = 0; i < assets.length; i++) {
            address asset = assets[i];
            uint256 amount = positionCollateralAmounts[user][positionId][asset];
            if (amount > 0) {
                Asset memory assetConfig = assetInfo[asset];
                if (uint8(assetConfig.tier) > uint8(tier)) {
                    tier = assetConfig.tier;
                }
            }
        }

        return tier;
    }

    /**
     * @notice Gets the token balance of an account
     * @param account The address to query
     * @return uint256 The number of tokens owned by the account
     * @dev Overrides ERC20Upgradeable and IERC20 implementations
     */
    function balanceOf(address account) public view virtual override(ERC20Upgradeable, IERC20) returns (uint256) {
        return super.balanceOf(account);
    }

    /**
     * @notice Returns the number of decimals used for token amounts
     * @return uint8 The number of decimals (18)
     * @dev Overrides ERC20Upgradeable implementation
     */
    function decimals() public view virtual override(ERC20Upgradeable) returns (uint8) {
        return super.decimals();
    }

    /**
     * @notice Gets the total supply of tokens in circulation
     * @return uint256 The total number of tokens
     * @dev Overrides ERC20Upgradeable and IERC20 implementations
     */
    function totalSupply() public view virtual override(ERC20Upgradeable, IERC20) returns (uint256) {
        return super.totalSupply();
    }

    //////////////////////////////////////////////////
    // ---------internal functions------------------//
    //////////////////////////////////////////////////

    /**
     * @notice Internal function to transfer all collateral assets from a liquidated position
     * @param user Address of the position owner
     * @param positionId ID of the position being liquidated
     * @param liquidator Address receiving the collateral assets
     * @dev Iterates through all position assets and transfers non-zero balances
     * @custom:state Updates:
     *      - Clears collateral amounts in position
     *      - Updates total collateral tracking
     *      - Deletes position assets array
     * @custom:events Emits:
     *      - WithdrawCollateral for each asset transferred
     */
    function _transferCollateralToLiquidator(address user, uint256 positionId, address liquidator) internal {
        address[] storage posAssets = positionCollateralAssets[user][positionId];

        // Transfer all collateral to liquidator
        for (uint256 i = 0; i < posAssets.length; i++) {
            address asset = posAssets[i];
            uint256 amount = positionCollateralAmounts[user][positionId][asset];
            if (amount > 0) {
                positionCollateralAmounts[user][positionId][asset] = 0;
                totalCollateral[asset] -= amount;
                TH.safeTransfer(IERC20(asset), liquidator, amount);
                emit WithdrawCollateral(user, positionId, asset, amount);
            }
        }

        // Clear position assets array
        delete positionCollateralAssets[user][positionId];
    }

    /**
     * @notice Internal function to process and distribute rewards for liquidity providers
     * @param amount The amount of liquidity being withdrawn or managed
     * @dev Calculates and distributes rewards based on time elapsed and amount supplied
     * @custom:validation Checks:
     *      - Sufficient time has elapsed since last reward (>= rewardInterval)
     *      - Amount meets minimum threshold (>= rewardableSupply)
     * @custom:calculations
     *      - Duration = current timestamp - last accrual time
     *      - Base reward = (targetReward * duration) / rewardInterval
     *      - Final reward = min(base reward, ecosystem maxReward)
     * @custom:state Updates:
     *      - Clears liquidityAccrueTimeIndex for user
     * @custom:events Emits:
     *      - Reward event with recipient and amount
     * @custom:security Only called internally during liquidity operations
     */
    function _rewardInternal(uint256 amount) internal {
        bool rewardable =
            block.timestamp - rewardInterval >= liquidityAccrueTimeIndex[msg.sender] && amount >= rewardableSupply;

        if (rewardable) {
            uint256 duration = block.timestamp - liquidityAccrueTimeIndex[msg.sender];
            uint256 reward = (targetReward * duration) / rewardInterval;
            uint256 maxReward = ecosystemInstance.maxReward();
            uint256 target = reward > maxReward ? maxReward : reward;
            delete liquidityAccrueTimeIndex[msg.sender];
            emit Reward(msg.sender, target);
            ecosystemInstance.reward(msg.sender, target);
        }
    }

    // Add these overrides right before the _authorizeUpgrade function:

    /// @inheritdoc ERC20Upgradeable
    function _update(address from, address to, uint256 value)
        internal
        override(ERC20Upgradeable, ERC20PausableUpgradeable)
    {
        super._update(from, to, value);
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {
        ++version;
        emit Upgrade(msg.sender, newImplementation);
    }
}
