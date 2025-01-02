// SPDX-License-Identifier: MIT
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
 *
 * @title Lendefi Protocol Liquidator
 * @notice Liquidation contract example
 * @author alexei@nlkimi-labs(dot)xyz
 * @disclaimer !!! USE AT YOUR OWN RISK !!!
 * @custom:security-contact security@alkimi.org
 */

import {IPROTOCOL} from "../interfaces/IProtocol.sol";
import {IVault} from "../vendor/@balancer-labs/v2-interfaces/contracts/vault/IVault.sol";
import {IFlashLoanRecipient} from "../vendor/@balancer-labs/v2-interfaces/contracts/vault/IFlashLoanRecipient.sol";
import {ISwapRouter} from "../vendor/@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract FlashLoanRecipient is IFlashLoanRecipient, Ownable {
    /// @dev USDC token instance
    IERC20 public immutable USDC_INSTANCE;
    /// @dev balancer vault instance
    /// @notice mainnet address 0xBA12222222228d8Ba445958a75a0704d566BF2C8
    IVault public immutable BALANCER_VAULT;
    /// @dev Lendefi instance
    IPROTOCOL public immutable PROTOCOL_INSTANCE;
    /// @dev gov token instance
    IERC20 public immutable TOKEN_INSTANCE;
    /// @dev Uniswap router instance
    ISwapRouter public immutable UNISWAP_ROUTER;

    /// @dev CustomError message
    /// @param msg error desciption message
    error CustomError(string msg);

    /**
     * @dev Throws if called by any account other than the owner.
     */
    modifier onlyVault() {
        _checkVault();
        _;
    }

    constructor(address usdc, address nlkimi, address balancerVault, address uniswapRouter, address govToken)
        Ownable(msg.sender)
    {
        USDC_INSTANCE = IERC20(usdc);
        PROTOCOL_INSTANCE = IPROTOCOL(payable(nlkimi));
        BALANCER_VAULT = IVault(balancerVault);
        UNISWAP_ROUTER = ISwapRouter(uniswapRouter); //uniswapV3
        TOKEN_INSTANCE = IERC20(govToken);
    }

    /**
     * @dev Liquidates borrower positions in the Alkimi protocol
     * @param account address
     */
    function liquidate(address account) external onlyOwner {
        uint256 positionId = PROTOCOL_INSTANCE.getUserPositionsCount(account) - 1;
        if (PROTOCOL_INSTANCE.isLiquidatable(account, positionId)) {
            require(TOKEN_INSTANCE.balanceOf(address(this)) >= 20_000 ether, "ERR_INSUFFIENT_LIQUIDATOR_TOKENS");

            uint256 debt = PROTOCOL_INSTANCE.calculateDebtWithInterest(account, positionId);
            uint256 liquidationBonus = PROTOCOL_INSTANCE.getPositionLiquidationFee(account, positionId);
            uint256 liquidationFee = debt * liquidationBonus / 1e6;
            IERC20[] memory array = new IERC20[](1);
            array[0] = USDC_INSTANCE;
            uint256[] memory amounts = new uint256[](1);
            amounts[0] = debt + liquidationFee;

            makeFlashLoan(array, amounts, abi.encodePacked(account));
        }
    }

    /**
     * @dev withdraws profit in USDC, and gov tokens required to make the liquidation (20_000e18)
     */
    function withdraw() external onlyOwner {
        uint256 profit = USDC_INSTANCE.balanceOf(address(this));
        uint256 govBalance = TOKEN_INSTANCE.balanceOf(address(this));
        SafeERC20.safeTransfer(USDC_INSTANCE, msg.sender, profit);
        SafeERC20.safeTransfer(TOKEN_INSTANCE, msg.sender, govBalance);
    }

    /**
     * @dev receives Balancer flash loan
     * @param tokens IERC20 instances array
     * @param amounts corresponding amounts array
     * @param feeAmounts corresponding fee amounts array
     * @param userData borrower address
     */
    function receiveFlashLoan(
        IERC20[] memory tokens,
        uint256[] memory amounts,
        uint256[] memory feeAmounts,
        bytes memory userData
    ) external override onlyVault {
        address target = address(uint160(bytes20(userData)));
        uint256 positionId = PROTOCOL_INSTANCE.getUserPositionsCount(target) - 1;
        address[] memory assets = PROTOCOL_INSTANCE.getPositionCollateralAssets(target, positionId);
        uint256 len = assets.length;

        uint256[] memory tokenAmounts = new uint256[](len);
        for (uint256 i = 0; i < len; ++i) {
            uint256 amount = PROTOCOL_INSTANCE.getUserCollateralAmount(target, positionId, assets[i]);
            if (amount > 0) {
                tokenAmounts[i] = amount;
            }
        }

        SafeERC20.forceApprove(USDC_INSTANCE, address(PROTOCOL_INSTANCE), amounts[0]);
        PROTOCOL_INSTANCE.liquidate(target, positionId); // 🚩 🚩 🚩 🚩 🚩 //

        uint256 recievedBase;
        for (uint256 i = 0; i < len; ++i) {
            if (tokenAmounts[i] > 0) {
                IPROTOCOL.Asset memory assetInfo = PROTOCOL_INSTANCE.getAssetInfo(assets[i]);
                uint256 assetPrice = PROTOCOL_INSTANCE.getAssetPrice(assetInfo.oracleUSD);
                uint256 amountOutMin = (tokenAmounts[i] * assetPrice * 99) / 10 ** assetInfo.oracleDecimals / 100;
                uint256 outAmount = uniswapV3(assets[i], tokenAmounts[i], amountOutMin);
                recievedBase += outAmount;
            }
        }

        require(recievedBase > amounts[0] + feeAmounts[0], "ERR_PROFIT_TARGET");
        SafeERC20.safeTransfer(tokens[0], address(BALANCER_VAULT), amounts[0] + feeAmounts[0]);
    }

    /**
     * @dev triggers Balancer flash loan
     * @param tokens IERC20 instances array
     * @param amounts corresponding amounts array
     * @param userData borrower address
     */
    function makeFlashLoan(IERC20[] memory tokens, uint256[] memory amounts, bytes memory userData) internal {
        BALANCER_VAULT.flashLoan(this, tokens, amounts, userData);
    }

    /**
     * @dev perform asset swap to USDC
     * @param asset address
     * @param swapAmount amount of asset you want to swap
     * @param amountOutMin how much to get back in USDC
     * @return amountOut of the swap
     */
    function uniswapV3(address asset, uint256 swapAmount, uint256 amountOutMin) internal returns (uint256) {
        uint24 poolFee = 3000;
        address usdc = address(USDC_INSTANCE);

        SafeERC20.forceApprove(IERC20(asset), address(UNISWAP_ROUTER), swapAmount);

        uint256 amountOut = UNISWAP_ROUTER.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: asset,
                tokenOut: usdc,
                fee: poolFee,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: swapAmount,
                amountOutMinimum: amountOutMin,
                sqrtPriceLimitX96: 0
            })
        );

        require(amountOut >= amountOutMin, "ERR_AMOUNT_OUT_MIN");

        return amountOut;
    }

    /**
     * @dev Throws if the sender is not the balancer Vault.
     */
    function _checkVault() internal view virtual {
        if (address(BALANCER_VAULT) != _msgSender()) {
            revert CustomError("UNAUTHORIZED");
        }
    }
}
