// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibMissionStorage} from "../libraries/LibMissionStorage.sol";
import {LibHenomorphsStorage} from "../libraries/LibHenomorphsStorage.sol";
import {LibMeta} from "../../shared/libraries/LibMeta.sol";
import {PodsUtils} from "../../../libraries/PodsUtils.sol";
import {AccessHelper} from "../../staking/libraries/AccessHelper.sol";
import {ColonyHelper} from "../../staking/libraries/ColonyHelper.sol";
import {AccessControlBase} from "../../common/facets/AccessControlBase.sol";
import {LibFeeCollection} from "../../staking/libraries/LibFeeCollection.sol";
import {ControlFee, SpecimenCollection, PowerMatrix} from "../../../libraries/HenomorphsModel.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ICollectionDiamond} from "../../modular/interfaces/ICollectionDiamond.sol";

/**
 * @title MissionFacet
 * @notice Core mission gameplay logic - start, play, complete missions
 * @dev Implements commit-reveal for fairness, integrates with charge system
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 */
contract MissionFacet is AccessControlBase {
    using SafeERC20 for IERC20;

    // ============================================================
    // REBALANCE CONSTANTS (2026-05 difficulty / agency upgrade)
    // ============================================================
    // Context: events used to be consequence-free. respondToEvent computed
    // outcome.damageTaken / outcome.rewardBonus but never applied them, so the
    // optimal play was "pick any response, just don't let it time out" and
    // Scan was strictly dominated (no hidden danger to reveal). These
    // constants give event resolution real teeth (failure = damage) and real
    // payoff (success = resources), give Scan information value via move-into-
    // fog ambush risk (B5), and reward squads that actually fight (B6).

    // B4 â€” per-event-type damage applied to the squad lead on a FAILED
    // response. Same channel as combat defeat (participant.damageTaken;
    // incapacitation at > initialCharge / 2).
    uint16 internal constant EVENT_DMG_PATROL = 15;
    uint16 internal constant EVENT_DMG_TRAP = 20;
    uint16 internal constant EVENT_DMG_AMBUSH = 25;
    uint16 internal constant EVENT_DMG_ENVIRONMENTAL = 18;
    uint16 internal constant EVENT_DMG_DEFAULT = 12;

    // B4 â€” dataFragments granted on a successful, reward-bearing event.
    uint8 internal constant EVENT_REWARD_FRAGMENTS = 8;

    // B5 â€” chance (%) that moving onto an UNDISCOVERED tile hiding an enemy
    // springs an ambush (damage, enemy NOT cleared). Scanning the tile first
    // sets discovered = true and avoids this entirely â€” Scan's reason to exist.
    uint8 internal constant MOVE_AMBUSH_CHANCE = 50;
    uint16 internal constant MOVE_AMBUSH_DAMAGE = 18;

    // B6 â€” engagement bonus: combat victories pay a small reward (basis points
    // of baseReward per win, capped). Combat costs charge and a loss dents the
    // performance rating, so this is a genuine risk/reward, not free money.
    uint16 internal constant COMBAT_WIN_BONUS_BP = 200;      // +2% per win
    uint16 internal constant COMBAT_WIN_BONUS_CAP_BP = 1000; // cap at +10%

    // ============================================================
    // EVENTS
    // ============================================================

    event MissionStarted(
        bytes32 indexed sessionId,
        address indexed initiator,
        uint16 passCollectionId,
        uint256 passTokenId,
        uint8 missionVariant,
        uint256[] participantIds
    );
    event MissionRevealed(bytes32 indexed sessionId, uint8 mapSize, uint8 objectiveCount);
    event MissionActionPerformed(
        bytes32 indexed sessionId,
        uint8 participantIndex,
        LibMissionStorage.MissionActionType actionType,
        bool success,
        uint8 chargeUsed
    );
    event MissionEventTriggered(bytes32 indexed sessionId, uint8 eventId, LibMissionStorage.EventType eventType);
    event MissionEventResolved(bytes32 indexed sessionId, uint8 eventId, bool success);
    // Emitted by expireMissionEvent â€” surfaced to UI so the player sees
    // "event timed out, mission continues" instead of being silently
    // unstuck. Penalty already accounted for via state.eventsFailed.
    event MissionEventTimedOut(bytes32 indexed sessionId, uint8 eventId);
    event MissionObjectiveCompleted(bytes32 indexed sessionId, uint8 objectiveId);
    event MissionCompleted(
        bytes32 indexed sessionId,
        address indexed initiator,
        uint256 totalReward,
        uint8 performanceRating
    );
    event MissionFailed(bytes32 indexed sessionId, address indexed initiator, string reason);
    event MissionAbandoned(bytes32 indexed sessionId, address indexed initiator);

    // Recharge events
    event MissionPassRecharged(
        uint16 indexed collectionId,
        uint256 indexed tokenId,
        address indexed user,
        uint16 usesAdded,
        uint256 totalCost
    );

    // Lending revenue share events
    event LenderRewardShareDeposited(
        uint16 indexed collectionId,
        uint256 indexed tokenId,
        address indexed lender,
        address borrower,
        uint256 amount
    );

    // ============================================================
    // ERRORS
    // ============================================================

    error MissionSystemPaused();
    error MissionNotFound(bytes32 sessionId);
    error NotMissionInitiator(bytes32 sessionId, address caller);
    error InvalidMissionPhase(bytes32 sessionId, LibMissionStorage.MissionPhase current, LibMissionStorage.MissionPhase expected);
    error RevealTooEarly(bytes32 sessionId, uint256 currentBlock, uint256 revealBlock);
    error RevealWindowExpired(bytes32 sessionId, uint256 currentBlock, uint256 deadline);
    error MissionDeadlinePassed(bytes32 sessionId, uint256 currentBlock, uint256 deadline);
    error EventResponseRequired(bytes32 sessionId, uint8 eventId);
    error NoEventPending(bytes32 sessionId);
    error EventDeadlinePassed(bytes32 sessionId);
    // 2026-05 upgrade â€” distinguishes "event expired, please clean up" from
    // "event still has time" so expireMissionEvent can be permissionless
    // without racing legitimate respondToEvent calls.
    error EventStillActive(bytes32 sessionId, uint256 currentBlock, uint256 deadline);
    error InvalidParticipantCount(uint256 provided, uint8 min, uint8 max);
    error ParticipantNotOwned(uint256 combinedId, address expected, address actual);
    error ParticipantAlreadyLocked(uint256 combinedId);
    error ParticipantInsufficientCharge(uint256 combinedId, uint256 current, uint256 required);
    error ParticipantNotActivated(uint256 combinedId);
    error CollectionNotEligible(uint16 collectionId);
    error MissionPassNotOwned(uint16 collectionId, uint256 tokenId);
    error MissionPassExhausted(uint16 collectionId, uint256 tokenId);
    error MissionPassCollectionDisabled(uint16 collectionId);
    error MissionVariantDisabled(uint16 collectionId, uint8 variantId);
    error UserAlreadyInMission(address user);
    error UserOnCooldown(address user, uint256 remainingTime);
    error TooManyActionsInBatch(uint256 provided, uint8 max);
    error InvalidActionTarget(uint8 nodeId);
    error ObjectivesNotComplete(bytes32 sessionId);
    error InsufficientRewardBalance(uint256 required, uint256 available);

    // Recharge errors
    error RechargeSystemPaused();
    error RechargeNotEnabled(uint16 collectionId);
    error RechargeOnCooldown(uint16 collectionId, uint256 tokenId, uint256 remainingTime);
    error PassNotInitialized(uint16 collectionId, uint256 tokenId);
    error TooManyUsesToRecharge(uint16 requested, uint16 max);
    error InsufficientPayment(uint256 required, uint256 available);

    // Delegation errors
    error PassCurrentlyDelegated(uint16 collectionId, uint256 tokenId);
    error NotPassOwnerOrDelegatee(uint16 collectionId, uint256 tokenId, address caller);
    error DelegationUsesExhausted(uint16 collectionId, uint256 tokenId);

    // ============================================================
    // MODIFIERS
    // ============================================================

    modifier whenMissionSystemActive() {
        if (LibMissionStorage.missionStorage().systemPaused) {
            revert MissionSystemPaused();
        }
        _;
    }

    modifier onlySessionInitiator(bytes32 sessionId) {
        LibMissionStorage.MissionStorage storage ms = LibMissionStorage.missionStorage();
        if (ms.sessionInitiators[sessionId] != LibMeta.msgSender()) {
            revert NotMissionInitiator(sessionId, LibMeta.msgSender());
        }
        _;
    }

    modifier inPhase(bytes32 sessionId, LibMissionStorage.MissionPhase expectedPhase) {
        LibMissionStorage.MissionStorage storage ms = LibMissionStorage.missionStorage();
        LibMissionStorage.MissionPhase currentPhase = LibMissionStorage.MissionPhase(ms.packedStates[sessionId].phase);
        if (currentPhase != expectedPhase) {
            revert InvalidMissionPhase(sessionId, currentPhase, expectedPhase);
        }
        _;
    }

    // ============================================================
    // CORE MISSION FUNCTIONS
    // ============================================================

    /**
     * @notice Start a new mission (Commit Phase)
     * @param passCollectionId Mission Pass collection ID
     * @param passTokenId Mission Pass token ID
     * @param missionVariant Which mission variant to play
     * @param participantIds Array of Henomorph combined IDs
     * @return sessionId Unique session identifier
     * @return revealBlock Block number when reveal becomes available
     */
    function startMission(
        uint16 passCollectionId,
        uint256 passTokenId,
        uint8 missionVariant,
        uint256[] calldata participantIds
    ) external whenMissionSystemActive whenNotPaused nonReentrant returns (bytes32 sessionId, uint256 revealBlock) {
        address initiator = LibMeta.msgSender();
        LibMissionStorage.MissionStorage storage ms = LibMissionStorage.missionStorage();

        // Check user not already in mission
        if (ms.userActiveMission[initiator] != bytes32(0)) {
            revert UserAlreadyInMission(initiator);
        }

        // Check user cooldown
        _checkUserCooldown(ms, passCollectionId, initiator);

        // Validate Mission Pass (returns isOwner for delegation tracking)
        bool isOwner = _validateMissionPass(passCollectionId, passTokenId, initiator);

        // Validate variant
        if (!ms.variantConfigs[passCollectionId][missionVariant].enabled) {
            revert MissionVariantDisabled(passCollectionId, missionVariant);
        }

        // Validate participants
        _validateParticipants(passCollectionId, participantIds);

        // Consume entry fee and Mission Pass use
        _consumeEntryFee(passCollectionId, initiator);
        _consumeMissionPassUse(passCollectionId, passTokenId, isOwner);

        // Generate session ID and initialize session
        sessionId = _generateSessionId(ms, initiator);
        revealBlock = block.number + LibMissionStorage.REVEAL_DELAY_BLOCKS;

        // Lock participants and notify Diamond about mission assignment
        // Note: Token is NOT transformed - only metadata tracking for mission status
        _lockParticipants(sessionId, participantIds, passCollectionId, passTokenId, missionVariant);

        // Initialize packed state
        _initializePackedState(ms, sessionId, passCollectionId, passTokenId, missionVariant, revealBlock);

        // Store session data
        ms.sessionInitiators[sessionId] = initiator;
        ms.sessionEntropy[sessionId] = bytes32(block.prevrandao);
        ms.userActiveMission[initiator] = sessionId;

        // Update counters
        ms.totalSessionsCreated++;

        emit MissionStarted(sessionId, initiator, passCollectionId, passTokenId, missionVariant, participantIds);
    }

    function _checkUserCooldown(
        LibMissionStorage.MissionStorage storage ms,
        uint16 passCollectionId,
        address initiator
    ) internal view {
        uint32 lastMissionEnd = ms.userMissionCooldowns[initiator];
        LibMissionStorage.MissionPassCollection storage passCollection = ms.passCollections[passCollectionId];
        if (lastMissionEnd > 0 && block.timestamp < lastMissionEnd + passCollection.globalCooldown) {
            revert UserOnCooldown(initiator, (lastMissionEnd + passCollection.globalCooldown) - block.timestamp);
        }
    }

    function _generateSessionId(
        LibMissionStorage.MissionStorage storage ms,
        address initiator
    ) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(
            block.timestamp,
            block.prevrandao,
            initiator,
            ms.totalSessionsCreated
        ));
    }

    function _initializePackedState(
        LibMissionStorage.MissionStorage storage ms,
        bytes32 sessionId,
        uint16 passCollectionId,
        uint256 passTokenId,
        uint8 missionVariant,
        uint256 revealBlock
    ) internal {
        uint32 deadlineBlock = uint32(block.number + ms.variantConfigs[passCollectionId][missionVariant].maxDurationBlocks);
        uint32 currentBlock = uint32(block.number);

        LibMissionStorage.PackedMissionState storage state = ms.packedStates[sessionId];

        // Slot 1
        state.sessionId = uint64(uint256(sessionId));
        state.startBlock = currentBlock;
        state.revealBlock = uint32(revealBlock);
        state.deadlineBlock = deadlineBlock;
        state.passCollectionId = passCollectionId;
        state.passTokenId = uint16(passTokenId);
        state.missionVariant = missionVariant;
        state.currentNodeId = 0;
        state.phase = uint8(LibMissionStorage.MissionPhase.Committed);
        state.objectivesMask = 0;
        state.totalActions = 0;
        state.combatsWon = 0;
        state.combatsLost = 0;
        state.flags = 0;

        // Slot 2
        state.chargeUsed = 0;
        state.dataFragments = 0;
        state.scrapMetal = 0;
        state.rareComponents = 0;
        state.eventsTriggered = 0;
        state.eventsResolved = 0;
        state.eventsFailed = 0;
        state.stealthSuccesses = 0;
        state.hacksCompleted = 0;
        state.secretsFound = 0;
        state.pendingEventId = 0;
        state.pendingEventDeadline = 0;
        state.lastActionBlock = currentBlock;
        state.rewardPool = 0;
    }

    /**
     * @notice Reveal mission map and objectives (after commit delay)
     * @param sessionId Session to reveal
     */
    function revealMission(bytes32 sessionId)
        external
        whenMissionSystemActive
        onlySessionInitiator(sessionId)
        inPhase(sessionId, LibMissionStorage.MissionPhase.Committed)
        nonReentrant
    {
        LibMissionStorage.MissionStorage storage ms = LibMissionStorage.missionStorage();
        LibMissionStorage.PackedMissionState storage state = ms.packedStates[sessionId];

        // Check reveal timing
        if (block.number < state.revealBlock) {
            revert RevealTooEarly(sessionId, block.number, state.revealBlock);
        }
        if (block.number > state.revealBlock + LibMissionStorage.REVEAL_WINDOW_BLOCKS) {
            // Mission expired - mark as failed
            state.phase = uint8(LibMissionStorage.MissionPhase.Expired);
            _unlockParticipants(sessionId);
            _cleanupSession(sessionId);
            emit MissionFailed(sessionId, LibMeta.msgSender(), "Reveal window expired");
            return;
        }

        // Generate entropy from reveal block
        bytes32 revealEntropy = keccak256(abi.encodePacked(
            ms.sessionEntropy[sessionId],
            blockhash(state.revealBlock)
        ));
        ms.sessionEntropy[sessionId] = revealEntropy;

        // Generate map
        LibMissionStorage.MissionVariantConfig storage config = ms.variantConfigs[state.passCollectionId][state.missionVariant];
        _generateMap(sessionId, revealEntropy, config);

        // Generate objectives
        _generateObjectives(sessionId, revealEntropy, config);

        // Update state
        state.phase = uint8(LibMissionStorage.MissionPhase.Active);
        state.lastActionBlock = uint32(block.number);

        emit MissionRevealed(sessionId, config.mapSize, config.requiredObjectivesCount + config.bonusObjectivesCount);
    }

    /**
     * @notice Perform mission actions (batch)
     * @param sessionId Active session
     * @param actions Array of actions to perform (max 5)
     * @return results Array of action results
     */
    function performMissionActions(
        bytes32 sessionId,
        LibMissionStorage.MissionAction[] calldata actions
    )
        external
        whenMissionSystemActive
        onlySessionInitiator(sessionId)
        inPhase(sessionId, LibMissionStorage.MissionPhase.Active)
        nonReentrant
        returns (LibMissionStorage.ActionResult[] memory results)
    {
        LibMissionStorage.MissionStorage storage ms = LibMissionStorage.missionStorage();
        LibMissionStorage.PackedMissionState storage state = ms.packedStates[sessionId];

        // Check deadline
        if (block.number > state.deadlineBlock) {
            revert MissionDeadlinePassed(sessionId, block.number, state.deadlineBlock);
        }

        // Validate action count
        if (actions.length > LibMissionStorage.MAX_ACTIONS_PER_BATCH) {
            revert TooManyActionsInBatch(actions.length, LibMissionStorage.MAX_ACTIONS_PER_BATCH);
        }

        results = new LibMissionStorage.ActionResult[](actions.length);

        for (uint256 i = 0; i < actions.length; i++) {
            results[i] = _resolveAction(sessionId, actions[i]);
            state.totalActions++;

            // The action itself fully executed (charge consumed, combat/loot/
            // scan resolved) regardless of whether it ALSO rolled a random
            // event. Emit its result BEFORE the event-trigger branch so a
            // Combat action that coincides with an event still surfaces its
            // win/lose. Previously the early `break` below skipped this emit,
            // so the client â€” which derives combat outcome SOLELY from
            // MissionActionPerformed â€” opened the event modal with no combat
            // result toast: the player saw charge spent with no resolution.
            emit MissionActionPerformed(
                sessionId,
                actions[i].participantIndex,
                actions[i].actionType,
                results[i].success,
                results[i].chargeUsed
            );

            // Check if event triggered
            if (results[i].triggeredEventId > 0) {
                state.phase = uint8(LibMissionStorage.MissionPhase.EventPending);
                state.pendingEventId = results[i].triggeredEventId;
                state.pendingEventDeadline = uint32(block.number) + ms.variantConfigs[state.passCollectionId][state.missionVariant].eventResponseBlocks;
                state.eventsTriggered++;

                emit MissionEventTriggered(sessionId, results[i].triggeredEventId, LibMissionStorage.EventType(results[i].triggeredEventId % 6));
                break; // Stop processing further actions
            }
        }

        state.lastActionBlock = uint32(block.number);

        // Check if all required objectives complete
        if (_checkAllRequiredObjectivesComplete(sessionId)) {
            state.phase = uint8(LibMissionStorage.MissionPhase.ReadyToComplete);
        }
    }

    /**
     * @notice Respond to a triggered event
     * @param sessionId Active session
     * @param response Player's response choice
     * @return outcome Result of the event resolution
     */
    function respondToEvent(
        bytes32 sessionId,
        LibMissionStorage.EventResponse response
    )
        external
        whenMissionSystemActive
        onlySessionInitiator(sessionId)
        inPhase(sessionId, LibMissionStorage.MissionPhase.EventPending)
        nonReentrant
        returns (LibMissionStorage.EventOutcome memory outcome)
    {
        LibMissionStorage.MissionStorage storage ms = LibMissionStorage.missionStorage();
        LibMissionStorage.PackedMissionState storage state = ms.packedStates[sessionId];

        // Check event deadline
        if (block.number > state.pendingEventDeadline) {
            revert EventDeadlinePassed(sessionId);
        }

        // Capture before clearing â€” the resolved event id is needed for the
        // emit below, which previously logged 0 (the already-cleared value).
        uint8 resolvedEventId = state.pendingEventId;

        // Resolve event
        outcome = _resolveEvent(sessionId, resolvedEventId, response);

        if (outcome.success) {
            state.eventsResolved++;
        } else {
            state.eventsFailed++;
            // Apply the event's bite to the squad lead â€” mirrors combat defeat
            // (participant.damageTaken + incapacitation at > initialCharge / 2).
            // Until now outcome.damageTaken was computed and discarded, which is
            // exactly why events were consequence-free.
            if (outcome.damageTaken > 0) {
                LibMissionStorage.PackedParticipant storage lead = ms.sessionParticipants[sessionId][0];
                lead.damageTaken += outcome.damageTaken;
                if (lead.damageTaken > lead.initialCharge / 2) {
                    lead.status = 1; // Incapacitated
                }
            }
        }

        // Clear event state
        state.pendingEventId = 0;
        state.pendingEventDeadline = 0;

        // Return to active phase
        state.phase = uint8(LibMissionStorage.MissionPhase.Active);

        // Check if objectives now complete
        if (_checkAllRequiredObjectivesComplete(sessionId)) {
            state.phase = uint8(LibMissionStorage.MissionPhase.ReadyToComplete);
        }

        emit MissionEventResolved(sessionId, resolvedEventId, outcome.success);
    }

    /**
     * @notice Auto-resolve a pending event whose response deadline has passed.
     * @dev Permissionless cleanup â€” the session initiator (or any keeper)
     *      can call this to break the EventPending lock without abandoning
     *      the squad. Penalty is the same as a failed Ignore response:
     *      eventsFailed++ (counts toward "eventIgnored" failure reason in
     *      _calculatePerformanceRating). After this call the session is
     *      back in Active phase and performMissionActions / extractMission
     *      become callable again.
     *
     *      This addresses a deployed-state bug where the contract had no
     *      auto-fail path for EventPending â€” a player who missed the event
     *      response window was forced to abandon (forfeiting the squad
     *      lock + accumulated rewards).
     */
    function expireMissionEvent(bytes32 sessionId)
        external
        whenMissionSystemActive
        nonReentrant
    {
        LibMissionStorage.MissionStorage storage ms = LibMissionStorage.missionStorage();
        LibMissionStorage.PackedMissionState storage state = ms.packedStates[sessionId];

        if (state.phase != uint8(LibMissionStorage.MissionPhase.EventPending)) {
            revert NoEventPending(sessionId);
        }
        if (block.number <= state.pendingEventDeadline) {
            revert EventStillActive(sessionId, block.number, state.pendingEventDeadline);
        }

        uint8 expiredEventId = state.pendingEventId;

        // Tally as a failed event (mirrors the response-failure path in
        // _resolveEvent + respondToEvent so performance rating treats this
        // identically to a botched Fight/Hide/Flee response).
        state.eventsFailed++;

        // Clear event state and return to active phase.
        state.pendingEventId = 0;
        state.pendingEventDeadline = 0;
        state.phase = uint8(LibMissionStorage.MissionPhase.Active);

        // After clearing, the player may have already met all required
        // objectives â€” flip phase straight to ReadyToComplete so they can
        // extract without an extra action tx.
        if (_checkAllRequiredObjectivesComplete(sessionId)) {
            state.phase = uint8(LibMissionStorage.MissionPhase.ReadyToComplete);
        }

        emit MissionEventTimedOut(sessionId, expiredEventId);
    }

    /**
     * @notice Complete mission and claim rewards
     * @param sessionId Session ready for completion
     * @return result Mission completion result including rewards
     */
    function extractMission(bytes32 sessionId)
        external
        whenMissionSystemActive
        onlySessionInitiator(sessionId)
        inPhase(sessionId, LibMissionStorage.MissionPhase.ReadyToComplete)
        nonReentrant
        returns (LibMissionStorage.MissionResult memory result)
    {
        LibMissionStorage.MissionStorage storage ms = LibMissionStorage.missionStorage();
        address initiator = ms.sessionInitiators[sessionId];

        // Mark Survive/Time as formally complete + emit completion events.
        // Must run BEFORE _calculateFinalRewards so performance rating and
        // perfect-completion bonus see the freshly closed objectives.
        // _checkAllRequiredObjectivesComplete already gated this extract via
        // live evaluation, so the conditions checked here are guaranteed
        // satisfiable for the required slots; bonus Survive/Time still get
        // a chance to flip if their condition holds.
        _completeTerminalObjectives(sessionId);

        // Calculate final rewards with all bonuses
        result = _calculateFinalRewards(sessionId);

        // Distribute rewards with revenue share support
        if (result.totalReward > 0) {
            LibMissionStorage.PackedMissionState storage state = ms.packedStates[sessionId];
            _distributeRewardsWithRevenueShare(
                initiator,
                result.totalReward,
                state.passCollectionId,
                state.passTokenId
            );
        }

        // Update user profile and state
        _updateUserProfileOnCompletion(ms, sessionId, initiator, result);

        // Unlock participants
        _unlockParticipants(sessionId);

        // Mark complete
        ms.packedStates[sessionId].phase = uint8(LibMissionStorage.MissionPhase.Completed);

        // Update cooldown
        ms.userMissionCooldowns[initiator] = uint32(block.timestamp);

        // Cleanup
        _cleanupSession(sessionId);

        // Update global stats
        ms.totalSessionsCompleted++;

        emit MissionCompleted(sessionId, initiator, result.totalReward, result.performanceRating);
    }

    function _updateUserProfileOnCompletion(
        LibMissionStorage.MissionStorage storage ms,
        bytes32 sessionId,
        address initiator,
        LibMissionStorage.MissionResult memory result
    ) internal {
        LibMissionStorage.PackedMissionState storage state = ms.packedStates[sessionId];
        LibMissionStorage.UserMissionProfile storage profile = ms.userProfiles[initiator];

        profile.totalMissionsCompleted++;
        profile.totalRewardsEarned += result.totalReward;
        profile.totalCombatsWon += state.combatsWon;
        profile.totalEventsResolved += state.eventsResolved;

        // Update streak
        _updateStreak(profile);

        // Check perfect completion
        if (state.combatsLost == 0 && state.eventsFailed == 0 && result.performanceRating == 100) {
            profile.perfectCompletions++;
        }
    }

    function _updateStreak(LibMissionStorage.UserMissionProfile storage profile) internal {
        uint32 today = uint32(block.timestamp / 1 days);
        if (profile.lastMissionDay == today - 1) {
            profile.currentStreak++;
            if (profile.currentStreak > profile.longestStreak) {
                profile.longestStreak = profile.currentStreak;
            }
        } else if (profile.lastMissionDay != today) {
            profile.currentStreak = 1;
        }
        profile.lastMissionDay = today;
    }

    /**
     * @notice Abandon an active mission (forfeit rewards)
     * @param sessionId Session to abandon
     */
    function abandonMission(bytes32 sessionId)
        external
        onlySessionInitiator(sessionId)
        nonReentrant
    {
        LibMissionStorage.MissionStorage storage ms = LibMissionStorage.missionStorage();
        LibMissionStorage.PackedMissionState storage state = ms.packedStates[sessionId];
        address initiator = ms.sessionInitiators[sessionId];

        // Can abandon from Committed, Active, or EventPending phases
        LibMissionStorage.MissionPhase phase = LibMissionStorage.MissionPhase(state.phase);
        if (phase == LibMissionStorage.MissionPhase.Completed ||
            phase == LibMissionStorage.MissionPhase.Failed ||
            phase == LibMissionStorage.MissionPhase.Expired ||
            phase == LibMissionStorage.MissionPhase.NotStarted) {
            revert InvalidMissionPhase(sessionId, phase, LibMissionStorage.MissionPhase.Active);
        }

        // Update profile
        ms.userProfiles[initiator].totalMissionsFailed++;
        ms.userProfiles[initiator].currentStreak = 0; // Reset streak on abandon

        // Unlock participants
        _unlockParticipants(sessionId);

        // Mark failed
        state.phase = uint8(LibMissionStorage.MissionPhase.Failed);

        // Cleanup
        _cleanupSession(sessionId);

        // Update global stats
        ms.totalSessionsFailed++;

        emit MissionAbandoned(sessionId, initiator);
    }

    // ============================================================
    // VIEW FUNCTIONS
    // ============================================================
    //
    // Most pure-storage views moved to MissionConfigFacet to free bytecode
    // budget on this facet (size-constrained at ~33KB). The two views left
    // here depend on internal helpers (_checkAllRequiredObjectivesComplete,
    // _calculateFinalRewards) that aren't worth duplicating.

    /**
     * @notice Check if mission can be extracted
     */
    function canExtractMission(bytes32 sessionId)
        external
        view
        returns (bool canExtract, string memory reason)
    {
        LibMissionStorage.MissionStorage storage ms = LibMissionStorage.missionStorage();
        LibMissionStorage.PackedMissionState storage state = ms.packedStates[sessionId];

        if (state.phase == uint8(LibMissionStorage.MissionPhase.ReadyToComplete)) {
            return (true, "");
        }
        if (state.phase == uint8(LibMissionStorage.MissionPhase.Active)) {
            if (!_checkAllRequiredObjectivesComplete(sessionId)) {
                return (false, "Required objectives not complete");
            }
            return (false, "Phase not updated yet - perform action or call check");
        }
        return (false, "Invalid mission phase");
    }

    /**
     * @notice Estimate rewards for completing current mission state
     */
    function estimateMissionRewards(bytes32 sessionId) external view returns (uint256 estimatedReward) {
        LibMissionStorage.MissionResult memory result = _calculateFinalRewards(sessionId);
        return result.totalReward;
    }

    // ============================================================
    // RECHARGE FUNCTIONS
    // ============================================================

    /**
     * @notice Recharge a Mission Pass with additional uses
     * @dev Only pass owner can recharge. Pass must be Active or Exhausted (not Uninitialized).
     * @param collectionId Mission Pass collection ID
     * @param tokenId Token ID to recharge
     * @param usesToAdd Number of uses to add
     */
    function rechargeMissionPass(
        uint16 collectionId,
        uint256 tokenId,
        uint16 usesToAdd
    ) external whenNotPaused nonReentrant {
        LibMissionStorage.MissionStorage storage ms = LibMissionStorage.missionStorage();

        // Check recharge system not paused
        if (ms.rechargeSystemPaused) {
            revert RechargeSystemPaused();
        }

        // Validate collection exists
        if (collectionId == 0 || collectionId > ms.passCollectionCounter) {
            revert MissionPassCollectionDisabled(collectionId);
        }

        LibMissionStorage.RechargeConfig storage config = ms.passRechargeConfigs[collectionId];

        // Check recharge enabled for this collection
        if (!config.enabled) {
            revert RechargeNotEnabled(collectionId);
        }

        // Verify caller is NFT owner (only owner can recharge, not delegatee)
        LibMissionStorage.MissionPassCollection storage passCollection = ms.passCollections[collectionId];
        address caller = LibMeta.msgSender();
        if (IERC721(passCollection.collectionAddress).ownerOf(tokenId) != caller) {
            revert MissionPassNotOwned(collectionId, tokenId);
        }

        // Check pass status - must be Active or Exhausted (not Uninitialized)
        LibMissionStorage.PassStatus status = ms.passStatus[collectionId][tokenId];
        if (status == LibMissionStorage.PassStatus.Uninitialized) {
            revert PassNotInitialized(collectionId, tokenId);
        }

        // Check max recharge per tx
        if (config.maxRechargePerTx > 0 && usesToAdd > config.maxRechargePerTx) {
            revert TooManyUsesToRecharge(usesToAdd, config.maxRechargePerTx);
        }

        // Check cooldown
        LibMissionStorage.PassRechargeRecord storage record = ms.passRechargeRecords[collectionId][tokenId];
        if (config.cooldownSeconds > 0 && record.lastRechargeTime > 0) {
            uint256 nextRechargeTime = record.lastRechargeTime + config.cooldownSeconds;
            if (block.timestamp < nextRechargeTime) {
                revert RechargeOnCooldown(collectionId, tokenId, nextRechargeTime - block.timestamp);
            }
        }

        // Calculate cost with discount
        // finalPrice = (pricePerUse * usesToAdd) * (10000 - discountBps) / 10000
        uint256 totalCost = uint256(config.pricePerUse) * usesToAdd;
        if (config.discountBps > 0) {
            totalCost = (totalCost * (10000 - config.discountBps)) / 10000;
        }

        // Collect payment
        if (totalCost > 0) {
            if (config.burnOnCollect) {
                // Burn tokens via treasury
                LibFeeCollection.collectAndBurnFee(
                    IERC20(config.paymentToken),
                    caller,
                    config.paymentBeneficiary,
                    totalCost,
                    "mission_pass_recharge"
                );
            } else {
                // Transfer to beneficiary using LibFeeCollection
                LibFeeCollection.collectFee(
                    IERC20(config.paymentToken),
                    caller,
                    config.paymentBeneficiary,
                    totalCost,
                    "mission_pass_recharge"
                );
            }
        }

        // Update uses remaining
        ms.passUsesRemaining[collectionId][tokenId] += usesToAdd;

        // Update status to Active
        ms.passStatus[collectionId][tokenId] = LibMissionStorage.PassStatus.Active;

        // Update recharge record
        record.lastRechargeTime = uint32(block.timestamp);
        record.totalRecharges++;
        record.totalUsesRecharged += usesToAdd;

        emit MissionPassRecharged(collectionId, tokenId, caller, usesToAdd, totalCost);
    }

    /**
     * @notice Get recharge info for a specific Mission Pass
     * @param collectionId Mission Pass collection ID
     * @param tokenId Token ID
     * @return status Current pass status
     * @return usesRemaining Remaining uses
     * @return canRecharge Whether pass can be recharged
     * @return cooldownRemaining Seconds until recharge available (0 if no cooldown)
     * @return pricePerUse Base price per use
     * @return discountBps Discount in basis points
     */
    function getPassRechargeInfo(uint16 collectionId, uint256 tokenId)
        external
        view
        returns (
            LibMissionStorage.PassStatus status,
            uint16 usesRemaining,
            bool canRecharge,
            uint256 cooldownRemaining,
            uint96 pricePerUse,
            uint16 discountBps
        )
    {
        LibMissionStorage.MissionStorage storage ms = LibMissionStorage.missionStorage();

        status = ms.passStatus[collectionId][tokenId];
        usesRemaining = ms.passUsesRemaining[collectionId][tokenId];

        LibMissionStorage.RechargeConfig storage config = ms.passRechargeConfigs[collectionId];
        pricePerUse = config.pricePerUse;
        discountBps = config.discountBps;

        // Can recharge if: recharge enabled, pass initialized (Active or Exhausted), not on cooldown
        canRecharge = config.enabled &&
            !ms.rechargeSystemPaused &&
            status != LibMissionStorage.PassStatus.Uninitialized;

        // Calculate cooldown remaining
        if (config.cooldownSeconds > 0) {
            LibMissionStorage.PassRechargeRecord storage record = ms.passRechargeRecords[collectionId][tokenId];
            if (record.lastRechargeTime > 0) {
                uint256 nextRechargeTime = record.lastRechargeTime + config.cooldownSeconds;
                if (block.timestamp < nextRechargeTime) {
                    cooldownRemaining = nextRechargeTime - block.timestamp;
                    canRecharge = false;
                }
            }
        }
    }

    /**
     * @notice Get recharge history for a specific Mission Pass
     * @param collectionId Mission Pass collection ID
     * @param tokenId Token ID
     * @return record Recharge record
     */
    function getPassRechargeRecord(uint16 collectionId, uint256 tokenId)
        external
        view
        returns (LibMissionStorage.PassRechargeRecord memory record)
    {
        return LibMissionStorage.missionStorage().passRechargeRecords[collectionId][tokenId];
    }

    // ============================================================
    // INTERNAL FUNCTIONS - VALIDATION
    // ============================================================

    /**
     * @notice Validate Mission Pass ownership or delegation (ERC-4907 pattern)
     * @dev Supports both direct ownership and time-limited delegation with auto-expiry
     * @param collectionId Mission Pass collection ID
     * @param tokenId Token ID
     * @param user Address attempting to use the pass
     * @return isOwner True if user is the NFT owner, false if delegatee
     */
    function _validateMissionPass(uint16 collectionId, uint256 tokenId, address user) internal view returns (bool isOwner) {
        LibMissionStorage.MissionStorage storage ms = LibMissionStorage.missionStorage();
        LibMissionStorage.MissionPassCollection storage passCollection = ms.passCollections[collectionId];

        if (!passCollection.enabled) {
            revert MissionPassCollectionDisabled(collectionId);
        }

        // Check if user is NFT owner
        address nftOwner = IERC721(passCollection.collectionAddress).ownerOf(tokenId);
        isOwner = (nftOwner == user);

        if (!isOwner) {
            // Check if user is valid delegatee (ERC-4907 auto-expiry pattern)
            LibMissionStorage.PassDelegation storage delegation = ms.passDelegations[collectionId][tokenId];

            // Auto-expiry: delegation is invalid if expired (like ERC-4907 userOf())
            if (delegation.delegatee != user || block.timestamp >= delegation.expires) {
                revert NotPassOwnerOrDelegatee(collectionId, tokenId, user);
            }

            // Check delegation use limit if set
            if (delegation.usesAllowed > 0 && delegation.usesConsumed >= delegation.usesAllowed) {
                revert DelegationUsesExhausted(collectionId, tokenId);
            }
        } else {
            // Owner cannot use pass if it's currently delegated to someone else
            LibMissionStorage.PassDelegation storage delegation = ms.passDelegations[collectionId][tokenId];
            if (delegation.delegatee != address(0) && block.timestamp < delegation.expires) {
                revert PassCurrentlyDelegated(collectionId, tokenId);
            }
        }

        // Check uses remaining using PassStatus
        if (passCollection.maxUsesPerToken > 0) {
            LibMissionStorage.PassStatus status = ms.passStatus[collectionId][tokenId];

            // If Exhausted, cannot use (must recharge first)
            if (status == LibMissionStorage.PassStatus.Exhausted) {
                revert MissionPassExhausted(collectionId, tokenId);
            }

            // If Active, check remaining uses
            if (status == LibMissionStorage.PassStatus.Active) {
                uint16 remaining = ms.passUsesRemaining[collectionId][tokenId];
                if (remaining == 0) {
                    revert MissionPassExhausted(collectionId, tokenId);
                }
            }
            // If Uninitialized, it will be initialized in _consumeMissionPassUse
        }
    }

    /**
     * @notice Consume one use of a Mission Pass
     * @dev Tracks uses for both owner and delegatee, updates PassStatus
     * @param collectionId Mission Pass collection ID
     * @param tokenId Token ID
     * @param isOwner True if caller is owner, false if delegatee
     */
    function _consumeMissionPassUse(uint16 collectionId, uint256 tokenId, bool isOwner) internal {
        LibMissionStorage.MissionStorage storage ms = LibMissionStorage.missionStorage();
        LibMissionStorage.MissionPassCollection storage passCollection = ms.passCollections[collectionId];

        if (passCollection.maxUsesPerToken > 0) {
            LibMissionStorage.PassStatus status = ms.passStatus[collectionId][tokenId];

            // Initialize if first use (Uninitialized status)
            if (status == LibMissionStorage.PassStatus.Uninitialized) {
                ms.passUsesRemaining[collectionId][tokenId] = passCollection.maxUsesPerToken;
                ms.passStatus[collectionId][tokenId] = LibMissionStorage.PassStatus.Active;
            }

            uint16 remaining = ms.passUsesRemaining[collectionId][tokenId];

            if (remaining == 0) {
                revert MissionPassExhausted(collectionId, tokenId);
            }

            // Decrement remaining uses
            remaining -= 1;
            ms.passUsesRemaining[collectionId][tokenId] = remaining;

            // Update status to Exhausted if no uses left
            if (remaining == 0) {
                ms.passStatus[collectionId][tokenId] = LibMissionStorage.PassStatus.Exhausted;
            }
        }

        // Track delegation usage if not owner
        if (!isOwner) {
            LibMissionStorage.PassDelegation storage delegation = ms.passDelegations[collectionId][tokenId];
            if (delegation.usesAllowed > 0) {
                delegation.usesConsumed++;
            }
        }
    }

    function _validateParticipants(uint16 passCollectionId, uint256[] calldata participantIds) internal view {
        LibMissionStorage.MissionStorage storage ms = LibMissionStorage.missionStorage();
        LibMissionStorage.MissionPassCollection storage passCollection = ms.passCollections[passCollectionId];

        // Check count
        if (participantIds.length < passCollection.minHenomorphs ||
            participantIds.length > passCollection.maxHenomorphs) {
            revert InvalidParticipantCount(participantIds.length, passCollection.minHenomorphs, passCollection.maxHenomorphs);
        }

        address owner = LibMeta.msgSender();
        for (uint256 i = 0; i < participantIds.length; i++) {
            _validateSingleParticipant(ms, passCollection, participantIds[i], owner);
        }
    }

    function _validateSingleParticipant(
        LibMissionStorage.MissionStorage storage ms,
        LibMissionStorage.MissionPassCollection storage passCollection,
        uint256 combinedId,
        address owner
    ) internal view {
        (uint256 collectionId, uint256 tokenId) = PodsUtils.extractIds(combinedId);

        // Check collection eligibility
        _checkCollectionEligibility(passCollection, uint16(collectionId));

        // Check ownership and state (supports both wallet-owned and staked tokens via AccessHelper)
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        if (!AccessHelper.checkTokenOwnership(collectionId, tokenId, owner, AccessHelper.getStakingAddress())) {
            revert ParticipantNotOwned(combinedId, owner, address(0));
        }

        // Check not already locked
        if (ms.lockedHenomorphs[combinedId]) {
            revert ParticipantAlreadyLocked(combinedId);
        }

        // Check power core activated and charge
        _checkParticipantCharge(hs, passCollection, combinedId);
    }

    function _checkCollectionEligibility(
        LibMissionStorage.MissionPassCollection storage passCollection,
        uint16 collectionId
    ) internal view {
        bool eligible = false;
        for (uint256 j = 0; j < passCollection.eligibleCollections.length; j++) {
            if (passCollection.eligibleCollections[j] == collectionId) {
                eligible = true;
                break;
            }
        }
        if (!eligible) {
            revert CollectionNotEligible(collectionId);
        }
    }

    function _checkParticipantCharge(
        LibHenomorphsStorage.HenomorphsStorage storage hs,
        LibMissionStorage.MissionPassCollection storage passCollection,
        uint256 combinedId
    ) internal view {
        PowerMatrix storage charge = hs.performedCharges[combinedId];
        if (charge.lastChargeTime == 0) {
            revert ParticipantNotActivated(combinedId);
        }

        uint256 minCharge = (charge.maxCharge * passCollection.minChargePercent) / 100;
        if (charge.currentCharge < minCharge) {
            revert ParticipantInsufficientCharge(combinedId, charge.currentCharge, minCharge);
        }
    }

    // ============================================================
    // INTERNAL FUNCTIONS - LOCKING
    // ============================================================

    function _lockParticipants(
        bytes32 sessionId,
        uint256[] calldata participantIds,
        uint16 passCollectionId,
        uint256 passTokenId,
        uint8 missionVariant
    ) internal {
        LibMissionStorage.MissionStorage storage ms = LibMissionStorage.missionStorage();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();

        // Get pass collection address for Diamond notifications
        address passCollectionAddress = ms.passCollections[passCollectionId].collectionAddress;

        for (uint256 i = 0; i < participantIds.length; i++) {
            uint256 combinedId = participantIds[i];

            // Lock in mission storage
            ms.lockedHenomorphs[combinedId] = true;
            ms.henomorphActiveMission[combinedId] = sessionId;

            // Store participant data
            PowerMatrix storage charge = hs.performedCharges[combinedId];
            ms.sessionParticipants[sessionId].push(LibMissionStorage.PackedParticipant({
                combinedId: uint128(combinedId),
                initialCharge: uint32(charge.currentCharge),
                currentCharge: uint32(charge.currentCharge),
                damageDealt: 0,
                damageTaken: 0,
                xpEarned: 0,
                actionsPerformed: 0,
                status: 0, // Active
                bonusFlags: 0
            }));

            // Notify Diamond about mission assignment (metadata tracking only)
            // Token is NOT transformed - only metadata reflects mission status
            _notifyMissionAssigned(
                combinedId,
                sessionId,
                passCollectionAddress,
                passTokenId,
                missionVariant
            );
        }
    }

    function _unlockParticipants(bytes32 sessionId) internal {
        LibMissionStorage.MissionStorage storage ms = LibMissionStorage.missionStorage();
        LibMissionStorage.PackedMissionState storage state = ms.packedStates[sessionId];
        LibMissionStorage.PackedParticipant[] storage participants = ms.sessionParticipants[sessionId];
        LibMissionStorage.MissionPassCollection storage passConfig = ms.passCollections[state.passCollectionId];

        // PackedParticipant.combinedId is uint128, but _lockParticipants stored
        // the lock under the FULL uint256 key `(specimenCollectionId<<128)|tokenId`.
        // The truncated value alone is not enough to reconstruct the original key,
        // so iterate over every eligible specimen collection and clear the entry
        // that actually points at this session. Other candidates are no-ops.
        for (uint256 i = 0; i < participants.length; i++) {
            uint256 truncated = uint256(participants[i].combinedId);

            for (uint256 j = 0; j < passConfig.eligibleCollections.length; j++) {
                uint256 fullKey = (uint256(passConfig.eligibleCollections[j]) << 128) | truncated;
                if (ms.henomorphActiveMission[fullKey] == sessionId) {
                    ms.lockedHenomorphs[fullKey] = false;
                    delete ms.henomorphActiveMission[fullKey];
                    _notifyMissionRemoved(fullKey, sessionId, passConfig.collectionAddress);
                }
            }
        }
    }

    // ============================================================
    // INTERNAL FUNCTIONS - DIAMOND NOTIFICATIONS
    // ============================================================

    /**
     * @notice Notify Diamond about mission assignment (metadata tracking only)
     * @dev Token is NOT transformed - Diamond only tracks mission status for metadata
     * @param combinedId Combined collection + token ID
     * @param sessionId Mission session ID
     * @param passCollectionAddress Mission Pass collection address
     * @param passTokenId Mission Pass token ID
     * @param missionVariant Mission variant (0-4)
     */
    function _notifyMissionAssigned(
        uint256 combinedId,
        bytes32 sessionId,
        address passCollectionAddress,
        uint256 passTokenId,
        uint8 missionVariant
    ) internal {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();

        // Extract collection ID and token ID from combined ID
        (uint256 collectionId, uint256 tokenId) = PodsUtils.extractIds(combinedId);

        // Get specimen collection configuration
        SpecimenCollection storage collection = hs.specimenCollections[uint16(collectionId)];

        // Only notify if collection has Diamond configured and is modular
        if (collection.diamondAddress != address(0) && collection.isModularSpecimen) {
            try ICollectionDiamond(collection.diamondAddress).onMissionAssigned(
                collection.collectionAddress,
                tokenId,
                sessionId,
                passCollectionAddress,
                passTokenId,
                missionVariant
            ) {
                // Success - Diamond notified
            } catch {
                // Ignore errors to prevent mission start failures
                // Mission can proceed even if metadata notification fails
            }
        }
    }

    /**
     * @notice Notify Diamond about mission removal (clear metadata tracking)
     * @dev Called when mission ends (complete, fail, or abandon)
     * @param combinedId Combined collection + token ID
     * @param sessionId Mission session ID
     */
    function _notifyMissionRemoved(
        uint256 combinedId,
        bytes32 sessionId,
        address
    ) internal {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();

        // Extract collection ID and token ID from combined ID
        (uint256 collectionId, uint256 tokenId) = PodsUtils.extractIds(combinedId);

        // Get specimen collection configuration
        SpecimenCollection storage collection = hs.specimenCollections[uint16(collectionId)];

        // Only notify if collection has Diamond configured and is modular
        if (collection.diamondAddress != address(0) && collection.isModularSpecimen) {
            try ICollectionDiamond(collection.diamondAddress).onMissionRemoved(
                collection.collectionAddress,
                tokenId,
                sessionId
            ) {
                // Success - Diamond notified
            } catch {
                // Ignore errors to prevent mission completion failures
            }
        }
    }

    // ============================================================
    // INTERNAL FUNCTIONS - FEE & REWARDS
    // ============================================================

    function _consumeEntryFee(uint16 passCollectionId, address payer) internal {
        LibMissionStorage.MissionStorage storage ms = LibMissionStorage.missionStorage();
        LibMissionStorage.MissionPassCollection storage config = ms.passCollections[passCollectionId];

        if (config.entryFee.amount > 0 && address(config.entryFee.currency) != address(0)) {
            LibFeeCollection.processOperationFee(config.entryFee, payer);
        }
    }

    function _distributeRewards(address recipient, uint256 amount) internal {
        LibMissionStorage.MissionStorage storage ms = LibMissionStorage.missionStorage();

        if (ms.rewardToken == address(0)) {
            return; // No reward token configured
        }

        // Transfer from treasury using LibFeeCollection pattern
        LibFeeCollection.transferFromTreasury(recipient, amount, "mission_reward");
    }

    /**
     * @notice Distribute rewards with revenue share support for lending
     * @dev Checks if initiator is a borrower with active revenue share delegation
     * @param initiator Mission initiator (owner or borrower)
     * @param totalReward Total reward amount
     * @param passCollectionId Mission Pass collection ID
     * @param passTokenId Mission Pass token ID
     */
    function _distributeRewardsWithRevenueShare(
        address initiator,
        uint256 totalReward,
        uint16 passCollectionId,
        uint16 passTokenId
    ) internal {
        LibMissionStorage.MissionStorage storage ms = LibMissionStorage.missionStorage();

        if (ms.rewardToken == address(0)) {
            return; // No reward token configured
        }

        // Check if initiator is a borrower with active revenue share delegation
        LibMissionStorage.PassDelegation storage delegation = ms.passDelegations[passCollectionId][passTokenId];

        // Revenue share only applies if:
        // 1. Delegation is active (not expired)
        // 2. Initiator is the delegatee (borrower)
        // 3. Revenue share percentage is configured (> 0)
        if (delegation.delegatee == initiator &&
            block.timestamp < delegation.expires &&
            delegation.rewardShareBps > 0) {

            // Calculate lender's share
            uint256 lenderShare = (totalReward * delegation.rewardShareBps) / 10000;
            uint256 borrowerShare = totalReward - lenderShare;

            // Add lender share to escrow (will be withdrawn via MissionPassLendingFacet)
            if (lenderShare > 0) {
                ms.lendingEscrowBalance[delegation.lender] += lenderShare;

                // Transfer lender share to this contract (escrow)
                LibFeeCollection.transferFromTreasury(address(this), lenderShare, "mission_reward_lender_share");

                emit LenderRewardShareDeposited(
                    passCollectionId,
                    passTokenId,
                    delegation.lender,
                    initiator,
                    lenderShare
                );
            }

            // Transfer borrower share directly to borrower
            if (borrowerShare > 0) {
                LibFeeCollection.transferFromTreasury(initiator, borrowerShare, "mission_reward_borrower_share");
            }
        } else {
            // No revenue share - full reward to initiator
            LibFeeCollection.transferFromTreasury(initiator, totalReward, "mission_reward");
        }
    }

    // ============================================================
    // INTERNAL FUNCTIONS - MAP GENERATION
    // ============================================================

    function _generateMap(
        bytes32 sessionId,
        bytes32 entropy,
        LibMissionStorage.MissionVariantConfig storage config
    ) internal {
        LibMissionStorage.MissionStorage storage ms = LibMissionStorage.missionStorage();
        LibMissionStorage.PackedMapNodes storage nodes = ms.sessionMaps[sessionId];

        uint8 mapSize = config.mapSize;
        uint8 combatNodesPlaced = 0;

        for (uint8 i = 0; i < mapSize; i++) {
            (LibMissionStorage.MapNode memory node, uint8 newCombatCount) = _generateNode(
                i, mapSize, entropy, config, combatNodesPlaced
            );
            combatNodesPlaced = newCombatCount;
            LibMissionStorage.setNode(nodes, i, node);
        }

        // Quota enforcement â€” pre-fix, _determineNodeType rolled each non-
        // forced slot independently against `lootNodeChance` etc., so a 6-8
        // node map could legitimately end with 0 Loot tiles while the
        // template's required Collect target was 3-5. _ensureMinimumPayloads
        // counts the surface area of each payload type and converts Empty
        // tiles to fill the gap so every required objective has at least
        // enough nodes to satisfy its maxTarget.
        _ensureMinimumPayloads(sessionId, entropy, config, nodes, mapSize);
    }

    /**
     * @notice Top up Loot/Combat/Terminal node counts so every required
     * objective has enough payload tiles to be completable.
     * @dev Iterates the variant's objective templates to find max(target)
     * per type, counts existing matching tiles in the generated map,
     * and converts Empty tiles (skipping node 0 and the Exit) to make up
     * any shortfall. Conversion order is deterministic from `entropy` so
     * identical (seed, variant) pairs still produce identical maps.
     */
    function _ensureMinimumPayloads(
        bytes32 sessionId,
        bytes32 entropy,
        LibMissionStorage.MissionVariantConfig storage config,
        LibMissionStorage.PackedMapNodes storage nodes,
        uint8 mapSize
    ) internal {
        // Templates configured? Then required-objective math drives quotas.
        // Legacy variants (templateCount=0) get conservative defaults so
        // they don't regress vs. the pre-fix RNG.
        uint8 needLoot;
        uint8 needEnemy;
        uint8 needTerminal;
        if (config.objectiveTemplateCount > 0) {
            for (uint8 ti = 0; ti < config.objectiveTemplateCount; ti++) {
                LibMissionStorage.ObjectiveTemplate storage tmpl = config.objectiveTemplates[ti];
                if (!tmpl.enabled || !tmpl.isRequired) continue;
                if (tmpl.objectiveType == LibMissionStorage.ObjectiveType.Collect) {
                    if (tmpl.maxTarget > needLoot) needLoot = tmpl.maxTarget;
                } else if (tmpl.objectiveType == LibMissionStorage.ObjectiveType.Defeat) {
                    if (tmpl.maxTarget > needEnemy) needEnemy = tmpl.maxTarget;
                } else if (tmpl.objectiveType == LibMissionStorage.ObjectiveType.Hack) {
                    if (tmpl.maxTarget > needTerminal) needTerminal = tmpl.maxTarget;
                }
            }
        } else {
            // Legacy floor: 2 of each so no variant is stuck with 0 payload.
            needLoot = 2;
            needEnemy = 2;
            needTerminal = 1;
        }

        // Count current placements (node 0 is Empty start, last is Exit;
        // both excluded from conversion below).
        uint8 haveLoot;
        uint8 haveEnemy;
        uint8 haveTerminal;
        for (uint8 i = 0; i < mapSize; i++) {
            LibMissionStorage.MapNode memory n = LibMissionStorage.getNode(nodes, i);
            if (n.hasLoot) haveLoot++;
            if (n.hasEnemy) haveEnemy++;
            if (n.nodeType == LibMissionStorage.NodeType.Terminal) haveTerminal++;
        }

        // Multi-pass conversion to fill quotas. Priority by source type so
        // higher-value gameplay tiles are preserved when possible:
        //   pass 0: Empty tiles (no gameplay value; preferred first)
        //   pass 1: Event tiles (random outcomes, OK to consume)
        //   pass 2: Secret tiles (random outcomes, last resort)
        //   pass 3: EXCESS Combat tiles (haveEnemy > needEnemy)
        //   pass 4: EXCESS Terminal tiles (haveTerminal > needTerminal)
        // Objective / Exit / start / first `minCombatNodes` Combats are NEVER
        // converted â€” they're either mission-critical or guaranteed minimums.
        //
        // 2026-05-11 PATCH (v1): single-pass Empty-only was too restrictive.
        // 2026-05-11 PATCH (v2): even 3-pass (Empty/Event/Secret) wasn't
        // sufficient on high-lootChance variants where RNG plus minCombatNodes
        // consumed all non-Combat slots. Adding excess-payload demotion
        // (passes 3-4) guarantees quotas are met whenever the math allows:
        //   needLoot + needEnemy + needTerminal <= mapSize - 2.
        // For V4 mapSize=14 / minCombat=5 / needEnemy=4 / needLoot=6 /
        // needTerminal=2 = 12 â‰¤ 12, the patch now satisfies even worst-case
        // RNG. The 1 excess Combat (minCombat 5 - needEnemy 4) gets demoted
        // to Loot in pass 3, providing the final tile needed.
        uint8 minCombatProtect = config.minCombatNodes;
        for (uint8 pass = 0; pass < 5; pass++) {
            if (haveLoot >= needLoot && haveEnemy >= needEnemy && haveTerminal >= needTerminal) break;

            for (uint8 i = 1; i + 1 < mapSize; i++) {
                if (haveLoot >= needLoot && haveEnemy >= needEnemy && haveTerminal >= needTerminal) break;

                LibMissionStorage.MapNode memory n = LibMissionStorage.getNode(nodes, i);

                // Source-type gate per pass.
                bool sourceOk;
                if (pass == 0) {
                    sourceOk = (n.nodeType == LibMissionStorage.NodeType.Empty);
                } else if (pass == 1) {
                    sourceOk = (n.nodeType == LibMissionStorage.NodeType.Event);
                } else if (pass == 2) {
                    sourceOk = (n.nodeType == LibMissionStorage.NodeType.Secret);
                } else if (pass == 3) {
                    // Excess Combat: only demote if haveEnemy > needEnemy AND
                    // this slot is beyond the forced minCombatNodes range
                    // (forced Combats sit at indices 1..minCombatNodes per
                    // `_generateNode`; demoting them would violate the variant
                    // contract). Don't pre-decrement: only convert when there
                    // is genuine excess.
                    sourceOk = (
                        n.nodeType == LibMissionStorage.NodeType.Combat
                        && n.hasEnemy
                        && i > minCombatProtect
                        && haveEnemy > needEnemy
                    );
                } else {
                    // pass 4: excess Terminal
                    sourceOk = (
                        n.nodeType == LibMissionStorage.NodeType.Terminal
                        && haveTerminal > needTerminal
                    );
                }
                if (!sourceOk) continue;

                // Pick the most under-quota target type. Tie-break with entropy.
                uint256 pick = uint256(keccak256(abi.encodePacked(entropy, "ensureMin", i, pass))) % 3;
                bool converted = false;
                if (haveLoot < needLoot && (pick == 0 || (haveEnemy >= needEnemy && haveTerminal >= needTerminal))) {
                    // Demoting a Combat? Clear hasEnemy and decrement count
                    // before flipping the tile, otherwise the post-write count
                    // would still consider it an enemy.
                    if (n.hasEnemy) { n.hasEnemy = false; haveEnemy--; }
                    n.nodeType = LibMissionStorage.NodeType.Loot;
                    n.hasLoot = true;
                    haveLoot++;
                    converted = true;
                } else if (haveEnemy < needEnemy && (pick == 1 || haveTerminal >= needTerminal)) {
                    n.nodeType = LibMissionStorage.NodeType.Combat;
                    n.hasEnemy = true;
                    haveEnemy++;
                    converted = true;
                } else if (haveTerminal < needTerminal) {
                    // Avoid double-counting if this was already a Terminal (pass 4 noop).
                    if (n.nodeType != LibMissionStorage.NodeType.Terminal) {
                        if (n.hasEnemy) { n.hasEnemy = false; haveEnemy--; }
                        n.nodeType = LibMissionStorage.NodeType.Terminal;
                        haveTerminal++;
                        converted = true;
                    }
                }

                if (converted) LibMissionStorage.setNode(nodes, i, n);
            }
        }

        // Silence unused-var warnings if strict; sessionId reserved for a
        // future event ("MapQuotaEnforced") that monitoring can subscribe to.
        sessionId;
    }

    function _generateNode(
        uint8 nodeIndex,
        uint8 mapSize,
        bytes32 entropy,
        LibMissionStorage.MissionVariantConfig storage config,
        uint8 combatNodesPlaced
    ) internal view returns (LibMissionStorage.MapNode memory node, uint8 newCombatCount) {
        uint256 nodeEntropy = uint256(keccak256(abi.encodePacked(entropy, nodeIndex)));
        newCombatCount = combatNodesPlaced;

        LibMissionStorage.NodeType nodeType;
        bool hasLoot = false;
        bool hasEnemy = false;

        if (nodeIndex == 0) {
            nodeType = LibMissionStorage.NodeType.Empty;
        } else if (nodeIndex == mapSize - 1) {
            nodeType = LibMissionStorage.NodeType.Exit;
        } else if (combatNodesPlaced < config.minCombatNodes) {
            nodeType = LibMissionStorage.NodeType.Combat;
            hasEnemy = true;
            newCombatCount++;
        } else {
            (nodeType, hasLoot, hasEnemy, newCombatCount) = _determineNodeType(
                nodeEntropy, config, combatNodesPlaced
            );
        }

        // Calculate connections
        uint8 connections = 0;
        if (nodeIndex > 0) connections |= 1;
        if (nodeIndex < mapSize - 1) connections |= 2;
        if (nodeIndex > 1 && (nodeEntropy % 4 == 0)) connections |= 4;

        node = LibMissionStorage.MapNode({
            nodeId: nodeIndex,
            nodeType: nodeType,
            difficulty: uint8((nodeEntropy >> 8) % 10) + 1,
            discovered: nodeIndex == 0,
            completed: false,
            hasLoot: hasLoot,
            hasEnemy: hasEnemy,
            connectedNodesMask: connections
        });
    }

    function _determineNodeType(
        uint256 nodeEntropy,
        LibMissionStorage.MissionVariantConfig storage config,
        uint8 combatNodesPlaced
    ) internal view returns (
        LibMissionStorage.NodeType nodeType,
        bool hasLoot,
        bool hasEnemy,
        uint8 newCombatCount
    ) {
        newCombatCount = combatNodesPlaced;
        uint8 roll = uint8(nodeEntropy % 100);

        if (roll < config.lootNodeChance) {
            nodeType = LibMissionStorage.NodeType.Loot;
            hasLoot = true;
        } else if (roll < config.lootNodeChance + 20 && combatNodesPlaced < config.maxCombatNodes) {
            nodeType = LibMissionStorage.NodeType.Combat;
            hasEnemy = true;
            newCombatCount++;
        } else if (roll < config.lootNodeChance + 30) {
            nodeType = LibMissionStorage.NodeType.Terminal;
        } else if (roll < config.lootNodeChance + 35) {
            nodeType = LibMissionStorage.NodeType.Secret;
        } else if (roll < config.lootNodeChance + 45) {
            nodeType = LibMissionStorage.NodeType.Event;
        } else {
            nodeType = LibMissionStorage.NodeType.Empty;
        }
    }

    // ============================================================
    // INTERNAL FUNCTIONS - OBJECTIVES
    // ============================================================

    function _generateObjectives(
        bytes32 sessionId,
        bytes32 entropy,
        LibMissionStorage.MissionVariantConfig storage config
    ) internal {
        LibMissionStorage.MissionStorage storage ms = LibMissionStorage.missionStorage();
        LibMissionStorage.PackedObjectives storage objectives = ms.sessionObjectives[sessionId];

        // If templates are configured, use template-based generation
        if (config.objectiveTemplateCount > 0) {
            _generateObjectivesFromTemplates(sessionId, entropy, config, objectives);
            return;
        }

        // Legacy generation (backward compatibility)
        uint8 totalObjectives = config.requiredObjectivesCount + config.bonusObjectivesCount;

        for (uint8 i = 0; i < totalObjectives; i++) {
            uint256 objEntropy = uint256(keccak256(abi.encodePacked(entropy, "obj", i)));

            // Determine objective type
            LibMissionStorage.ObjectiveType objType = LibMissionStorage.ObjectiveType(objEntropy % 7);

            // Calculate target based on type
            uint8 target;
            if (objType == LibMissionStorage.ObjectiveType.Collect) {
                target = uint8((objEntropy >> 8) % 5) + 3; // 3-7 items
            } else if (objType == LibMissionStorage.ObjectiveType.Defeat) {
                target = uint8((objEntropy >> 8) % 3) + 2; // 2-4 combats
            } else if (objType == LibMissionStorage.ObjectiveType.Hack) {
                target = uint8((objEntropy >> 8) % 2) + 1; // 1-2 hacks
            } else {
                target = 1; // Single action for others
            }

            // Bonus reward for bonus objectives
            uint16 bonusReward = i >= config.requiredObjectivesCount ?
                uint16((objEntropy >> 16) % 500) + 100 : // 100-600 basis points
                0;

            LibMissionStorage.MissionObjective memory obj = LibMissionStorage.MissionObjective({
                objectiveId: i,
                objectiveType: objType,
                targetAmount: target,
                currentProgress: 0,
                isRequired: i < config.requiredObjectivesCount,
                isCompleted: false,
                bonusRewardPercent: bonusReward
            });

            LibMissionStorage.setObjective(objectives, i, obj);
        }
    }

    /**
     * @notice Generate objectives from configured templates
     * @dev Uses ObjectiveTemplate array to create mission objectives with randomized targets
     */
    function _generateObjectivesFromTemplates(
        bytes32 sessionId,
        bytes32 entropy,
        LibMissionStorage.MissionVariantConfig storage config,
        LibMissionStorage.PackedObjectives storage objectives
    ) internal {
        uint8 objectiveIndex = 0;

        for (uint8 i = 0; i < config.objectiveTemplateCount && objectiveIndex < LibMissionStorage.MAX_OBJECTIVES; i++) {
            LibMissionStorage.ObjectiveTemplate storage template = config.objectiveTemplates[i];

            // Skip disabled templates
            if (!template.enabled) continue;

            uint256 objEntropy = uint256(keccak256(abi.encodePacked(entropy, "obj_tmpl", i)));

            // Randomize target within configured range
            uint8 target = template.minTarget;
            if (template.maxTarget > template.minTarget) {
                target += uint8(objEntropy % (template.maxTarget - template.minTarget + 1));
            }

            LibMissionStorage.MissionObjective memory obj = LibMissionStorage.MissionObjective({
                objectiveId: objectiveIndex,
                objectiveType: template.objectiveType,
                targetAmount: target,
                currentProgress: 0,
                isRequired: template.isRequired,
                isCompleted: false,
                bonusRewardPercent: template.bonusRewardBps
            });

            LibMissionStorage.setObjective(objectives, objectiveIndex, obj);
            objectiveIndex++;
        }
    }

    /**
     * @notice Mark Survive/Time objectives complete based on session-final
     * state and emit MissionObjectiveCompleted for each one.
     * @dev Called from extractMission BEFORE rewards calculation so
     * _calculateFinalRewards / performance rating reflect the freshly-
     * marked objectives. _checkAllRequiredObjectivesComplete (the gate
     * that flipped Activeâ†’ReadyToComplete) accepts these via live check,
     * so by the time we reach extract the conditions are guaranteed â€”
     * but the on-chain `isCompleted` flag still needs to be set for
     * downstream readers (UI, rewards, perfect-completion check).
     */
    function _completeTerminalObjectives(bytes32 sessionId) internal {
        LibMissionStorage.MissionStorage storage ms = LibMissionStorage.missionStorage();
        LibMissionStorage.PackedMissionState storage state = ms.packedStates[sessionId];
        LibMissionStorage.PackedObjectives storage objectives = ms.sessionObjectives[sessionId];

        LibMissionStorage.MissionVariantConfig storage config = ms.variantConfigs[state.passCollectionId][state.missionVariant];
        uint8 totalObjectives = config.requiredObjectivesCount + config.bonusObjectivesCount;

        for (uint8 i = 0; i < totalObjectives; i++) {
            LibMissionStorage.MissionObjective memory obj = LibMissionStorage.getObjective(objectives, i);
            if (obj.isCompleted) continue;

            bool shouldComplete = false;
            if (obj.objectiveType == LibMissionStorage.ObjectiveType.Survive) {
                shouldComplete = (state.combatsLost == 0);
            } else if (obj.objectiveType == LibMissionStorage.ObjectiveType.Time) {
                uint256 elapsed = uint256(state.lastActionBlock) > uint256(state.revealBlock)
                    ? uint256(state.lastActionBlock) - uint256(state.revealBlock)
                    : 0;
                shouldComplete = (elapsed <= uint256(obj.targetAmount));
            }

            if (shouldComplete) {
                obj.currentProgress = obj.targetAmount;
                obj.isCompleted = true;
                LibMissionStorage.setObjective(objectives, i, obj);
                emit MissionObjectiveCompleted(sessionId, i);
            }
        }
    }

    function _checkAllRequiredObjectivesComplete(bytes32 sessionId) internal view returns (bool) {
        LibMissionStorage.MissionStorage storage ms = LibMissionStorage.missionStorage();
        LibMissionStorage.PackedMissionState storage state = ms.packedStates[sessionId];
        LibMissionStorage.PackedObjectives storage objectives = ms.sessionObjectives[sessionId];

        uint8 requiredCount = ms.variantConfigs[state.passCollectionId][state.missionVariant].requiredObjectivesCount;

        for (uint8 i = 0; i < requiredCount; i++) {
            LibMissionStorage.MissionObjective memory obj = LibMissionStorage.getObjective(objectives, i);
            if (obj.isCompleted) continue;
            // Live check for terminal objectives â€” Survive/Time can satisfy
            // the gate even before they are formally marked completed
            // (the formal mark + event happens in _completeTerminalObjectives
            // at extractMission time). Without this, phase would never flip
            // to ReadyToComplete on missions that include Survive/Time as
            // required, so extractMission could never be called.
            if (obj.objectiveType == LibMissionStorage.ObjectiveType.Survive) {
                if (state.combatsLost == 0) continue;
                return false;
            }
            if (obj.objectiveType == LibMissionStorage.ObjectiveType.Time) {
                // Player must complete within obj.targetAmount blocks of the
                // reveal block (when actual gameplay starts). targetAmount is
                // a direct block budget â€” admin sets meaningful values per
                // variant via objective templates.
                uint256 elapsed = uint256(state.lastActionBlock) > uint256(state.revealBlock)
                    ? uint256(state.lastActionBlock) - uint256(state.revealBlock)
                    : 0;
                if (elapsed <= uint256(obj.targetAmount)) continue;
                return false;
            }
            return false;
        }
        return true;
    }

    // ============================================================
    // INTERNAL FUNCTIONS - ACTION RESOLUTION
    // ============================================================

    function _resolveAction(
        bytes32 sessionId,
        LibMissionStorage.MissionAction calldata action
    ) internal returns (LibMissionStorage.ActionResult memory result) {
        LibMissionStorage.MissionStorage storage ms = LibMissionStorage.missionStorage();
        LibMissionStorage.PackedMissionState storage state = ms.packedStates[sessionId];
        LibMissionStorage.PackedParticipant storage participant = ms.sessionParticipants[sessionId][action.participantIndex];

        // Get charge cost for action
        uint8 chargeCost = _getActionChargeCost(action.actionType, action.combatStyle);

        // Check participant has enough charge
        if (participant.currentCharge < chargeCost) {
            result.success = false;
            return result;
        }

        // Consume charge
        _consumeActionCharge(participant, state, chargeCost);
        result.chargeUsed = chargeCost;

        // Process action based on type
        result = _executeAction(sessionId, action, state, participant);
        result.chargeUsed = chargeCost;

        // Check for random event trigger
        if (_shouldTriggerEvent(sessionId, state)) {
            // Derive the event ID from a per-action hash, NOT a fixed slice of
            // sessionEntropy. The old `(entropy >> 24) % 10` depended only on
            // the session seed, so every event a mission ever rolled was the
            // SAME id â€” players saw "disarm bomb" on repeat (Jerry 2026-05-30).
            // Mixing in `totalActions` (changes every action) re-rolls each
            // trigger across the full 1..10 pool, so consecutive events differ.
            result.triggeredEventId = uint8(
                uint256(keccak256(abi.encodePacked(ms.sessionEntropy[sessionId], state.totalActions, "eventId"))) % 10
            ) + 1;
        }

        // Update objective progress if applicable
        _updateObjectiveProgress(sessionId, action.actionType, result);
    }

    function _consumeActionCharge(
        LibMissionStorage.PackedParticipant storage participant,
        LibMissionStorage.PackedMissionState storage state,
        uint8 chargeCost
    ) internal {
        participant.currentCharge -= chargeCost;
        participant.actionsPerformed++;
        state.chargeUsed += chargeCost;

        // Update PowerMatrix in main storage
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        PowerMatrix storage charge = hs.performedCharges[uint256(participant.combinedId)];
        if (charge.currentCharge >= chargeCost) {
            charge.currentCharge -= uint128(chargeCost);
        }
    }

    function _executeAction(
        bytes32 sessionId,
        LibMissionStorage.MissionAction calldata action,
        LibMissionStorage.PackedMissionState storage state,
        LibMissionStorage.PackedParticipant storage participant
    ) internal returns (LibMissionStorage.ActionResult memory result) {
        LibMissionStorage.MissionStorage storage ms = LibMissionStorage.missionStorage();
        LibMissionStorage.PackedMapNodes storage nodes = ms.sessionMaps[sessionId];
        LibMissionStorage.MapNode memory currentNode = LibMissionStorage.getNode(nodes, state.currentNodeId);

        if (action.actionType == LibMissionStorage.MissionActionType.Move) {
            result = _processMoveAction(sessionId, action.targetNodeId, state, nodes, participant);
        } else if (action.actionType == LibMissionStorage.MissionActionType.Scan) {
            result = _processScanAction(sessionId, state, nodes);
        } else if (action.actionType == LibMissionStorage.MissionActionType.Loot) {
            result = _processLootAction(sessionId, state, currentNode);
        } else if (action.actionType == LibMissionStorage.MissionActionType.Combat) {
            result = _processCombatAction(sessionId, action.combatStyle, state, participant, currentNode);
        } else if (action.actionType == LibMissionStorage.MissionActionType.Stealth) {
            result = _processStealthAction(sessionId, state, currentNode);
        } else if (action.actionType == LibMissionStorage.MissionActionType.Hack) {
            result = _processHackAction(sessionId, state, currentNode);
        } else if (action.actionType == LibMissionStorage.MissionActionType.Rest) {
            result = _processRestAction(sessionId, state, participant);
        }
    }

    function _getActionChargeCost(
        LibMissionStorage.MissionActionType actionType,
        LibMissionStorage.CombatStyle combatStyle
    ) internal pure returns (uint8) {
        if (actionType == LibMissionStorage.MissionActionType.Move) {
            return LibMissionStorage.CHARGE_MOVE;
        } else if (actionType == LibMissionStorage.MissionActionType.Scan) {
            return LibMissionStorage.CHARGE_SCAN;
        } else if (actionType == LibMissionStorage.MissionActionType.Loot) {
            return LibMissionStorage.CHARGE_LOOT;
        } else if (actionType == LibMissionStorage.MissionActionType.Combat) {
            if (combatStyle == LibMissionStorage.CombatStyle.Aggressive) {
                return LibMissionStorage.CHARGE_COMBAT_AGGRESSIVE;
            } else if (combatStyle == LibMissionStorage.CombatStyle.Balanced) {
                return LibMissionStorage.CHARGE_COMBAT_BALANCED;
            } else {
                return LibMissionStorage.CHARGE_COMBAT_DEFENSIVE;
            }
        } else if (actionType == LibMissionStorage.MissionActionType.Stealth) {
            return LibMissionStorage.CHARGE_STEALTH;
        } else if (actionType == LibMissionStorage.MissionActionType.Hack) {
            return LibMissionStorage.CHARGE_HACK;
        } else if (actionType == LibMissionStorage.MissionActionType.Rest) {
            return 0; // Rest doesn't cost charge, it restores it
        }
        return 0;
    }

    function _processMoveAction(
        bytes32 sessionId,
        uint8 targetNodeId,
        LibMissionStorage.PackedMissionState storage state,
        LibMissionStorage.PackedMapNodes storage nodes,
        LibMissionStorage.PackedParticipant storage participant
    ) internal returns (LibMissionStorage.ActionResult memory result) {
        LibMissionStorage.MapNode memory targetNode = LibMissionStorage.getNode(nodes, targetNodeId);

        // Validate connection (simplified - allow adjacent moves)
        if (targetNodeId > state.currentNodeId + 2 || (targetNodeId < state.currentNodeId && state.currentNodeId > 0 && targetNodeId < state.currentNodeId - 1)) {
            result.success = false;
            return result;
        }

        // Capture fog state BEFORE we discover the tile below.
        bool wasFog = !targetNode.discovered;

        // B5: stepping blind into a hostile tile can spring an ambush. Only
        // fires on tiles that were never scanned (wasFog) and that hide an
        // enemy. Scan reveals current+1..+3 (sets discovered = true), so
        // scouting ahead defuses this â€” that is Scan's reason to exist.
        // The enemy is NOT cleared: the squad still has to fight or bypass it.
        if (wasFog && targetNode.hasEnemy) {
            LibMissionStorage.MissionStorage storage ms = LibMissionStorage.missionStorage();
            uint256 ambushRoll = uint256(
                keccak256(abi.encodePacked(ms.sessionEntropy[sessionId], "ambush", state.totalActions))
            ) % 100;
            if (ambushRoll < MOVE_AMBUSH_CHANCE) {
                participant.damageTaken += MOVE_AMBUSH_DAMAGE;
                if (participant.damageTaken > participant.initialCharge / 2) {
                    participant.status = 1; // Incapacitated
                }
                result.damageTaken = MOVE_AMBUSH_DAMAGE;
            }
        }

        // Move to target
        state.currentNodeId = targetNodeId;

        // Discover node â€” count toward Discover objective only if we just
        // un-fogged it. Subsequent moves through the same tile shouldn't
        // pay out Discover progress.
        if (wasFog) {
            result.newlyDiscoveredCount = 1;
        }
        targetNode.discovered = true;
        LibMissionStorage.setNode(nodes, targetNodeId, targetNode);

        result.success = true;
    }

    function _processScanAction(
        bytes32,
        LibMissionStorage.PackedMissionState storage state,
        LibMissionStorage.PackedMapNodes storage nodes
    ) internal returns (LibMissionStorage.ActionResult memory result) {
        LibMissionStorage.MissionStorage storage ms = LibMissionStorage.missionStorage();
        uint8 mapSize = ms.variantConfigs[state.passCollectionId][state.missionVariant].mapSize;

        // Discover surrounding nodes â€” track how many were genuinely revealed
        // (i.e. previously discovered=false) so Discover objective progress
        // reflects actual exploration value, not spam-scan farming on
        // already-mapped neighbours.
        //
        // Reveal radius: one tile BEHIND (closes the fog gap left by a +2 move
        // jump) plus THREE tiles AHEAD. The forward reach is the whole point of
        // the redesign (Jerry 2026-05-30): the map is linear and Move already
        // un-fogs its destination (max +2), so the old Â±1 Scan only revealed
        // current+1 â€” a tile Move would reveal anyway â€” making Scan dead weight
        // that just burned charge. Reaching current+3 lets Scan out-range Move,
        // so a player can spot an incoming Combat/Terminal/Loot node and plan
        // charge/rest/route before committing. That is the recon role Scan was
        // always priced for (CHARGE_SCAN = 5).
        uint8 newly = 0;
        uint8 current = state.currentNodeId;
        if (current > 0) {
            LibMissionStorage.MapNode memory prevNode = LibMissionStorage.getNode(nodes, current - 1);
            if (!prevNode.discovered) {
                newly++;
                prevNode.discovered = true;
                LibMissionStorage.setNode(nodes, current - 1, prevNode);
            }
        }
        for (uint8 d = 1; d <= 3; d++) {
            uint8 idx = current + d;
            if (idx >= mapSize) break;
            LibMissionStorage.MapNode memory ahead = LibMissionStorage.getNode(nodes, idx);
            if (!ahead.discovered) {
                newly++;
                ahead.discovered = true;
                LibMissionStorage.setNode(nodes, idx, ahead);
            }
        }

        result.newlyDiscoveredCount = newly;
        result.success = true;
    }

    function _processLootAction(
        bytes32 sessionId,
        LibMissionStorage.PackedMissionState storage state,
        LibMissionStorage.MapNode memory currentNode
    ) internal returns (LibMissionStorage.ActionResult memory result) {
        if (!currentNode.hasLoot) {
            result.success = false;
            return result;
        }

        LibMissionStorage.MissionStorage storage ms = LibMissionStorage.missionStorage();
        uint256 lootRoll = uint256(ms.sessionEntropy[sessionId]) >> 32;

        // Generate loot
        uint8 items = uint8((lootRoll % 3) + 1);
        state.dataFragments += uint16(items * 10);
        state.scrapMetal += uint16(items * 5);
        if (lootRoll % 10 == 0) {
            state.rareComponents++;
        }

        // Mark node as looted
        currentNode.hasLoot = false;
        LibMissionStorage.setNode(ms.sessionMaps[sessionId], state.currentNodeId, currentNode);

        result.success = true;
        result.itemsFound = items;
    }

    function _processCombatAction(
        bytes32 sessionId,
        LibMissionStorage.CombatStyle style,
        LibMissionStorage.PackedMissionState storage state,
        LibMissionStorage.PackedParticipant storage participant,
        LibMissionStorage.MapNode memory currentNode
    ) internal returns (LibMissionStorage.ActionResult memory result) {
        if (!currentNode.hasEnemy) {
            result.success = false;
            return result;
        }

        LibMissionStorage.MissionStorage storage ms = LibMissionStorage.missionStorage();
        uint256 combatRoll = uint256(keccak256(abi.encodePacked(ms.sessionEntropy[sessionId], state.totalActions)));

        // Calculate combat outcome
        uint8 playerPower = _getPlayerPower(style);
        uint8 enemyPower = currentNode.difficulty * 5 + 20;
        bool victory = (combatRoll % 100) + playerPower > enemyPower + 25;

        if (victory) {
            _handleCombatVictory(ms, sessionId, state, participant, currentNode, playerPower, result);
        } else {
            _handleCombatDefeat(state, participant, enemyPower, result);
        }

        result.xpGained = 5;
        participant.xpEarned += 5;
    }

    function _getPlayerPower(LibMissionStorage.CombatStyle style) internal pure returns (uint8) {
        if (style == LibMissionStorage.CombatStyle.Aggressive) {
            return 80;
        } else if (style == LibMissionStorage.CombatStyle.Balanced) {
            return 65;
        }
        return 50;
    }

    function _handleCombatVictory(
        LibMissionStorage.MissionStorage storage ms,
        bytes32 sessionId,
        LibMissionStorage.PackedMissionState storage state,
        LibMissionStorage.PackedParticipant storage participant,
        LibMissionStorage.MapNode memory currentNode,
        uint8 playerPower,
        LibMissionStorage.ActionResult memory result
    ) internal {
        state.combatsWon++;
        result.success = true;
        result.damageDealt = uint16(playerPower);
        participant.damageDealt += uint16(playerPower);

        // Clear enemy from node
        currentNode.hasEnemy = false;
        currentNode.completed = true;
        LibMissionStorage.setNode(ms.sessionMaps[sessionId], state.currentNodeId, currentNode);
    }

    function _handleCombatDefeat(
        LibMissionStorage.PackedMissionState storage state,
        LibMissionStorage.PackedParticipant storage participant,
        uint8 enemyPower,
        LibMissionStorage.ActionResult memory result
    ) internal {
        state.combatsLost++;
        result.success = false;
        uint16 damage = uint16(enemyPower / 2);
        result.damageTaken = damage;
        participant.damageTaken += damage;

        // Check if participant incapacitated
        if (participant.damageTaken > participant.initialCharge / 2) {
            participant.status = 1; // Incapacitated
        }
    }

    function _processStealthAction(
        bytes32 sessionId,
        LibMissionStorage.PackedMissionState storage state,
        LibMissionStorage.MapNode memory currentNode
    ) internal returns (LibMissionStorage.ActionResult memory result) {
        LibMissionStorage.MissionStorage storage ms = LibMissionStorage.missionStorage();
        uint256 stealthRoll = uint256(keccak256(abi.encodePacked(ms.sessionEntropy[sessionId], "stealth", state.totalActions)));

        // Stealth success based on difficulty.
        // 2026-05 upgrade: lowered multiplier 8 â†’ 6 to soften the curve.
        // Pre-fix: difficulty 1 = 91% / difficulty 10 = 19% â€” the high-end
        // 19% turned high-difficulty maps into stealth-grinding loops.
        // Post-fix: difficulty 1 = 93% / difficulty 5 = 70% / difficulty 10 = 40%.
        // High difficulty stays meaningfully harder, but Stealth-required
        // missions (Variant 1/3/4 Pass Collection 5) stop being ragequit
        // material on bad-roll maps.
        bool success = (stealthRoll % 100) > (currentNode.difficulty * 6);

        if (success) {
            state.stealthSuccesses++;
            result.success = true;

            // If enemy present, bypass it. Clear `hasEnemy` so the node ends
            // in a coherent (completed=true, hasEnemy=false) terminal state.
            // Pre-fix this only set `completed` and left `hasEnemy=true`,
            // which made downstream consumers disagree: `MapNode.tsx` hid
            // the enemy icon (checked both flags) but the tooltip in
            // `MissionMapView` showed "Enemy present" (checked only
            // `hasEnemy`), and `_processCombatAction` would still proceed
            // on the now-bypassed node. Mirror `_handleCombatVictory`
            // (lines 1969-1972) which always clears both.
            if (currentNode.hasEnemy) {
                currentNode.hasEnemy = false;
                currentNode.completed = true;
                LibMissionStorage.setNode(ms.sessionMaps[sessionId], state.currentNodeId, currentNode);
            }
        } else {
            result.success = false;
        }
    }

    function _processHackAction(
        bytes32 sessionId,
        LibMissionStorage.PackedMissionState storage state,
        LibMissionStorage.MapNode memory currentNode
    ) internal returns (LibMissionStorage.ActionResult memory result) {
        if (currentNode.nodeType != LibMissionStorage.NodeType.Terminal) {
            result.success = false;
            return result;
        }

        LibMissionStorage.MissionStorage storage ms = LibMissionStorage.missionStorage();
        uint256 hackRoll = uint256(keccak256(abi.encodePacked(ms.sessionEntropy[sessionId], "hack", state.totalActions)));

        bool success = (hackRoll % 100) > (currentNode.difficulty * 6);

        if (success) {
            state.hacksCompleted++;
            result.success = true;

            // Grant data fragments
            state.dataFragments += uint16(currentNode.difficulty * 5);

            // Mark terminal as hacked
            currentNode.completed = true;
            LibMissionStorage.setNode(ms.sessionMaps[sessionId], state.currentNodeId, currentNode);
        } else {
            result.success = false;
        }
    }

    /**
     * @notice Process Rest action - restore charge to a participant
     * @dev Limited uses per mission, configurable via variant config
     * @param sessionId Mission session ID
     * @param state Packed mission state
     * @param participant Participant performing the rest action
     * @return result Action result with success status
     */
    function _processRestAction(
        bytes32 sessionId,
        LibMissionStorage.PackedMissionState storage state,
        LibMissionStorage.PackedParticipant storage participant
    ) internal returns (LibMissionStorage.ActionResult memory result) {
        LibMissionStorage.MissionStorage storage ms = LibMissionStorage.missionStorage();
        LibMissionStorage.MissionVariantConfig storage config = ms.variantConfigs[state.passCollectionId][state.missionVariant];

        // Check if Rest is enabled for this variant
        if (config.maxRestUsesPerMission == 0) {
            result.success = false;
            return result;
        }

        // Track rest uses in flags (bits 4-7 for rest counter)
        uint8 restUsed = (state.flags >> 4) & 0x0F;
        if (restUsed >= config.maxRestUsesPerMission) {
            result.success = false;
            return result;
        }

        // Calculate charge to restore
        uint8 restoreAmount = config.restChargeRestore > 0
            ? config.restChargeRestore
            : LibMissionStorage.CHARGE_REST_DEFAULT;

        // Restore charge (capped at initial charge)
        uint32 newCharge = participant.currentCharge + restoreAmount;
        if (newCharge > participant.initialCharge) {
            newCharge = participant.initialCharge;
        }
        uint8 actualRestored = uint8(newCharge - participant.currentCharge);
        participant.currentCharge = newCharge;

        // Also update PowerMatrix in main storage
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        PowerMatrix storage charge = hs.performedCharges[uint256(participant.combinedId)];
        uint256 newPowerCharge = uint256(charge.currentCharge) + uint256(actualRestored);
        if (newPowerCharge > uint256(charge.maxCharge)) {
            newPowerCharge = uint256(charge.maxCharge);
        }
        charge.currentCharge = uint128(newPowerCharge);

        // Increment rest counter in flags
        state.flags = (state.flags & 0x0F) | ((restUsed + 1) << 4);

        result.success = true;
        result.chargeUsed = 0; // Rest doesn't consume charge
    }

    function _shouldTriggerEvent(
        bytes32 sessionId,
        LibMissionStorage.PackedMissionState storage state
    ) internal view returns (bool) {
        LibMissionStorage.MissionStorage storage ms = LibMissionStorage.missionStorage();
        LibMissionStorage.MissionVariantConfig storage config = ms.variantConfigs[state.passCollectionId][state.missionVariant];

        if (config.eventFrequency == 0) return false;
        if (state.eventsTriggered >= config.eventFrequency) return false;

        uint256 roll = uint256(keccak256(abi.encodePacked(ms.sessionEntropy[sessionId], state.totalActions, "event")));
        return (roll % 100) < (config.eventFrequency * 10);
    }

    function _updateObjectiveProgress(
        bytes32 sessionId,
        LibMissionStorage.MissionActionType actionType,
        LibMissionStorage.ActionResult memory result
    ) internal {
        if (!result.success) return;

        LibMissionStorage.MissionStorage storage ms = LibMissionStorage.missionStorage();
        LibMissionStorage.PackedMissionState storage state = ms.packedStates[sessionId];
        LibMissionStorage.PackedObjectives storage objectives = ms.sessionObjectives[sessionId];

        uint8 totalObjectives = ms.variantConfigs[state.passCollectionId][state.missionVariant].requiredObjectivesCount +
                               ms.variantConfigs[state.passCollectionId][state.missionVariant].bonusObjectivesCount;

        // Discover progresses by however many fog tiles this single action
        // un-fogged (1 for Move into fog, 0-2 for Scan). Computed once per
        // action, applied to every Discover objective in the loop below.
        bool isDiscoverAction =
            actionType == LibMissionStorage.MissionActionType.Move
            || actionType == LibMissionStorage.MissionActionType.Scan;
        uint8 discoverDelta = isDiscoverAction ? result.newlyDiscoveredCount : 0;

        for (uint8 i = 0; i < totalObjectives; i++) {
            LibMissionStorage.MissionObjective memory obj = LibMissionStorage.getObjective(objectives, i);
            if (obj.isCompleted) continue;

            // Per-action progress amount. Default 1 (one action = one tick)
            // for the existing handlers; Discover deviates because a single
            // Scan can reveal up to 2 tiles. Survive/Time are handled in
            // _completeTerminalObjectives, not here.
            uint8 delta = 0;

            if (obj.objectiveType == LibMissionStorage.ObjectiveType.Collect && actionType == LibMissionStorage.MissionActionType.Loot) {
                delta = 1;
            } else if (obj.objectiveType == LibMissionStorage.ObjectiveType.Defeat && actionType == LibMissionStorage.MissionActionType.Combat) {
                delta = 1;
            } else if (obj.objectiveType == LibMissionStorage.ObjectiveType.Hack && actionType == LibMissionStorage.MissionActionType.Hack) {
                delta = 1;
            } else if (obj.objectiveType == LibMissionStorage.ObjectiveType.Stealth && actionType == LibMissionStorage.MissionActionType.Stealth) {
                delta = 1;
            } else if (obj.objectiveType == LibMissionStorage.ObjectiveType.Discover && discoverDelta > 0) {
                delta = discoverDelta;
            }

            if (delta > 0) {
                bool completed = LibMissionStorage.updateObjectiveProgress(objectives, i, delta);
                if (completed) {
                    emit MissionObjectiveCompleted(sessionId, i);
                }
            }
        }
    }

    // ============================================================
    // INTERNAL FUNCTIONS - EVENT RESOLUTION
    // ============================================================

    function _resolveEvent(
        bytes32 sessionId,
        uint8 eventId,
        LibMissionStorage.EventResponse response
    ) internal returns (LibMissionStorage.EventOutcome memory outcome) {
        LibMissionStorage.MissionStorage storage ms = LibMissionStorage.missionStorage();
        LibMissionStorage.EventType eventType = LibMissionStorage.EventType(eventId % 6);

        uint256 roll = uint256(keccak256(abi.encodePacked(ms.sessionEntropy[sessionId], eventId, response)));
        uint8 successChance = 50;
        uint16 failDamage = EVENT_DMG_DEFAULT;

        // Success chance AND failure damage vary by event type and response, so
        // picking the right response (and the roll) actually matters.
        if (eventType == LibMissionStorage.EventType.Patrol) {
            if (response == LibMissionStorage.EventResponse.Hide) successChance = 70;
            else if (response == LibMissionStorage.EventResponse.Flee) successChance = 60;
            else if (response == LibMissionStorage.EventResponse.Fight) successChance = 45;
            failDamage = EVENT_DMG_PATROL;
        } else if (eventType == LibMissionStorage.EventType.Trap) {
            // Disarm is the skilled play; fleeing a live trap is riskier.
            if (response == LibMissionStorage.EventResponse.Disarm) successChance = 60;
            else if (response == LibMissionStorage.EventResponse.Flee) successChance = 40;
            failDamage = EVENT_DMG_TRAP;
        } else if (eventType == LibMissionStorage.EventType.Ambush) {
            // Forced fight â€” no safe response, real teeth on failure.
            successChance = 50;
            failDamage = EVENT_DMG_AMBUSH;
        } else if (eventType == LibMissionStorage.EventType.Discovery) {
            successChance = 90; // Almost always good
        } else if (eventType == LibMissionStorage.EventType.Ally) {
            // Decline is the safe out (no reward, no risk); engaging can pay more.
            if (response == LibMissionStorage.EventResponse.Decline) successChance = 100;
            else if (response == LibMissionStorage.EventResponse.Accept) successChance = 80;
            else if (response == LibMissionStorage.EventResponse.Negotiate) successChance = 60;
        } else if (eventType == LibMissionStorage.EventType.Environmental) {
            if (response == LibMissionStorage.EventResponse.Hide) successChance = 65;
            else if (response == LibMissionStorage.EventResponse.Flee) successChance = 55;
            failDamage = EVENT_DMG_ENVIRONMENTAL;
        }

        outcome.success = (roll % 100) < successChance;

        if (outcome.success) {
            // Reward scales with event type: Discovery pays most, Ally pays for
            // engaging (not Declining), evading a Patrol/hazard pays a small
            // consolation so working the event loop beats ignoring it. Trap /
            // Ambush success pays nothing â€” you simply avoided the harm.
            if (eventType == LibMissionStorage.EventType.Discovery) {
                ms.packedStates[sessionId].secretsFound++;
                outcome.rewardBonus = EVENT_REWARD_FRAGMENTS * 2;
            } else if (eventType == LibMissionStorage.EventType.Ally) {
                if (response != LibMissionStorage.EventResponse.Decline) {
                    outcome.rewardBonus = EVENT_REWARD_FRAGMENTS;
                }
            } else if (
                eventType == LibMissionStorage.EventType.Patrol ||
                eventType == LibMissionStorage.EventType.Environmental
            ) {
                outcome.rewardBonus = EVENT_REWARD_FRAGMENTS / 2;
            }

            if (outcome.rewardBonus > 0) {
                ms.packedStates[sessionId].dataFragments += outcome.rewardBonus;
            }
        } else {
            outcome.damageTaken = failDamage;
        }
    }

    // ============================================================
    // INTERNAL FUNCTIONS - REWARDS CALCULATION
    // ============================================================

    function _calculateFinalRewards(bytes32 sessionId)
        internal
        view
        returns (LibMissionStorage.MissionResult memory result)
    {
        LibMissionStorage.MissionStorage storage ms = LibMissionStorage.missionStorage();
        LibMissionStorage.PackedMissionState storage state = ms.packedStates[sessionId];
        LibMissionStorage.MissionVariantConfig storage config = ms.variantConfigs[state.passCollectionId][state.missionVariant];

        uint256 reward = _calculateBaseReward(ms, sessionId, config);
        reward = _applyBonuses(ms, sessionId, config, reward);

        // Performance rating (0-100)
        uint8 performanceRating = _calculatePerformanceRating(sessionId);
        reward = (reward * performanceRating) / 100;

        // Perfect completion bonus
        if (state.combatsLost == 0 && state.eventsFailed == 0 && performanceRating == 100) {
            reward += (config.baseReward * config.perfectCompletionBonus) / 10000;
        }

        result.totalReward = reward;
        result.performanceRating = performanceRating;
        result.dataFragmentsEarned = state.dataFragments;
        result.scrapMetalEarned = state.scrapMetal;
        result.rareComponentsEarned = state.rareComponents;
        result.success = true;
    }

    function _calculateBaseReward(
        LibMissionStorage.MissionStorage storage ms,
        bytes32 sessionId,
        LibMissionStorage.MissionVariantConfig storage config
    ) internal view returns (uint256 reward) {
        reward = config.baseReward;

        // Difficulty multiplier
        reward = (reward * config.difficultyMultiplier) / 10000;

        // B6 â€” engagement bonus: reward squads that actually fight. Combat
        // costs charge and a loss dents the performance rating, so this is a
        // genuine risk/reward (not free money), and the cap keeps it from
        // dominating. Stops "do only the required fights, then stop" from
        // being strictly optimal.
        uint256 combatBonusBp = uint256(ms.packedStates[sessionId].combatsWon) * COMBAT_WIN_BONUS_BP;
        if (combatBonusBp > COMBAT_WIN_BONUS_CAP_BP) {
            combatBonusBp = COMBAT_WIN_BONUS_CAP_BP;
        }
        if (combatBonusBp > 0) {
            reward += (config.baseReward * combatBonusBp) / 10000;
        }

        // Bonus objectives
        LibMissionStorage.PackedObjectives storage objectives = ms.sessionObjectives[sessionId];
        uint8 totalObjectives = config.requiredObjectivesCount + config.bonusObjectivesCount;

        for (uint8 i = config.requiredObjectivesCount; i < totalObjectives; i++) {
            LibMissionStorage.MissionObjective memory obj = LibMissionStorage.getObjective(objectives, i);
            if (obj.isCompleted) {
                reward += (config.baseReward * obj.bonusRewardPercent) / 10000;
            }
        }
    }

    function _applyBonuses(
        LibMissionStorage.MissionStorage storage ms,
        bytes32 sessionId,
        LibMissionStorage.MissionVariantConfig storage config,
        uint256 reward
    ) internal view returns (uint256) {
        // Multi-participant bonus
        uint256 participantCount = ms.sessionParticipants[sessionId].length;
        if (participantCount > 1) {
            reward += (config.baseReward * config.multiParticipantBonus * (participantCount - 1)) / 10000;
        }

        // Colony bonus - check if all participants are in same colony
        if (_allInSameColony(sessionId)) {
            reward += (config.baseReward * config.colonyBonus) / 10000;
        }

        // Streak bonus
        address initiator = ms.sessionInitiators[sessionId];
        LibMissionStorage.UserMissionProfile storage profile = ms.userProfiles[initiator];
        uint256 streakBonus = (config.baseReward * config.streakBonusPerDay * profile.currentStreak) / 10000;
        uint256 maxStreak = (config.baseReward * config.maxStreakBonus) / 10000;
        if (streakBonus > maxStreak) {
            streakBonus = maxStreak;
        }
        reward += streakBonus;

        // Weekend bonus
        if (_isWeekend()) {
            reward += (config.baseReward * config.weekendBonus) / 10000;
        }

        return reward;
    }

    function _allInSameColony(bytes32 sessionId) internal view returns (bool) {
        LibMissionStorage.MissionStorage storage ms = LibMissionStorage.missionStorage();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        LibMissionStorage.PackedParticipant[] storage participants = ms.sessionParticipants[sessionId];

        if (participants.length <= 1) return false;

        bytes32 firstColony = hs.specimenColonies[uint256(participants[0].combinedId)];
        if (firstColony == bytes32(0)) return false;

        for (uint256 i = 1; i < participants.length; i++) {
            bytes32 colony = hs.specimenColonies[uint256(participants[i].combinedId)];
            if (colony != firstColony) return false;
        }

        return true;
    }

    function _isWeekend() internal view returns (bool) {
        // 0 = Thursday (Unix epoch), so (days + 4) % 7 gives: 0=Mon, 5=Sat, 6=Sun
        uint256 dayOfWeek = ((block.timestamp / 1 days) + 4) % 7;
        return dayOfWeek == 5 || dayOfWeek == 6;
    }

    function _calculatePerformanceRating(bytes32 sessionId) internal view returns (uint8) {
        LibMissionStorage.MissionStorage storage ms = LibMissionStorage.missionStorage();
        LibMissionStorage.PackedMissionState storage state = ms.packedStates[sessionId];
        LibMissionStorage.MissionVariantConfig storage config = ms.variantConfigs[state.passCollectionId][state.missionVariant];

        uint256 rating = 100;

        // Deduct for combat losses
        if (state.combatsLost > 0) {
            rating -= uint256(state.combatsLost) * 10;
        }

        // Deduct for failed events
        if (state.eventsFailed > 0) {
            rating -= uint256(state.eventsFailed) * 5;
        }

        // Bonus for efficiency (completing quickly)
        uint256 blocksUsed = state.lastActionBlock - state.startBlock;
        uint256 maxBlocks = config.maxDurationBlocks;
        if (blocksUsed < maxBlocks / 2) {
            rating += 10;
        }

        // Cap rating
        if (rating > 100) rating = 100;
        if (rating < 10) rating = 10;

        return uint8(rating);
    }

    // ============================================================
    // INTERNAL FUNCTIONS - CLEANUP
    // ============================================================

    function _cleanupSession(bytes32 sessionId) internal {
        LibMissionStorage.MissionStorage storage ms = LibMissionStorage.missionStorage();
        address initiator = ms.sessionInitiators[sessionId];

        // Clear user active mission
        delete ms.userActiveMission[initiator];
    }
}
