// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";


/**
 * @title MockWBTC
 * @author Sivaji
 * @notice A fake Wrapped Bitcoin token used ONLY in local tests and Sepolia.
 *
 * @dev Why WBTC as collateral?
 *      Native ETH cannot be held in an ERC20 vault directly — you need WETH.
 *      But WBTC is already an ERC20, so it is simpler to demonstrate
 *      multi-collateral lending. In Step 4 we will accept both WETH and WBTC.
 *
 *      Key fact: Real WBTC has 8 decimals (matching Bitcoin).
 *      1 BTC = 1_00_000_000 satoshis = 1e8 WBTC units.
 *      We replicate this so our price feed math handles 8-decimal tokens correctly.
 *      This is a common interview question: "how do you handle tokens with
 *      different decimal counts?" — our PriceOracle (Step 3) handles this.
 */
contract MockWBTC is ERC20 {
    address private immutable I_OWNER;
    
    //CONSTRUCTOR

    constructor() ERC20("Wrapped Bitcoin", "WBTC") {
        I_OWNER = msg.sender;
    }

    /**
     * @notice Mints WBTC to any address — used in tests to fund accounts
     * @param to      The address receiving the minted tokens
     * @param amount  Amount in WBTC units (remember: 8 decimals, so 1 WBTC = 1e8)
     */
    function mint(address to, uint256 amount) external {
        require(msg.sender == I_OWNER, "Only owner can mint");
        _mint(to, amount);
        
    }

      /**
     * @notice Returns 8 decimals — matching real WBTC exactly
     * @dev Bitcoin uses 8 decimal places (satoshis).
     *      WBTC mirrors this. Without this override, 1 WBTC would be
     *      treated as 1e18 units instead of 1e8 — a 10 billion times error.
     */
    function decimals() public pure override returns (uint8) {
        return 8;
    }


}
