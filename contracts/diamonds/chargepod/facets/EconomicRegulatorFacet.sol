// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibMeta} from "../../shared/libraries/LibMeta.sol";
import {LibResourceStorage} from "../libraries/LibResourceStorage.sol";
import {AccessControlBase} from "../../common/facets/AccessControlBase.sol";

/**
 * @title EconomicRegulatorFacet
 * @notice Manages resource economy: supply caps, decay, and emergency controls
 * @dev Part of the Diamond proxy pattern - append-only storage
 * @author rutilicus.eth (ArchXS)
 */
contract EconomicRegulatorFacet is AccessControlBase {
    // Events
    event SupplyCapUpdated(uint8 indexed resourceType, uint256 oldCap, uint256 newCap);
    event SupplyCapSystemToggled(bool enabled);
    event ResourceGenerationPaused(bool paused);
    event ColonyDecayConfigUpdated(bool enabled, uint16 rate);
    event GlobalSupplySnapshot(uint256[4] supplies, uint256 timestamp);

    // Errors
    error InvalidResourceType(uint8 resourceType);
    error InvalidDecayRate(uint16 rate);

    // ============================================
    // ADMIN FUNCTIONS - SUPPLY CAPS
    // ============================================

    /**
     * @notice Set supply cap for a specific resource type
     * @param resourceType Resource type (0-3)
     * @param cap Maximum supply (0 = unlimited)
     */
    function setResourceSupplyCap(uint8 resourceType, uint256 cap) external onlyAuthorized {
        if (resourceType > 3) revert InvalidResourceType(resourceType);

        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();

        uint256 oldCap = rs.resourceSupplyCaps[resourceType];
        rs.resourceSupplyCaps[resourceType] = cap;

        emit SupplyCapUpdated(resourceType, oldCap, cap);
    }

    /**
     * @notice Set supply caps for all resource types at once
     * @param caps Array of 4 caps [basic, energy, bio, rare]
     */
    function setAllResourceSupplyCaps(uint256[4] calldata caps) external onlyAuthorized {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();

        for (uint8 i = 0; i < 4; i++) {
            uint256 oldCap = rs.resourceSupplyCaps[i];
            rs.resourceSupplyCaps[i] = caps[i];
            emit SupplyCapUpdated(i, oldCap, caps[i]);
        }
    }

    /**
     * @notice Enable or disable the supply cap system
     * @param enabled True to enable caps, false to disable
     */
    function setResourceSupplyCapEnabled(bool enabled) external onlyAuthorized {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        rs.supplyCapEnabled = enabled;

        emit SupplyCapSystemToggled(enabled);
    }

    /**
     * @notice Emergency pause/unpause all resource generation
     * @param paused True to pause, false to resume
     */
    function setResourceGenerationPaused(bool paused) external onlyAuthorized {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        rs.resourceGenerationPaused = paused;

        emit ResourceGenerationPaused(paused);
    }

    // ============================================
    // ADMIN FUNCTIONS - COLONY DECAY
    // ============================================

    /**
     * @notice Configure colony resource decay
     * @param enabled True to enable decay for colonies
     * @param rate Decay rate in basis points per day (max 1000 = 10%)
     */
    function setColonyDecayConfig(bool enabled, uint16 rate) external onlyAuthorized {
        if (rate > 1000) revert InvalidDecayRate(rate);

        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        rs.colonyDecayEnabled = enabled;
        rs.colonyDecayRate = rate;

        emit ColonyDecayConfigUpdated(enabled, rate);
    }

    // ============================================
    // ADMIN FUNCTIONS - SUPPLY CORRECTIONS
    // ============================================

    /**
     * @notice Manually adjust global supply tracking (for corrections)
     * @dev Use with caution - only for fixing tracking discrepancies
     * @param resourceType Resource type (0-3)
     * @param newSupply Corrected supply value
     */
    function correctGlobalResourceSupply(uint8 resourceType, uint256 newSupply) external onlyAuthorized {
        if (resourceType > 3) revert InvalidResourceType(resourceType);

        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        rs.resourceGlobalSupply[resourceType] = newSupply;
    }

    /**
     * @notice Initialize supply caps system (upgrade function)
     * @dev Called once during upgrade to v3
     */
    function initializeSupplyCapsSystem() external onlyAuthorized {
        LibResourceStorage.initializeSupplyCaps();
    }

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    /**
     * @notice Get supply cap for a resource type
     * @param resourceType Resource type (0-3)
     * @return cap Current cap (0 = unlimited)
     */
    function getResourceSupplyCap(uint8 resourceType) external view returns (uint256 cap) {
        if (resourceType > 3) revert InvalidResourceType(resourceType);
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        return rs.resourceSupplyCaps[resourceType];
    }

    /**
     * @notice Get all supply caps
     * @return caps Array of 4 caps [basic, energy, bio, rare]
     */
    function getAllResourceSupplyCaps() external view returns (uint256[4] memory caps) {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        for (uint8 i = 0; i < 4; i++) {
            caps[i] = rs.resourceSupplyCaps[i];
        }
        return caps;
    }

    /**
     * @notice Get current global supply for a resource type
     * @param resourceType Resource type (0-3)
     * @return supply Current global supply
     */
    function getGlobalResourceSupply(uint8 resourceType) external view returns (uint256 supply) {
        if (resourceType > 3) revert InvalidResourceType(resourceType);
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        return rs.resourceGlobalSupply[resourceType];
    }

    /**
     * @notice Get all global supplies
     * @return supplies Array of 4 supplies [basic, energy, bio, rare]
     */
    function getAllGlobalResourceSupplies() external view returns (uint256[4] memory supplies) {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        for (uint8 i = 0; i < 4; i++) {
            supplies[i] = rs.resourceGlobalSupply[i];
        }
        return supplies;
    }

    /**
     * @notice Get available supply before cap is reached
     * @param resourceType Resource type (0-3)
     * @return available Remaining supply (type(uint256).max if unlimited)
     */
    function getAvailableResourceSupply(uint8 resourceType) external view returns (uint256 available) {
        if (resourceType > 3) revert InvalidResourceType(resourceType);
        return LibResourceStorage.getAvailableSupply(resourceType);
    }

    /**
     * @notice Get supply utilization percentage
     * @param resourceType Resource type (0-3)
     * @return utilizationBps Utilization in basis points (0-10000)
     */
    function getResourceSupplyUtilization(uint8 resourceType) external view returns (uint256 utilizationBps) {
        if (resourceType > 3) revert InvalidResourceType(resourceType);

        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();

        uint256 cap = rs.resourceSupplyCaps[resourceType];
        if (cap == 0) return 0; // Unlimited = 0% utilization

        uint256 current = rs.resourceGlobalSupply[resourceType];
        return (current * 10000) / cap;
    }

    /**
     * @notice Check if supply cap system is enabled
     * @return enabled True if caps are enforced
     */
    function isResourceSupplyCapEnabled() external view returns (bool enabled) {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        return rs.supplyCapEnabled;
    }

    /**
     * @notice Check if resource generation is paused
     * @return paused True if generation is halted
     */
    function isResourceGenerationPaused() external view returns (bool paused) {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        return rs.resourceGenerationPaused;
    }

    /**
     * @notice Get colony decay configuration
     * @return enabled Whether colony decay is enabled
     * @return rate Decay rate in basis points per day
     */
    function getColonyDecayConfig() external view returns (bool enabled, uint16 rate) {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        return (rs.colonyDecayEnabled, rs.colonyDecayRate);
    }

    /**
     * @notice Get comprehensive supply status for all resources
     * @return caps Current caps
     * @return supplies Current supplies
     * @return available Available before cap
     * @return capEnabled Whether caps are enforced
     * @return generationPaused Whether generation is paused
     */
    function getResourceSupplyStatus() external view returns (
        uint256[4] memory caps,
        uint256[4] memory supplies,
        uint256[4] memory available,
        bool capEnabled,
        bool generationPaused
    ) {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();

        capEnabled = rs.supplyCapEnabled;
        generationPaused = rs.resourceGenerationPaused;

        for (uint8 i = 0; i < 4; i++) {
            caps[i] = rs.resourceSupplyCaps[i];
            supplies[i] = rs.resourceGlobalSupply[i];
            available[i] = LibResourceStorage.getAvailableSupply(i);
        }

        return (caps, supplies, available, capEnabled, generationPaused);
    }

    /**
     * @notice Emit snapshot event for off-chain tracking
     * @dev Can be called by anyone - useful for indexers
     */
    function emitResourceSupplySnapshot() external {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();

        uint256[4] memory supplies;
        for (uint8 i = 0; i < 4; i++) {
            supplies[i] = rs.resourceGlobalSupply[i];
        }

        emit GlobalSupplySnapshot(supplies, block.timestamp);
    }
}
