// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

/**
 * @title FootballDeathHandicapSettlement
 * @dev Football settlement contract for converting ternary results to binary death handicap outcomes
 * @notice Integrates with Chainlink sports data sources for automated football match settlement
 * @notice All handicaps are death betting (0.5 multiples only): +/-0.5, +/-1.5, +/-2.5, +/-3.5, +/-4.5
 */

// ============ External Interfaces ============

interface ISportMonksChainlink {
    struct GameResult {
        uint256 gameId;
        uint256 homeScore;
        uint256 awayScore;
        uint256 gameStatus;      // 0=scheduled, 1=live, 2=finished, 3=cancelled
        uint256 lastUpdated;
        bool isValid;
    }

    function getGameResult(uint256 gameId) external view returns (GameResult memory);
    function getMultipleGameResults(uint256[] calldata gameIds) external view returns (GameResult[] memory);
}

interface ITheRundownSports {
    struct SportEvent {
        uint256 eventId;
        uint256 homeTeamScore;
        uint256 awayTeamScore;
        uint256 status;          // 1=scheduled, 2=active, 3=complete, 4=cancelled
        uint256 updatedAt;
    }

    function getEventResult(uint256 eventId) external view returns (SportEvent memory);
}

interface IOddsMarket {
    function proposeResultFromExternalOracle(uint256 marketId, uint256 outcome) external;
}

