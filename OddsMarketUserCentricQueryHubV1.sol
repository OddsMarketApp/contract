// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./libraries/BaseQueryHubV2.sol";
import "./interfaces/IOddsMarketAdapter.sol";

/**
 * @title OddsMarketUserCentricQueryHubV1
 * @notice Comprehensive user position tracking and trading history query hub
 * @dev Specialized for user portfolio management, position tracking, and trading analytics
 */
contract OddsMarketUserCentricQueryHubV1 is BaseQueryHubV2 {
    
    // ============ USER DATA STRUCTURES ============
    
    struct UserTradingPosition {
        uint256 marketId;
        string marketTitle;
        uint256[2] shareBalances;        // [outcome0Shares, outcome1Shares]
        uint256 lpTokenBalance;
        uint256 totalSpentWei;
        uint256 currentValue;
        bool claimed;
        uint8 marketStatus;
        uint256 closingTime;
        bool outcomeSet;
        uint256 winningOutcome;
    }
    
    struct UserShareBalance {
        uint256 marketId;
        string marketTitle;
        uint256 outcome;
        uint256 shares;
        uint256 currentPrice;
        uint256 estimatedValue;
        bool canClaim;
        uint256 claimableAmount;
    }
    
    struct UserClaimableWinnings {
        uint256 marketId;
        string marketTitle;
        uint256 winningOutcome;
        uint256 userShares;
        uint256 claimableAmount;
        bool alreadyClaimed;
        uint256 payoutPerShare;
    }
    
    struct UserPortfolioSummary {
        uint256 totalPositions;
        uint256 totalInvestedWei;
        uint256 totalCurrentValueWei;
        uint256 totalClaimableWei;
        uint256 totalUnrealizedPnL;
        uint256 activeMarkets;
        uint256 claimableMarkets;
        UserTradingPosition[] positions;
    }
    
    struct UserTradingHistory {
        uint256 marketId;
        string marketTitle;
        uint256 timestamp;
        string actionType;              // "BUY", "SELL", "ADD_LIQUIDITY", "REMOVE_LIQUIDITY", "CLAIM"
        uint256 amount;
        uint256 shares;
        uint256 outcome;
        uint256 price;
        uint256 fees;
    }
    
    struct UserMarketParticipation {
        uint256 marketId;
        string marketTitle;
        uint256 firstParticipation;
        uint256 lastActivity;
        uint256 totalTrades;
        uint256 totalVolumeWei;
        bool hasActivePosition;
        bool hasClaimableWinnings;
    }
    
    // ============ CONSTRUCTOR ============
    
    constructor(address _adapter) BaseQueryHubV2(_adapter) {}
    
    // ============ MAIN FUNCTIONS ============
    
    /**
     * @notice Get user trading positions across all markets
     * @param user User address
     * @return positions Array of user trading positions
     */
    function getUserTradingPositions(address user)
        external
        view
        returns (UserTradingPosition[] memory positions)
    {
        require(user != address(0), "Invalid user address");
        
        uint256 marketCount = adapter.getMarketCount();
        
        // Temporary array to collect positions
        UserTradingPosition[] memory tempPositions = new UserTradingPosition[](marketCount);
        uint256 positionCount = 0;
        
        for (uint256 marketId = 1; marketId <= marketCount; marketId++) {
            UserTradingPosition memory position = _getUserPositionForMarket(user, marketId);
            
            // Include position if user has any involvement in the market
            if (position.shareBalances[0] > 0 || position.shareBalances[1] > 0 || 
                position.lpTokenBalance > 0 || position.totalSpentWei > 0) {
                tempPositions[positionCount] = position;
                positionCount++;
            }
        }
        
        // Create exact-size array
        positions = new UserTradingPosition[](positionCount);
        for (uint256 i = 0; i < positionCount; i++) {
            positions[i] = tempPositions[i];
        }
    }
    
    /**
     * @notice Get user share balances for specific markets
     * @param user User address
     * @param marketIds Array of market IDs
     * @return balances Array of user share balances
     */
    function getUserShareBalances(address user, uint256[] calldata marketIds)
        external
        view
        returns (UserShareBalance[] memory balances)
    {
        require(user != address(0), "Invalid user address");
        
        balances = new UserShareBalance[](marketIds.length * 2); // Max 2 outcomes per market
        uint256 balanceCount = 0;
        
        for (uint256 i = 0; i < marketIds.length; i++) {
            uint256 marketId = marketIds[i];
            MinimalMarketData memory data = getMinimalMarketData(marketId);
            
            if (!data.isValid) continue;
            
            // Check balances for both outcomes
            for (uint256 outcome = 0; outcome < 2; outcome++) {
                uint256 shares = _getUserShareBalance(user, marketId, outcome);
                
                if (shares > 0) {
                    UserShareBalance memory balance;
                    balance.marketId = marketId;
                    balance.marketTitle = data.title;
                    balance.outcome = outcome;
                    balance.shares = shares;
                    balance.currentPrice = data.currentPrices[outcome];
                    balance.estimatedValue = (shares * data.currentPrices[outcome]) / PRECISION_UNIT;
                    
                    // Check if market is resolved and user can claim
                    if (data.status == 3 && data.outcomeSet) { // RESOLVED = 3
                        balance.canClaim = (data.winningOutcome == outcome);
                        if (balance.canClaim) {
                            balance.claimableAmount = (shares * data.payoutPerShareWei) / PRECISION_UNIT;
                        }
                    }
                    
                    balances[balanceCount] = balance;
                    balanceCount++;
                }
            }
        }
        
        // Resize array to actual size
        assembly {
            mstore(balances, balanceCount)
        }
    }
    
    /**
     * @notice Get user claimable winnings from resolved markets
     * @param user User address
     * @return winnings Array of claimable winnings
     */
    function getUserClaimableWinnings(address user)
        external
        view
        returns (UserClaimableWinnings[] memory winnings)
    {
        require(user != address(0), "Invalid user address");
        
        uint256 marketCount = adapter.getMarketCount();
        
        // Temporary array to collect winnings
        UserClaimableWinnings[] memory tempWinnings = new UserClaimableWinnings[](marketCount);
        uint256 winningsCount = 0;
        
        for (uint256 marketId = 1; marketId <= marketCount; marketId++) {
            MinimalMarketData memory data = getMinimalMarketData(marketId);
            
            // Only check resolved markets
            if (!data.isValid || data.status != 3 || !data.outcomeSet) continue;
            
            uint256 winningOutcome = data.winningOutcome;
            uint256 userShares = _getUserShareBalance(user, marketId, winningOutcome);
            
            if (userShares > 0) {
                UserClaimableWinnings memory winning;
                winning.marketId = marketId;
                winning.marketTitle = data.title;
                winning.winningOutcome = winningOutcome;
                winning.userShares = userShares;
                winning.payoutPerShare = data.payoutPerShareWei;
                winning.claimableAmount = (userShares * data.payoutPerShareWei) / PRECISION_UNIT;
                
                // Check if already claimed (simplified check)
                try adapter.getUserPosition(user, marketId) returns (IOddsMarketAdapter.StableUserPosition memory userPos, bool success) {
                    if (success) {
                        winning.alreadyClaimed = userPos.claimed;
                    }
                } catch {
                    // Assume not claimed if check fails
                    winning.alreadyClaimed = false;
                }
                
                tempWinnings[winningsCount] = winning;
                winningsCount++;
            }
        }
        
        // Create exact-size array
        winnings = new UserClaimableWinnings[](winningsCount);
        for (uint256 i = 0; i < winningsCount; i++) {
            winnings[i] = tempWinnings[i];
        }
    }
    
    /**
     * @notice Get comprehensive user portfolio summary
     * @param user User address
     * @return summary Complete portfolio overview
     */
    function getUserPortfolioSummary(address user)
        external
        view
        returns (UserPortfolioSummary memory summary)
    {
        require(user != address(0), "Invalid user address");
        
        // Get all user positions
        UserTradingPosition[] memory positions = this.getUserTradingPositions(user);
        summary.positions = positions;
        summary.totalPositions = positions.length;
        
        // Calculate aggregated metrics
        for (uint256 i = 0; i < positions.length; i++) {
            UserTradingPosition memory position = positions[i];
            
            summary.totalInvestedWei += position.totalSpentWei;
            summary.totalCurrentValueWei += position.currentValue;
            
            if (position.marketStatus == 1) { // ACTIVE
                summary.activeMarkets++;
            } else if (position.marketStatus == 3 && position.outcomeSet && !position.claimed) { // RESOLVED
                summary.claimableMarkets++;
                // Calculate claimable amount
                if (position.shareBalances[position.winningOutcome] > 0) {
                    MinimalMarketData memory data = getMinimalMarketData(position.marketId);
                    if (data.isValid) {
                        uint256 claimable = (position.shareBalances[position.winningOutcome] * data.payoutPerShareWei) / PRECISION_UNIT;
                        summary.totalClaimableWei += claimable;
                    }
                }
            }
        }
        
        // Calculate unrealized PnL
        if (summary.totalCurrentValueWei >= summary.totalInvestedWei) {
            summary.totalUnrealizedPnL = summary.totalCurrentValueWei - summary.totalInvestedWei;
        } else {
            // Handle negative PnL (store as complement for simplicity)
            summary.totalUnrealizedPnL = summary.totalInvestedWei - summary.totalCurrentValueWei;
        }
    }
    
    /**
     * @notice Get user trading history (simplified version based on current state)
     * @param user User address
     * @param limit Maximum number of records
     * @return history Array of trading history records
     */
    function getUserTradingHistory(address user, uint256 limit)
        external
        view
        returns (UserTradingHistory[] memory history)
    {
        require(user != address(0), "Invalid user address");
        
        // Note: This is a simplified implementation based on current positions
        // In a full implementation, this would require event log analysis
        UserTradingPosition[] memory positions = this.getUserTradingPositions(user);
        
        uint256 recordCount = positions.length > limit ? limit : positions.length;
        history = new UserTradingHistory[](recordCount);
        
        for (uint256 i = 0; i < recordCount; i++) {
            UserTradingPosition memory position = positions[i];
            
            // Create a representative trading record
            UserTradingHistory memory record;
            record.marketId = position.marketId;
            record.marketTitle = position.marketTitle;
            record.timestamp = position.closingTime - 86400; // Estimate as 1 day before closing
            
            // Determine primary action based on position
            if (position.lpTokenBalance > 0) {
                record.actionType = "ADD_LIQUIDITY";
                record.amount = position.totalSpentWei;
            } else if (position.shareBalances[0] > position.shareBalances[1]) {
                record.actionType = "BUY";
                record.outcome = 0;
                record.shares = position.shareBalances[0];
            } else if (position.shareBalances[1] > 0) {
                record.actionType = "BUY";
                record.outcome = 1;
                record.shares = position.shareBalances[1];
            }
            
            record.amount = position.totalSpentWei;
            // Estimate average price
            if (record.shares > 0) {
                record.price = (position.totalSpentWei * PRECISION_UNIT) / record.shares;
            }
            
            history[i] = record;
        }
    }
    
    /**
     * @notice Get user market participation summary
     * @param user User address
     * @return participation Array of market participation records
     */
    function getUserMarketParticipation(address user)
        external
        view
        returns (UserMarketParticipation[] memory participation)
    {
        require(user != address(0), "Invalid user address");
        
        UserTradingPosition[] memory positions = this.getUserTradingPositions(user);
        participation = new UserMarketParticipation[](positions.length);
        
        for (uint256 i = 0; i < positions.length; i++) {
            UserTradingPosition memory position = positions[i];
            
            UserMarketParticipation memory record;
            record.marketId = position.marketId;
            record.marketTitle = position.marketTitle;
            record.firstParticipation = position.closingTime - 86400; // Estimate
            record.lastActivity = position.closingTime - 3600; // Estimate
            record.totalTrades = 1; // Simplified
            record.totalVolumeWei = position.totalSpentWei;
            record.hasActivePosition = (position.shareBalances[0] > 0 || position.shareBalances[1] > 0 || position.lpTokenBalance > 0);
            record.hasClaimableWinnings = (position.marketStatus == 3 && position.outcomeSet && !position.claimed);
            
            participation[i] = record;
        }
    }
    
    // ============ INTERNAL HELPER FUNCTIONS ============
    
    /**
     * @notice Get user position for a specific market
     * @param user User address
     * @param marketId Market ID
     * @return position User trading position
     */
    function _getUserPositionForMarket(address user, uint256 marketId)
        internal
        view
        returns (UserTradingPosition memory position)
    {
        position.marketId = marketId;
        
        // Get market data
        MinimalMarketData memory data = getMinimalMarketData(marketId);
        if (!data.isValid) return position;
        
        position.marketTitle = data.title;
        position.marketStatus = data.status;
        position.closingTime = data.closingTime;
        position.outcomeSet = data.outcomeSet;
        position.winningOutcome = data.winningOutcome;
        
        // Get user share balances for both outcomes
        position.shareBalances[0] = _getUserShareBalance(user, marketId, 0);
        position.shareBalances[1] = _getUserShareBalance(user, marketId, 1);
        
        // Get LP token balance via adapter
        try adapter.getUserPosition(user, marketId) returns (IOddsMarketAdapter.StableUserPosition memory userPos, bool success) {
            if (success) {
                position.lpTokenBalance = userPos.lpTokens;
                position.totalSpentWei = userPos.totalSpentWei;
                position.claimed = userPos.claimed;
            }
        } catch {
            // Use fallback calculations if adapter fails
            position.lpTokenBalance = 0;
        }
        
        // Calculate current value
        position.currentValue = 
            (position.shareBalances[0] * data.currentPrices[0] + 
             position.shareBalances[1] * data.currentPrices[1]) / PRECISION_UNIT;
        
        // Add LP token value estimate
        if (position.lpTokenBalance > 0 && data.lpTokenSupply > 0) {
            position.currentValue += (data.principalAmountWei * position.lpTokenBalance) / data.lpTokenSupply;
        }
    }
    
    /**
     * @notice Get user share balance for specific market and outcome
     * @param user User address
     * @param marketId Market ID
     * @param outcome Outcome (0 or 1)
     * @return shares Share balance
     */
    function _getUserShareBalance(address user, uint256 marketId, uint256 outcome)
        internal
        view
        returns (uint256 shares)
    {
        // Prefer adapter to expose share balances; until then, resolve main contract via adapter
        // and query ERC1155 balanceOf(address,uint256) on the market contract.
        uint256 shareTokenId = _getShareTokenId(marketId, outcome);

        // Resolve underlying market contract address from adapter configuration
        (address marketContract, ) = adapter.getConfiguration();

        if (marketContract == address(0)) {
            return 0;
        }

        // Perform safe static call to market.balanceOf(address,uint256)
        (bool success, bytes memory result) = marketContract.staticcall(
            abi.encodeWithSelector(bytes4(keccak256("balanceOf(address,uint256)")), user, shareTokenId)
        );

        if (success && result.length >= 32) {
            shares = abi.decode(result, (uint256));
        } else {
            shares = 0;
        }
    }
    
    /**
     * @notice Health check for the contract
     * @return healthy Whether the contract is functioning properly
     * @return marketCount Current market count
     */
    function getHealth() external view returns (bool healthy, uint256 marketCount) {
        try adapter.getHealth() returns (bool adapterHealthy, uint256 count) {
            return (adapterHealthy, count);
        } catch {
            return (false, 0);
        }
    }
}
