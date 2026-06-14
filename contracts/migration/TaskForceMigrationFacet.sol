// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { LibDiamond } from "../diamonds/shared/libraries/LibDiamond.sol";
import { LibColonyWarsStorage } from "../diamonds/chargepod/libraries/LibColonyWarsStorage.sol";
import { PodsUtils } from "../libraries/PodsUtils.sol";

/**
 * @title TaskForceMigrationFacet
 * @notice One-shot facet to migrate Task Force storage entries from the OLD
 *         storage slot index to the CURRENT one, after commit 54936f3 shrunk
 *         `LibColonyWarsStorage.ExternalContracts` from 3 fields to 2 and
 *         shifted every subsequent field in `ColonyWarsStorage` by -1 slot.
 *
 * @dev
 *  Background — verified empirically on Polygon mainnet 2026-05-28:
 *    - Slot constant `keccak256("henomorphs.colonywars.storage.ext.v2")` is
 *      unchanged since 2025-12-08. Data is not lost, only at a different
 *      offset within the parent struct.
 *    - The OLD `ColonyTaskForceFacet` (compiled BEFORE the shrink) wrote
 *      `cws.taskForces` mapping at struct offset 97. The taskForceCounter
 *      lives at OLD offset 98 (= 50, total TFs created across all seasons).
 *    - Today's redeploy of `ColonyTaskForceFacet` (compiled AFTER the shrink)
 *      reads `cws.taskForces` at struct offset 96 (one earlier). That slot
 *      is empty → `getTaskForce()` returns all zeros → `initiateCombat`
 *      reverts `TaskForceInvalid()` for every player.
 *    - `colonyWarProfiles` mapping (idx 15) was NEVER written by an OLD-layout
 *      writer, so player profiles are unaffected by this issue.
 *
 *  This facet:
 *    1. Reads the OLD storage at offset 97 (hardcoded as constant) via
 *       inline assembly, decoding the full TaskForce struct (colonyId,
 *       seasonId, name, collectionIds[], tokenIds[], createdAt, active).
 *    2. Writes the data back to NEW storage via normal Solidity (the
 *       compiler resolves `cws.taskForces[id]` to the CURRENT offset —
 *       whatever the source-and-bytecode pair compiles to).
 *    3. Rebuilds the secondary indices: `colonyTaskForces[colony][season]`
 *       (push id) and `tokenToTaskForce[season][combinedId]` (set id).
 *    4. Bumps `taskForceCounter` to the OLD value (50) so future
 *       `createTaskForce` calls don't collide with migrated IDs.
 *
 *  Idempotency: if a TF was already migrated (its `createdAt` in NEW layout
 *  is non-zero), it is skipped — re-running the migration with the same
 *  TF IDs is safe and won't duplicate index entries.
 *
 *  Safety assumptions verified before deploying:
 *    - All 50 TF names are <= 31 bytes (inline short-string layout).
 *      If a longer-than-31-byte name appears, the migration reverts
 *      with `LongNameNotSupported`. Owner can extend the function.
 *    - `collectionIds.length == tokenIds.length` for every migrated TF
 *      (consistent with how `createTaskForce` produced them).
 *
 *  This facet is one-shot. After the migration completes, owner should:
 *      1. Call `diamondCut(action=Remove, [migrateTaskForces.selector])`
 *      2. Optionally selfdestruct the deployed facet contract.
 */
