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
        deployCompleteWithOracle();

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
                guardian,
                address(oracleInstance)
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
        (uint256[4] memory jumpRates, uint256[4] memory LiquidationFees) = LendefiInstance.getTierRates();

        // Check borrow rates
        assertEq(jumpRates[0], 0.15e6, "Incorrect ISOLATED borrow rate");
        assertEq(jumpRates[1], 0.12e6, "Incorrect CROSS_B borrow rate");
        assertEq(jumpRates[2], 0.08e6, "Incorrect CROSS_A borrow rate");
        assertEq(jumpRates[3], 0.05e6, "Incorrect STABLE borrow rate");

        // Check liquidation bonuses
        assertEq(LiquidationFees[0], 0.04e6, "Incorrect ISOLATED liquidation bonus");
        assertEq(LiquidationFees[1], 0.03e6, "Incorrect CROSS_A liquidation bonus");
        assertEq(LiquidationFees[2], 0.02e6, "Incorrect CROSS_B liquidation bonus");
        assertEq(LiquidationFees[3], 0.01e6, "Incorrect STABLE liquidation bonus");

        // Check version increment
        assertEq(LendefiInstance.version(), 1, "Version not incremented");

        // Check treasury and timelock addresses
        assertEq(LendefiInstance.treasury(), address(treasuryInstance), "Treasury address not set correctly");
    }

    function test_InitializeRevertsOnZeroAddress() public {
        // Deploy a fresh Lendefi implementation for testing
        Lendefi lendefiImpl = new Lendefi();

        // Create array of parameter names for better error messages
        string[] memory paramNames = new string[](7);
        paramNames[0] = "USDC";
        paramNames[1] = "Token";
        paramNames[2] = "Ecosystem";
        paramNames[3] = "Treasury";
        paramNames[4] = "Timelock";
        paramNames[5] = "Guardian";
        paramNames[6] = "Oracle";

        // Reference array with valid addresses
        address[] memory validAddresses = new address[](7);
        validAddresses[0] = address(usdcInstance);
        validAddresses[1] = address(tokenInstance);
        validAddresses[2] = address(ecoInstance);
        validAddresses[3] = address(treasuryInstance);
        validAddresses[4] = address(timelockInstance);
        validAddresses[5] = guardian;
        validAddresses[6] = address(oracleInstance);

        // Test each parameter with a zero address
        for (uint256 i = 0; i < validAddresses.length; i++) {
            // Create a copy of valid addresses
            address[] memory testAddresses = new address[](7);
            for (uint256 j = 0; j < validAddresses.length; j++) {
                testAddresses[j] = validAddresses[j];
            }

            // Replace one address with zero address
            testAddresses[i] = address(0);

            // Encode initialization call with the current test addresses
            bytes memory initData = abi.encodeCall(
                Lendefi.initialize,
                (
                    testAddresses[0], // usdc
                    testAddresses[1], // govToken
                    testAddresses[2], // ecosystem
                    testAddresses[3], // treasury
                    testAddresses[4], // timelock
                    testAddresses[5], // guardian
                    testAddresses[6] // oracle
                )
            );

            // Expect revert for zero address
            vm.expectRevert(bytes("ZERO_ADDRESS_DETECTED"));
            new ERC1967Proxy(address(lendefiImpl), initData);

            // Log which parameter was tested
            console2.log("Tested zero address for", paramNames[i]);
        }
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
                guardian,
                address(oracleInstance)
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
                guardian,
                address(oracleInstance)
            )
        );

        address payable proxy = payable(Upgrades.deployUUPSProxy("Lendefi.sol", data));
        LendefiInstance = Lendefi(proxy);

        // Verify exact decimal precision of initialized values
        assertEq(LendefiInstance.baseBorrowRate(), 60_000, "baseBorrowRate should be 0.06e6 = 60000");
        assertEq(LendefiInstance.baseProfitTarget(), 10_000, "baseProfitTarget should be 0.01e6 = 10000");
        (uint256[4] memory jumpRates, uint256[4] memory liquidationFees) = LendefiInstance.getTierRates();
        assertEq(jumpRates[0], 0.15e6, "ISOLATED rate should be 0.15e6");
        assertEq(liquidationFees[0], 0.04e6, "ISOLATED rate should be 0.04e6");
        assertEq(
            LendefiInstance.getTierLiquidationFee(IPROTOCOL.CollateralTier.STABLE),
            0.01e6,
            "STABLE bonus should be 0.05e6 = 50000"
        );
    }

    // Test that uninitialized contracts have expected default values
    function test_UninitializedHasCorrectDefaults() public {
        Lendefi uninitializedContract = new Lendefi();

        assertEq(uninitializedContract.treasury(), address(0), "Treasury should be zero address before init");
    }

    // Test that initialization properly sets up protocol parameters for each tier
    function test_InitializationSetsAllTierParameters() public {
        // Deploy with initialization

        // Test all tier parameters individually to provide better error messages
        IPROTOCOL.CollateralTier[] memory tiers = new IPROTOCOL.CollateralTier[](4);
        tiers[0] = IPROTOCOL.CollateralTier.ISOLATED;
        tiers[1] = IPROTOCOL.CollateralTier.CROSS_A;
        tiers[2] = IPROTOCOL.CollateralTier.CROSS_B;
        tiers[3] = IPROTOCOL.CollateralTier.STABLE;

        uint256[] memory expectedJumpRates = new uint256[](4);
        expectedJumpRates[0] = 0.15e6;
        expectedJumpRates[1] = 0.12e6;
        expectedJumpRates[2] = 0.08e6;
        expectedJumpRates[3] = 0.05e6;

        uint256[] memory expectedLiquidationFees = new uint256[](4);
        expectedLiquidationFees[0] = 0.04e6;
        expectedLiquidationFees[1] = 0.03e6;
        expectedLiquidationFees[2] = 0.02e6;
        expectedLiquidationFees[3] = 0.01e6;

        // Check tier parameters
        (uint256[4] memory jumpRates, uint256[4] memory liquidationFees) = LendefiInstance.getTierRates();

        for (uint256 i = 0; i < tiers.length; i++) {
            assertEq(
                jumpRates[i],
                expectedJumpRates[i],
                string.concat("Incorrect borrow rate for tier ", Strings.toString(uint256(tiers[i])))
            );

            assertEq(
                liquidationFees[i],
                expectedLiquidationFees[i],
                string.concat("Incorrect liquidation bonus for tier ", Strings.toString(uint256(tiers[i])))
            );
        }
    }
}
