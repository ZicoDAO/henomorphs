// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibMeta} from "../../shared/libraries/LibMeta.sol";
import {LibColonyWarsStorage} from "../libraries/LibColonyWarsStorage.sol";
import {LibHenomorphsStorage} from "../libraries/LibHenomorphsStorage.sol";
import {AccessControlBase} from "../../common/facets/AccessControlBase.sol";
import {AccessHelper} from "../../staking/libraries/AccessHelper.sol";
import {WarfareHelper, TokenStats, IAccessoryFacet} from "../libraries/WarfareHelper.sol";
import {LibFeeCollection} from "../../staking/libraries/LibFeeCollection.sol";
import {LibAchievementTrigger} from "../libraries/LibAchievementTrigger.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @dev Cross-facet view used for the NAP treaty check (implemented in AllianceEvolutionFacet).
 */
interface ICAF_AllianceEvolution {
    function getActiveTreaty(bytes32 alliance1, bytes32 alliance2)
        external view returns (bool exists, uint8 treatyType, uint32 expiresAt);
}

/**
 * @title CoordinatedAttackFacet
 * @notice Self-contained implementation of alliance coordinated attacks.
 *
 * @dev WHY A DEDICATED FACET:
 *      The original coordinated-attack functions lived in AllianceEvolutionFacet and
 *      self-called ColonyWarsFacet.initiateAttack. That path was non-functional for
 *      several independent reasons (verified against source):
 *        - coordinatedAttackConfig.enabled had NO setter, so it was permanently false;
 *        - alliance task forces were never populated (no create path);
 *        - the internal self-call ran with LibMeta.msgSender() == calldata-tail garbage;
 *        - both the outer and inner functions were nonReentrant (guard would revert);
 *        - the outer code moved stake to the Diamond, but payouts pull from the treasury.
 *      Folding the logic into ColonyWarsFacet pushed it over the 24KB EIP-170 limit, so
 *      everything coordinated now lives here. Entrypoints and battle creation are in the
 *      SAME contract, so they call each other as plain internal functions and msgSender()
 *      resolves to the real leader throughout â€” no self-call, no garbage sender.
 *
 *      ASSET CONSENT MODEL: opt-in. The leader creates a task force with its own tokens;
 *      each member joins from ITS OWN transaction, committing its own tokens. Stake is
 *      funded entirely by the leader (matches the app UX). Battles are created one per
 *      participating colony and are resolvable by the existing ColonyWarsFacet.resolveBattle
 *      (battle state is shared Diamond storage).
 */
