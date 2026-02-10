// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/**
 * @title IColonyBoosterCards
 * @notice Interface for Colony Booster Cards NFT contract
 * @dev Used by Colony Wars facets to communicate with Booster NFT contract
 */
interface IColonyBoosterCards {

    /// @notice Multi-system attachment target (ABI-compatible with ColonyBoostersCards.AttachmentTarget)
    struct AttachmentTarget {
        uint8 system;           // 0=Buildings, 1=Evolution, 2=Venture, 3=Universal
        bytes32 colonyId;       // Buildings: colony identifier
        uint8 buildingType;     // Buildings: building type (0-7)
        uint256 collectionId;   // Evolution: specimen collection ID
        uint256 tokenId;        // Evolution: specimen token ID
        address user;           // Venture/Universal: user address
        uint8 ventureType;      // Venture: venture type (0-4)
    }

    // ============ COLONY_WARS_ROLE functions ============

    /// @notice Combine 3 boosters of same system, subType and rarity into 1 upgraded
    function upgradeBoosters(uint256[] calldata tokenIds) external returns (uint256);

    /// @notice Attach booster to any target (generic multi-system)
    function attachBooster(uint256 tokenId, AttachmentTarget calldata target) external;

    /// @notice Detach booster from target (generic, with cooldown check)
    function detachBooster(uint256 tokenId) external;

    /// @notice Attach booster to a colony building (legacy convenience)
    function attachToColony(uint256 tokenId, bytes32 colonyId, uint8 buildingType) external;

    /// @notice Detach booster from colony (legacy convenience, no cooldown check)
    function detachFromColony(uint256 tokenId) external;

    /// @notice Activate a blueprint (converts to active booster)
    function activateBlueprint(uint256 tokenId) external;

    // ============ Transfer Model D ============

    /// @notice Approve a pending transfer request
    function approveTransfer(uint256 tokenId, address to) external;

    /// @notice Complete an approved transfer
    function completeTransfer(address from, address to, uint256 tokenId) external;

    /// @notice Reject a pending transfer request
    function rejectTransfer(uint256 tokenId, string calldata reason) external;

    // ============ View functions ============

    /// @notice Get the owner of a booster token
    function ownerOf(uint256 tokenId) external view returns (address);

    /// @notice Check if booster is currently attached to a target
    function isAttached(uint256 tokenId) external view returns (bool);

    /// @notice Check if booster is an unactivated blueprint
    function isBlueprint(uint256 tokenId) external view returns (bool);

    /// @notice Get bonuses for a building target
    function getBuildingBonus(bytes32 colonyId, uint8 buildingType)
        external view returns (uint16 primaryBps, uint16 secondaryBps);

    /// @notice Get bonuses for an evolution target
    function getEvolutionBonus(uint256 collectionId, uint256 specimenTokenId)
        external view returns (uint16 costReductionBps, uint8 tierBonus);

    /// @notice Get bonuses for a venture target
    function getVentureBonus(address user, uint8 ventureType)
        external view returns (uint16 successBps, uint16 rewardBps);
}
