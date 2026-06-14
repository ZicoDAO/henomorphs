// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {CupMatchEngine} from "../diamonds/chargepod/libraries/CupMatchEngine.sol";

/**
 * @title CupMatchEngineHarness
 * @notice TEST-ONLY wrapper exposing the internal CupMatchEngine v2 for unit tests
 *         and Sol<->TS parity fixture generation. NEVER cut into the Diamond.
 */
contract CupMatchEngineHarness {

    function applyTactics(
        CupMatchEngine.TeamStrength calldata s,
        uint8 mine,
        uint8 opponent
    ) external pure returns (CupMatchEngine.TeamStrength memory) {
        return CupMatchEngine.applyTactics(s, mine, opponent);
    }

    function simulateHalf(
        CupMatchEngine.TeamStrength calldata home,
        CupMatchEngine.TeamStrength calldata away,
        bytes32 seed,
        uint8 halfIndex,
        uint8 curHome,
        uint8 curAway,
        uint8 prevEventCount
    ) external pure returns (CupMatchEngine.HalfResult memory) {
        return CupMatchEngine.simulateHalf(home, away, seed, halfIndex, curHome, curAway, prevEventCount);
    }

    /// @notice Full-match convenience for tests: tactics + two halves with rules
    function simulateRanked(
        CupMatchEngine.TeamStrength calldata home,
        CupMatchEngine.TeamStrength calldata away,
        uint256 homePlan,
        uint256 awayPlan,
        bytes32 seed1,
        bytes32 seed2
    )
        external
        pure
        returns (uint8 scoreHome, uint8 scoreAway, uint8 eventCount, uint256 packedEvents)
    {
        uint8 hT = CupMatchEngine.baseTactic(homePlan);
        uint8 aT = CupMatchEngine.baseTactic(awayPlan);

        CupMatchEngine.HalfResult memory h1 = CupMatchEngine.simulateHalf(
            CupMatchEngine.applyTactics(home, hT, aT),
            CupMatchEngine.applyTactics(away, aT, hT),
            seed1,
            0,
            0,
            0,
            0
        );

        CupMatchEngine.HalfPlan memory hp = CupMatchEngine.secondHalfPlan(
            homePlan,
            int16(uint16(h1.goalsHome)) - int16(uint16(h1.goalsAway))
        );
        CupMatchEngine.HalfPlan memory ap = CupMatchEngine.secondHalfPlan(
            awayPlan,
            int16(uint16(h1.goalsAway)) - int16(uint16(h1.goalsHome))
        );

        CupMatchEngine.HalfResult memory h2 = CupMatchEngine.simulateHalf(
            CupMatchEngine.applyTactics(home, hp.tactic, ap.tactic),
            CupMatchEngine.applyTactics(away, ap.tactic, hp.tactic),
            seed2,
            1,
            h1.goalsHome,
            h1.goalsAway,
            h1.eventCount
        );

        scoreHome = h1.goalsHome + h2.goalsHome;
        scoreAway = h1.goalsAway + h2.goalsAway;
        eventCount = h1.eventCount + h2.eventCount;
        packedEvents = h1.packedEvents | h2.packedEvents;
    }

    function baseTactic(uint256 plan) external pure returns (uint8) {
        return CupMatchEngine.baseTactic(plan);
    }

    function secondHalfPlan(uint256 plan, int16 goalDiff)
        external
        pure
        returns (CupMatchEngine.HalfPlan memory)
    {
        return CupMatchEngine.secondHalfPlan(plan, goalDiff);
    }

    function decodeRule(uint16 rule) external pure returns (CupMatchEngine.HalfPlan memory) {
        return CupMatchEngine.decodeRule(rule);
    }

    function simulateShootout(
        uint32 homePicks,
        uint32 awayPicks,
        bytes32 seed
    ) external pure returns (uint8 homeGoals, uint8 awayGoals, bool homeWins, uint32 packedKicks, uint8 rounds) {
        return CupMatchEngine.simulateShootout(homePicks, awayPicks, seed);
    }

    function unpackEvent(
        uint256 packedEvents,
        uint8 index
    ) external pure returns (uint8 minute, bool isHome, uint8 scorerSlot) {
        return CupMatchEngine.unpackEvent(packedEvents, index);
    }
}
