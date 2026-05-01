// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {ERC1967Proxy} from
    "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PriceOracle} from "../../src/libraries/PriceOracle.sol";
import {MockWETH} from "../../src/mocks/MockWETH.sol";
import {MockV3Aggregator} from "../../src/mocks/MockV3Aggregator.sol";

/**
 * @title PriceOracleV2
 * @notice Simulates a protocol upgrade — adds a version() function.
 *         In a real upgrade this might fix a bug or add new logic.
 * @dev Inherits all V1 state and logic — only extends it.
 */
contract PriceOracleV2 is PriceOracle {
    /**
     * @notice Returns the implementation version.
     *         Does not exist in V1 — only available after upgrade.
     */
    function version() external pure returns (string memory) {
        return "2.0.0";
    }

    /**
     * @notice Example new feature: returns price scaled to any precision.
     * @param token     Collateral token
     * @param amount    Token amount
     * @param precision Target precision (e.g. 1e6 for USDC-like output)
     */
    function getUsdValueScaled(
        address token,
        uint256 amount,
        uint256 precision
    ) external view returns (uint256) {
        uint256 fullValue = this.getUsdValue(token, amount);
        return (fullValue * precision) / 1e18;
    }
}

/**
 * @title UpgradeTest
 * @notice Tests the complete UUPS upgrade lifecycle.
 *
 * What we prove:
 *   1. V1 deploys and works correctly
 *   2. Proxy address never changes during upgrade
 *   3. All V1 state persists after upgrade (storage is in proxy)
 *   4. V2 features become available after upgrade
 *   5. V1 implementation cannot be initialised directly
 *   6. Non-owners cannot trigger upgrades
 */
