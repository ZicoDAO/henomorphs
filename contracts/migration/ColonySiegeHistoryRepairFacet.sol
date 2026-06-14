// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { LibDiamond } from "../diamonds/shared/libraries/LibDiamond.sol";
import { LibColonyWarsStorage } from "../diamonds/chargepod/libraries/LibColonyWarsStorage.sol";

/**
 * @title ColonySiegeHistoryRepairFacet
 * @notice One-shot owner-only repair for `colonySiegeHistory` corruption that
 *         caused siege Panic 0x41 (verified on Polygon mainnet 2026-05-30).
 *
 * @dev Root cause (opcode-traced, reproduced 3× identically):
 *   `TerritorySiegeFacet._finalizeSiegeSetup` does
 *      cws.colonySiegeHistory[attackerColony].push(siegeId);
 *   `colonySiegeHistory` is field-slot 46 in the CURRENT ColonyWarsStorage
 *   layout. For veteran colonies (e.g. CheekyChooks 0xb10fef03…) the length
 *   slot keccak256(colonyId . 46) holds a ~3.07e19 value — orphaned data a
 *   pre-`ExternalContracts`-shrink (commit 54936f3) facet wrote there for a
 *   then-different field. solc's `length < 2**64` guard before `.push` (and
 *   before any storage-array→memory copy in getColonySiegeHistory) sees that
 *   garbage length and reverts Panic 0x41.
 *
 * Fix: reset the array LENGTH slot to 0. We MUST NOT use `delete
 *   cws.colonySiegeHistory[c]` — Solidity's array delete loops over the
 *   (garbage, 3e19) length zeroing elements and would itself run out of
 *   gas / panic. Instead we read the array's storage slot via `.slot` (so the
 *   offset is taken from the CURRENT compiled layout, never hardcoded) and
 *   `sstore(slot, 0)`. Old element words at keccak(slot)+i become orphaned and
 *   harmless. The siege-history list (cosmetic; same data lives in
 *   seasonSieges + events) restarts empty.
 *
 * Idempotent: clearing an already-clean (length 0) array is a no-op write.
 *
 * One-shot: after repair the owner should diamondCut.Remove these selectors.
 */
contract ColonySiegeHistoryRepairFacet {
    error NotOwner();

    /// Solc's storage-array length ceiling. A length >= 2**64 is the corrupt
    /// (orphaned old-layout scalar) state that triggers Panic 0x41; a legit
    /// siege history can never reach this. Only such arrays are reset, so it is
    /// SAFE to pass clean/legit colonies — their real history is preserved.
    uint256 internal constant CORRUPT_THRESHOLD = 1 << 64;

    event ColonySiegeHistoryRepaired(bytes32 indexed colonyId, uint256 oldRawLength);
    event ColonySiegeHistorySkipped(bytes32 indexed colonyId, uint256 rawLength);
    event RepairBatchComplete(uint256 attempted, uint256 repaired);

    /**
     * @notice Reset colonySiegeHistory[colony] length to 0 ONLY for colonies
     *         whose length slot is corrupt (>= 2**64). Legit histories (any
     *         length < 2**64, including 0) are left untouched.
     * @param colonies Colony IDs to check; safe to pass a superset.
     */
    function repairColonySiegeHistory(bytes32[] calldata colonies) external {
        if (msg.sender != LibDiamond.contractOwner()) revert NotOwner();

        LibColonyWarsStorage.ColonyWarsStorage storage cws =
            LibColonyWarsStorage.colonyWarsStorage();

        uint256 repaired = 0;
        for (uint256 i = 0; i < colonies.length; i++) {
            bytes32[] storage arr = cws.colonySiegeHistory[colonies[i]];
            uint256 slot;
            assembly { slot := arr.slot }
            uint256 oldRaw;
            assembly { oldRaw := sload(slot) }
            if (oldRaw >= CORRUPT_THRESHOLD) {
                assembly { sstore(slot, 0) }
                repaired++;
                emit ColonySiegeHistoryRepaired(colonies[i], oldRaw);
            } else {
                emit ColonySiegeHistorySkipped(colonies[i], oldRaw);
            }
        }
        emit RepairBatchComplete(colonies.length, repaired);
    }

    /**
     * @notice Diagnostic: raw value of the colonySiegeHistory length slot.
     *         A value >= 2**64 means corrupt (would Panic 0x41 on read/push).
     */
    function rawSiegeHistoryLength(bytes32 colonyId) external view returns (uint256 raw) {
        LibColonyWarsStorage.ColonyWarsStorage storage cws =
            LibColonyWarsStorage.colonyWarsStorage();
        bytes32[] storage arr = cws.colonySiegeHistory[colonyId];
        uint256 slot;
        assembly { slot := arr.slot }
        assembly { raw := sload(slot) }
    }
}
