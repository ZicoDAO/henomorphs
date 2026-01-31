// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title IMeritCollection
 * @notice Interface for Colony Merit collections (Territory, Infrastructure, Resources)
 * @dev Defines Colony Wars integration interface.
 *
 *      Transfer functions (requestTransfer, approveTransfer, etc.) and their events
 *      are inherited from ModularMerit base contract.
 *
 *      This interface defines only Colony-specific functions:
 *      - isAssigned: Check if token is assigned to colony/node
 *      - getAssignmentTarget: Get assignment target ID
 *
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 */
interface IMeritCollection {

    // ==================== COLONY INTEGRATION ====================

    /**
     * @notice Check if token is assigned to any colony/node/slot
     * @dev Implementation varies by collection type:
     *      - Territory: assigned to colonyId
     *      - Infrastructure: equipped to colonyId
     *      - Resources: staked to nodeId
     * @param tokenId Token ID
     * @return Whether token is currently assigned
     */
    function isAssigned(uint256 tokenId) external view returns (bool);

    /**
     * @notice Get assignment target (colonyId, nodeId, etc.)
     * @dev Returns 0 if not assigned
     *      Implementation varies by collection type
     * @param tokenId Token ID
     * @return Assignment target ID (0 if not assigned)
     */
    function getAssignmentTarget(uint256 tokenId) external view returns (uint256);
}