contract UpgradeTest is Test {
    // ─── Contracts ────────────────────────────────────────────────

    PriceOracle   oracleV1;
    PriceOracleV2 oracleV2;

    MockWETH         weth;
    MockV3Aggregator ethFeed;

    // ─── Actors ───────────────────────────────────────────────────

    address ADMIN    = makeAddr("admin");
    address ATTACKER = makeAddr("attacker");

    // ─── Setup — deploy V1 ────────────────────────────────────────

    function setUp() public {
        weth    = new MockWETH();
        ethFeed = new MockV3Aggregator(8, 2000e8);

        // Deploy V1 behind proxy
        PriceOracle impl = new PriceOracle();

        address[] memory tokens = new address[](1);
        address[] memory feeds  = new address[](1);
        tokens[0] = address(weth);
        feeds[0]  = address(ethFeed);

        bytes memory initData = abi.encodeWithSelector(
            PriceOracle.initialize.selector,
            tokens, feeds, ADMIN
        );

        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);

        // Cast proxy to V1 type
        oracleV1 = PriceOracle(address(proxy));
    }

    // ─── V1 baseline tests ────────────────────────────────────────

    function test_V1_WorksCorrectly() public view {
        uint256 value = oracleV1.getUsdValue(address(weth), 1e18);
        assertEq(value, 2000e18);
        console2.log("V1 price for 1 WETH:", value / 1e18, "USD");
    }

    function test_V1_OwnerIsAdmin() public view {
        assertEq(oracleV1.owner(), ADMIN);
    }

    function test_V1_WETHRegistered() public view {
        assertTrue(oracleV1.isAllowedCollateral(address(weth)));
    }

    // ─── Upgrade tests ────────────────────────────────────────────

    function test_Upgrade_ProxyAddressDoesNotChange() public {
        // Record proxy address before upgrade
        address proxyAddressBefore = address(oracleV1);

        // Deploy V2 implementation
        PriceOracleV2 implV2 = new PriceOracleV2();

        // Upgrade proxy to point at V2
        vm.prank(ADMIN);
        oracleV1.upgradeToAndCall(address(implV2), "");

        // Proxy address is unchanged — users never update their address
        address proxyAddressAfter = address(oracleV1);
        assertEq(proxyAddressBefore, proxyAddressAfter);
        console2.log("Proxy address stable:", proxyAddressBefore);
    }

    function test_Upgrade_StatePersistedAfterUpgrade() public {
        // Record state before upgrade
        uint256 valueBefore = oracleV1.getUsdValue(address(weth), 1e18);
        address ownerBefore = oracleV1.owner();
        bool allowedBefore  = oracleV1.isAllowedCollateral(address(weth));

        // Upgrade to V2
        PriceOracleV2 implV2 = new PriceOracleV2();
        vm.prank(ADMIN);
        oracleV1.upgradeToAndCall(address(implV2), "");

        // Cast proxy to V2 type — same address, new implementation
        oracleV2 = PriceOracleV2(address(oracleV1));

        // State must be identical
        uint256 valueAfter = oracleV2.getUsdValue(address(weth), 1e18);
        address ownerAfter = oracleV2.owner();
        bool allowedAfter  = oracleV2.isAllowedCollateral(address(weth));

        assertEq(valueBefore, valueAfter);
        assertEq(ownerBefore, ownerAfter);
        assertEq(allowedBefore, allowedAfter);

        console2.log("Price preserved:", valueAfter / 1e18, "USD");
        console2.log("Owner preserved:", ownerAfter);
    }

    function test_Upgrade_V2FeaturesAvailable() public {
        // Before upgrade — version() does not exist on V1
        // Calling it would revert

        // Upgrade to V2
        PriceOracleV2 implV2 = new PriceOracleV2();
        vm.prank(ADMIN);
        oracleV1.upgradeToAndCall(address(implV2), "");

        oracleV2 = PriceOracleV2(address(oracleV1));

        // V2 functions now available
        string memory ver = oracleV2.version();
        assertEq(ver, "2.0.0");
        console2.log("V2 version:", ver);

        // New scaled value function
        uint256 scaled = oracleV2.getUsdValueScaled(address(weth), 1e18, 1e6);
        assertEq(scaled, 2000e6); // $2000 in 6-decimal precision
        console2.log("Scaled value (6 dec):", scaled);
    }

    function test_Upgrade_V1FunctionStillWorks() public {
        // After upgrade, V1 functions must keep working
        PriceOracleV2 implV2 = new PriceOracleV2();
        vm.prank(ADMIN);
        oracleV1.upgradeToAndCall(address(implV2), "");

        oracleV2 = PriceOracleV2(address(oracleV1));

        // getUsdValue still works on V2
        uint256 value = oracleV2.getUsdValue(address(weth), 2e18);
        assertEq(value, 4000e18);
    }

    function test_Upgrade_WorksAfterPriceChange() public {
        // Update price before upgrade
        ethFeed.updateAnswer(3000e8); // ETH moves to $3000

        // Upgrade
        PriceOracleV2 implV2 = new PriceOracleV2();
        vm.prank(ADMIN);
        oracleV1.upgradeToAndCall(address(implV2), "");

        oracleV2 = PriceOracleV2(address(oracleV1));

        // Price reads correctly from feed after upgrade
        uint256 value = oracleV2.getUsdValue(address(weth), 1e18);
        assertEq(value, 3000e18);
    }

    // ─── Access control tests ─────────────────────────────────────

    function test_Upgrade_Revert_NonOwnerCannotUpgrade() public {
        PriceOracleV2 implV2 = new PriceOracleV2();

        // Attacker tries to upgrade — must revert
        vm.prank(ATTACKER);
        vm.expectRevert();
        oracleV1.upgradeToAndCall(address(implV2), "");

        // V1 still in place — version() does not exist
        // (if it did, the upgrade succeeded — which would be the bug)
        vm.expectRevert();
        PriceOracleV2(address(oracleV1)).version();
    }

    function test_Upgrade_Revert_CannotInitialiseImplementationDirectly() public {
        // Deploy bare implementation — no proxy
        PriceOracle bareImpl = new PriceOracle();

        address[] memory tokens = new address[](1);
        address[] memory feeds  = new address[](1);
        tokens[0] = address(weth);
        feeds[0]  = address(ethFeed);

        // _disableInitializers() in constructor prevents this
        vm.expectRevert();
        bareImpl.initialize(tokens, feeds, ADMIN);
    }

    function test_Upgrade_Revert_CannotCallInitializeAgain() public {
        // initialize() on already-initialised proxy must revert
        address[] memory tokens = new address[](1);
        address[] memory feeds  = new address[](1);
        tokens[0] = address(weth);
        feeds[0]  = address(ethFeed);

        vm.prank(ADMIN);
        vm.expectRevert();
        oracleV1.initialize(tokens, feeds, ADMIN);
    }

    // ─── Implementation slot test ─────────────────────────────────

    function test_ImplementationSlot_ChangesAfterUpgrade() public {
        // ERC1967 stores implementation address at a specific storage slot
        // keccak256("eip1967.proxy.implementation") - 1
        bytes32 IMPL_SLOT = bytes32(
            uint256(keccak256("eip1967.proxy.implementation")) - 1
        );

        // Read implementation address from proxy storage before upgrade
        bytes32 implBefore = vm.load(address(oracleV1), IMPL_SLOT);

        // Upgrade
        PriceOracleV2 implV2 = new PriceOracleV2();
        vm.prank(ADMIN);
        oracleV1.upgradeToAndCall(address(implV2), "");

        // Read after upgrade — must have changed
        bytes32 implAfter = vm.load(address(oracleV1), IMPL_SLOT);

        assertTrue(implBefore != implAfter);

        // New slot value must match implV2 address
        assertEq(
            address(uint160(uint256(implAfter))),
            address(implV2)
        );

        console2.log("Impl before:", address(uint160(uint256(implBefore))));
        console2.log("Impl after: ", address(uint160(uint256(implAfter))));
    }
}