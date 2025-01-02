// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../BasicDeploy.sol";
import {console2} from "forge-std/console2.sol";
import {IPROTOCOL} from "../../contracts/interfaces/IProtocol.sol";
import {RWAPriceConsumerV3} from "../../contracts/mock/RWAOracle.sol";
import {WETHPriceConsumerV3} from "../../contracts/mock/WETHOracle.sol";
import {MockRWA} from "../../contracts/mock/MockRWA.sol";
import {Lendefi} from "../../contracts/lender/Lendefi.sol";

contract SupplyCollateralTest is BasicDeploy {
    // Events to verify
    event SupplyCollateral(address indexed user, uint256 indexed positionId, address indexed asset, uint256 amount);
    event TVLUpdated(address indexed asset, uint256 amount);

    MockRWA internal rwaToken;
    MockRWA internal stableToken;
    MockRWA internal crossBToken;

    RWAPriceConsumerV3 internal rwaOracleInstance;
    RWAPriceConsumerV3 internal stableOracleInstance;
    RWAPriceConsumerV3 internal crossBOracleInstance;
    WETHPriceConsumerV3 internal wethOracleInstance;

    function setUp() public {
        deployComplete();

        // TGE setup
        vm.prank(guardian);
        tokenInstance.initializeTGE(address(ecoInstance), address(treasuryInstance));

        // Deploy mock tokens
        usdcInstance = new USDC();
        wethInstance = new WETH9();
        rwaToken = new MockRWA("Ondo Finance", "ONDO");
        stableToken = new MockRWA("USDT", "USDT");
        crossBToken = new MockRWA("Cross B Token", "CROSSB");

        // Deploy oracles
        wethOracleInstance = new WETHPriceConsumerV3();
        rwaOracleInstance = new RWAPriceConsumerV3();
        stableOracleInstance = new RWAPriceConsumerV3();
        crossBOracleInstance = new RWAPriceConsumerV3();

        // Set prices
        wethOracleInstance.setPrice(2500e8); // $2500 per ETH
        rwaOracleInstance.setPrice(1000e8); // $1000 per RWA token
        stableOracleInstance.setPrice(1e8); // $1 per USDT
        crossBOracleInstance.setPrice(500e8); // $500 per CROSSB token

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

        _setupAssets();
        _setupLiquidity();
    }

    function _setupAssets() internal {
        vm.startPrank(address(timelockInstance));

        // Configure WETH as CROSS_A tier
        LendefiInstance.updateAssetConfig(
            address(wethInstance),
            address(wethOracleInstance),
            8,
            18,
            1,
            800, // 80% borrow threshold
            850, // 85% liquidation threshold
            1_000_000 ether,
            IPROTOCOL.CollateralTier.CROSS_A,
            0
        );

        // Configure RWA token as ISOLATED tier
        LendefiInstance.updateAssetConfig(
            address(rwaToken),
            address(rwaOracleInstance),
            8,
            18,
            1,
            650, // 65% borrow threshold
            750, // 75% liquidation threshold
            1_000_000 ether,
            IPROTOCOL.CollateralTier.ISOLATED,
            100_000e6 // Isolation debt cap of 100,000 USDC
        );

        // Configure USDT as STABLE tier
        LendefiInstance.updateAssetConfig(
            address(stableToken),
            address(stableOracleInstance),
            8,
            18,
            1,
            900, // 90% borrow threshold
            950, // 95% liquidation threshold
            1_000_000 ether,
            IPROTOCOL.CollateralTier.STABLE,
            0
        );

        // Configure Cross B token
        LendefiInstance.updateAssetConfig(
            address(crossBToken),
            address(crossBOracleInstance),
            8,
            18,
            1,
            700, // 70% borrow threshold
            800, // 80% liquidation threshold
            1_000_000 ether,
            IPROTOCOL.CollateralTier.CROSS_B,
            0
        );

        vm.stopPrank();
    }

    function _setupLiquidity() internal {
        // Provide liquidity to the protocol
        usdcInstance.mint(alice, 1_000_000e6);
        vm.startPrank(alice);
        usdcInstance.approve(address(LendefiInstance), 1_000_000e6);
        LendefiInstance.supplyLiquidity(1_000_000e6);
        vm.stopPrank();
    }

    function _createPosition(address user, address asset, bool isIsolated) internal returns (uint256) {
        vm.startPrank(user);
        LendefiInstance.createPosition(asset, isIsolated);
        uint256 positionId = LendefiInstance.getUserPositionsCount(user) - 1;
        vm.stopPrank();
        return positionId;
    }

    function _mintTokens(address user, address token, uint256 amount) internal {
        if (token == address(wethInstance)) {
            vm.deal(user, amount);
            vm.prank(user);
            wethInstance.deposit{value: amount}();
        } else {
            MockRWA(token).mint(user, amount);
        }
    }

    // Test 1: Basic supply of collateral to a non-isolated position
    function test_BasicSupplyCollateral() public {
        uint256 collateralAmount = 10 ether;

        // Create position
        uint256 positionId = _createPosition(bob, address(wethInstance), false);

        // Mint collateral tokens
        _mintTokens(bob, address(wethInstance), collateralAmount);

        uint256 initialTVL = LendefiInstance.assetTVL(address(wethInstance));
        uint256 initialTotalCollateral = LendefiInstance.totalCollateral(address(wethInstance));

        vm.startPrank(bob);
        wethInstance.approve(address(LendefiInstance), collateralAmount);

        // First we expect the TVLUpdated event
        vm.expectEmit(true, false, false, true);
        emit TVLUpdated(address(wethInstance), initialTVL + collateralAmount);

        // Then we expect the SupplyCollateral event
        vm.expectEmit(true, true, true, true);
        emit SupplyCollateral(bob, positionId, address(wethInstance), collateralAmount);

        // Supply collateral
        LendefiInstance.supplyCollateral(address(wethInstance), collateralAmount, positionId);
        vm.stopPrank();

        // Verify state changes
        uint256 finalTVL = LendefiInstance.assetTVL(address(wethInstance));
        uint256 finalTotalCollateral = LendefiInstance.totalCollateral(address(wethInstance));
        uint256 positionCollateral = LendefiInstance.getUserCollateralAmount(bob, positionId, address(wethInstance));

        assertEq(finalTVL, initialTVL + collateralAmount, "TVL should increase");
        assertEq(finalTotalCollateral, initialTotalCollateral + collateralAmount, "Total collateral should increase");
        assertEq(positionCollateral, collateralAmount, "Position collateral should be updated");

        // Check position assets
        address[] memory posAssets = LendefiInstance.getPositionCollateralAssets(bob, positionId);
        assertEq(posAssets.length, 1, "Position should have 1 asset");
        assertEq(posAssets[0], address(wethInstance), "Position asset should be WETH");
    }

    // Test 2: Supply collateral to an isolated position
    function test_SupplyIsolatedCollateral() public {
        uint256 collateralAmount = 10 ether;

        // Create isolated position
        uint256 positionId = _createPosition(bob, address(rwaToken), true);

        // Mint collateral tokens
        _mintTokens(bob, address(rwaToken), collateralAmount);

        vm.startPrank(bob);
        rwaToken.approve(address(LendefiInstance), collateralAmount);

        // Supply collateral
        LendefiInstance.supplyCollateral(address(rwaToken), collateralAmount, positionId);
        vm.stopPrank();

        // Verify state changes
        uint256 positionCollateral = LendefiInstance.getUserCollateralAmount(bob, positionId, address(rwaToken));
        assertEq(positionCollateral, collateralAmount, "Position collateral should be updated");

        // Check position is still in isolation mode
        IPROTOCOL.UserPosition memory position = LendefiInstance.getUserPosition(bob, positionId);
        address[] memory posAssets = LendefiInstance.getPositionCollateralAssets(bob, positionId);
        assertTrue(position.isIsolated, "Position should remain isolated");
        assertEq(posAssets[0], address(rwaToken), "Isolated asset should be RWA token");
    }

    // Test 3: Supply isolated asset to a non-isolated position should fail
    function test_SupplyIsolatedAssetToNonIsolatedPosition() public {
        uint256 collateralAmount = 10 ether;

        // Create non-isolated position
        uint256 positionId = _createPosition(bob, address(wethInstance), false);

        // Mint RWA tokens (isolated asset)
        _mintTokens(bob, address(rwaToken), collateralAmount);

        vm.startPrank(bob);
        rwaToken.approve(address(LendefiInstance), collateralAmount);

        // Should fail when trying to supply isolated asset to non-isolated position
        vm.expectRevert(abi.encodeWithSelector(IPROTOCOL.IsolationModeRequired.selector, address(rwaToken)));
        LendefiInstance.supplyCollateral(address(rwaToken), collateralAmount, positionId);
        vm.stopPrank();
    }

    // Test 5: Supply to an isolated position that already has the same asset
    function test_SupplyMoreToIsolatedPosition() public {
        uint256 initialAmount = 5 ether;
        uint256 additionalAmount = 5 ether;

        // Create isolated position
        uint256 positionId = _createPosition(bob, address(rwaToken), true);

        // Mint and supply initial collateral
        _mintTokens(bob, address(rwaToken), initialAmount + additionalAmount);

        vm.startPrank(bob);
        rwaToken.approve(address(LendefiInstance), initialAmount + additionalAmount);
        LendefiInstance.supplyCollateral(address(rwaToken), initialAmount, positionId);

        // Supply more of the same asset
        LendefiInstance.supplyCollateral(address(rwaToken), additionalAmount, positionId);
        vm.stopPrank();

        // Verify total collateral
        uint256 positionCollateral = LendefiInstance.getUserCollateralAmount(bob, positionId, address(rwaToken));
        assertEq(positionCollateral, initialAmount + additionalAmount, "Position collateral should be updated");

        // Check assets array still has only one entry
        address[] memory posAssets = LendefiInstance.getPositionCollateralAssets(bob, positionId);
        assertEq(posAssets.length, 1, "Position should have 1 asset");
    }

    // Test 6: Supply multiple assets to a cross-collateral position
    function test_SupplyMultipleAssetsToCrossPosition() public {
        uint256 wethAmount = 5 ether;
        uint256 stableAmount = 1000 ether;
        uint256 crossBAmount = 10 ether;

        // Create cross position
        uint256 positionId = _createPosition(bob, address(wethInstance), false);

        // Mint tokens
        _mintTokens(bob, address(wethInstance), wethAmount);
        _mintTokens(bob, address(stableToken), stableAmount);
        _mintTokens(bob, address(crossBToken), crossBAmount);

        vm.startPrank(bob);
        wethInstance.approve(address(LendefiInstance), wethAmount);
        stableToken.approve(address(LendefiInstance), stableAmount);
        crossBToken.approve(address(LendefiInstance), crossBAmount);

        // Supply all three assets
        LendefiInstance.supplyCollateral(address(wethInstance), wethAmount, positionId);
        LendefiInstance.supplyCollateral(address(stableToken), stableAmount, positionId);
        LendefiInstance.supplyCollateral(address(crossBToken), crossBAmount, positionId);
        vm.stopPrank();

        // Verify collateral amounts
        assertEq(
            LendefiInstance.getUserCollateralAmount(bob, positionId, address(wethInstance)),
            wethAmount,
            "WETH collateral incorrect"
        );
        assertEq(
            LendefiInstance.getUserCollateralAmount(bob, positionId, address(stableToken)),
            stableAmount,
            "Stable collateral incorrect"
        );
        assertEq(
            LendefiInstance.getUserCollateralAmount(bob, positionId, address(crossBToken)),
            crossBAmount,
            "CrossB collateral incorrect"
        );

        // Check position assets
        address[] memory posAssets = LendefiInstance.getPositionCollateralAssets(bob, positionId);
        assertEq(posAssets.length, 3, "Position should have 3 assets");
    }

    // Test 7: Supply up to supply cap
    function test_SupplyUpToCap() public {
        // Set a small supply cap for testing
        vm.startPrank(address(timelockInstance));
        LendefiInstance.updateAssetConfig(
            address(stableToken),
            address(stableOracleInstance),
            8,
            18,
            1,
            900,
            950,
            100 ether, // Low cap of 100 tokens
            IPROTOCOL.CollateralTier.STABLE,
            0
        );
        vm.stopPrank();

        // Create position
        uint256 positionId = _createPosition(bob, address(stableToken), false);

        // Mint tokens - exactly at the cap
        _mintTokens(bob, address(stableToken), 100 ether);

        vm.startPrank(bob);
        stableToken.approve(address(LendefiInstance), 100 ether);

        // Supply exactly at cap (should succeed)
        LendefiInstance.supplyCollateral(address(stableToken), 100 ether, positionId);
        vm.stopPrank();

        // Verify amount
        assertEq(
            LendefiInstance.getUserCollateralAmount(bob, positionId, address(stableToken)),
            100 ether,
            "Collateral should be supplied"
        );
    }

    // Test 8: Supply exceeding cap should fail
    function test_SupplyExceedingCap() public {
        // Set a small supply cap for testing
        vm.startPrank(address(timelockInstance));
        LendefiInstance.updateAssetConfig(
            address(stableToken),
            address(stableOracleInstance),
            8,
            18,
            1,
            900,
            950,
            100 ether, // Low cap of 100 tokens
            IPROTOCOL.CollateralTier.STABLE,
            0
        );
        vm.stopPrank();

        // Create position
        uint256 positionId = _createPosition(bob, address(stableToken), false);

        // Mint tokens - exceeding the cap
        _mintTokens(bob, address(stableToken), 101 ether);

        vm.startPrank(bob);
        stableToken.approve(address(LendefiInstance), 101 ether);

        // Attempt to supply over cap
        vm.expectRevert(
            abi.encodeWithSelector(IPROTOCOL.SupplyCapExceeded.selector, address(stableToken), 101 ether, 100 ether)
        );
        LendefiInstance.supplyCollateral(address(stableToken), 101 ether, positionId);
        vm.stopPrank();
    }

    // Test 9: Supply to position with existing debt
    function test_SupplyToPositionWithDebt() public {
        uint256 collateralAmount = 10 ether;
        uint256 additionalCollateral = 5 ether;

        // Create position and supply initial collateral
        uint256 positionId = _createPosition(bob, address(wethInstance), false);
        _mintTokens(bob, address(wethInstance), collateralAmount + additionalCollateral);

        vm.startPrank(bob);
        wethInstance.approve(address(LendefiInstance), collateralAmount + additionalCollateral);
        LendefiInstance.supplyCollateral(address(wethInstance), collateralAmount, positionId);

        // Borrow against the position
        uint256 borrowAmount = 5000e6; // $5000 USDC
        LendefiInstance.borrow(positionId, borrowAmount);

        // Supply additional collateral after borrowing
        LendefiInstance.supplyCollateral(address(wethInstance), additionalCollateral, positionId);
        vm.stopPrank();

        // Verify position state
        uint256 positionCollateral = LendefiInstance.getUserCollateralAmount(bob, positionId, address(wethInstance));
        assertEq(positionCollateral, collateralAmount + additionalCollateral, "Position collateral should be updated");

        IPROTOCOL.UserPosition memory position = LendefiInstance.getUserPosition(bob, positionId);
        assertEq(position.debtAmount, borrowAmount, "Debt should remain unchanged");
    }

    // Test 10: Supply to an inactive asset should fail
    function test_SupplyInactiveAsset() public {
        // Deactivate the WETH asset
        vm.startPrank(address(timelockInstance));
        LendefiInstance.updateAssetConfig(
            address(wethInstance),
            address(wethOracleInstance),
            8,
            18,
            0, // Set inactive
            800,
            850,
            1_000_000 ether,
            IPROTOCOL.CollateralTier.CROSS_A,
            0
        );
        vm.stopPrank();

        // Create position
        uint256 positionId = _createPosition(bob, address(wethInstance), false);
        _mintTokens(bob, address(wethInstance), 10 ether);

        vm.startPrank(bob);
        wethInstance.approve(address(LendefiInstance), 10 ether);

        // Attempt to supply inactive asset
        vm.expectRevert(abi.encodeWithSelector(IPROTOCOL.AssetDisabled.selector, address(wethInstance)));
        LendefiInstance.supplyCollateral(address(wethInstance), 10 ether, positionId);
        vm.stopPrank();
    }

    // Test 11: Supply to invalid position
    function test_SupplyInvalidPositionId() public {
        _mintTokens(bob, address(wethInstance), 10 ether);

        vm.startPrank(bob);
        wethInstance.approve(address(LendefiInstance), 10 ether);

        // Attempt to supply to nonexistent position
        vm.expectRevert(abi.encodeWithSelector(IPROTOCOL.InvalidPosition.selector, bob, 999));
        LendefiInstance.supplyCollateral(address(wethInstance), 10 ether, 999);
        vm.stopPrank();
    }

    // Test 12: Supply unlisted asset should fail
    function test_SupplyUnlistedAsset() public {
        // Create a new unlisted token
        MockRWA unlistedToken = new MockRWA("Unlisted", "UNLIST");

        // Create position
        uint256 positionId = _createPosition(bob, address(wethInstance), false);
        _mintTokens(bob, address(unlistedToken), 10 ether);

        vm.startPrank(bob);
        unlistedToken.approve(address(LendefiInstance), 10 ether);

        // Attempt to supply unlisted asset
        vm.expectRevert(abi.encodeWithSelector(IPROTOCOL.AssetNotListed.selector, address(unlistedToken)));
        LendefiInstance.supplyCollateral(address(unlistedToken), 10 ether, positionId);
        vm.stopPrank();
    }

    // Test 13: Supply when protocol is paused should fail
    function test_SupplyWhenPaused() public {
        uint256 positionId = _createPosition(bob, address(wethInstance), false);
        _mintTokens(bob, address(wethInstance), 10 ether);

        // Pause the protocol
        vm.prank(guardian);
        LendefiInstance.pause();

        vm.startPrank(bob);
        wethInstance.approve(address(LendefiInstance), 10 ether);

        // Attempt to supply when paused
        bytes memory expError = abi.encodeWithSignature("EnforcedPause()");
        vm.expectRevert(expError);
        LendefiInstance.supplyCollateral(address(wethInstance), 10 ether, positionId);
        vm.stopPrank();
    }

    // Test 14: Supply zero amount
    function test_SupplyZeroAmount() public {
        uint256 positionId = _createPosition(bob, address(wethInstance), false);

        vm.startPrank(bob);
        wethInstance.approve(address(LendefiInstance), 0);

        // Supply zero amount
        LendefiInstance.supplyCollateral(address(wethInstance), 0, positionId);
        vm.stopPrank();

        // Verify no change
        uint256 positionCollateral = LendefiInstance.getUserCollateralAmount(bob, positionId, address(wethInstance));
        assertEq(positionCollateral, 0, "Position collateral should remain zero");
    }

    // Fuzz Test 1: Supply varying amounts
    function testFuzz_SupplyVaryingAmounts(uint256 amount) public {
        // Bound to reasonable amounts
        amount = bound(amount, 0, 1000 ether);

        uint256 positionId = _createPosition(bob, address(wethInstance), false);
        _mintTokens(bob, address(wethInstance), amount);

        vm.startPrank(bob);
        wethInstance.approve(address(LendefiInstance), amount);
        LendefiInstance.supplyCollateral(address(wethInstance), amount, positionId);
        vm.stopPrank();

        // Verify state
        uint256 positionCollateral = LendefiInstance.getUserCollateralAmount(bob, positionId, address(wethInstance));
        assertEq(positionCollateral, amount, "Position collateral should match supplied amount");
    }

    // Fuzz Test 2: Supply multiple times with varying amounts
    function testFuzz_MultipleSupplies(uint256 amount1, uint256 amount2, uint256 amount3) public {
        // Bound to reasonable amounts
        amount1 = bound(amount1, 0, 500 ether);
        amount2 = bound(amount2, 0, 500 ether);
        amount3 = bound(amount3, 0, 500 ether);

        uint256 totalAmount = amount1 + amount2 + amount3;

        uint256 positionId = _createPosition(bob, address(wethInstance), false);
        _mintTokens(bob, address(wethInstance), totalAmount);

        vm.startPrank(bob);
        wethInstance.approve(address(LendefiInstance), totalAmount);

        // Supply in multiple transactions
        LendefiInstance.supplyCollateral(address(wethInstance), amount1, positionId);
        LendefiInstance.supplyCollateral(address(wethInstance), amount2, positionId);
        LendefiInstance.supplyCollateral(address(wethInstance), amount3, positionId);
        vm.stopPrank();

        // Verify accumulated amount
        uint256 positionCollateral = LendefiInstance.getUserCollateralAmount(bob, positionId, address(wethInstance));
        assertEq(positionCollateral, totalAmount, "Position collateral should match total supplied");
    }

    // Fuzz Test 3: Test with multiple positions
    function testFuzz_MultiplePositions(uint256 amount1, uint256 amount2) public {
        // Bound to reasonable amounts
        amount1 = bound(amount1, 1 ether, 500 ether);
        amount2 = bound(amount2, 1 ether, 500 ether);

        // Create  positions
        uint256 positionId1 = _createPosition(bob, address(wethInstance), false);
        uint256 positionId2 = _createPosition(bob, address(wethInstance), false);

        _mintTokens(bob, address(wethInstance), amount1 + amount2);

        vm.startPrank(bob);
        wethInstance.approve(address(LendefiInstance), amount1 + amount2);

        // Supply to both positions
        LendefiInstance.supplyCollateral(address(wethInstance), amount1, positionId1);
        LendefiInstance.supplyCollateral(address(wethInstance), amount2, positionId2);
        vm.stopPrank();

        // Verify individual position amounts
        uint256 collateral1 = LendefiInstance.getUserCollateralAmount(bob, positionId1, address(wethInstance));
        uint256 collateral2 = LendefiInstance.getUserCollateralAmount(bob, positionId2, address(wethInstance));

        assertEq(collateral1, amount1, "Position 1 collateral incorrect");
        assertEq(collateral2, amount2, "Position 2 collateral incorrect");
    }
}
