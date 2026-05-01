// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20}      from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LendingPool} from "../src/LendingPool.sol";

/**
 * @title Interact
 * @notice Script to interact with the deployed protocol on Sepolia.
 *
 * Usage:
 *   forge script script/Interact.s.sol \
 *     --rpc-url $SEPOLIA_RPC_URL \
 *     --private-key $PRIVATE_KEY \
 *     --broadcast \
 *     -vvvv
 *
 * Set LENDING_POOL_ADDRESS and WETH_ADDRESS before running.
 */
contract Interact is Script {
    // ── Fill these after deployment ────────────────────────────────
    address constant LENDING_POOL = 0x0000000000000000000000000000000000000000;
    address constant WETH_ADDRESS = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer    = vm.addr(deployerKey);

        LendingPool pool = LendingPool(LENDING_POOL);
        IERC20    weth = IERC20(WETH_ADDRESS);

        vm.startBroadcast(deployerKey);

        // Check current position before doing anything
        (
            uint256 colUsd,
            uint256 debt,
            uint256 hf,
            bool    liq
        ) = pool.getUserPosition(deployer);

        console2.log("=== Current Position ===");
        console2.log("Collateral USD:", colUsd / 1e18);
        console2.log("Debt USDC:     ", debt   / 1e6);
        console2.log("Health factor: ", hf);
        console2.log("Liquidatable:  ", liq);

        vm.stopBroadcast();
    }
}