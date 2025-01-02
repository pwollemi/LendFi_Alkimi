// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../BasicDeploy.sol";
import {console2} from "forge-std/console2.sol";
import {IPROTOCOL} from "../../contracts/interfaces/IProtocol.sol";
import {Lendefi} from "../../contracts/lender/Lendefi.sol";
import {WETHPriceConsumerV3} from "../../contracts/mock/WETHOracle.sol";
import {StablePriceConsumerV3} from "../../contracts/mock/StableOracle.sol";
import {TokenMock} from "../../contracts/mock/TokenMock.sol";

contract getPositionCollateralAssetsTest is BasicDeploy {
    // Assets
    WETHPriceConsumerV3 internal wethOracleInstance;
    StablePriceConsumerV3 internal stableOracleInstance;
    WETHPriceConsumerV3 internal linkOracleInstance;

    TokenMock internal linkInstance;

    // Constants
    uint256 constant ETH_PRICE = 2500e8; // $2500 per ETH
    uint256 constant LINK_PRICE = 15e8; // $15 per LINK

    function setUp() public {
        deployComplete();

        // TGE setup
        vm.prank(guardian);
        tokenInstance.initializeTGE(address(ecoInstance), address(treasuryInstance));
        vm.warp(block.timestamp + 90 days);

        // Deploy mock tokens
        usdcInstance = new USDC();
        wethInstance = new WETH9();
        linkInstance = new TokenMock("Chainlink", "LINK");

        // Deploy oracles
        wethOracleInstance = new WETHPriceConsumerV3();
        stableOracleInstance = new StablePriceConsumerV3();
        linkOracleInstance = new WETHPriceConsumerV3();

        // Set prices
        wethOracleInstance.setPrice(int256(ETH_PRICE)); // $2500 per ETH
        stableOracleInstance.setPrice(1e8); // $1 per stable
        linkOracleInstance.setPrice(int256(LINK_PRICE)); // $15 per LINK

        // Deploy Lendefi
        bytes memory data = abi.encodeCall(
            Lendefi.initialize,
            (
                address(usdcInstance),
                address(tokenInstance),
                address(ecoInstance),
                address(treasuryInstance),
                address(timelockInstance),
                guardian
            )
        );

        address payable proxy = payable(Upgrades.deployUUPSProxy("Lendefi.sol", data));
        LendefiInstance = Lendefi(proxy);

        // Setup roles
        vm.prank(guardian);
        ecoInstance.grantRole(REWARDER_ROLE, address(LendefiInstance));

        // Configure assets
        _setupAssets();

        // Add liquidity to enable borrowing
        usdcInstance.mint(guardian, 1_000_000e6);
        vm.startPrank(guardian);
        usdcInstance.approve(address(LendefiInstance), 1_000_000e6);
        LendefiInstance.supplyLiquidity(1_000_000e6);
        vm.stopPrank();
    }

    function _setupAssets() internal {
        vm.startPrank(address(timelockInstance));

        // Configure WETH as CROSS_A tier
        LendefiInstance.updateAssetConfig(
            address(wethInstance),
            address(wethOracleInstance),
            8, // Oracle decimals
            18, // Asset decimals
            1, // Active
            800, // 80% borrow threshold
            850, // 85% liquidation threshold
            1_000_000 ether, // Supply limit
            IPROTOCOL.CollateralTier.CROSS_A,
            10_000e6 // Isolation debt cap
        );

        // Configure USDC as STABLE tier
        LendefiInstance.updateAssetConfig(
            address(usdcInstance),
            address(stableOracleInstance),
            8, // Oracle decimals
            6, // USDC decimals
            1, // Active
            900, // 90% borrow threshold
            950, // 95% liquidation threshold
            1_000_000e6, // Supply limit
            IPROTOCOL.CollateralTier.STABLE,
            0 // No isolation debt cap
        );

        // Configure LINK as ISOLATED tier
        LendefiInstance.updateAssetConfig(
            address(linkInstance),
            address(linkOracleInstance),
            8, // Oracle decimals
            18, // Asset decimals
            1, // Active
            700, // 70% borrow threshold
            750, // 75% liquidation threshold
            100_000 ether, // Supply limit
            IPROTOCOL.CollateralTier.ISOLATED,
            5_000e6 // Isolation debt cap
        );

        vm.stopPrank();
    }

    function _setupPosition(address user, bool isIsolated) internal returns (uint256) {
        vm.startPrank(user);

        // Create position with WETH collateral by default (or LINK if isolated)
        address collateralAsset = isIsolated ? address(linkInstance) : address(wethInstance);

        // Create position
        LendefiInstance.createPosition(collateralAsset, isIsolated);
        uint256 positionId = LendefiInstance.getUserPositionsCount(user) - 1;

        vm.stopPrank();

        return positionId;
    }

    function _addCollateralToPosition(address user, uint256 positionId, address asset, uint256 amount) internal {
        vm.startPrank(user);

        // Mint and approve token
        if (asset == address(wethInstance)) {
            vm.deal(user, amount);
            wethInstance.deposit{value: amount}();
            wethInstance.approve(address(LendefiInstance), amount);
        } else if (asset == address(linkInstance)) {
            linkInstance.mint(user, amount);
            linkInstance.approve(address(LendefiInstance), amount);
        } else if (asset == address(usdcInstance)) {
            usdcInstance.mint(user, amount);
            usdcInstance.approve(address(LendefiInstance), amount);
        }

        // Add collateral
        LendefiInstance.supplyCollateral(asset, amount, positionId);

        vm.stopPrank();
    }

    function test_getPositionCollateralAssets_Empty() public {
        uint256 positionId = _setupPosition(alice, false);

        // Position should have no assets yet
        address[] memory assets = LendefiInstance.getPositionCollateralAssets(alice, positionId);
        assertEq(assets.length, 0, "New position should have no assets");
    }

    function test_getPositionCollateralAssets_SingleAsset() public {
        uint256 positionId = _setupPosition(alice, false);

        // Add WETH collateral
        uint256 wethAmount = 1 ether;
        _addCollateralToPosition(alice, positionId, address(wethInstance), wethAmount);

        // Check position assets
        address[] memory assets = LendefiInstance.getPositionCollateralAssets(alice, positionId);

        assertEq(assets.length, 1, "Position should have exactly one asset");
        assertEq(assets[0], address(wethInstance), "Asset should be WETH");

        // Verify collateral amount
        uint256 collateralAmount = LendefiInstance.getUserCollateralAmount(alice, positionId, address(wethInstance));
        assertEq(collateralAmount, wethAmount, "Collateral amount should match");
    }

    function test_getPositionCollateralAssets_IsolatedPosition() public {
        uint256 positionId = _setupPosition(alice, true);

        // Add LINK collateral (isolated position can only have LINK)
        uint256 linkAmount = 10 ether;
        _addCollateralToPosition(alice, positionId, address(linkInstance), linkAmount);

        // Check position assets
        address[] memory assets = LendefiInstance.getPositionCollateralAssets(alice, positionId);

        assertEq(assets.length, 1, "Position should have exactly one asset");
        assertEq(assets[0], address(linkInstance), "Asset should be LINK");

        // Verify collateral amount
        uint256 collateralAmount = LendefiInstance.getUserCollateralAmount(alice, positionId, address(linkInstance));
        assertEq(collateralAmount, linkAmount, "Collateral amount should match");
    }

    function test_getPositionCollateralAssets_MultiplePositions() public {
        // Create  positions for Alice
        uint256 position1 = _setupPosition(alice, false);
        uint256 position2 = _setupPosition(alice, true);

        // Add different collateral to each position
        _addCollateralToPosition(alice, position1, address(wethInstance), 2 ether);
        _addCollateralToPosition(alice, position2, address(linkInstance), 20 ether);

        // Check position assets for position 1
        address[] memory assets1 = LendefiInstance.getPositionCollateralAssets(alice, position1);
        assertEq(assets1.length, 1, "Position 1 should have one asset");
        assertEq(assets1[0], address(wethInstance), "Position 1 asset should be WETH");

        // Check position assets for position 2
        address[] memory assets2 = LendefiInstance.getPositionCollateralAssets(alice, position2);
        assertEq(assets2.length, 1, "Position 2 should have one asset");
        assertEq(assets2[0], address(linkInstance), "Position 2 asset should be LINK");
    }

    function test_getPositionCollateralAssets_MultipleAssets() public {
        // Create a non-isolated position
        uint256 positionId = _setupPosition(alice, false);

        // Add WETH collateral
        uint256 wethAmount = 2 ether;
        _addCollateralToPosition(alice, positionId, address(wethInstance), wethAmount);

        // Add USDC collateral instead of LINK (since LINK requires isolation mode)
        uint256 usdcAmount = 1000e6;
        _addCollateralToPosition(alice, positionId, address(usdcInstance), usdcAmount);

        // Check position assets
        address[] memory assets = LendefiInstance.getPositionCollateralAssets(alice, positionId);

        assertEq(assets.length, 2, "Position should have exactly  assets");

        // Sort assets for consistent testing since order isn't guaranteed
        address[] memory sortedAssets = new address[](2);
        sortedAssets[0] = assets[0] < assets[1] ? assets[0] : assets[1];
        sortedAssets[1] = assets[0] < assets[1] ? assets[1] : assets[0];

        assertEq(
            sortedAssets[0] == address(usdcInstance) || sortedAssets[0] == address(wethInstance),
            true,
            "First asset should be USDC or WETH"
        );
        assertEq(
            sortedAssets[1] == address(usdcInstance) || sortedAssets[1] == address(wethInstance),
            true,
            "Second asset should be USDC or WETH"
        );
        assertNotEq(sortedAssets[0], sortedAssets[1], "Assets should be different");

        // Verify collateral amounts
        uint256 wethCollateralAmount = LendefiInstance.getUserCollateralAmount(alice, positionId, address(wethInstance));
        uint256 usdcCollateralAmount = LendefiInstance.getUserCollateralAmount(alice, positionId, address(usdcInstance));

        assertEq(wethCollateralAmount, wethAmount, "WETH collateral amount should match");
        assertEq(usdcCollateralAmount, usdcAmount, "USDC collateral amount should match");
    }

    function test_getPositionCollateralAssets_AfterWithdrawal() public {
        uint256 positionId = _setupPosition(alice, false);

        // Add WETH and USDC collateral instead of LINK (since LINK requires isolation mode)
        _addCollateralToPosition(alice, positionId, address(wethInstance), 3 ether);
        _addCollateralToPosition(alice, positionId, address(usdcInstance), 15_000e6);

        // Withdraw all WETH
        vm.startPrank(alice);
        LendefiInstance.withdrawCollateral(address(wethInstance), 3 ether, positionId);
        vm.stopPrank();

        // Check position assets
        address[] memory assets = LendefiInstance.getPositionCollateralAssets(alice, positionId);

        assertEq(assets.length, 1, "Position should have exactly one asset after withdrawal");
        assertEq(assets[0], address(usdcInstance), "Remaining asset should be USDC");

        // Verify WETH is removed and USDC is still there
        uint256 wethCollateralAmount = LendefiInstance.getUserCollateralAmount(alice, positionId, address(wethInstance));
        uint256 usdcCollateralAmount = LendefiInstance.getUserCollateralAmount(alice, positionId, address(usdcInstance));

        assertEq(wethCollateralAmount, 0, "WETH collateral amount should be zero");
        assertEq(usdcCollateralAmount, 15_000e6, "USDC collateral amount should remain unchanged");
    }

    function testRevert_getPositionCollateralAssets_InvalidPosition() public {
        // This should fail since position ID 999 doesn't exist
        vm.expectRevert(abi.encodeWithSelector(IPROTOCOL.InvalidPosition.selector, alice, 999));
        LendefiInstance.getPositionCollateralAssets(alice, 999);
    }

    function testRevert_getPositionCollateralAssets_WrongUser() public {
        // Create a position for Alice
        uint256 positionId = _setupPosition(alice, false);
        _addCollateralToPosition(alice, positionId, address(wethInstance), 1 ether);

        // Try to access Alice's position as Bob (should fail)
        vm.expectRevert(abi.encodeWithSelector(IPROTOCOL.InvalidPosition.selector, bob, positionId));
        LendefiInstance.getPositionCollateralAssets(bob, positionId);
    }
}