contract FootballDeathHandicapSettlement is Ownable, ReentrancyGuard, Pausable {

    // ============ Constants ============

    // CRITICAL FIX: Changed from int16 to int256 to prevent overflow
    // Supported handicap range: -4.5 to +4.5 goals, stored as half values
    int256 public constant MIN_HANDICAP_HALF = -9;  // -4.5 * 2
    int256 public constant MAX_HANDICAP_HALF = 9;   // +4.5 * 2

    // Data validation constants
    uint256 public constant DATA_FRESHNESS_REQUIREMENT = 300;    // 5 minutes in seconds
    uint256 public constant MIN_SCORE_DIFF_FOR_VERIFICATION = 2; // Score difference requiring dual verification
    uint256 public constant MAX_REASONABLE_SCORE = 20;           // Maximum reasonable score for validation

    // ============ Enums ============

    enum DataStatus {
        NOT_AVAILABLE,      // Data not available from sources
        AVAILABLE,          // Data available and consistent
        INCONSISTENT,       // Data sources show different results
        MANUAL_REQUIRED     // Manual intervention required
    }

    // ============ Structs ============

    struct DataSourceConfig {
        address sportMonksChainlink;     // SportMonks Chainlink node address
        address theRundownSports;        // TheRundown sports data address
        address backupDataSource;        // Backup data source address
        uint256 dataTimeout;             // Data timeout in seconds
        bool enableMultiSource;          // Enable multi-source verification
    }

    struct FootballGame {
        uint256 gameId;                  // Internal game ID
        uint256 sportMonksGameId;        // SportMonks game ID
        uint256 theRundownEventId;       // TheRundown event ID
        uint256 homeTeamId;              // Home team identifier
        uint256 awayTeamId;              // Away team identifier
        string gameDescription;          // Game description (e.g., "Man City vs Arsenal")
        uint256 scheduledTime;           // Scheduled start time
        bool settled;                    // Settlement status
        uint256 settlementTime;          // Time when settled
    }

    struct DeathHandicapConfig {
        uint256 gameId;                  // Football game ID
        int256 handicapHalf;             // CRITICAL FIX: Changed from int16 to int256 to prevent overflow
        address targetMarket;            // Target binary prediction market contract
        uint256 targetMarketId;          // Target market ID
        bool isHomeFavored;             // true=home team favored, false=away team favored
        uint256 dataSourcePriority;     // 0=SportMonks priority, 1=TheRundown priority
        bool settled;                    // Settlement status
    }

    struct DataSourceResult {
        bool success;                    // Operation success status
        uint256 homeScore;               // Home team score
        uint256 awayScore;               // Away team score
        bool isFinished;                 // Game finished status
        uint256 timestamp;               // Data timestamp
        string source;                   // Data source name
    }

    struct DataConflict {
        uint256 gameId;                  // Game ID with conflict
        DataSourceResult sportMonksResult; // SportMonks data
        DataSourceResult theRundownResult; // TheRundown data
        uint256 conflictTime;            // When conflict was detected
        bool resolved;                   // Resolution status
        string resolution;               // Resolution details
    }

    // ============ State Variables ============

    DataSourceConfig public dataSourceConfig;

    // Game and market mappings
    mapping(uint256 => FootballGame) public footballGames;
    mapping(uint256 => DeathHandicapConfig) public deathHandicaps;
    mapping(uint256 => uint256[]) public gameToHandicapConfigs; // gameId => configId[]

    // Data conflict management
    mapping(uint256 => DataConflict) public dataConflicts;
    mapping(uint256 => bool) public gamesRequiringManualIntervention;
    uint256 public dataConflictCount;

    // Counters
    uint256 private gameIdCounter = 1;
    uint256 private configIdCounter = 1;

    // ============ Events ============

    event DataSourceConfigured(
        address indexed sportMonks,
        address indexed theRundown,
        address indexed backup
    );

    event GameRegistered(
        uint256 indexed gameId,
        uint256 sportMonksId,
        uint256 theRundownId,
        string description
    );

    event DeathHandicapConfigured(
        uint256 indexed configId,
        uint256 indexed gameId,
        int256 handicapHalf, // CRITICAL FIX: Changed from int16 to int256 to prevent overflow
        bool isHomeFavored,
        address targetMarket,
        uint256 targetMarketId
    );

    event DataInconsistencyDetected(
        uint256 indexed gameId,
        uint256 sportMonksHome,
        uint256 sportMonksAway,
        uint256 theRundownHome,
        uint256 theRundownAway,
        uint256 conflictId
    );

    event ManualInterventionRequired(uint256 indexed gameId, string reason);

    event DeathHandicapSettled(
        uint256 indexed configId,
        uint256 indexed gameId,
        uint256 homeScore,
        uint256 awayScore,
        int16 scoreDiffHalf,
        uint256 result
    );

    event GameManuallySettled(
        uint256 indexed gameId,
        uint256 homeScore,
        uint256 awayScore,
        string verificationSource
    );

    event DataConflictResolved(
        uint256 indexed gameId,
        uint256 finalHome,
        uint256 finalAway,
        string method
    );

    event ConflictResolved(uint256 indexed conflictId, string resolution);
    event ManualInterventionReset(uint256 indexed gameId);
    event EmergencyScoreSet(uint256 gameId, uint256 homeScore, uint256 awayScore, string reason);

    // ============ Constructor ============

    constructor() {}

    // ============ Data Source Configuration ============

    /**
     * @notice Configure data source addresses and settings
     * @param _sportMonksChainlink SportMonks Chainlink node address
     * @param _theRundownSports TheRundown sports oracle address
     * @param _backupDataSource Backup data source address
     * @param _dataTimeout Data timeout in seconds
     * @param _enableMultiSource Enable multi-source verification
     */
    function configureDataSources(
        address _sportMonksChainlink,
        address _theRundownSports,
        address _backupDataSource,
        uint256 _dataTimeout,
        bool _enableMultiSource
    ) external onlyOwner {
        require(_sportMonksChainlink != address(0), "Invalid SportMonks address");
        require(_theRundownSports != address(0), "Invalid TheRundown address");
        require(_dataTimeout >= 60 && _dataTimeout <= 3600, "Invalid timeout range");

        dataSourceConfig = DataSourceConfig({
            sportMonksChainlink: _sportMonksChainlink,
            theRundownSports: _theRundownSports,
            backupDataSource: _backupDataSource,
            dataTimeout: _dataTimeout,
            enableMultiSource: _enableMultiSource
        });

        emit DataSourceConfigured(_sportMonksChainlink, _theRundownSports, _backupDataSource);
    }

    // ============ Game Registration ============

    /**
     * @notice Register a football game with multiple data source IDs
     * @param sportMonksGameId SportMonks game identifier
     * @param theRundownEventId TheRundown event identifier
     * @param homeTeamId Home team identifier
     * @param awayTeamId Away team identifier
     * @param gameDescription Human-readable game description
     * @param scheduledTime Scheduled start time (Unix timestamp)
     * @return gameId The assigned internal game ID
     */
    function registerFootballGame(
        uint256 sportMonksGameId,
        uint256 theRundownEventId,
        uint256 homeTeamId,
        uint256 awayTeamId,
        string calldata gameDescription,
        uint256 scheduledTime
    ) external onlyOwner returns (uint256 gameId) {
        require(bytes(gameDescription).length > 0, "Empty game description");
        require(scheduledTime > block.timestamp, "Invalid scheduled time");
        require(homeTeamId != awayTeamId, "Teams cannot be the same");

        gameId = gameIdCounter++;

        footballGames[gameId] = FootballGame({
            gameId: gameId,
            sportMonksGameId: sportMonksGameId,
            theRundownEventId: theRundownEventId,
            homeTeamId: homeTeamId,
            awayTeamId: awayTeamId,
            gameDescription: gameDescription,
            scheduledTime: scheduledTime,
            settled: false,
            settlementTime: 0
        });

        emit GameRegistered(gameId, sportMonksGameId, theRundownEventId, gameDescription);

        return gameId;
    }

    // ============ Death Handicap Configuration ============

    /**
     * @notice Configure a death handicap market for a football game
     * @param gameId Football game ID
     * @param handicapHalf Handicap value * 2 (e.g., 1.5 goals = 3)
     * @param targetMarket Target binary prediction market contract
     * @param targetMarketId Target market ID
     * @param isHomeFavored true if home team is favored, false if away team is favored
     * @param dataSourcePriority 0=SportMonks priority, 1=TheRundown priority
     * @return configId The assigned configuration ID
     */
    function configureDeathHandicap(
        uint256 gameId,
        int256 handicapHalf, // CRITICAL FIX: Changed from int16 to int256 to prevent overflow
        address targetMarket,
        uint256 targetMarketId,
        bool isHomeFavored,
        uint256 dataSourcePriority
    ) external onlyOwner returns (uint256 configId) {
        require(footballGames[gameId].gameId != 0, "Game not registered");
        require(!footballGames[gameId].settled, "Game already settled");
        require(handicapHalf >= MIN_HANDICAP_HALF && handicapHalf <= MAX_HANDICAP_HALF, "Invalid handicap range");
        require(handicapHalf != 0, "Zero handicap not allowed in death betting");
        // CRITICAL FIX: Since we store x2 values (0.5→1, 1.5→3), require odd numbers for 0.5 multiples
        require((uint256(handicapHalf) & 1) == 1, "Must be 0.5 multiple (odd number required)");
        require(targetMarket != address(0), "Invalid target market");
        require(dataSourcePriority <= 1, "Invalid data source priority");

        // Validate handicap direction consistency
        if (isHomeFavored) {
            require(handicapHalf > 0, "Home favored must have positive handicap");
        } else {
            require(handicapHalf < 0, "Away favored must have negative handicap");
        }

        configId = configIdCounter++;

        deathHandicaps[configId] = DeathHandicapConfig({
            gameId: gameId,
            handicapHalf: handicapHalf,
            targetMarket: targetMarket,
            targetMarketId: targetMarketId,
            isHomeFavored: isHomeFavored,
            dataSourcePriority: dataSourcePriority,
            settled: false
        });

        // Add to game's handicap config list
        gameToHandicapConfigs[gameId].push(configId);

        emit DeathHandicapConfigured(
            configId,
            gameId,
            handicapHalf,
            isHomeFavored,
            targetMarket,
            targetMarketId
        );

        return configId;
    }

    // ============ Settlement Functions ============

    /**
     * @notice Settle a death handicap market using Chainlink data sources
     * @param configId Configuration ID to settle
     */
    function settleDeathHandicap(uint256 configId) external nonReentrant whenNotPaused {
        DeathHandicapConfig storage config = deathHandicaps[configId];
        require(config.gameId != 0, "Configuration not found");
        require(!config.settled, "Already settled");

        FootballGame storage game = footballGames[config.gameId];
        require(!game.settled, "Game already settled");

        // Get game score with strict validation
        (uint256 homeScore, uint256 awayScore, bool isFinished) = _getGameScoreStrict(config.gameId);
        require(isFinished, "Game not finished");

        // Calculate death handicap result
        uint256 result = _calculateDeathHandicapResult(
            homeScore,
            awayScore,
            config.handicapHalf,
            config.isHomeFavored
        );

        // Mark as settled
        config.settled = true;

        // Submit result to target market
        IOddsMarket(config.targetMarket).proposeResultFromExternalOracle(
            config.targetMarketId,
            result
        );

        // Calculate score difference for event
        int16 scoreDiffHalf = int16(int256(homeScore) * 2 - int256(awayScore) * 2);

        emit DeathHandicapSettled(
            configId,
            config.gameId,
            homeScore,
            awayScore,
            scoreDiffHalf,
            result
        );
    }

    /**
     * @notice Manually set game score and settle all handicaps (owner only)
     * @param gameId Game ID
     * @param homeScore Home team score
     * @param awayScore Away team score
     * @param verificationSource Source of verification
     */
    function manualSetScore(
        uint256 gameId,
        uint256 homeScore,
        uint256 awayScore,
        string calldata verificationSource
    ) external onlyOwner nonReentrant {
        FootballGame storage game = footballGames[gameId];
        require(game.gameId != 0, "Game not found");
        require(!game.settled, "Game already settled");
        require(gamesRequiringManualIntervention[gameId], "Manual intervention not required");
        require(bytes(verificationSource).length > 0, "Verification source required");

        // Validate score reasonableness
        require(homeScore <= MAX_REASONABLE_SCORE && awayScore <= MAX_REASONABLE_SCORE, "Unrealistic score");

        // Settle all handicap configs for this game
        _settleAllHandicapsForGame(gameId, homeScore, awayScore);

        // Update game state
        game.settled = true;
        game.settlementTime = block.timestamp;
        gamesRequiringManualIntervention[gameId] = false;

        emit DataConflictResolved(gameId, homeScore, awayScore, verificationSource);
        emit GameManuallySettled(gameId, homeScore, awayScore, verificationSource);
    }

    /**
     * @notice Emergency score setting for critical situations (owner only)
     * @param gameId Game ID
     * @param homeScore Home team score
     * @param awayScore Away team score
     * @param reason Emergency reason
     */
    function emergencySetScore(
        uint256 gameId,
        uint256 homeScore,
        uint256 awayScore,
        string calldata reason
    ) external onlyOwner nonReentrant {
        FootballGame storage game = footballGames[gameId];
        require(game.gameId != 0, "Game not found");
        require(!game.settled, "Game already settled");
        require(bytes(reason).length > 0, "Reason required");

        // Validate score reasonableness
        require(homeScore <= MAX_REASONABLE_SCORE && awayScore <= MAX_REASONABLE_SCORE, "Unrealistic score");

        // Settle all handicap configs for this game
        _settleAllHandicapsForGame(gameId, homeScore, awayScore);

        // Update game state
        game.settled = true;
        game.settlementTime = block.timestamp;
        gamesRequiringManualIntervention[gameId] = false;

        emit EmergencyScoreSet(gameId, homeScore, awayScore, reason);
    }

    // ============ Internal Settlement Logic ============

    /**
     * @notice Get game score with strict data consistency validation
     * @param gameId Game ID
     * @return homeScore Home team score
     * @return awayScore Away team score
     * @return isFinished Game finished status
     */
    function _getGameScoreStrict(uint256 gameId)
        internal returns (uint256 homeScore, uint256 awayScore, bool isFinished) {

        FootballGame storage game = footballGames[gameId];

        // Check if manual intervention is required
        if (gamesRequiringManualIntervention[gameId]) {
            revert("Game requires manual intervention - automatic settlement disabled");
        }

        // CRITICAL FIX: Implement proper enableMultiSource and dataSourcePriority logic
        if (dataSourceConfig.enableMultiSource) {
            // Multi-source mode: require both sources to be consistent
            DataSourceResult memory sportMonksResult = _getFromSportMonks(game.sportMonksGameId);
            DataSourceResult memory theRundownResult = _getFromTheRundown(game.theRundownEventId);

            // Check if both sources succeeded
            if (sportMonksResult.success && theRundownResult.success) {
                // Both sources available, check consistency
                DataStatus status = _validateDataConsistency(sportMonksResult, theRundownResult);

                if (status == DataStatus.AVAILABLE) {
                    // Data is consistent, return result
                    return (sportMonksResult.homeScore, sportMonksResult.awayScore, true);
                } else {
                    // Data inconsistent, record conflict and require manual intervention
                    _recordDataConflict(gameId, sportMonksResult, theRundownResult);
                    _requireManualIntervention(gameId, "Data source inconsistency detected");
                    revert("Data inconsistency - manual intervention required");
                }
            } else if (sportMonksResult.success || theRundownResult.success) {
                // Only one source succeeded - this could be configurable policy
                // For now, enter manual intervention as safety measure
                _requireManualIntervention(gameId, "Only single data source available in multi-source mode");
                revert("Incomplete data in multi-source mode - manual intervention required");
            } else {
                // Neither source succeeded
                revert("No data available from any source");
            }
        } else {
            // Single-source mode: use dataSourcePriority to choose primary source
            uint256[] memory configIds = gameToHandicapConfigs[gameId];
            require(configIds.length > 0, "No config found for game");
            DeathHandicapConfig storage config = deathHandicaps[configIds[0]];

            if (config.dataSourcePriority == 0) {
                // SportMonks priority, TheRundown fallback
                DataSourceResult memory primaryResult = _getFromSportMonks(game.sportMonksGameId);
                if (primaryResult.success && primaryResult.isFinished) {
                    return (primaryResult.homeScore, primaryResult.awayScore, true);
                }

                // Primary failed, try fallback
                DataSourceResult memory fallbackResult = _getFromTheRundown(game.theRundownEventId);
                if (fallbackResult.success && fallbackResult.isFinished) {
                    return (fallbackResult.homeScore, fallbackResult.awayScore, true);
                }

                revert("No valid data from primary or fallback source");
            } else {
                // TheRundown priority, SportMonks fallback
                DataSourceResult memory primaryResult = _getFromTheRundown(game.theRundownEventId);
                if (primaryResult.success && primaryResult.isFinished) {
                    return (primaryResult.homeScore, primaryResult.awayScore, true);
                }

                // Primary failed, try fallback
                DataSourceResult memory fallbackResult = _getFromSportMonks(game.sportMonksGameId);
                if (fallbackResult.success && fallbackResult.isFinished) {
                    return (fallbackResult.homeScore, fallbackResult.awayScore, true);
                }

                revert("No valid data from primary or fallback source");
            }
        }
    }

    /**
     * @notice Calculate death handicap result
     * @param homeScore Home team score
     * @param awayScore Away team score
     * @param handicapHalf Handicap value * 2
     * @param isHomeFavored Home team favored status
     * @return 1 if favored team covers handicap, 0 if not
     */
    function _calculateDeathHandicapResult(
        uint256 homeScore,
        uint256 awayScore,
        int256 handicapHalf, // CRITICAL FIX: Changed from int16 to int256 to prevent overflow
        bool isHomeFavored
    ) internal pure returns (uint256) {

        // CRITICAL FIX: Use int256 throughout to prevent overflow
        // Calculate actual score difference * 2 (maintaining 0.5 precision)
        int256 actualScoreDiffHalf = int256(homeScore) * 2 - int256(awayScore) * 2;

        if (isHomeFavored) {
            // Home team favored: actual score difference > handicap = home team covers
            return actualScoreDiffHalf > handicapHalf ? 1 : 0;
        } else {
            // Away team favored: actual score difference < handicap = away team covers
            return actualScoreDiffHalf < handicapHalf ? 1 : 0;
        }
    }

    /**
     * @notice Settle all handicap configurations for a game
     * @param gameId Game ID
     * @param homeScore Home team score
     * @param awayScore Away team score
     */
    function _settleAllHandicapsForGame(
        uint256 gameId,
        uint256 homeScore,
        uint256 awayScore
    ) internal {
        uint256[] memory configIds = gameToHandicapConfigs[gameId];

        for (uint256 i = 0; i < configIds.length; i++) {
            uint256 configId = configIds[i];
            DeathHandicapConfig storage config = deathHandicaps[configId];

            if (!config.settled) {
                // Calculate result
                uint256 result = _calculateDeathHandicapResult(
                    homeScore,
                    awayScore,
                    config.handicapHalf,
                    config.isHomeFavored
                );

                // Mark as settled
                config.settled = true;

                // Submit to target market
                IOddsMarket(config.targetMarket).proposeResultFromExternalOracle(
                    config.targetMarketId,
                    result
                );

                // Calculate score difference for event
                int16 scoreDiffHalf = int16(int256(homeScore) * 2 - int256(awayScore) * 2);

                emit DeathHandicapSettled(
                    configId,
                    gameId,
                    homeScore,
                    awayScore,
                    scoreDiffHalf,
                    result
                );
            }
        }
    }

    // ============ Data Source Functions ============

    /**
     * @notice Get game result from SportMonks
     * @param sportMonksGameId SportMonks game ID
     * @return result Data source result structure
     */
    function _getFromSportMonks(uint256 sportMonksGameId)
        internal view returns (DataSourceResult memory result) {

        address dataSource = dataSourceConfig.sportMonksChainlink;
        if (dataSource == address(0)) {
            return DataSourceResult(false, 0, 0, false, block.timestamp, "SportMonks");
        }

        try ISportMonksChainlink(dataSource).getGameResult(sportMonksGameId) returns (
            ISportMonksChainlink.GameResult memory gameResult
        ) {
            // Validate data
            if (!gameResult.isValid) {
                return DataSourceResult(false, 0, 0, false, block.timestamp, "SportMonks");
            }
            // CRITICAL FIX: Use configured dataTimeout instead of constant
            uint256 timeout = (dataSourceConfig.dataTimeout == 0) ? DATA_FRESHNESS_REQUIREMENT : dataSourceConfig.dataTimeout;
            if (block.timestamp - gameResult.lastUpdated > timeout) {
                return DataSourceResult(false, 0, 0, false, block.timestamp, "SportMonks");
            }

            // gameStatus: 2=finished
            bool finished = (gameResult.gameStatus == 2);
            return DataSourceResult(
                true,
                gameResult.homeScore,
                gameResult.awayScore,
                finished,
                gameResult.lastUpdated,
                "SportMonks"
            );

        } catch {
            return DataSourceResult(false, 0, 0, false, block.timestamp, "SportMonks");
        }
    }

    /**
     * @notice Get game result from TheRundown
     * @param theRundownEventId TheRundown event ID
     * @return result Data source result structure
     */
    function _getFromTheRundown(uint256 theRundownEventId)
        internal view returns (DataSourceResult memory result) {

        address dataSource = dataSourceConfig.theRundownSports;
        if (dataSource == address(0)) {
            return DataSourceResult(false, 0, 0, false, block.timestamp, "TheRundown");
        }

        try ITheRundownSports(dataSource).getEventResult(theRundownEventId) returns (
            ITheRundownSports.SportEvent memory sportEvent
        ) {
            // CRITICAL FIX: Use configured dataTimeout instead of constant
            uint256 timeout = (dataSourceConfig.dataTimeout == 0) ? DATA_FRESHNESS_REQUIREMENT : dataSourceConfig.dataTimeout;
            if (block.timestamp - sportEvent.updatedAt > timeout) {
                return DataSourceResult(false, 0, 0, false, block.timestamp, "TheRundown");
            }

            // status: 3=complete
            bool finished = (sportEvent.status == 3);
            return DataSourceResult(
                true,
                sportEvent.homeTeamScore,
                sportEvent.awayTeamScore,
                finished,
                sportEvent.updatedAt,
                "TheRundown"
            );

        } catch {
            return DataSourceResult(false, 0, 0, false, block.timestamp, "TheRundown");
        }
    }

    /**
     * @notice Validate data consistency between sources
     * @param result1 First data source result
     * @param result2 Second data source result
     * @return Data status enum
     */
    function _validateDataConsistency(
        DataSourceResult memory result1,
        DataSourceResult memory result2
    ) internal pure returns (DataStatus) {

        // Check if both sources are successful and games are finished
        if (!result1.success || !result1.isFinished) {
            return DataStatus.NOT_AVAILABLE;
        }
        if (!result2.success || !result2.isFinished) {
            return DataStatus.NOT_AVAILABLE;
        }

        // Strict score comparison
        if (result1.homeScore == result2.homeScore && result1.awayScore == result2.awayScore) {
            return DataStatus.AVAILABLE;
        } else {
            return DataStatus.INCONSISTENT;
        }
    }

    /**
     * @notice Record data conflict for investigation
     * @param gameId Game ID with conflict
     * @param sportMonksResult SportMonks data
     * @param theRundownResult TheRundown data
     */
    function _recordDataConflict(
        uint256 gameId,
        DataSourceResult memory sportMonksResult,
        DataSourceResult memory theRundownResult
    ) internal {
        uint256 conflictId = dataConflictCount++;

        dataConflicts[conflictId] = DataConflict({
            gameId: gameId,
            sportMonksResult: sportMonksResult,
            theRundownResult: theRundownResult,
            conflictTime: block.timestamp,
            resolved: false,
            resolution: ""
        });

        emit DataInconsistencyDetected(
            gameId,
            sportMonksResult.homeScore,
            sportMonksResult.awayScore,
            theRundownResult.homeScore,
            theRundownResult.awayScore,
            conflictId
        );
    }

    /**
     * @notice Mark game as requiring manual intervention
     * @param gameId Game ID
     * @param reason Intervention reason
     */
    function _requireManualIntervention(uint256 gameId, string memory reason) internal {
        gamesRequiringManualIntervention[gameId] = true;
        emit ManualInterventionRequired(gameId, reason);
    }

    // ============ Management Functions ============

    /**
     * @notice Resolve data conflict (mark as resolved)
     * @param conflictId Conflict ID
     * @param resolutionNote Resolution details
     */
    function resolveDataConflict(
        uint256 conflictId,
        string calldata resolutionNote
    ) external onlyOwner {
        DataConflict storage conflict = dataConflicts[conflictId];
        require(conflict.conflictTime != 0, "Conflict not found");
        require(!conflict.resolved, "Conflict already resolved");
        require(bytes(resolutionNote).length > 0, "Resolution note required");

        conflict.resolved = true;
        conflict.resolution = resolutionNote;

        emit ConflictResolved(conflictId, resolutionNote);
    }

    /**
     * @notice Reset manual intervention flag for a game
     * @param gameId Game ID
     */
    function resetManualInterventionFlag(uint256 gameId) external onlyOwner {
        require(footballGames[gameId].gameId != 0, "Game not found");
        gamesRequiringManualIntervention[gameId] = false;
        emit ManualInterventionReset(gameId);
    }

    // ============ View Functions ============

    /**
     * @notice Preview death handicap result for given scores
     * @param homeScore Home team score
     * @param awayScore Away team score
     * @param handicapHalf Handicap value * 2
     * @param isHomeFavored Home team favored status
     * @return result 1 if favored team covers, 0 if not
     * @return explanation Human-readable explanation
     * @return handicapDisplay Formatted handicap display
     */
    function previewDeathHandicapResult(
        uint256 homeScore,
        uint256 awayScore,
        int16 handicapHalf,
        bool isHomeFavored
    ) external pure returns (
        uint256 result,
        string memory explanation,
        string memory handicapDisplay
    ) {
        result = _calculateDeathHandicapResult(homeScore, awayScore, handicapHalf, isHomeFavored);

        // Generate handicap display text
        if (handicapHalf > 0) {
            handicapDisplay = string(abi.encodePacked("Home -", _formatHandicap(handicapHalf)));
        } else {
            handicapDisplay = string(abi.encodePacked("Away -", _formatHandicap(-handicapHalf)));
        }

        // Generate result explanation
        if (isHomeFavored) {
            explanation = result == 1 ? "Home team covers handicap" : "Away team covers handicap";
        } else {
            explanation = result == 1 ? "Away team covers handicap" : "Home team covers handicap";
        }
    }

    /**
     * @notice Get data conflict details
     * @param conflictId Conflict ID
     * @return gameId Game ID
     * @return sportMonksHome SportMonks home score
     * @return sportMonksAway SportMonks away score
     * @return theRundownHome TheRundown home score
     * @return theRundownAway TheRundown away score
     * @return conflictTime When conflict occurred
     * @return resolved Resolution status
     * @return resolution Resolution details
     */
    function getDataConflictDetails(uint256 conflictId) external view returns (
        uint256 gameId,
        uint256 sportMonksHome,
        uint256 sportMonksAway,
        uint256 theRundownHome,
        uint256 theRundownAway,
        uint256 conflictTime,
        bool resolved,
        string memory resolution
    ) {
        DataConflict storage conflict = dataConflicts[conflictId];
        return (
            conflict.gameId,
            conflict.sportMonksResult.homeScore,
            conflict.sportMonksResult.awayScore,
            conflict.theRundownResult.homeScore,
            conflict.theRundownResult.awayScore,
            conflict.conflictTime,
            conflict.resolved,
            conflict.resolution
        );
    }

    /**
     * @notice Get game data status from both sources
     * @param gameId Game ID
     * @return sportMonksAvailable SportMonks data availability
     * @return theRundownAvailable TheRundown data availability
     * @return sportMonksScore1 SportMonks home score
     * @return sportMonksScore2 SportMonks away score
     * @return theRundownScore1 TheRundown home score
     * @return theRundownScore2 TheRundown away score
     * @return gameFinished Game finished status
     * @return lastUpdate Last update timestamp
     */
    function getGameDataStatus(uint256 gameId) external view returns (
        bool sportMonksAvailable,
        bool theRundownAvailable,
        uint256 sportMonksScore1,
        uint256 sportMonksScore2,
        uint256 theRundownScore1,
        uint256 theRundownScore2,
        bool gameFinished,
        uint256 lastUpdate
    ) {
        FootballGame storage game = footballGames[gameId];
        require(game.gameId != 0, "Game not found");

        DataSourceResult memory sportMonksResult = _getFromSportMonks(game.sportMonksGameId);
        DataSourceResult memory theRundownResult = _getFromTheRundown(game.theRundownEventId);

        sportMonksAvailable = sportMonksResult.success;
        sportMonksScore1 = sportMonksResult.homeScore;
        sportMonksScore2 = sportMonksResult.awayScore;

        theRundownAvailable = theRundownResult.success;
        theRundownScore1 = theRundownResult.homeScore;
        theRundownScore2 = theRundownResult.awayScore;

        gameFinished = sportMonksResult.isFinished && theRundownResult.isFinished;

        // CRITICAL FIX: Return real data source update time instead of block.timestamp
        uint256 sportMonksUpdate = sportMonksResult.success ? sportMonksResult.timestamp : 0;
        uint256 theRundownUpdate = theRundownResult.success ? theRundownResult.timestamp : 0;
        lastUpdate = sportMonksUpdate > theRundownUpdate ? sportMonksUpdate : theRundownUpdate;
    }

    /**
     * @notice Get all handicap configurations for a game
     * @param gameId Game ID
     * @return configIds Array of configuration IDs
     */
    function getGameHandicapConfigs(uint256 gameId) external view returns (uint256[] memory configIds) {
        return gameToHandicapConfigs[gameId];
    }

    /**
     * @notice Check if game requires manual intervention
     * @param gameId Game ID
     * @return requires True if manual intervention required
     */
    function requiresManualIntervention(uint256 gameId) external view returns (bool requires) {
        return gamesRequiringManualIntervention[gameId];
    }

    // ============ Internal Helper Functions ============

    /**
     * @notice Format handicap value for display
     * @param handicapHalf Handicap value * 2
     * @return Formatted string (e.g., "1.5", "2.0")
     */
    function _formatHandicap(int16 handicapHalf) internal pure returns (string memory) {
        uint16 absHandicap = uint16(handicapHalf < 0 ? -handicapHalf : handicapHalf);
        uint16 whole = absHandicap / 2;
        uint16 half = absHandicap % 2;

        if (half == 0) {
            return string(abi.encodePacked(_toString(whole), ".0"));
        } else {
            return string(abi.encodePacked(_toString(whole), ".5"));
        }
    }

    /**
     * @notice Convert uint256 to string
     * @param value Value to convert
     * @return String representation
     */
    function _toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) {
            return "0";
        }
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }

    // ============ Emergency Functions ============

    /**
     * @notice Pause contract (emergency only)
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpause contract
     */
    function unpause() external onlyOwner {
        _unpause();
    }
}
