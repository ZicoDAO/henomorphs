// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/**
 * @title LibSpecimenEvolutionStorage
 * @notice Dedicated storage library for Specimen Evolution System
 * @dev Uses Diamond storage pattern with unique position - safe for proxy upgrades
 * @author rutilicus.eth (ArchXS)
 */
library LibSpecimenEvolutionStorage {
    bytes32 constant SPECIMEN_EVOLUTION_STORAGE_POSITION = keccak256("henomorphs.specimen.evolution.storage.v1");

    // ============================================
    // STRUCTS
    // ============================================

    /**
     * @notice Resource costs for evolution tier
     * @dev Index: 0=BasicMaterials, 1=EnergyCrystals, 2=BioCompounds, 3=RareElements
     */
    struct EvolutionTier {
        uint256[4] resourceCosts;     // Cost per resource type
        uint256 tokenCost;            // YLW/ZICO cost
        uint16 statBoostBps;          // Stat boost in basis points (100 = 1%)
        uint16 productionBoostBps;    // Resource production boost
        uint32 cooldownSeconds;       // Cooldown after evolution
        bool requiresPreviousTier;    // Must have previous tier first
        bool enabled;                 // Tier is available
    }

    /**
     * @notice Evolution state for a specific token
     */
    struct SpecimenEvolution {
        uint8 currentLevel;           // Current evolution level (0 = base, 5 = max)
        uint32 lastEvolutionTime;     // Timestamp of last evolution
        uint16 totalStatBoost;        // Cumulative stat boost from evolutions
        uint16 totalProductionBoost;  // Cumulative production boost
        bool locked;                  // Locked (e.g., during special events)
    }

    /**
     * @notice Evolution configuration
     */
    struct EvolutionConfig {
        uint8 maxLevel;               // Maximum evolution level (default: 5)
        bool systemEnabled;           // Master switch for evolution system
        bool useGovernanceToken;      // True = ZICO, False = YLW for token costs
        address governanceToken;      // ZICO address
        address utilityToken;         // YLW address
        address beneficiary;          // Where token fees go
        uint16 failureRefundBps;      // Refund on failure in bps (0 = no failure possible)
        bool burnOnCollect;           // Whether to burn YLW instead of transferring (deflationary)
    }

    /**
     * @notice Per-collection evolution settings
     */
    struct CollectionEvolutionConfig {
        bool evolutionEnabled;        // Can tokens from this collection evolve
        uint16 bonusMultiplierBps;    // Collection-specific bonus (10000 = 1x)
        uint8 maxLevelOverride;       // Override max level (0 = use global)
    }

    // ============================================
    // STORAGE STRUCT
    // ============================================

    struct SpecimenEvolutionStorage {
        // Configuration
        EvolutionConfig config;

        // Evolution tiers (level => tier data)
        // Tier 1 = evolve from 0 to 1, Tier 5 = evolve from 4 to 5
        mapping(uint8 => EvolutionTier) evolutionTiers;

        // Token evolution state
        // Key: keccak256(collectionId, tokenId) => SpecimenEvolution
        mapping(bytes32 => SpecimenEvolution) specimenEvolutions;

        // Per-collection configuration
        mapping(uint256 => CollectionEvolutionConfig) collectionConfigs;

        // Statistics
        uint256 totalEvolutionsPerformed;
        uint256 totalResourcesConsumed;
        uint256 totalTokensConsumed;
        mapping(uint8 => uint256) evolutionsPerLevel; // Count per level

        // Evolution history (for analytics)
        mapping(bytes32 => uint32[]) evolutionHistory; // specimenKey => timestamps

        // Version for upgrades
        uint256 storageVersion;
    }

    // ============================================
    // STORAGE ACCESSOR
    // ============================================

    function specimenEvolutionStorage() internal pure returns (SpecimenEvolutionStorage storage ses) {
        bytes32 position = SPECIMEN_EVOLUTION_STORAGE_POSITION;
        assembly {
            ses.slot := position
        }
    }

    // ============================================
    // HELPER FUNCTIONS
    // ============================================

    /**
     * @notice Generate unique key for specimen (token)
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @return key Unique identifier
     */
    function getSpecimenKey(uint256 collectionId, uint256 tokenId) internal pure returns (bytes32 key) {
        return keccak256(abi.encodePacked(collectionId, tokenId));
    }

    /**
     * @notice Get specimen's current evolution level
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @return level Current level (0 = not evolved)
     */
    function getSpecimenLevel(uint256 collectionId, uint256 tokenId) internal view returns (uint8 level) {
        SpecimenEvolutionStorage storage ses = specimenEvolutionStorage();
        bytes32 key = getSpecimenKey(collectionId, tokenId);
        return ses.specimenEvolutions[key].currentLevel;
    }

    /**
     * @notice Check if specimen can evolve to next level
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @return canEvolve True if evolution is possible
     * @return reason Reason if cannot evolve
     */
    function canSpecimenEvolve(
        uint256 collectionId,
        uint256 tokenId
    ) internal view returns (bool canEvolve, string memory reason) {
        SpecimenEvolutionStorage storage ses = specimenEvolutionStorage();

        // Check system enabled
        if (!ses.config.systemEnabled) {
            return (false, "Evolution system disabled");
        }

        // Check collection enabled
        CollectionEvolutionConfig storage collConfig = ses.collectionConfigs[collectionId];
        if (!collConfig.evolutionEnabled) {
            return (false, "Collection not evolution-enabled");
        }

        bytes32 key = getSpecimenKey(collectionId, tokenId);
        SpecimenEvolution storage evolution = ses.specimenEvolutions[key];

        // Check if locked
        if (evolution.locked) {
            return (false, "Specimen evolution locked");
        }

        // Check max level
        uint8 maxLevel = collConfig.maxLevelOverride > 0
            ? collConfig.maxLevelOverride
            : ses.config.maxLevel;

        if (evolution.currentLevel >= maxLevel) {
            return (false, "Already at max level");
        }

        // Check cooldown
        uint8 nextLevel = evolution.currentLevel + 1;
        EvolutionTier storage tier = ses.evolutionTiers[nextLevel];

        if (!tier.enabled) {
            return (false, "Next tier not enabled");
        }

        if (evolution.lastEvolutionTime + tier.cooldownSeconds > block.timestamp) {
            return (false, "Cooldown not finished");
        }

        return (true, "");
    }

    /**
     * @notice Get total boosts for a specimen
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @return statBoostBps Total stat boost in basis points
     * @return productionBoostBps Total production boost in basis points
     */
    function getSpecimenBoosts(
        uint256 collectionId,
        uint256 tokenId
    ) internal view returns (uint16 statBoostBps, uint16 productionBoostBps) {
        SpecimenEvolutionStorage storage ses = specimenEvolutionStorage();
        bytes32 key = getSpecimenKey(collectionId, tokenId);
        SpecimenEvolution storage evolution = ses.specimenEvolutions[key];

        // Apply collection multiplier if set
        CollectionEvolutionConfig storage collConfig = ses.collectionConfigs[collectionId];
        uint16 multiplier = collConfig.bonusMultiplierBps > 0
            ? collConfig.bonusMultiplierBps
            : 10000; // Default 1x

        statBoostBps = uint16((uint256(evolution.totalStatBoost) * multiplier) / 10000);
        productionBoostBps = uint16((uint256(evolution.totalProductionBoost) * multiplier) / 10000);

        return (statBoostBps, productionBoostBps);
    }

    /**
     * @notice Initialize default evolution tiers
     * @dev Called during first setup
     */
    function initializeDefaultTiers() internal {
        SpecimenEvolutionStorage storage ses = specimenEvolutionStorage();

        if (ses.storageVersion > 0) return; // Already initialized

        // Tier 1: Level 0 → 1 (Basic evolution)
        ses.evolutionTiers[1] = EvolutionTier({
            resourceCosts: [uint256(500 ether), 100 ether, 0, 0],
            tokenCost: 10 ether,
            statBoostBps: 500,       // +5%
            productionBoostBps: 300, // +3%
            cooldownSeconds: 0,      // No cooldown for first
            requiresPreviousTier: false,
            enabled: true
        });

        // Tier 2: Level 1 → 2
        ses.evolutionTiers[2] = EvolutionTier({
            resourceCosts: [uint256(1000 ether), 300 ether, 200 ether, 0],
            tokenCost: 25 ether,
            statBoostBps: 750,       // +7.5%
            productionBoostBps: 500, // +5%
            cooldownSeconds: 3600,   // 1 hour cooldown
            requiresPreviousTier: true,
            enabled: true
        });

        // Tier 3: Level 2 → 3
        ses.evolutionTiers[3] = EvolutionTier({
            resourceCosts: [uint256(2500 ether), 500 ether, 500 ether, 100 ether],
            tokenCost: 50 ether,
            statBoostBps: 1000,      // +10%
            productionBoostBps: 750, // +7.5%
            cooldownSeconds: 7200,   // 2 hours cooldown
            requiresPreviousTier: true,
            enabled: true
        });

        // Tier 4: Level 3 → 4
        ses.evolutionTiers[4] = EvolutionTier({
            resourceCosts: [uint256(5000 ether), 1000 ether, 1000 ether, 500 ether],
            tokenCost: 100 ether,
            statBoostBps: 1500,       // +15%
            productionBoostBps: 1000, // +10%
            cooldownSeconds: 14400,   // 4 hours cooldown
            requiresPreviousTier: true,
            enabled: true
        });

        // Tier 5: Level 4 → 5 (Max)
        ses.evolutionTiers[5] = EvolutionTier({
            resourceCosts: [uint256(10000 ether), 2000 ether, 2000 ether, 1000 ether],
            tokenCost: 200 ether,
            statBoostBps: 2500,       // +25%
            productionBoostBps: 1500, // +15%
            cooldownSeconds: 28800,   // 8 hours cooldown
            requiresPreviousTier: true,
            enabled: true
        });

        // Set default config
        ses.config.maxLevel = 5;
        ses.config.systemEnabled = true;
        ses.config.useGovernanceToken = false; // Use YLW by default
        ses.config.failureRefundBps = 0; // No failure mechanic initially

        ses.storageVersion = 1;
    }
}
