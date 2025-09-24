// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./libraries/BaseQueryHubV2.sol";

/**
 * @title OddsMarketAdminQueryHubV1
 * @notice Platform governance and administrative oversight query hub
 * @dev Specialized for system monitoring, risk assessment, and operational analytics
 */
contract OddsMarketAdminQueryHubV1 is BaseQueryHubV2 {
    
    // ============ ADMIN DATA STRUCTURES ============
    
    struct PlatformOverview {
        uint256 totalMarkets;
        uint256 activeMarkets;
        uint256 resolvedMarkets;
        uint256 totalValueLocked;
        uint256 totalVolume;
        uint256 totalFees;
        uint256 totalUsers;
        uint256 platformHealth;
        uint256 averageMarketSize;
        uint256 marketGrowthRate;
    }
    
    struct MarketCategoryStats {
        string category;
        uint256 marketCount;
        uint256 totalVolume;
        uint256 totalLiquidity;
        uint256 averageAPY;
        uint256 categoryHealth;
        uint256 userParticipation;
    }
    
    struct RiskAnalysis {
        uint256 overallRiskScore;
        uint256 liquidityRisk;
        uint256 concentrationRisk;
        uint256 operationalRisk;
        uint256 marketsAtRisk;
        uint256 totalExposure;
        string riskLevel;
        string[] riskFactors;
    }
    
    struct SystemMetrics {
        uint256 avgGasUsage;
        uint256 transactionSuccess;
        uint256 errorRate;
        uint256 systemUptime;
        uint256 userSatisfaction;
        uint256 performanceScore;
    }
    
    struct MarketPerformanceRanking {
        uint256 marketId;
        string description;
        uint256 performanceScore;
        uint256 volume;
        uint256 liquidity;
        uint256 participantCount;
        uint256 healthScore;
        string category;
    }
    
    // ============ CONSTRUCTOR ============
    
    constructor(address _adapter) BaseQueryHubV2(_adapter) {}
    
    // ============ MAIN FUNCTIONS ============
    
    /**
     * @notice Get comprehensive platform overview
     * @return overview Platform statistics and health metrics
     */
    function getPlatformOverview()
        external
        view
        returns (PlatformOverview memory overview)
    {
        uint256 marketCount = adapter.getMarketCount();
        overview.totalMarkets = marketCount;
        
        if (marketCount == 0) return overview;
        
        uint256 healthSum = 0;
        uint256 validHealthCount = 0;
        
        for (uint256 i = 1; i <= marketCount; i++) {
            MinimalMarketData memory data = getMinimalMarketData(i);
            if (!data.isValid) continue;
            
            // Count by status
            if (data.status == 1) {  // Active
                overview.activeMarkets++;
            } else if (data.status == 3) {  // Resolved
                overview.resolvedMarkets++;
            }
            
            // Aggregate metrics
            overview.totalValueLocked += data.totalLiquidityWei;
            overview.totalVolume += data.totalVolumeWei;
            overview.totalFees += data.feesAmountWei;
            
            // Calculate health scores
            MarketHealthMetrics memory health = calculateMarketHealth(data);
            healthSum += health.healthScore;
            validHealthCount++;
        }
        
        // Calculate derived metrics
        if (validHealthCount > 0) {
            overview.platformHealth = healthSum / validHealthCount;
            overview.averageMarketSize = overview.totalValueLocked / validHealthCount;
        }
        
        // Estimate total users (simplified: 5 users per active market)
        overview.totalUsers = overview.activeMarkets * 5;
        
        // Growth rate (simplified placeholder)
        overview.marketGrowthRate = 1200; // 12%
    }
    
    /**
     * @notice Get market statistics by category with pagination
     * @param categories Array of category names
     * @return stats Array of category statistics
     */
    function getMarketCategoryStats(string[] calldata categories)
        external
        view
        returns (MarketCategoryStats[] memory stats)
    {
        stats = new MarketCategoryStats[](categories.length);
        
        for (uint256 c = 0; c < categories.length; c++) {
            stats[c].category = categories[c];
            
            uint256 marketCount = adapter.getMarketCount();
            uint256 categoryMarkets = 0;
            uint256[] memory apyValues = new uint256[](marketCount);
            uint256 apyCount = 0;
            
            for (uint256 i = 1; i <= marketCount; i++) {
                MinimalMarketData memory data = getMinimalMarketData(i);
                if (!data.isValid) continue;
                
                // Simple category matching (contains check)
                if (_stringContains(data.title, categories[c])) {
                    categoryMarkets++;
                    stats[c].totalVolume += data.totalVolumeWei;
                    stats[c].totalLiquidity += data.totalLiquidityWei;
                    
                    // Calculate APY for this market
                    uint256 marketAge = block.timestamp - data.creationTime;
                    uint256 daysElapsed = marketAge / 86400;
                    if (daysElapsed > 0 && data.totalLiquidityWei > 0) {
                        uint256 apy = calculateAPY(data.feesAmountWei, data.totalLiquidityWei, daysElapsed);
                        apyValues[apyCount] = apy;
                        apyCount++;
                    }
                }
            }
            
            stats[c].marketCount = categoryMarkets;
            
            // Calculate average APY
            if (apyCount > 0) {
                uint256 totalAPY = 0;
                for (uint256 j = 0; j < apyCount; j++) {
                    totalAPY += apyValues[j];
                }
                stats[c].averageAPY = totalAPY / apyCount;
            }
            
            // Calculate category health (simplified)
            if (categoryMarkets > 0) {
                stats[c].categoryHealth = categoryMarkets >= 10 ? 9000 : 
                                         categoryMarkets >= 5 ? 7000 : 5000;
                stats[c].userParticipation = categoryMarkets * 3; // Estimate 3 users per market
            }
        }
    }
    
    /**
     * @notice Get comprehensive risk analysis
     * @return analysis Risk assessment for the platform
     */
    function getRiskAnalysis()
        external
        view
        returns (RiskAnalysis memory analysis)
    {
        uint256 marketCount = adapter.getMarketCount();
        if (marketCount == 0) return analysis;
        
        uint256 lowLiquidityMarkets = 0;
        uint256 extremePriceMarkets = 0;
        uint256 totalLiquidity = 0;
        uint256 maxMarketLiquidity = 0;
        
        for (uint256 i = 1; i <= marketCount; i++) {
            MinimalMarketData memory data = getMinimalMarketData(i);
            if (!data.isValid) continue;
            
            totalLiquidity += data.totalLiquidityWei;
            
            // Track max liquidity for concentration risk
            if (data.totalLiquidityWei > maxMarketLiquidity) {
                maxMarketLiquidity = data.totalLiquidityWei;
            }
            
            // Count risk factors
            if (data.totalLiquidityWei < HIGH_RISK_LIQUIDITY_THRESHOLD) {
                lowLiquidityMarkets++;
            }
            
            // Check for extreme prices: below 5% or above 95% indicates extreme market sentiment
            if (calculateExtremePriceFlag(data.currentPrices, 500, 9500)) {
                extremePriceMarkets++;
            }
        }
        
        // Calculate risk scores
        analysis.liquidityRisk = lowLiquidityMarkets > marketCount / 4 ? 8000 : 
                               lowLiquidityMarkets > marketCount / 10 ? 5000 : 2000;
        
        // Concentration risk
        if (totalLiquidity > 0) {
            uint256 concentrationRatio = (maxMarketLiquidity * BASIS_POINTS) / totalLiquidity;
            analysis.concentrationRisk = concentrationRatio > 5000 ? 8000 : 
                                       concentrationRatio > 3000 ? 5000 : 2000;
        }
        
        // Operational risk (simplified)
        analysis.operationalRisk = 3000; // Medium baseline
        
        // Overall risk score
        analysis.overallRiskScore = (analysis.liquidityRisk + 
                                   analysis.concentrationRisk + 
                                   analysis.operationalRisk) / 3;
        
        analysis.marketsAtRisk = lowLiquidityMarkets + extremePriceMarkets;
        analysis.totalExposure = totalLiquidity;
        
        // Risk level classification
        if (analysis.overallRiskScore > 7000) {
            analysis.riskLevel = "High";
        } else if (analysis.overallRiskScore > 4000) {
            analysis.riskLevel = "Medium";
        } else {
            analysis.riskLevel = "Low";
        }
    }
    
    /**
     * @notice Get system performance metrics
     * @return metrics System performance indicators
     */
    function getSystemMetrics()
        external
        pure
        returns (SystemMetrics memory metrics)
    {
        // Simplified metrics (in real implementation, these would come from monitoring)
        metrics.avgGasUsage = 150000; // Average gas per transaction
        metrics.transactionSuccess = 9800; // 98% success rate
        metrics.errorRate = 200; // 2% error rate
        metrics.systemUptime = 9950; // 99.5% uptime
        metrics.userSatisfaction = 8500; // 85% satisfaction
        
        // Calculate performance score
        metrics.performanceScore = (metrics.transactionSuccess + 
                                  metrics.systemUptime + 
                                  metrics.userSatisfaction) / 3;
    }
    
    /**
     * @notice Get top performing markets ranking
     * @param limit Maximum number of markets to return
     * @return rankings Array of market performance rankings
     */
    function getTopPerformingMarkets(uint256 limit)
        external
        view
        returns (MarketPerformanceRanking[] memory rankings)
    {
        uint256 marketCount = adapter.getMarketCount();
        if (marketCount == 0 || limit == 0) return rankings;
        
        uint256 effectiveLimit = limit > marketCount ? marketCount : limit;
        rankings = new MarketPerformanceRanking[](effectiveLimit);
        
        uint256 index = 0;
        for (uint256 i = 1; i <= marketCount && index < effectiveLimit; i++) {
            MinimalMarketData memory data = getMinimalMarketData(i);
            if (!data.isValid) continue;
            
            rankings[index].marketId = i;
            rankings[index].description = data.title;
            rankings[index].volume = data.totalVolumeWei;
            rankings[index].liquidity = data.totalLiquidityWei;
            
            // Calculate performance score (cache healthScore to avoid duplicate calculation)
            uint256 volumeScore = data.totalVolumeWei >= 10e18 ? 4000 : 
                                (data.totalVolumeWei * 4000) / 10e18;
            uint256 liquidityScore = data.totalLiquidityWei >= 5e18 ? 3000 : 
                                   (data.totalLiquidityWei * 3000) / 5e18;
            uint256 fullHealthScore = calculateMarketHealth(data).healthScore;
            uint256 healthScore = fullHealthScore * 3 / 10;
            
            rankings[index].performanceScore = volumeScore + liquidityScore + healthScore;
            rankings[index].healthScore = fullHealthScore;
            
            // Estimate participant count
            rankings[index].participantCount = data.totalVolumeWei / 1e18; // 1 BNB per participant
            
            // Simple category classification
            rankings[index].category = _inferCategory(data.title);
            
            index++;
        }
        
        // Note: In a real implementation, this should be sorted by performance score
    }
    
    /**
     * @notice Get markets requiring admin attention with pagination
     * @param startId Starting market ID
     * @param limit Maximum markets to return
     * @return marketIds Array of market IDs needing attention
     * @return reasons Array of reason codes (1=low_liquidity, 2=extreme_prices, 3=stalled)
     */
    function getMarketsRequiringAttention(uint256 startId, uint256 limit)
        external
        view
        returns (uint256[] memory marketIds, uint256[] memory reasons)
    {
        (MinimalMarketData[] memory markets, ) = getMinimalMarketsData(startId, limit);
        
        // Count markets needing attention
        uint256 attentionCount = 0;
        for (uint256 i = 0; i < markets.length; i++) {
            if (!markets[i].isValid) continue;
            
            MarketHealthMetrics memory health = calculateMarketHealth(markets[i]);
            if (health.hasLowLiquidity || health.hasExtremePrices || health.isStalled) {
                attentionCount++;
            }
        }
        
        marketIds = new uint256[](attentionCount);
        reasons = new uint256[](attentionCount);
        
        uint256 index = 0;
        for (uint256 i = 0; i < markets.length; i++) {
            if (!markets[i].isValid) continue;
            
            MarketHealthMetrics memory health = calculateMarketHealth(markets[i]);
            
            if (health.hasLowLiquidity || health.hasExtremePrices || health.isStalled) {
                marketIds[index] = startId + i;
                
                // Determine primary reason
                if (health.hasLowLiquidity) {
                    reasons[index] = 1; // Low liquidity
                } else if (health.hasExtremePrices) {
                    reasons[index] = 2; // Extreme prices
                } else if (health.isStalled) {
                    reasons[index] = 3; // Stalled
                }
                
                index++;
            }
        }
    }
    
    // ============ INTERNAL FUNCTIONS ============
    
    function _stringContains(string memory str, string memory substr)
        internal
        pure
        returns (bool)
    {
        bytes memory strBytes = bytes(str);
        bytes memory substrBytes = bytes(substr);
        
        if (substrBytes.length == 0) return true;
        if (strBytes.length < substrBytes.length) return false;
        
        // Simple contains check (case sensitive)
        for (uint256 i = 0; i <= strBytes.length - substrBytes.length; i++) {
            bool found = true;
            for (uint256 j = 0; j < substrBytes.length; j++) {
                if (strBytes[i + j] != substrBytes[j]) {
                    found = false;
                    break;
                }
            }
            if (found) return true;
        }
        
        return false;
    }
    
    function _inferCategory(string memory description)
        internal
        pure
        returns (string memory)
    {
        // Simple category inference based on keywords
        if (_stringContains(description, "Bitcoin") || _stringContains(description, "BTC")) {
            return "Crypto";
        } else if (_stringContains(description, "Football") || _stringContains(description, "Soccer")) {
            return "Sports";
        } else if (_stringContains(description, "Election") || _stringContains(description, "Politics")) {
            return "Politics";
        } else if (_stringContains(description, "Stock") || _stringContains(description, "Market")) {
            return "Finance";
        } else {
            return "Other";
        }
    }
    
    // ============ BACKWARD COMPATIBILITY ============
    
    /**
     * @notice Get all markets requiring attention (full scan)
     * @return marketIds Array of market IDs needing attention
     * @return reasons Array of reason codes
     */
    function getAllMarketsRequiringAttention()
        external
        view
        returns (uint256[] memory marketIds, uint256[] memory reasons)
    {
        uint256 marketCount = adapter.getMarketCount();
        return this.getMarketsRequiringAttention(1, marketCount);
    }
}
