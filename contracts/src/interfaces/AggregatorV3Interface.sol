// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @title AggregatorV3Interface
 * @notice The interface that all Chainlink V3 price feeds implement.
 *
 * @dev Why define our own interface instead of importing from Chainlink?
 *      1. Smaller dependency surface — we only need one function
 *      2. Our MockV3Aggregator implements this same interface
 *      3. In production: pass the real Chainlink address
 *         In tests: pass the MockV3Aggregator address
 *      Both work because they share the same interface.
 *
 *      This is the "dependency inversion principle" in practice:
 *      your contract depends on an interface, not a concrete implementation.
 *      Swap the address, change the behaviour — zero code change needed.
 *
 *      Real Chainlink feed addresses on Sepolia:
 *      ETH/USD: 0x694AA1769357215DE4FAC081bf1f309aDC325306
 *      BTC/USD: 0x1b44F3514812d835EB1BDB0acB33d3fA3351Ee43
 */
interface AggregatorV3Interface {
    /**
     * @notice Returns the latest price round data
     * @return roundId          ID of the current round — increments with each update
     * @return answer           The price — for ETH/USD: price in USD with 8 decimals
     * @return startedAt        Unix timestamp when this round started
     * @return updatedAt        Unix timestamp of the last price update
     *                          IMPORTANT: check this against block.timestamp
     *                          to detect stale prices
     * @return answeredInRound  Should match roundId — mismatch means stale data
     */
    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );

    /**
     * @notice Returns how many decimal places the price has
     * @dev Always 8 for USD pairs on Chainlink.
     *      ETH at $2000 → answer = 200000000000 (2000 * 10^8)
     */
    function decimals() external view returns (uint8);
}
