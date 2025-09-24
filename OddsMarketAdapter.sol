// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title OddsMarketAdapter
 * @notice Lightweight adapter for isolating QueryHub from main contract ABI changes
 * @dev Provides stable interface that QueryHub can depend on, regardless of main contract evolution
 */
contract OddsMarketAdapter {
    
    // ============ EVENTS ============
    
    event MainContractUpdated(address indexed oldContract, address indexed newContract);
    
    // ============ CONSTANTS ============
    
    uint256 public constant PRECISION_UNIT = 1e18;
    
    // ============ STATE VARIABLES ============
    
    address public owner;
    address public mainContract;
    string public contractVersion; // "lmsr" or "zero"
    
    // ============ STABLE DATA STRUCTURES ============
    
    /**
     * @notice Stable market data structure for QueryHub consumption
     * @dev This structure will remain stable across main contract upgrades
     */
    struct StableMarketData {
        uint256 marketId;
        string title;
        uint256 creationTime;
        uint256 closingTime;
        uint8 status;
        address oracle;
        uint256 liquidityParameter;
        uint256 totalLiquidityWei;
        uint256 totalVolumeWei;
        uint256 totalFeesWei;
        bool outcomeSet;
        uint256 winningOutcome;
        uint256 proposalTime;
        uint256 payoutPerShareWei;
        uint256 lpLockdownDurationSeconds;
        // Additional stable fields
        uint256 lpTokenSupply;
        uint256 principalAmountWei;
        uint256 feesAmountWei;
        uint256 userTradingPool; // Unified field for different contract types
    }
    
    struct StableUserPosition {
        uint256 lpTokens;
        uint256 totalSpentWei;
        bool claimed;
    }
    
    // ============ MODIFIERS ============
    
    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner can call");
        _;
    }
    
    // ============ CONSTRUCTOR ============
    
    constructor(address _mainContract, string memory _contractVersion) {
        owner = msg.sender;
        mainContract = _mainContract;
        contractVersion = _contractVersion;
    }
    
    // ============ ADMIN FUNCTIONS ============
    
    /**
     * @notice Update main contract address
     * @param _newContract New main contract address
     * @param _newVersion New contract version ("lmsr" or "zero")
     */
    function setMainContract(address _newContract, string memory _newVersion) external onlyOwner {
        require(_newContract != address(0), "Invalid contract address");
        
        address oldContract = mainContract;
        mainContract = _newContract;
        contractVersion = _newVersion;
        
        emit MainContractUpdated(oldContract, _newContract);
    }
    
    /**
     * @notice Transfer ownership
     * @param _newOwner New owner address
     */
    function transferOwnership(address _newOwner) external onlyOwner {
        require(_newOwner != address(0), "Invalid owner address");
        owner = _newOwner;
    }
    
    // ============ STABLE QUERY INTERFACE ============
    
    /**
     * @notice Get market count from main contract
     * @return count Total number of markets
     */
    function getMarketCount() external view returns (uint256 count) {
        try this.safeCall(abi.encodeWithSignature("getMarketCount()")) returns (bytes memory result) {
            count = abi.decode(result, (uint256));
        } catch {
            count = 0;
        }
    }
    
    /**
     * @notice Get stable market data structure
     * @param marketId Market ID to fetch
     * @return data Stable market data structure
     * @return success Whether the fetch was successful
     */
    function getStableMarketData(uint256 marketId) external view returns (StableMarketData memory data, bool success) {
        data.marketId = marketId;
        
        // Decode market data based on contract version
        try this.safeCall(abi.encodeWithSignature("markets(uint256)", marketId)) returns (bytes memory result) {
            
            if (keccak256(bytes(contractVersion)) == keccak256(bytes("lmsr"))) {
                // LMSR contract: 18 fields including manualOracle, settlementAdapter, totalShares[2], and fundsSeparated (bool)
                address manualOracle;
                address settlementAdapter;
                uint256[2] memory totalShares; // Decode but not store (QueryHub currently doesn't use)
                bool fundsSeparated;
                (
                    data.marketId,
                    data.title,
                    data.creationTime,
                    data.closingTime,
                    data.status,
                    manualOracle,
                    settlementAdapter,
                    data.liquidityParameter,
                    totalShares,
                    data.totalLiquidityWei,
                    data.totalVolumeWei,
                    data.totalFeesWei,
                    data.outcomeSet,
                    data.winningOutcome,
                    data.proposalTime,
                    data.payoutPerShareWei,
                    data.lpLockdownDurationSeconds,
                    fundsSeparated
                ) = abi.decode(result, (
                    uint256, string, uint256, uint256, uint8, address, address,
                    uint256, uint256[2], uint256, uint256, uint256, bool, uint256,
                    uint256, uint256, uint256, bool
                ));
                // Map stable oracle field to manualOracle for backwards compatibility
                data.oracle = manualOracle;
                
            } else {
                // Zero contract: 17 fields including manualOracle, settlementAdapter, totalShares[2] (no fundsSeparated)
                address manualOracle;
                address settlementAdapter;
                uint256[2] memory totalShares; // Decode but not store (QueryHub currently doesn't use)
                (
                    data.marketId,
                    data.title,
                    data.creationTime,
                    data.closingTime,
                    data.status,
                    manualOracle,
                    settlementAdapter,
                    data.liquidityParameter,
                    totalShares,
                    data.totalLiquidityWei,
                    data.totalVolumeWei,
                    data.totalFeesWei,
                    data.outcomeSet,
                    data.winningOutcome,
                    data.proposalTime,
                    data.payoutPerShareWei,
                    data.lpLockdownDurationSeconds
                ) = abi.decode(result, (
                    uint256, string, uint256, uint256, uint8, address, address,
                    uint256, uint256[2], uint256, uint256, uint256, bool, uint256,
                    uint256, uint256, uint256
                ));
                // Map stable oracle field to manualOracle for backwards compatibility
                data.oracle = manualOracle;
            }
            
            // Fetch additional data safely
            _fetchAdditionalMarketData(marketId, data);
            success = true;
            
        } catch {
            success = false;
        }
    }
    
    /**
     * @notice Get market prices with safe fallback
     * @param marketId Market ID
     * @return prices Market prices [price0, price1]
     * @return success Whether prices were successfully retrieved
     */
    function getMarketPrices(uint256 marketId) external view returns (uint256[2] memory prices, bool success) {
        try this.safeCall(abi.encodeWithSignature("getMarketPrices(uint256)", marketId)) returns (bytes memory result) {
            prices = abi.decode(result, (uint256[2]));
            
            // Validate prices
            if (prices[0] > 0 && prices[1] > 0) {
                success = true;
            } else {
                // Return safe 50/50 if invalid
                prices[0] = PRECISION_UNIT / 2;
                prices[1] = PRECISION_UNIT / 2;
                success = false; // Mark as fallback
            }
        } catch {
            // Safe fallback to 50/50
            prices[0] = PRECISION_UNIT / 2;
            prices[1] = PRECISION_UNIT / 2;
            success = false;
        }
    }
    
    /**
     * @notice Get batch market prices (lightweight, following main contract design)
     * @dev Returns only price0 for each market, price1 = 1e18 - price0
     * @param marketIds Array of market IDs
     * @return prices Array of price0 values
     * @return successes Array indicating success for each market
     */
    function getBatchMarketPricesLightweight(uint256[] calldata marketIds)
        external view returns (uint256[] memory prices, bool[] memory successes) {
        
        try this.safeCall(abi.encodeWithSignature("getBatchMarketPrices(uint256[])", marketIds)) returns (bytes memory result) {
            prices = abi.decode(result, (uint256[]));
            
            // Initialize success array
            successes = new bool[](marketIds.length);
            for (uint256 i = 0; i < marketIds.length; i++) {
                successes[i] = (i < prices.length && prices[i] > 0);
                if (!successes[i]) {
                    prices[i] = PRECISION_UNIT / 2; // Safe fallback
                }
            }
        } catch {
            // Fallback: safe 50% prices
            prices = new uint256[](marketIds.length);
            successes = new bool[](marketIds.length);
            for (uint256 i = 0; i < marketIds.length; i++) {
                prices[i] = PRECISION_UNIT / 2;
                successes[i] = false;
            }
        }
    }
    
    /**
     * @notice Get user position with version-aware decoding
     * @param user User address
     * @param marketId Market ID
     * @return position Stable user position structure
     * @return success Whether the fetch was successful
     */
    function getUserPosition(address user, uint256 marketId) external view returns (StableUserPosition memory position, bool success) {
        try this.safeCall(abi.encodeWithSignature("userPositions(address,uint256)", user, marketId)) returns (bytes memory result) {
            
            // Both contracts have the same userPosition structure: (shares[2], lpTokens, totalSpentWei, claimed)
            (, uint256 lpTokens, uint256 totalSpentWei, bool claimed) = 
                abi.decode(result, (uint256[2], uint256, uint256, bool));
            
            position.lpTokens = lpTokens;
            position.totalSpentWei = totalSpentWei;
            position.claimed = claimed;
            
            success = true;
            
        } catch {
            success = false;
        }
    }
    
    /**
     * @notice Get unified user trading pool amount
     * @param marketId Market ID
     * @return poolAmount Amount in user trading pool
     * @return success Whether the fetch was successful
     */
    function getUserTradingPool(uint256 marketId) external view returns (uint256 poolAmount, bool success) {
        if (keccak256(bytes(contractVersion)) == keccak256(bytes("zero"))) {
            // Zero contract: userTradingFundsWei
            try this.safeCall(abi.encodeWithSignature("userTradingFundsWei(uint256)", marketId)) returns (bytes memory result) {
                poolAmount = abi.decode(result, (uint256));
                success = true;
            } catch {
                success = false;
            }
        } else {
            // LMSR contract: reservedPayoutWei
            try this.safeCall(abi.encodeWithSignature("reservedPayoutWei(uint256)", marketId)) returns (bytes memory result) {
                poolAmount = abi.decode(result, (uint256));
                success = true;
            } catch {
                success = false;
            }
        }
    }
    
    // Settlement configuration passthrough
    function getSettlementConfiguration(uint256 marketId) external view returns (address manualOracle, address settlementAdapter, bool success) {
        try this.safeCall(abi.encodeWithSignature("getSettlementConfiguration(uint256)", marketId)) returns (bytes memory result) {
            (manualOracle, settlementAdapter) = abi.decode(result, (address, address));
            success = true;
        } catch {
            success = false;
        }
    }
    
    // ============ INTERNAL FUNCTIONS ============
    
    /**
     * @notice Fetch additional market data safely
     * @param marketId Market ID
     * @param data Data structure to populate
     */
    function _fetchAdditionalMarketData(uint256 marketId, StableMarketData memory data) internal view {
        // LP Token Supply
        try this.safeCall(abi.encodeWithSignature("lpTokenSupplies(uint256)", _getLPTokenId(marketId))) returns (bytes memory result) {
            data.lpTokenSupply = abi.decode(result, (uint256));
        } catch {}

        // Principal Amount
        try this.safeCall(abi.encodeWithSignature("principalAmountWei(uint256)", marketId)) returns (bytes memory result) {
            data.principalAmountWei = abi.decode(result, (uint256));
        } catch {}

        // Fees Amount
        try this.safeCall(abi.encodeWithSignature("feesAmountWei(uint256)", marketId)) returns (bytes memory result) {
            data.feesAmountWei = abi.decode(result, (uint256));
        } catch {}

        // User Trading Pool (unified field)
        (uint256 poolAmount, bool success) = this.getUserTradingPool(marketId);
        if (success) {
            data.userTradingPool = poolAmount;
        }

        // V2.0 Settlement Configuration (already stored in main decoding, but verify)
        // This data was already captured in getStableMarketData, so no additional call needed
    }
    
    /**
     * @notice Safe external call to main contract
     * @param data Encoded function call
     * @return result Raw return data
     */
    function safeCall(bytes memory data) external view returns (bytes memory result) {
        require(msg.sender == address(this), "Internal call only");
        
        (bool success, bytes memory returnData) = mainContract.staticcall(data);
        if (success) {
            result = returnData;
        } else {
            revert("Main contract call failed");
        }
    }
    
    /**
     * @notice Calculate LP token ID
     * @param marketId Market ID
     * @return lpTokenId LP token ID
     */
    function _getLPTokenId(uint256 marketId) internal pure returns (uint256 lpTokenId) {
        lpTokenId = (1 << 255) | marketId;
    }
    
    // ============ VIEW FUNCTIONS ============
    
    /**
     * @notice Get adapter configuration
     * @return contractAddr Main contract address
     * @return version Contract version string
     */
    function getConfiguration() external view returns (address contractAddr, string memory version) {
        contractAddr = mainContract;
        version = contractVersion;
    }
    
    /**
     * @notice Check adapter health
     * @return healthy Whether the adapter is functioning properly
     * @return marketCount Current market count
     */
    function getHealth() external view returns (bool healthy, uint256 marketCount) {
        try this.getMarketCount() returns (uint256 count) {
            healthy = true;
            marketCount = count;
        } catch {
            healthy = false;
            marketCount = 0;
        }
    }
}
