// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title MockUSDC
 * @author Sivaji
 * @notice A fake USDC token used ONLY in local tests and Sepolia testnet.
 *        
 *
 * @dev Why do we need this?
 *      Real USDC on mainnet has a centralized minter — only Circle can mint it.
 *      For tests we need to freely mint tokens to test accounts so we can
 *      simulate lending scenarios without begging a faucet.
 *
 *      Key difference from real USDC:
 *      - Real USDC has 6 decimals (1 USDC = 1_000_000 units)
 *      - We keep 6 decimals here to match real behaviour exactly
 *      - This matters because our math must handle both 18-decimal collateral
 *        and 6-decimal stablecoins correctly
 */
contract MockUSDC is ERC20 {

    address private owner;


    //ERRORS

    error MockUSDC__NotOwner(address caller);
    
    // CONSTRUCTOR
   /**
     * @notice Deploys the mock USDC token
     * @dev The deployer becomes the owner and is the only one who can mint.
     *      We pass "USD Coin" and "USDC" to the ERC20 parent constructor
     *      which stores the name and symbol on-chain.
     */
    constructor() ERC20("USD Coin", "USDC") {
        owner = msg.sender;
    }

    // EXTERNAL FUNCTIONS
    
    /**
     * @notice Transfers ownership to a new address
     * @param newOwner The address of the new owner
     * @dev Only the current owner can call this
     */
    function setOwner(address newOwner) external {
        if (msg.sender != owner) {
            revert MockUSDC__NotOwner(msg.sender);
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
     * @notice Mints USDC to any address — used in tests to fund accounts
     * @param to      The address receiving the minted tokens
     * @param amount  Amount in USDC units (remember: 6 decimals, so 1 USDC = 1e6)
     *
     * @dev In a real protocol this function would not exist.
     *      Only the owner (test contract) can call this to prevent abuse.
     */
    function mint(address to, uint256 amount) external {
        if (msg.sender != owner) {
            revert MockUSDC__NotOwner(msg.sender);
        }
        _mint(to, amount);
    }

    // OVERRIDES
    // ──────────────────────────────────────────────────────────────

    /**
     * @notice Returns 6 decimals — matching real USDC exactly
     * @dev ERC20's default decimals() returns 18.
     *      We override it to return 6 because real USDC uses 6.
     *      This is critical — if we forgot this override, our protocol math
     *      would calculate values 1_000_000_000_000 times too large.
     */
    function decimals() public pure override returns (uint8) {
        return 6;
    }
}