contract TaskForceMigrationFacet {
    // ============================================================
    // CONSTANTS — empirically verified on Polygon mainnet
    // ============================================================

    /// Storage base for `LibColonyWarsStorage.ColonyWarsStorage` (slot v2).
    bytes32 private constant BASE_SLOT =
        keccak256("henomorphs.colonywars.storage.ext.v2");

    /// Offset of `taskForces` mapping in the OLD parent-struct layout
    /// (before commit 54936f3 shrunk `ExternalContracts`).
    uint256 private constant OLD_TASK_FORCES_OFFSET = 97;

    /// Value of `taskForceCounter` at OLD offset 98 — total TFs created
    /// before the redeploy. Bumping the NEW counter to this value
    /// prevents ID collisions with already-migrated TFs.
    uint256 private constant OLD_TOTAL_TF_COUNT = 50;

    // ============================================================
    // ERRORS
    // ============================================================

    error NotOwner();
    error ArrayLengthMismatch(bytes32 taskForceId, uint256 collections, uint256 tokens);

    // ============================================================
    // EVENTS
    // ============================================================

    event TaskForceMigrated(bytes32 indexed taskForceId, bytes32 indexed colonyId, uint32 seasonId, uint256 tokenCount);
    event MigrationBatchComplete(uint256 totalAttempted, uint256 totalMigrated, uint256 totalSkipped);
    event CounterBumped(uint256 oldValue, uint256 newValue);

    // ============================================================
    // ENTRY POINT
    // ============================================================

    /**
     * @notice Migrate a batch of Task Forces from OLD storage offset to NEW.
     * @param tfIds Task Force IDs to migrate. Caller may split the full set
     *              across multiple calls if a single call would run out of gas.
     */
    function migrateTaskForces(bytes32[] calldata tfIds) external {
        if (msg.sender != LibDiamond.contractOwner()) revert NotOwner();

        LibColonyWarsStorage.ColonyWarsStorage storage cws =
            LibColonyWarsStorage.colonyWarsStorage();

        bytes32 oldMappingSlot = bytes32(uint256(BASE_SLOT) + OLD_TASK_FORCES_OFFSET);

        uint256 migrated = 0;
        uint256 skipped = 0;

        for (uint256 i = 0; i < tfIds.length; i++) {
            (bool didMigrate, uint256 tokenCnt) = _migrateOne(cws, oldMappingSlot, tfIds[i]);
            if (didMigrate) {
                migrated++;
                emit TaskForceMigrated(tfIds[i], cws.taskForces[tfIds[i]].colonyId, cws.taskForces[tfIds[i]].seasonId, tokenCnt);
            } else {
                skipped++;
            }
        }

        // Bump counter once we've placed at least one TF — prevents future
        // createTaskForce from generating an ID that collides with migrated.
        if (cws.taskForceCounter < OLD_TOTAL_TF_COUNT) {
            uint256 prev = cws.taskForceCounter;
            cws.taskForceCounter = OLD_TOTAL_TF_COUNT;
            emit CounterBumped(prev, OLD_TOTAL_TF_COUNT);
        }

        emit MigrationBatchComplete(tfIds.length, migrated, skipped);
    }

    /**
     * @dev Migrate a single Task Force. Internal helper extracted to keep
     *      the main loop's stack pressure low (Solidity's "stack too deep").
     *      Returns (true, tokenCount) if migrated, (false, 0) if skipped.
     */
    function _migrateOne(
        LibColonyWarsStorage.ColonyWarsStorage storage cws,
        bytes32 oldMappingSlot,
        bytes32 tfId
    ) internal returns (bool didMigrate, uint256 tokenCount) {
        // Idempotency: skip if already migrated.
        if (cws.taskForces[tfId].createdAt != 0) return (false, 0);

        bytes32 oldBase = keccak256(abi.encode(tfId, oldMappingSlot));

        // Read header (slots 0, 1, 2, 5) — header is gas-cheap to decode here.
        bytes32 colonyIdBytes;
        bytes32 slot1;
        bytes32 slot2;
        bytes32 slot5;
        uint256 nElements;
        assembly {
            colonyIdBytes := sload(oldBase)
            slot1 := sload(add(oldBase, 1))
            slot2 := sload(add(oldBase, 2))
            slot5 := sload(add(oldBase, 5))
            // Read array lengths inline to detect mismatches early.
            let nC := sload(add(oldBase, 3))
            let nT := sload(add(oldBase, 4))
            // Reuse stack: store nT in nElements if equal, else 0xFFFF for mismatch flag.
            switch eq(nC, nT)
            case 1 { nElements := nC }
            default { nElements := not(0) } // sentinel meaning mismatch
        }

        if (colonyIdBytes == bytes32(0)) return (false, 0);
        if (nElements == type(uint256).max) {
            // length mismatch — re-read both for the revert message
            uint256 nC; uint256 nT;
            assembly { nC := sload(add(oldBase, 3)) nT := sload(add(oldBase, 4)) }
            revert ArrayLengthMismatch(tfId, nC, nT);
        }

        // Write fixed-size header fields to NEW storage.
        LibColonyWarsStorage.TaskForce storage tf = cws.taskForces[tfId];
        tf.colonyId = colonyIdBytes;
        tf.seasonId = uint32(uint256(slot1));
        tf.name = _decodeName(slot2, oldBase);
        tf.createdAt = uint32(uint256(slot5));
        tf.active = ((uint256(slot5) >> 32) & 0xff) != 0;

        // Write arrays + secondary indices.
        _migrateArraysAndIndices(cws, tf, tfId, oldBase, nElements);

        return (true, nElements);
    }

    /**
     * @dev Decode a Solidity-encoded string from storage. Handles both
     *      short (≤31 bytes, inline) and long (>31 bytes, data at keccak)
     *      encodings — required because one of the TFs has a 32-byte name
     *      ("Zapite mordy amunicję przepiły") that uses the long layout.
     */
    function _decodeName(bytes32 slot2, bytes32 oldBase)
        internal
        view
        returns (string memory)
    {
        uint256 fullValue = uint256(slot2);
        if (fullValue & 1 == 0) {
            // Short string: low byte = length*2, data inline (high bytes, MSB first).
            uint256 nameLen = (fullValue & 0xff) >> 1;
            bytes memory nameBytes = new bytes(nameLen);
            for (uint256 j = 0; j < nameLen; j++) {
                nameBytes[j] = bytes1(uint8(fullValue >> (8 * (31 - j))));
            }
            return string(nameBytes);
        }

        // Long string: slot value = length*2 + 1.
        // Data lives at keccak256(slotPosition) and continues in subsequent
        // slots (32 bytes per slot, MSB-first within each slot).
        uint256 longLen = (fullValue - 1) >> 1;
        bytes memory longBytes = new bytes(longLen);
        bytes32 nameSlotPos = bytes32(uint256(oldBase) + 2);
        bytes32 dataLoc = keccak256(abi.encode(nameSlotPos));
        uint256 wordCount = (longLen + 31) >> 5;
        for (uint256 w = 0; w < wordCount; w++) {
            bytes32 word;
            bytes32 wordLoc = bytes32(uint256(dataLoc) + w);
            assembly { word := sload(wordLoc) }
            uint256 wEnd = (w + 1) * 32;
            uint256 cap = wEnd > longLen ? longLen : wEnd;
            for (uint256 i = w * 32; i < cap; i++) {
                longBytes[i] = bytes1(uint8(uint256(word) >> (8 * (31 - (i - w * 32)))));
            }
        }
        return string(longBytes);
    }

    function _migrateArraysAndIndices(
        LibColonyWarsStorage.ColonyWarsStorage storage cws,
        LibColonyWarsStorage.TaskForce storage tf,
        bytes32 tfId,
        bytes32 oldBase,
        uint256 n
    ) internal {
        uint256[] memory collectionIds = new uint256[](n);
        uint256[] memory tokenIds = new uint256[](n);
        bytes32 collectionDataBase = keccak256(abi.encode(bytes32(uint256(oldBase) + 3)));
        bytes32 tokenDataBase = keccak256(abi.encode(bytes32(uint256(oldBase) + 4)));
        for (uint256 j = 0; j < n; j++) {
            bytes32 cLoc = bytes32(uint256(collectionDataBase) + j);
            bytes32 tLoc = bytes32(uint256(tokenDataBase) + j);
            uint256 cVal;
            uint256 tVal;
            assembly { cVal := sload(cLoc) tVal := sload(tLoc) }
            collectionIds[j] = cVal;
            tokenIds[j] = tVal;
        }
        tf.collectionIds = collectionIds;
        tf.tokenIds = tokenIds;

        // Secondary index: per-colony per-season TF list.
        cws.colonyTaskForces[tf.colonyId][tf.seasonId].push(tfId);

        // Reverse index: which TF owns each token (per season).
        for (uint256 j = 0; j < n; j++) {
            uint256 combinedId = PodsUtils.combineIds(collectionIds[j], tokenIds[j]);
            cws.tokenToTaskForce[tf.seasonId][combinedId] = tfId;
        }
    }

    /**
     * @notice Off-chain diagnostic accessor — returns the OLD storage offset
     *         and current counter so the migration script can sanity-check
     *         before and after the migration call.
     */
    function getMigrationDiagnostics()
        external
        view
        returns (
            uint256 oldOffset,
            uint256 currentCounter,
            bytes32 baseSlot
        )
    {
        oldOffset = OLD_TASK_FORCES_OFFSET;
        currentCounter = LibColonyWarsStorage.colonyWarsStorage().taskForceCounter;
        baseSlot = BASE_SLOT;
    }
}
