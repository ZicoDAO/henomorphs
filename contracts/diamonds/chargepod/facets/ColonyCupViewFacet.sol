// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibColonyCupStorage} from "../libraries/LibColonyCupStorage.sol";

/**
 * @title ColonyCupViewFacet
 * @notice Read-side of Colony Cup: league table, fixtures, teams, top scorers
 * @dev Table/scorer lists are returned unsorted with pagination; clients sort.
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 */
contract ColonyCupViewFacet {

    struct TableEntry {
        bytes32 colonyId;
        LibColonyCupStorage.TableRow row;
    }

    struct ScorerEntry {
        uint256 combinedId;
        uint16 goals;
    }

    struct CupSeasonInfo {
        uint32 seasonId;
        bool initialized;
        bool enabled;
        uint64 endTime;          // 0 while season open (actual close)
        uint256 participantCount;
        uint256 rewardPool;
        uint256 allocatedTotal;
        string name;             // championship display name
        uint64 startsAt;         // scheduled start of play; 0 = immediate
        uint64 endsAt;           // scheduled end; 0 = open-ended
    }

    // ============ CONFIG / SEASON ============

    function getCupConfig() external view returns (LibColonyCupStorage.CupConfig memory config, bool initialized) {
        LibColonyCupStorage.CupStorage storage cs = LibColonyCupStorage.cupStorage();
        return (cs.config, cs.initialized);
    }

    function getCurrentCupSeason() external view returns (CupSeasonInfo memory info) {
        LibColonyCupStorage.CupStorage storage cs = LibColonyCupStorage.cupStorage();
        return _seasonInfo(cs, cs.currentSeason);
    }

    function getCupSeasonInfo(uint32 seasonId) external view returns (CupSeasonInfo memory info) {
        LibColonyCupStorage.CupStorage storage cs = LibColonyCupStorage.cupStorage();
        return _seasonInfo(cs, seasonId);
    }

    function _seasonInfo(
        LibColonyCupStorage.CupStorage storage cs,
        uint32 seasonId
    ) private view returns (CupSeasonInfo memory info) {
        LibColonyCupStorage.SeasonSchedule storage sched = cs.seasonSchedule[seasonId];
        info = CupSeasonInfo({
            seasonId: seasonId,
            initialized: cs.initialized,
            enabled: cs.config.enabled,
            endTime: cs.seasonEndTime[seasonId],
            participantCount: cs.participants[seasonId].length,
            rewardPool: cs.seasonPool[seasonId],
            allocatedTotal: cs.seasonAllocatedTotal[seasonId],
            name: sched.name,
            startsAt: sched.startsAt,
            endsAt: sched.endsAt
        });
    }

    // ============ TEAMS ============

    function getCupTeam(uint32 seasonId, bytes32 colonyId)
        external
        view
        returns (LibColonyCupStorage.TeamSheet memory team)
    {
        return LibColonyCupStorage.cupStorage().teams[seasonId][colonyId];
    }

    /// @notice Paginated list of colonies with a registered team this season
    function getCupParticipants(uint32 seasonId, uint256 offset, uint256 limit)
        external
        view
        returns (bytes32[] memory colonyIds, uint256 total)
    {
        bytes32[] storage participants = LibColonyCupStorage.cupStorage().participants[seasonId];
        total = participants.length;
        colonyIds = new bytes32[](_sliceLength(total, offset, limit));
        for (uint256 i = 0; i < colonyIds.length; i++) {
            colonyIds[i] = participants[offset + i];
        }
    }

    // ============ MATCHES ============

    function getCupMatch(uint256 matchId) external view returns (LibColonyCupStorage.CupMatch memory matchData) {
        return LibColonyCupStorage.cupStorage().matches[matchId];
    }

    function getCupMatchCount() external view returns (uint256) {
        return LibColonyCupStorage.cupStorage().matchCounter;
    }

    /// @notice All match ids of a colony in a season (challenges, friendlies, played)
    function getColonyCupMatches(uint32 seasonId, bytes32 colonyId)
        external
        view
        returns (uint256[] memory matchIds)
    {
        return LibColonyCupStorage.cupStorage().colonyMatches[seasonId][colonyId];
    }

    // ============ LEAGUE TABLE ============

    /// @notice Paginated, UNSORTED league table — clients sort by points/GD
    function getLeagueTable(uint32 seasonId, uint256 offset, uint256 limit)
        external
        view
        returns (TableEntry[] memory entries, uint256 total)
    {
        LibColonyCupStorage.CupStorage storage cs = LibColonyCupStorage.cupStorage();
        bytes32[] storage participants = cs.participants[seasonId];
        total = participants.length;

        entries = new TableEntry[](_sliceLength(total, offset, limit));
        for (uint256 i = 0; i < entries.length; i++) {
            bytes32 colonyId = participants[offset + i];
            entries[i] = TableEntry({colonyId: colonyId, row: cs.table[seasonId][colonyId]});
        }
    }

    function getTableRow(uint32 seasonId, bytes32 colonyId)
        external
        view
        returns (LibColonyCupStorage.TableRow memory row)
    {
        return LibColonyCupStorage.cupStorage().table[seasonId][colonyId];
    }

    // ============ GOLDEN BOOT ============

    /// @notice Paginated, UNSORTED scorer list — clients sort by goals
    function getTopScorers(uint32 seasonId, uint256 offset, uint256 limit)
        external
        view
        returns (ScorerEntry[] memory entries, uint256 total)
    {
        LibColonyCupStorage.CupStorage storage cs = LibColonyCupStorage.cupStorage();
        uint256[] storage scorers = cs.seasonScorers[seasonId];
        total = scorers.length;

        entries = new ScorerEntry[](_sliceLength(total, offset, limit));
        for (uint256 i = 0; i < entries.length; i++) {
            uint256 combinedId = scorers[offset + i];
            entries[i] = ScorerEntry({combinedId: combinedId, goals: cs.goalsByToken[seasonId][combinedId]});
        }
    }

    function getTokenGoals(uint32 seasonId, uint256 combinedId) external view returns (uint16) {
        return LibColonyCupStorage.cupStorage().goalsByToken[seasonId][combinedId];
    }

    // ============ LIMITS / REWARDS ============

    function getDailyMatchesUsed(bytes32 colonyId) external view returns (uint16 used, uint16 limit) {
        LibColonyCupStorage.CupStorage storage cs = LibColonyCupStorage.cupStorage();
        return (cs.matchesOnDay[colonyId][LibColonyCupStorage.dayId()], cs.config.dailyMatchLimit);
    }

    function getPairCooldown(bytes32 colonyA, bytes32 colonyB) external view returns (uint64 availableAt) {
        LibColonyCupStorage.CupStorage storage cs = LibColonyCupStorage.cupStorage();
        uint64 last = cs.pairLastMatch[LibColonyCupStorage.pairKey(colonyA, colonyB)];
        return last == 0 ? 0 : last + cs.config.pairCooldown;
    }

    function getSeasonReward(uint32 seasonId, bytes32 colonyId)
        external
        view
        returns (uint256 allocated, uint256 claimed)
    {
        LibColonyCupStorage.CupStorage storage cs = LibColonyCupStorage.cupStorage();
        return (cs.seasonAllocations[seasonId][colonyId], cs.seasonClaimed[seasonId][colonyId]);
    }

    // ============ INTERNALS ============

    function _sliceLength(uint256 total, uint256 offset, uint256 limit) private pure returns (uint256) {
        if (offset >= total || limit == 0) {
            return 0;
        }
        uint256 remaining = total - offset;
        return remaining < limit ? remaining : limit;
    }
}
