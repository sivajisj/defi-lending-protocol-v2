// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title MockWETH
 * @author Sivaji
 * @notice A fake Wrapped Ether token used ONLY in local tests and Sepolia.
 *
 * @dev Why WETH and not native ETH?
 *      Smart contracts cannot hold native ETH in an ERC20 vault directly.
 *      WETH is an ERC20 that is 1:1 pegged to ETH — this is the standard
 *      pattern used by Aave, Compound, and MakerDAO for ETH collateral.
 *      WETH uses 18 decimals — same as native ETH. No override needed.
 */
contract MockWETH is ERC20 {
    address private owner;

    error MockWETH__NotOwner(address caller);

    constructor() ERC20("Wrapped Ether", "WETH") {
        owner = msg.sender;
    }

    /**
     * @notice Transfers ownership to a new address
     * @param newOwner The address of the new owner
     * @dev Only the current owner can call this
     */
    function setOwner(address newOwner) external {
        if (msg.sender != owner) {
            revert MockWETH__NotOwner(msg.sender);
        }
        owner = newOwner;
    }

    /**
     * @notice Returns the current owner address
     */
    function getOwner() external view returns (address) {
        return owner;
    }

    /**
     * @notice Mints WETH to any address for testing
     * @param to      Amount of WETH recipient address
     * @param amount  Amount in wei (18 decimals — 1 WETH = 1e18)
     */
    function mint(address to, uint256 amount) external {
        if (msg.sender != owner) {
            revert MockWETH__NotOwner(msg.sender);
        }
        _mint(to, amount);
    }
}