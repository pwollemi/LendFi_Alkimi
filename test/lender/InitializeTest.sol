// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../BasicDeploy.sol";
import {console2} from "forge-std/console2.sol";
import {IPROTOCOL} from "../../contracts/interfaces/IProtocol.sol";
import {Lendefi} from "../../contracts/lender/Lendefi.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

contract InitializeTest is BasicDeploy {
    function setUp() public {
        usdcInstance = new USDC();
        deployComplete();

        // TGE setup
        vm.prank(guardian);
        tokenInstance.initializeTGE(address(ecoInstance), address(treasuryInstance));
    }

    function test_InitializeSuccess() public {
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
        // Test that contract is properly initialized with correct initial state
        assertEq(LendefiInstance.name(), "LENDEFI YIELD TOKEN", "Token name incorrect");
        assertEq(LendefiInstance.symbol(), "LYT", "Token symbol incorrect");

        // Check roles assignment
        assertTrue(LendefiInstance.hasRole(0x00, guardian), "Guardian not assigned DEFAULT_ADMIN_ROLE");
        assertTrue(LendefiInstance.hasRole(keccak256("PAUSER_ROLE"), guardian), "Guardian not assigned PAUSER_ROLE");
        assertTrue(
            LendefiInstance.hasRole(keccak256("MANAGER_ROLE"), address(timelockInstance)),
            "Timelock not assigned MANAGER_ROLE"
        );
        assertTrue(
            LendefiInstance.hasRole(keccak256("UPGRADER_ROLE"), address(timelockInstance)),
            "Timelock not assigned UPGRADER_ROLE"
        );

        // Check default parameters
        assertEq(LendefiInstance.targetReward(), 2_000 ether, "Incorrect targetReward");
        assertEq(LendefiInstance.rewardInterval(), 180 days, "Incorrect rewardInterval");
        assertEq(LendefiInstance.rewardableSupply(), 100_000 * 1e6, "Incorrect rewardableSupply");
        assertEq(LendefiInstance.baseBorrowRate(), 0.06e6, "Incorrect baseBorrowRate");
        assertEq(LendefiInstance.baseProfitTarget(), 0.01e6, "Incorrect baseProfitTarget");
        assertEq(LendefiInstance.liquidatorThreshold(), 20_000 ether, "Incorrect liquidatorThreshold");

        // Check tier parameters
        (uint256[4] memory borrowRates, uint256[4] memory liquidationBonuses) = LendefiInstance.getTierRates();

        // Check borrow rates
        assertEq(borrowRates[0], 0.15e6, "Incorrect ISOLATED borrow rate");
        assertEq(borrowRates[1], 0.08e6, "Incorrect CROSS_A borrow rate");
        assertEq(borrowRates[2], 0.12e6, "Incorrect CROSS_B borrow rate");
        assertEq(borrowRates[3], 0.05e6, "Incorrect STABLE borrow rate");

        // Check liquidation bonuses
        assertEq(liquidationBonuses[0], 0.15e6, "Incorrect ISOLATED liquidation bonus");
        assertEq(liquidationBonuses[1], 0.08e6, "Incorrect CROSS_A liquidation bonus");
        assertEq(liquidationBonuses[2], 0.1e6, "Incorrect CROSS_B liquidation bonus");
        assertEq(liquidationBonuses[3], 0.05e6, "Incorrect STABLE liquidation bonus");

        // Check version increment
        assertEq(LendefiInstance.version(), 1, "Version not incremented");

        // Check treasury and timelock addresses
        assertEq(LendefiInstance.treasury(), address(treasuryInstance), "Treasury address not set correctly");
    }

    function test_InitializeRevertsOnZeroAddress() public {
        // Deploy new logic contract
        LendefiInstance = new Lendefi();

        // Initialize with zero USDC address
        bytes memory initData = abi.encodeCall(
            Lendefi.initialize,
            (
                address(0), // Zero USDC address
                address(tokenInstance),
                address(ecoInstance),
                address(treasuryInstance),
                address(timelockInstance),
                guardian
            )
        );

        vm.expectRevert("ZERO_ADDRESS_DETECTED");
        ERC1967Proxy proxy1 = new ERC1967Proxy(address(LendefiInstance), initData);
        Lendefi(payable(address(proxy1)));

        // Initialize with zero token address
        initData = abi.encodeCall(
            Lendefi.initialize,
            (
                address(usdcInstance),
                address(0), // Zero token address
                address(ecoInstance),
                address(treasuryInstance),
                address(timelockInstance),
                guardian
            )
        );

        vm.expectRevert("ZERO_ADDRESS_DETECTED");
        ERC1967Proxy proxy2 = new ERC1967Proxy(address(LendefiInstance), initData);
        Lendefi(payable(address(proxy2)));

        // Initialize with zero treasury address
        initData = abi.encodeCall(
            Lendefi.initialize,
            (
                address(usdcInstance),
                address(tokenInstance),
                address(ecoInstance),
                address(0), // Zero treasury address
                address(timelockInstance),
                guardian
            )
        );

        vm.expectRevert("ZERO_ADDRESS_DETECTED");
        ERC1967Proxy proxy3 = new ERC1967Proxy(address(LendefiInstance), initData);
        Lendefi(payable(address(proxy3)));

        // Initialize with zero timelock address
        initData = abi.encodeCall(
            Lendefi.initialize,
            (
                address(usdcInstance),
                address(tokenInstance),
                address(ecoInstance),
                address(treasuryInstance),
                address(0), // Zero timelock address
                guardian
            )
        );

        vm.expectRevert("ZERO_ADDRESS_DETECTED");
        ERC1967Proxy proxy4 = new ERC1967Proxy(address(LendefiInstance), initData);
        Lendefi(payable(address(proxy4)));

        // Initialize with zero guardian address
        initData = abi.encodeCall(
            Lendefi.initialize,
            (
                address(usdcInstance),
                address(tokenInstance),
                address(ecoInstance),
                address(treasuryInstance),
                address(timelockInstance),
                address(0) // Zero guardian address
            )
        );

        vm.expectRevert("ZERO_ADDRESS_DETECTED");
        ERC1967Proxy proxy5 = new ERC1967Proxy(address(LendefiInstance), initData);
        Lendefi(payable(address(proxy5)));
    }

    function test_InitializeCannotBeCalledTwice() public {
        LendefiInstance = new Lendefi();
        // Initialize with zero USDC address
        bytes memory initData = abi.encodeCall(
            Lendefi.initialize,
            (
                address(usdcInstance), // Zero USDC address
                address(tokenInstance),
                address(ecoInstance),
                address(treasuryInstance),
                address(timelockInstance),
                guardian
            )
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(LendefiInstance), initData);
        LendefiInstance = Lendefi(payable(address(proxy)));

        bytes memory expError = abi.encodeWithSignature("InvalidInitialization()");
        vm.expectRevert(expError);
        LendefiInstance.initialize(
            address(usdcInstance),
            address(tokenInstance),
            address(ecoInstance),
            address(treasuryInstance),
            address(timelockInstance),
            guardian
        );
    }

    function test_InitialStateIsEmpty() public {
        // Deploy new logic contract
        LendefiInstance = new Lendefi();

        // Check initial state before initialization
        assertEq(LendefiInstance.version(), 0, "Version should be 0 before initialization");
        assertEq(LendefiInstance.totalBorrow(), 0, "totalBorrow should be 0 before initialization");
        assertEq(
            LendefiInstance.totalSuppliedLiquidity(), 0, "totalSuppliedLiquidity should be 0 before initialization"
        );
        assertEq(
            LendefiInstance.totalAccruedBorrowerInterest(), 0, "totalAccruedInterest should be 0 before initialization"
        );
    }

    // Test for correct role selectors// Test for correct role assignments instead of constants
    function test_RoleAssignments() public {
        // Calculate the expected role hashes directly
        bytes32 pauserRole = keccak256("PAUSER_ROLE");
        bytes32 managerRole = keccak256("MANAGER_ROLE");
        bytes32 upgraderRole = keccak256("UPGRADER_ROLE");
        bytes32 defaultAdminRole = 0x00;

        // Deploy with initialization
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

        // Check that roles are properly assigned to the right addresses
        assertTrue(LendefiInstance.hasRole(defaultAdminRole, guardian), "Guardian should have admin role");
        assertTrue(LendefiInstance.hasRole(pauserRole, guardian), "Guardian should have pauser role");
        assertTrue(LendefiInstance.hasRole(managerRole, address(timelockInstance)), "Timelock should have manager role");
        assertTrue(
            LendefiInstance.hasRole(upgraderRole, address(timelockInstance)), "Timelock should have upgrader role"
        );

        // Verify negative cases - addresses that shouldn't have roles
        assertFalse(LendefiInstance.hasRole(managerRole, guardian), "Guardian should not have manager role");
        assertFalse(LendefiInstance.hasRole(upgraderRole, guardian), "Guardian should not have upgrader role");
        assertFalse(
            LendefiInstance.hasRole(defaultAdminRole, address(timelockInstance)), "Timelock should not have admin role"
        );
        assertFalse(
            LendefiInstance.hasRole(pauserRole, address(timelockInstance)), "Timelock should not have pauser role"
        );
    }

    // Test for decimal precision in initialized values
    function test_InitializationDecimalPrecision() public {
        // Deploy Lendefi with initialization
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

        // Verify exact decimal precision of initialized values
        assertEq(LendefiInstance.baseBorrowRate(), 60_000, "baseBorrowRate should be 0.06e6 = 60000");
        assertEq(LendefiInstance.baseProfitTarget(), 10_000, "baseProfitTarget should be 0.01e6 = 10000");
        assertEq(
            LendefiInstance.tierBaseBorrowRate(IPROTOCOL.CollateralTier.ISOLATED),
            150_000,
            "ISOLATED rate should be 0.15e6 = 150000"
        );
        assertEq(
            LendefiInstance.tierLiquidationBonus(IPROTOCOL.CollateralTier.STABLE),
            50_000,
            "STABLE bonus should be 0.05e6 = 50000"
        );
    }

    // Test that uninitialized contracts have expected default values
    function test_UninitializedHasCorrectDefaults() public {
        Lendefi uninitializedContract = new Lendefi();

        assertEq(uninitializedContract.treasury(), address(0), "Treasury should be zero address before init");

        // Check that mappings return default values
        assertEq(
            uninitializedContract.tierBaseBorrowRate(IPROTOCOL.CollateralTier.ISOLATED),
            0,
            "Mapping should return 0 before initialization"
        );
    }

    // Test that initialization properly sets up protocol parameters for each tier
    function test_InitializationSetsAllTierParameters() public {
        // Deploy with initialization
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

        // Test all tier parameters individually to provide better error messages
        IPROTOCOL.CollateralTier[] memory tiers = new IPROTOCOL.CollateralTier[](4);
        tiers[0] = IPROTOCOL.CollateralTier.ISOLATED;
        tiers[1] = IPROTOCOL.CollateralTier.CROSS_A;
        tiers[2] = IPROTOCOL.CollateralTier.CROSS_B;
        tiers[3] = IPROTOCOL.CollateralTier.STABLE;

        uint256[] memory expectedBorrowRates = new uint256[](4);
        expectedBorrowRates[0] = 0.15e6;
        expectedBorrowRates[1] = 0.08e6;
        expectedBorrowRates[2] = 0.12e6;
        expectedBorrowRates[3] = 0.05e6;

        uint256[] memory expectedLiquidationBonuses = new uint256[](4);
        expectedLiquidationBonuses[0] = 0.15e6;
        expectedLiquidationBonuses[1] = 0.08e6;
        expectedLiquidationBonuses[2] = 0.1e6;
        expectedLiquidationBonuses[3] = 0.05e6;

        for (uint256 i = 0; i < tiers.length; i++) {
            assertEq(
                LendefiInstance.tierBaseBorrowRate(tiers[i]),
                expectedBorrowRates[i],
                string.concat("Incorrect borrow rate for tier ", Strings.toString(uint256(tiers[i])))
            );

            assertEq(
                LendefiInstance.tierLiquidationBonus(tiers[i]),
                expectedLiquidationBonuses[i],
                string.concat("Incorrect liquidation bonus for tier ", Strings.toString(uint256(tiers[i])))
            );
        }
    }
}
