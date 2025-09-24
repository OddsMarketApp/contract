// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/**
 * @title ITargetMarket
 * @dev Interface for target market contracts
 */
interface ITargetMarket {
    function proposeResultFromExternalOracle(uint256 marketId, uint256 outcome) external;
    function finalizeResult(uint256 marketId) external;
}

/**
 * @title FinancialNBASettlement
 * @dev Independent settlement contract for Financial Markets and NBA Games
 * @notice Handles binary market settlement for:
 *         - Financial markets: Price feeds (BTC/USD, ETH/USD, SPY, etc.)
 *         - NBA games: Game results (Team A vs Team B)
 * @dev All comments and code must be in English
 */
contract FinancialNBASettlement is ReentrancyGuard, Pausable, Ownable {

    // =============================================================================
    // STRUCTS AND ENUMS
    // =============================================================================

    enum MarketType {
        FINANCIAL_PRICE,    // Price above/below threshold
        NBA_GAME           // Team A wins / Team B wins
    }

    enum SettlementStatus {
        PENDING,           // Awaiting settlement
        SETTLED,          // Successfully settled
        FAILED,           // Settlement failed
        MANUAL_REQUIRED   // Requires manual intervention
    }

    struct FinancialMarketConfig {
        uint256 configId;
        uint256 marketId;
        address targetMarket;
        uint256 targetMarketId;
        address priceFeeds;         // Chainlink price feed address
        uint256 thresholdPrice;     // Price threshold (normalized to INTERNAL_DECIMALS)
        uint256 settlementTime;     // Settlement timestamp
        bool isPriceAbove;          // true: price above wins, false: price below wins
        MarketType marketType;
        SettlementStatus status;
        uint256 settledPrice;       // Final settled price (normalized to INTERNAL_DECIMALS)
        uint256 settledAt;         // Settlement timestamp
        uint8 feedDecimals;         // CRITICAL FIX: Store feed decimals for proper scaling
    }

    struct NBAGameConfig {
        uint256 configId;
        uint256 gameId;            // External game ID
        address targetMarket;
        uint256 targetMarketId;
        string homeTeam;           // Home team name
        string awayTeam;           // Away team name
        uint256 gameTime;          // Game start time
        uint256 settlementTime;    // Settlement deadline
        bool isHomeTeamOption0;    // true: home team is option 0, false: away team is option 0
        MarketType marketType;
        SettlementStatus status;
        uint256 homeScore;         // Final home team score
        uint256 awayScore;         // Final away team score
        uint256 settledAt;         // Settlement timestamp
    }

    // =============================================================================
    // STATE VARIABLES
    // =============================================================================

    // Configuration storage
    mapping(uint256 => FinancialMarketConfig) public financialConfigs;
    mapping(uint256 => NBAGameConfig) public nbaConfigs;

    // Config ID counters
    uint256 public nextFinancialConfigId = 1;
    uint256 public nextNBAConfigId = 1;

    // Market lookup mappings
    mapping(address => mapping(uint256 => uint256)) public marketToFinancialConfig;
    mapping(address => mapping(uint256 => uint256)) public marketToNBAConfig;

    // Authorized oracles for manual intervention
    mapping(address => bool) public authorizedOracles;

    // Minimum time delay between proposal and confirmation (24 hours)
    uint256 public constant RESOLUTION_DELAY = 24 hours;

    // Price feed validation settings
    uint256 public constant MAX_PRICE_AGE = 3600; // 1 hour

    // CRITICAL FIX: Internal decimals for price normalization
    uint8 public constant INTERNAL_DECIMALS = 8;
    uint256 public constant INTERNAL_SCALE = 10**8;

    // =============================================================================
    // EVENTS
    // =============================================================================

    event FinancialMarketConfigured(
        uint256 indexed configId,
        address indexed targetMarket,
        uint256 indexed targetMarketId,
        address priceFeeds,
        uint256 thresholdPrice,
        uint256 settlementTime
    );

    event NBAGameConfigured(
        uint256 indexed configId,
        uint256 indexed gameId,
        address indexed targetMarket,
        uint256 targetMarketId,
        string homeTeam,
        string awayTeam,
        uint256 gameTime
    );

    event FinancialMarketSettled(
        uint256 indexed configId,
        uint256 indexed outcome,
        uint256 settledPrice,
        uint256 thresholdPrice
    );

    event NBAGameSettled(
        uint256 indexed configId,
        uint256 indexed outcome,
        uint256 homeScore,
        uint256 awayScore
    );

    event ManualSettlementRequired(
        uint256 indexed configId,
        MarketType marketType,
        string reason
    );

    event OracleAuthorized(address indexed oracle, bool authorized);

    // =============================================================================
    // MODIFIERS
    // =============================================================================

    modifier onlyAuthorizedOracle() {
        require(authorizedOracles[msg.sender] || msg.sender == owner(), "Not authorized oracle");
        _;
    }

    modifier validFinancialConfig(uint256 configId) {
        require(configId > 0 && configId < nextFinancialConfigId, "Invalid financial config ID");
        _;
    }

    modifier validNBAConfig(uint256 configId) {
        require(configId > 0 && configId < nextNBAConfigId, "Invalid NBA config ID");
        _;
    }

    // =============================================================================
    // CONSTRUCTOR
    // =============================================================================

    constructor() {
        // Owner is automatically authorized oracle
        authorizedOracles[msg.sender] = true;
    }

    // =============================================================================
    // INTERNAL HELPER FUNCTIONS
    // =============================================================================

    /**
     * @dev Scale price value to internal decimals (8 decimals)
     * @param value Price value to scale
     * @param fromDecimals Source decimals
     * @param toDecimals Target decimals
     * @return scaledValue Scaled price value
     */
    function _scaleTo(uint256 value, uint8 fromDecimals, uint8 toDecimals) internal pure returns (uint256 scaledValue) {
        if (fromDecimals == toDecimals) {
            return value;
        }

        if (fromDecimals > toDecimals) {
            // Scale down
            uint8 decimalDiff = fromDecimals - toDecimals;
            return value / (10**decimalDiff);
        } else {
            // Scale up
            uint8 decimalDiff = toDecimals - fromDecimals;
            return value * (10**decimalDiff);
        }
    }

    // =============================================================================
    // FINANCIAL MARKET CONFIGURATION
    // =============================================================================

    /**
     * @dev Configure a financial market for automated price-based settlement
     * @param targetMarket Address of the market contract to settle
     * @param targetMarketId Market ID within the target contract
     * @param priceFeeds Chainlink price feed address
     * @param thresholdPrice Price threshold (scaled by 8 decimals)
     * @param settlementTime Timestamp when settlement should occur
     * @param isPriceAbove true if price above threshold wins, false if below wins
     * @return configId The configuration ID for this market
     */
    function configureFinancialMarket(
        address targetMarket,
        uint256 targetMarketId,
        address priceFeeds,
        uint256 thresholdPrice,
        uint256 settlementTime,
        bool isPriceAbove
    ) external onlyOwner returns (uint256 configId) {
        require(targetMarket != address(0), "Invalid target market");
        require(priceFeeds != address(0), "Invalid price feed");
        require(thresholdPrice > 0, "Invalid threshold price");
        require(settlementTime > block.timestamp, "Settlement time must be in future");

        // Check that this market hasn't been configured already
        require(marketToFinancialConfig[targetMarket][targetMarketId] == 0, "Market already configured");

        // CRITICAL FIX: Read feed decimals and normalize threshold price
        AggregatorV3Interface feed = AggregatorV3Interface(priceFeeds);
        uint8 feedDecimals = feed.decimals();

        // Threshold price should be passed in feed's native decimals, then normalized to INTERNAL_DECIMALS
        uint256 normalizedThreshold = _scaleTo(thresholdPrice, feedDecimals, INTERNAL_DECIMALS);

        configId = nextFinancialConfigId++;

        financialConfigs[configId] = FinancialMarketConfig({
            configId: configId,
            marketId: targetMarketId,
            targetMarket: targetMarket,
            targetMarketId: targetMarketId,
            priceFeeds: priceFeeds,
            thresholdPrice: normalizedThreshold, // Store normalized threshold
            settlementTime: settlementTime,
            isPriceAbove: isPriceAbove,
            marketType: MarketType.FINANCIAL_PRICE,
            status: SettlementStatus.PENDING,
            settledPrice: 0,
            settledAt: 0,
            feedDecimals: feedDecimals // Store feed decimals for runtime scaling
        });

        marketToFinancialConfig[targetMarket][targetMarketId] = configId;

        emit FinancialMarketConfigured(
            configId,
            targetMarket,
            targetMarketId,
            priceFeeds,
            thresholdPrice,
            settlementTime
        );
    }

    // =============================================================================
    // NBA GAME CONFIGURATION
    // =============================================================================

    /**
     * @dev Configure an NBA game for automated settlement
     * @param gameId External game identifier
     * @param targetMarket Address of the market contract to settle
     * @param targetMarketId Market ID within the target contract
     * @param homeTeam Home team name
     * @param awayTeam Away team name
     * @param gameTime Game start timestamp
     * @param settlementTime Settlement deadline timestamp
     * @param isHomeTeamOption0 true if home team is option 0, false if away team is option 0
     * @return configId The configuration ID for this game
     */
    function configureNBAGame(
        uint256 gameId,
        address targetMarket,
        uint256 targetMarketId,
        string calldata homeTeam,
        string calldata awayTeam,
        uint256 gameTime,
        uint256 settlementTime,
        bool isHomeTeamOption0
    ) external onlyOwner returns (uint256 configId) {
        require(targetMarket != address(0), "Invalid target market");
        require(bytes(homeTeam).length > 0, "Invalid home team");
        require(bytes(awayTeam).length > 0, "Invalid away team");
        require(gameTime > block.timestamp, "Game time must be in future");
        require(settlementTime > gameTime, "Settlement time must be after game time");

        // Check that this market hasn't been configured already
        require(marketToNBAConfig[targetMarket][targetMarketId] == 0, "Market already configured");

        configId = nextNBAConfigId++;

        nbaConfigs[configId] = NBAGameConfig({
            configId: configId,
            gameId: gameId,
            targetMarket: targetMarket,
            targetMarketId: targetMarketId,
            homeTeam: homeTeam,
            awayTeam: awayTeam,
            gameTime: gameTime,
            settlementTime: settlementTime,
            isHomeTeamOption0: isHomeTeamOption0,
            marketType: MarketType.NBA_GAME,
            status: SettlementStatus.PENDING,
            homeScore: 0,
            awayScore: 0,
            settledAt: 0
        });

        marketToNBAConfig[targetMarket][targetMarketId] = configId;

        emit NBAGameConfigured(
            configId,
            gameId,
            targetMarket,
            targetMarketId,
            homeTeam,
            awayTeam,
            gameTime
        );
    }

    // =============================================================================
    // AUTOMATED SETTLEMENT FUNCTIONS
    // =============================================================================

    /**
     * @dev Settle a financial market using Chainlink price feed
     * @param configId Financial market configuration ID
     */
    function settleFinancialMarket(uint256 configId)
        external
        nonReentrant
        whenNotPaused
        validFinancialConfig(configId)
    {
        FinancialMarketConfig storage config = financialConfigs[configId];

        require(config.status == SettlementStatus.PENDING, "Market already settled");
        require(block.timestamp >= config.settlementTime, "Settlement time not reached");

        // CRITICAL FIX: Use anti-manipulation price fetching with proper error handling
        try this._getPriceAtOrBefore(config.priceFeeds, config.settlementTime) returns (uint256 currentPrice, uint256 updatedAt) {
            // Validate price freshness
            require(block.timestamp - updatedAt <= MAX_PRICE_AGE, "Price data too old");

            // CRITICAL FIX: Normalize current price to internal decimals for comparison
            uint256 normalizedPrice = _scaleTo(currentPrice, config.feedDecimals, INTERNAL_DECIMALS);

            config.settledPrice = normalizedPrice; // Store normalized price
            config.settledAt = block.timestamp;

            // Determine outcome based on normalized price vs normalized threshold
            uint256 outcome;
            if (config.isPriceAbove) {
                // Option 0 wins if price is above threshold
                outcome = normalizedPrice >= config.thresholdPrice ? 0 : 1;
            } else {
                // Option 0 wins if price is below threshold
                outcome = normalizedPrice <= config.thresholdPrice ? 0 : 1;
            }

            // Propose resolution to target market
            ITargetMarket(config.targetMarket).proposeResultFromExternalOracle(config.targetMarketId, outcome);

            config.status = SettlementStatus.SETTLED;

            emit FinancialMarketSettled(configId, outcome, normalizedPrice, config.thresholdPrice);

        } catch {
            config.status = SettlementStatus.MANUAL_REQUIRED;
            emit ManualSettlementRequired(configId, MarketType.FINANCIAL_PRICE, "Chainlink price feed failed");
        }
    }

    /**
     * @dev Get latest valid price from Chainlink feed (legacy method)
     * @param priceFeed Chainlink price feed address
     * @return price The latest valid price
     * @return updatedAt The timestamp of the price update
     */
    function _getChainlinkPrice(address priceFeed) external view returns (uint256 price, uint256 updatedAt) {
        // This is a simplified version - for production, use _getPriceAtOrBefore with settlement time
        return _getLatestValidPrice(priceFeed);
    }

    /**
     * @dev CRITICAL FIX: Get price at or before settlement time to prevent manipulation
     * @param priceFeed Chainlink price feed address
     * @param settlementTime Target settlement timestamp
     * @return price The price at or before settlement time
     * @return updatedAt The timestamp of the price update used
     */
    function _getPriceAtOrBefore(address priceFeed, uint256 settlementTime) public view returns (uint256 price, uint256 updatedAt) {
        AggregatorV3Interface feed = AggregatorV3Interface(priceFeed);

        // Get latest round
        (uint80 roundId, int256 answer, , uint256 updateTime, uint80 answeredInRound) = feed.latestRoundData();
        require(answer > 0 && updateTime != 0 && answeredInRound >= roundId, "Invalid latest round");

        // If latest round is at or before settlement time, use it
        if (updateTime <= settlementTime) {
            return (uint256(answer), updateTime);
        }

        // Otherwise, search backwards for the round at or before settlement time
        uint256 maxHops = 50; // Prevent infinite loops
        uint256 hops = 0;

        while (updateTime > settlementTime && roundId > 0 && hops < maxHops) {
            hops++;
            roundId -= 1;

            try feed.getRoundData(roundId) returns (
                uint80 id,
                int256 ans,
                uint256 /* startedAt */,
                uint256 updatedAt2,
                uint80 answeredInRound2
            ) {
                if (ans > 0 && updatedAt2 != 0 && answeredInRound2 >= id) {
                    answer = ans;
                    updateTime = updatedAt2;
                } else {
                    // Invalid round, continue searching
                    continue;
                }
            } catch {
                // Failed to get round data, continue searching
                continue;
            }
        }

        // Validate final result
        require(updateTime <= settlementTime + MAX_PRICE_AGE, "No valid round near settlement time");
        require(answer > 0, "No valid price found");

        return (uint256(answer), updateTime);
    }

    /**
     * @dev Get latest valid price for compatibility
     * @param priceFeed Chainlink price feed address
     * @return price The latest price
     * @return updatedAt The timestamp of the latest price update
     */
    function _getLatestValidPrice(address priceFeed) internal view returns (uint256 price, uint256 updatedAt) {
        AggregatorV3Interface feed = AggregatorV3Interface(priceFeed);

        // CRITICAL FIX: Complete round integrity validation
        (uint80 roundId, int256 answer, , uint256 updateTime, uint80 answeredInRound) = feed.latestRoundData();

        require(answer > 0, "Invalid price from Chainlink");
        require(updateTime != 0, "Stale round - no valid timestamp");
        require(answeredInRound >= roundId, "Incomplete round - data not fully answered");

        price = uint256(answer);
        updatedAt = updateTime;
    }

    // =============================================================================
    // MANUAL SETTLEMENT FUNCTIONS
    // =============================================================================

    /**
     * @dev Manual settlement for NBA games (oracle input required)
     * @param configId NBA game configuration ID
     * @param homeScore Final home team score
     * @param awayScore Final away team score
     */
    function settleNBAGameManual(
        uint256 configId,
        uint256 homeScore,
        uint256 awayScore
    )
        external
        nonReentrant
        whenNotPaused
        onlyAuthorizedOracle
        validNBAConfig(configId)
    {
        NBAGameConfig storage config = nbaConfigs[configId];

        require(config.status == SettlementStatus.PENDING, "Game already settled");
        require(block.timestamp >= config.settlementTime, "Settlement time not reached");

        config.homeScore = homeScore;
        config.awayScore = awayScore;
        config.settledAt = block.timestamp;

        // Determine winner
        uint256 outcome;
        if (homeScore > awayScore) {
            // Home team wins
            outcome = config.isHomeTeamOption0 ? 0 : 1;
        } else if (awayScore > homeScore) {
            // Away team wins
            outcome = config.isHomeTeamOption0 ? 1 : 0;
        } else {
            // Tie - requires manual decision or predefined rule
            config.status = SettlementStatus.MANUAL_REQUIRED;
            emit ManualSettlementRequired(configId, MarketType.NBA_GAME, "Game ended in tie");
            return;
        }

        // Propose resolution to target market
        ITargetMarket(config.targetMarket).proposeResultFromExternalOracle(config.targetMarketId, outcome);

        config.status = SettlementStatus.SETTLED;

        emit NBAGameSettled(configId, outcome, homeScore, awayScore);
    }

    /**
     * @dev Manual settlement for financial markets when Chainlink fails
     * @param configId Financial market configuration ID
     * @param manualPrice Manual price input (scaled by 8 decimals)
     */
    function settleFinancialMarketManual(
        uint256 configId,
        uint256 manualPrice
    )
        external
        nonReentrant
        whenNotPaused
        onlyAuthorizedOracle
        validFinancialConfig(configId)
    {
        FinancialMarketConfig storage config = financialConfigs[configId];

        require(config.status == SettlementStatus.MANUAL_REQUIRED || config.status == SettlementStatus.PENDING, "Invalid status for manual settlement");
        require(block.timestamp >= config.settlementTime, "Settlement time not reached");
        require(manualPrice > 0, "Invalid manual price");

        // CRITICAL FIX: Normalize manual price to internal decimals for consistency
        // Manual price should be provided in feed's native decimals
        uint256 normalizedPrice = _scaleTo(manualPrice, config.feedDecimals, INTERNAL_DECIMALS);

        config.settledPrice = normalizedPrice;
        config.settledAt = block.timestamp;

        // Determine outcome based on normalized manual price vs normalized threshold
        uint256 outcome;
        if (config.isPriceAbove) {
            outcome = normalizedPrice >= config.thresholdPrice ? 0 : 1;
        } else {
            outcome = normalizedPrice <= config.thresholdPrice ? 0 : 1;
        }

        // Propose resolution to target market
        ITargetMarket(config.targetMarket).proposeResultFromExternalOracle(config.targetMarketId, outcome);

        config.status = SettlementStatus.SETTLED;

        emit FinancialMarketSettled(configId, outcome, manualPrice, config.thresholdPrice);
    }

    // =============================================================================
    // ADMIN FUNCTIONS
    // =============================================================================

    /**
     * @dev Authorize or deauthorize an oracle
     * @param oracle Oracle address
     * @param authorized true to authorize, false to deauthorize
     */
    function setAuthorizedOracle(address oracle, bool authorized) external onlyOwner {
        require(oracle != address(0), "Invalid oracle address");
        authorizedOracles[oracle] = authorized;
        emit OracleAuthorized(oracle, authorized);
    }

    /**
     * @dev Emergency pause function
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @dev Emergency unpause function
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    // =============================================================================
    // VIEW FUNCTIONS
    // =============================================================================

    /**
     * @dev Get financial market configuration
     * @param configId Configuration ID
     * @return config The financial market configuration
     */
    function getFinancialConfig(uint256 configId) external view returns (FinancialMarketConfig memory config) {
        require(configId > 0 && configId < nextFinancialConfigId, "Invalid config ID");
        return financialConfigs[configId];
    }

    /**
     * @dev Get NBA game configuration
     * @param configId Configuration ID
     * @return config The NBA game configuration
     */
    function getNBAConfig(uint256 configId) external view returns (NBAGameConfig memory config) {
        require(configId > 0 && configId < nextNBAConfigId, "Invalid config ID");
        return nbaConfigs[configId];
    }

    /**
     * @dev Get configuration ID for a specific market (financial)
     * @param targetMarket Market contract address
     * @param targetMarketId Market ID
     * @return configId The configuration ID (0 if not configured)
     */
    function getFinancialConfigId(address targetMarket, uint256 targetMarketId) external view returns (uint256 configId) {
        return marketToFinancialConfig[targetMarket][targetMarketId];
    }

    /**
     * @dev Get configuration ID for a specific market (NBA)
     * @param targetMarket Market contract address
     * @param targetMarketId Market ID
     * @return configId The configuration ID (0 if not configured)
     */
    function getNBAConfigId(address targetMarket, uint256 targetMarketId) external view returns (uint256 configId) {
        return marketToNBAConfig[targetMarket][targetMarketId];
    }

    /**
     * @dev Check if an address is an authorized oracle
     * @param oracle Address to check
     * @return authorized true if authorized, false otherwise
     */
    function isAuthorizedOracle(address oracle) external view returns (bool authorized) {
        return authorizedOracles[oracle];
    }

    /**
     * @dev Get current Chainlink price for testing purposes
     * @param priceFeed Chainlink price feed address
     * @return price Current price (scaled by 8 decimals)
     * @return updatedAt Timestamp of last update
     */
    function getCurrentPrice(address priceFeed) external view returns (uint256 price, uint256 updatedAt) {
        return this._getChainlinkPrice(priceFeed);
    }
}
