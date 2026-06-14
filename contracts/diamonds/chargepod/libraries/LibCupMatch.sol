// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {LibHenomorphsStorage} from "./LibHenomorphsStorage.sol";
import {LibColonyCupStorage} from "./LibColonyCupStorage.sol";
import {CupMatchEngine} from "./CupMatchEngine.sol";
import {PodsUtils} from "../../../libraries/PodsUtils.sol";
import {TokenStats, IAccessoryFacet, WarfareHelper} from "./WarfareHelper.sol";

/**
 * @title LibCupMatch
 * @notice Shared internals for the Colony Cup facets (ColonyCupFacet + ColonyCupPlayFacet)
 * @dev Pulled out of the facet when v2 split the match flow into its own facet to
 *      stay under the 24,576-byte limit. Errors used by both facets live here.
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 */
library LibCupMatch {
    using SafeERC20 for IERC20;

    // ============ SHARED ERRORS ============

    error CupNotInitialized();
    error CupDisabled();
    error CupSeasonNotActive();
    error CupSeasonNotStarted(uint64 startsAt);
    error CupSeasonConcluded(uint64 endedAt);
    error TreasuryCurrencyNotConfigured();
    error TeamNotRegistered(bytes32 colonyId);
    error SquadTokenNotInColony(uint256 combinedId);
    error DuplicateSquadToken(uint256 combinedId);
    error MatchNotFound(uint256 matchId);
    error InvalidMatchStatus(uint256 matchId, uint8 status);
    error DailyLimitReached(bytes32 colonyId);

    // ============ GUARDS ============

    function requireCupActive() internal view returns (LibColonyCupStorage.CupStorage storage cs) {
        cs = LibColonyCupStorage.cupStorage();
        if (!cs.initialized) {
            revert CupNotInitialized();
        }
        if (!cs.config.enabled) {
            revert CupDisabled();
        }
        if (cs.currentSeason == 0 || cs.seasonEndTime[cs.currentSeason] != 0) {
            revert CupSeasonNotActive();
        }
        // Past the scheduled end everything new is blocked (team mgmt included);
        // in-flight matches stay finishable — their phases never call this guard.
        LibColonyCupStorage.SeasonSchedule storage sched = cs.seasonSchedule[cs.currentSeason];
        if (sched.endsAt != 0 && block.timestamp > sched.endsAt) {
            revert CupSeasonConcluded(sched.endsAt);
        }
    }

    /// @dev Match-starting gate: registration opens with startCupSeason, PLAY only
    ///      within the scheduled [startsAt, endsAt] window.
    function requireSeasonInPlay(LibColonyCupStorage.CupStorage storage cs, uint32 seasonId) internal view {
        LibColonyCupStorage.SeasonSchedule storage sched = cs.seasonSchedule[seasonId];
        if (sched.startsAt != 0 && block.timestamp < sched.startsAt) {
            revert CupSeasonNotStarted(sched.startsAt);
        }
        if (sched.endsAt != 0 && block.timestamp > sched.endsAt) {
            revert CupSeasonConcluded(sched.endsAt);
        }
    }

    function requireTeam(
        LibColonyCupStorage.CupStorage storage cs,
        uint32 seasonId,
        bytes32 colonyId
    ) internal view returns (LibColonyCupStorage.TeamSheet storage team) {
        team = cs.teams[seasonId][colonyId];
        if (!team.active) {
            revert TeamNotRegistered(colonyId);
        }
    }

    function requireMatch(
        LibColonyCupStorage.CupStorage storage cs,
        uint256 matchId
    ) internal view returns (LibColonyCupStorage.CupMatch storage matchData) {
        matchData = cs.matches[matchId];
        if (matchData.status == LibColonyCupStorage.MatchStatus.None) {
            revert MatchNotFound(matchId);
        }
    }

    function requireStatus(
        LibColonyCupStorage.CupMatch storage matchData,
        uint256 matchId,
        LibColonyCupStorage.MatchStatus expected
    ) internal view {
        if (matchData.status != expected) {
            revert InvalidMatchStatus(matchId, uint8(matchData.status));
        }
    }

    function currency() internal view returns (IERC20) {
        address token = LibHenomorphsStorage.henomorphsStorage().chargeTreasury.treasuryCurrency;
        if (token == address(0)) {
            revert TreasuryCurrencyNotConfigured();
        }
        return IERC20(token);
    }

    // ============ SQUAD VALIDATION ============

    /// @dev Validates membership + uniqueness and returns combined IDs per slot
    function validateSquad(
        bytes32 colonyId,
        uint256[5] calldata collectionIds,
        uint256[5] calldata tokenIds
    ) internal view returns (uint256[5] memory combined) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();

        for (uint256 i = 0; i < LibColonyCupStorage.SQUAD_SIZE; i++) {
            uint256 combinedId = PodsUtils.combineIds(collectionIds[i], tokenIds[i]);
            if (hs.specimenColonies[combinedId] != colonyId) {
                revert SquadTokenNotInColony(combinedId);
            }
            for (uint256 j = 0; j < i; j++) {
                if (combined[j] == combinedId) {
                    revert DuplicateSquadToken(combinedId);
                }
            }
            combined[i] = combinedId;
        }
    }

    /// @dev Bench slots may be empty (0/0); occupied ones must be unique colony members
    function validateBench(
        bytes32 colonyId,
        uint256[2] calldata collectionIds,
        uint256[2] calldata tokenIds,
        uint256[5] memory squad
    ) internal view returns (uint256[2] memory bench) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();

        for (uint256 i = 0; i < LibColonyCupStorage.BENCH_SIZE; i++) {
            if (collectionIds[i] == 0 && tokenIds[i] == 0) {
                continue; // empty bench slot
            }
            uint256 combinedId = PodsUtils.combineIds(collectionIds[i], tokenIds[i]);
            if (hs.specimenColonies[combinedId] != colonyId) {
                revert SquadTokenNotInColony(combinedId);
            }
            for (uint256 j = 0; j < LibColonyCupStorage.SQUAD_SIZE; j++) {
                if (squad[j] == combinedId) {
                    revert DuplicateSquadToken(combinedId);
                }
            }
            if (i == 1 && bench[0] == combinedId) {
                revert DuplicateSquadToken(combinedId);
            }
            bench[i] = combinedId;
        }
    }

    function requireSquadInColony(uint256[5] memory tokens, bytes32 colonyId) internal view {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        for (uint256 i = 0; i < LibColonyCupStorage.SQUAD_SIZE; i++) {
            if (hs.specimenColonies[tokens[i]] != colonyId) {
                revert SquadTokenNotInColony(tokens[i]);
            }
        }
    }

    /// @notice True when the combined token is still a member of the colony
    function isInColony(uint256 combinedId, bytes32 colonyId) internal view returns (bool) {
        return LibHenomorphsStorage.henomorphsStorage().specimenColonies[combinedId] == colonyId;
    }

    // ============ LIMITS ============

    function consumeDailySlot(
        LibColonyCupStorage.CupStorage storage cs,
        bytes32 colonyId,
        uint16 dailyLimit
    ) internal {
        uint32 day = LibColonyCupStorage.dayId();
        if (cs.matchesOnDay[colonyId][day] >= dailyLimit) {
            revert DailyLimitReached(colonyId);
        }
        cs.matchesOnDay[colonyId][day]++;
    }

    // ============ STRENGTH ============

    /**
     * @dev Aggregate squad strength from live token stats via the AccessoryFacet
     *      (diamond self-call, same source the wars power formula uses). Variant is
     *      normalized to 1..4 (collections that do not expose itemVariant report 0/1).
     */
    function computeStrength(uint256[5] memory tokens)
        internal
        view
        returns (CupMatchEngine.TeamStrength memory strength)
    {
        uint256[] memory collectionIds = new uint256[](LibColonyCupStorage.SQUAD_SIZE);
        uint256[] memory tokenIds = new uint256[](LibColonyCupStorage.SQUAD_SIZE);
        for (uint256 i = 0; i < LibColonyCupStorage.SQUAD_SIZE; i++) {
            (collectionIds[i], tokenIds[i]) = PodsUtils.extractIds(tokens[i]);
        }

        TokenStats[] memory stats = IAccessoryFacet(address(this)).getTokenPerformanceStats(collectionIds, tokenIds);

        for (uint256 i = 0; i < LibColonyCupStorage.SQUAD_SIZE; i++) {
            uint256 power = WarfareHelper.calculateTokenPower(stats[i]);

            uint8 variant = stats[i].variant;
            if (variant == 0) variant = 1;
            if (variant > 4) variant = 4;
            if (variant != expectedVariant(uint8(i))) {
                power = (power * LibColonyCupStorage.OFF_POSITION_FACTOR) / 100;
            }

            if (i == LibColonyCupStorage.SLOT_GK) {
                strength.gk = uint32(power);
            } else if (i == LibColonyCupStorage.SLOT_DEF_A || i == LibColonyCupStorage.SLOT_DEF_B) {
                strength.def += uint32(power);
            } else if (i == LibColonyCupStorage.SLOT_MID) {
                strength.mid = uint32(power);
            } else {
                strength.att = uint32(power);
            }
        }
    }

    /// @dev Natural position per squad slot: v1=GK, v2=DEF, v3=MID, v4=ATT
    function expectedVariant(uint8 slot) internal pure returns (uint8) {
        if (slot == LibColonyCupStorage.SLOT_GK) return 1;
        if (slot == LibColonyCupStorage.SLOT_DEF_A || slot == LibColonyCupStorage.SLOT_DEF_B) return 2;
        if (slot == LibColonyCupStorage.SLOT_MID) return 3;
        return 4;
    }

    // ============ RESULT APPLICATION ============

    /// @dev outcomeCode: 0 = home wins, 1 = away wins, 2 = draw (final, after shootout)
    function applyTable(
        LibColonyCupStorage.CupStorage storage cs,
        LibColonyCupStorage.CupMatch storage matchData,
        uint8 outcomeCode
    ) internal {
        LibColonyCupStorage.TableRow storage homeRow = cs.table[matchData.seasonId][matchData.home];
        LibColonyCupStorage.TableRow storage awayRow = cs.table[matchData.seasonId][matchData.away];

        homeRow.played++;
        awayRow.played++;
        homeRow.goalsFor += matchData.scoreHome;
        homeRow.goalsAgainst += matchData.scoreAway;
        awayRow.goalsFor += matchData.scoreAway;
        awayRow.goalsAgainst += matchData.scoreHome;

        if (outcomeCode == 0) {
            homeRow.wins++;
            homeRow.points += 3;
            awayRow.losses++;
        } else if (outcomeCode == 1) {
            awayRow.wins++;
            awayRow.points += 3;
            homeRow.losses++;
        } else {
            homeRow.draws++;
            awayRow.draws++;
            homeRow.points += 1;
            awayRow.points += 1;
        }
    }

    function applyScorers(
        LibColonyCupStorage.CupStorage storage cs,
        LibColonyCupStorage.CupMatch storage matchData
    ) internal {
        uint32 seasonId = matchData.seasonId;
        for (uint8 i = 0; i < matchData.eventCount; i++) {
            (, bool isHome, uint8 scorerSlot) = CupMatchEngine.unpackEvent(matchData.packedEvents, i);
            uint256 scorerToken = isHome ? matchData.homeSquad[scorerSlot] : matchData.awaySquad[scorerSlot];
            if (cs.goalsByToken[seasonId][scorerToken] == 0) {
                cs.seasonScorers[seasonId].push(scorerToken);
            }
            cs.goalsByToken[seasonId][scorerToken]++;
        }
    }

    /// @dev outcomeCode: 0 = home wins, 1 = away wins, 2 = draw (split after fee)
    function settleStakes(
        LibColonyCupStorage.CupStorage storage cs,
        LibColonyCupStorage.CupMatch storage matchData,
        uint8 outcomeCode
    ) internal {
        uint256 pot = uint256(matchData.stake) * 2;
        if (pot == 0) {
            return;
        }

        uint256 fee = (pot * cs.config.feeBps) / 10000;
        cs.seasonPool[matchData.seasonId] += fee;
        uint256 payout = pot - fee;

        IERC20 token = currency();
        if (outcomeCode == 0) {
            token.safeTransfer(matchData.homeOwner, payout);
        } else if (outcomeCode == 1) {
            token.safeTransfer(matchData.awayOwner, payout);
        } else {
            uint256 homeShare = payout / 2;
            token.safeTransfer(matchData.homeOwner, homeShare);
            token.safeTransfer(matchData.awayOwner, payout - homeShare);
        }
    }
}
