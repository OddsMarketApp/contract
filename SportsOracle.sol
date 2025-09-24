// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

/**
 * @title SportsOracle
 * @dev Oracle contract for providing sports event results to prediction markets
 * @notice Handles result submission and dispute resolution for sports events
 * @author OddsMarket Team
 */
contract SportsOracle is Ownable, Pausable {
    
    // ============ Events ============
    
    event ResultSubmitted(
        uint256 indexed eventId,
        uint256 indexed winningOutcome,
        address indexed submitter,
        uint256 timestamp
    );
    
    event OracleAdded(address indexed oracle, string description);
    event OracleRemoved(address indexed oracle);
    event DisputeRaised(uint256 indexed eventId, address indexed disputer);
    
    // ============ Structs ============
    
    struct SportEvent {
        uint256 eventId;
        string description;
        uint256 submissionTime;
        uint256 winningOutcome;
        address submitter;
        bool isDisputed;
        bool isFinalized;
    }
    
    // ============ State Variables ============
    
    /// @dev Mapping of authorized oracle addresses
    mapping(address => bool) public authorizedOracles;
    
    /// @dev Mapping of oracle descriptions
    mapping(address => string) public oracleDescriptions;
    
    /// @dev Mapping of event results
    mapping(uint256 => SportEvent) public eventResults;
    
    /// @dev Array of all oracle addresses
    address[] public oracles;
    
    /// @dev Dispute period duration (24 hours)
    uint256 public constant DISPUTE_PERIOD = 24 hours;
    
    /// @dev Minimum time before result can be finalized
    uint256 public constant MIN_FINALIZATION_TIME = 1 hours;
    
    // ============ Modifiers ============
    
    modifier onlyAuthorizedOracle() {
        require(authorizedOracles[msg.sender], "Not authorized oracle");
        _;
    }
    
    modifier validEventId(uint256 eventId) {
        require(eventId > 0, "Invalid event ID");
        _;
    }
    
    modifier resultExists(uint256 eventId) {
        require(eventResults[eventId].submissionTime > 0, "Result does not exist");
        _;
    }
    
    // ============ Constructor ============
    
    constructor() {
        // Add deployer as initial oracle
        _addOracle(msg.sender, "Deployer Oracle");
    }
    
    // ============ Oracle Management ============
    
    /**
     * @dev Adds a new authorized oracle
     * @param oracle The oracle address to add
     * @param description Description of the oracle
     */
    function addOracle(address oracle, string calldata description) 
        external 
        onlyOwner 
    {
        require(oracle != address(0), "Invalid oracle address");
        require(!authorizedOracles[oracle], "Oracle already exists");
        
        _addOracle(oracle, description);
    }
    
    /**
     * @dev Removes an authorized oracle
     * @param oracle The oracle address to remove
     */
    function removeOracle(address oracle) external onlyOwner {
        require(authorizedOracles[oracle], "Oracle does not exist");
        
        authorizedOracles[oracle] = false;
        delete oracleDescriptions[oracle];
        
        // Remove from oracles array
        for (uint256 i = 0; i < oracles.length; i++) {
            if (oracles[i] == oracle) {
                oracles[i] = oracles[oracles.length - 1];
                oracles.pop();
                break;
            }
        }
        
        emit OracleRemoved(oracle);
    }
    
    /**
     * @dev Internal function to add oracle
     */
    function _addOracle(address oracle, string memory description) internal {
        authorizedOracles[oracle] = true;
        oracleDescriptions[oracle] = description;
        oracles.push(oracle);
        
        emit OracleAdded(oracle, description);
    }
    
    // ============ Result Submission ============
    
    /**
     * @dev Submits a result for a sports event (V1 simplified version)
     * @param eventId The unique event identifier
     * @param description Description of the event
     * @param winningOutcome The winning outcome (0 or 1)
     */
    function submitResult(
        uint256 eventId,
        string calldata description,
        uint256 winningOutcome
    ) 
        external 
        validEventId(eventId)
        onlyAuthorizedOracle
        whenNotPaused
    {
        require(winningOutcome < 2, "Invalid outcome");
        require(bytes(description).length > 0, "Empty description");
        
        SportEvent storage eventResult = eventResults[eventId];
        
        // 🛡️ V1 SECURITY FIX: Prevent resubmission after finalization
        if (eventResult.submissionTime > 0) {
            require(!eventResult.isFinalized, "Result already finalized");
            // 🔧 V1 FIX: Remove complex dispute resubmission logic
            require(!eventResult.isDisputed || msg.sender == owner(), "Cannot resubmit disputed result");
        }
        
        eventResult.eventId = eventId;
        eventResult.description = description;
        eventResult.submissionTime = block.timestamp;
        eventResult.winningOutcome = winningOutcome;
        eventResult.submitter = msg.sender;
        eventResult.isDisputed = false;
        eventResult.isFinalized = false;
        
        emit ResultSubmitted(eventId, winningOutcome, msg.sender, block.timestamp);
    }
    
    /**
     * @dev V1 Simplified: Submit and immediately finalize result (for admin use)
     * @param eventId The unique event identifier
     * @param description Description of the event
     * @param winningOutcome The winning outcome (0 or 1)
     */
    function submitAndFinalizeResult(
        uint256 eventId,
        string calldata description,
        uint256 winningOutcome
    ) 
        external 
        validEventId(eventId)
        onlyAuthorizedOracle
        whenNotPaused
    {
        require(winningOutcome < 2, "Invalid outcome");
        require(bytes(description).length > 0, "Empty description");
        
        SportEvent storage eventResult = eventResults[eventId];
        require(eventResult.submissionTime == 0, "Result already exists");
        
        // Create and immediately finalize result for V1 simplicity
        eventResult.eventId = eventId;
        eventResult.description = description;
        eventResult.submissionTime = block.timestamp;
        eventResult.winningOutcome = winningOutcome;
        eventResult.submitter = msg.sender;
        eventResult.isDisputed = false;
        eventResult.isFinalized = true; // 🔧 V1: Immediate finalization
        
        emit ResultSubmitted(eventId, winningOutcome, msg.sender, block.timestamp);
    }
    
    /**
     * @dev Raises a dispute for a submitted result
     * @param eventId The event ID to dispute
     */
    function disputeResult(uint256 eventId) 
        external 
        validEventId(eventId)
        resultExists(eventId)
        onlyAuthorizedOracle
    {
        SportEvent storage eventResult = eventResults[eventId];
        require(!eventResult.isFinalized, "Result already finalized");
        require(!eventResult.isDisputed, "Already disputed");
        require(
            block.timestamp <= eventResult.submissionTime + DISPUTE_PERIOD,
            "Dispute period ended"
        );
        require(msg.sender != eventResult.submitter, "Cannot dispute own result");
        
        eventResult.isDisputed = true;
        
        emit DisputeRaised(eventId, msg.sender);
    }
    
    /**
     * @dev Finalizes a result after dispute period
     * @param eventId The event ID to finalize
     */
    function finalizeResult(uint256 eventId) 
        external 
        validEventId(eventId)
        resultExists(eventId)
    {
        SportEvent storage eventResult = eventResults[eventId];
        require(!eventResult.isFinalized, "Already finalized");
        require(
            block.timestamp >= eventResult.submissionTime + MIN_FINALIZATION_TIME,
            "Too early to finalize"
        );
        
        // If disputed, only allow original submitter or owner to finalize
        if (eventResult.isDisputed) {
            require(
                msg.sender == eventResult.submitter || msg.sender == owner(),
                "Not authorized to finalize disputed result"
            );
        }
        
        // Ensure dispute period has passed if not disputed
        if (!eventResult.isDisputed) {
            require(
                block.timestamp >= eventResult.submissionTime + DISPUTE_PERIOD,
                "Dispute period not ended"
            );
        }
        
        eventResult.isFinalized = true;
    }
    
    // ============ View Functions ============
    
    /**
     * @dev Gets result for an event
     * @param eventId The event ID
     * @return result The sport event result
     */
    function getResult(uint256 eventId) 
        external 
        view 
        validEventId(eventId)
        returns (SportEvent memory result) 
    {
        return eventResults[eventId];
    }
    
    /**
     * @dev Checks if a result exists and is finalized
     * @param eventId The event ID
     * @return exists Whether result exists
     * @return finalized Whether result is finalized
     * @return winningOutcome The winning outcome (if finalized)
     */
    function isResultFinalized(uint256 eventId) 
        external 
        view 
        validEventId(eventId)
        returns (bool exists, bool finalized, uint256 winningOutcome) 
    {
        SportEvent storage eventResult = eventResults[eventId];
        exists = eventResult.submissionTime > 0;
        finalized = eventResult.isFinalized;
        winningOutcome = eventResult.winningOutcome;
    }
    
    /**
     * @dev Gets all authorized oracles
     * @return oracleList Array of oracle addresses
     */
    function getOracles() external view returns (address[] memory oracleList) {
        return oracles;
    }
    
    /**
     * @dev Checks if an address is an authorized oracle
     * @param oracle The address to check
     * @return isAuthorized Whether the address is authorized
     */
    function isAuthorizedOracle(address oracle) external view returns (bool isAuthorized) {
        return authorizedOracles[oracle];
    }
    
    /**
     * @dev Gets the time remaining in dispute period
     * @param eventId The event ID
     * @return timeRemaining Time remaining in seconds (0 if period ended)
     */
    function getDisputeTimeRemaining(uint256 eventId) 
        external 
        view 
        validEventId(eventId)
        resultExists(eventId)
        returns (uint256 timeRemaining) 
    {
        SportEvent storage eventResult = eventResults[eventId];
        uint256 disputeEndTime = eventResult.submissionTime + DISPUTE_PERIOD;
        
        if (block.timestamp >= disputeEndTime) {
            return 0;
        }
        
        return disputeEndTime - block.timestamp;
    }
    
    // ============ Administrative Functions ============
    
    /**
     * @dev Emergency pause function
     */
    function pause() external onlyOwner {
        _pause();
    }
    
    /**
     * @dev Unpause function
     */
    function unpause() external onlyOwner {
        _unpause();
    }
    
    /**
     * @dev Emergency function to force finalize a result (only owner)
     * @param eventId The event ID to force finalize
     * @param winningOutcome The outcome to set
     */
    function forceFinalize(uint256 eventId, uint256 winningOutcome) 
        external 
        onlyOwner
        validEventId(eventId)
    {
        require(winningOutcome < 2, "Invalid outcome");
        
        SportEvent storage eventResult = eventResults[eventId];
        eventResult.eventId = eventId;
        eventResult.description = "Emergency finalization";
        eventResult.submissionTime = block.timestamp;
        eventResult.winningOutcome = winningOutcome;
        eventResult.submitter = msg.sender;
        eventResult.isDisputed = false;
        eventResult.isFinalized = true;
        
        emit ResultSubmitted(eventId, winningOutcome, msg.sender, block.timestamp);
    }
}
