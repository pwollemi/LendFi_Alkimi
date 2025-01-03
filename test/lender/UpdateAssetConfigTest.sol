// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../BasicDeploy.sol";
import {IPROTOCOL} from "../../contracts/interfaces/IProtocol.sol";
import {Lendefi} from "../../contracts/lender/Lendefi.sol";
import {MockRWA} from "../../contracts/mock/MockRWA.sol";
import {RWAPriceConsumerV3} from "../../contracts/mock/RWAOracle.sol";

contract UpdateAssetConfigTest is BasicDeploy {
    event UpdateAssetConfig(address indexed asset);

    MockRWA internal testToken;
    RWAPriceConsumerV3 internal testOracle;

    // Test parameters
    uint8 internal constant ORACLE_DECIMALS = 8;
    uint8 internal constant ASSET_DECIMALS = 18;
    uint8 internal constant ASSET_ACTIVE = 1;
    uint32 internal constant BORROW_THRESHOLD = 800; // 80%
    uint32 internal constant LIQUIDATION_THRESHOLD = 850; // 85%
    uint256 internal constant MAX_SUPPLY = 1_000_000 ether;
    uint256 internal constant ISOLATION_DEBT_CAP = 100_000e6;

    function setUp() public {
        // Use the updated deployment function that includes Oracle setup
        deployCompleteWithOracle();

        // TGE setup
        vm.prank(guardian);
        tokenInstance.initializeTGE(address(ecoInstance), address(treasuryInstance));

        // Deploy test token and oracle for this specific test
        testToken = new MockRWA("Test Token", "TEST");
        testOracle = new RWAPriceConsumerV3();
        testOracle.setPrice(1000e8); // $1000 per token

        // Now register the test oracle with our Oracle module
        vm.startPrank(address(timelockInstance));
        oracleInstance.addOracle(address(testToken), address(testOracle), ORACLE_DECIMALS);
        oracleInstance.setPrimaryOracle(address(testToken), address(testOracle));
        vm.stopPrank();
    }

    // Test 1: Only manager can update asset config
    function test_OnlyManagerCanUpdateAssetConfig() public {
        // Regular user should not be able to call updateAssetConfig
        vm.startPrank(alice);
        vm.expectRevert(); // Should revert due to missing role
        LendefiInstance.updateAssetConfig(
            address(testToken),
            address(testOracle),
            ORACLE_DECIMALS,
            ASSET_DECIMALS,
            ASSET_ACTIVE,
            BORROW_THRESHOLD,
            LIQUIDATION_THRESHOLD,
            MAX_SUPPLY,
            IPROTOCOL.CollateralTier.CROSS_A,
            ISOLATION_DEBT_CAP
        );
        vm.stopPrank();

        // Manager (timelock) should be able to update asset config
        vm.prank(address(timelockInstance));
        LendefiInstance.updateAssetConfig(
            address(testToken),
            address(testOracle),
            ORACLE_DECIMALS,
            ASSET_DECIMALS,
            ASSET_ACTIVE,
            BORROW_THRESHOLD,
            LIQUIDATION_THRESHOLD,
            MAX_SUPPLY,
            IPROTOCOL.CollateralTier.CROSS_A,
            ISOLATION_DEBT_CAP
        );
    }

    // Test 2: Adding a new asset
    function test_AddingNewAsset() public {
        // Initial state - asset should not be listed
        address[] memory initialAssets = LendefiInstance.getListedAssets();
        bool initiallyPresent = false;
        for (uint256 i = 0; i < initialAssets.length; i++) {
            if (initialAssets[i] == address(testToken)) {
                initiallyPresent = true;
                break;
            }
        }
        assertFalse(initiallyPresent, "Asset should not be listed initially");

        // Update asset config
        vm.prank(address(timelockInstance));
        LendefiInstance.updateAssetConfig(
            address(testToken),
            address(testOracle),
            ORACLE_DECIMALS,
            ASSET_DECIMALS,
            ASSET_ACTIVE,
            BORROW_THRESHOLD,
            LIQUIDATION_THRESHOLD,
            MAX_SUPPLY,
            IPROTOCOL.CollateralTier.CROSS_A,
            ISOLATION_DEBT_CAP
        );

        // Asset should now be listed
        address[] memory updatedAssets = LendefiInstance.getListedAssets();
        bool nowPresent = false;
        for (uint256 i = 0; i < updatedAssets.length; i++) {
            if (updatedAssets[i] == address(testToken)) {
                nowPresent = true;
                break;
            }
        }
        assertTrue(nowPresent, "Asset should be listed after update");
    }

    // Test 3: All parameters correctly stored
    function test_AllParametersCorrectlyStored() public {
        // Update asset config
        vm.prank(address(timelockInstance));
        LendefiInstance.updateAssetConfig(
            address(testToken),
            address(testOracle),
            ORACLE_DECIMALS,
            ASSET_DECIMALS,
            ASSET_ACTIVE,
            BORROW_THRESHOLD,
            LIQUIDATION_THRESHOLD,
            MAX_SUPPLY,
            IPROTOCOL.CollateralTier.CROSS_A,
            ISOLATION_DEBT_CAP
        );

        // Get stored asset info
        IPROTOCOL.Asset memory assetInfo = LendefiInstance.getAssetInfo(address(testToken));

        // Verify all parameters
        assertEq(assetInfo.active, ASSET_ACTIVE, "Active status not stored correctly");
        assertEq(assetInfo.oracleUSD, address(testOracle), "Oracle address not stored correctly");
        assertEq(assetInfo.oracleDecimals, ORACLE_DECIMALS, "Oracle decimals not stored correctly");
        assertEq(assetInfo.decimals, ASSET_DECIMALS, "Asset decimals not stored correctly");
        assertEq(assetInfo.borrowThreshold, BORROW_THRESHOLD, "Borrow threshold not stored correctly");
        assertEq(assetInfo.liquidationThreshold, LIQUIDATION_THRESHOLD, "Liquidation threshold not stored correctly");
        assertEq(assetInfo.maxSupplyThreshold, MAX_SUPPLY, "Max supply not stored correctly");
        assertEq(uint8(assetInfo.tier), uint8(IPROTOCOL.CollateralTier.CROSS_A), "Tier not stored correctly");
        assertEq(assetInfo.isolationDebtCap, ISOLATION_DEBT_CAP, "Isolation debt cap not stored correctly");
    }

    // Test 4: Update existing asset
    function test_UpdateExistingAsset() public {
        // First add the asset
        vm.prank(address(timelockInstance));
        LendefiInstance.updateAssetConfig(
            address(testToken),
            address(testOracle),
            ORACLE_DECIMALS,
            ASSET_DECIMALS,
            ASSET_ACTIVE,
            BORROW_THRESHOLD,
            LIQUIDATION_THRESHOLD,
            MAX_SUPPLY,
            IPROTOCOL.CollateralTier.CROSS_A,
            ISOLATION_DEBT_CAP
        );

        // Now update some parameters
        uint8 newActive = 0; // Deactivate
        uint32 newBorrowThreshold = 700; // 70%
        IPROTOCOL.CollateralTier newTier = IPROTOCOL.CollateralTier.ISOLATED;
        uint256 newDebtCap = 50_000e6;

        vm.prank(address(timelockInstance));
        LendefiInstance.updateAssetConfig(
            address(testToken),
            address(testOracle),
            ORACLE_DECIMALS,
            ASSET_DECIMALS,
            newActive,
            newBorrowThreshold,
            LIQUIDATION_THRESHOLD,
            MAX_SUPPLY,
            newTier,
            newDebtCap
        );

        // Verify updated parameters
        IPROTOCOL.Asset memory assetInfo = LendefiInstance.getAssetInfo(address(testToken));

        assertEq(assetInfo.active, newActive, "Active status not updated correctly");
        assertEq(assetInfo.borrowThreshold, newBorrowThreshold, "Borrow threshold not updated correctly");
        assertEq(uint8(assetInfo.tier), uint8(newTier), "Tier not updated correctly");
        assertEq(assetInfo.isolationDebtCap, newDebtCap, "Isolation debt cap not updated correctly");
    }

    // Test 5: Correct event emission
    function test_EventEmission() public {
        vm.expectEmit(true, false, false, false);
        emit UpdateAssetConfig(address(testToken));

        vm.prank(address(timelockInstance));
        LendefiInstance.updateAssetConfig(
            address(testToken),
            address(testOracle),
            ORACLE_DECIMALS,
            ASSET_DECIMALS,
            ASSET_ACTIVE,
            BORROW_THRESHOLD,
            LIQUIDATION_THRESHOLD,
            MAX_SUPPLY,
            IPROTOCOL.CollateralTier.CROSS_A,
            ISOLATION_DEBT_CAP
        );
    }

    // Test 6: Effect on collateral management
    function test_EffectOnCollateral() public {
        // First add the asset as active
        vm.prank(address(timelockInstance));
        LendefiInstance.updateAssetConfig(
            address(testToken),
            address(testOracle),
            ORACLE_DECIMALS,
            ASSET_DECIMALS,
            ASSET_ACTIVE,
            BORROW_THRESHOLD,
            LIQUIDATION_THRESHOLD,
            MAX_SUPPLY,
            IPROTOCOL.CollateralTier.CROSS_A,
            ISOLATION_DEBT_CAP
        );

        // Setup user position
        testToken.mint(alice, 10 ether);
        vm.startPrank(alice);
        LendefiInstance.createPosition(address(testToken), false);
        testToken.approve(address(LendefiInstance), 10 ether);
        LendefiInstance.supplyCollateral(address(testToken), 5 ether, 0);
        vm.stopPrank();

        // Deactivate the asset
        vm.prank(address(timelockInstance));
        LendefiInstance.updateAssetConfig(
            address(testToken),
            address(testOracle),
            ORACLE_DECIMALS,
            ASSET_DECIMALS,
            0, // Deactivate
            BORROW_THRESHOLD,
            LIQUIDATION_THRESHOLD,
            MAX_SUPPLY,
            IPROTOCOL.CollateralTier.CROSS_A,
            ISOLATION_DEBT_CAP
        );

        // Try supplying more collateral - should revert
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(IPROTOCOL.AssetDisabled.selector, address(testToken)));
        LendefiInstance.supplyCollateral(address(testToken), 5 ether, 0);
        vm.stopPrank();
    }
}
