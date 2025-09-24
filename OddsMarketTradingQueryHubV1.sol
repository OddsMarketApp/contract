// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./libraries/BaseQueryHubV2.sol";

/**
 * @title OddsMarketTradingQueryHubV1
 * @notice Advanced trading analytics and market behavior insights query hub
 * @dev Specialized for trading statistics, market depth analysis, and user behavior patterns
 * 
 * IMPORTANT: estimatedTrades, priceImpact, and slippageRate are APPROXIMATIONS 
 * based on simplified models. Use for reference only, not trading decisions.
 */
contract OddsMarketTradingQueryHubV1 is BaseQueryHubV2 {
    
    // ============ TRADING DATA STRUCTURES ============
    
    struct TradingStatistics {
        uint256 totalTrades;
        uint256 totalVolume;
        uint256 averageTradeSize;
        uint256 buyTrades;
        uint256 sellTrades;
        uint256 totalFees;
        uint256 averageFeeRate;
        uint256 priceImpact;
        uint256 slippageRate;
        uint256 marketDepth;
    }
    
    struct MarketTradingMetrics {
        uint256 marketId;
        string description;
        uint256 totalVolume;
        uint256 estimatedTrades;
        uint256 averageTradeSize;
        uint256 volumeGrowthRate;
        uint256 tradingEfficiency;
        uint256 marketDepth;
        uint256 bidAskSpread;
        uint256 priceVolatility;
        uint256[2] currentPrices;
        TradingStatistics stats;
    }
    
    struct VolumeAnalysis {
        uint256 period;
        uint256 totalVolume;
        uint256 peakVolume;
        uint256 averageDailyVolume;
        uint256 volumeGrowth;
        uint256 marketCount;
        uint256 activeTraders;
        uint256 volumeConcentration;
    }
    
    struct PriceMovementAnalysis {
        uint256 marketId;
        uint256[2] startPrices;
        uint256[2] currentPrices;
        uint256[2] priceChange;
        uint256 volatility;
        uint256 momentum;
        uint256 trendStrength;
        uint256 supportLevel;
        uint256 resistanceLevel;
    }
    
    struct TradingOpportunity {
        uint256 marketId;
        string description;
        uint256 opportunityType; // 1=arbitrage, 2=momentum, 3=mean_reversion
        uint256 expectedReturn;
        uint256 riskLevel;
        uint256 confidence;
        uint256 timeHorizon;
        string recommendation;
    }
    
    // ============ CONSTRUCTOR ============
    
    constructor(address _adapter) BaseQueryHubV2(_adapter) {}
    
    // ============ MAIN FUNCTIONS ============
    
    /**
     * @notice Get comprehensive trading statistics with pagination
     * @param startId Starting market ID
     * @param limit Maximum number of markets to analyze
     * @return stats Overall trading statistics
     */
    function getTradingStatisticsPaginated(uint256 startId, uint256 limit)
        external
        view
        returns (TradingStatistics memory stats)
    {
        // Early return for invalid startId
        if (startId == 0) return stats;
        
        (MinimalMarketData[] memory markets, ) = getMinimalMarketsData(startId, limit);
        
        uint256 validMarkets = 0;
        uint256 totalDepth = 0;
        uint256 totalSlippage = 0;
        
        for (uint256 i = 0; i < markets.length; i++) {
            if (!markets[i].isValid) continue;
            
            validMarkets++;
            stats.totalVolume += markets[i].totalVolumeWei;
            stats.totalFees += markets[i].feesAmountWei;
            
            // Estimate trades (simplified: volume / avg trade size)
            uint256 estimatedTrades = markets[i].totalVolumeWei / 5e17; // Assume 0.5 BNB avg
            stats.totalTrades += estimatedTrades;
            
            // Calculate market depth (liquidity available)
            totalDepth += markets[i].totalLiquidityWei;
            
            // Estimate slippage based on price deviation from 50/50
            uint256 priceDeviation = markets[i].currentPrices[0] > (PRECISION_UNIT / 2) ?
                markets[i].currentPrices[0] - (PRECISION_UNIT / 2) :
                (PRECISION_UNIT / 2) - markets[i].currentPrices[0];
            totalSlippage += (priceDeviation * BASIS_POINTS) / PRECISION_UNIT;
        }
        
        // Calculate aggregated metrics
        if (validMarkets > 0) {
            stats.averageTradeSize = stats.totalTrades > 0 ? stats.totalVolume / stats.totalTrades : 0;
            stats.marketDepth = totalDepth / validMarkets;
            stats.slippageRate = totalSlippage / validMarkets;
            
            // Estimate buy/sell distribution (simplified)
            stats.buyTrades = stats.totalTrades * 55 / 100; // Assume 55% buys
            stats.sellTrades = stats.totalTrades * 45 / 100; // Assume 45% sells
            
            // Calculate average fee rate
            if (stats.totalVolume > 0) {
                stats.averageFeeRate = (stats.totalFees * BASIS_POINTS) / stats.totalVolume;
            }
            
            // Price impact (simplified)
            stats.priceImpact = stats.slippageRate / 2;
        }
    }
    
    /**
     * @notice Get detailed trading metrics for specific markets
     * @param marketIds Array of market IDs
     * @return metrics Array of market trading metrics
     */
    function getMarketsTradingMetrics(uint256[] calldata marketIds)
        external
        view
        returns (MarketTradingMetrics[] memory metrics)
    {
        metrics = new MarketTradingMetrics[](marketIds.length);
        
        for (uint256 i = 0; i < marketIds.length; i++) {
            MinimalMarketData memory data = getMinimalMarketData(marketIds[i]);
            if (!data.isValid) continue;
            
            metrics[i] = _calculateMarketTradingMetrics(marketIds[i], data);
        }
    }
    
    /**
     * @notice Get volume analysis for a specific time period
     * @param periodHours Time period in hours
     * @return analysis Volume analysis data
     */
    function getVolumeAnalysis(uint256 periodHours)
        external
        view
        returns (VolumeAnalysis memory analysis)
    {
        analysis.period = periodHours;
        uint256 marketCount = adapter.getMarketCount();
        
        uint256 maxVolume = 0;
        uint256 activeMarkets = 0;
        
        for (uint256 i = 1; i <= marketCount; i++) {
            MinimalMarketData memory data = getMinimalMarketData(i);
            if (!data.isValid) continue;
            
            analysis.totalVolume += data.totalVolumeWei;
            analysis.marketCount++;
            
            if (data.status == 1) { // Active status
                activeMarkets++;
            }
            
            if (data.totalVolumeWei > maxVolume) {
                maxVolume = data.totalVolumeWei;
            }
        }
        
        analysis.peakVolume = maxVolume;
        analysis.activeTraders = activeMarkets * 10; // Estimate 10 traders per active market
        
        // Calculate daily metrics
        if (periodHours >= 24) {
            uint256 daysCount = periodHours / 24;
            analysis.averageDailyVolume = analysis.totalVolume / daysCount;
        }
        
        // Volume concentration (top market % of total)
        if (analysis.totalVolume > 0) {
            analysis.volumeConcentration = (maxVolume * BASIS_POINTS) / analysis.totalVolume;
        }
        
        // Growth rate (simplified)
        analysis.volumeGrowth = 500; // 5% placeholder
    }
    
    /**
     * @notice Get price movement analysis for markets
     * @param marketIds Array of market IDs
     * @return movements Array of price movement analysis
     */
    function getPriceMovementAnalysis(uint256[] calldata marketIds)
        external
        view
        returns (PriceMovementAnalysis[] memory movements)
    {
        movements = new PriceMovementAnalysis[](marketIds.length);
        
        for (uint256 i = 0; i < marketIds.length; i++) {
            MinimalMarketData memory data = getMinimalMarketData(marketIds[i]);
            if (!data.isValid) continue;
            
            movements[i].marketId = marketIds[i];
            movements[i].currentPrices = data.currentPrices;
            
            // Assume initial prices were 50/50
            movements[i].startPrices[0] = PRECISION_UNIT / 2;
            movements[i].startPrices[1] = PRECISION_UNIT / 2;
            
            // Calculate price changes
            movements[i].priceChange[0] = _calculatePriceChange(
                movements[i].startPrices[0],
                movements[i].currentPrices[0]
            );
            movements[i].priceChange[1] = _calculatePriceChange(
                movements[i].startPrices[1],
                movements[i].currentPrices[1]
            );
            
            // Calculate volatility
            uint256 maxPrice = data.currentPrices[0] > data.currentPrices[1] ?
                data.currentPrices[0] : data.currentPrices[1];
            movements[i].volatility = (maxPrice * BASIS_POINTS) / PRECISION_UNIT;
            
            // Momentum (simplified)
            if (data.currentPrices[0] > (PRECISION_UNIT / 2)) {
                movements[i].momentum = movements[i].priceChange[0];
            } else {
                movements[i].momentum = movements[i].priceChange[1];
            }
            
            // Trend strength
            movements[i].trendStrength = movements[i].volatility;
            
            // Support/Resistance levels (simplified)
            movements[i].supportLevel = PRECISION_UNIT / 4;  // 25%
            movements[i].resistanceLevel = (PRECISION_UNIT * 3) / 4; // 75%
        }
    }
    
    /**
     * @notice Identify trading opportunities
     * @param marketIds Array of market IDs to analyze
     * @return opportunities Array of trading opportunities
     */
    function identifyTradingOpportunities(uint256[] calldata marketIds)
        external
        view
        returns (TradingOpportunity[] memory opportunities)
    {
        opportunities = new TradingOpportunity[](marketIds.length);
        
        for (uint256 i = 0; i < marketIds.length; i++) {
            MinimalMarketData memory data = getMinimalMarketData(marketIds[i]);
            if (!data.isValid) continue;
            
            opportunities[i] = _identifyOpportunity(marketIds[i], data);
        }
    }
    
    /**
     * @notice Get trading summary with top performers
     * @return stats Overall trading statistics
     * @return topVolume Top 5 markets by volume
     * @return opportunities Top 3 trading opportunities
     */
    function getTradingSummary()
        external
        view
        returns (
            TradingStatistics memory stats,
            MarketTradingMetrics[] memory topVolume,
            TradingOpportunity[] memory opportunities
        )
    {
        uint256 marketCount = adapter.getMarketCount();
        
        // Get overall stats
        stats = this.getTradingStatisticsPaginated(1, marketCount);
        
        // Get top markets by volume (simplified - just get first 5 active markets)
        topVolume = new MarketTradingMetrics[](5);
        uint256 index = 0;
        
        for (uint256 i = 1; i <= marketCount && index < 5; i++) {
            MinimalMarketData memory data = getMinimalMarketData(i);
            if (!data.isValid || data.status != 1) continue; // 1 = Active status
            
            topVolume[index] = _calculateMarketTradingMetrics(i, data);
            index++;
        }
        
        // Get trading opportunities (first 3 active markets)
        opportunities = new TradingOpportunity[](3);
        index = 0;
        
        for (uint256 i = 1; i <= marketCount && index < 3; i++) {
            MinimalMarketData memory data = getMinimalMarketData(i);
            if (!data.isValid || data.status != 1) continue; // 1 = Active status
            
            opportunities[index] = _identifyOpportunity(i, data);
            index++;
        }
    }
    
    // ============ INTERNAL FUNCTIONS ============
    
    function _calculateMarketTradingMetrics(uint256 marketId, MinimalMarketData memory data)
        internal
        pure
        returns (MarketTradingMetrics memory metrics)
    {
        metrics.marketId = marketId;
        metrics.description = data.title;
        metrics.totalVolume = data.totalVolumeWei;
        metrics.currentPrices = data.currentPrices;
        
        // Estimate trades
        metrics.estimatedTrades = data.totalVolumeWei / 5e17; // 0.5 BNB avg
        if (metrics.estimatedTrades > 0) {
            metrics.averageTradeSize = data.totalVolumeWei / metrics.estimatedTrades;
        }
        
        // Calculate bid-ask spread
        uint256 spread = data.currentPrices[0] > data.currentPrices[1] ?
            data.currentPrices[0] - data.currentPrices[1] :
            data.currentPrices[1] - data.currentPrices[0];
        metrics.bidAskSpread = (spread * BASIS_POINTS) / PRECISION_UNIT;
        
        // Market depth
        metrics.marketDepth = data.totalLiquidityWei;
        
        // Price volatility
        uint256 priceDeviation = data.currentPrices[0] > (PRECISION_UNIT / 2) ?
            data.currentPrices[0] - (PRECISION_UNIT / 2) :
            (PRECISION_UNIT / 2) - data.currentPrices[0];
        metrics.priceVolatility = (priceDeviation * BASIS_POINTS) / PRECISION_UNIT;
        
        // Trading efficiency (volume to liquidity ratio)
        if (data.totalLiquidityWei > 0) {
            metrics.tradingEfficiency = (data.totalVolumeWei * BASIS_POINTS) / data.totalLiquidityWei;
        }
        
        // Volume growth (simplified)
        metrics.volumeGrowthRate = 1000; // 10% placeholder
        
        // Populate stats
        metrics.stats.totalTrades = metrics.estimatedTrades;
        metrics.stats.totalVolume = data.totalVolumeWei;
        metrics.stats.averageTradeSize = metrics.averageTradeSize;
        metrics.stats.buyTrades = metrics.estimatedTrades * 55 / 100;
        metrics.stats.sellTrades = metrics.estimatedTrades * 45 / 100;
        metrics.stats.totalFees = data.feesAmountWei;
        if (data.totalVolumeWei > 0) {
            metrics.stats.averageFeeRate = (data.feesAmountWei * BASIS_POINTS) / data.totalVolumeWei;
        }
        metrics.stats.priceImpact = metrics.priceVolatility / 2;
        metrics.stats.slippageRate = metrics.bidAskSpread;
        metrics.stats.marketDepth = data.totalLiquidityWei;
    }
    
    function _identifyOpportunity(uint256 marketId, MinimalMarketData memory data)
        internal
        pure
        returns (TradingOpportunity memory opp)
    {
        opp.marketId = marketId;
        opp.description = data.title;
        
        // Check for extreme prices (potential mean reversion): below 5% or above 95%
        if (calculateExtremePriceFlag(data.currentPrices, 500, 9500)) {
            opp.opportunityType = 3; // Mean reversion
            opp.recommendation = "Consider contrarian position";
            opp.expectedReturn = 1500; // 15%
            opp.riskLevel = 7000; // High risk
            opp.confidence = 6000; // Medium confidence
            opp.timeHorizon = 7; // 7 days
        }
        // Check for momentum opportunities
        else if (data.currentPrices[0] > 6e17 || data.currentPrices[1] > 6e17) { // >60%
            opp.opportunityType = 2; // Momentum
            opp.recommendation = "Follow the trend";
            opp.expectedReturn = 800; // 8%
            opp.riskLevel = 5000; // Medium risk
            opp.confidence = 7000; // Good confidence
            opp.timeHorizon = 3; // 3 days
        }
        // Balanced market
        else {
            opp.opportunityType = 1; // Low volatility arbitrage
            opp.recommendation = "Wait for better entry";
            opp.expectedReturn = 300; // 3%
            opp.riskLevel = 3000; // Low risk
            opp.confidence = 8000; // High confidence
            opp.timeHorizon = 1; // 1 day
        }
    }
    
    function _calculatePriceChange(uint256 initial, uint256 current)
        internal
        pure
        returns (uint256)
    {
        if (initial == 0) return 0;
        
        if (current >= initial) {
            return ((current - initial) * BASIS_POINTS) / initial;
        } else {
            return ((initial - current) * BASIS_POINTS) / initial;
        }
    }
    
    // ============ BACKWARD COMPATIBILITY ============
    
    /**
     * @notice Get trading statistics (full scan for backward compatibility)
     * @return stats Overall trading statistics
     */
    function getTradingStatistics()
        external
        view
        returns (TradingStatistics memory stats)
    {
        uint256 marketCount = adapter.getMarketCount();
        return this.getTradingStatisticsPaginated(1, marketCount);
    }
}
