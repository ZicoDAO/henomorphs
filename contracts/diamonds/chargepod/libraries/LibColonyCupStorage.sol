// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {CupMatchEngine} from "./CupMatchEngine.sol";

/**
 * @title LibColonyCupStorage
 * @notice Storage library for Colony Cup (football match mode, "FIFA 2026 edition") — v2
 * @dev Uses Diamond Storage pattern with its OWN unique slot. Deliberately does NOT
 *      extend ColonyWarsStorage — the cup is a complementary mode with an independent
 *      season/registration lifecycle, and a dedicated slot makes layout drift impossible.
 *
 *      v2 (MATCH PLAN pattern): plan-card commits at challenge/accept, two-half play
 *      with a half-time break, 5+2 bench, open half-time overrides, penalty shootout
 *      for drawn ranked matches, optional scheduled kickoff. Nothing was deployed on
 *      v1 layout, so structs are extended freely under the same slot.
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 */
library LibColonyCupStorage {
    bytes32 constant COLONY_CUP_STORAGE_POSITION = keccak256("henomorphs.colonycup.storage.v1");

    // ============================================================
    // CONSTANTS
    // ============================================================

    uint8 constant SQUAD_SIZE = 5;
    uint8 constant BENCH_SIZE = 2;
    /// @dev Squad slot layout: [0]=GK, [1]=DEF, [2]=DEF, [3]=MID, [4]=ATT
    uint8 constant SLOT_GK = 0;
    uint8 constant SLOT_DEF_A = 1;
    uint8 constant SLOT_DEF_B = 2;
    uint8 constant SLOT_MID = 3;
    uint8 constant SLOT_ATT = 4;

    /// @dev Each half must be resolved within this many blocks of becoming playable
    ///      or the match falls to its expiry path (blockhash window is 256).
    uint16 constant KICKOFF_WINDOW_BLOCKS = 250;

    /// @dev A scheduled kickoff may be at most ~1 week ahead (Polygon ~2s blocks).
    uint32 constant MAX_SCHEDULE_AHEAD_BLOCKS = 302400;

    /// @dev Out-of-position penalty applied to a token's contribution (percent kept).
    uint8 constant OFF_POSITION_FACTOR = 75;

    // ============================================================
    // ENUMS
    // ============================================================

    enum MatchStatus {
        None,             // 0 - not created
        Pending,          // 1 - challenge issued, waiting for opponent stake
        Scheduled,        // 2 - both staked, plans committed, waiting for kickoff
        HalfTime,         // 3 - first half resolved, break window open
        AwaitingShootout, // 4 - drawn ranked match, penalty commit/reveal pending
        Played,           // 5 - result final
        Expired,          // 6 - kickoff window missed, stakes refunded
        Cancelled         // 7 - challenge cancelled/expired before accept, stake refunded
    }

    // ============================================================
    // STRUCTS
    // ============================================================

    struct CupConfig {
        uint128 minStake;            // ranked stake bounds (treasury currency, ZICO)
        uint128 maxStake;
        uint32 challengeTimeout;     // seconds a pending challenge stays acceptable
        uint16 kickoffDelayBlocks;   // minimum blocks between accept and kickoff
        uint16 dailyMatchLimit;      // matches a colony may start/accept per UTC day
        uint32 pairCooldown;         // seconds between ranked matches of the same pair
        uint16 feeBps;               // pot cut routed to the season reward pool
        uint16 halftimeBlocks;       // break length: override window for both sides
        uint16 shootoutCommitBlocks; // window to commit penalty picks
        uint16 shootoutRevealBlocks; // window to reveal penalty picks
        bool enabled;
    }

    struct TeamSheet {
        uint256[SQUAD_SIZE] tokens;  // combined IDs, slot layout per SLOT_* constants
        uint256[BENCH_SIZE] bench;   // combined IDs, 0 = empty bench slot
        bytes3 kitPrimary;
        bytes3 kitSecondary;
        uint8 kitPattern;            // 0=solid, 1=stripes, 2=hoops
        uint32 seasonId;
        uint64 registeredAt;
        bool active;
    }

    /// @dev Per-side interactive state of a ranked match
    struct SidePlan {
        bytes32 planCommit;          // keccak256(plan, salt), locked at challenge/accept
        uint256 plan;                // revealed plan card (see CupMatchEngine layout)
        bool planRevealed;
        uint16 overrideRule;         // open half-time override (12-bit rule shape)
        bool overrideSet;
        bytes32 shootoutCommit;      // keccak256(picks, salt)
        uint32 shootoutPicks;
        bool shootoutRevealed;
    }

    struct CupMatch {
        uint32 seasonId;
        bytes32 home;                // challenger colony
        bytes32 away;
        address homeOwner;           // payout/refund targets captured at stake time
        address awayOwner;
        uint128 stake;               // per side; 0 for friendlies
        uint64 createdAt;
        uint64 kickoffBlock;         // 0 until accepted
        uint64 desiredKickoffBlock;  // challenger-proposed scheduled kickoff (0 = ASAP)
        uint64 breakEndBlock;        // set when the first half resolves
        uint64 shootoutCommitEnd;    // block deadlines for the shootout phases
        uint64 shootoutRevealEnd;
        MatchStatus status;
        bool friendly;
        uint8 scoreHome;             // running, then final
        uint8 scoreAway;
        uint8 scoreHomeHT;           // half-time snapshot (conditional rules + UI)
        uint8 scoreAwayHT;
        bytes32 entropy;             // committed at accept, mixed with phase blockhashes
        bytes32 seed;                // first-half seed (set when first half plays)
        uint8 eventCount;
        uint256 packedEvents;        // CupMatchEngine packing, 11 bits per goal
        uint256[SQUAD_SIZE] homeSquad; // squad snapshots for scorer attribution
        uint256[SQUAD_SIZE] awaySquad; // (second half may swap one slot from bench)
        uint256[BENCH_SIZE] homeBench; // bench snapshots taken at accept
        uint256[BENCH_SIZE] awayBench;
        CupMatchEngine.TeamStrength homeStrength; // base strengths at accept
        CupMatchEngine.TeamStrength awayStrength;
        SidePlan homeSide;
        SidePlan awaySide;
        uint8 shootoutHomeGoals;
        uint8 shootoutAwayGoals;
        uint32 shootoutPackedKicks;  // 2 bits per round: home bit, away bit
        uint8 shootoutRounds;
        bool shootoutHomeWins;
    }

    struct TableRow {
        uint16 played;
        uint16 wins;
        uint16 draws;
        uint16 losses;
        uint32 goalsFor;
        uint32 goalsAgainst;
        uint32 points;               // 3/1/0; shootout win counts as a win
    }

    struct SeasonSchedule {
        string name;                 // championship display name shown in the app
        uint64 startsAt;             // unix start of play; 0 = in play immediately
        uint64 endsAt;               // unix scheduled end; 0 = open until endCupSeason
    }

    struct CupStorage {
        bool initialized;
        uint32 currentSeason;
        CupConfig config;

        // Teams & participation (keyed by cup season)
        mapping(uint32 => mapping(bytes32 => TeamSheet)) teams;
        mapping(uint32 => bytes32[]) participants;

        // Matches
        uint256 matchCounter;
        mapping(uint256 => CupMatch) matches;
        mapping(uint32 => mapping(bytes32 => uint256[])) colonyMatches; // season => colony => match ids

        // League table
        mapping(uint32 => mapping(bytes32 => TableRow)) table;

        // Golden boot
        mapping(uint32 => mapping(uint256 => uint16)) goalsByToken;     // season => combinedId => goals
        mapping(uint32 => uint256[]) seasonScorers;                     // season => combinedIds with >=1 goal

        // Anti-farming
        mapping(bytes32 => mapping(uint32 => uint16)) matchesOnDay;     // colony => dayId => count
        mapping(bytes32 => uint64) pairLastMatch;                       // pairKey => last ranked match timestamp

        // Season rewards (funds stay escrowed in the Diamond)
        mapping(uint32 => uint256) seasonPool;                          // accumulated fee cuts
        mapping(uint32 => uint64) seasonEndTime;                        // 0 while season open
        mapping(uint32 => uint256) seasonAllocatedTotal;
        mapping(uint32 => mapping(bytes32 => uint256)) seasonAllocations;
        mapping(uint32 => mapping(bytes32 => uint256)) seasonClaimed;

        // Season identity & schedule (appended — keep layout append-only)
        mapping(uint32 => SeasonSchedule) seasonSchedule;
    }

    // ============================================================
    // ACCESS
    // ============================================================

    function cupStorage() internal pure returns (CupStorage storage cs) {
        bytes32 position = COLONY_CUP_STORAGE_POSITION;
        assembly {
            cs.slot := position
        }
    }

    // ============================================================
    // HELPERS
    // ============================================================

    /// @notice Order-independent key for a colony pair (cooldown tracking)
    function pairKey(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    /// @notice UTC day bucket for daily match limits
    function dayId() internal view returns (uint32) {
        return uint32(block.timestamp / 1 days);
    }
}
