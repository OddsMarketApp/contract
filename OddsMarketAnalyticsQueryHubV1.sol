// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./libraries/BaseQueryHubV2.sol";

/**
 * @title OddsMarketAnalyticsQueryHubV1
 * @notice Advanced market analytics and trend analysis query hub
 * @dev Specialized for market performance metrics, price analytics, and predictive insights
 * 
 * IMPORTANT: All APY calculations, volatility metrics, and performance scores are 
 * APPROXIMATIONS based on current state. Use for reference only, not financial advice.
 */
contract OddsMarketAnalyticsQueryHubV1 is BaseQueryHubV2 {
    
    // ============ ANALYTICS DATA STRUCTURES ============
    
    struct MarketPerformanceMetrics {
        uint256 marketId;
        string description;
        uint256 totalVolume;
        uint256 liquidityUtilization;
        uint256 priceVolatility;
        uint256 tradingEfficiency;
        uint256 participantCount;
        uint256 averageTradeSize;
        uint256 feeGeneration;
        uint256 performanceScore;
        uint256 trendDirection; // 0=down, 1=stable, 2=up
    }
    
    struct PriceAnalytics {
        uint256 marketId;
        uint256[2] currentPrices;
        uint256[2] openingPrices;
        uint256[2] highPrices;
        uint256[2] lowPrices;
        uint256 priceSpread;
        uint256 volatilityIndex;
        uint256 momentumScore;
        uint256 supportLevel;
        uint256 resistanceLevel;
        bool isPricingEfficient;
    }
    
    struct VolumeAnalytics {
        uint256 totalPlatformVolume;
        uint256 averageDailyVolume;
        uint256 peakVolume;
        uint256 volumeGrowthRate;
        uint256 marketVolumeDistribution;
        uint256 topMarketVolume;
        uint256 volumeConcentrationRatio;
        uint256 tradingActivityScore;
    }
    
    struct LiquidityAnalytics {
        uint256 totalLiquidity;
        uint256 averageLiquidity;
        uint256 liquidityDistribution;
        uint256 utilizationRate;
        uint256 liquidityEfficiency;
        uint256 providerCount;
        uint256 avgPoolSize;
        uint256 liquidityStability;
    }
    
    struct PlatformInsights {
        uint256 userEngagement;
        uint256 marketDiversity;
        uint256 pricingAccuracy;
        uint256 liquidityHealth;
        uint256 tradingActivity;
        uint256 overallScore;
        uint256 growthPotential;
        string[] keyInsights;
    }
    
    struct TrendAnalysis {
        uint256 period;
        uint256 trendStrength;
        uint256 trendDirection;
        uint256 volatilityTrend;
        uint256 volumeTrend;
        uint256 liquidityTrend;
        uint256 participationTrend;
        string trendSummary;
    }
    
    // ============ CONSTRUCTOR ============
    
    constructor(address _adapter) BaseQueryHubV2(_adapter) {}
    
    // ============ MAIN FUNCTIONS ============
    
    /**
     * @notice Get comprehensive market performance analysis with pagination
     * @param startId Starting market ID
     * @param limit Maximum markets to analyze
     * @return metrics Array of market performance metrics
     */
    function getMarketPerformanceMetricsPaginated(uint256 startId, uint256 limit)
        external
        view
        returns (MarketPerformanceMetrics[] memory metrics)
    {
        (MinimalMarketData[] memory markets, ) = getMinimalMarketsData(startId, limit);
        
        // Only return metrics for valid markets
        uint256 metricsCount = 0;
        for (uint256 i = 0; i < markets.length; i++) {
            if (markets[i].isValid) metricsCount++;
        }
        
        metrics = new MarketPerformanceMetrics[](metricsCount);
        uint256 index = 0;
        
        for (uint256 i = 0; i < markets.length; i++) {
            if (!markets[i].isValid) continue;
            
            metrics[index] = _calculateMarketPerformance(startId + i, markets[i]);
            index++;
        }
    }
    
    /**
     * @notice Get detailed price analytics for specific markets
     * @param marketIds Array of market IDs
     * @return analytics Array of price analytics
     */
    function getPriceAnalytics(uint256[] calldata marketIds)
        external
        view
        returns (PriceAnalytics[] memory analytics)
    {
        analytics = new PriceAnalytics[](marketIds.length);
        
        for (uint256 i = 0; i < marketIds.length; i++) {
            MinimalMarketData memory data = getMinimalMarketData(marketIds[i]);
            if (!data.isValid) continue;
            
            analytics[i] = _analyzePrices(marketIds[i], data);
        }
    }
    
    /**
     * @notice Get volume analytics for the platform
     * @return analytics Volume analysis data
     */
    function getVolumeAnalytics()
        external
        view
        returns (VolumeAnalytics memory analytics)
    {
        uint256 marketCount = adapter.getMarketCount();
        if (marketCount == 0) return analytics;
        
        uint256[] memory volumes = new uint256[](marketCount);
        uint256 validMarkets = 0;
        uint256 maxVolume = 0;
        
        for (uint256 i = 1; i <= marketCount; i++) {
            MinimalMarketData memory data = getMinimalMarketData(i);
            if (!data.isValid) continue;
            
            volumes[validMarkets] = data.totalVolumeWei;
            analytics.totalPlatformVolume += data.totalVolumeWei;
            
            if (data.totalVolumeWei > maxVolume) {
                maxVolume = data.totalVolumeWei;
            }
            
            validMarkets++;
        }
        
        if (validMarkets > 0) {
            analytics.averageDailyVolume = analytics.totalPlatformVolume / 7; // Weekly average
            analytics.peakVolume = maxVolume;
            analytics.topMarketVolume = maxVolume;
            
            // Calculate volume concentration
            if (analytics.totalPlatformVolume > 0) {
                analytics.volumeConcentrationRatio = (maxVolume * BASIS_POINTS) / analytics.totalPlatformVolume;
            }
            
            // Calculate trading activity score
            analytics.tradingActivityScore = validMarkets >= 20 ? 9000 : 
                                           validMarkets >= 10 ? 7000 : 
                                           validMarkets >= 5 ? 5000 : 3000;
        }
        
        // Growth rate (simplified)
        analytics.volumeGrowthRate = 800; // 8% placeholder
    }
    
    /**
     * @notice Get liquidity analytics for the platform
     * @return analytics Liquidity analysis data
     */
    function getLiquidityAnalytics()
        external
        view
        returns (LiquidityAnalytics memory analytics)
    {
        uint256 marketCount = adapter.getMarketCount();
        if (marketCount == 0) return analytics;
        
        uint256 totalUtilization = 0;
        uint256 validPools = 0;
        uint256 activeProviders = 0;
        
        for (uint256 i = 1; i <= marketCount; i++) {
            MinimalMarketData memory data = getMinimalMarketData(i);
            if (!data.isValid || data.totalLiquidityWei == 0) continue;
            
            validPools++;
            analytics.totalLiquidity += data.totalLiquidityWei;
            
            // Calculate utilization rate
            if (data.totalLiquidityWei > 0) {
                uint256 utilization = (data.totalVolumeWei * BASIS_POINTS) / data.totalLiquidityWei;
                totalUtilization += utilization;
            }
            
            // Estimate LP count (simplified)
            if (data.lpTokenSupply > 0) {
                activeProviders += (data.totalLiquidityWei / 1e18) + 1; // Rough estimate
            }
        }
        
        if (validPools > 0) {
            analytics.averageLiquidity = analytics.totalLiquidity / validPools;
            analytics.utilizationRate = totalUtilization / validPools;
            analytics.avgPoolSize = analytics.averageLiquidity;
            analytics.providerCount = activeProviders;
            
            // Calculate efficiency score
            analytics.liquidityEfficiency = analytics.utilizationRate > 5000 ? 8000 : 
                                          analytics.utilizationRate > 2000 ? 6000 : 4000;
            
            // Stability score
            analytics.liquidityStability = 7500; // Baseline stability
        }
    }
    
    /**
     * @notice Get comprehensive platform insights
     * @return insights Platform analysis and recommendations
     */
    function getPlatformInsights()
        external
        view
        returns (PlatformInsights memory insights)
    {
        VolumeAnalytics memory volumeData = this.getVolumeAnalytics();
        LiquidityAnalytics memory liquidityData = this.getLiquidityAnalytics();
        
        // Calculate component scores
        insights.userEngagement = volumeData.tradingActivityScore;
        insights.liquidityHealth = liquidityData.liquidityEfficiency;
        insights.tradingActivity = volumeData.tradingActivityScore;
        
        // Market diversity score
        uint256 marketCount = adapter.getMarketCount();
        insights.marketDiversity = marketCount >= 50 ? 9000 : 
                                 marketCount >= 20 ? 7000 : 
                                 marketCount >= 10 ? 5000 : 3000;
        
        // Pricing accuracy (based on liquidity and volume)
        if (liquidityData.totalLiquidity > 100e18 && volumeData.totalPlatformVolume > 50e18) {
            insights.pricingAccuracy = 8500;
        } else if (liquidityData.totalLiquidity > 50e18) {
            insights.pricingAccuracy = 7000;
        } else {
            insights.pricingAccuracy = 5000;
        }
        
        // Overall score
        insights.overallScore = (insights.userEngagement + 
                               insights.marketDiversity + 
                               insights.pricingAccuracy + 
                               insights.liquidityHealth + 
                               insights.tradingActivity) / 5;
        
        // Growth potential
        insights.growthPotential = insights.overallScore > 8000 ? 9000 : 
                                 insights.overallScore > 6000 ? 7000 : 5000;
    }
    
    /**
     * @notice Get trend analysis for specified period
     * @param periodHours Analysis period in hours
     * @return analysis Trend analysis data
     */
    function getTrendAnalysis(uint256 periodHours)
        external
        view
        returns (TrendAnalysis memory analysis)
    {
        analysis.period = periodHours;
        
        VolumeAnalytics memory volumeData = this.getVolumeAnalytics();
        LiquidityAnalytics memory liquidityData = this.getLiquidityAnalytics();
        
        // Simplified trend analysis
        analysis.trendStrength = 7000; // Moderate strength
        analysis.trendDirection = 2; // Upward trend
        
        // Volume trend
        analysis.volumeTrend = volumeData.volumeGrowthRate > 500 ? 2 : 1; // Up if >5% growth
        
        // Liquidity trend
        analysis.liquidityTrend = liquidityData.liquidityEfficiency > 6000 ? 2 : 1;
        
        // Participation trend
        analysis.participationTrend = volumeData.tradingActivityScore > 7000 ? 2 : 1;
        
        // Volatility trend (simplified)
        analysis.volatilityTrend = 1; // Stable
        
        // Summary
        if (analysis.volumeTrend == 2 && analysis.liquidityTrend == 2) {
            analysis.trendSummary = "Strong upward trend with healthy growth";
        } else if (analysis.volumeTrend >= 1 && analysis.liquidityTrend >= 1) {
            analysis.trendSummary = "Stable growth with positive indicators";
        } else {
            analysis.trendSummary = "Mixed signals, monitoring required";
        }
    }
    
    /**
     * @notice Get top performing markets by various criteria
     * @param criteria Performance criteria (1=volume, 2=liquidity, 3=efficiency)
     * @param limit Number of markets to return
     * @return marketIds Top performing market IDs
     * @return scores Performance scores
     */
    function getTopPerformers(uint256 criteria, uint256 limit)
        external
        view
        returns (uint256[] memory marketIds, uint256[] memory scores)
    {
        uint256 marketCount = adapter.getMarketCount();
        if (marketCount == 0 || limit == 0) return (marketIds, scores);
        
        uint256 effectiveLimit = limit > marketCount ? marketCount : limit;
        marketIds = new uint256[](effectiveLimit);
        scores = new uint256[](effectiveLimit);
        
        uint256 index = 0;
        for (uint256 i = 1; i <= marketCount && index < effectiveLimit; i++) {
            MinimalMarketData memory data = getMinimalMarketData(i);
            if (!data.isValid) continue;
            
            marketIds[index] = i;
            
            // Calculate score based on criteria
            if (criteria == 1) { // Volume
                scores[index] = data.totalVolumeWei;
            } else if (criteria == 2) { // Liquidity
                scores[index] = data.totalLiquidityWei;
            } else if (criteria == 3) { // Efficiency
                scores[index] = _calculateEfficiencyScore(data);
            } else {
                scores[index] = _calculateOverallScore(data);
            }
            
            index++;
        }
        
        // Note: In production, this should be sorted by scores
    }
    
    // ============ INTERNAL FUNCTIONS ============
    
    function _calculateMarketPerformance(uint256 marketId, MinimalMarketData memory data)
        internal
        pure
        returns (MarketPerformanceMetrics memory metrics)
    {
        metrics.marketId = marketId;
        metrics.description = data.title;
        metrics.totalVolume = data.totalVolumeWei;
        
        // Liquidity utilization
        if (data.totalLiquidityWei > 0) {
            metrics.liquidityUtilization = (data.totalVolumeWei * BASIS_POINTS) / data.totalLiquidityWei;
        }
        
        // Price volatility
        uint256 priceDeviation = data.currentPrices[0] > data.currentPrices[1] ? 
                                data.currentPrices[0] - data.currentPrices[1] :
                                data.currentPrices[1] - data.currentPrices[0];
        metrics.priceVolatility = (priceDeviation * BASIS_POINTS) / PRECISION_UNIT;
        
        // Trading efficiency
        metrics.tradingEfficiency = _calculateEfficiencyScore(data);
        
        // Estimate participant count
        metrics.participantCount = data.totalVolumeWei / 1e18; // 1 BNB per participant
        
        // Average trade size
        if (metrics.participantCount > 0) {
            metrics.averageTradeSize = data.totalVolumeWei / metrics.participantCount;
        }
        
        // Fee generation
        metrics.feeGeneration = data.feesAmountWei;
        
        // Performance score
        metrics.performanceScore = _calculateOverallScore(data);
        
        // Trend direction (simplified)
        if (data.currentPrices[0] > (PRECISION_UNIT * 6) / 10) { // >60%
            metrics.trendDirection = 2; // Up
        } else if (data.currentPrices[0] < (PRECISION_UNIT * 4) / 10) { // <40%
            metrics.trendDirection = 0; // Down
        } else {
            metrics.trendDirection = 1; // Stable
        }
    }
    
    function _analyzePrices(uint256 marketId, MinimalMarketData memory data)
        internal
        pure
        returns (PriceAnalytics memory analytics)
    {
        analytics.marketId = marketId;
        analytics.currentPrices = data.currentPrices;
        
        // Assume opening prices were 50/50
        analytics.openingPrices[0] = PRECISION_UNIT / 2;
        analytics.openingPrices[1] = PRECISION_UNIT / 2;
        
        // For high/low, use current as approximation
        analytics.highPrices = data.currentPrices;
        analytics.lowPrices[0] = PRECISION_UNIT / 4; // Assume 25% minimum
        analytics.lowPrices[1] = PRECISION_UNIT / 4;
        
        // Price spread
        analytics.priceSpread = data.currentPrices[0] > data.currentPrices[1] ? 
                               data.currentPrices[0] - data.currentPrices[1] :
                               data.currentPrices[1] - data.currentPrices[0];
        
        // Volatility index
        analytics.volatilityIndex = (analytics.priceSpread * BASIS_POINTS) / PRECISION_UNIT;
        
        // Momentum score (based on deviation from 50/50)
        uint256 deviation = data.currentPrices[0] > (PRECISION_UNIT / 2) ? 
                           data.currentPrices[0] - (PRECISION_UNIT / 2) :
                           (PRECISION_UNIT / 2) - data.currentPrices[0];
        analytics.momentumScore = (deviation * BASIS_POINTS) / PRECISION_UNIT;
        
        // Support and resistance levels
        analytics.supportLevel = PRECISION_UNIT / 4; // 25%
        analytics.resistanceLevel = (PRECISION_UNIT * 3) / 4; // 75%
        
        // Pricing efficiency check
        analytics.isPricingEfficient = analytics.volatilityIndex < 2000 && 
                                      analytics.volatilityIndex > 100;
    }
    
    function _calculateEfficiencyScore(MinimalMarketData memory data)
        internal
        pure
        returns (uint256 score)
    {
        if (data.totalLiquidityWei == 0) return 0;
        
        // Efficiency = volume per unit liquidity
        uint256 efficiency = (data.totalVolumeWei * BASIS_POINTS) / data.totalLiquidityWei;
        
        // Normalize to 0-10000 scale
        score = efficiency > 20000 ? 10000 : efficiency / 2;
    }
    
    function _calculateOverallScore(MinimalMarketData memory data)
        internal
        pure
        returns (uint256 score)
    {
        uint256 volumeScore = data.totalVolumeWei >= 10e18 ? 3000 : 
                            (data.totalVolumeWei * 3000) / 10e18;
        
        uint256 liquidityScore = data.totalLiquidityWei >= 5e18 ? 3000 : 
                               (data.totalLiquidityWei * 3000) / 5e18;
        
        uint256 efficiencyScore = _calculateEfficiencyScore(data) * 4 / 10;
        
        score = volumeScore + liquidityScore + efficiencyScore;
    }
    
    // ============ BACKWARD COMPATIBILITY ============
    
    /**
     * @notice Get market performance for all markets (full scan)
     * @return metrics Array of performance metrics
     */
    function getAllMarketPerformanceMetrics()
        external
        view
        returns (MarketPerformanceMetrics[] memory metrics)
    {
        uint256 marketCount = adapter.getMarketCount();
        return this.getMarketPerformanceMetricsPaginated(1, marketCount);
    }
}
