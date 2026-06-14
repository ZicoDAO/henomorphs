// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {LibMeta} from "../../shared/libraries/LibMeta.sol";
import {LibHenomorphsStorage} from "../libraries/LibHenomorphsStorage.sol";
import {LibColonyCupStorage} from "../libraries/LibColonyCupStorage.sol";
import {LibCupMatch} from "../libraries/LibCupMatch.sol";
import {CupMatchEngine} from "../libraries/CupMatchEngine.sol";
import {LibFeeCollection} from "../../staking/libraries/LibFeeCollection.sol";
import {AccessControlBase} from "../../common/facets/AccessControlBase.sol";
import {AccessHelper} from "../../staking/libraries/AccessHelper.sol";
import {ColonyHelper} from "../../staking/libraries/ColonyHelper.sol";

/**
 * @title ColonyCupPlayFacet
 * @notice Colony Cup ranked match flow — v2 MATCH PLAN pattern
 * @dev Lifecycle:
 *        challengeMatch(planCommit, optional scheduled kickoff)
 *          -> acceptMatch(planCommit)            [stakes escrowed, entropy locked]
 *          -> revealPlan x2                      [deadline = kickoff block]
 *          -> playFirstHalf                      [anyone, tactic-adjusted half 1]
 *          -> setSecondHalfPlan (optional, open) [break window, both sides]
 *          -> playSecondHalf                     [anyone; conditional rules + subs]
 *          -> (draw, ranked) commitShootout x2 -> revealShootout x2 -> resolveShootout
 *
 *      Every phase is permissionless to FINISH: unrevealed plans default to
 *      BALANCED, an absent side's conditional rules still play for them, missed
 *      shootout picks fall back to seed-derived directions, and missed play
 *      windows settle or refund. An AFK player can never block funds.
 *
 *      Randomness: entropy at accept + blockhash of the phase boundary block
 *      (kickoff / break end), so all decisions lock before their randomness exists.
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 */
contract ColonyCupPlayFacet is AccessControlBase {
    using SafeERC20 for IERC20;

    // ============ EVENTS ============

    event MatchChallenged(uint256 indexed matchId, bytes32 indexed home, bytes32 indexed away, uint256 stake, address challenger, uint64 desiredKickoffBlock);
    event MatchAccepted(uint256 indexed matchId, uint64 kickoffBlock);
    event ChallengeCancelled(uint256 indexed matchId, bool expired);
    event MatchExpired(uint256 indexed matchId);
    event PlanRevealed(uint256 indexed matchId, bool isHome);
    event FirstHalfPlayed(uint256 indexed matchId, uint8 scoreHome, uint8 scoreAway, uint64 breakEndBlock);
    event SecondHalfPlanSet(uint256 indexed matchId, bool isHome, uint16 rule);
    event ShootoutRequired(uint256 indexed matchId, uint64 commitEndBlock, uint64 revealEndBlock);
    event ShootoutCommitted(uint256 indexed matchId, bool isHome);
    event ShootoutRevealed(uint256 indexed matchId, bool isHome);
    event ShootoutResolved(uint256 indexed matchId, uint8 homeGoals, uint8 awayGoals, bool homeWins, uint32 packedKicks, uint8 rounds);
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

    // ============ ERRORS ============

    error SelfMatchForbidden();
    error InvalidStakeAmount(uint256 given, uint128 minStake, uint128 maxStake);
    error PairOnCooldown(uint64 availableAt);
    error ChallengeStillAcceptable(uint256 matchId, uint64 acceptableUntil);
    error ChallengeExpired(uint256 matchId, uint64 acceptableUntil);
    error KickoffNotReached(uint64 kickoffBlock);
    error PlanCommitRequired();
    error InvalidScheduledKickoff(uint64 desired);
    error NotMatchParticipant(uint256 matchId, address caller);
    error PlanAlreadyRevealed(uint256 matchId);
    error RevealDeadlinePassed(uint256 matchId, uint64 deadlineBlock);
    error InvalidPlanReveal(uint256 matchId);
    error BreakNotFinished(uint256 matchId, uint64 breakEndBlock);
    error BreakFinished(uint256 matchId, uint64 breakEndBlock);
    error ShootoutCommitClosed(uint256 matchId, uint64 commitEndBlock);
    error ShootoutRevealClosed(uint256 matchId, uint64 revealEndBlock);
    error ShootoutCommitMissing(uint256 matchId);
    error ShootoutNotResolvable(uint256 matchId, uint64 revealEndBlock);
    error InvalidShootoutReveal(uint256 matchId);

    // ============ CHALLENGE / ACCEPT ============

    /**
     * @notice Challenge another colony to a ranked match, escrowing the stake
     * @param planCommit keccak256(abi.encodePacked(plan, salt)) — locked now, revealed before kickoff
     * @param desiredKickoffBlock Optional scheduled kickoff (0 = ASAP after accept)
     */
    function challengeMatch(
        bytes32 homeColony,
        bytes32 awayColony,
        uint256 stake,
        bytes32 planCommit,
        uint64 desiredKickoffBlock
    ) external whenNotPaused nonReentrant returns (uint256 matchId) {
        _requireColonyCreator(homeColony);
        LibColonyCupStorage.CupStorage storage cs = LibCupMatch.requireCupActive();
        LibCupMatch.requireSeasonInPlay(cs, cs.currentSeason);
        if (homeColony == awayColony) {
            revert SelfMatchForbidden();
        }
        if (planCommit == bytes32(0)) {
            revert PlanCommitRequired();
        }
        if (desiredKickoffBlock != 0 &&
            (desiredKickoffBlock <= block.number ||
             desiredKickoffBlock > block.number + LibColonyCupStorage.MAX_SCHEDULE_AHEAD_BLOCKS)) {
            revert InvalidScheduledKickoff(desiredKickoffBlock);
        }

        uint32 seasonId = cs.currentSeason;
        LibCupMatch.requireTeam(cs, seasonId, homeColony);
        LibCupMatch.requireTeam(cs, seasonId, awayColony);

        LibColonyCupStorage.CupConfig storage config = cs.config;
        if (stake < config.minStake || stake > config.maxStake) {
            revert InvalidStakeAmount(stake, config.minStake, config.maxStake);
        }

        LibCupMatch.consumeDailySlot(cs, homeColony, config.dailyMatchLimit);

        bytes32 pair = LibColonyCupStorage.pairKey(homeColony, awayColony);
        uint64 availableAt = cs.pairLastMatch[pair] + config.pairCooldown;
        if (block.timestamp < availableAt) {
            revert PairOnCooldown(availableAt);
        }

        address sender = LibMeta.msgSender();
        LibFeeCollection.collectFee(LibCupMatch.currency(), sender, address(this), stake, "cup_challenge_stake");

        matchId = ++cs.matchCounter;
        LibColonyCupStorage.CupMatch storage matchData = cs.matches[matchId];
        matchData.seasonId = seasonId;
        matchData.home = homeColony;
        matchData.away = awayColony;
        matchData.homeOwner = sender;
        matchData.stake = uint128(stake);
        matchData.createdAt = uint64(block.timestamp);
        matchData.desiredKickoffBlock = desiredKickoffBlock;
        matchData.homeSide.planCommit = planCommit;
        matchData.status = LibColonyCupStorage.MatchStatus.Pending;

        cs.colonyMatches[seasonId][homeColony].push(matchId);
        cs.colonyMatches[seasonId][awayColony].push(matchId);

        emit MatchChallenged(matchId, homeColony, awayColony, stake, sender, desiredKickoffBlock);
    }

    /**
     * @notice Accept a pending challenge: escrow stake, snapshot squads, schedule kickoff
     */
    function acceptMatch(uint256 matchId, bytes32 planCommit) external whenNotPaused nonReentrant {
        LibColonyCupStorage.CupStorage storage cs = LibColonyCupStorage.cupStorage();
        LibColonyCupStorage.CupMatch storage matchData = LibCupMatch.requireMatch(cs, matchId);
        LibCupMatch.requireStatus(matchData, matchId, LibColonyCupStorage.MatchStatus.Pending);
        _requireColonyCreator(matchData.away);
        if (planCommit == bytes32(0)) {
            revert PlanCommitRequired();
        }

        uint64 acceptableUntil = matchData.createdAt + cs.config.challengeTimeout;
        if (block.timestamp > acceptableUntil) {
            revert ChallengeExpired(matchId, acceptableUntil);
        }
        // No new match may START outside the scheduled play window; the challenger
        // can still cancel/expire for a refund.
        LibCupMatch.requireSeasonInPlay(cs, matchData.seasonId);

        uint32 seasonId = matchData.seasonId;
        LibColonyCupStorage.TeamSheet storage homeTeam = LibCupMatch.requireTeam(cs, seasonId, matchData.home);
        LibColonyCupStorage.TeamSheet storage awayTeam = LibCupMatch.requireTeam(cs, seasonId, matchData.away);

        // Squads must still be intact in their colonies at scheduling time
        LibCupMatch.requireSquadInColony(homeTeam.tokens, matchData.home);
        LibCupMatch.requireSquadInColony(awayTeam.tokens, matchData.away);

        LibCupMatch.consumeDailySlot(cs, matchData.away, cs.config.dailyMatchLimit);

        address sender = LibMeta.msgSender();
        LibFeeCollection.collectFee(LibCupMatch.currency(), sender, address(this), matchData.stake, "cup_accept_stake");

        // Snapshot squads, benches and strengths — the match is played as fielded here
        matchData.homeSquad = homeTeam.tokens;
        matchData.awaySquad = awayTeam.tokens;
        matchData.homeBench = homeTeam.bench;
        matchData.awayBench = awayTeam.bench;
        matchData.homeStrength = LibCupMatch.computeStrength(homeTeam.tokens);
        matchData.awayStrength = LibCupMatch.computeStrength(awayTeam.tokens);

        matchData.awayOwner = sender;
        matchData.awaySide.planCommit = planCommit;

        uint64 minKickoff = uint64(block.number + cs.config.kickoffDelayBlocks);
        matchData.kickoffBlock = matchData.desiredKickoffBlock > minKickoff
            ? matchData.desiredKickoffBlock
            : minKickoff;

        matchData.entropy = keccak256(abi.encodePacked(block.prevrandao, matchId, blockhash(block.number - 1)));
        matchData.status = LibColonyCupStorage.MatchStatus.Scheduled;

        cs.pairLastMatch[LibColonyCupStorage.pairKey(matchData.home, matchData.away)] = uint64(block.timestamp);

        emit MatchAccepted(matchId, matchData.kickoffBlock);
    }

    /// @notice Cancel an unaccepted challenge (challenger only) with a stake refund
    function cancelChallenge(uint256 matchId) external whenNotPaused nonReentrant {
        LibColonyCupStorage.CupStorage storage cs = LibColonyCupStorage.cupStorage();
        LibColonyCupStorage.CupMatch storage matchData = LibCupMatch.requireMatch(cs, matchId);
        LibCupMatch.requireStatus(matchData, matchId, LibColonyCupStorage.MatchStatus.Pending);
        _requireColonyCreator(matchData.home);

        matchData.status = LibColonyCupStorage.MatchStatus.Cancelled;
        LibCupMatch.currency().safeTransfer(matchData.homeOwner, matchData.stake);

        emit ChallengeCancelled(matchId, false);
    }

    /// @notice Expire a timed-out challenge (anyone) with a stake refund to the challenger
    function expireChallenge(uint256 matchId) external whenNotPaused nonReentrant {
        LibColonyCupStorage.CupStorage storage cs = LibColonyCupStorage.cupStorage();
        LibColonyCupStorage.CupMatch storage matchData = LibCupMatch.requireMatch(cs, matchId);
        LibCupMatch.requireStatus(matchData, matchId, LibColonyCupStorage.MatchStatus.Pending);

        uint64 acceptableUntil = matchData.createdAt + cs.config.challengeTimeout;
        if (block.timestamp <= acceptableUntil) {
            revert ChallengeStillAcceptable(matchId, acceptableUntil);
        }

        matchData.status = LibColonyCupStorage.MatchStatus.Cancelled;
        LibCupMatch.currency().safeTransfer(matchData.homeOwner, matchData.stake);

        emit ChallengeCancelled(matchId, true);
    }

    // ============ PLAN REVEAL ============

    /**
     * @notice Reveal a committed plan card (deadline: the kickoff block)
     * @dev Commits were locked at challenge/accept, so an early reveal leaks no
     *      exploitable information — the opponent cannot change theirs anymore.
     */
    function revealPlan(uint256 matchId, bytes32 colonyId, uint256 plan, bytes32 salt) external whenNotPaused {
        LibColonyCupStorage.CupStorage storage cs = LibColonyCupStorage.cupStorage();
        LibColonyCupStorage.CupMatch storage matchData = LibCupMatch.requireMatch(cs, matchId);
        LibCupMatch.requireStatus(matchData, matchId, LibColonyCupStorage.MatchStatus.Scheduled);
        if (block.number > matchData.kickoffBlock) {
            revert RevealDeadlinePassed(matchId, matchData.kickoffBlock);
        }

        (LibColonyCupStorage.SidePlan storage side, bool isHome) = _callerSide(matchData, matchId, colonyId);
        if (side.planRevealed) {
            revert PlanAlreadyRevealed(matchId);
        }
        if (keccak256(abi.encodePacked(plan, salt)) != side.planCommit) {
            revert InvalidPlanReveal(matchId);
        }

        side.plan = plan;
        side.planRevealed = true;

        emit PlanRevealed(matchId, isHome);
    }

    // ============ FIRST HALF ============

    /**
     * @notice Resolve the first half after kickoff (anyone can call)
     * @dev Unrevealed plans default to BALANCED. Past the 250-block window the
     *      match expires and both stakes are refunded.
     */
    function playFirstHalf(uint256 matchId) external whenNotPaused nonReentrant {
        LibColonyCupStorage.CupStorage storage cs = LibColonyCupStorage.cupStorage();
        LibColonyCupStorage.CupMatch storage matchData = LibCupMatch.requireMatch(cs, matchId);
        LibCupMatch.requireStatus(matchData, matchId, LibColonyCupStorage.MatchStatus.Scheduled);
        if (block.number <= matchData.kickoffBlock) {
            revert KickoffNotReached(matchData.kickoffBlock);
        }

        bytes32 kickoffHash = blockhash(matchData.kickoffBlock);
        if (block.number > matchData.kickoffBlock + LibColonyCupStorage.KICKOFF_WINDOW_BLOCKS || kickoffHash == bytes32(0)) {
            matchData.status = LibColonyCupStorage.MatchStatus.Expired;
            IERC20 refundCurrency = LibCupMatch.currency();
            refundCurrency.safeTransfer(matchData.homeOwner, matchData.stake);
            refundCurrency.safeTransfer(matchData.awayOwner, matchData.stake);
            emit MatchExpired(matchId);
            return;
        }

        uint8 homeTactic = matchData.homeSide.planRevealed
            ? CupMatchEngine.baseTactic(matchData.homeSide.plan)
            : CupMatchEngine.TACTIC_BALANCED;
        uint8 awayTactic = matchData.awaySide.planRevealed
            ? CupMatchEngine.baseTactic(matchData.awaySide.plan)
            : CupMatchEngine.TACTIC_BALANCED;

        bytes32 seed = keccak256(abi.encodePacked(matchData.entropy, kickoffHash, uint8(1)));
        CupMatchEngine.HalfResult memory h1 = CupMatchEngine.simulateHalf(
            CupMatchEngine.applyTactics(matchData.homeStrength, homeTactic, awayTactic),
            CupMatchEngine.applyTactics(matchData.awayStrength, awayTactic, homeTactic),
            seed,
            0,
            0,
            0,
            0
        );

        matchData.seed = seed;
        matchData.scoreHome = h1.goalsHome;
        matchData.scoreAway = h1.goalsAway;
        matchData.scoreHomeHT = h1.goalsHome;
        matchData.scoreAwayHT = h1.goalsAway;
        matchData.eventCount = h1.eventCount;
        matchData.packedEvents = h1.packedEvents;
        matchData.breakEndBlock = uint64(block.number + cs.config.halftimeBlocks);
        matchData.status = LibColonyCupStorage.MatchStatus.HalfTime;

        emit FirstHalfPlayed(matchId, h1.goalsHome, h1.goalsAway, matchData.breakEndBlock);
    }

    // ============ HALF-TIME OVERRIDE ============

    /**
     * @notice Override your second-half instruction during the break (open, optional)
     * @dev Deliberately NOT commit-reveal: both sides may react to what they see —
     *      touchline mind games. Last call before the break ends stands. An absent
     *      side falls back to the conditional rules of its revealed plan.
     * @param rule 12-bit rule shape (condition bits ignored): see CupMatchEngine
     */
    function setSecondHalfPlan(uint256 matchId, bytes32 colonyId, uint16 rule) external whenNotPaused {
        LibColonyCupStorage.CupStorage storage cs = LibColonyCupStorage.cupStorage();
        LibColonyCupStorage.CupMatch storage matchData = LibCupMatch.requireMatch(cs, matchId);
        LibCupMatch.requireStatus(matchData, matchId, LibColonyCupStorage.MatchStatus.HalfTime);
        if (block.number >= matchData.breakEndBlock) {
            revert BreakFinished(matchId, matchData.breakEndBlock);
        }

        (LibColonyCupStorage.SidePlan storage side, bool isHome) = _callerSide(matchData, matchId, colonyId);
        side.overrideRule = rule;
        side.overrideSet = true;

        emit SecondHalfPlanSet(matchId, isHome, rule);
    }

    // ============ SECOND HALF ============

    /**
     * @notice Resolve the second half after the break (anyone can call)
     * @dev Applies overrides, else conditional plan rules (incl. substitutions),
     *      else carries the base tactic. Past the play window the match settles
     *      at the half-time score — funds always move.
     */
    function playSecondHalf(uint256 matchId) external whenNotPaused nonReentrant {
        LibColonyCupStorage.CupStorage storage cs = LibColonyCupStorage.cupStorage();
        LibColonyCupStorage.CupMatch storage matchData = LibCupMatch.requireMatch(cs, matchId);
        LibCupMatch.requireStatus(matchData, matchId, LibColonyCupStorage.MatchStatus.HalfTime);
        if (block.number <= matchData.breakEndBlock) {
            revert BreakNotFinished(matchId, matchData.breakEndBlock);
        }

        bytes32 breakHash = blockhash(matchData.breakEndBlock);
        if (block.number > matchData.breakEndBlock + LibColonyCupStorage.KICKOFF_WINDOW_BLOCKS || breakHash == bytes32(0)) {
            // Window missed: half-time score becomes the final result
            _finalize(cs, matchData, matchId);
            return;
        }

        CupMatchEngine.HalfPlan memory homePlan = _resolveHalfPlan(matchData.homeSide, true, matchData);
        CupMatchEngine.HalfPlan memory awayPlan = _resolveHalfPlan(matchData.awaySide, false, matchData);

        CupMatchEngine.TeamStrength memory homeBase = _applySubstitution(matchData, true, homePlan);
        CupMatchEngine.TeamStrength memory awayBase = _applySubstitution(matchData, false, awayPlan);

        bytes32 seed2 = keccak256(abi.encodePacked(matchData.entropy, breakHash, uint8(2)));
        CupMatchEngine.HalfResult memory h2 = CupMatchEngine.simulateHalf(
            CupMatchEngine.applyTactics(homeBase, homePlan.tactic, awayPlan.tactic),
            CupMatchEngine.applyTactics(awayBase, awayPlan.tactic, homePlan.tactic),
            seed2,
            1,
            matchData.scoreHomeHT,
            matchData.scoreAwayHT,
            matchData.eventCount
        );

        matchData.scoreHome = matchData.scoreHomeHT + h2.goalsHome;
        matchData.scoreAway = matchData.scoreAwayHT + h2.goalsAway;
        matchData.packedEvents |= h2.packedEvents;
        matchData.eventCount += h2.eventCount;

        if (matchData.scoreHome == matchData.scoreAway) {
            matchData.status = LibColonyCupStorage.MatchStatus.AwaitingShootout;
            matchData.shootoutCommitEnd = uint64(block.number + cs.config.shootoutCommitBlocks);
            matchData.shootoutRevealEnd = matchData.shootoutCommitEnd + cs.config.shootoutRevealBlocks;
            emit ShootoutRequired(matchId, matchData.shootoutCommitEnd, matchData.shootoutRevealEnd);
            return;
        }

        _finalize(cs, matchData, matchId);
    }

    // ============ PENALTY SHOOTOUT ============

    /// @notice Commit penalty picks: keccak256(abi.encodePacked(picks, salt))
    function commitShootout(uint256 matchId, bytes32 colonyId, bytes32 commit) external whenNotPaused {
        LibColonyCupStorage.CupStorage storage cs = LibColonyCupStorage.cupStorage();
        LibColonyCupStorage.CupMatch storage matchData = LibCupMatch.requireMatch(cs, matchId);
        LibCupMatch.requireStatus(matchData, matchId, LibColonyCupStorage.MatchStatus.AwaitingShootout);
        if (block.number > matchData.shootoutCommitEnd) {
            revert ShootoutCommitClosed(matchId, matchData.shootoutCommitEnd);
        }
        if (commit == bytes32(0)) {
            revert PlanCommitRequired();
        }

        (LibColonyCupStorage.SidePlan storage side, bool isHome) = _callerSide(matchData, matchId, colonyId);
        side.shootoutCommit = commit;

        emit ShootoutCommitted(matchId, isHome);
    }

    /// @notice Reveal penalty picks (5 shots + 5 dives, 2 bits each)
    function revealShootout(uint256 matchId, bytes32 colonyId, uint32 picks, bytes32 salt) external whenNotPaused {
        LibColonyCupStorage.CupStorage storage cs = LibColonyCupStorage.cupStorage();
        LibColonyCupStorage.CupMatch storage matchData = LibCupMatch.requireMatch(cs, matchId);
        LibCupMatch.requireStatus(matchData, matchId, LibColonyCupStorage.MatchStatus.AwaitingShootout);
        if (block.number > matchData.shootoutRevealEnd) {
            revert ShootoutRevealClosed(matchId, matchData.shootoutRevealEnd);
        }

        (LibColonyCupStorage.SidePlan storage side, bool isHome) = _callerSide(matchData, matchId, colonyId);
        if (side.shootoutCommit == bytes32(0)) {
            revert ShootoutCommitMissing(matchId);
        }
        if (keccak256(abi.encodePacked(picks, salt)) != side.shootoutCommit) {
            revert InvalidShootoutReveal(matchId);
        }

        side.shootoutPicks = picks;
        side.shootoutRevealed = true;

        emit ShootoutRevealed(matchId, isHome);
    }

    /**
     * @notice Resolve the shootout (anyone) once both revealed or the window passed
     * @dev Unrevealed sides shoot/dive on seed-derived directions, so settlement
     *      never blocks. No blockhash dependency — resolvable forever.
     */
    function resolveShootout(uint256 matchId) external whenNotPaused nonReentrant {
        LibColonyCupStorage.CupStorage storage cs = LibColonyCupStorage.cupStorage();
        LibColonyCupStorage.CupMatch storage matchData = LibCupMatch.requireMatch(cs, matchId);
        LibCupMatch.requireStatus(matchData, matchId, LibColonyCupStorage.MatchStatus.AwaitingShootout);

        bool bothRevealed = matchData.homeSide.shootoutRevealed && matchData.awaySide.shootoutRevealed;
        if (!bothRevealed && block.number <= matchData.shootoutRevealEnd) {
            revert ShootoutNotResolvable(matchId, matchData.shootoutRevealEnd);
        }

        uint32 homePicks = matchData.homeSide.shootoutRevealed ? matchData.homeSide.shootoutPicks : type(uint32).max;
        uint32 awayPicks = matchData.awaySide.shootoutRevealed ? matchData.awaySide.shootoutPicks : type(uint32).max;

        bytes32 seed = keccak256(abi.encodePacked(matchData.entropy, uint8(3), matchData.scoreHome, matchData.scoreAway));
        (uint8 hg, uint8 ag, bool homeWins, uint32 packedKicks, uint8 rounds) =
            CupMatchEngine.simulateShootout(homePicks, awayPicks, seed);

        matchData.shootoutHomeGoals = hg;
        matchData.shootoutAwayGoals = ag;
        matchData.shootoutHomeWins = homeWins;
        matchData.shootoutPackedKicks = packedKicks;
        matchData.shootoutRounds = rounds;

        emit ShootoutResolved(matchId, hg, ag, homeWins, packedKicks, rounds);

        _finalize(cs, matchData, matchId);
    }

    // ============ INTERNALS ============

    function _requireColonyCreator(bytes32 colonyId) internal view {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        if (!ColonyHelper.isColonyCreator(colonyId, hs.stakingSystemAddress)) {
            revert AccessHelper.Unauthorized(LibMeta.msgSender(), "Not colony creator");
        }
    }

    /// @dev Sides are addressed EXPLICITLY by colonyId (not by sender) because one
    ///      wallet may own both colonies of a match; sender must own that side.
    function _callerSide(
        LibColonyCupStorage.CupMatch storage matchData,
        uint256 matchId,
        bytes32 colonyId
    ) internal view returns (LibColonyCupStorage.SidePlan storage side, bool isHome) {
        address sender = LibMeta.msgSender();
        if (colonyId == matchData.home && sender == matchData.homeOwner) {
            return (matchData.homeSide, true);
        }
        if (colonyId == matchData.away && sender == matchData.awayOwner) {
            return (matchData.awaySide, false);
        }
        revert NotMatchParticipant(matchId, sender);
    }

    /// @dev Override (if set) beats conditional plan rules beats base tactic
    function _resolveHalfPlan(
        LibColonyCupStorage.SidePlan storage side,
        bool isHome,
        LibColonyCupStorage.CupMatch storage matchData
    ) internal view returns (CupMatchEngine.HalfPlan memory hp) {
        if (side.overrideSet) {
            return CupMatchEngine.decodeRule(side.overrideRule);
        }
        if (side.planRevealed) {
            int16 diff = isHome
                ? int16(uint16(matchData.scoreHomeHT)) - int16(uint16(matchData.scoreAwayHT))
                : int16(uint16(matchData.scoreAwayHT)) - int16(uint16(matchData.scoreHomeHT));
            return CupMatchEngine.secondHalfPlan(side.plan, diff);
        }
        hp.tactic = CupMatchEngine.TACTIC_BALANCED;
    }

    /// @dev Swap a squad slot from the bench (skipped silently if the bench token
    ///      left the colony — substitutions never brick the match) and recompute
    ///      strength when the squad actually changed.
    function _applySubstitution(
        LibColonyCupStorage.CupMatch storage matchData,
        bool isHome,
        CupMatchEngine.HalfPlan memory hp
    ) internal returns (CupMatchEngine.TeamStrength memory strength) {
        strength = isHome ? matchData.homeStrength : matchData.awayStrength;
        if (!hp.subActive) {
            return strength;
        }

        uint256 benchToken = isHome ? matchData.homeBench[hp.benchIdx] : matchData.awayBench[hp.benchIdx];
        bytes32 colonyId = isHome ? matchData.home : matchData.away;
        if (benchToken == 0 || !LibCupMatch.isInColony(benchToken, colonyId)) {
            return strength;
        }

        uint256[5] memory squad = isHome ? matchData.homeSquad : matchData.awaySquad;
        squad[hp.subSlot] = benchToken;
        strength = LibCupMatch.computeStrength(squad);

        // Persist the swapped squad so scorer attribution follows the field
        if (isHome) {
            matchData.homeSquad = squad;
        } else {
            matchData.awaySquad = squad;
        }
    }

    /// @dev Final whistle: table, golden boot, stake settlement, MatchPlayed
    function _finalize(
        LibColonyCupStorage.CupStorage storage cs,
        LibColonyCupStorage.CupMatch storage matchData,
        uint256 matchId
    ) internal {
        uint8 outcomeCode;
        if (matchData.scoreHome > matchData.scoreAway) {
            outcomeCode = 0;
        } else if (matchData.scoreHome < matchData.scoreAway) {
            outcomeCode = 1;
        } else if (matchData.status == LibColonyCupStorage.MatchStatus.AwaitingShootout) {
            outcomeCode = matchData.shootoutHomeWins ? 0 : 1;
        } else {
            outcomeCode = 2;
        }

        matchData.status = LibColonyCupStorage.MatchStatus.Played;

        LibCupMatch.applyTable(cs, matchData, outcomeCode);
        LibCupMatch.applyScorers(cs, matchData);
        LibCupMatch.settleStakes(cs, matchData, outcomeCode);

        emit MatchPlayed(
            matchId,
            matchData.home,
            matchData.away,
            matchData.scoreHome,
            matchData.scoreAway,
            matchData.seed,
            matchData.packedEvents,
            matchData.eventCount,
            false
        );
    }
}
