// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {LibMeta} from "../../shared/libraries/LibMeta.sol";
import {LibHenomorphsStorage} from "../libraries/LibHenomorphsStorage.sol";
import {LibColonyCupStorage} from "../libraries/LibColonyCupStorage.sol";
import {LibCupMatch} from "../libraries/LibCupMatch.sol";
import {CupMatchEngine} from "../libraries/CupMatchEngine.sol";
import {AccessControlBase} from "../../common/facets/AccessControlBase.sol";
import {AccessHelper} from "../../staking/libraries/AccessHelper.sol";
import {ColonyHelper} from "../../staking/libraries/ColonyHelper.sol";

/**
 * @title ColonyCupFacet
 * @notice Colony Cup core: admin, team management (5+2 bench), friendlies, season rewards
 * @dev v2 (MATCH PLAN pattern). The ranked match flow (challenge -> plans -> halves ->
 *      shootout) lives in ColonyCupPlayFacet; shared internals in LibCupMatch.
 *      The cup is fully independent from wars and missions: own storage slot, own
 *      season lifecycle, no chick locks — only token stats + colony membership reads.
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 */
contract ColonyCupFacet is AccessControlBase {
    using SafeERC20 for IERC20;

    // ============ EVENTS ============

    event CupConfigUpdated(LibColonyCupStorage.CupConfig config);
    event CupSeasonStarted(uint32 indexed seasonId, string name, uint64 startsAt, uint64 endsAt);
    event CupSeasonScheduleUpdated(uint32 indexed seasonId, string name, uint64 startsAt, uint64 endsAt);
    event CupSeasonEnded(uint32 indexed seasonId, uint256 rewardPool);
    event TeamRegistered(bytes32 indexed colonyId, uint32 indexed seasonId, uint256[5] tokens, uint256[2] bench);
    event SquadChanged(bytes32 indexed colonyId, uint32 indexed seasonId, uint256[5] tokens, uint256[2] bench);
    event KitChanged(bytes32 indexed colonyId, uint32 indexed seasonId, bytes3 kitPrimary, bytes3 kitSecondary, uint8 kitPattern);
    event MatchPlayed(
        uint256 indexed matchId,
        bytes32 indexed home,
        bytes32 indexed away,
        uint8 scoreHome,
        uint8 scoreAway,
        bytes32 seed,
        uint256 packedEvents,
        uint8 eventCount,
        bool friendly
    );
    event SeasonAllocationSet(uint32 indexed seasonId, bytes32 indexed colonyId, uint256 amount);
    event SeasonRewardClaimed(uint32 indexed seasonId, bytes32 indexed colonyId, address recipient, uint256 amount);

    // ============ ERRORS ============

    error CupAlreadyInitialized();
    error CupSeasonStillActive();
    error InvalidCupConfig(string reason);
    error InvalidSquad(string reason);
    error SelfMatchForbidden();
    error AllocationExceedsPool(uint32 seasonId, uint256 allocated, uint256 pool);
    error NothingToClaim(uint32 seasonId, bytes32 colonyId);

    // ============ MODIFIERS ============

    /// @dev Same creator gate the wars registration facet uses
    modifier onlyColonyCreator(bytes32 colonyId) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        if (!ColonyHelper.isColonyCreator(colonyId, hs.stakingSystemAddress)) {
            revert AccessHelper.Unauthorized(LibMeta.msgSender(), "Not colony creator");
        }
        _;
    }

    // ============ ADMIN ============

    function initializeCup(LibColonyCupStorage.CupConfig calldata config) external onlyAuthorized {
        LibColonyCupStorage.CupStorage storage cs = LibColonyCupStorage.cupStorage();
        if (cs.initialized) {
            revert CupAlreadyInitialized();
        }
        _validateConfig(config);
        cs.initialized = true;
        cs.config = config;
        emit CupConfigUpdated(config);
    }

    function setCupConfig(LibColonyCupStorage.CupConfig calldata config) external onlyAuthorized {
        LibColonyCupStorage.CupStorage storage cs = LibColonyCupStorage.cupStorage();
        if (!cs.initialized) {
            revert LibCupMatch.CupNotInitialized();
        }
        _validateConfig(config);
        cs.config = config;
        emit CupConfigUpdated(config);
    }

    /**
     * @notice Open a new championship: display name + scheduled play window.
     * @param name     championship name shown in the app (e.g. "Colony Cup 2026")
     * @param startsAt unix start of PLAY; 0 = in play immediately. Registration is
     *                 open from this call regardless (pre-season prep).
     * @param endsAt   unix scheduled end; 0 = open until endCupSeason
     */
    function startCupSeason(
        string calldata name,
        uint64 startsAt,
        uint64 endsAt
    ) external onlyAuthorized returns (uint32 seasonId) {
        LibColonyCupStorage.CupStorage storage cs = LibColonyCupStorage.cupStorage();
        if (!cs.initialized) {
            revert LibCupMatch.CupNotInitialized();
        }
        if (cs.currentSeason != 0 && cs.seasonEndTime[cs.currentSeason] == 0) {
            revert CupSeasonStillActive();
        }
        _validateSchedule(startsAt, endsAt);
        seasonId = ++cs.currentSeason;
        LibColonyCupStorage.SeasonSchedule storage sched = cs.seasonSchedule[seasonId];
        sched.name = name;
        sched.startsAt = startsAt;
        sched.endsAt = endsAt;
        emit CupSeasonStarted(seasonId, name, startsAt, endsAt);
    }

    /// @notice Amend name/dates of the OPEN season (e.g. extend the championship)
    function setSeasonSchedule(
        string calldata name,
        uint64 startsAt,
        uint64 endsAt
    ) external onlyAuthorized {
        LibColonyCupStorage.CupStorage storage cs = LibColonyCupStorage.cupStorage();
        uint32 seasonId = cs.currentSeason;
        if (seasonId == 0 || cs.seasonEndTime[seasonId] != 0) {
            revert LibCupMatch.CupSeasonNotActive();
        }
        _validateSchedule(startsAt, endsAt);
        LibColonyCupStorage.SeasonSchedule storage sched = cs.seasonSchedule[seasonId];
        sched.name = name;
        sched.startsAt = startsAt;
        sched.endsAt = endsAt;
        emit CupSeasonScheduleUpdated(seasonId, name, startsAt, endsAt);
    }

    function endCupSeason() external onlyAuthorized {
        LibColonyCupStorage.CupStorage storage cs = LibColonyCupStorage.cupStorage();
        uint32 seasonId = cs.currentSeason;
        if (seasonId == 0 || cs.seasonEndTime[seasonId] != 0) {
            revert LibCupMatch.CupSeasonNotActive();
        }
        cs.seasonEndTime[seasonId] = uint64(block.timestamp);
        emit CupSeasonEnded(seasonId, cs.seasonPool[seasonId]);
    }

    /// @notice Permissionless close once the scheduled end has passed — claims must
    ///         never wait for an admin (force-move philosophy).
    function closeExpiredCupSeason() external {
        LibColonyCupStorage.CupStorage storage cs = LibColonyCupStorage.cupStorage();
        uint32 seasonId = cs.currentSeason;
        if (seasonId == 0 || cs.seasonEndTime[seasonId] != 0) {
            revert LibCupMatch.CupSeasonNotActive();
        }
        uint64 endsAt = cs.seasonSchedule[seasonId].endsAt;
        if (endsAt == 0 || block.timestamp <= endsAt) {
            revert CupSeasonStillActive();
        }
        cs.seasonEndTime[seasonId] = endsAt;
        emit CupSeasonEnded(seasonId, cs.seasonPool[seasonId]);
    }

    function _validateSchedule(uint64 startsAt, uint64 endsAt) private view {
        uint64 effectiveStart = startsAt == 0 ? uint64(block.timestamp) : startsAt;
        if (endsAt != 0 && endsAt <= effectiveStart) {
            revert InvalidCupConfig("season end before start");
        }
    }

    /**
     * @notice Set (override) reward allocations for a finished season
     * @dev Allocations are claim-based; total may never exceed the season pool.
     */
    function setSeasonAllocations(
        uint32 seasonId,
        bytes32[] calldata colonyIds,
        uint256[] calldata amounts
    ) external onlyAuthorized {
        LibColonyCupStorage.CupStorage storage cs = LibColonyCupStorage.cupStorage();
        if (cs.seasonEndTime[seasonId] == 0) {
            revert CupSeasonStillActive();
        }
        if (colonyIds.length != amounts.length) {
            revert InvalidCupConfig("array length mismatch");
        }

        uint256 allocated = cs.seasonAllocatedTotal[seasonId];
        for (uint256 i = 0; i < colonyIds.length; i++) {
            uint256 previous = cs.seasonAllocations[seasonId][colonyIds[i]];
            uint256 claimed = cs.seasonClaimed[seasonId][colonyIds[i]];
            if (amounts[i] < claimed) {
                revert InvalidCupConfig("allocation below claimed");
            }
            allocated = allocated - previous + amounts[i];
            cs.seasonAllocations[seasonId][colonyIds[i]] = amounts[i];
            emit SeasonAllocationSet(seasonId, colonyIds[i], amounts[i]);
        }

        if (allocated > cs.seasonPool[seasonId]) {
            revert AllocationExceedsPool(seasonId, allocated, cs.seasonPool[seasonId]);
        }
        cs.seasonAllocatedTotal[seasonId] = allocated;
    }

    // ============ TEAM MANAGEMENT ============

    /**
     * @notice Register (or re-activate) a colony's cup team for the current season
     * @param colonyId Colony fielding the team
     * @param collectionIds Collection per squad slot [GK, DEF, DEF, MID, ATT]
     * @param tokenIds Token per squad slot
     * @param benchCollectionIds Bench collections (0/0 = empty slot)
     * @param benchTokenIds Bench tokens
     * @param kitPrimary Primary kit color (RGB)
     * @param kitSecondary Secondary kit color (RGB)
     * @param kitPattern 0=solid, 1=stripes, 2=hoops
     */
    function registerTeam(
        bytes32 colonyId,
        uint256[5] calldata collectionIds,
        uint256[5] calldata tokenIds,
        uint256[2] calldata benchCollectionIds,
        uint256[2] calldata benchTokenIds,
        bytes3 kitPrimary,
        bytes3 kitSecondary,
        uint8 kitPattern
    ) external whenNotPaused onlyColonyCreator(colonyId) {
        LibColonyCupStorage.CupStorage storage cs = LibCupMatch.requireCupActive();
        if (kitPattern > 2) {
            revert InvalidSquad("kit pattern");
        }

        uint256[5] memory combined = LibCupMatch.validateSquad(colonyId, collectionIds, tokenIds);
        uint256[2] memory bench = LibCupMatch.validateBench(colonyId, benchCollectionIds, benchTokenIds, combined);

        uint32 seasonId = cs.currentSeason;
        LibColonyCupStorage.TeamSheet storage team = cs.teams[seasonId][colonyId];
        bool firstRegistration = team.registeredAt == 0;

        team.tokens = combined;
        team.bench = bench;
        team.kitPrimary = kitPrimary;
        team.kitSecondary = kitSecondary;
        team.kitPattern = kitPattern;
        team.seasonId = seasonId;
        team.registeredAt = uint64(block.timestamp);
        team.active = true;

        if (firstRegistration) {
            cs.participants[seasonId].push(colonyId);
        }

        emit TeamRegistered(colonyId, seasonId, combined, bench);
    }

    /// @notice Replace the squad + bench of an already registered team
    function setSquad(
        bytes32 colonyId,
        uint256[5] calldata collectionIds,
        uint256[5] calldata tokenIds,
        uint256[2] calldata benchCollectionIds,
        uint256[2] calldata benchTokenIds
    ) external whenNotPaused onlyColonyCreator(colonyId) {
        LibColonyCupStorage.CupStorage storage cs = LibCupMatch.requireCupActive();
        LibColonyCupStorage.TeamSheet storage team = LibCupMatch.requireTeam(cs, cs.currentSeason, colonyId);

        uint256[5] memory combined = LibCupMatch.validateSquad(colonyId, collectionIds, tokenIds);
        uint256[2] memory bench = LibCupMatch.validateBench(colonyId, benchCollectionIds, benchTokenIds, combined);
        team.tokens = combined;
        team.bench = bench;

        emit SquadChanged(colonyId, cs.currentSeason, combined, bench);
    }

    /// @notice Change kit colors/pattern of an already registered team
    function setKit(
        bytes32 colonyId,
        bytes3 kitPrimary,
        bytes3 kitSecondary,
        uint8 kitPattern
    ) external whenNotPaused onlyColonyCreator(colonyId) {
        LibColonyCupStorage.CupStorage storage cs = LibCupMatch.requireCupActive();
        LibColonyCupStorage.TeamSheet storage team = LibCupMatch.requireTeam(cs, cs.currentSeason, colonyId);
        if (kitPattern > 2) {
            revert InvalidSquad("kit pattern");
        }

        team.kitPrimary = kitPrimary;
        team.kitSecondary = kitSecondary;
        team.kitPattern = kitPattern;

        emit KitChanged(colonyId, cs.currentSeason, kitPrimary, kitSecondary, kitPattern);
    }

    // ============ FRIENDLIES ============

    /**
     * @notice Play an instant friendly (sparring) against another registered team
     * @dev No stake, no table impact, no opponent consent needed — it is a simulation
     *      against their currently registered squad. Counts toward the daily limit of
     *      the initiator only. The initiator's plan is OPEN (no commit); the opponent
     *      plays BALANCED with no rules. Both halves resolve in this single tx, with
     *      the initiator's conditional rules applied at the simulated break.
     * @param plan Initiator's open plan card (see CupMatchEngine layout)
     */
    function playFriendly(
        bytes32 homeColony,
        bytes32 awayColony,
        uint256 plan
    ) external whenNotPaused nonReentrant onlyColonyCreator(homeColony) returns (uint256 matchId) {
        LibColonyCupStorage.CupStorage storage cs = LibCupMatch.requireCupActive();
        LibCupMatch.requireSeasonInPlay(cs, cs.currentSeason);
        if (homeColony == awayColony) {
            revert SelfMatchForbidden();
        }

        uint32 seasonId = cs.currentSeason;
        LibColonyCupStorage.TeamSheet storage homeTeam = LibCupMatch.requireTeam(cs, seasonId, homeColony);
        LibColonyCupStorage.TeamSheet storage awayTeam = LibCupMatch.requireTeam(cs, seasonId, awayColony);

        LibCupMatch.requireSquadInColony(homeTeam.tokens, homeColony);
        LibCupMatch.requireSquadInColony(awayTeam.tokens, awayColony);

        LibCupMatch.consumeDailySlot(cs, homeColony, cs.config.dailyMatchLimit);

        matchId = ++cs.matchCounter;
        LibColonyCupStorage.CupMatch storage matchData = cs.matches[matchId];
        matchData.seasonId = seasonId;
        matchData.home = homeColony;
        matchData.away = awayColony;
        matchData.homeOwner = LibMeta.msgSender();
        matchData.createdAt = uint64(block.timestamp);
        matchData.kickoffBlock = uint64(block.number);
        matchData.friendly = true;
        matchData.homeSide.plan = plan;
        matchData.homeSide.planRevealed = true;

        matchData.homeSquad = homeTeam.tokens;
        matchData.awaySquad = awayTeam.tokens;
        matchData.homeBench = homeTeam.bench;
        matchData.homeStrength = LibCupMatch.computeStrength(homeTeam.tokens);
        matchData.awayStrength = LibCupMatch.computeStrength(awayTeam.tokens);

        bytes32 seed = keccak256(abi.encodePacked(
            block.prevrandao,
            matchId,
            blockhash(block.number - 1),
            homeColony,
            awayColony
        ));
        matchData.seed = seed;

        _simulateFriendly(matchData, plan, seed);

        matchData.status = LibColonyCupStorage.MatchStatus.Played;

        cs.colonyMatches[seasonId][homeColony].push(matchId);
        cs.colonyMatches[seasonId][awayColony].push(matchId);

        emit MatchPlayed(
            matchId,
            homeColony,
            awayColony,
            matchData.scoreHome,
            matchData.scoreAway,
            seed,
            matchData.packedEvents,
            matchData.eventCount,
            true
        );
    }

    /// @dev Both halves in one go; home's conditional rules fire on the half-time score
    function _simulateFriendly(
        LibColonyCupStorage.CupMatch storage matchData,
        uint256 plan,
        bytes32 seed
    ) internal {
        uint8 homeTactic = CupMatchEngine.baseTactic(plan);

        // First half
        CupMatchEngine.HalfResult memory h1 = CupMatchEngine.simulateHalf(
            CupMatchEngine.applyTactics(matchData.homeStrength, homeTactic, CupMatchEngine.TACTIC_BALANCED),
            CupMatchEngine.applyTactics(matchData.awayStrength, CupMatchEngine.TACTIC_BALANCED, homeTactic),
            keccak256(abi.encodePacked(seed, uint8(1))),
            0,
            0,
            0,
            0
        );
        matchData.scoreHomeHT = h1.goalsHome;
        matchData.scoreAwayHT = h1.goalsAway;
        matchData.packedEvents = h1.packedEvents;
        matchData.eventCount = h1.eventCount;

        // Half-time: apply the initiator's conditional rule (incl. substitution)
        CupMatchEngine.HalfPlan memory hp = CupMatchEngine.secondHalfPlan(
            plan,
            int16(uint16(h1.goalsHome)) - int16(uint16(h1.goalsAway))
        );
        CupMatchEngine.TeamStrength memory homeBase = matchData.homeStrength;
        if (hp.subActive) {
            uint256 benchToken = matchData.homeBench[hp.benchIdx];
            if (benchToken != 0 && LibCupMatch.isInColony(benchToken, matchData.home)) {
                uint256[5] memory squad = matchData.homeSquad;
                squad[hp.subSlot] = benchToken;
                matchData.homeSquad = squad;
                homeBase = LibCupMatch.computeStrength(squad);
            }
        }

        // Second half
        CupMatchEngine.HalfResult memory h2 = CupMatchEngine.simulateHalf(
            CupMatchEngine.applyTactics(homeBase, hp.tactic, CupMatchEngine.TACTIC_BALANCED),
            CupMatchEngine.applyTactics(matchData.awayStrength, CupMatchEngine.TACTIC_BALANCED, hp.tactic),
            keccak256(abi.encodePacked(seed, uint8(2))),
            1,
            h1.goalsHome,
            h1.goalsAway,
            h1.eventCount
        );
        matchData.scoreHome = h1.goalsHome + h2.goalsHome;
        matchData.scoreAway = h1.goalsAway + h2.goalsAway;
        matchData.packedEvents |= h2.packedEvents;
        matchData.eventCount = h1.eventCount + h2.eventCount;
    }

    // ============ SEASON REWARDS ============

    /// @notice Claim an allocated season reward for a colony (creator only)
    function claimSeasonReward(uint32 seasonId, bytes32 colonyId)
        external
        whenNotPaused
        nonReentrant
        onlyColonyCreator(colonyId)
    {
        LibColonyCupStorage.CupStorage storage cs = LibColonyCupStorage.cupStorage();
        uint256 claimable = cs.seasonAllocations[seasonId][colonyId] - cs.seasonClaimed[seasonId][colonyId];
        if (claimable == 0) {
            revert NothingToClaim(seasonId, colonyId);
        }

        cs.seasonClaimed[seasonId][colonyId] += claimable;
        address recipient = LibMeta.msgSender();
        LibCupMatch.currency().safeTransfer(recipient, claimable);

        emit SeasonRewardClaimed(seasonId, colonyId, recipient, claimable);
    }

    // ============ INTERNALS ============

    function _validateConfig(LibColonyCupStorage.CupConfig calldata config) internal pure {
        if (config.maxStake < config.minStake) {
            revert InvalidCupConfig("stake bounds");
        }
        if (config.kickoffDelayBlocks == 0 || config.kickoffDelayBlocks > LibColonyCupStorage.KICKOFF_WINDOW_BLOCKS) {
            revert InvalidCupConfig("kickoff delay");
        }
        if (config.dailyMatchLimit == 0) {
            revert InvalidCupConfig("daily limit");
        }
        if (config.feeBps > 2000) {
            revert InvalidCupConfig("fee above 20%");
        }
        if (config.challengeTimeout < 1 hours) {
            revert InvalidCupConfig("challenge timeout");
        }
        if (config.halftimeBlocks == 0 || config.halftimeBlocks > LibColonyCupStorage.KICKOFF_WINDOW_BLOCKS) {
            revert InvalidCupConfig("halftime window");
        }
        if (config.shootoutCommitBlocks == 0 || config.shootoutRevealBlocks == 0) {
            revert InvalidCupConfig("shootout windows");
        }
    }
}
