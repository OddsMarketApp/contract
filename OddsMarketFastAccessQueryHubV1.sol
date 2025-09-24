// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./libraries/BaseQueryHubV2.sol";

/**
 * @title OddsMarketFastAccessQueryHubV1
 * @notice High-performance query hub optimized for frontend real-time rendering
 * @dev Specialized for fast, lightweight market queries with minimal gas consumption
 */
contract OddsMarketFastAccessQueryHubV1 is BaseQueryHubV2 {
    struct MarketCardData {
        uint256 marketId;
        string description;
        uint256[2] prices;
        uint256 totalLiquidityWei;
        uint256 totalVolumeWei;
        uint256 closingTime;
    }

    constructor(address _adapter) BaseQueryHubV2(_adapter) {}

    /**
     * @notice Returns active market IDs for a given category
     * @param category Category keyword (case-insensitive, e.g., "football")
     */
    function getActiveMarketIdsByCategory(string calldata category)
        external
        view
        returns (uint256[] memory activeMarketIds)
    {
        uint256 marketCount = adapter.getMarketCount();
        uint256[] memory tempIds = new uint256[](marketCount);
        uint256 count = 0;

        for (uint256 i = 1; i <= marketCount; i++) {
            MinimalMarketData memory data = getMinimalMarketData(i);
            if (!data.isValid) continue;

            if (_matchCategory(data, string(category)) && data.status == 1) {  // 1 = Active status
                tempIds[count] = i;
                count++;
            }
        }

        activeMarketIds = new uint256[](count);
        for (uint256 j = 0; j < count; j++) {
            activeMarketIds[j] = tempIds[j];
        }
    }

    /**
     * @notice Returns full market card data for active markets in the given category
     * @param category Category keyword
     */
    function getActiveMarketsByCategory(string calldata category)
        external
        view
        returns (MarketCardData[] memory marketsData)
    {
        uint256[] memory ids = _getActiveMarketIdsByCategory(category);
        marketsData = new MarketCardData[](ids.length);

        for (uint256 idx = 0; idx < ids.length; idx++) {
            uint256 marketId = ids[idx];
            MinimalMarketData memory data = getMinimalMarketData(marketId);
            marketsData[idx] = MarketCardData({
                marketId: marketId,
                description: data.title,
                prices: data.currentPrices,
                totalLiquidityWei: data.totalLiquidityWei,
                totalVolumeWei: data.totalVolumeWei,
                closingTime: data.closingTime
            });
        }
    }

    /**
     * @notice Returns top-N active markets by volume for given category (OPTIMIZED)
     * @param category Category keyword
     * @param limit Maximum number of markets to return
     */
    function getTopActiveMarketsByVolume(string calldata category, uint256 limit)
        external
        view
        returns (MarketCardData[] memory marketsData)
    {
        uint256[] memory ids = _getActiveMarketIdsByCategory(category);
        if (limit > ids.length) {
            limit = ids.length;
        }
        
        // Pre-load all market data to avoid repeated calls
        MinimalMarketData[] memory allData = new MinimalMarketData[](ids.length);
        for (uint256 i = 0; i < ids.length; i++) {
            allData[i] = getMinimalMarketData(ids[i]);
        }
        
        // Optimized sorting using selection sort (better for small arrays)
        for (uint256 i = 0; i < limit && i < ids.length; i++) {
            uint256 maxIdx = i;
            for (uint256 j = i + 1; j < ids.length; j++) {
                if (allData[j].totalVolumeWei > allData[maxIdx].totalVolumeWei) {
                    maxIdx = j;
                }
            }
            if (maxIdx != i) {
                // Swap both arrays
                uint256 tempId = ids[i];
                ids[i] = ids[maxIdx];
                ids[maxIdx] = tempId;
                
                MinimalMarketData memory tempData = allData[i];
                allData[i] = allData[maxIdx];
                allData[maxIdx] = tempData;
            }
        }
        
        marketsData = new MarketCardData[](limit);
        for (uint256 idx = 0; idx < limit; idx++) {
            marketsData[idx] = MarketCardData({
                marketId: ids[idx],
                description: allData[idx].title,
                prices: allData[idx].currentPrices,
                totalLiquidityWei: allData[idx].totalLiquidityWei,
                totalVolumeWei: allData[idx].totalVolumeWei,
                closingTime: allData[idx].closingTime
            });
        }
    }

    /**
     * @notice Returns recently resolved market IDs for given category
     * @param category Category keyword
     * @param limit Maximum number of markets to return
     */
    function getRecentResolvedMarketIds(string calldata category, uint256 limit)
        external
        view
        returns (uint256[] memory recentIds)
    {
        uint256 marketCount = adapter.getMarketCount();
        uint256[] memory tempIds = new uint256[](marketCount);
        uint256 count = 0;

        for (uint256 i = marketCount; i >= 1; i--) {
            MinimalMarketData memory data = getMinimalMarketData(i);
            if (!data.isValid) continue;
            if (_matchCategory(data, string(category)) && data.status == 3) {  // 3 = Resolved status
                tempIds[count] = i;
                count++;
                if (count == limit) break;
            }
            if (i == 1) break; // Avoid underflow
        }

        recentIds = new uint256[](count);
        for (uint256 j = 0; j < count; j++) {
            recentIds[j] = tempIds[j];
        }
    }

    function _matchCategory(MinimalMarketData memory data, string memory category) internal pure returns (bool) {
        return _stringContains(_toLower(data.title), _toLower(category));
    }

    function _stringContains(string memory str, string memory substr) 
        internal 
        pure 
        returns (bool) 
    {
        bytes memory strBytes = bytes(str);
        bytes memory substrBytes = bytes(substr);
        
        if (substrBytes.length == 0) return true;
        if (substrBytes.length > strBytes.length) return false;
        
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

    /**
     * @notice Internal version of getActiveMarketIdsByCategory to avoid external call overhead
     */
    function _getActiveMarketIdsByCategory(string memory category)
        internal
        view
        returns (uint256[] memory activeMarketIds)
    {
        uint256 marketCount = adapter.getMarketCount();
        uint256[] memory tempIds = new uint256[](marketCount);
        uint256 count = 0;

        for (uint256 i = 1; i <= marketCount; i++) {
            MinimalMarketData memory data = getMinimalMarketData(i);
            if (!data.isValid) continue;

            if (_matchCategory(data, category) && data.status == 1) {  // 1 = Active status
                tempIds[count] = i;
                count++;
            }
        }

        activeMarketIds = new uint256[](count);
        for (uint256 j = 0; j < count; j++) {
            activeMarketIds[j] = tempIds[j];
        }
    }

    function _toLower(string memory str) internal pure returns (string memory) {
        bytes memory bStr = bytes(str);
        for (uint256 i = 0; i < bStr.length; i++) {
            if ((uint8(bStr[i]) >= 65) && (uint8(bStr[i]) <= 90)) {
                bStr[i] = bytes1(uint8(bStr[i]) + 32);
            }
        }
        return string(bStr);
    }
}
