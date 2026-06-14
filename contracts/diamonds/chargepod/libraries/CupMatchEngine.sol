// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/**
 * @title CupMatchEngine
 * @notice Deterministic football match simulation for Colony Cup — v2
 * @dev Pure library: identical inputs -> identical result, always. The mobile app
 *      re-runs plan decoding and replays goal events from on-chain data, so ANY
 *      change to the math here is a breaking protocol change for the client.
 *      Keep in lockstep with the TS port and the Sol<->TS parity fixture.
 *
 *      v2 additions (MATCH PLAN pattern):
 *      - tactics with a soft counter triangle (applyTactics)
 *      - two-half simulation (simulateHalf) so plans can change at the break
 *      - plan-card decoding (baseTactic / secondHalfPlan) — first matching
 *        conditional rule wins
 *      - penalty shootout (simulateShootout) for drawn ranked matches
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 */
library CupMatchEngine {

    // ============================================================
    // CONSTANTS (calibration)
    // ============================================================

    /// @dev Per-half chance budget: HALF_BASE + totalMid/MID_PER_EXTRA, capped.
    ///      Calibration matches v1's 6 + mid/100 cap 14 over 90 minutes.
    uint8 internal constant HALF_BASE_CHANCES = 3;
    uint8 internal constant MAX_HALF_CHANCES = 7;
    uint16 internal constant MID_PER_EXTRA_CHANCE = 200;
    uint8 internal constant MIN_GOAL_PCT = 8;
    uint8 internal constant MAX_GOAL_PCT = 65;
    uint8 internal constant MAX_GOALS_PER_SIDE = 7;

    /// @dev roll domains for keccak(seed, domain, index) — keep unique per purpose
    uint8 internal constant DOMAIN_SIDE = 0;
    uint8 internal constant DOMAIN_GOAL = 1;
    uint8 internal constant DOMAIN_MINUTE = 2;
    uint8 internal constant DOMAIN_SCORER = 3;
    uint8 internal constant DOMAIN_SHOOTOUT = 4;

    // ============================================================
    // TACTICS
    // ============================================================

    uint8 internal constant TACTIC_BALANCED = 0;
    uint8 internal constant TACTIC_ALLOUT = 1;   // NAWALNICA: att +20%, def -15%
    uint8 internal constant TACTIC_BUS = 2;      // AUTOBUS:   def +25%, att -20%
    uint8 internal constant TACTIC_PRESSING = 3; // PRESSING:  mid +20%

    /// @dev Counter-triangle bonus applied to att+mid of the side whose tactic
    ///      beats the opponent's: ALLOUT > PRESSING > BUS > ALLOUT.
    uint8 internal constant COUNTER_BONUS_PCT = 10;

    // ============================================================
    // TYPES
    // ============================================================

    /// @notice Aggregated positional strength of a 5-chick squad
    /// @dev def is the SUM of both defender slots; values are WarfareHelper-style
    ///      token powers (~75-400 each) after the out-of-position multiplier.
    struct TeamStrength {
        uint32 gk;
        uint32 def;
        uint32 mid;
        uint32 att;
    }

    /// @notice Result of one simulated half
    /// @dev Goal events are packed 11 bits each, OFFSET by the caller-provided
    ///      event count: [minute:7][isHome:1][scorerSlot:3]
    struct HalfResult {
        uint8 goalsHome;
        uint8 goalsAway;
        uint8 eventCount;      // events added THIS half
        uint256 packedEvents;  // already shifted to start at prevEventCount*11
    }

    /// @notice Decoded second-half instruction from a plan card
    struct HalfPlan {
        uint8 tactic;
        bool subActive;
        uint8 subSlot;   // squad slot 0..4 to replace
        uint8 benchIdx;  // bench slot 0..1 coming in
    }

    // ============================================================
    // PLAN CARD
    // ============================================================
    // Plan layout (uint256):
    //   bits [0..1]    base tactic
    //   bits [8+i*12 .. 19+i*12] for i in 0..2 — conditional rule i:
    //     bit 0     active
    //     bits 1-2  condition: 0=losing, 1=drawing, 2=winning (at half time)
    //     bits 3-4  tactic for the second half
    //     bit 5     substitution active
    //     bits 6-8  squad slot going off (0..4)
    //     bit 9     bench index coming on (0..1)
    //     bits 10-11 reserved
    // First active rule whose condition matches the half-time score wins.

    function baseTactic(uint256 plan) internal pure returns (uint8) {
        return uint8(plan & 0x3);
    }

    /**
     * @notice Resolve the second-half instruction for one side
     * @param plan The side's revealed plan card (0 = balanced, no rules)
     * @param goalDiff Half-time goal difference FROM THIS SIDE'S PERSPECTIVE
     */
    function secondHalfPlan(uint256 plan, int16 goalDiff) internal pure returns (HalfPlan memory hp) {
        hp.tactic = baseTactic(plan);
        for (uint256 i = 0; i < 3; i++) {
            uint256 rule = (plan >> (8 + i * 12)) & 0xFFF;
            if (rule & 1 == 0) continue;
            uint256 cond = (rule >> 1) & 0x3;
            bool matches =
                (cond == 0 && goalDiff < 0) ||
                (cond == 1 && goalDiff == 0) ||
                (cond == 2 && goalDiff > 0);
            if (!matches) continue;
            hp = decodeRule(uint16(rule));
            break;
        }
    }

    /// @notice Decode a single 12-bit rule (also used for half-time overrides)
    function decodeRule(uint16 rule) internal pure returns (HalfPlan memory hp) {
        hp.tactic = uint8((rule >> 3) & 0x3);
        hp.subActive = (rule >> 5) & 1 == 1;
        hp.subSlot = uint8((rule >> 6) & 0x7);
        if (hp.subSlot > 4) hp.subActive = false;
        hp.benchIdx = uint8((rule >> 9) & 0x1);
    }

    // ============================================================
    // TACTICS APPLICATION
    // ============================================================

    /// @notice Apply a side's tactic + the counter-triangle bonus vs the opponent
    function applyTactics(
        TeamStrength memory s,
        uint8 mine,
        uint8 opponent
    ) internal pure returns (TeamStrength memory out) {
        out = TeamStrength(s.gk, s.def, s.mid, s.att);

        if (mine == TACTIC_ALLOUT) {
            out.att = uint32((uint256(out.att) * 120) / 100);
            out.def = uint32((uint256(out.def) * 85) / 100);
        } else if (mine == TACTIC_BUS) {
            out.def = uint32((uint256(out.def) * 125) / 100);
            out.att = uint32((uint256(out.att) * 80) / 100);
        } else if (mine == TACTIC_PRESSING) {
            out.mid = uint32((uint256(out.mid) * 120) / 100);
        }

        if (_beats(mine, opponent)) {
            out.att = uint32((uint256(out.att) * (100 + COUNTER_BONUS_PCT)) / 100);
            out.mid = uint32((uint256(out.mid) * (100 + COUNTER_BONUS_PCT)) / 100);
        }
    }

    /// @dev Soft counter triangle: ALLOUT > PRESSING > BUS > ALLOUT
    function _beats(uint8 mine, uint8 opponent) private pure returns (bool) {
        return
            (mine == TACTIC_ALLOUT && opponent == TACTIC_PRESSING) ||
            (mine == TACTIC_PRESSING && opponent == TACTIC_BUS) ||
            (mine == TACTIC_BUS && opponent == TACTIC_ALLOUT);
    }

    // ============================================================
    // HALF SIMULATION
    // ============================================================

    /**
     * @notice Simulate one half (45 minutes) with tactic-adjusted strengths
     * @param home Tactic-adjusted home strength for THIS half
     * @param away Tactic-adjusted away strength for THIS half
     * @param seed Half-specific seed (halves use independent seeds)
     * @param halfIndex 0 = first half (minutes 1-45), 1 = second (46-90)
     * @param curHome Cumulative home score before this half (goal cap)
     * @param curAway Cumulative away score before this half
     * @param prevEventCount Events already packed (offset for this half's events)
     */
    function simulateHalf(
        TeamStrength memory home,
        TeamStrength memory away,
        bytes32 seed,
        uint8 halfIndex,
        uint8 curHome,
        uint8 curAway,
        uint8 prevEventCount
    ) internal pure returns (HalfResult memory r) {
        uint256 totalMid = uint256(home.mid) + uint256(away.mid);

        uint256 chances = uint256(HALF_BASE_CHANCES) + totalMid / MID_PER_EXTRA_CHANCE;
        if (chances > MAX_HALF_CHANCES) chances = MAX_HALF_CHANCES;

        uint8 scoreHome = curHome;
        uint8 scoreAway = curAway;

        for (uint256 i = 0; i < chances; i++) {
            bool isHome;
            if (totalMid == 0) {
                isHome = _roll(seed, DOMAIN_SIDE, i) % 2 == 0;
            } else {
                isHome = _roll(seed, DOMAIN_SIDE, i) % totalMid < home.mid;
            }

            uint256 att = isHome ? home.att : away.att;
            uint256 def = isHome ? away.def : home.def;
            uint256 gk = isHome ? away.gk : home.gk;

            uint256 denom = att + def / 2 + gk;
            uint256 goalPct = denom == 0 ? MIN_GOAL_PCT : (att * 100) / denom;
            if (goalPct < MIN_GOAL_PCT) goalPct = MIN_GOAL_PCT;
            if (goalPct > MAX_GOAL_PCT) goalPct = MAX_GOAL_PCT;

            if (_roll(seed, DOMAIN_GOAL, i) % 100 >= goalPct) {
                continue;
            }
            if (isHome && scoreHome >= MAX_GOALS_PER_SIDE) continue;
            if (!isHome && scoreAway >= MAX_GOALS_PER_SIDE) continue;

            uint16 packed = _packEvent(seed, i, chances, halfIndex, isHome);
            r.packedEvents |= uint256(packed) << (uint256(prevEventCount + r.eventCount) * 11);
            r.eventCount++;
            if (isHome) {
                r.goalsHome++;
                scoreHome++;
            } else {
                r.goalsAway++;
                scoreAway++;
            }
        }
    }

    /**
     * @notice Unpack a single goal event
     */
    function unpackEvent(
        uint256 packedEvents,
        uint8 index
    ) internal pure returns (uint8 minute, bool isHome, uint8 scorerSlot) {
        uint256 raw = (packedEvents >> (uint256(index) * 11)) & 0x7FF;
        minute = uint8(raw >> 4);
        isHome = (raw >> 3) & 1 == 1;
        scorerSlot = uint8(raw & 0x7);
    }

    // ============================================================
    // PENALTY SHOOTOUT
    // ============================================================
    // picks layout (uint32): 5 shot directions at bits [0..9] (2 bits each),
    // 5 dive directions at bits [10..19]. Direction 0/1/2 = left/center/right;
    // value 3 (or an unrevealed pack) falls back to a seed-derived direction.
    // A kick scores when the shot direction differs from the keeper's dive.
    // 5 rounds, then sudden death from the seed; hard cap 10 rounds, then the
    // seed flips a coin so settlement can never be blocked.

    function simulateShootout(
        uint32 homePicks,
        uint32 awayPicks,
        bytes32 seed
    ) internal pure returns (uint8 homeGoals, uint8 awayGoals, bool homeWins, uint32 packedKicks, uint8 rounds) {
        for (uint8 r = 0; r < 10; r++) {
            uint8 homeShot = _direction(homePicks, r, false, seed, r * 4);
            uint8 awayDive = _direction(awayPicks, r, true, seed, r * 4 + 1);
            bool homeScored = homeShot != awayDive;

            uint8 awayShot = _direction(awayPicks, r, false, seed, r * 4 + 2);
            uint8 homeDive = _direction(homePicks, r, true, seed, r * 4 + 3);
            bool awayScored = awayShot != homeDive;

            if (homeScored) {
                homeGoals++;
                packedKicks |= uint32(1) << (r * 2);
            }
            if (awayScored) {
                awayGoals++;
                packedKicks |= uint32(1) << (r * 2 + 1);
            }
            rounds = r + 1;

            if (r >= 4 && homeGoals != awayGoals) {
                homeWins = homeGoals > awayGoals;
                return (homeGoals, awayGoals, homeWins, packedKicks, rounds);
            }
        }
        // Still level after 10 rounds — seed coin flip, settlement must finish
        homeWins = _roll(seed, DOMAIN_SHOOTOUT, 99) % 2 == 0;
    }

    /// @dev Pick for round r: rounds 0-4 read the player's pack, sudden death
    ///      (5+) and invalid/unset picks come from the seed.
    function _direction(
        uint32 picks,
        uint8 round,
        bool isDive,
        bytes32 seed,
        uint256 rollIndex
    ) private pure returns (uint8 dir) {
        if (round < 5) {
            // dives occupy bit positions 10..19 -> slot index = round + 5
            uint8 offset = isDive ? 5 : 0;
            dir = uint8((picks >> ((round + offset) * 2)) & 0x3);
            if (dir <= 2) return dir;
        }
        dir = uint8(_roll(seed, DOMAIN_SHOOTOUT, rollIndex) % 3);
    }

    // ============================================================
    // INTERNALS
    // ============================================================

    /// @dev Chance index maps to a 45-minute window so goals come out chronological
    function _packEvent(
        bytes32 seed,
        uint256 chanceIndex,
        uint256 totalChances,
        uint8 halfIndex,
        bool isHome
    ) private pure returns (uint16 packed) {
        uint256 window = 45 / totalChances;
        if (window == 0) window = 1;
        uint256 minute = 1 + (chanceIndex * 45) / totalChances + _roll(seed, DOMAIN_MINUTE, chanceIndex) % window;
        if (minute > 45) minute = 45;
        minute += uint256(halfIndex) * 45;

        uint8 scorerSlot = _pickScorer(_roll(seed, DOMAIN_SCORER, chanceIndex) % 100);
        packed = uint16((minute << 4) | ((isHome ? 1 : 0) << 3) | scorerSlot);
    }

    /// @dev Scorer weights: ATT 60%, MID 25%, DEF 7%+7%, GK 1% (screamer)
    ///      Squad layout: [0]=GK, [1]=DEF, [2]=DEF, [3]=MID, [4]=ATT
    function _pickScorer(uint256 roll) private pure returns (uint8 slot) {
        if (roll < 60) return 4;
        if (roll < 85) return 3;
        if (roll < 92) return 1;
        if (roll < 99) return 2;
        return 0;
    }

    function _roll(bytes32 seed, uint8 domain, uint256 index) private pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(seed, domain, uint8(index))));
    }
}