contract CoordinatedAttackFacet is AccessControlBase {

    // ===== Events =====
    event CoordinatedAttackInitiated(
        bytes32 indexed allianceId,
        bytes32 indexed targetColony,
        bytes32[] battleIds,
        uint8 participatingColonies
    );
    event AllianceTaskForceCreated(bytes32 indexed taskForceId, bytes32 indexed leaderColony, bytes32 indexed allianceId);
    event AllianceTaskForceJoined(bytes32 indexed taskForceId, bytes32 indexed memberColony);
    event AllianceTaskForceLeft(bytes32 indexed taskForceId, bytes32 indexed memberColony);
    event AllianceTaskForceDisbanded(bytes32 indexed taskForceId);
    event CoordinatedAttackConfigUpdated(bool enabled, uint8 minParticipants, uint8 maxParticipants);
    event CoordinatedBattleCreated(bytes32 indexed battleId, bytes32 indexed attackerColony, bytes32 indexed defenderColony, uint256 stake);

    // ===== Errors =====
    error AllianceNotEligible();
    error CoordinatedAttacksNotEnabled();
    error DailyCoordinatedAttackLimitReached(uint8 attacksToday, uint8 maxPerDay);
    error TooFewParticipants();
    error TooManyParticipants();
    error InsufficientStakeForCoordinatedAttack();
    error TaskForceNotActive();
    error NotColonyCreator();
    error NotTaskForceLeader();
    error ColonyNotRegistered();
    error AlreadyInTaskForce();
    error NotInTaskForce();
    error InvalidTaskForceName();
    error NotLeaderOwnedColony();
    error InvalidStake();
    error InvalidTokenCount();
    error WarfareNotStarted();
    error WarfareEnded();
    error TokenInActiveBattle();
    error CannotAttackOwnColony();
    error InvalidBattleState();
    error SeasonNotActive();
    error AttackOnCooldown();

    // ===== Modifiers =====
    modifier duringWarfarePeriod() {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibColonyWarsStorage.Season storage season = cws.seasons[cws.currentSeason];
        if (block.timestamp < season.registrationEnd) revert WarfareNotStarted();
        if (block.timestamp > season.warfareEnd) revert WarfareEnded();
        _;
    }

    // ============================================================
    // ADMIN
    // ============================================================

    /**
     * @notice Configure (and enable) coordinated attacks. Owner/operator only.
     * @dev This is the on-chain switch the feature was always missing.
     */
    function setCoordinatedAttackConfig(
        bool enabled,
        uint8 minParticipants,
        uint8 maxParticipants,
        uint8 maxCoordinatedAttacksPerDay,
        uint256 minStakePerParticipant,
        uint8 bonusDamagePercent
    ) external onlyAuthorized {
        LibColonyWarsStorage.requireInitialized();
        LibColonyWarsStorage.colonyWarsStorage().coordinatedAttackConfig =
            LibColonyWarsStorage.CoordinatedAttackConfig({
                enabled: enabled,
                minParticipants: minParticipants,
                maxParticipants: maxParticipants,
                maxCoordinatedAttacksPerDay: maxCoordinatedAttacksPerDay,
                minStakePerParticipant: minStakePerParticipant,
                bonusDamagePercent: bonusDamagePercent
            });
        emit CoordinatedAttackConfigUpdated(enabled, minParticipants, maxParticipants);
    }

    function getCoordinatedAttackConfig()
        external
        view
        returns (bool enabled, uint8 minParticipants, uint8 maxParticipants, uint8 maxCoordinatedAttacksPerDay, uint256 minStakePerParticipant, uint8 bonusDamagePercent)
    {
        LibColonyWarsStorage.CoordinatedAttackConfig storage c =
            LibColonyWarsStorage.colonyWarsStorage().coordinatedAttackConfig;
        return (c.enabled, c.minParticipants, c.maxParticipants, c.maxCoordinatedAttacksPerDay, c.minStakePerParticipant, c.bonusDamagePercent);
    }

    // ============================================================
    // OPT-IN ALLIANCE TASK FORCE LIFECYCLE
    // ============================================================

    /**
     * @notice Leader creates an alliance task force seeded with its own tokens.
     */
    function createAllianceTaskForce(
        bytes32 leaderColony,
        string calldata name,
        uint256[] calldata collectionIds,
        uint256[] calldata tokenIds
    ) external whenNotPaused nonReentrant returns (bytes32 taskForceId) {
        LibColonyWarsStorage.requireInitialized();
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();

        address user = LibMeta.msgSender();
        if (hs.colonyCreators[leaderColony] != user) revert NotColonyCreator();
        if (LibColonyWarsStorage.getUserAllianceId(user) == bytes32(0)) revert AllianceNotEligible();
        if (bytes(name).length == 0 || bytes(name).length > 32) revert InvalidTaskForceName();

        _requireRegistered(cws, leaderColony);
        _requireValidColonyTokens(hs, leaderColony, collectionIds, tokenIds);

        cws.allianceTaskForceCounter++;
        taskForceId = keccak256(abi.encodePacked("alliance-tf", leaderColony, cws.currentSeason, cws.allianceTaskForceCounter, block.timestamp));

        LibColonyWarsStorage.ColonyTaskForce storage tf = cws.allianceTaskForces[taskForceId];
        tf.leaderColonyId = leaderColony;
        tf.seasonId = cws.currentSeason;
        tf.name = name;
        tf.createdAt = uint32(block.timestamp);
        tf.isActive = true;

        cws.taskForceColonyCollections[taskForceId][leaderColony] = collectionIds;
        cws.taskForceColonyTokens[taskForceId][leaderColony] = tokenIds;
        cws.colonyAllianceTaskForces[leaderColony][cws.currentSeason].push(taskForceId);

        emit AllianceTaskForceCreated(taskForceId, leaderColony, LibColonyWarsStorage.getUserAllianceId(user));
    }

    /**
     * @notice Member opts into an alliance task force with its OWN tokens (own tx = consent).
     */
    function joinAllianceTaskForce(
        bytes32 taskForceId,
        bytes32 memberColony,
        uint256[] calldata collectionIds,
        uint256[] calldata tokenIds
    ) external whenNotPaused nonReentrant {
        LibColonyWarsStorage.requireInitialized();
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();

        address user = LibMeta.msgSender();
        if (hs.colonyCreators[memberColony] != user) revert NotColonyCreator();

        LibColonyWarsStorage.ColonyTaskForce storage tf = cws.allianceTaskForces[taskForceId];
        if (!tf.isActive) revert TaskForceNotActive();
        if (memberColony == tf.leaderColonyId) revert AlreadyInTaskForce();

        // Member must share the leader's alliance.
        bytes32 leaderAlliance = LibColonyWarsStorage.getUserAllianceId(hs.colonyCreators[tf.leaderColonyId]);
        if (leaderAlliance == bytes32(0) || LibColonyWarsStorage.getUserAllianceId(user) != leaderAlliance) {
            revert AllianceNotEligible();
        }

        uint256 memberCount = tf.memberColonyIds.length;
        for (uint256 i; i < memberCount; i++) {
            if (tf.memberColonyIds[i] == memberColony) revert AlreadyInTaskForce();
        }

        // Cap participants (leader + existing members + this new one) at maxParticipants.
        uint8 maxP = cws.coordinatedAttackConfig.maxParticipants;
        if (maxP != 0 && uint256(memberCount) + 2 > maxP) revert TooManyParticipants();

        _requireRegistered(cws, memberColony);
        _requireValidColonyTokens(hs, memberColony, collectionIds, tokenIds);

        tf.memberColonyIds.push(memberColony);
        cws.taskForceColonyCollections[taskForceId][memberColony] = collectionIds;
        cws.taskForceColonyTokens[taskForceId][memberColony] = tokenIds;

        emit AllianceTaskForceJoined(taskForceId, memberColony);
    }

    /**
     * @notice Member leaves a task force before the attack (frees its tokens from the squad).
     */
    function leaveAllianceTaskForce(bytes32 taskForceId, bytes32 memberColony)
        external whenNotPaused nonReentrant
    {
        LibColonyWarsStorage.requireInitialized();
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();

        if (hs.colonyCreators[memberColony] != LibMeta.msgSender()) revert NotColonyCreator();

        LibColonyWarsStorage.ColonyTaskForce storage tf = cws.allianceTaskForces[taskForceId];
        if (!tf.isActive) revert TaskForceNotActive();

        uint256 n = tf.memberColonyIds.length;
        bool found;
        for (uint256 i; i < n; i++) {
            if (tf.memberColonyIds[i] == memberColony) {
                tf.memberColonyIds[i] = tf.memberColonyIds[n - 1];
                tf.memberColonyIds.pop();
                found = true;
                break;
            }
        }
        if (!found) revert NotInTaskForce();

        delete cws.taskForceColonyCollections[taskForceId][memberColony];
        delete cws.taskForceColonyTokens[taskForceId][memberColony];

        emit AllianceTaskForceLeft(taskForceId, memberColony);
    }

    /**
     * @notice Leader disbands the task force.
     */
    function disbandAllianceTaskForce(bytes32 taskForceId) external whenNotPaused nonReentrant {
        LibColonyWarsStorage.requireInitialized();
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();

        LibColonyWarsStorage.ColonyTaskForce storage tf = cws.allianceTaskForces[taskForceId];
        if (!tf.isActive) revert TaskForceNotActive();
        if (hs.colonyCreators[tf.leaderColonyId] != LibMeta.msgSender()) revert NotTaskForceLeader();

        tf.isActive = false;
        emit AllianceTaskForceDisbanded(taskForceId);
    }

    // ============================================================
    // COORDINATED ATTACK ENTRYPOINTS
    // ============================================================

    /**
     * @notice QUICK: launch a coordinated attack with a pre-formed (opt-in) alliance task force.
     *         Leader funds the full stake; one battle per participating colony with that
     *         colony's opted-in tokens.
     */
    function initiateCoordinatedAttackWithTaskForce(
        bytes32 targetColony,
        bytes32 taskForceId,
        uint256 totalStake
    ) external whenNotPaused nonReentrant duringWarfarePeriod returns (bytes32[] memory battleIds) {
        LibColonyWarsStorage.requireInitialized();
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();

        address leader = LibMeta.msgSender();
        LibColonyWarsStorage.ColonyTaskForce storage tf = cws.allianceTaskForces[taskForceId];
        if (!tf.isActive) revert TaskForceNotActive();
        if (hs.colonyCreators[tf.leaderColonyId] != leader) revert NotTaskForceLeader();

        uint8 numColonies = uint8(tf.memberColonyIds.length) + 1;
        bytes32 allianceId = _validateCoordinated(cws, leader, numColonies, totalStake);

        uint256 stakePerColony = totalStake / numColonies;
        battleIds = new bytes32[](numColonies);

        // Leader battle.
        battleIds[0] = _createCoordinatedBattle(
            tf.leaderColonyId,
            targetColony,
            cws.taskForceColonyCollections[taskForceId][tf.leaderColonyId],
            cws.taskForceColonyTokens[taskForceId][tf.leaderColonyId],
            stakePerColony,
            leader
        );

        // Member battles.
        uint256 m = tf.memberColonyIds.length;
        for (uint256 i; i < m; i++) {
            bytes32 mc = tf.memberColonyIds[i];
            battleIds[i + 1] = _createCoordinatedBattle(
                mc,
                targetColony,
                cws.taskForceColonyCollections[taskForceId][mc],
                cws.taskForceColonyTokens[taskForceId][mc],
                stakePerColony,
                leader
            );
        }

        LibColonyWarsStorage.incrementAllianceCoordinatedAttackCount(allianceId);
        emit CoordinatedAttackInitiated(allianceId, targetColony, battleIds, numColonies);
        LibAchievementTrigger.triggerCoordinatedAttack(leader);
    }

    /**
     * @notice CUSTOM: ad-hoc coordinated attack across multiple colonies OWNED BY THE LEADER.
     *         No member consent needed because the leader owns every participating colony.
     * @param participatingColonies Colonies (all leader-owned) joining the strike.
     * @param collectionIds Flattened collection IDs, tokensPerColony per colony, leader order.
     * @param tokenIds Flattened token IDs, parallel to collectionIds.
     * @param tokensPerColony Tokens contributed by each colony.
     * @param totalStake Total stake funded by the leader, split evenly per colony.
     */
    function initiateCoordinatedAttack(
        bytes32 targetColony,
        bytes32[] calldata participatingColonies,
        uint256[] calldata collectionIds,
        uint256[] calldata tokenIds,
        uint8 tokensPerColony,
        uint256 totalStake
    ) external whenNotPaused nonReentrant duringWarfarePeriod returns (bytes32[] memory battleIds) {
        LibColonyWarsStorage.requireInitialized();
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();

        address leader = LibMeta.msgSender();
        uint8 numColonies = uint8(participatingColonies.length);
        bytes32 allianceId = _validateCoordinated(cws, leader, numColonies, totalStake);

        if (collectionIds.length != tokenIds.length) revert InvalidTokenCount();
        if (collectionIds.length != uint256(numColonies) * tokensPerColony) revert InvalidTokenCount();

        // Every participating colony must be owned by the leader (no third-party consent needed).
        for (uint256 i; i < numColonies; i++) {
            if (hs.colonyCreators[participatingColonies[i]] != leader) revert NotLeaderOwnedColony();
        }

        uint256 stakePerColony = totalStake / numColonies;
        battleIds = new bytes32[](numColonies);

        for (uint256 i; i < numColonies; i++) {
            (uint256[] memory cols, uint256[] memory toks) =
                _slice(collectionIds, tokenIds, i * tokensPerColony, tokensPerColony);
            battleIds[i] = _createCoordinatedBattle(participatingColonies[i], targetColony, cols, toks, stakePerColony, leader);
        }

        LibColonyWarsStorage.incrementAllianceCoordinatedAttackCount(allianceId);
        emit CoordinatedAttackInitiated(allianceId, targetColony, battleIds, numColonies);
        LibAchievementTrigger.triggerCoordinatedAttack(leader);
    }

    // ============================================================
    // VIEWS
    // ============================================================

    function getAllianceTaskForce(bytes32 taskForceId)
        external
        view
        returns (bytes32 leaderColonyId, bytes32[] memory memberColonyIds, uint32 seasonId, string memory name, uint32 createdAt, bool isActive)
    {
        LibColonyWarsStorage.ColonyTaskForce storage tf =
            LibColonyWarsStorage.colonyWarsStorage().allianceTaskForces[taskForceId];
        return (tf.leaderColonyId, tf.memberColonyIds, tf.seasonId, tf.name, tf.createdAt, tf.isActive);
    }

    function getAllianceTaskForceTokens(bytes32 taskForceId, bytes32 colonyId)
        external
        view
        returns (uint256[] memory collectionIds, uint256[] memory tokenIds)
    {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        return (cws.taskForceColonyCollections[taskForceId][colonyId], cws.taskForceColonyTokens[taskForceId][colonyId]);
    }

    /**
     * @param seasonId Pass 0 for the current season.
     */
    function getColonyAllianceTaskForces(bytes32 colonyId, uint32 seasonId)
        external
        view
        returns (bytes32[] memory taskForceIds)
    {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        uint32 s = seasonId == 0 ? cws.currentSeason : seasonId;
        return cws.colonyAllianceTaskForces[colonyId][s];
    }

    // ============================================================
    // INTERNAL HELPERS
    // ============================================================

    function _validateCoordinated(
        LibColonyWarsStorage.ColonyWarsStorage storage cws,
        address leader,
        uint8 numColonies,
        uint256 totalStake
    ) private view returns (bytes32 allianceId) {
        if (!cws.coordinatedAttackConfig.enabled) revert CoordinatedAttacksNotEnabled();

        allianceId = LibColonyWarsStorage.getUserAllianceId(leader);
        if (allianceId == bytes32(0)) revert AllianceNotEligible();

        (bool canAttack, uint8 attacksToday) = LibColonyWarsStorage.canAllianceInitiateCoordinatedAttack(allianceId);
        if (!canAttack) revert DailyCoordinatedAttackLimitReached(attacksToday, cws.coordinatedAttackConfig.maxCoordinatedAttacksPerDay);

        if (numColonies < cws.coordinatedAttackConfig.minParticipants) revert TooFewParticipants();
        uint8 maxP = cws.coordinatedAttackConfig.maxParticipants;
        if (maxP != 0 && numColonies > maxP) revert TooManyParticipants();

        uint256 minStake = cws.coordinatedAttackConfig.minStakePerParticipant * numColonies;
        if (totalStake < minStake) revert InsufficientStakeForCoordinatedAttack();
    }

    function _requireRegistered(LibColonyWarsStorage.ColonyWarsStorage storage cws, bytes32 colonyId) private view {
        LibColonyWarsStorage.ColonyWarProfile storage p = cws.colonyWarProfiles[colonyId];
        if (!p.registered || p.registeredSeasonId != cws.currentSeason) revert ColonyNotRegistered();
    }

    function _requireValidColonyTokens(
        LibHenomorphsStorage.HenomorphsStorage storage hs,
        bytes32 colonyId,
        uint256[] calldata collectionIds,
        uint256[] calldata tokenIds
    ) private view {
        if (collectionIds.length != tokenIds.length) revert InvalidTokenCount();
        if (collectionIds.length < 2 || collectionIds.length > LibColonyWarsStorage.colonyWarsStorage().config.maxBattleTokens) {
            revert InvalidTokenCount();
        }
        // Reverts (TokensNoLongerInColony) if any token is not in this colony.
        WarfareHelper.verifyAndConvertTokens(collectionIds, tokenIds, colonyId, hs);
    }

    function _slice(
        uint256[] calldata cols,
        uint256[] calldata toks,
        uint256 start,
        uint8 count
    ) private pure returns (uint256[] memory outCols, uint256[] memory outToks) {
        outCols = new uint256[](count);
        outToks = new uint256[](count);
        for (uint256 j; j < count; j++) {
            outCols[j] = cols[start + j];
            outToks[j] = toks[start + j];
        }
    }

    /**
     * @dev Creates one battle for a participating colony. Mirrors ColonyWarsFacet.initiateAttack's
     *      battle-creation body, but: identity is derived from the attacker colony's creator (not
     *      msgSender), stake is collected from the explicit `payer` (leader) into the treasury, and
     *      there is no per-sender rate limit / sender-ownership auth (the entrypoint enforced
     *      alliance membership + opt-in instead). Split into validate/record halves to stay within
     *      Yul stack limits.
     */
    function _createCoordinatedBattle(
        bytes32 attackerColony,
        bytes32 defenderColony,
        uint256[] memory attackCollectionIds,
        uint256[] memory attackTokenIds,
        uint256 stakeAmount,
        address payer
    ) private returns (bytes32 battleId) {
        uint256[] memory attackTokens =
            _validateBattle(attackerColony, defenderColony, attackCollectionIds, attackTokenIds, stakeAmount);
        battleId = _recordBattle(attackerColony, defenderColony, attackCollectionIds, attackTokenIds, attackTokens, stakeAmount, payer);
    }

    function _validateBattle(
        bytes32 attackerColony,
        bytes32 defenderColony,
        uint256[] memory attackCollectionIds,
        uint256[] memory attackTokenIds,
        uint256 stakeAmount
    ) private view returns (uint256[] memory attackTokens) {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();

        {
            bytes32 aA = LibColonyWarsStorage.getUserAllianceId(hs.colonyCreators[attackerColony]);
            bytes32 dA = LibColonyWarsStorage.getUserAllianceId(hs.colonyCreators[defenderColony]);
            if (aA != bytes32(0) && dA != bytes32(0) && aA != dA) {
                (bool hasTreaty, , ) = ICAF_AllianceEvolution(address(this)).getActiveTreaty(aA, dA);
                if (hasTreaty) revert AccessHelper.Unauthorized(hs.colonyCreators[attackerColony], "NAP treaty active");
            }
        }

        if (WarfareHelper.checkTokensForWarfareConflict(attackCollectionIds, attackTokenIds, defenderColony)) {
            revert AccessHelper.Unauthorized(hs.colonyCreators[attackerColony], "Token conflict with defender");
        }
        if (hs.colonyCreators[attackerColony] == hs.colonyCreators[defenderColony]) revert CannotAttackOwnColony();
        if (attackerColony == defenderColony) revert InvalidBattleState();
        if (attackCollectionIds.length != attackTokenIds.length) revert InvalidTokenCount();
        if (attackCollectionIds.length < 2 || attackCollectionIds.length > cws.config.maxBattleTokens) revert InvalidTokenCount();

        {
            LibColonyWarsStorage.ColonyWarProfile storage ap = cws.colonyWarProfiles[attackerColony];
            LibColonyWarsStorage.ColonyWarProfile storage dp = cws.colonyWarProfiles[defenderColony];
            if (!ap.registered || ap.registeredSeasonId != cws.currentSeason) revert SeasonNotActive();
            if (!dp.registered || dp.registeredSeasonId != cws.currentSeason) revert SeasonNotActive();
            if (block.timestamp < ap.lastAttackTime + cws.config.attackCooldown) revert AttackOnCooldown();
            if (!dp.acceptingChallenges) revert InvalidBattleState();
            if (stakeAmount < dp.defensiveStake / 2) revert InvalidStake();
        }

        attackTokens = WarfareHelper.verifyAndConvertTokens(attackCollectionIds, attackTokenIds, attackerColony, hs);
        for (uint256 i; i < attackTokens.length; i++) {
            if (!LibColonyWarsStorage.isTokenAvailableForBattle(attackTokens[i])) revert TokenInActiveBattle();
        }
    }

    function _recordBattle(
        bytes32 attackerColony,
        bytes32 defenderColony,
        uint256[] memory attackCollectionIds,
        uint256[] memory attackTokenIds,
        uint256[] memory attackTokens,
        uint256 stakeAmount,
        address payer
    ) private returns (bytes32 battleId) {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();

        cws.battleCounter++;
        battleId = keccak256(abi.encodePacked("battle", attackerColony, defenderColony, block.timestamp, cws.battleCounter));

        {
            LibColonyWarsStorage.BattleInstance storage battle = cws.battles[battleId];
            battle.attackerColony = attackerColony;
            battle.defenderColony = defenderColony;
            battle.attackerTokens = attackTokens;
            battle.battleStartTime = uint32(block.timestamp);
            battle.battleEndTime = uint32(block.timestamp + cws.config.battlePreparationTime + cws.config.battleDuration);
            battle.battleState = 0;

            uint256 validatedStake = _validateStakeAmount(stakeAmount, cws.colonyWarProfiles[defenderColony].defensiveStake);
            battle.stakeAmount = validatedStake;
            battle.prizePool = validatedStake;

            LibColonyWarsStorage.reserveTokensForBattle(attackTokens, battle.battleEndTime);

            LibFeeCollection.collectFee(
                IERC20(hs.chargeTreasury.treasuryCurrency),
                payer,
                hs.chargeTreasury.treasuryAddress,
                validatedStake,
                "coordinated_battle_stake"
            );
        }

        {
            (bool isBetrayal, bytes32 betrayedAllianceId) = LibColonyWarsStorage.validateAndProcessBetrayal(
                hs.colonyCreators[attackerColony], attackerColony, defenderColony, "attack"
            );
            if (isBetrayal) {
                cws.battles[battleId].isBetrayalAttack = true;
                emit WarfareHelper.BetrayalRecorded(attackerColony, betrayedAllianceId);
                emit WarfareHelper.ColonyLeftAlliance(betrayedAllianceId, attackerColony, "Attacked alliance member");
            }
        }

        {
            TokenStats[] memory stats = IAccessoryFacet(address(this)).getTokenPerformanceStats(attackCollectionIds, attackTokenIds);
            uint256[] memory powers = new uint256[](stats.length);
            for (uint256 i; i < stats.length; i++) {
                powers[i] = WarfareHelper.calculateTokenPower(stats[i]);
            }
            cws.battleSnapshots[battleId].attackerPowers = powers;
            cws.battleSnapshots[battleId].timestamp = block.timestamp;
        }

        cws.colonyWarProfiles[attackerColony].lastAttackTime = uint32(block.timestamp);
        cws.seasonBattles[cws.currentSeason].push(battleId);
        cws.colonyBattleHistory[attackerColony].push(battleId);
        cws.colonyBattleHistory[defenderColony].push(battleId);

        emit CoordinatedBattleCreated(battleId, attackerColony, defenderColony, stakeAmount);
    }

    function _validateStakeAmount(uint256 stakeAmount, uint256 defenderStake) private pure returns (uint256 validatedStake) {
        if (stakeAmount < defenderStake / 2) revert InvalidStake();
        uint256 maxStake = defenderStake * 4;
        validatedStake = stakeAmount > maxStake ? maxStake : stakeAmount;
    }
}
