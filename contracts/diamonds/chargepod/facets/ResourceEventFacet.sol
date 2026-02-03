// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibMeta} from "../../shared/libraries/LibMeta.sol";
import {LibResourceStorage} from "../libraries/LibResourceStorage.sol";
import {LibHenomorphsStorage} from "../libraries/LibHenomorphsStorage.sol";
import {LibGamingStorage} from "../libraries/LibGamingStorage.sol";
import {AccessControlBase} from "../../common/facets/AccessControlBase.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @notice Interface for mintable reward token (YLW)
 */
interface IRewardToken is IERC20 {
    function mint(address to, uint256 amount, string calldata reason) external;
}

/**
 * @title ResourceEventFacet
 * @notice Integrates resource system with existing seasonal events from SeasonFacet
 * @dev Extends SeasonFacet/AutomatedEventFacet without duplicating event management
 */
contract ResourceEventFacet is AccessControlBase {
    using SafeERC20 for IERC20;
    
    // ==================== EVENTS ====================
    
    event ResourceEventStarted(string indexed eventType, uint32 startTime, uint32 endTime);
    event ResourceEventEnded(string indexed eventType, uint256 participantCount);
    event EventParticipation(address indexed user, string indexed eventType, uint256 contribution);
    event EventRewardClaimed(address indexed user, string indexed eventType, uint256 reward);
    event EventLeaderboardUpdated(string indexed eventType, address indexed leader, uint256 score);
    
    // ==================== ERRORS ====================
    
    error EventNotActive(string eventType);
    error AlreadyParticipating(string eventType);
    error InsufficientContribution(uint256 required, uint256 provided);
    error RewardsNotAvailable();
    error LeaderboardFull();
    error InvalidEventId();
    
    // Storage structures moved to LibResourceStorage
    
    // ==================== EVENT MANAGEMENT ====================
    
    /**
     * @notice Start resource event with explicit start and end times
     * @dev Supports scheduled events (future start) or immediate start (startTime = 0)
     * @param eventId Unique event identifier
     * @param eventType Event type (1=Rush, 3=Festival, 11-14=Per-resource)
     * @param startTime Start timestamp (0 = start now)
     * @param endTime End timestamp
     * @param productionMultiplier Production bonus in basis points (20000 = 200%)
     * @param costReduction Cost reduction in basis points (2500 = 25%)
     * @param rewardPool Total reward pool in tokens
     */
    function startResourceEvent(
        string calldata eventId,
        uint8 eventType,
        uint40 startTime,
        uint40 endTime,
        uint16 productionMultiplier,
        uint16 costReduction,
        uint256 rewardPool
    ) external onlyAuthorized whenNotPaused {
        // Validate eventId is not empty
        if (bytes(eventId).length == 0) revert InvalidEventId();

        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();

        // Check if event already exists in active events
        bytes32 eventHash = keccak256(bytes(eventId));
        if (rs.resourceEvents[eventHash].active) revert AlreadyParticipating(eventId);

        // If startTime is 0, use current block timestamp
        uint40 actualStartTime = startTime == 0 ? uint40(block.timestamp) : startTime;

        // Validate end time is after start time
        require(endTime > actualStartTime, "End time must be after start time");

        rs.resourceEvents[eventHash] = LibResourceStorage.ResourceEvent({
            eventId: eventHash,
            name: eventId,
            description: "",
            startTime: actualStartTime,
            endTime: endTime,
            productionMultiplier: productionMultiplier,
            processingDiscount: costReduction,
            active: true,
            creator: LibMeta.msgSender(),
            globalEvent: true,
            eventType: eventType,
            minContribution: 100,
            rewardPool: rewardPool
        });

        rs.activeEventIds.push(eventId);
        rs.allEventIds.push(eventId);

        emit ResourceEventStarted(eventId, uint32(actualStartTime), uint32(endTime));
    }

    /**
     * @notice Start resource event with duration (legacy/convenience method)
     * @dev Starts immediately with specified duration
     */
    function startResourceEventWithDuration(
        string calldata eventId,
        uint8 eventType,
        uint32 duration,
        uint16 productionMultiplier,
        uint16 costReduction,
        uint256 rewardPool
    ) external onlyAuthorized whenNotPaused {
        uint40 startTime = uint40(block.timestamp);
        uint40 endTime = startTime + uint40(duration);

        // Call the main function via internal call pattern
        this.startResourceEvent(
            eventId,
            eventType,
            startTime,
            endTime,
            productionMultiplier,
            costReduction,
            rewardPool
        );
    }
    
    /**
     * @notice End resource event and prepare rewards
     */
    function endResourceEvent(string calldata eventId) external onlyAuthorized {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        bytes32 eventHash = keccak256(bytes(eventId));
        LibResourceStorage.ResourceEvent storage evt = rs.resourceEvents[eventHash];

        if (!evt.active) revert EventNotActive(eventId);

        evt.active = false;
        evt.endTime = uint40(block.timestamp);

        _removeFromActiveEvents(eventId);
        unchecked { rs.totalEventsHosted++; }

        emit ResourceEventEnded(eventId, rs.totalEventParticipants[eventId]);
    }

    /**
     * @notice Update event parameters (bonuses, duration, reward pool)
     * @dev Can only update active events
     */
    function updateResourceEvent(
        string calldata eventId,
        uint16 productionMultiplier,
        uint16 costReduction,
        uint40 newStartTime,
        uint40 newEndTime,
        uint256 rewardPool
    ) external onlyAuthorized {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        bytes32 eventHash = keccak256(bytes(eventId));
        LibResourceStorage.ResourceEvent storage evt = rs.resourceEvents[eventHash];

        if (!evt.active) revert EventNotActive(eventId);

        evt.productionMultiplier = productionMultiplier;
        evt.processingDiscount = costReduction;
        evt.startTime = newStartTime;
        evt.endTime = newEndTime;
        evt.rewardPool = rewardPool;
    }

    /**
     * @notice Activate or deactivate event without ending it
     */
    function setResourceEventActive(string calldata eventId, bool active) external onlyAuthorized {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        bytes32 eventHash = keccak256(bytes(eventId));
        LibResourceStorage.ResourceEvent storage evt = rs.resourceEvents[eventHash];

        if (bytes(evt.name).length == 0) revert InvalidEventId();

        bool wasActive = evt.active;
        evt.active = active;

        // Update activeEventIds array
        if (active && !wasActive) {
            rs.activeEventIds.push(eventId);
        } else if (!active && wasActive) {
            _removeFromActiveEvents(eventId);
        }
    }

    /**
     * @notice Delete event definition completely
     * @dev Only for cleanup - cannot delete events with participants who haven't claimed
     */
    function deleteResourceEvent(string calldata eventId) external onlyAuthorized {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        bytes32 eventHash = keccak256(bytes(eventId));
        LibResourceStorage.ResourceEvent storage evt = rs.resourceEvents[eventHash];

        if (bytes(evt.name).length == 0) revert InvalidEventId();

        // Remove from active events if present
        if (evt.active) {
            _removeFromActiveEvents(eventId);
        }

        // Clear event data
        delete rs.resourceEvents[eventHash];
    }

    /**
     * @notice Update minimum contribution required to claim rewards
     * @dev Allows fixing events where users participated via actions but not direct contributions
     */
    function setEventMinContribution(string calldata eventId, uint256 minContribution) external onlyAuthorized {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        bytes32 eventHash = keccak256(bytes(eventId));
        LibResourceStorage.ResourceEvent storage evt = rs.resourceEvents[eventHash];

        if (bytes(evt.name).length == 0) revert InvalidEventId();

        evt.minContribution = minContribution;
    }

    /**
     * @notice Admin function to distribute rewards to eligible users manually
     * @dev For users who participated via actions but can't claim due to minContribution
     */
    function adminDistributeEventReward(
        string calldata eventId,
        address user,
        uint256 amount
    ) external onlyAuthorized nonReentrant {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        bytes32 eventHash = keccak256(bytes(eventId));
        LibResourceStorage.ResourceEvent storage evt = rs.resourceEvents[eventHash];

        if (bytes(evt.name).length == 0) revert InvalidEventId();

        LibResourceStorage.EventParticipant storage participant = rs.eventParticipants[eventId][user];

        // User must have participated (either contribution or actions)
        require(participant.contribution > 0 || participant.actionsCompleted > 0, "User did not participate");
        require(!participant.rewardClaimed, "Already claimed");

        participant.rewardClaimed = true;

        // Distribute reward
        _distributeYlwReward(rs.config.utilityToken, rs.config.paymentBeneficiary, user, amount);

        unchecked {
            rs.totalRewardsDistributed += amount;
        }

        emit EventRewardClaimed(user, eventId, amount);
    }

    // ==================== PARTICIPATION ====================
    
    /**
     * @notice Participate in active resource event
     * @param eventId Event identifier
     * @param resourceType Resource type to contribute (0-3)
     * @param amount Amount to contribute
     */
    function participateInEvent(
        string calldata eventId,
        uint8 resourceType,
        uint256 amount
    ) external whenNotPaused {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        bytes32 eventHash = keccak256(bytes(eventId));
        LibResourceStorage.ResourceEvent storage evt = rs.resourceEvents[eventHash];
        
        if (!evt.active) revert EventNotActive(eventId);
        if (block.timestamp > evt.endTime) revert EventNotActive(eventId);
        
        address user = LibMeta.msgSender();

        // Apply decay before consuming resources
        LibResourceStorage.applyResourceDecay(user);

        // Consume resources
        if (rs.userResources[user][resourceType] < amount) {
            revert InsufficientContribution(amount, rs.userResources[user][resourceType]);
        }

        rs.userResources[user][resourceType] -= amount;
        
        // Track participation
        LibResourceStorage.EventParticipant storage participant = rs.eventParticipants[eventId][user];
        
        if (participant.contribution == 0 && participant.actionsCompleted == 0) {
            // First time participating - add to participants list
            participant.participationTime = uint32(block.timestamp);
            rs.eventParticipantsList[eventId].push(user);
            unchecked { rs.totalEventParticipants[eventId]++; }
        }
        
        participant.contribution += amount;
        participant.actionsCompleted++;

        rs.totalEventContributions[eventId] += amount;

        // Update leaderboard with full score (contribution + actions bonus)
        uint256 score = participant.contribution + (participant.actionsCompleted * 10);
        _updateLeaderboard(eventId, user, score);
        
        emit EventParticipation(user, eventId, amount);
    }
    
    /**
     * @notice Complete action during event for bonus tracking
     * @dev Called by other facets (ResourcePodFacet, etc.) when user performs actions
     *      Uses onlyTrusted to allow: inter-facet calls, staking system, and admins
     */
    function recordEventAction(string calldata eventId, address user) external onlyTrusted {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        bytes32 eventHash = keccak256(bytes(eventId));
        LibResourceStorage.ResourceEvent storage evt = rs.resourceEvents[eventHash];
        
        if (!evt.active || block.timestamp < evt.startTime || block.timestamp > evt.endTime) return;

        LibResourceStorage.EventParticipant storage participant = rs.eventParticipants[eventId][user];

        // First interaction - add to participants list
        if (participant.contribution == 0 && participant.actionsCompleted == 0) {
            participant.participationTime = uint32(block.timestamp);
            rs.eventParticipantsList[eventId].push(user);
            unchecked { rs.totalEventParticipants[eventId]++; }
        }

        participant.actionsCompleted++;
        
        // Update leaderboard score (contribution + actions)
        uint256 score = participant.contribution + (participant.actionsCompleted * 10);
        _updateLeaderboard(eventId, user, score);
    }
    
    // ==================== REWARDS ====================
    
    /**
     * @notice Claim event rewards after completion
     */
    function claimEventReward(string calldata eventId) external whenNotPaused nonReentrant {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        bytes32 eventHash = keccak256(bytes(eventId));
        LibResourceStorage.ResourceEvent storage evt = rs.resourceEvents[eventHash];
        
        if (evt.active) revert EventNotActive(eventId);
        
        address user = LibMeta.msgSender();
        LibResourceStorage.EventParticipant storage participant = rs.eventParticipants[eventId][user];
        
        if (participant.rewardClaimed) revert RewardsNotAvailable();

        // Check eligibility: either sufficient contribution OR active participation via actions
        // actionsCompleted * 10 converts actions to equivalent contribution value (matching leaderboard scoring)
        uint256 effectiveContribution = participant.contribution + (participant.actionsCompleted * 10);
        if (effectiveContribution < evt.minContribution) {
            revert InsufficientContribution(evt.minContribution, effectiveContribution);
        }

        // Calculate reward based on effective contribution (contribution + actions)
        // Use leaderboard score as the basis for fair reward distribution
        uint256 userScore = participant.contribution + (participant.actionsCompleted * 10);
        uint256 totalContributions = rs.totalEventContributions[eventId];

        uint256 baseReward = 0;
        if (totalContributions > 0 && participant.contribution > 0) {
            // User contributed resources - calculate share based on contribution
            uint256 userShare = (participant.contribution * 10000) / totalContributions;
            baseReward = (evt.rewardPool * userShare) / 10000;
        } else if (userScore > 0) {
            // User only did actions - give minimum participation reward (1% of pool per 1000 score, capped at 10%)
            uint256 scoreBonus = (userScore * 100) / 1000; // 0.1% per 100 score
            if (scoreBonus > 1000) scoreBonus = 1000; // Cap at 10%
            baseReward = (evt.rewardPool * scoreBonus) / 10000;
        }
        
        // Leaderboard bonuses (top 10 get extra)
        uint256 leaderboardBonus = _calculateLeaderboardBonus(eventId, user, baseReward);
        uint256 totalReward = baseReward + leaderboardBonus;
        
        participant.rewardClaimed = true;
        
        // Distribute reward using Treasury → Mint fallback pattern
        _distributeYlwReward(rs.config.utilityToken, rs.config.paymentBeneficiary, user, totalReward);
        
        unchecked {
            rs.totalRewardsDistributed += totalReward;
        }
        
        emit EventRewardClaimed(user, eventId, totalReward);
    }
    
    /**
     * @notice Calculate leaderboard bonus
     */
    function _calculateLeaderboardBonus(
        string calldata eventId,
        address user,
        uint256 baseReward
    ) internal view returns (uint256) {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        LibResourceStorage.EventLeaderboard storage leaderboard = rs.eventLeaderboards[eventId];
        
        // Find position in leaderboard
        for (uint256 i = 0; i < leaderboard.topParticipants.length; i++) {
            if (leaderboard.topParticipants[i] == user) {
                // Bonus decreases by position: 1st=100%, 2nd=90%, ..., 10th=10%
                uint256 bonusPercent = 100 - (i * 10);
                return (baseReward * bonusPercent) / 100;
            }
        }
        
        return 0;
    }
    
    // ==================== LEADERBOARD ====================
    
    /**
     * @notice Update event leaderboard
     * @dev Handles duplicates by checking if user already exists in leaderboard
     */
    function _updateLeaderboard(
        string calldata eventId,
        address user,
        uint256 score
    ) internal {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        LibResourceStorage.EventLeaderboard storage leaderboard = rs.eventLeaderboards[eventId];

        rs.eventLeaderboardScores[eventId][user] = score;

        // Check if user already exists in leaderboard
        bool userExists = false;
        for (uint256 i = 0; i < leaderboard.topParticipants.length; i++) {
            if (leaderboard.topParticipants[i] == user) {
                userExists = true;
                break;
            }
        }

        // If user already in leaderboard, just re-sort
        if (userExists) {
            _sortLeaderboard(eventId);
        }
        // If leaderboard not full, add user
        else if (leaderboard.topParticipants.length < 10) {
            leaderboard.topParticipants.push(user);
            _sortLeaderboard(eventId);
        }
        // If score beats minimum, replace lowest scorer
        else if (score > leaderboard.minScoreRequired) {
            leaderboard.topParticipants[9] = user;
            _sortLeaderboard(eventId);
        }

        // Update min score
        if (leaderboard.topParticipants.length == 10) {
            leaderboard.minScoreRequired = rs.eventLeaderboardScores[eventId][leaderboard.topParticipants[9]];
        }

        emit EventLeaderboardUpdated(eventId, leaderboard.topParticipants[0], rs.eventLeaderboardScores[eventId][leaderboard.topParticipants[0]]);
    }
    
    /**
     * @notice Sort leaderboard (bubble sort - small array)
     */
    function _sortLeaderboard(string calldata eventId) internal {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        LibResourceStorage.EventLeaderboard storage leaderboard = rs.eventLeaderboards[eventId];
        uint256 length = leaderboard.topParticipants.length;
        
        for (uint256 i = 0; i < length - 1; i++) {
            for (uint256 j = 0; j < length - i - 1; j++) {
                if (rs.eventLeaderboardScores[eventId][leaderboard.topParticipants[j]] < 
                    rs.eventLeaderboardScores[eventId][leaderboard.topParticipants[j + 1]]) {
                    // Swap
                    address temp = leaderboard.topParticipants[j];
                    leaderboard.topParticipants[j] = leaderboard.topParticipants[j + 1];
                    leaderboard.topParticipants[j + 1] = temp;
                }
            }
        }
    }
    
    // ==================== EVENT BONUSES ====================

    /**
     * @notice Get active production multiplier for resource type
     * @dev Called by ResourcePodFacet to apply event bonuses
     * @param resourceType Resource type:
     *   0 = BasicMaterials (Stone, Wood)
     *   1 = EnergyCrystals
     *   2 = BioCompounds
     *   3 = RareElements
     *
     * Event types and their resource targeting:
     *   1  = Resource Rush (ALL resources)
     *   11 = Basic Materials Rush (only type 0)
     *   12 = Energy Rush (only type 1)
     *   13 = Bio Rush (only type 2)
     *   14 = Rare Elements Rush (only type 3)
     */
    function getActiveProductionMultiplier(uint8 resourceType) external view returns (uint16 multiplier) {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        multiplier = 10000; // 100% base

        for (uint256 i = 0; i < rs.activeEventIds.length; i++) {
            bytes32 eventHash = keccak256(bytes(rs.activeEventIds[i]));
            LibResourceStorage.ResourceEvent storage evt = rs.resourceEvents[eventHash];

            if (evt.active && block.timestamp >= evt.startTime && block.timestamp <= evt.endTime) {
                uint8 evtType = evt.eventType;

                // Type 1: Resource Rush - all resources get bonus
                if (evtType == 1) {
                    multiplier = (multiplier * evt.productionMultiplier) / 10000;
                }
                // Types 11-14: Per-resource Rush (11 = resource 0, 12 = resource 1, etc.)
                else if (evtType >= 11 && evtType <= 14 && evtType - 11 == resourceType) {
                    multiplier = (multiplier * evt.productionMultiplier) / 10000;
                }
            }
        }
    }
    
    /**
     * @notice Get active cost reduction for resource processing
     */
    function getActiveCostReduction() external view returns (uint16 reduction) {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        reduction = 0;
        
        for (uint256 i = 0; i < rs.activeEventIds.length; i++) {
            bytes32 eventHash = keccak256(bytes(rs.activeEventIds[i]));
            LibResourceStorage.ResourceEvent storage evt = rs.resourceEvents[eventHash];
            
            if (evt.active && block.timestamp >= evt.startTime && block.timestamp <= evt.endTime) {
                // Crafting Festival (type 3) - reduce costs
                if (evt.eventType == 3) {
                    if (evt.processingDiscount > reduction) {
                        reduction = evt.processingDiscount;
                    }
                }
            }
        }
        
        return reduction;
    }
    
    // ==================== VIEW FUNCTIONS ====================

    /**
     * @notice Get currently active events (active flag AND not expired)
     */
    function getActiveResourceEvents() external view returns (string[] memory) {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();

        // Count truly active events
        uint256 activeCount = 0;
        for (uint256 i = 0; i < rs.activeEventIds.length; i++) {
            bytes32 eventHash = keccak256(bytes(rs.activeEventIds[i]));
            LibResourceStorage.ResourceEvent storage evt = rs.resourceEvents[eventHash];
            if (evt.active && block.timestamp >= evt.startTime && block.timestamp <= evt.endTime) {
                activeCount++;
            }
        }

        // Build filtered array
        string[] memory result = new string[](activeCount);
        uint256 idx = 0;
        for (uint256 i = 0; i < rs.activeEventIds.length; i++) {
            bytes32 eventHash = keccak256(bytes(rs.activeEventIds[i]));
            LibResourceStorage.ResourceEvent storage evt = rs.resourceEvents[eventHash];
            if (evt.active && block.timestamp >= evt.startTime && block.timestamp <= evt.endTime) {
                result[idx++] = rs.activeEventIds[i];
            }
        }

        return result;
    }

    /**
     * @notice Get all event IDs (scheduled, active, and completed)
     * @dev Returns all events ever created - use getResourceEventDetails to check status
     */
    function getAllResourceEventIds() external view returns (string[] memory) {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        return rs.allEventIds;
    }

    /**
     * @notice Get scheduled future events (created but not yet started)
     * @dev Returns events where active=true AND block.timestamp < startTime
     */
    function getScheduledResourceEvents() external view returns (string[] memory) {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();

        // Count scheduled events
        uint256 scheduledCount = 0;
        for (uint256 i = 0; i < rs.allEventIds.length; i++) {
            bytes32 eventHash = keccak256(bytes(rs.allEventIds[i]));
            LibResourceStorage.ResourceEvent storage evt = rs.resourceEvents[eventHash];
            if (evt.active && block.timestamp < evt.startTime) {
                scheduledCount++;
            }
        }

        // Build filtered array
        string[] memory result = new string[](scheduledCount);
        uint256 idx = 0;
        for (uint256 i = 0; i < rs.allEventIds.length; i++) {
            bytes32 eventHash = keccak256(bytes(rs.allEventIds[i]));
            LibResourceStorage.ResourceEvent storage evt = rs.resourceEvents[eventHash];
            if (evt.active && block.timestamp < evt.startTime) {
                result[idx++] = rs.allEventIds[i];
            }
        }

        return result;
    }

    /**
     * @notice Get completed events (ended or expired)
     * @dev Returns events where active=false OR block.timestamp > endTime
     */
    function getCompletedResourceEvents() external view returns (string[] memory) {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();

        // Count completed events
        uint256 completedCount = 0;
        for (uint256 i = 0; i < rs.allEventIds.length; i++) {
            bytes32 eventHash = keccak256(bytes(rs.allEventIds[i]));
            LibResourceStorage.ResourceEvent storage evt = rs.resourceEvents[eventHash];
            // Event is completed if: not active OR past end time
            if (!evt.active || block.timestamp > evt.endTime) {
                completedCount++;
            }
        }

        // Build filtered array
        string[] memory result = new string[](completedCount);
        uint256 idx = 0;
        for (uint256 i = 0; i < rs.allEventIds.length; i++) {
            bytes32 eventHash = keccak256(bytes(rs.allEventIds[i]));
            LibResourceStorage.ResourceEvent storage evt = rs.resourceEvents[eventHash];
            if (!evt.active || block.timestamp > evt.endTime) {
                result[idx++] = rs.allEventIds[i];
            }
        }

        return result;
    }

    /**
     * @notice Get event leaderboard
     */
    function getResourceEventLeaderboard(string calldata eventId) external view returns (
        address[] memory participants,
        uint256[] memory scores
    ) {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        LibResourceStorage.EventLeaderboard storage leaderboard = rs.eventLeaderboards[eventId];
        
        uint256 length = leaderboard.topParticipants.length;
        participants = new address[](length);
        scores = new uint256[](length);
        
        for (uint256 i = 0; i < length; i++) {
            participants[i] = leaderboard.topParticipants[i];
            scores[i] = rs.eventLeaderboardScores[eventId][participants[i]];
        }
    }

    /**
     * @notice Get paginated full ranking for event
     * @param eventId Event identifier
     * @param offset Starting index (0-based)
     * @param limit Max results to return (recommended: 50-100)
     * @return addresses Participant addresses (sorted by score descending)
     * @return scores Corresponding scores
     * @return total Total number of participants
     */
    function getEventRankingPaginated(
        string calldata eventId,
        uint256 offset,
        uint256 limit
    ) external view returns (
        address[] memory addresses,
        uint256[] memory scores,
        uint256 total
    ) {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        address[] storage allParticipants = rs.eventParticipantsList[eventId];
        total = allParticipants.length;

        if (offset >= total || limit == 0) {
            return (new address[](0), new uint256[](0), total);
        }

        // Build temporary arrays with scores for sorting
        uint256[] memory allScores = new uint256[](total);
        address[] memory sorted = new address[](total);

        for (uint256 i = 0; i < total; i++) {
            sorted[i] = allParticipants[i];
            allScores[i] = rs.eventLeaderboardScores[eventId][allParticipants[i]];
        }

        // Insertion sort (descending) - efficient enough for typical event sizes
        for (uint256 i = 1; i < total; i++) {
            uint256 keyScore = allScores[i];
            address keyAddr = sorted[i];
            uint256 j = i;
            while (j > 0 && allScores[j - 1] < keyScore) {
                allScores[j] = allScores[j - 1];
                sorted[j] = sorted[j - 1];
                j--;
            }
            allScores[j] = keyScore;
            sorted[j] = keyAddr;
        }

        // Apply pagination
        uint256 end = offset + limit;
        if (end > total) end = total;
        uint256 resultLen = end - offset;

        addresses = new address[](resultLen);
        scores = new uint256[](resultLen);

        for (uint256 i = 0; i < resultLen; i++) {
            addresses[i] = sorted[offset + i];
            scores[i] = allScores[offset + i];
        }
    }

    /**
     * @notice Get total participant count for event
     */
    function getEventParticipantCount(string calldata eventId) external view returns (uint256) {
        return LibResourceStorage.resourceStorage().eventParticipantsList[eventId].length;
    }

    /**
     * @notice Backfill participants list for existing events (migration)
     * @dev Only adds addresses that have actual participation data
     * @param eventId Event identifier
     * @param participants Addresses to add (from off-chain EventParticipation events)
     */
    function backfillEventParticipants(
        string calldata eventId,
        address[] calldata participants
    ) external onlyAuthorized {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();

        for (uint256 i = 0; i < participants.length; i++) {
            address user = participants[i];
            LibResourceStorage.EventParticipant storage p = rs.eventParticipants[eventId][user];

            // Only add if user actually participated (has contribution or actions)
            if (p.contribution > 0 || p.actionsCompleted > 0) {
                rs.eventParticipantsList[eventId].push(user);
            }
        }
    }

    /**
     * @notice Get user participation data
     */
    function getUserResourceEventData(string calldata eventId, address user) external view returns (
        uint256 contribution,
        uint256 actions,
        bool rewardClaimed,
        uint256 estimatedReward
    ) {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        LibResourceStorage.EventParticipant storage participant = rs.eventParticipants[eventId][user];
        
        contribution = participant.contribution;
        actions = participant.actionsCompleted;
        rewardClaimed = participant.rewardClaimed;
        
        // Calculate estimated reward (matching claimEventReward logic)
        bytes32 eventHash = keccak256(bytes(eventId));
        uint256 userScore = contribution + (actions * 10);
        uint256 rewardPool = rs.resourceEvents[eventHash].rewardPool;

        if (rs.totalEventContributions[eventId] > 0 && contribution > 0) {
            // User contributed - calculate share
            uint256 userShare = (contribution * 10000) / rs.totalEventContributions[eventId];
            estimatedReward = (rewardPool * userShare) / 10000;
        } else if (userScore > 0) {
            // User only did actions - calculate score-based reward
            uint256 scoreBonus = (userScore * 100) / 1000;
            if (scoreBonus > 1000) scoreBonus = 1000;
            estimatedReward = (rewardPool * scoreBonus) / 10000;
        }

        // Add leaderboard bonus estimate if in top 10
        LibResourceStorage.EventLeaderboard storage leaderboard = rs.eventLeaderboards[eventId];
        for (uint256 i = 0; i < leaderboard.topParticipants.length; i++) {
            if (leaderboard.topParticipants[i] == user) {
                uint256 bonusPercent = 100 - (i * 10);
                estimatedReward += (estimatedReward * bonusPercent) / 100;
                break;
            }
        }
    }

    /**
     * @notice Get full resource event details
     * @param eventId Event identifier string
     * @return eventType Event type (1=Resource Rush, 2=Trade Frenzy, 3=Crafting Festival, 4=Harvest Bonanza)
     * @return startTime Unix timestamp when event started
     * @return endTime Unix timestamp when event ends
     * @return productionMultiplier Production bonus in basis points (10000 = 100%)
     * @return processingDiscount Cost reduction in basis points
     * @return rewardPool Total YLW reward pool for the event
     * @return totalContributions Total resources contributed by all participants
     * @return participantCount Number of unique participants
     * @return active Whether the event is currently active
     * @return minContribution Minimum contribution required to claim rewards
     */
    function getResourceEventDetails(string calldata eventId) external view returns (
        uint8 eventType,
        uint40 startTime,
        uint40 endTime,
        uint16 productionMultiplier,
        uint16 processingDiscount,
        uint256 rewardPool,
        uint256 totalContributions,
        uint256 participantCount,
        bool active,
        uint256 minContribution
    ) {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        bytes32 eventHash = keccak256(bytes(eventId));
        LibResourceStorage.ResourceEvent storage evt = rs.resourceEvents[eventHash];

        return (
            evt.eventType,
            evt.startTime,
            evt.endTime,
            evt.productionMultiplier,
            evt.processingDiscount,
            evt.rewardPool,
            rs.totalEventContributions[eventId],
            rs.totalEventParticipants[eventId],
            evt.active,
            evt.minContribution
        );
    }

    // ==================== HELPERS ====================

    /**
     * @notice Migrate existing events to allEventIds array
     * @dev One-time migration for events created before allEventIds was added
     * @param eventIds Array of event IDs to add to allEventIds
     */
    function migrateEventsToAllEventIds(string[] calldata eventIds) external onlyAuthorized {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();

        for (uint256 i = 0; i < eventIds.length; i++) {
            bytes32 eventHash = keccak256(bytes(eventIds[i]));
            // Only add if event exists (has a name)
            if (bytes(rs.resourceEvents[eventHash].name).length > 0) {
                rs.allEventIds.push(eventIds[i]);
            }
        }
    }

    function _removeFromActiveEvents(string calldata eventId) internal {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        
        for (uint256 i = 0; i < rs.activeEventIds.length; i++) {
            if (keccak256(bytes(rs.activeEventIds[i])) == keccak256(bytes(eventId))) {
                rs.activeEventIds[i] = rs.activeEventIds[rs.activeEventIds.length - 1];
                rs.activeEventIds.pop();
                break;
            }
        }
    }
    
    /**
     * @notice Distribute YLW reward with Treasury → Mint fallback
     * @dev Priority: 1) Transfer from treasury, 2) Mint if treasury insufficient
     * @param rewardToken YLW token address
     * @param treasury Treasury address
     * @param recipient User receiving the reward
     * @param amount Amount to distribute
     */
    function _distributeYlwReward(
        address rewardToken,
        address treasury,
        address recipient,
        uint256 amount
    ) internal {
        // Check treasury balance and allowance
        uint256 treasuryBalance = IERC20(rewardToken).balanceOf(treasury);
        uint256 allowance = IERC20(rewardToken).allowance(treasury, address(this));
        
        if (treasuryBalance >= amount && allowance >= amount) {
            // Pay from treasury (preferred - sustainable)
            IERC20(rewardToken).safeTransferFrom(treasury, recipient, amount);
        } else if (treasuryBalance > 0 && allowance > 0) {
            // Partial from treasury, rest from mint
            uint256 fromTreasury = treasuryBalance < allowance ? treasuryBalance : allowance;
            IERC20(rewardToken).safeTransferFrom(treasury, recipient, fromTreasury);
            
            uint256 shortfall = amount - fromTreasury;
            IRewardToken(rewardToken).mint(recipient, shortfall, "event_reward");
        } else {
            // Fallback: Mint new tokens
            IRewardToken(rewardToken).mint(recipient, amount, "event_reward");
        }
    }
}
