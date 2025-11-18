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


