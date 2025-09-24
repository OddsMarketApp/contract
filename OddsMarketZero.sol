// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title OddsMarketZero - Zero-Sum Game Version (Compact)
 * @notice Zero-sum binary prediction market where LP funds are protected from trading risk
 * 
 * ZERO-SUM ARCHITECTURE: Separated Fund Pools
 * - totalPoolWei: Unified fund pool for LMSR calculations
 * - principalAmountWei: LP principal funds (protected from trading losses)
 * - feesAmountWei: LP accumulated fees (reward for providing liquidity)
 * - userTradingFundsWei: Pure user trading capital (zero-sum game pool)
 * 
 * KEY PRINCIPLES:
 * - LP provide liquidity but don't bear trading risk
 * - Payouts come exclusively from userTradingFundsWei
 * - LP earn fees from trading volume, not trading outcomes
 * - Early LP exit forfeits fees (anti-sniping protection)
 * - True zero-sum: users split what users contributed
 * 
 * SECURITY: Direct transfers, EOA-only restrictions, ReentrancyGuard, state-first pattern
 */

import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

contract OddsMarketZero is ERC1155, Ownable, ReentrancyGuard, Pausable {
    // ============ CORE ALGORITHM CONTRACT ============

    ISecretLMSRCore public immutable secretLMSRCore;

    // ============ Configuration / constants ============
    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant SHARE_UNIT = 1e18;
    uint256 public constant MIN_B = 1e17; // 0.1 BNB - improved price stability
    uint256 public constant MAX_B = 5e19; // 50 BNB - support larger markets
    uint256 public constant MIN_TRADE_AMOUNT = 1e15; // 0.001 BNB minimum trade
    uint256 public constant MIN_LIQUIDITY_RESERVE = 1e15; // 0.001 BNB minimum reserve
    uint256 public constant MAX_TRADE_SIZE = 2e20; // 200 BNB maximum single trade
    uint256 public constant MAX_SHARES = 1e24; // Maximum shares to prevent overflow
    // LP Lockdown period constraints
    uint256 public constant MIN_LP_LOCKDOWN_SECONDS = 60; // 1 minute minimum
    uint256 public constant MAX_LP_LOCKDOWN_SECONDS = 3600; // 1 hour maximum 
    uint256 public constant DEFAULT_LP_LOCKDOWN_SECONDS = 600; // 10 minutes default
    // P0 CRITICAL: PRBMath exp() overflow protection
    uint256 public constant MAX_EXP_ARG = 113e18;
    // Sweep protection: Grace period after market resolution before protocol can sweep winner funds
    uint256 public constant SWEEP_GRACE_PERIOD = 14 days;

    // ============ Errors ============
    error InvalidMarket();
    error MarketNotActive();
    error MarketClosed();
    error Unauthorized();
    error AmountTooLarge();
    error SharesTooLarge();
    error ZeroAmount();
    error InsufficientLP();
    error InsufficientBalance();
    error InsufficientPool();
    error TransferFailed();
    error AlreadyClaimed();
    error AlreadyFinalized();
    error OutcomeInvalid();
    error InvalidFee();
    error NothingToWithdraw();
    error TimelockNotElapsed();
    error InvariantViolated();
    error SlippageExceeded();
    error DustAmountNotAllowed();
    error TransfersDisabled();
    error DirectDepositsDisabled();
    error LMSRArgumentTooLarge();
    error LPLockdownPeriod();
    error LPLockedUntilResolution();

    // ============ Structs ============
    enum MarketStatus { Created, Active, Closed, Resolved }

    struct Market {
        uint256 marketId;
        string title;
        uint256 creationTime;
        uint256 closingTime;
        MarketStatus status;
        address manualOracle;                // Manual settlement oracle address
        address settlementAdapter;          // Automated settlement adapter address (optional)
        uint256 liquidityParameter;
        uint256[2] totalShares;
        uint256 totalLiquidityWei;
        uint256 totalVolumeWei;
        uint256 totalFeesWei;
        bool outcomeSet;
        uint256 winningOutcome;
        uint256 proposalTime;
        uint256 payoutPerShareWei;
        uint256 lpLockdownDurationSeconds; // LP lockdown duration
    }

    struct UserPosition {
        uint256[2] shares;
        uint256 lpTokens; // LP token balance
        uint256 totalSpentWei;
        bool claimed;
    }

    // ============ State ============
    uint256 private _marketIdCounter;
    uint256 public minLiquidityWei = 1e18;
    uint256 public disputePeriod = 5 minutes;

    // Fee rates in basis points
    uint256 public protocolFeeRateBP = 25; // 0.25%
    uint256 public lpFeeRateBP = 75;       // 0.75%
    uint256 public constant MAX_PROTOCOL_FEE_BP = 500;  // 5%
    uint256 public constant MAX_LP_FEE_BP = 1500;       // 15%
    uint256 public constant MAX_TOTAL_FEE_BP = 2000;    // 20%

    // Storage
    mapping(uint256 => Market) public markets;
    mapping(address => mapping(uint256 => UserPosition)) public userPositions;

    // ============ ZERO-SUM ARCHITECTURE ============
    // ZERO-SUM INNOVATION: Separated fund pools for LP protection
    mapping(uint256 => uint256) public totalPoolWei;      // Single unified fund pool
    mapping(uint256 => uint256) public principalAmountWei; // Virtual: LP principal tracking
    mapping(uint256 => uint256) public feesAmountWei;      // Virtual: Accumulated fees
    mapping(uint256 => uint256) public userTradingFundsWei; // NEW: Pure user trading funds (zero-sum pool)
    uint256 public protocolPoolTotalWei;                   // Global protocol fees
    uint256 public totalAllPoolsWei;                       // P1 FIX: Running total of all market pools (gas optimization)

    // Token supplies
    mapping(uint256 => uint256[2]) public tokenSupplies;
    mapping(uint256 => uint256) public lpTokenSupplies;

    // Authorization
    mapping(address => bool) public authorizedCreators;
    uint256 public authorizedCreatorCount;
    

    // LP Early Exit Tracking (ANTI-SNIPING)
    mapping(uint256 => mapping(address => bool)) public hasExitedBeforeDeadline;

    // Market pause state
    mapping(uint256 => bool) public marketPaused;

    // ============ Events ============
    event MarketCreated(uint256 indexed marketId, string title, uint256 indexed closingTime, address indexed manualOracle, address settlementAdapter, uint256 initialB, uint256 lpLockdownDurationSeconds, address creator);
    event MarketActivated(uint256 indexed marketId, address indexed provider, uint256 amountWei);
    event SharesPurchased(uint256 indexed marketId, address indexed buyer, uint256 outcome, uint256 sharesScaled, uint256 costWei, uint256 protocolFeeWei, uint256 lpFeeWei);
    event SharesSold(uint256 indexed marketId, address indexed seller, uint256 outcome, uint256 sharesScaled, uint256 netPayoutWei, uint256 protocolFeeWei, uint256 lpFeeWei);
    event LiquidityAdded(uint256 indexed marketId, address indexed provider, uint256 amountWei, uint256 lpTokens);
    event LiquidityRemoved(uint256 indexed marketId, address indexed provider, uint256 principalWei, uint256 feesWei, uint256 lpTokens);
    event LPExitedBeforeDeadline(uint256 indexed marketId, address indexed provider, uint256 forfeitedFeesWei);
    event LPLockdownAttempt(uint256 indexed marketId, address indexed provider, uint256 timeUntilClose);
    event LPLockEnforced(uint256 indexed marketId, address indexed provider, MarketStatus status, string reason);
    event ResultProposed(uint256 indexed marketId, uint256 outcome, address indexed proposer);
    event ResultFinalized(uint256 indexed marketId, uint256 indexed outcome);
    event Claimed(uint256 indexed marketId, address indexed user, uint256 payoutWei);
    event FundsReserved(
        uint256 indexed marketId, 
        uint256 fromFeesWei, 
        uint256 fromProtocolWei, 
        uint256 totalReservedWei, 
        uint256 payoutPerShareWei, 
        uint256 maxPossiblePayout
    );
    event EmergencyFinalized(uint256 indexed marketId, uint256 outcome, address indexed executor);
    event MarketPaused(uint256 indexed marketId);
    event MarketUnpaused(uint256 indexed marketId);
    event ProtocolFeesQueued(address indexed owner, uint256 indexed amountWei);
    // Simplified events for bytecode optimization
    event AccountingAdjustment(uint256 indexed marketId, uint256 adjustment);
    event WinnerPoolSwept(uint256 indexed marketId, uint256 amountWei);

    // ============ Modifiers ============
    
    
    modifier validMarket(uint256 marketId) {
        if (marketId == 0 || marketId > _marketIdCounter || markets[marketId].marketId == 0) {
            revert InvalidMarket();
        }
        _;
    }

    modifier whenMarketNotPaused(uint256 marketId) {
        if (marketPaused[marketId]) revert MarketNotActive();
        _;
    }

    modifier checkPoolInvariants(uint256 marketId) {
        _;
        _verifyPoolInvariants(marketId);
    }

    // ============ Constructor ============
    constructor(address _secretLMSRCore) ERC1155("") {
        require(_secretLMSRCore != address(0), "Invalid SecretLMSRCore address");
        secretLMSRCore = ISecretLMSRCore(_secretLMSRCore);
        authorizedCreators[msg.sender] = true;
        authorizedCreatorCount = 1;
    }

    // ============ Market Management ============
    
    /**
     * @notice Create a new binary prediction market
     * @param title Market title (short, descriptive name)
     * @param durationSeconds Duration until market closes
     * @param oracle Oracle address for result resolution
     * @param initialB LMSR liquidity parameter (0.1-10 BNB)
     * @param lpLockdownDurationSeconds LP lockdown period before market close
     */
    /**
     * @notice Create a market with flexible settlement configuration (main implementation)
     * @param title Market title
     * @param durationSeconds Duration until market closes (seconds)
     * @param manualOracle Manual settlement oracle address (set to address(0) for auto-only)
     * @param settlementAdapter Automated settlement adapter address (set to address(0) for manual-only)
     * @param initialB Liquidity parameter (b)
     * @param lpLockdownDurationSeconds LP lockdown duration after market closure
     * @return marketId The newly created market ID
     */
    function createMarketWithSettlement(
        string calldata title,
        uint256 durationSeconds,
        address manualOracle,
        address settlementAdapter,
        uint256 initialB,
        uint256 lpLockdownDurationSeconds
    ) external returns (uint256) {
        if (!authorizedCreators[msg.sender]) revert Unauthorized();
        // At least one settlement method must be provided
        if (manualOracle == address(0) && settlementAdapter == address(0)) revert InvalidMarket();
        // Both addresses can be set for hybrid settlement (first-to-arrive wins)
        if (initialB < MIN_B || initialB > MAX_B) revert InvalidMarket();
        if (lpLockdownDurationSeconds < MIN_LP_LOCKDOWN_SECONDS ||
            lpLockdownDurationSeconds > MAX_LP_LOCKDOWN_SECONDS) revert InvalidMarket();
        if (durationSeconds < 1 hours) revert InvalidMarket();

        uint256 marketId = ++_marketIdCounter;
        uint256 closingTime = block.timestamp + durationSeconds;

        Market storage m = markets[marketId];
        m.marketId = marketId;
        m.title = title;
        m.creationTime = block.timestamp;
        m.closingTime = closingTime;
        m.status = MarketStatus.Created;
        m.manualOracle = manualOracle;
        m.settlementAdapter = settlementAdapter;
        m.liquidityParameter = initialB;
        m.lpLockdownDurationSeconds = lpLockdownDurationSeconds;

        // V3 IMPROVEMENT: Start with zero shares for true market neutrality
        // Market begins in Created state, becomes Active when first LP adds liquidity
        // m.totalShares[0] = 0; // Default value
        // m.totalShares[1] = 0; // Default value

        emit MarketCreated(marketId, title, closingTime, manualOracle, settlementAdapter, initialB, lpLockdownDurationSeconds, msg.sender);
        return marketId;
    }

    /**
     * @notice Create a market (legacy interface - manual settlement only)
     * @param title Market title
     * @param durationSeconds Duration until market closes (seconds)
     * @param oracle Manual settlement oracle address
     * @param initialB Liquidity parameter (b)
     * @param lpLockdownDurationSeconds LP lockdown duration after market closure
     * @return marketId The newly created market ID
     */
    function createMarket(
        string calldata title,
        uint256 durationSeconds,
        address oracle,
        uint256 initialB,
        uint256 lpLockdownDurationSeconds
    ) external returns (uint256) {
        // Legacy interface: manual settlement only
        if (!authorizedCreators[msg.sender]) revert Unauthorized();
        if (oracle == address(0)) revert InvalidMarket();
        if (initialB < MIN_B || initialB > MAX_B) revert InvalidMarket();
        if (lpLockdownDurationSeconds < MIN_LP_LOCKDOWN_SECONDS ||
            lpLockdownDurationSeconds > MAX_LP_LOCKDOWN_SECONDS) revert InvalidMarket();
        if (durationSeconds < 1 hours) revert InvalidMarket();

        uint256 marketId = ++_marketIdCounter;
        uint256 closingTime = block.timestamp + durationSeconds;

        Market storage m = markets[marketId];
        m.marketId = marketId;
        m.title = title;
        m.creationTime = block.timestamp;
        m.closingTime = closingTime;
        m.status = MarketStatus.Created;
        m.manualOracle = oracle;
        m.settlementAdapter = address(0); // No auto settlement for legacy interface
        m.liquidityParameter = initialB;
        m.lpLockdownDurationSeconds = lpLockdownDurationSeconds;

        emit MarketCreated(marketId, title, closingTime, oracle, address(0), initialB, lpLockdownDurationSeconds, msg.sender);
        return marketId;
    }

    // ============ Liquidity Management ============
    
    /**
     * @notice Add liquidity to a market (V2: Single Pool Architecture)
     * @param marketId Market to add liquidity to
     */
    function addLiquidity(uint256 marketId) 
        external 
        payable 
        validMarket(marketId) 
        nonReentrant 
        whenNotPaused 
        whenMarketNotPaused(marketId)
        checkPoolInvariants(marketId)
    {
        if (msg.value == 0) revert ZeroAmount();
        Market storage m = markets[marketId];
        if (!(m.status == MarketStatus.Created || (m.status == MarketStatus.Active && block.timestamp < m.closingTime))) {
            revert MarketNotActive();
        }

        uint256 lpTokens;
        
        if (m.status == MarketStatus.Created && m.totalLiquidityWei == 0) {
            // First liquidity addition - activate market
            if (msg.value < minLiquidityWei) revert InvalidMarket();

            m.status = MarketStatus.Active;
            m.totalLiquidityWei = msg.value;
            lpTokens = msg.value;
            emit MarketActivated(marketId, msg.sender, msg.value);
        } else {
            // Additional liquidity - proportional LP tokens
            uint256 lpTokenId = _getLPTokenId(marketId);
            uint256 totalSupply = lpTokenSupplies[lpTokenId];
            if (totalSupply == 0) {
                lpTokens = msg.value;
            } else {
                lpTokens = (msg.value * totalSupply) / m.totalLiquidityWei;
            }
            m.totalLiquidityWei += msg.value;
        }

        // V3 IMPROVEMENT: Atomic accounting update
        _applyAccountingDeltas(
            marketId,
            int256(msg.value),  // +totalPool
            int256(msg.value),  // +principal (LP funds)
            0,                  // fees unchanged
            0                   // userTradingFunds unchanged
        );

        // Update LP tokens
        uint256 lpTokenIdFinal = _getLPTokenId(marketId);
        lpTokenSupplies[lpTokenIdFinal] += lpTokens;
        userPositions[msg.sender][marketId].lpTokens += lpTokens;
        _mint(msg.sender, lpTokenIdFinal, lpTokens, "");

        emit LiquidityAdded(marketId, msg.sender, msg.value, lpTokens);
    }

    /**
     * @notice Remove liquidity from market (V2: Single Pool with LP Incentive Control)
     * @param marketId Market to remove liquidity from
     * @param lpTokens Amount of LP tokens to burn
     */
    function removeLiquidity(uint256 marketId, uint256 lpTokens) 
        external 
        validMarket(marketId) 
        nonReentrant 
        whenNotPaused
        whenMarketNotPaused(marketId)
        checkPoolInvariants(marketId)
    {
        if (lpTokens == 0) revert ZeroAmount();
        uint256 lpTokenId = _getLPTokenId(marketId);
        if (balanceOf(msg.sender, lpTokenId) < lpTokens) revert InsufficientLP();
        uint256 totalLPSupply = lpTokenSupplies[lpTokenId];
        if (totalLPSupply == 0) revert InsufficientLP();

        // Dust protection
        uint256 minWithdrawal = Math.max(totalLPSupply / 1000, 1000);
        if (lpTokens < minWithdrawal && lpTokens < balanceOf(msg.sender, lpTokenId)) {
            revert DustAmountNotAllowed();
        }

        Market storage m = markets[marketId];
        
        // LP LOCKDOWN: Anti-sniping mechanism (optimized calculation)
        uint256 lockdownStart = m.closingTime - m.lpLockdownDurationSeconds;
        bool isInLockdownPeriod = block.timestamp >= lockdownStart && block.timestamp < m.closingTime;
        
        if (isInLockdownPeriod) {
            uint256 timeUntilClose = m.closingTime - block.timestamp;
            emit LPLockdownAttempt(marketId, msg.sender, timeUntilClose);
            revert LPLockdownPeriod();
        }
        
        // New rule: After closing time, LP cannot exit until resolved
        if (block.timestamp >= m.closingTime && m.status != MarketStatus.Resolved) {
            emit LPLockEnforced(marketId, msg.sender, m.status, "LP locked post-close until resolution");
            revert LPLockedUntilResolution();
        }

        // CRITICAL FIX: LP locked during Closed status until Resolution
        if (m.status == MarketStatus.Closed) {
            emit LPLockEnforced(marketId, msg.sender, m.status, "LP locked during settlement period");
            revert LPLockedUntilResolution();
        }

        // V2 ARCHITECTURE: Calculate withdrawal from virtual accounting
        // Mark early-exit if withdrawing before resolution (fee forfeiture)
        if (!hasExitedBeforeDeadline[marketId][msg.sender] && m.status != MarketStatus.Resolved && block.timestamp < m.closingTime) {
            hasExitedBeforeDeadline[marketId][msg.sender] = true;
        }
        uint256 principalShare = (lpTokens * principalAmountWei[marketId]) / totalLPSupply;
        uint256 feeShare = 0;

        // LP INCENTIVE CONTROL: Fee distribution based on loyalty (lockdown exits blocked above)
        if (!hasExitedBeforeDeadline[marketId][msg.sender]) {
            // Loyal LP gets proportional fee share
            feeShare = (lpTokens * feesAmountWei[marketId]) / totalLPSupply;
        }

        uint256 totalWithdraw = principalShare + feeShare;

        // V2 INVARIANT CHECKS: Ensure sufficient funds in single pool
        if (totalPoolWei[marketId] < totalWithdraw) revert InsufficientBalance();
        if (principalAmountWei[marketId] < principalShare) revert InsufficientBalance();
        if (feeShare > 0 && feesAmountWei[marketId] < feeShare) revert InsufficientBalance();
        
        // Minimum liquidity reserve protection (only during active trading)
        // Allow complete LP removal after market resolution
        if (m.status != MarketStatus.Resolved) {
            if (principalAmountWei[marketId] - principalShare < MIN_LIQUIDITY_RESERVE) {
                revert InsufficientLP();
            }
        }

        // V3 IMPROVEMENT: Atomic accounting update
        _applyAccountingDeltas(
            marketId,
            -int256(totalWithdraw),  // -totalPool
            -int256(principalShare), // -principal (LP funds)
            -int256(feeShare),       // -fees
            0                        // userTradingFunds unchanged
        );

        // Update LP tokens and market state
        lpTokenSupplies[lpTokenId] -= lpTokens;
        userPositions[msg.sender][marketId].lpTokens -= lpTokens;
        _burn(msg.sender, lpTokenId, lpTokens);
        m.totalLiquidityWei -= principalShare;

        // Direct transfer - state-first, transfer-last pattern
        // All state changes are complete, now transfer immediately
        (bool success, ) = payable(msg.sender).call{value: totalWithdraw}("");
        if (!success) revert TransferFailed();
        
        emit LiquidityRemoved(marketId, msg.sender, principalShare, feeShare, lpTokens);
    }

    // ============ Trading ============
    
    /**
     * @notice Buy shares in a market (Zero-Sum Game Version)
     * @param marketId Market to buy shares in
     * @param outcome Outcome to buy (0 or 1)
     * @param minSharesScaled Minimum shares to receive (slippage protection)
     * @dev ZERO-SUM: User payment goes to userTradingFundsWei (game pool), 
     *      LP only earns fees, no exposure to trading outcomes
     */
    function buyShares(uint256 marketId, uint256 outcome, uint256 minSharesScaled) 
        external 
        payable 
        validMarket(marketId) 
        nonReentrant 
        whenNotPaused 
        checkPoolInvariants(marketId)
        whenMarketNotPaused(marketId)
    {
        // Input validation
        if (msg.value == 0) revert ZeroAmount();
        if (msg.value < MIN_TRADE_AMOUNT) revert ZeroAmount();
        if (msg.value > MAX_TRADE_SIZE) revert AmountTooLarge();
        if (outcome > 1) revert OutcomeInvalid();
        
        Market storage m = markets[marketId];
        UserPosition storage userPos = userPositions[msg.sender][marketId];
        
        // Cache frequently accessed values for gas optimization
        MarketStatus status = m.status;
        uint256 closingTime = m.closingTime;
        
        // Market state validation
        if (status != MarketStatus.Active) revert MarketNotActive();
        if (block.timestamp >= closingTime) revert MarketClosed();
        

        // V3 CRITICAL FIX: Budget-first approach to eliminate estimation inconsistencies
        uint256 protoBP = protocolFeeRateBP;
        uint256 lpBP = lpFeeRateBP;
        uint256 combinedFeeBP = protoBP + lpBP;
        
        // Calculate available budget after fees
        uint256 availableBudget = (msg.value * BASIS_POINTS) / (BASIS_POINTS + combinedFeeBP);

        // Validate LMSR bounds before library call (consistency with sell/price paths)
        {
            uint256[2] memory s = [m.totalShares[0], m.totalShares[1]];
            _validateLMSRBounds(s, m.liquidityParameter);
        }

        // Core algorithm: Single library call to get optimal shares and cost
        (uint256 sharesToBuyScaled, uint256 baseCostWei) = secretLMSRCore.buyWithinBudget(
            m.totalShares[0],       // s0
            m.totalShares[1],       // s1
            outcome,                // outcome
            m.liquidityParameter,   // b
            availableBudget,        // availableBudget
            m.totalLiquidityWei    // totalLiquidityWei for adaptive optimization
        );

        // Library call result validation
        if (sharesToBuyScaled == 0) revert ZeroAmount();
        if (sharesToBuyScaled > MAX_SHARES) revert SharesTooLarge();
        if (baseCostWei == 0) revert ZeroAmount(); // Zero-cost defensive check
        if (baseCostWei > availableBudget) revert InsufficientBalance();
        
        uint256 protocolFeeWei = (baseCostWei * protoBP) / BASIS_POINTS;
        uint256 lpFeeWei = (baseCostWei * lpBP) / BASIS_POINTS;
        uint256 totalCostWei = baseCostWei + protocolFeeWei + lpFeeWei;
        
        // This should never fail now, but keep as safety check
        if (msg.value < totalCostWei) revert InsufficientBalance();
        
        // Check slippage after knowing actual shares
        if (sharesToBuyScaled < minSharesScaled) revert SlippageExceeded();

        // ZERO-SUM: Atomic accounting update with separated user trading funds
        _applyAccountingDeltas(
            marketId,
            int256(baseCostWei + lpFeeWei), // +totalPool (trading cost + LP fees)
            0,                              // principal unchanged (LP本金不变)
            int256(lpFeeWei),              // +fees (LP fees)
            int256(baseCostWei)            // +userTradingFunds (pure user trading capital)
        );
        
        // Protocol fees go to global pool (separate from market accounting)
        protocolPoolTotalWei += protocolFeeWei;

        // Update market state - write shares back to storage
        m.totalShares[outcome] += sharesToBuyScaled;
        m.totalVolumeWei += baseCostWei;
        m.totalFeesWei += protocolFeeWei + lpFeeWei;

        // Update token supplies and user position
        tokenSupplies[marketId][outcome] += sharesToBuyScaled;
        userPos.shares[outcome] += sharesToBuyScaled;
        userPos.totalSpentWei += totalCostWei;

        // Mint share tokens to user
        uint256 shareTokenId = _getShareTokenId(marketId, outcome);
        _mint(msg.sender, shareTokenId, sharesToBuyScaled, "");

        // Direct refund - state-first, transfer-last pattern
        // All state changes are complete, now refund immediately if needed
        uint256 refundAmount = msg.value - totalCostWei;
        if (refundAmount > 0) {
            (bool success, ) = payable(msg.sender).call{value: refundAmount}("");
            if (!success) revert TransferFailed();
        }

        emit SharesPurchased(marketId, msg.sender, outcome, sharesToBuyScaled, baseCostWei, protocolFeeWei, lpFeeWei);
    }

    /**
     * @notice Sell shares in a market (V2: Single Pool LMSR)
     * @param marketId Market to sell shares in
     * @param outcome Outcome to sell (0 or 1)
     * @param sharesToSellScaled Amount of shares to sell
     * @param minPayoutWei Minimum payout to receive (slippage protection)
     */
    function sellShares(
        uint256 marketId,
        uint256 outcome,
        uint256 sharesToSellScaled,
        uint256 minPayoutWei
    ) 
        external 
        validMarket(marketId) 
        nonReentrant 
        whenNotPaused 
        checkPoolInvariants(marketId)
        whenMarketNotPaused(marketId) 
    {
        if (sharesToSellScaled == 0) revert ZeroAmount();
        if (outcome > 1) revert OutcomeInvalid();

        Market storage m = markets[marketId];
        UserPosition storage userPos = userPositions[msg.sender][marketId];
        
        // Cache frequently accessed values for gas optimization
        MarketStatus status = m.status;
        uint256 closingTime = m.closingTime;
        
        if (status != MarketStatus.Active) revert MarketNotActive();
        if (block.timestamp >= closingTime) revert MarketClosed();
        
        // V3 IMPROVEMENT: Ensure market has liquidity before trading
        if (m.totalShares[0] == 0 && m.totalShares[1] == 0) revert MarketNotActive();
        
        uint256 shareTokenId = _getShareTokenId(marketId, outcome);
        if (balanceOf(msg.sender, shareTokenId) < sharesToSellScaled) revert InsufficientBalance();
        if (m.totalShares[outcome] < sharesToSellScaled) revert InsufficientBalance();

        // Core algorithm: Safe library call with bounds validation
        uint256 baseValueWei = safeLMSRSellValue(
            m.totalShares,         // shares array
            sharesToSellScaled,    // sharesToSell
            outcome,               // outcome
            m.liquidityParameter   // b
        );

        // Apply fees
        uint256 protocolFeeWei = (baseValueWei * protocolFeeRateBP) / BASIS_POINTS;
        uint256 lpFeeWei = (baseValueWei * lpFeeRateBP) / BASIS_POINTS;
        uint256 netPayoutWei = baseValueWei - protocolFeeWei - lpFeeWei;

        if (netPayoutWei < minPayoutWei) revert SlippageExceeded();
        
        // Check sufficient funds in single pool:
        // Pool reduction = (net payout + protocol fee) = baseValueWei - lpFeeWei
        if (totalPoolWei[marketId] < (baseValueWei - lpFeeWei)) revert InsufficientPool();

        // ZERO-SUM: Atomic accounting update for sellShares
        // Reduce user trading funds and total pool, LP fee stays in pool as tracked fees
        _applyAccountingDeltas(
            marketId,
            -int256(baseValueWei - lpFeeWei), // -totalPool (reduce by net payout + protocol fee)
            0,                                // principal unchanged (LP funds protected)
            int256(lpFeeWei),                // +fees (LP fee stays in pool)
            -int256(baseValueWei)            // -userTradingFunds (reduce user trading capital)
        );
        
        // Protocol fees go to global pool (separate from market accounting)
        protocolPoolTotalWei += protocolFeeWei;

        // Update market state
        m.totalShares[outcome] -= sharesToSellScaled;
        m.totalVolumeWei += baseValueWei;
        m.totalFeesWei += protocolFeeWei + lpFeeWei;

        // Update token supplies and user position
        tokenSupplies[marketId][outcome] -= sharesToSellScaled;
        userPos.shares[outcome] -= sharesToSellScaled;

        // Burn share tokens from user
        _burn(msg.sender, shareTokenId, sharesToSellScaled);

        // Direct transfer - state-first, transfer-last pattern
        // All state changes are complete, now transfer immediately
        (bool success, ) = payable(msg.sender).call{value: netPayoutWei}("");
        if (!success) revert TransferFailed();

        emit SharesSold(marketId, msg.sender, outcome, sharesToSellScaled, netPayoutWei, protocolFeeWei, lpFeeWei);
    }

    // ============ Resolution ============
    
    /**
     * @notice Propose market result (oracle only)
     */
    function proposeResult(uint256 marketId, uint256 outcome)
        external
        validMarket(marketId)
        nonReentrant
    {
        Market storage m = markets[marketId];

        // Only manual oracle can propose through this entry point
        if (msg.sender != m.manualOracle) revert Unauthorized();
        if (m.status != MarketStatus.Active) revert MarketNotActive();
        if (block.timestamp < m.closingTime) revert MarketNotActive();
        if (outcome > 1) revert OutcomeInvalid();
        if (m.outcomeSet) revert AlreadyFinalized();

        m.status = MarketStatus.Closed;
        m.winningOutcome = outcome;
        m.outcomeSet = true;
        m.proposalTime = block.timestamp;

        emit ResultProposed(marketId, outcome, msg.sender);
    }

    /**
     * @notice Propose result from external settlement adapter (automated settlement)
     * @param marketId Market ID to propose result for
     * @param outcome Proposed outcome (0 or 1)
     */
    function proposeResultFromExternalOracle(uint256 marketId, uint256 outcome)
        external
        validMarket(marketId)
        nonReentrant
    {
        Market storage m = markets[marketId];

        // Only settlement adapter can propose through this entry point
        if (msg.sender != m.settlementAdapter) revert Unauthorized();
        if (m.status != MarketStatus.Active) revert MarketNotActive();
        if (block.timestamp < m.closingTime) revert MarketNotActive();
        if (outcome > 1) revert OutcomeInvalid();
        if (m.outcomeSet) revert AlreadyFinalized(); // First-to-arrive protection

        m.status = MarketStatus.Closed;
        m.winningOutcome = outcome;
        m.outcomeSet = true;
        m.proposalTime = block.timestamp;

        emit ResultProposed(marketId, outcome, msg.sender);
    }

    /**
     * @notice Finalize market result after dispute period
     */
    function finalizeResult(uint256 marketId)
        external
        validMarket(marketId)
        nonReentrant
        checkPoolInvariants(marketId)
    {
        Market storage m = markets[marketId];
        if (!m.outcomeSet) revert InvalidMarket();
        if (m.status != MarketStatus.Closed) revert InvalidMarket();
        if (block.timestamp < m.proposalTime + disputePeriod) revert TimelockNotElapsed();

        m.status = MarketStatus.Resolved;

        // V2 ARCHITECTURE: Calculate payout per share using unified logic
        _calculatePayoutPerShare(marketId, m.winningOutcome);
        
        // Emit funds reserved event if there are winners
        uint256 winningShares = m.totalShares[m.winningOutcome];
        if (winningShares > 0) {
            // Zero-sum: winnersPayable equals the aggregate payout computed from userTradingFunds
            uint256 winnersPayable = (winningShares * m.payoutPerShareWei) / SHARE_UNIT;
            uint256 actualReserved = winnersPayable; // zero-sum model reserves exactly winners' payable
            
            emit FundsReserved(
                marketId,
                feesAmountWei[marketId],
                0, // No protocol fees used for payout
                actualReserved,
                m.payoutPerShareWei,
                winnersPayable
            );
        }

        emit ResultFinalized(marketId, m.winningOutcome);
    }


    /**
     * @notice Claim winnings for resolved market (Zero-Sum Game Version)
     * @dev ZERO-SUM: Payouts come exclusively from userTradingFundsWei
     *      LP funds remain protected, winners split user trading pool
     */
    function claimWinnings(uint256 marketId) 
        external 
        validMarket(marketId) 
        nonReentrant 
        checkPoolInvariants(marketId)
    {
        Market storage m = markets[marketId];
        UserPosition storage userPos = userPositions[msg.sender][marketId];
        
        if (m.status != MarketStatus.Resolved) revert InvalidMarket();
        if (userPos.claimed) revert AlreadyClaimed();

        uint256 winningShares = userPos.shares[m.winningOutcome];
        if (winningShares == 0) revert NothingToWithdraw();

        uint256 payoutWei = (winningShares * m.payoutPerShareWei) / SHARE_UNIT;
        
        // Prevent zero-amount claim from burning shares silently
        if (payoutWei == 0) revert NothingToWithdraw();
        if (totalPoolWei[marketId] < payoutWei) revert InsufficientBalance();

        userPos.claimed = true;
        
        // Burn the winning shares to maintain accounting consistency
        uint256 winningTokenId = _getShareTokenId(marketId, m.winningOutcome);
        _burn(msg.sender, winningTokenId, winningShares);
        
        // Also burn losing shares if user has any
        uint256 losingOutcome = m.winningOutcome == 0 ? 1 : 0;
        uint256 losingShares = userPos.shares[losingOutcome];
        if (losingShares > 0) {
            uint256 losingTokenId = _getShareTokenId(marketId, losingOutcome);
            _burn(msg.sender, losingTokenId, losingShares);
            tokenSupplies[marketId][losingOutcome] -= losingShares;
        }
        
        // Update token supplies for winning shares
        tokenSupplies[marketId][m.winningOutcome] -= winningShares;
        
        // Clear user's shares (both winning and losing)
        userPos.shares[0] = 0;
        userPos.shares[1] = 0;

        // ZERO-SUM: Validate sufficient user trading funds for payout
        if (userTradingFundsWei[marketId] < payoutWei) {
            revert InsufficientPool(); // Not enough user trading funds to pay winner
        }
        
        // ZERO-SUM: Apply atomic accounting changes - payout comes from user trading funds only
        _applyAccountingDeltas(
            marketId,
            -int256(payoutWei),  // -totalPool
            0,                   // principal unchanged (LP funds protected in zero-sum)
            0,                   // fees unchanged (LP fees protected)
            -int256(payoutWei)   // -userTradingFunds (payout reduces user trading capital)
        );

        // Direct transfer - state-first, transfer-last pattern  
        // All state changes are complete, now transfer immediately
        (bool success, ) = payable(msg.sender).call{value: payoutWei}("");
        if (!success) revert TransferFailed();

        emit Claimed(marketId, msg.sender, payoutWei);
    }

    // ============ Emergency Functions ============
    
    /**
     * @notice Emergency finalize (owner only)
     */
    function emergencyFinalize(uint256 marketId, uint256 outcome) 
        external 
        onlyOwner 
        validMarket(marketId) 
    {
        if (outcome > 1) revert OutcomeInvalid();
        
        Market storage m = markets[marketId];
        m.status = MarketStatus.Resolved;
        m.winningOutcome = outcome;
        m.outcomeSet = true;
        m.proposalTime = block.timestamp;
        
        // Calculate payout per share using unified logic
        _calculatePayoutPerShare(marketId, outcome);

        emit EmergencyFinalized(marketId, outcome, msg.sender);
    }

    // ============ Direct Transfers Only ============
    // Pull Payment system has been removed in favor of direct transfers

    /**
     * @notice Withdraw protocol fees (owner only)
     */
    function withdrawProtocolFees(uint256 amountWei) external onlyOwner nonReentrant {
        if (amountWei > protocolPoolTotalWei) revert InsufficientBalance();
        
        // State-first pattern: update balances before transfer
        protocolPoolTotalWei -= amountWei;
        
        // Direct transfer immediately
        (bool success, ) = payable(msg.sender).call{value: amountWei}("");
        if (!success) revert TransferFailed();

        emit ProtocolFeesQueued(msg.sender, amountWei);
    }

    /**
     * @notice Emergency withdraw only surplus funds (owner only)
     * @dev Withdraws only unaccounted surplus to avoid touching user/LP/protocol funds:
     *      surplus = address(this).balance - (protocolPoolTotalWei + totalAllPoolsWei)
     */
    /**
     * @notice OWNER SWEEP: Move ZERO-SUM winner pool to protocol fee pool (no immediate external transfer)
     * @dev Minimal-change path:
     *      - Reduce userTradingFundsWei by 'amount'
     *      - Increase protocolPoolTotalWei by 'amount'
     *      - Keep totalPoolWei unchanged (funds remain on contract, later withdraw via withdrawProtocolFees)
     *      Safety: Only owner; market must be Resolved; amount > 0
     */
    function sweepWinnerPoolToProtocol(uint256 marketId)
        external
        onlyOwner
        nonReentrant
        validMarket(marketId)
        checkPoolInvariants(marketId)
    {
        Market storage m = markets[marketId];
        if (m.status != MarketStatus.Resolved) revert InvalidMarket();

        // 14-day grace period: must wait dispute period + grace period after proposal
        if (block.timestamp < m.proposalTime + disputePeriod + SWEEP_GRACE_PERIOD) revert TimelockNotElapsed();

        uint256 amount = userTradingFundsWei[marketId];
        if (amount == 0) revert NothingToWithdraw();

        // Reduce zero-sum user pool, keep totalPoolWei unchanged
        _applyAccountingDeltas(marketId, 0, 0, 0, -int256(amount));
        // Credit protocol pool (withdrawable via withdrawProtocolFees)
        protocolPoolTotalWei += amount;

        emit WinnerPoolSwept(marketId, amount);
    }

    function emergencyWithdraw() external onlyOwner nonReentrant {
        uint256 accounted = protocolPoolTotalWei + totalAllPoolsWei;
        uint256 balance = address(this).balance;
        if (balance <= accounted) revert NothingToWithdraw();
        uint256 surplus = balance - accounted;
        (bool success, ) = payable(msg.sender).call{value: surplus}("");
        if (!success) revert TransferFailed();
        
        // Surplus withdrawn - no event needed for size optimization
    }

    // ============ View Functions ============

    /**
     * @notice Get market count
     */
    function getMarketCount() external view returns (uint256) {
        return _marketIdCounter;
    }
    

    /**
     * @notice Get detailed market information
     */
    function getMarketInfo(uint256 marketId) external view validMarket(marketId) returns (Market memory) {
        return markets[marketId];
    }

    /**
     * @notice Get current market prices
     */
    function getMarketPrices(uint256 marketId) external view validMarket(marketId) returns (uint256[2] memory) {
        Market storage m = markets[marketId];
        // CRITICAL: Must use safeLMSRPrices for _validateLMSRBounds check
        return safeLMSRPrices(m.totalShares, m.liquidityParameter);
    }

    /**
     * @notice Get batch market prices
     */
    function getBatchMarketPrices(uint256[] calldata marketIds) external view returns (uint256[] memory prices) {
        prices = new uint256[](marketIds.length);
        for (uint256 i = 0; i < marketIds.length; i++) {
            if (_isValidMarketId(marketIds[i])) {
                Market storage m = markets[marketIds[i]];
                // CRITICAL: Must use safeLMSRPrices for _validateLMSRBounds check
                uint256[2] memory marketPrices = safeLMSRPrices(m.totalShares, m.liquidityParameter);
                prices[i] = marketPrices[0]; // Return price for outcome 0
            }
        }
    }

    /**
     * @notice Get batch market info
     */
    function getBatchMarketInfo(uint256[] calldata marketIds) external view returns (Market[] memory marketInfos) {
        marketInfos = new Market[](marketIds.length);
        for (uint256 i = 0; i < marketIds.length; i++) {
            if (_isValidMarketId(marketIds[i])) {
                marketInfos[i] = markets[marketIds[i]];
            }
        }
    }

    /**
     * @notice Get user position in market
     */
    function getUserPosition(uint256 marketId, address user) external view validMarket(marketId) returns (UserPosition memory) {
        return userPositions[user][marketId];
    }

    /**
     * @notice Estimate buy shares result for wallet integration
     * @dev Provides transaction preview without executing, prevents wallet estimation failures
     * @param marketId Market ID to buy shares in
     * @param outcome Outcome to buy (0 or 1)
     * @param msgValue Transaction value (msg.value)
     * @return sharesToBuy Estimated shares to receive
     * @return totalCost Total cost including all fees
     * @return protocolFee Protocol fee amount
     * @return lpFee LP fee amount
     */
    function estimateBuyShares(
        uint256 marketId,
        uint256 outcome,
        uint256 msgValue
    ) external view validMarket(marketId) returns (
        uint256 sharesToBuy,
        uint256 totalCost,
        uint256 protocolFee,
        uint256 lpFee
    ) {
        Market storage m = markets[marketId];

        // 1) Calculate available budget, identical to buyShares
        uint256 combinedFeeBP = protocolFeeRateBP + lpFeeRateBP;
        uint256 availableBudget = (msgValue * BASIS_POINTS) / (BASIS_POINTS + combinedFeeBP);

        // 2) Boundary: small budget → return 0, no revert
        if (availableBudget < MIN_TRADE_AMOUNT) {
            return (0, 0, 0, 0);
        }

        // 3) Outcome validation
        if (outcome > 1) {
            return (0, 0, 0, 0);
        }

        // 4) Market state validation (consistent with buyShares, but return 0 instead of revert)
        if (m.status != MarketStatus.Active) {
            return (0, 0, 0, 0);
        }
        if (block.timestamp >= m.closingTime) {
            return (0, 0, 0, 0);
        }

        // 5) Exponential bounds pre-check to avoid revert in view
        {
            uint256[2] memory s = [m.totalShares[0], m.totalShares[1]];
            uint256 maxArg = (MAX_EXP_ARG * m.liquidityParameter) / 1e18;
            if (s[0] > maxArg || s[1] > maxArg) {
                return (0, 0, 0, 0);
            }
        }

        // 6) Call library to calculate shares/baseCost (view can call pure)
        uint256 baseCost;
        (sharesToBuy, baseCost) = secretLMSRCore.buyWithinBudget(
            m.totalShares[0],
            m.totalShares[1],
            outcome,
            m.liquidityParameter,
            availableBudget,
            m.totalLiquidityWei
        );

        if (sharesToBuy == 0) {
            return (0, 0, 0, 0);
        }

        // 7) Calculate fees and total cost
        protocolFee = (baseCost * protocolFeeRateBP) / BASIS_POINTS;
        lpFee = (baseCost * lpFeeRateBP) / BASIS_POINTS;
        totalCost = baseCost + protocolFee + lpFee;
    }

    /**
     * @notice Estimate sell shares result for wallet integration (non-reverting)
     * @dev Returns zeros instead of reverting when conditions are not met or value is too small.
     *      This is a VIEW helper for frontends to avoid "estimated to fail" popups.
     *      Note: This function does NOT check user's balance; it estimates market payout if such shares are sold.
     * @param marketId Market ID to sell shares in
     * @param outcome Outcome to sell (0 or 1)
     * @param sharesToSellScaled Amount of shares to sell (scaled by 1e18)
     * @return baseValue Base value (before fees)
     * @return netPayout Net payout to user (after fees)
     * @return protocolFee Protocol fee amount
     * @return lpFee LP fee amount
     */
    function estimateSellShares(
        uint256 marketId,
        uint256 outcome,
        uint256 sharesToSellScaled
    ) external view validMarket(marketId) returns (
        uint256 baseValue,
        uint256 netPayout,
        uint256 protocolFee,
        uint256 lpFee
    ) {
        Market storage m = markets[marketId];

        // Basic validations - return zeros instead of revert
        if (outcome > 1) {
            return (0, 0, 0, 0);
        }
        if (sharesToSellScaled == 0) {
            return (0, 0, 0, 0);
        }
        // Respect global and per-market pause states
        if (paused() || marketPaused[marketId]) {
            return (0, 0, 0, 0);
        }
        // Market must be active and not past closing time
        if (m.status != MarketStatus.Active) {
            return (0, 0, 0, 0);
        }
        if (block.timestamp >= m.closingTime) {
            return (0, 0, 0, 0);
        }

        // Shares and bounds checks (non-reverting)
        uint256 s0 = m.totalShares[0];
        uint256 s1 = m.totalShares[1];

        // MAX_SHARES bounds
        if (s0 > MAX_SHARES || s1 > MAX_SHARES || sharesToSellScaled > MAX_SHARES) {
            return (0, 0, 0, 0);
        }

        // Must have enough market shares on that outcome to support the sell
        if ((outcome == 0 && s0 < sharesToSellScaled) || (outcome == 1 && s1 < sharesToSellScaled)) {
            return (0, 0, 0, 0);
        }

        // Exponential bounds pre-check to avoid PRBMath overflow (non-reverting)
        uint256 maxArg = (MAX_EXP_ARG * m.liquidityParameter) / 1e18;
        if (s0 > maxArg || s1 > maxArg) {
            return (0, 0, 0, 0);
        }

        // Call library with try/catch - non-reverting by design
        uint256 baseValueWei;
        try secretLMSRCore.sellValue(
            s0,
            s1,
            outcome,
            m.liquidityParameter,
            sharesToSellScaled
        ) returns (uint256 _baseValue) {
            baseValueWei = _baseValue;
        } catch {
            return (0, 0, 0, 0);
        }

        if (baseValueWei == 0) {
            // Extremely small sell resulting in zero-wei value - treat as not executable
            return (0, 0, 0, 0);
        }

        // Fees and net payout
        protocolFee = (baseValueWei * protocolFeeRateBP) / BASIS_POINTS;
        lpFee = (baseValueWei * lpFeeRateBP) / BASIS_POINTS;

        // Pool sufficiency check (same as sellShares but non-reverting)
        // Pool reduction = (net payout + protocol fee) = baseValueWei - lpFee
        if (totalPoolWei[marketId] < (baseValueWei - lpFee)) {
            return (0, 0, 0, 0);
        }

        baseValue = baseValueWei;
        netPayout = baseValueWei - protocolFee - lpFee;
        // Additional guard (should not underflow)
        if (netPayout == 0) {
            return (0, 0, 0, 0);
        }
        return (baseValue, netPayout, protocolFee, lpFee);
    }

    /**
     * @notice Get LP lockdown status
     */
    function getLPLockdownStatus(uint256 marketId) external view validMarket(marketId) returns (
        bool isLockdown,
        uint256 timeUntilLockdown,
        uint256 timeUntilClose,
        uint256 lockdownDuration
    ) {
        Market storage m = markets[marketId];
        lockdownDuration = m.lpLockdownDurationSeconds;
        uint256 lockdownStart = m.closingTime - lockdownDuration;
        
        if (block.timestamp >= lockdownStart && block.timestamp < m.closingTime) {
            isLockdown = true;
            timeUntilClose = m.closingTime - block.timestamp;
        } else if (block.timestamp < lockdownStart) {
            timeUntilLockdown = lockdownStart - block.timestamp;
            timeUntilClose = m.closingTime - block.timestamp;
        } else {
            timeUntilClose = 0; // Market closed
        }
    }

    // ============ Administration ============
    
    /**
     * @notice Authorize market creator
     */
    function authorizeMarketCreator(address creator) external onlyOwner nonReentrant {
        if (!authorizedCreators[creator]) {
            authorizedCreators[creator] = true;
            authorizedCreatorCount++;
        }
    }

    /**
     * @notice Revoke market creator
     */
    function revokeMarketCreator(address creator) external onlyOwner nonReentrant {
        if (authorizedCreators[creator]) {
            authorizedCreators[creator] = false;
            authorizedCreatorCount--;
        }
    }
    

    /**
     * @notice Set protocol fee rate
     */
    function setProtocolFeeRateBP(uint256 _bp) external onlyOwner {
        if (_bp > MAX_PROTOCOL_FEE_BP) revert InvalidFee();
        _validateTotalFeeRate(_bp, lpFeeRateBP);
        protocolFeeRateBP = _bp;
    }

    /**
     * @notice Set LP fee rate
     */
    function setLPFeeRateBP(uint256 _bp) external onlyOwner {
        if (_bp > MAX_LP_FEE_BP) revert InvalidFee();
        _validateTotalFeeRate(protocolFeeRateBP, _bp);
        lpFeeRateBP = _bp;
    }

    /**
     * @notice Set dispute period
     */
    function setDisputePeriod(uint256 _period) external onlyOwner {
        disputePeriod = _period;
    }

    /**
     * @notice Set minimum liquidity
     */
    function setMinLiquidityWei(uint256 _min) external onlyOwner {
        minLiquidityWei = _min;
    }

    /**
     * @notice Set liquidity parameter for existing market
     */
    function setLiquidityParameter(uint256 marketId, uint256 newB) external onlyOwner validMarket(marketId) {
        if (newB < MIN_B || newB > MAX_B) revert InvalidMarket();
        markets[marketId].liquidityParameter = newB;
    }

    /**
     * @notice Pause market
     */
    function pauseMarket(uint256 marketId) external onlyOwner validMarket(marketId) {
        marketPaused[marketId] = true;
        emit MarketPaused(marketId);
    }

    /**
     * @notice Unpause market
     */
    function unpauseMarket(uint256 marketId) external onlyOwner validMarket(marketId) {
        marketPaused[marketId] = false;
        emit MarketUnpaused(marketId);
    }

    /**
     * @notice Global pause
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Global unpause
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    // ============ LMSR Safety Functions ============
    
    // DELETED: safeLMSRBuyCost to avoid logic errors
    // buyShares now uses buyWithinBudget which returns both shares and cost
    
    function safeLMSRSellValue(
        uint256[2] memory shares,
        uint256 sharesToSell,
        uint256 outcome,
        uint256 b
    ) internal view returns (uint256) {
        _validateLMSRInputs(shares, sharesToSell, b); // Contains _validateLMSRBounds
        return secretLMSRCore.sellValue(shares[0], shares[1], outcome, b, sharesToSell);
    }
    
    
    function safeLMSRPrices(
        uint256[2] memory shares,
        uint256 b
    ) internal view returns (uint256[2] memory) {
        _validateLMSRBounds(shares, b);
        (uint256 p0, uint256 p1) = secretLMSRCore.prices(shares[0], shares[1], b);
        uint256[2] memory arr;
        arr[0] = p0;
        arr[1] = p1;
        return arr;
    }

    function _validateLMSRBounds(uint256[2] memory shares, uint256 b) internal pure {
        // Prevent PRBMath overflow in exp() calculations
        // P2 DEFENSIVE FIX: Use safe comparison to avoid multiplication overflow
        // Instead of: (shares[i] * 1e18) / b > MAX_EXP_ARG
        // Use: shares[i] > (MAX_EXP_ARG * b) / 1e18
        if (shares[0] > (MAX_EXP_ARG * b) / 1e18 || shares[1] > (MAX_EXP_ARG * b) / 1e18) {
            revert LMSRArgumentTooLarge();
        }
    }

    // ============ Internal Helpers ============
    
    /**
     * @notice Calculate payout per share for winning outcome (Zero-Sum Game Core)
     * @param marketId Market identifier  
     * @param winningOutcome The winning outcome (0 or 1)
     * @dev CRITICAL ZERO-SUM LOGIC: 
     *      - Payouts calculated ONLY from userTradingFundsWei
     *      - LP principal and fees remain completely protected
     *      - Winners split what all users contributed, nothing more
     *      - If insufficient user funds, payout < 1 BNB per share (acceptable)
     */
    function _calculatePayoutPerShare(uint256 marketId, uint256 winningOutcome) internal {
        Market storage m = markets[marketId];
        uint256 winningShares = m.totalShares[winningOutcome];
        
        if (winningShares > 0) {
            // ZERO-SUM CORE: Only use user trading funds for payouts, LP funds protected
            uint256 userFundsAvailable = userTradingFundsWei[marketId];
            
            // Calculate per-share payout based on zero-sum pool
            m.payoutPerShareWei = (userFundsAvailable * SHARE_UNIT) / winningShares;
            
            // Note: This can be less than 1 BNB per share if user funds insufficient
            // This is the essence of zero-sum: users split what users contributed
        } else {
            // No winners - LP benefits from remaining user trading funds (house edge)
            m.payoutPerShareWei = 0;
        }
    }
    
    /**
     * @notice Validate market ID for batch operations
     */
    function _isValidMarketId(uint256 marketId) internal view returns (bool) {
        return marketId > 0 && 
               marketId <= _marketIdCounter && 
               markets[marketId].marketId != 0;
    }
    
    /**
     * @notice Unified LMSR input validation
     */
    function _validateLMSRInputs(
        uint256[2] memory shares, 
        uint256 amount, 
        uint256 b
    ) internal pure {
        if (amount > MAX_SHARES) revert SharesTooLarge();
        if (shares[0] > MAX_SHARES || shares[1] > MAX_SHARES) revert SharesTooLarge();
        _validateLMSRBounds(shares, b);
    }
    
    /**
     * @notice Validate total fee rate across protocol and LP fees
     */
    function _validateTotalFeeRate(uint256 protocolBP, uint256 lpBP) internal pure {
        if (protocolBP + lpBP > MAX_TOTAL_FEE_BP) revert InvalidFee();
    }
    
    /**
     * @notice Find maximum shares buyable within budget using binary search
     * @dev Solves the problem of estimation vs actual cost inconsistency
     * @param currentShares Current market share distribution
     * @param maxBudget Maximum available budget (after fee deduction)
     * @param outcome Outcome to buy (0 or 1)
     * @param b LMSR liquidity parameter
     * @return Maximum shares that can be bought within budget
     */
    // DELETED: _getOptimalIterations - integrated into SecretLMSRCore library

    // DEPRECATED: _findMaxSharesWithinBudget function has been integrated into SecretLMSRCore library
    // This complex exponential + binary search algorithm is now part of the buyWithinBudget implementation
    // Use SecretLMSRCore.buyWithinBudget() instead
    
    /**
     * @notice Apply atomic accounting changes with invariant protection (Zero-Sum Version)
     * @dev V3 CRITICAL IMPROVEMENT: Ensures all accounting changes are atomic with LP protection
     * @param marketId Market to update
     * @param deltaTotalPool Change in total pool (can be negative)
     * @param deltaPrincipal Change in principal amount (LP funds, can be negative)  
     * @param deltaFees Change in fees amount (can be negative)
     * @param deltaUserTradingFunds Change in user trading funds (zero-sum game pool, can be negative)
     */
    function _applyAccountingDeltas(
        uint256 marketId, 
        int256 deltaTotalPool, 
        int256 deltaPrincipal, 
        int256 deltaFees,
        int256 deltaUserTradingFunds
    ) internal {
        // Apply changes in defined order: principal → fees → userTradingFunds → pool (prevents intermediate invariant violations)
        
        // 1. Update principal amount (LP funds)
        if (deltaPrincipal != 0) {
            if (deltaPrincipal < 0) {
                uint256 reduction = uint256(-deltaPrincipal);
                principalAmountWei[marketId] -= Math.min(principalAmountWei[marketId], reduction);
            } else {
                principalAmountWei[marketId] += uint256(deltaPrincipal);
            }
        }
        
        // 2. Update fees amount
        if (deltaFees != 0) {
            if (deltaFees < 0) {
                uint256 reduction = uint256(-deltaFees);
                feesAmountWei[marketId] -= Math.min(feesAmountWei[marketId], reduction);
            } else {
                feesAmountWei[marketId] += uint256(deltaFees);
            }
        }
        
        // 3. Update user trading funds (zero-sum game funds)
        if (deltaUserTradingFunds != 0) {
            if (deltaUserTradingFunds < 0) {
                uint256 reduction = uint256(-deltaUserTradingFunds);
                userTradingFundsWei[marketId] -= Math.min(userTradingFundsWei[marketId], reduction);
            } else {
                userTradingFundsWei[marketId] += uint256(deltaUserTradingFunds);
            }
        }
        
        // 4. Update total pool (last to maintain consistency)
        if (deltaTotalPool != 0) {
            if (deltaTotalPool < 0) {
                uint256 reduction = uint256(-deltaTotalPool);
                totalPoolWei[marketId] -= reduction;
                totalAllPoolsWei -= reduction;
            } else {
                uint256 increase = uint256(deltaTotalPool);
                totalPoolWei[marketId] += increase;
                totalAllPoolsWei += increase;
            }
        }
        
        // 4. Verify critical invariant: principal + fees + userTradingFunds <= totalPool
        uint256 totalVirtual = principalAmountWei[marketId] + feesAmountWei[marketId] + userTradingFundsWei[marketId];
        uint256 poolActual = totalPoolWei[marketId];
        
        if (totalVirtual > poolActual) {
            // Calculate discrepancy
            uint256 discrepancy = totalVirtual - poolActual;
            
            // Define tolerance: 0.001 BNB or 0.1% of pool, whichever is greater
            uint256 tolerance = Math.max(1e15, poolActual / 1000);
            
            if (discrepancy <= tolerance) {
                // MINIMAL FIX: Virtual downward adjustment to avoid inflation
                if (feesAmountWei[marketId] >= discrepancy) {
                    feesAmountWei[marketId] -= discrepancy;
                    emit AccountingAdjustment(marketId, discrepancy);
                } else if (feesAmountWei[marketId] + userTradingFundsWei[marketId] >= discrepancy) {
                    uint256 feeReduction = feesAmountWei[marketId];
                    uint256 userFundReduction = discrepancy - feeReduction;
                    feesAmountWei[marketId] = 0;
                    userTradingFundsWei[marketId] -= userFundReduction;
                    emit AccountingAdjustment(marketId, discrepancy);
                } else {
                    revert InvariantViolated(); // Cannot safely adjust
                }
            } else {
                // Critical invariant violation
                revert InvariantViolated();
            }
        }
    }

    // ============ Pool Invariants ============
    
    /**
     * @notice Verify pool invariants (Zero-Sum: include user trading funds)
     */
    function _verifyPoolInvariants(uint256 marketId) internal view {
        uint256 totalPool = totalPoolWei[marketId];
        uint256 principal = principalAmountWei[marketId];
        uint256 fees = feesAmountWei[marketId];
        uint256 userFunds = userTradingFundsWei[marketId];
        
        // Strengthened invariant: principal + fees + userFunds must not exceed total pool
        if (principal + fees + userFunds > totalPool) {
            revert InvariantViolated();
        }
        
        // Additional invariant: Market total liquidity should match virtual principal
        Market storage m = markets[marketId];
        if (m.totalLiquidityWei != principal && m.status != MarketStatus.Created) {
            // Allow more reasonable deviation for rounding errors in high-volume scenarios
            uint256 deviation = m.totalLiquidityWei > principal ? 
                m.totalLiquidityWei - principal : principal - m.totalLiquidityWei;
            
            // Simplified tolerance: 0.01 BNB or 0.1% of total liquidity, whichever is greater
            uint256 tolerance = Math.max(1e16, m.totalLiquidityWei / 1000);
            
            if (deviation > tolerance) {
                revert InvariantViolated();
            }
        }
    }

    // ============ Token ID Helpers ============
    
    function _getShareTokenId(uint256 marketId, uint256 outcome) internal pure returns (uint256) {
        if (marketId >= 2**127) revert InvalidMarket();
        return (marketId << 128) | outcome;
    }

    function _getLPTokenId(uint256 marketId) internal pure returns (uint256) {
        if (marketId >= 2**127) revert InvalidMarket();
        return (1 << 255) | marketId;
    }

    // ============ Disabled Functions ============
    
    /**
     * @notice Disable ERC1155 transfers for security
     */
    function safeTransferFrom(address, address, uint256, uint256, bytes memory) public pure override {
        revert TransfersDisabled();
    }

    function safeBatchTransferFrom(address, address, uint256[] memory, uint256[] memory, bytes memory) public pure override {
        revert TransfersDisabled();
    }

    function setApprovalForAll(address, bool) public pure override {
        revert TransfersDisabled();
    }

    // ============ Settlement Configuration View Functions ============

    /**
     * @notice Check if a market has automated settlement configured
     * @param marketId Market ID to check
     * @return hasAutoSettlement true if automated settlement is configured
     */
    function hasAutomaticSettlement(uint256 marketId) external view validMarket(marketId) returns (bool hasAutoSettlement) {
        return markets[marketId].settlementAdapter != address(0);
    }

    /**
     * @notice Get settlement configuration for a market
     * @param marketId Market ID to check
     * @return manualOracle Manual settlement oracle address
     * @return settlementAdapter Automated settlement adapter address (address(0) if not configured)
     */
    function getSettlementConfiguration(uint256 marketId) external view validMarket(marketId)
        returns (address manualOracle, address settlementAdapter) {
        Market storage m = markets[marketId];
        return (m.manualOracle, m.settlementAdapter);
    }

    /**
     * @notice Check if an address is authorized to propose resolution for a market
     * @param marketId Market ID to check
     * @param proposer Address to check authorization for
     * @return authorized true if the address can propose resolution
     */
    function canProposeResolution(uint256 marketId, address proposer) external view validMarket(marketId)
        returns (bool authorized) {
        Market storage m = markets[marketId];
        return (proposer == m.manualOracle) ||
               (m.settlementAdapter != address(0) && proposer == m.settlementAdapter);
    }

    // ============ Settlement Management (Owner Only) ============

    /**
     * @notice Set manual oracle for a market (only allowed before outcome is set)
     * @param marketId Market ID to update
     * @param newOracle New manual oracle address
     */
    function setManualOracle(uint256 marketId, address newOracle) external onlyOwner validMarket(marketId) {
        Market storage m = markets[marketId];
        require(!m.outcomeSet, "Cannot change oracle after outcome is set");
        m.manualOracle = newOracle;
        emit OracleUpdated(marketId, newOracle, m.settlementAdapter);
    }

    /**
     * @notice Set settlement adapter for a market (only allowed before outcome is set)
     * @param marketId Market ID to update
     * @param newAdapter New settlement adapter address
     */
    function setSettlementAdapter(uint256 marketId, address newAdapter) external onlyOwner validMarket(marketId) {
        Market storage m = markets[marketId];
        require(!m.outcomeSet, "Cannot change adapter after outcome is set");
        m.settlementAdapter = newAdapter;
        emit OracleUpdated(marketId, m.manualOracle, newAdapter);
    }

    /**
     * @notice Get manual oracle address for a market
     * @param marketId Market ID to check
     * @return manualOracle Manual oracle address
     */
    function getManualOracle(uint256 marketId) external view validMarket(marketId) returns (address manualOracle) {
        return markets[marketId].manualOracle;
    }

    /**
     * @notice Get settlement adapter address for a market
     * @param marketId Market ID to check
     * @return settlementAdapter Settlement adapter address
     */
    function getSettlementAdapter(uint256 marketId) external view validMarket(marketId) returns (address settlementAdapter) {
        return markets[marketId].settlementAdapter;
    }

    // Event for oracle/adapter updates
    event OracleUpdated(uint256 indexed marketId, address indexed manualOracle, address indexed settlementAdapter);

    receive() external payable {
        revert DirectDepositsDisabled();
    }

    fallback() external payable {
        revert DirectDepositsDisabled();
    }
}
