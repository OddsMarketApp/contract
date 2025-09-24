// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./libraries/BaseQueryHubV2.sol";
import "./interfaces/IOddsMarketAdapter.sol";

// No additional interface needed - inheriting from BaseQueryHub

/**
 * @title OddsMarketLiquidityQueryHubV1
 * @notice Liquidity provider analytics and LP position management query hub
 * @dev Specialized for LP token tracking, fee analysis, and liquidity optimization
 * 
 * IMPORTANT: LP value calculations use principalAmountWei linear estimation.
 * Actual LP values may differ based on market conditions and impermanent loss.
 */
contract OddsMarketLiquidityQueryHubV1 is BaseQueryHubV2 {
    
    struct LPPosition {
        uint256 marketId;
        string marketTitle;
        uint256 lpTokenBalance;
        uint256 liquidityValue;
        uint256 feesEarned;
        uint8 marketStatus;
        bool hasPosition;
        uint256 closingTime;
        bool outcomeSet;
    }
    
    struct UserSummary {
        uint256 totalPositions;
        uint256 totalLiquidityValue;
        uint256 totalFeesEarned;
        LPPosition[] positions;
    }
    
    constructor(address _adapter) BaseQueryHubV2(_adapter) {}
    
    /**
     * @notice 获取用户所有LP头寸
     */
    function getUserLPSummary(address user) external view returns (UserSummary memory summary) {
        require(user != address(0), "Invalid user address");
        
        uint256 marketCount;
        try adapter.getMarketCount() returns (uint256 count) {
            marketCount = count;
        } catch {
            return summary; // Return empty summary on error
        }
        
        // Temporary array for positions
        LPPosition[] memory tempPositions = new LPPosition[](marketCount);
        uint256 positionCount = 0;
        
        // Scan all markets for LP positions
        for (uint256 marketId = 1; marketId <= marketCount; marketId++) {
            LPPosition memory position = _getUserLPPosition(user, marketId);
            if (position.hasPosition) {
                tempPositions[positionCount] = position;
                positionCount++;
                summary.totalLiquidityValue += position.liquidityValue;
                summary.totalFeesEarned += position.feesEarned;
            }
        }
        
        summary.totalPositions = positionCount;
        
        // Create exact-size array
        summary.positions = new LPPosition[](positionCount);
        for (uint256 i = 0; i < positionCount; i++) {
            summary.positions[i] = tempPositions[i];
        }
    }
    
    /**
     * @notice 获取单个市场的LP头寸
     */
    function getUserLPPosition(address user, uint256 marketId) external view returns (LPPosition memory) {
        require(user != address(0), "Invalid user address");
        require(marketId > 0, "Invalid market ID");
        
        return _getUserLPPosition(user, marketId);
    }
    
    /**
     * @notice Internal function to get LP position with robust error handling
     */
    function _getUserLPPosition(address user, uint256 marketId) internal view returns (LPPosition memory position) {
        position.marketId = marketId;
        
        // Get market basic information using BaseQueryHub method
        MinimalMarketData memory data = getMinimalMarketData(marketId);
        
        if (!data.isValid) {
            return position; // Return empty position if market data invalid
        }
        
        position.marketTitle = data.title;
        position.marketStatus = data.status;
        position.closingTime = data.closingTime;
        position.outcomeSet = data.outcomeSet;
        
        // Get user position via adapter
        try adapter.getUserPosition(user, marketId) returns (IOddsMarketAdapter.StableUserPosition memory userPos, bool success) {
            if (success && userPos.lpTokens > 0) {
                position.lpTokenBalance = userPos.lpTokens;
                position.hasPosition = true;
                
                // Get LP token supply from market data
                uint256 lpTokenSupply = data.lpTokenSupply;
                if (lpTokenSupply > 0) {
                    // Calculate liquidity value using principal amount
                    position.liquidityValue = (data.principalAmountWei * userPos.lpTokens) / lpTokenSupply;
                    
                    // Calculate fee earnings using fees amount
                    position.feesEarned = (data.feesAmountWei * userPos.lpTokens) / lpTokenSupply;
                }
            }
        } catch {
            // Position remains with hasPosition = false
        }
    }
    
    /**
     * @notice 健康检查
     */
    function getHealth() external view returns (bool healthy, uint256 marketCount) {
        try adapter.getMarketCount() returns (uint256 count) {
            return (true, count);
        } catch {
            return (false, 0);
        }
    }
}
