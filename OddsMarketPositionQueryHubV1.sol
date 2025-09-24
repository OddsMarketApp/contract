// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./libraries/BaseQueryHubV2.sol";
import "./interfaces/IOddsMarketAdapter.sol";

/**
 * @title OddsMarketPositionQueryHubV1
 * @notice Advanced trading position analysis and classification query hub
 * @dev Uses BaseQueryHubV2 adapter pattern to stay ABI-independent from main contracts
 */
contract OddsMarketPositionQueryHubV1 is BaseQueryHubV2 {

    // ============ CONSTANTS ============
    uint256 private constant SHARE_UNIT = 1e18;
    uint256 private constant MAX_MARKETS_PER_BATCH = 50;

    // ============ STRUCTS ============
    struct TradingPosition {
        uint256 marketId;
        string marketTitle;
        uint256 sharesOptionA;
        uint256 sharesOptionB;
        uint256 totalSpentWei;
        uint256 estimatedValueWei;
        uint256 potentialClaimWei;
        uint256 closingTime;
        uint8 marketStatus;          // 1=Active, 2=Closed, 3=Resolved
        bool outcomeSet;
        uint256 winningOutcome;      // 0 or 1
        uint256 payoutPerShareWei;
        bool alreadyClaimed;
        bool hasLPPosition;
        bool hasTradingPosition;

        PositionType positionType;
        uint256 lpTokenBalance;
        bool isHybridPosition;
        uint256 tradingConfidence;
        string positionSource;
    }

    enum PositionType {
        NONE,
        TRADING_ONLY,
        LP_ONLY,
        HYBRID
    }

    struct PortfolioSummary {
        uint256 totalPositions;
        uint256 totalInvestedWei;
        uint256 totalEstimatedValueWei;
        uint256 totalClaimableWei;
        uint256 activePositionsCount;
        uint256 closedPositionsCount;
        uint256 settledPositionsCount;

        uint256 tradingOnlyCount;
        uint256 lpOnlyCount;
        uint256 hybridPositionsCount;
        uint256 totalLPTokenSum;  // Fixed: Renamed from totalLPValueWei to reflect actual content (token count, not Wei value)

        TradingPosition[] positions;
    }

    struct ClassifiedPositions {
        TradingPosition[] activePositions;
        TradingPosition[] closedPositions;
        TradingPosition[] settledPositions;
    }

    // ============ CONSTRUCTOR ============
    constructor(address _adapter) BaseQueryHubV2(_adapter) {}

    // ============ MAIN QUERY FUNCTIONS ============

    function getUserTradingPortfolio(address user) external view returns (PortfolioSummary memory summary) {
        require(user != address(0), "Invalid user address");

        uint256 marketCount = adapter.getMarketCount();
        if (marketCount == 0) return summary;

        // Pass 1: count up to MAX_MARKETS_PER_BATCH
        uint256 positionCount = 0;
        for (uint256 marketId = 1; marketId <= marketCount; marketId++) {
            if (_hasAnyPosition(user, marketId)) {
                positionCount++;
                if (positionCount >= MAX_MARKETS_PER_BATCH) break; // circuit breaker
            }
        }

        summary.positions = new TradingPosition[](positionCount);

        // Pass 2: fill
        uint256 index = 0;
        for (uint256 marketId = 1; marketId <= marketCount && index < positionCount; marketId++) {
            TradingPosition memory pos = _analyzeEnhancedPosition(user, marketId);
            if (_shouldIncludePosition(pos)) {
                summary.positions[index] = pos;
                _updatePortfolioSummary(summary, pos);
                index++;
            }
        }

        summary.totalPositions = index;
    }

    function getClassifiedTradingPositions(address user) external view returns (ClassifiedPositions memory classified) {
        PortfolioSummary memory portfolio = this.getUserTradingPortfolio(user);

        uint256 activeCount = 0;
        uint256 closedCount = 0;
        uint256 settledCount = 0;

        for (uint256 i = 0; i < portfolio.positions.length; i++) {
            TradingPosition memory pos = portfolio.positions[i];
            if (pos.marketStatus == 1) activeCount++;
            else if (pos.marketStatus == 2) closedCount++;
            else if (pos.marketStatus == 3) settledCount++;
        }

        classified.activePositions = new TradingPosition[](activeCount);
        classified.closedPositions = new TradingPosition[](closedCount);
        classified.settledPositions = new TradingPosition[](settledCount);

        uint256 a = 0; uint256 c = 0; uint256 s = 0;
        for (uint256 i = 0; i < portfolio.positions.length; i++) {
            TradingPosition memory pos = portfolio.positions[i];
            if (pos.marketStatus == 1) classified.activePositions[a++] = pos;
            else if (pos.marketStatus == 2) classified.closedPositions[c++] = pos;
            else if (pos.marketStatus == 3) classified.settledPositions[s++] = pos;
        }
    }

    function getPositionsByType(address user, PositionType positionType) external view returns (TradingPosition[] memory positions) {
        PortfolioSummary memory portfolio = this.getUserTradingPortfolio(user);

        uint256 count = 0;
        for (uint256 i = 0; i < portfolio.positions.length; i++) {
            if (portfolio.positions[i].positionType == positionType) count++;
        }

        positions = new TradingPosition[](count);
        uint256 idx = 0;
        for (uint256 i = 0; i < portfolio.positions.length; i++) {
            if (portfolio.positions[i].positionType == positionType) {
                positions[idx++] = portfolio.positions[i];
            }
        }
    }

    /**
     * Only pure trading (no LP) positions
     */
    function getPureTradingPositions(address user) external view returns (TradingPosition[] memory positions) {
        require(user != address(0), "Invalid user address");

        uint256 marketCount = adapter.getMarketCount();

        // Pass 1: count
        uint256 pureCount = 0;
        for (uint256 marketId = 1; marketId <= marketCount; marketId++) {
            (IOddsMarketAdapter.StableUserPosition memory up, ) = adapter.getUserPosition(user, marketId);
            if (up.lpTokens > 0) continue;
            uint256 sharesA = _getUserShareBalance(user, marketId, 0);
            uint256 sharesB = _getUserShareBalance(user, marketId, 1);
            if (sharesA > 0 || sharesB > 0) pureCount++;
        }

        positions = new TradingPosition[](pureCount);
        if (pureCount == 0) return positions;

        // Pass 2: fill
        uint256 index = 0;
        for (uint256 marketId = 1; marketId <= marketCount && index < pureCount; marketId++) {
            (IOddsMarketAdapter.StableUserPosition memory up2, ) = adapter.getUserPosition(user, marketId);
            if (up2.lpTokens > 0) continue;

            uint256 sharesA2 = _getUserShareBalance(user, marketId, 0);
            uint256 sharesB2 = _getUserShareBalance(user, marketId, 1);
            if (sharesA2 == 0 && sharesB2 == 0) continue;

            (IOddsMarketAdapter.StableMarketData memory m, ) = adapter.getStableMarketData(marketId);

            positions[index] = TradingPosition({
                marketId: marketId,
                marketTitle: m.title,
                sharesOptionA: sharesA2,
                sharesOptionB: sharesB2,
                totalSpentWei: up2.totalSpentWei,
                estimatedValueWei: 0,
                potentialClaimWei: _calculateClaimAmount(sharesA2, sharesB2, m.status, m.outcomeSet, m.winningOutcome, m.payoutPerShareWei),
                closingTime: m.closingTime,
                marketStatus: m.status,
                outcomeSet: m.outcomeSet,
                winningOutcome: m.winningOutcome,
                payoutPerShareWei: m.payoutPerShareWei,
                alreadyClaimed: up2.claimed,
                hasLPPosition: false,
                hasTradingPosition: true,
                positionType: PositionType.TRADING_ONLY,
                lpTokenBalance: 0,
                isHybridPosition: false,
                tradingConfidence: _calculateTradingConfidence(sharesA2, sharesB2),
                positionSource: "pure_trading_shares"
            });
            _calculatePositionValues(positions[index]);
            index++;
        }
    }

    /**
     * Only claimable rewards (resolved markets, pure trading)
     */
    function getClaimableRewardsOnly(address user) external view returns (TradingPosition[] memory positions) {
        require(user != address(0), "Invalid user address");

        uint256 marketCount = adapter.getMarketCount();
        uint256 claimableCount = 0;

        // Pass 1: count
        for (uint256 marketId = 1; marketId <= marketCount; marketId++) {
            (IOddsMarketAdapter.StableUserPosition memory up, ) = adapter.getUserPosition(user, marketId);
            if (up.claimed || up.lpTokens > 0) continue;
            (IOddsMarketAdapter.StableMarketData memory m, ) = adapter.getStableMarketData(marketId);
            if (m.status != 3 || !m.outcomeSet) continue;
            uint256 winningShares = _getUserShareBalance(user, marketId, m.winningOutcome);
            if (winningShares > 0 && m.payoutPerShareWei > 0) claimableCount++;
        }

        positions = new TradingPosition[](claimableCount);
        if (claimableCount == 0) return positions;

        // Pass 2: fill
        uint256 index = 0;
        for (uint256 marketId = 1; marketId <= marketCount && index < claimableCount; marketId++) {
            (IOddsMarketAdapter.StableUserPosition memory up2, ) = adapter.getUserPosition(user, marketId);
            if (up2.claimed || up2.lpTokens > 0) continue;
            (IOddsMarketAdapter.StableMarketData memory m2, ) = adapter.getStableMarketData(marketId);
            if (m2.status != 3 || !m2.outcomeSet) continue;

            uint256 sharesA = _getUserShareBalance(user, marketId, 0);
            uint256 sharesB = _getUserShareBalance(user, marketId, 1);
            uint256 winningShares2 = m2.winningOutcome == 0 ? sharesA : sharesB;
            if (winningShares2 == 0 || m2.payoutPerShareWei == 0) continue;

            uint256 claimAmount = (winningShares2 * m2.payoutPerShareWei) / SHARE_UNIT;

            positions[index] = TradingPosition({
                marketId: marketId,
                marketTitle: m2.title,
                sharesOptionA: sharesA,
                sharesOptionB: sharesB,
                totalSpentWei: up2.totalSpentWei,
                estimatedValueWei: claimAmount,
                potentialClaimWei: claimAmount,
                closingTime: m2.closingTime,
                marketStatus: m2.status,
                outcomeSet: m2.outcomeSet,
                winningOutcome: m2.winningOutcome,
                payoutPerShareWei: m2.payoutPerShareWei,
                alreadyClaimed: up2.claimed,
                hasLPPosition: false,
                hasTradingPosition: true,
                positionType: PositionType.TRADING_ONLY,
                lpTokenBalance: 0,
                isHybridPosition: false,
                tradingConfidence: 100,
                positionSource: "claimable_rewards_only"
            });
            index++;
        }
    }

    /**
     * All trading shares (pure + mixed LP)
     */
    function getAllTradingShares(address user) external view returns (TradingPosition[] memory positions) {
        require(user != address(0), "Invalid user address");

        uint256 marketCount = adapter.getMarketCount();
        uint256 tradingCount = 0;

        for (uint256 marketId = 1; marketId <= marketCount; marketId++) {
            uint256 s0 = _getUserShareBalance(user, marketId, 0);
            uint256 s1 = _getUserShareBalance(user, marketId, 1);
            if (s0 > 0 || s1 > 0) tradingCount++;
        }

        positions = new TradingPosition[](tradingCount);
        if (tradingCount == 0) return positions;

        uint256 index = 0;
        for (uint256 marketId = 1; marketId <= marketCount && index < tradingCount; marketId++) {
            uint256 sharesA = _getUserShareBalance(user, marketId, 0);
            uint256 sharesB = _getUserShareBalance(user, marketId, 1);
            if (sharesA == 0 && sharesB == 0) continue;

            (IOddsMarketAdapter.StableUserPosition memory up, ) = adapter.getUserPosition(user, marketId);
            (IOddsMarketAdapter.StableMarketData memory m, ) = adapter.getStableMarketData(marketId);

            bool hasLP = up.lpTokens > 0;
            PositionType posType = hasLP ? PositionType.HYBRID : PositionType.TRADING_ONLY;

            positions[index] = TradingPosition({
                marketId: marketId,
                marketTitle: m.title,
                sharesOptionA: sharesA,
                sharesOptionB: sharesB,
                totalSpentWei: up.totalSpentWei,
                estimatedValueWei: 0,
                potentialClaimWei: _calculateClaimAmount(sharesA, sharesB, m.status, m.outcomeSet, m.winningOutcome, m.payoutPerShareWei),
                closingTime: m.closingTime,
                marketStatus: m.status,
                outcomeSet: m.outcomeSet,
                winningOutcome: m.winningOutcome,
                payoutPerShareWei: m.payoutPerShareWei,
                alreadyClaimed: up.claimed,
                hasLPPosition: hasLP,
                hasTradingPosition: true,
                positionType: posType,
                lpTokenBalance: up.lpTokens,
                isHybridPosition: hasLP,
                tradingConfidence: _calculateTradingConfidence(sharesA, sharesB),
                positionSource: hasLP ? "mixed_trading_and_lp" : "pure_trading_shares"
            });
            _calculatePositionValues(positions[index]);
            index++;
        }
    }

    // ============ INTERNAL ANALYSIS ============

    function _analyzeEnhancedPosition(address user, uint256 marketId) internal view returns (TradingPosition memory position) {
        position.marketId = marketId;

        // Market metadata
        (IOddsMarketAdapter.StableMarketData memory m, bool ok) = adapter.getStableMarketData(marketId);
        if (!ok) {
            position.positionSource = "market-data-failed";
            return position;
        }

        position.marketTitle = m.title;
        position.closingTime = m.closingTime;
        position.marketStatus = m.status;
        position.outcomeSet = m.outcomeSet;
        position.winningOutcome = m.winningOutcome;
        position.payoutPerShareWei = m.payoutPerShareWei;

        // User data
        (IOddsMarketAdapter.StableUserPosition memory up, bool ok2) = adapter.getUserPosition(user, marketId);
        if (!ok2) {
            position.positionSource = "position-data-failed";
            return position;
        }

        position.totalSpentWei = up.totalSpentWei;
        position.alreadyClaimed = up.claimed;
        position.lpTokenBalance = up.lpTokens;

        // Token balances
        position.sharesOptionA = _getUserShareBalance(user, marketId, 0);
        position.sharesOptionB = _getUserShareBalance(user, marketId, 1);

        // LP token balance cross-validate (optional, we already have up.lpTokens)
        uint256 actualLPBalance = _getUserLpTokenBalance(user, marketId);

        // Classification
        position = _classifyPositionType(position, actualLPBalance);

        // Derived values
        _calculatePositionValues(position);
    }

    function _classifyPositionType(TradingPosition memory position, uint256 actualLPBalance) internal pure returns (TradingPosition memory) {
        uint256 totalShares = position.sharesOptionA + position.sharesOptionB;
        bool hasShares = totalShares > 0;
        bool hasSpent = position.totalSpentWei > 0;
        bool hasLP = actualLPBalance > 0;

        bool lpBalanceConsistent = (position.lpTokenBalance == actualLPBalance);

        if (hasLP && hasShares && hasSpent) {
            position.positionType = PositionType.HYBRID;
            position.isHybridPosition = true;
            position.hasLPPosition = true;
            position.hasTradingPosition = true;
            position.tradingConfidence = 95;
            position.positionSource = "hybrid-multi-validation";
        } else if (hasShares && hasSpent && !hasLP) {
            position.positionType = PositionType.TRADING_ONLY;
            position.isHybridPosition = false;
            position.hasLPPosition = false;
            position.hasTradingPosition = true;
            position.tradingConfidence = 90;
            position.positionSource = "trading-pure-validation";
        } else if (hasLP && !hasSpent && !hasShares) {
            position.positionType = PositionType.LP_ONLY;
            position.isHybridPosition = false;
            position.hasLPPosition = true;
            position.hasTradingPosition = false;
            position.tradingConfidence = 0;
            position.positionSource = "lp-pure-validation";
        } else if (hasShares && !hasSpent && !hasLP) {
            position.positionType = PositionType.TRADING_ONLY;
            position.isHybridPosition = false;
            position.hasLPPosition = false;
            position.hasTradingPosition = true;
            position.tradingConfidence = 60;
            position.positionSource = "trading-shares-only-suspicious";
        } else if (!hasShares && !hasSpent && hasLP) {
            position.positionType = PositionType.LP_ONLY;
            position.isHybridPosition = false;
            position.hasLPPosition = true;
            position.hasTradingPosition = false;
            position.tradingConfidence = 0;
            position.positionSource = "lp-tokens-only";
        } else {
            position.positionType = PositionType.NONE;
            position.isHybridPosition = false;
            position.hasLPPosition = hasLP;
            position.hasTradingPosition = false;
            position.tradingConfidence = 0;
            position.positionSource = "no-clear-position";
        }

        if (!lpBalanceConsistent) {
            position.positionSource = string(abi.encodePacked(position.positionSource, "-lp-inconsistent"));
        }

        return position;
    }

    function _calculatePositionValues(TradingPosition memory position) internal view {
        if (position.sharesOptionA > 0 || position.sharesOptionB > 0) {
            (uint256[2] memory prices, bool success) = adapter.getMarketPrices(position.marketId);
            if (success) {
                position.estimatedValueWei =
                    (position.sharesOptionA * prices[0] + position.sharesOptionB * prices[1]) / PRECISION_UNIT;
            } else {
                uint256 totalShares = position.sharesOptionA + position.sharesOptionB;
                position.estimatedValueWei = totalShares / 2; // Fallback: assume avg price 0.5
            }
        } else {
            position.estimatedValueWei = 0;
        }

        if (position.marketStatus == 3 && position.outcomeSet && !position.alreadyClaimed) {
            uint256 winningShares = position.winningOutcome == 0
                ? position.sharesOptionA
                : position.sharesOptionB;
            position.potentialClaimWei = (winningShares * position.payoutPerShareWei) / SHARE_UNIT;
        }
    }

    function _hasAnyPosition(address user, uint256 marketId) internal view returns (bool) {
        (IOddsMarketAdapter.StableUserPosition memory up, bool ok) = adapter.getUserPosition(user, marketId);
        if (ok && (up.lpTokens > 0 || up.totalSpentWei > 0)) return true;

        // Fallback check: shares balances
        uint256 s0 = _getUserShareBalance(user, marketId, 0);
        if (s0 > 0) return true;
        uint256 s1 = _getUserShareBalance(user, marketId, 1);
        if (s1 > 0) return true;

        return false;
    }

    function _shouldIncludePosition(TradingPosition memory position) internal pure returns (bool) {
        return position.positionType == PositionType.TRADING_ONLY ||
               position.positionType == PositionType.HYBRID;
    }

    function _updatePortfolioSummary(PortfolioSummary memory summary, TradingPosition memory position) internal pure {
        if (position.marketStatus == 1) summary.activePositionsCount++;
        else if (position.marketStatus == 2) summary.closedPositionsCount++;
        else if (position.marketStatus == 3) summary.settledPositionsCount++;

        if (position.positionType == PositionType.TRADING_ONLY) summary.tradingOnlyCount++;
        else if (position.positionType == PositionType.LP_ONLY) summary.lpOnlyCount++;
        else if (position.positionType == PositionType.HYBRID) summary.hybridPositionsCount++;

        summary.totalInvestedWei += position.totalSpentWei;
        summary.totalEstimatedValueWei += position.estimatedValueWei;
        summary.totalClaimableWei += position.potentialClaimWei;

        if (position.hasLPPosition) {
            summary.totalLPTokenSum += position.lpTokenBalance;  // Fixed: Updated to use corrected field name
        }
    }

    function _calculateClaimAmount(
        uint256 sharesA,
        uint256 sharesB,
        uint8 status,
        bool outcomeSet,
        uint256 winningOutcome,
        uint256 payoutPerShareWei
    ) internal pure returns (uint256) {
        if (status != 3 || !outcomeSet || payoutPerShareWei == 0) return 0;
        uint256 winningShares = (winningOutcome == 0) ? sharesA : sharesB;
        return (winningShares * payoutPerShareWei) / SHARE_UNIT;
    }

    function _calculateTradingConfidence(uint256 sharesA, uint256 sharesB) internal pure returns (uint256) {
        uint256 totalShares = sharesA + sharesB;
        if (totalShares == 0) return 0;
        if (totalShares >= SHARE_UNIT) return 100;
        return 50 + ((totalShares * 50) / SHARE_UNIT);
    }

    // ============ LOW-LEVEL HELPERS ============

    function _getUserShareBalance(address user, uint256 marketId, uint256 outcome) internal view returns (uint256 shares) {
        (address marketAddr, ) = adapter.getConfiguration();
        if (marketAddr == address(0)) return 0;

        uint256 tokenId = _getShareTokenId(marketId, outcome);
        (bool ok, bytes memory result) = marketAddr.staticcall(
            abi.encodeWithSelector(bytes4(keccak256("balanceOf(address,uint256)")), user, tokenId)
        );
        if (ok && result.length >= 32) {
            shares = abi.decode(result, (uint256));
        } else {
            shares = 0;
        }
    }

    function _getUserLpTokenBalance(address user, uint256 marketId) internal view returns (uint256 balance) {
        (address marketAddr, ) = adapter.getConfiguration();
        if (marketAddr == address(0)) return 0;

        uint256 lpTokenId = _getLPTokenId(marketId);
        (bool ok, bytes memory result) = marketAddr.staticcall(
            abi.encodeWithSelector(bytes4(keccak256("balanceOf(address,uint256)")), user, lpTokenId)
        );
        if (ok && result.length >= 32) {
            balance = abi.decode(result, (uint256));
        } else {
            balance = 0;
        }
    }

    // ============ SYSTEM HEALTH ============

    function getSystemHealth() public view override returns (bool healthy, uint256 marketCount, string memory adapterVersion) {
        (healthy, marketCount) = adapter.getHealth();
        (, adapterVersion) = adapter.getConfiguration();
    }
}
