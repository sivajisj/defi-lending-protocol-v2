// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @title MockV3Aggregator
 * @author Sivaji
 * @notice A fake Chainlink price feed used ONLY in local tests and Sepolia.
 *
 * @dev This is a simplified version of the real Chainlink AggregatorV3Interface.
 *      It allows us to set a fixed price for testing our PriceOracle and lending logic.
 *      In production, you would use the real Chainlink price feeds.
 */
contract MockV3Aggregator {
    uint8 public immutable DECIMALS;

    /// @dev The current price — stored as int256 (Chainlink uses signed int)
    ///      Negative prices are theoretically possible for inverse feeds
    int256 public latestAnswer;

    /// @dev Tracks how many times the price has been updated
    ///      Each update increments this — used to detect stale data
    uint80 private sRoundId;

    /// @dev Timestamp of the last price update
    ///      Our PriceOracle checks: if block.timestamp - updatedAt > TIMEOUT → revert
    uint256 private sUpdatedAt;

     /**
     * @notice Deploys the mock feed with an initial price
     * @param _decimals     Should be 8 to match real Chainlink USD feeds
     * @param _initialAnswer The starting price (e.g. 2000e8 for $2000 ETH)
     *
     * @dev Example deployment in tests:
     *      MockV3Aggregator ethFeed = new MockV3Aggregator(8, 2000e8);
     *      // This means ETH = $2000.00000000
     */
    constructor(uint8 _decimals, int256 _initialAnswer) {
        DECIMALS = _decimals;
        updateAnswer(_initialAnswer);
    }

    /**
     * @notice Updates the price — used in tests to simulate price changes
     * @param _answer The new price (e.g. 2500e8 for $2500 ETH)
     *
     * @dev Each call increments roundId and updates the timestamp.
     *      This allows us to test stale price logic in our PriceOracle.
     */
    function updateAnswer(int256 _answer)  public {
        latestAnswer = _answer;
        sRoundId++;
        sUpdatedAt = block.timestamp;
        
    }

/**
     * @notice Returns price data in the exact same format as real Chainlink feeds
     * @return roundId          Increments each price update — used to detect stale data
     * @return answer           The price in 8-decimal USD (e.g. 2000e8 = $2000)
     * @return startedAt        When this round started — we simplify to updatedAt
     * @return updatedAt        Timestamp of last update — THIS is what we check for staleness
     * @return answeredInRound  Should equal roundId — if not, data is stale
     *
     * @dev This is the EXACT function signature your PriceOracle will call.
     *      The real Chainlink contract on Sepolia has the same signature.
     *      By using an interface, we can swap mock → real just by changing the address.
     *
     *      The staleness check in PriceOracle (Step 3) will look like:
     *      if (block.timestamp - updatedAt > FEED_TIMEOUT) revert StalePrice();
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
        )    {
        return (sRoundId, latestAnswer, sUpdatedAt, sUpdatedAt, sRoundId);
    }

     /**
     * @notice Returns the number of decimals in the price
     * @dev Real Chainlink USD feeds always return 8 here.
     *      Our PriceOracle uses this to normalise prices to 18 decimals
     *      so all our internal math works with a single precision standard.
     */
    function getDecimals() external view returns (uint8) {
        return DECIMALS;
    }
}