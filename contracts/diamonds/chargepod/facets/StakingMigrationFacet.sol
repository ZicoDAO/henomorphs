// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibStakingStorage} from "../../staking/libraries/LibStakingStorage.sol";
import {StakedSpecimen} from "../../../libraries/StakingModel.sol";
import {AccessControlBase} from "../../common/facets/AccessControlBase.sol";

/**
 * @title StakingMigrationFacet
 * @notice Admin-only facet to reassign the owner/staker of staked specimens
 *         from one address to another, in place.
 * @dev The physical NFTs stay in the vault and every StakedSpecimen field
 *      (level, experience, lockup, charge, wear, rewards, colony membership)
 *      is preserved — only the recorded owner and the staker-tracking
 *      bookkeeping change. `totalStakedSpecimens` is intentionally untouched
 *      because the tokens remain staked.
 *
 *      Added as an isolated facet (single new selector) to keep the diamond
 *      cut's blast radius minimal — no existing facet is replaced.
 */
contract StakingMigrationFacet is AccessControlBase {
    error ZeroAddressNotAllowed();
    error SameOwner();

    /// @notice Emitted once per staked specimen moved between owners.
    event StakeReassigned(uint256 indexed combinedId, address indexed oldOwner, address indexed newOwner);

    /// @notice Emitted once per reassignStaker call with the total moved.
    event StakerReassigned(address indexed oldOwner, address indexed newOwner, uint256 movedCount);

    /**
     * @notice Move every staked specimen currently owned by `oldOwner` to `newOwner`.
     * @dev Authorized (diamond owner / operator) only. For each combinedId in the
     *      old owner's staker list that is genuinely staked and still owned by
     *      `oldOwner`: rewrites StakedSpecimen.owner, appends the combinedId to the
     *      new owner's list, then fixes active-staker tracking deterministically.
     *      Skips stale list entries. Safe to leave staking paused.
     * @param oldOwner Current staker address losing the tokens.
     * @param newOwner Address receiving ownership of the staked tokens.
     * @return moved Number of staked specimens reassigned.
     */
    function reassignStaker(address oldOwner, address newOwner)
        external
        onlyAuthorized
        returns (uint256 moved)
    {
        if (oldOwner == address(0) || newOwner == address(0)) revert ZeroAddressNotAllowed();
        if (oldOwner == newOwner) revert SameOwner();

        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();

        uint256[] storage oldTokens = ss.stakerTokens[oldOwner];
        uint256 len = oldTokens.length;

        for (uint256 i = 0; i < len; i++) {
            uint256 combinedId = oldTokens[i];
            StakedSpecimen storage staked = ss.stakedSpecimens[combinedId];

            // Only move entries that are genuinely staked and still owned by oldOwner.
            // (Guards against stale list entries and any already-moved duplicates.)
            if (staked.staked && staked.owner == oldOwner) {
                staked.owner = newOwner;
                ss.stakerTokens[newOwner].push(combinedId);
                unchecked { ++moved; }
                emit StakeReassigned(combinedId, oldOwner, newOwner);
            }
        }

        // Drop the old owner's list entirely (also clears any stale leftovers).
        delete ss.stakerTokens[oldOwner];

        // ---- Active-staker tracking (deterministic) ----
        if (moved > 0) {
            if (!ss.isActiveStaker[newOwner]) {
                ss.activeStakers.push(newOwner);
                ss.isActiveStaker[newOwner] = true;
            }
            ss.stakerTokenCount[newOwner] += moved;
        }

        // Old owner now holds zero staked tokens: reset its tracking.
        ss.stakerTokenCount[oldOwner] = 0;
        if (ss.isActiveStaker[oldOwner]) {
            uint256 n = ss.activeStakers.length;
            for (uint256 i = 0; i < n; i++) {
                if (ss.activeStakers[i] == oldOwner) {
                    ss.activeStakers[i] = ss.activeStakers[n - 1];
                    ss.activeStakers.pop();
                    break;
                }
            }
            ss.isActiveStaker[oldOwner] = false;
        }

        emit StakerReassigned(oldOwner, newOwner, moved);
    }
}
