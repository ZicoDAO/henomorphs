// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/**
 * @title LibBuildingsStorage
 * @notice Dedicated storage library for Colony Buildings System
 * @dev Uses Diamond storage pattern with unique position - safe for proxy upgrades
 * @author rutilicus.eth (ArchXS)
 */
library LibBuildingsStorage {
    bytes32 constant BUILDINGS_STORAGE_POSITION = keccak256("henomorphs.buildings.storage.v1");

    // ============================================
    // BUILDING TYPES
    // ============================================

    uint8 constant BUILDING_WAREHOUSE = 0;       // Reduces resource decay
    uint8 constant BUILDING_REFINERY = 1;        // Increases processing efficiency
    uint8 constant BUILDING_LABORATORY = 2;      // Increases tech level, unlocks recipes
    uint8 constant BUILDING_DEFENSE_TOWER = 3;   // Raid protection
    uint8 constant BUILDING_TRADE_HUB = 4;       // Reduces marketplace fees
    uint8 constant BUILDING_ENERGY_PLANT = 5;    // Passive energy generation
    uint8 constant BUILDING_BIO_LAB = 6;         // Passive bio compound generation
    uint8 constant BUILDING_MINING_OUTPOST = 7;  // Passive basic materials generation

    uint8 constant MAX_BUILDING_TYPE = 7;
    uint8 constant MAX_BUILDING_LEVEL = 5;

    // ============================================
    // STRUCTS
    // ============================================

    /**
     * @notice Building instance in a colony
     */
    struct Building {
        uint8 buildingType;           // Type of building (0-7)
        uint8 level;                  // Current level (1-5)
        uint32 constructionStart;     // When construction started (0 if complete)
        uint32 constructionEnd;       // When construction completes
        uint32 lastMaintenancePaid;   // Last maintenance payment timestamp
        bool active;                  // Whether building is operational
        bool underConstruction;       // Currently being built/upgraded
    }

    /**
     * @notice Building blueprint - costs and effects per level
     */
    struct BuildingBlueprint {
        uint256[4] resourceCosts;     // [basic, energy, bio, rare] per level
        uint256 tokenCost;            // YLW cost per level
        uint32 constructionTime;      // Base construction time in seconds
        uint16[5] effectValues;       // Effect value per level (level 1-5)
        uint256 maintenanceCost;      // Weekly maintenance in YLW
        bool enabled;                 // Whether this building type is available
    }

    /**
     * @notice Building effects for a colony (computed from all buildings)
     */
    struct ColonyBuildingEffects {
        uint16 decayReductionBps;     // Warehouse effect (basis points)
        uint16 processingBonusBps;    // Refinery effect
        uint8 techLevelBonus;         // Laboratory effect
        uint16 raidResistanceBps;     // Defense Tower effect
        uint16 marketFeeReductionBps; // Trade Hub effect
        uint256 passiveEnergyPerDay;  // Energy Plant effect
        uint256 passiveBioPerDay;     // Bio Lab effect
        uint256 passiveBasicPerDay;   // Mining Outpost effect
    }

    /**
     * @notice Global buildings configuration
     */
    struct BuildingsConfig {
        bool systemEnabled;           // Master switch
        uint8 maxBuildingsPerColony;  // Max total buildings per colony
        uint8 maxPerBuildingType;     // Max buildings of same type
        uint32 maintenancePeriod;     // Maintenance period in seconds (default: 7 days)
        uint16 maintenancePenaltyBps; // Penalty per missed period (bps)
        address utilityToken;         // YLW address for construction/maintenance costs
        address governanceToken;      // ZICO address for premium operations (optional)
        address beneficiary;          // Where fees go
        bool burnOnCollect;           // Whether to burn YLW instead of transferring to beneficiary
        bool useGovernanceForPremium; // Use ZICO for premium buildings (level 4-5)
    }

    // ============================================
    // BUILDING CARDS SYSTEM - ENUMS & STRUCTS (v3)
    // ============================================

    /**
     * @notice Card rarity levels with predefined bonus ranges
     * @dev Based on industry standards (Parallel, Gods Unchained, Axie)
     */
    enum CardRarity {
        Common,      // 0: 500-1000 bps bonus (5-10%)
        Uncommon,    // 1: 1000-1500 bps bonus (10-15%)
        Rare,        // 2: 1500-2500 bps bonus (15-25%)
        Epic,        // 3: 2500-4000 bps bonus (25-40%)
        Legendary,   // 4: 4000-6000 bps bonus (40-60%)
        Mythic       // 5: 6000-10000 bps bonus (60-100%)
    }

    /**
     * @notice Card system compatibility - which game system the card works with
     * @dev Allows a single card system to serve multiple game mechanics
     */
    enum CardCompatibleSystem {
        Buildings,   // 0: Colony buildings only
        Evolution,   // 1: Specimen evolution system
        Venture,     // 2: Resource venture system
        Universal    // 3: Works with all systems
    }

    /**
     * @notice Card type definition - determines compatibility and base stats
     * @dev v4: Added compatibleSystems for multi-system support
     */
    struct CardTypeDefinition {
        string name;                      // "Warehouse Booster", "Defense Matrix", etc.
        uint8 compatibleBuildingType;     // Which building type this card works with (255 = universal building)
        CardRarity minRarity;             // Minimum rarity for this card type
        uint16 baseBonusBps;              // Base bonus in basis points
        uint16 rarityScalingBps;          // Additional bonus per rarity level
        bool stackable;                   // Can multiple cards of same type be used (for future)
        bool enabled;                     // Card type is active
        CardCompatibleSystem system;      // Which game system this card works with
        uint8 evolutionTierBonus;         // Additional evolution tier boost (0-5)
        uint16 ventureSuccessBoostBps;    // Additional venture success rate boost
    }

    /**
     * @notice Card attached to a specimen for evolution bonuses
     * @dev Mirrors AttachedCard structure for building cards
     */
    struct SpecimenAttachedCard {
        uint256 tokenId;                  // NFT token ID
        uint16 collectionId;              // Which collection this card is from
        uint8 cardTypeId;                 // Card type definition ID
        CardRarity rarity;                // Card rarity
        uint16 computedBonusBps;          // Pre-computed total bonus for cost reduction
        uint8 tierBonus;                  // Additional evolution tier boost
        uint32 attachedAt;                // When card was attached
        uint32 cooldownUntil;             // Cannot detach until this time
        bool locked;                      // Locked during evolution
    }

    /**
     * @notice Card attached to a venture for success/reward bonuses
     * @dev Mirrors AttachedCard structure for building cards
     */
    struct VentureAttachedCard {
        uint256 tokenId;                  // NFT token ID
        uint16 collectionId;              // Which collection this card is from
        uint8 cardTypeId;                 // Card type definition ID
        CardRarity rarity;                // Card rarity
        uint16 successBoostBps;           // Additional success rate boost
        uint16 rewardBoostBps;            // Additional reward multiplier
        uint32 attachedAt;                // When card was attached
        uint32 cooldownUntil;             // Cannot detach until this time
        bool locked;                      // Locked during active venture
    }

    /**
     * @notice Registered card collection with validation
     */
    struct CardCollection {
        address contractAddress;          // ERC721 contract address
        string name;                      // "Building Cards Genesis", etc.
        bool enabled;                     // Collection is active
        bool requiresVerification;        // Requires on-chain trait verification
        uint16 collectionBonusBps;        // Bonus for using this collection
        uint32 registeredAt;              // Registration timestamp
    }

    /**
     * @notice Attached card instance with full metadata
     */
    struct AttachedCard {
        uint256 tokenId;                  // NFT token ID
        uint16 collectionId;              // Which collection this card is from
        uint8 cardTypeId;                 // Card type definition ID
        CardRarity rarity;                // Card rarity
        uint16 computedBonusBps;          // Pre-computed total bonus
        uint32 attachedAt;                // When card was attached
        uint32 cooldownUntil;             // Cannot detach until this time
        bool locked;                      // Locked by external system (staking, etc.)
    }

    /**
     * @notice Card set definition for set bonuses
     */
    struct CardSet {
        string name;                      // "Genesis Complete", "Defense Mastery"
        uint8[] requiredCardTypes;        // Card types needed for this set
        uint16 setBonusBps;               // Bonus when set is complete
        bool enabled;                     // Set is active
    }

    /**
     * @notice Card system configuration
     */
    struct CardSystemConfig {
        bool systemEnabled;               // Master switch for card system
        uint32 attachCooldownSeconds;     // Cooldown after attaching (anti-swap exploit)
        uint32 detachCooldownSeconds;     // Cooldown after detaching
        uint16 maxBonusCapBps;            // Maximum total bonus from cards (default: 10000 = 100%)
        uint8 maxCardsPerColony;          // Maximum cards attached per colony
        bool requireOwnership;            // Must own card to attach (vs delegated)
        address verifierContract;         // Optional: external verifier for card traits
    }

    /**
     * @notice Configurable rarity bonus values (not hardcoded)
     * @dev Allows adjusting rarity bonuses without code deployment
     */
    struct RarityBonusConfig {
        uint16 commonBonusBps;            // Default: 500 (5%)
        uint16 uncommonBonusBps;          // Default: 1000 (10%)
        uint16 rareBonusBps;              // Default: 1500 (15%)
        uint16 epicBonusBps;              // Default: 2500 (25%)
        uint16 legendaryBonusBps;         // Default: 4000 (40%)
        uint16 mythicBonusBps;            // Default: 6000 (60%)
    }

    // ============================================
    // STORAGE STRUCT
    // ============================================

    struct BuildingsStorage {
        // Configuration
        BuildingsConfig config;

        // Building blueprints (buildingType => blueprint)
        mapping(uint8 => BuildingBlueprint) blueprints;

        // Colony buildings
        // colonyId => buildingType => Building
        mapping(bytes32 => mapping(uint8 => Building)) colonyBuildings;

        // Colony building counts
        mapping(bytes32 => uint8) colonyBuildingCount;

        // Passive generation tracking
        mapping(bytes32 => uint32) lastPassiveClaimTime;

        // Statistics
        uint256 totalBuildingsConstructed;
        uint256 totalUpgradesPerformed;
        uint256 totalMaintenancePaid;
        mapping(uint8 => uint256) buildingsPerType;

        // Version for upgrades
        uint256 storageVersion;

        // ============================================
        // BUILDING CARDS INTEGRATION (APPEND-ONLY v2)
        // ============================================

        /**
         * @notice Building Cards collection contract address
         */
        address buildingCardsContract;

        /**
         * @notice Attached card token ID per building slot
         * @dev colonyId => buildingType => tokenId (0 = no card attached)
         */
        mapping(bytes32 => mapping(uint8 => uint256)) attachedBuildingCard;

        /**
         * @notice Card rarity bonus multiplier
         * @dev colonyId => buildingType => bonus in basis points
         */
        mapping(bytes32 => mapping(uint8 => uint16)) cardRarityBonus;

        /**
         * @notice Track which colonies have card token attached
         * @dev tokenId => colonyId (bytes32(0) if not attached)
         */
        mapping(uint256 => bytes32) cardToColony;

        /**
         * @notice Track building type of attached card
         * @dev tokenId => buildingType
         */
        mapping(uint256 => uint8) cardToBuildingType;

        /**
         * @notice Whether card mode is enabled (optional alternative to resource construction)
         */
        bool cardModeEnabled;

        // ============================================
        // BUILDING CARDS SYSTEM - EXTENDED STORAGE (v3)
        // ============================================

        /**
         * @notice Card system configuration
         */
        CardSystemConfig cardConfig;

        /**
         * @notice Configurable rarity bonus values
         */
        RarityBonusConfig rarityBonuses;

        /**
         * @notice Registered card collections
         * @dev collectionId => CardCollection
         */
        mapping(uint16 => CardCollection) cardCollections;
        uint16 cardCollectionCounter;

        /**
         * @notice Card type definitions
         * @dev cardTypeId => CardTypeDefinition
         */
        mapping(uint8 => CardTypeDefinition) cardTypes;
        uint8 cardTypeCounter;

        /**
         * @notice Full attached card data (replaces simple tokenId mapping)
         * @dev colonyId => buildingType => AttachedCard
         */
        mapping(bytes32 => mapping(uint8 => AttachedCard)) attachedCards;

        /**
         * @notice User card attachment cooldown tracking
         * @dev user => last detach timestamp
         */
        mapping(address => uint32) userLastDetachTime;

        /**
         * @notice Card sets registry
         * @dev setId => CardSet
         */
        mapping(uint8 => CardSet) cardSets;
        uint8 cardSetCounter;

        /**
         * @notice Active sets per colony (for bonus calculation)
         * @dev colonyId => array of active set IDs
         */
        mapping(bytes32 => uint8[]) colonyActiveSets;

        /**
         * @notice Colony total card bonus cache (for gas optimization)
         * @dev colonyId => cached total bonus (invalidate on card change)
         */
        mapping(bytes32 => uint16) colonyCardBonusCache;
        mapping(bytes32 => uint32) colonyCardBonusCacheTime;

        /**
         * @notice Statistics for card system
         */
        uint256 totalCardsAttached;
        uint256 totalCardDetachments;
        mapping(uint16 => uint256) cardsPerCollection;
        mapping(uint8 => uint256) cardsPerType;

        // ============================================
        // MULTI-SYSTEM CARD SUPPORT (v4)
        // ============================================

        /**
         * @notice Cards attached to specimens for evolution bonuses
         * @dev specimenKey (keccak256(collection, tokenId)) => SpecimenAttachedCard
         */
        mapping(bytes32 => SpecimenAttachedCard) specimenCards;

        /**
         * @notice Track which specimen has card attached
         * @dev tokenId => specimenKey (bytes32(0) if not attached)
         */
        mapping(uint256 => bytes32) cardToSpecimen;

        /**
         * @notice Cards attached to venture types for success/reward bonuses
         * @dev user => ventureType => VentureAttachedCard
         */
        mapping(address => mapping(uint8 => VentureAttachedCard)) ventureCards;

        /**
         * @notice Track which user/venture has card attached
         * @dev tokenId => user address (address(0) if not attached)
         */
        mapping(uint256 => address) cardToVentureUser;
        mapping(uint256 => uint8) cardToVentureType;

        /**
         * @notice Maximum cards per specimen
         */
        uint8 maxCardsPerSpecimen;

        /**
         * @notice Maximum cards per venture slot
         */
        uint8 maxCardsPerVentureSlot;

        /**
         * @notice Statistics for multi-system cards
         */
        uint256 totalSpecimenCardsAttached;
        uint256 totalVentureCardsAttached;
        mapping(CardCompatibleSystem => uint256) cardsPerSystem;
    }

    // ============================================
    // STORAGE ACCESSOR
    // ============================================

    function buildingsStorage() internal pure returns (BuildingsStorage storage bs) {
        bytes32 position = BUILDINGS_STORAGE_POSITION;
        assembly {
            bs.slot := position
        }
    }

    // ============================================
    // HELPER FUNCTIONS
    // ============================================

    /**
     * @notice Calculate building effects for a colony
     * @param colonyId Colony identifier
     * @return effects Computed effects from all buildings
     */
    function getColonyBuildingEffects(bytes32 colonyId) internal view returns (ColonyBuildingEffects memory effects) {
        BuildingsStorage storage bs = buildingsStorage();

        // Iterate through all building types
        for (uint8 i = 0; i <= MAX_BUILDING_TYPE; i++) {
            Building storage building = bs.colonyBuildings[colonyId][i];

            if (!building.active || building.underConstruction || building.level == 0) {
                continue;
            }

            // Check maintenance status - reduce effectiveness if overdue
            uint16 effectMultiplier = getMaintenanceMultiplier(building, bs.config);

            BuildingBlueprint storage blueprint = bs.blueprints[i];
            uint16 baseEffect = blueprint.effectValues[building.level - 1];
            uint16 adjustedEffect = uint16((uint256(baseEffect) * effectMultiplier) / 10000);

            // Apply effect based on building type
            if (i == BUILDING_WAREHOUSE) {
                effects.decayReductionBps += adjustedEffect;
            } else if (i == BUILDING_REFINERY) {
                effects.processingBonusBps += adjustedEffect;
            } else if (i == BUILDING_LABORATORY) {
                effects.techLevelBonus += uint8(adjustedEffect / 100); // Convert bps to level
            } else if (i == BUILDING_DEFENSE_TOWER) {
                effects.raidResistanceBps += adjustedEffect;
            } else if (i == BUILDING_TRADE_HUB) {
                effects.marketFeeReductionBps += adjustedEffect;
            } else if (i == BUILDING_ENERGY_PLANT) {
                effects.passiveEnergyPerDay += adjustedEffect * 1 ether; // Scale to token units
            } else if (i == BUILDING_BIO_LAB) {
                effects.passiveBioPerDay += adjustedEffect * 1 ether;
            } else if (i == BUILDING_MINING_OUTPOST) {
                effects.passiveBasicPerDay += adjustedEffect * 1 ether;
            }
        }

        // Cap effects at reasonable maximums
        if (effects.decayReductionBps > 5000) effects.decayReductionBps = 5000; // Max 50% decay reduction
        if (effects.processingBonusBps > 5000) effects.processingBonusBps = 5000;
        if (effects.raidResistanceBps > 7500) effects.raidResistanceBps = 7500; // Max 75% raid resist
        if (effects.marketFeeReductionBps > 5000) effects.marketFeeReductionBps = 5000;

        return effects;
    }

    /**
     * @notice Get maintenance multiplier (100% if paid, less if overdue)
     */
    function getMaintenanceMultiplier(
        Building storage building,
        BuildingsConfig storage config
    ) internal view returns (uint16 multiplier) {
        if (building.lastMaintenancePaid == 0) {
            return 10000; // 100% - new building, grace period
        }

        uint32 timeSinceMaintenance = uint32(block.timestamp) - building.lastMaintenancePaid;

        if (timeSinceMaintenance <= config.maintenancePeriod) {
            return 10000; // 100% - maintenance is current
        }

        // Calculate penalty
        uint32 periodsOverdue = (timeSinceMaintenance - config.maintenancePeriod) / config.maintenancePeriod;
        uint16 penalty = uint16(periodsOverdue) * config.maintenancePenaltyBps;

        if (penalty >= 9000) {
            return 1000; // Minimum 10% effectiveness
        }

        return 10000 - penalty;
    }

    /**
     * @notice Check if colony can build a specific building
     * @param colonyId Colony ID
     * @param buildingType Building type
     * @return canBuild True if can build
     * @return reason Reason if cannot
     */
    function canColonyBuild(
        bytes32 colonyId,
        uint8 buildingType
    ) internal view returns (bool canBuild, string memory reason) {
        BuildingsStorage storage bs = buildingsStorage();

        if (!bs.config.systemEnabled) {
            return (false, "Buildings system disabled");
        }

        if (buildingType > MAX_BUILDING_TYPE) {
            return (false, "Invalid building type");
        }

        if (!bs.blueprints[buildingType].enabled) {
            return (false, "Building type not enabled");
        }

        Building storage existing = bs.colonyBuildings[colonyId][buildingType];

        if (existing.active) {
            return (false, "Building already exists");
        }

        if (existing.underConstruction) {
            return (false, "Building under construction");
        }

        if (bs.colonyBuildingCount[colonyId] >= bs.config.maxBuildingsPerColony) {
            return (false, "Max buildings reached");
        }

        return (true, "");
    }

    /**
     * @notice Check if building can be upgraded
     * @param colonyId Colony ID
     * @param buildingType Building type
     * @return canUpgrade True if can upgrade
     * @return reason Reason if cannot
     */
    function canUpgradeBuilding(
        bytes32 colonyId,
        uint8 buildingType
    ) internal view returns (bool canUpgrade, string memory reason) {
        BuildingsStorage storage bs = buildingsStorage();

        if (!bs.config.systemEnabled) {
            return (false, "Buildings system disabled");
        }

        Building storage building = bs.colonyBuildings[colonyId][buildingType];

        if (!building.active) {
            return (false, "Building does not exist");
        }

        if (building.underConstruction) {
            return (false, "Building under construction");
        }

        if (building.level >= MAX_BUILDING_LEVEL) {
            return (false, "Already at max level");
        }

        return (true, "");
    }

    /**
     * @notice Initialize default building blueprints
     */
    function initializeDefaultBlueprints() internal {
        BuildingsStorage storage bs = buildingsStorage();

        if (bs.storageVersion > 0) return; // Already initialized

        // Warehouse - reduces decay
        bs.blueprints[BUILDING_WAREHOUSE] = BuildingBlueprint({
            resourceCosts: [uint256(1000 ether), 200 ether, 0, 0],
            tokenCost: 50 ether,
            constructionTime: 3600,      // 1 hour
            effectValues: [uint16(1000), 1500, 2000, 3000, 5000], // 10%, 15%, 20%, 30%, 50% decay reduction
            maintenanceCost: 25 ether,   // 25 YLW per week
            enabled: true
        });

        // Refinery - processing bonus
        bs.blueprints[BUILDING_REFINERY] = BuildingBlueprint({
            resourceCosts: [uint256(1500 ether), 500 ether, 100 ether, 0],
            tokenCost: 75 ether,
            constructionTime: 7200,      // 2 hours
            effectValues: [uint16(500), 1000, 1500, 2500, 4000], // 5%, 10%, 15%, 25%, 40% processing bonus
            maintenanceCost: 40 ether,
            enabled: true
        });

        // Laboratory - tech level
        bs.blueprints[BUILDING_LABORATORY] = BuildingBlueprint({
            resourceCosts: [uint256(500 ether), 300 ether, 500 ether, 100 ether],
            tokenCost: 100 ether,
            constructionTime: 14400,     // 4 hours
            effectValues: [uint16(100), 200, 300, 400, 500], // +1, +2, +3, +4, +5 tech levels
            maintenanceCost: 60 ether,
            enabled: true
        });

        // Defense Tower - raid resistance
        bs.blueprints[BUILDING_DEFENSE_TOWER] = BuildingBlueprint({
            resourceCosts: [uint256(2000 ether), 500 ether, 0, 200 ether],
            tokenCost: 80 ether,
            constructionTime: 10800,     // 3 hours
            effectValues: [uint16(1000), 2000, 3500, 5000, 7500], // 10%, 20%, 35%, 50%, 75% raid resist
            maintenanceCost: 50 ether,
            enabled: true
        });

        // Trade Hub - marketplace fee reduction
        bs.blueprints[BUILDING_TRADE_HUB] = BuildingBlueprint({
            resourceCosts: [uint256(800 ether), 400 ether, 200 ether, 50 ether],
            tokenCost: 60 ether,
            constructionTime: 5400,      // 1.5 hours
            effectValues: [uint16(500), 1000, 1500, 2500, 4000], // 5%, 10%, 15%, 25%, 40% fee reduction
            maintenanceCost: 30 ether,
            enabled: true
        });

        // Energy Plant - passive energy generation
        bs.blueprints[BUILDING_ENERGY_PLANT] = BuildingBlueprint({
            resourceCosts: [uint256(1200 ether), 800 ether, 200 ether, 0],
            tokenCost: 70 ether,
            constructionTime: 7200,      // 2 hours
            effectValues: [uint16(50), 100, 200, 350, 500], // 50, 100, 200, 350, 500 energy per day
            maintenanceCost: 35 ether,
            enabled: true
        });

        // Bio Lab - passive bio generation
        bs.blueprints[BUILDING_BIO_LAB] = BuildingBlueprint({
            resourceCosts: [uint256(600 ether), 200 ether, 600 ether, 100 ether],
            tokenCost: 80 ether,
            constructionTime: 10800,     // 3 hours
            effectValues: [uint16(30), 60, 120, 200, 300], // 30, 60, 120, 200, 300 bio per day
            maintenanceCost: 45 ether,
            enabled: true
        });

        // Mining Outpost - passive basic materials generation
        bs.blueprints[BUILDING_MINING_OUTPOST] = BuildingBlueprint({
            resourceCosts: [uint256(1500 ether), 300 ether, 0, 0],
            tokenCost: 40 ether,
            constructionTime: 3600,      // 1 hour
            effectValues: [uint16(100), 200, 400, 700, 1000], // 100, 200, 400, 700, 1000 basic per day
            maintenanceCost: 20 ether,
            enabled: true
        });

        // Set default config
        bs.config.systemEnabled = true;
        bs.config.maxBuildingsPerColony = 8;      // Can have all 8 types
        bs.config.maxPerBuildingType = 1;         // One of each type
        bs.config.maintenancePeriod = 604800;     // 7 days
        bs.config.maintenancePenaltyBps = 2000;   // 20% per missed week

        bs.storageVersion = 1;
    }

    // ============================================
    // BUILDING CARDS INTEGRATION HELPERS (v2)
    // ============================================

    /**
     * @notice Check if building slot has card attached
     * @param colonyId Colony identifier
     * @param buildingType Building type
     * @return hasCard True if card is attached
     */
    function hasBuildingCard(bytes32 colonyId, uint8 buildingType) internal view returns (bool hasCard) {
        BuildingsStorage storage bs = buildingsStorage();
        return bs.attachedBuildingCard[colonyId][buildingType] != 0;
    }

    /**
     * @notice Get attached card token ID
     * @param colonyId Colony identifier
     * @param buildingType Building type
     * @return tokenId Card token ID (0 if none)
     */
    function getAttachedCard(bytes32 colonyId, uint8 buildingType) internal view returns (uint256 tokenId) {
        BuildingsStorage storage bs = buildingsStorage();
        return bs.attachedBuildingCard[colonyId][buildingType];
    }

    /**
     * @notice Attach card to building slot
     * @param colonyId Colony identifier
     * @param buildingType Building type
     * @param tokenId Card token ID
     * @param rarityBonusBps Rarity bonus in basis points
     */
    function attachBuildingCard(
        bytes32 colonyId,
        uint8 buildingType,
        uint256 tokenId,
        uint16 rarityBonusBps
    ) internal {
        BuildingsStorage storage bs = buildingsStorage();

        bs.attachedBuildingCard[colonyId][buildingType] = tokenId;
        bs.cardRarityBonus[colonyId][buildingType] = rarityBonusBps;
        bs.cardToColony[tokenId] = colonyId;
        bs.cardToBuildingType[tokenId] = buildingType;
    }

    /**
     * @notice Detach card from building slot
     * @param colonyId Colony identifier
     * @param buildingType Building type
     * @return tokenId The detached token ID
     */
    function detachBuildingCard(bytes32 colonyId, uint8 buildingType) internal returns (uint256 tokenId) {
        BuildingsStorage storage bs = buildingsStorage();

        tokenId = bs.attachedBuildingCard[colonyId][buildingType];

        if (tokenId != 0) {
            delete bs.cardToColony[tokenId];
            delete bs.cardToBuildingType[tokenId];
        }

        delete bs.attachedBuildingCard[colonyId][buildingType];
        delete bs.cardRarityBonus[colonyId][buildingType];

        return tokenId;
    }

    /**
     * @notice Get card rarity bonus for a building
     * @param colonyId Colony identifier
     * @param buildingType Building type
     * @return bonusBps Bonus in basis points (0 if no card)
     */
    function getCardRarityBonus(bytes32 colonyId, uint8 buildingType) internal view returns (uint16 bonusBps) {
        BuildingsStorage storage bs = buildingsStorage();
        return bs.cardRarityBonus[colonyId][buildingType];
    }

    /**
     * @notice Get building effects with card bonuses applied
     * @param colonyId Colony identifier
     * @return effects Computed effects with card bonuses
     */
    function getColonyBuildingEffectsWithCards(bytes32 colonyId) internal view returns (ColonyBuildingEffects memory effects) {
        BuildingsStorage storage bs = buildingsStorage();

        for (uint8 i = 0; i <= MAX_BUILDING_TYPE; i++) {
            Building storage building = bs.colonyBuildings[colonyId][i];

            if (!building.active || building.underConstruction || building.level == 0) {
                continue;
            }

            // Base maintenance multiplier
            uint16 effectMultiplier = getMaintenanceMultiplier(building, bs.config);

            // Apply card rarity bonus if attached
            uint16 cardBonus = bs.cardRarityBonus[colonyId][i];
            if (cardBonus > 0) {
                // Card bonus adds to base effectiveness (capped at 200%)
                effectMultiplier = effectMultiplier + cardBonus;
                if (effectMultiplier > 20000) effectMultiplier = 20000;
            }

            BuildingBlueprint storage blueprint = bs.blueprints[i];
            uint16 baseEffect = blueprint.effectValues[building.level - 1];
            uint16 adjustedEffect = uint16((uint256(baseEffect) * effectMultiplier) / 10000);

            // Apply effect based on building type
            if (i == BUILDING_WAREHOUSE) {
                effects.decayReductionBps += adjustedEffect;
            } else if (i == BUILDING_REFINERY) {
                effects.processingBonusBps += adjustedEffect;
            } else if (i == BUILDING_LABORATORY) {
                effects.techLevelBonus += uint8(adjustedEffect / 100);
            } else if (i == BUILDING_DEFENSE_TOWER) {
                effects.raidResistanceBps += adjustedEffect;
            } else if (i == BUILDING_TRADE_HUB) {
                effects.marketFeeReductionBps += adjustedEffect;
            } else if (i == BUILDING_ENERGY_PLANT) {
                effects.passiveEnergyPerDay += adjustedEffect * 1 ether;
            } else if (i == BUILDING_BIO_LAB) {
                effects.passiveBioPerDay += adjustedEffect * 1 ether;
            } else if (i == BUILDING_MINING_OUTPOST) {
                effects.passiveBasicPerDay += adjustedEffect * 1 ether;
            }
        }

        // Cap effects (higher caps with NFT bonuses possible)
        if (effects.decayReductionBps > 7500) effects.decayReductionBps = 7500;
        if (effects.processingBonusBps > 7500) effects.processingBonusBps = 7500;
        if (effects.raidResistanceBps > 9000) effects.raidResistanceBps = 9000;
        if (effects.marketFeeReductionBps > 7500) effects.marketFeeReductionBps = 7500;

        return effects;
    }

    // ============================================
    // BUILDING CARDS SYSTEM v3 - HELPER FUNCTIONS
    // ============================================

    /**
     * @notice Get base bonus for a rarity level (configurable via storage)
     * @param rarity Card rarity
     * @return baseBonusBps Base bonus in basis points
     */
    function getRarityBaseBonus(CardRarity rarity) internal view returns (uint16 baseBonusBps) {
        BuildingsStorage storage bs = buildingsStorage();
        RarityBonusConfig storage config = bs.rarityBonuses;

        if (rarity == CardRarity.Common) return config.commonBonusBps;
        if (rarity == CardRarity.Uncommon) return config.uncommonBonusBps;
        if (rarity == CardRarity.Rare) return config.rareBonusBps;
        if (rarity == CardRarity.Epic) return config.epicBonusBps;
        if (rarity == CardRarity.Legendary) return config.legendaryBonusBps;
        if (rarity == CardRarity.Mythic) return config.mythicBonusBps;
        return 0;
    }

    /**
     * @notice Compute total bonus for a card
     * @param cardTypeId Card type ID
     * @param rarity Card rarity
     * @param collectionId Collection ID
     * @return totalBonusBps Total computed bonus
     */
    function computeCardBonus(
        uint8 cardTypeId,
        CardRarity rarity,
        uint16 collectionId
    ) internal view returns (uint16 totalBonusBps) {
        BuildingsStorage storage bs = buildingsStorage();

        CardTypeDefinition storage cardType = bs.cardTypes[cardTypeId];
        if (!cardType.enabled) return 0;

        // Base bonus from card type
        uint16 bonus = cardType.baseBonusBps;

        // Add rarity scaling
        bonus += uint16(uint8(rarity)) * cardType.rarityScalingBps;

        // Add rarity base bonus
        bonus += getRarityBaseBonus(rarity);

        // Add collection bonus
        CardCollection storage collection = bs.cardCollections[collectionId];
        if (collection.enabled) {
            bonus += collection.collectionBonusBps;
        }

        // Cap at max
        if (bonus > bs.cardConfig.maxBonusCapBps) {
            bonus = bs.cardConfig.maxBonusCapBps;
        }

        return bonus;
    }

    /**
     * @notice Check if card can be attached to building
     * @param cardTypeId Card type ID
     * @param buildingType Target building type
     * @return canAttach True if compatible
     * @return reason Reason if incompatible
     */
    function isCardCompatible(
        uint8 cardTypeId,
        uint8 buildingType
    ) internal view returns (bool canAttach, string memory reason) {
        BuildingsStorage storage bs = buildingsStorage();

        CardTypeDefinition storage cardType = bs.cardTypes[cardTypeId];

        if (!cardType.enabled) {
            return (false, "Card type not enabled");
        }

        // 255 = universal card, works with any building
        if (cardType.compatibleBuildingType != 255 &&
            cardType.compatibleBuildingType != buildingType) {
            return (false, "Card incompatible with building type");
        }

        return (true, "");
    }

    /**
     * @notice Check if user can attach card (cooldown check)
     * @param user User address
     * @return canAttach True if can attach
     * @return cooldownRemaining Seconds remaining if in cooldown
     */
    function canUserAttachCard(address user) internal view returns (bool canAttach, uint32 cooldownRemaining) {
        BuildingsStorage storage bs = buildingsStorage();

        uint32 lastDetach = bs.userLastDetachTime[user];
        if (lastDetach == 0) return (true, 0);

        uint32 cooldownEnd = lastDetach + bs.cardConfig.detachCooldownSeconds;
        if (block.timestamp >= cooldownEnd) return (true, 0);

        return (false, cooldownEnd - uint32(block.timestamp));
    }

    /**
     * @notice Check if card can be detached (cooldown check)
     * @param colonyId Colony identifier
     * @param buildingType Building type
     * @return canDetach True if can detach
     * @return cooldownRemaining Seconds remaining if in cooldown
     */
    function canDetachCard(
        bytes32 colonyId,
        uint8 buildingType
    ) internal view returns (bool canDetach, uint32 cooldownRemaining) {
        BuildingsStorage storage bs = buildingsStorage();

        AttachedCard storage card = bs.attachedCards[colonyId][buildingType];

        if (card.tokenId == 0) {
            return (false, 0); // No card to detach
        }

        if (card.locked) {
            return (false, type(uint32).max); // Locked by external system
        }

        if (block.timestamp < card.cooldownUntil) {
            return (false, card.cooldownUntil - uint32(block.timestamp));
        }

        return (true, 0);
    }

    /**
     * @notice Attach card with full metadata (v3)
     * @param colonyId Colony identifier
     * @param buildingType Building type
     * @param tokenId Card token ID
     * @param collectionId Collection ID
     * @param cardTypeId Card type ID
     * @param rarity Card rarity
     */
    function attachCardV3(
        bytes32 colonyId,
        uint8 buildingType,
        uint256 tokenId,
        uint16 collectionId,
        uint8 cardTypeId,
        CardRarity rarity
    ) internal {
        BuildingsStorage storage bs = buildingsStorage();

        uint16 computedBonus = computeCardBonus(cardTypeId, rarity, collectionId);

        bs.attachedCards[colonyId][buildingType] = AttachedCard({
            tokenId: tokenId,
            collectionId: collectionId,
            cardTypeId: cardTypeId,
            rarity: rarity,
            computedBonusBps: computedBonus,
            attachedAt: uint32(block.timestamp),
            cooldownUntil: uint32(block.timestamp) + bs.cardConfig.attachCooldownSeconds,
            locked: false
        });

        // Update legacy mappings for backwards compatibility
        bs.attachedBuildingCard[colonyId][buildingType] = tokenId;
        bs.cardRarityBonus[colonyId][buildingType] = computedBonus;
        bs.cardToColony[tokenId] = colonyId;
        bs.cardToBuildingType[tokenId] = buildingType;

        // Invalidate bonus cache
        delete bs.colonyCardBonusCache[colonyId];

        // Update statistics
        bs.totalCardsAttached++;
        bs.cardsPerCollection[collectionId]++;
        bs.cardsPerType[cardTypeId]++;
    }

    /**
     * @notice Detach card with cooldown (v3)
     * @param colonyId Colony identifier
     * @param buildingType Building type
     * @param user User performing detachment
     * @return card The detached card data
     */
    function detachCardV3(
        bytes32 colonyId,
        uint8 buildingType,
        address user
    ) internal returns (AttachedCard memory card) {
        BuildingsStorage storage bs = buildingsStorage();

        card = bs.attachedCards[colonyId][buildingType];

        if (card.tokenId != 0) {
            // Update statistics
            bs.totalCardDetachments++;
            if (bs.cardsPerCollection[card.collectionId] > 0) {
                bs.cardsPerCollection[card.collectionId]--;
            }
            if (bs.cardsPerType[card.cardTypeId] > 0) {
                bs.cardsPerType[card.cardTypeId]--;
            }

            // Clear legacy mappings
            delete bs.cardToColony[card.tokenId];
            delete bs.cardToBuildingType[card.tokenId];
            delete bs.attachedBuildingCard[colonyId][buildingType];
            delete bs.cardRarityBonus[colonyId][buildingType];
        }

        // Clear v3 data
        delete bs.attachedCards[colonyId][buildingType];

        // Set user cooldown
        bs.userLastDetachTime[user] = uint32(block.timestamp);

        // Invalidate bonus cache
        delete bs.colonyCardBonusCache[colonyId];

        return card;
    }

    /**
     * @notice Get attached card data (v3)
     * @param colonyId Colony identifier
     * @param buildingType Building type
     * @return card Full card data
     */
    function getAttachedCardV3(
        bytes32 colonyId,
        uint8 buildingType
    ) internal view returns (AttachedCard memory card) {
        BuildingsStorage storage bs = buildingsStorage();
        return bs.attachedCards[colonyId][buildingType];
    }

    /**
     * @notice Calculate total card bonus for colony (with caching)
     * @param colonyId Colony identifier
     * @return totalBonusBps Total bonus from all cards
     */
    function getColonyTotalCardBonus(bytes32 colonyId) internal view returns (uint16 totalBonusBps) {
        BuildingsStorage storage bs = buildingsStorage();

        // Check cache validity (5 minute cache)
        if (bs.colonyCardBonusCacheTime[colonyId] > 0 &&
            block.timestamp - bs.colonyCardBonusCacheTime[colonyId] < 300) {
            return bs.colonyCardBonusCache[colonyId];
        }

        // Calculate fresh
        uint256 total = 0;
        for (uint8 i = 0; i <= MAX_BUILDING_TYPE; i++) {
            AttachedCard storage card = bs.attachedCards[colonyId][i];
            if (card.tokenId != 0) {
                total += card.computedBonusBps;
            }
        }

        // Cap at maximum
        if (total > bs.cardConfig.maxBonusCapBps) {
            total = bs.cardConfig.maxBonusCapBps;
        }

        return uint16(total);
    }

    /**
     * @notice Check if colony has complete card set
     * @param colonyId Colony identifier
     * @param setId Set ID to check
     * @return isComplete True if all required cards present
     */
    function hasCompleteSet(bytes32 colonyId, uint8 setId) internal view returns (bool isComplete) {
        BuildingsStorage storage bs = buildingsStorage();

        CardSet storage cardSet = bs.cardSets[setId];
        if (!cardSet.enabled || cardSet.requiredCardTypes.length == 0) {
            return false;
        }

        for (uint256 i = 0; i < cardSet.requiredCardTypes.length; i++) {
            uint8 requiredType = cardSet.requiredCardTypes[i];
            bool found = false;

            for (uint8 j = 0; j <= MAX_BUILDING_TYPE; j++) {
                AttachedCard storage card = bs.attachedCards[colonyId][j];
                if (card.tokenId != 0 && card.cardTypeId == requiredType) {
                    found = true;
                    break;
                }
            }

            if (!found) return false;
        }

        return true;
    }

    /**
     * @notice Initialize default card system configuration
     */
    function initializeCardSystemDefaults() internal {
        BuildingsStorage storage bs = buildingsStorage();

        if (bs.cardConfig.systemEnabled) return; // Already initialized

        bs.cardConfig = CardSystemConfig({
            systemEnabled: true,
            attachCooldownSeconds: 3600,      // 1 hour after attach
            detachCooldownSeconds: 86400,     // 24 hours between detachments
            maxBonusCapBps: 10000,            // 100% max total bonus
            maxCardsPerColony: 8,             // One per building slot
            requireOwnership: true,
            verifierContract: address(0)
        });

        // Initialize configurable rarity bonuses (can be changed later via admin)
        bs.rarityBonuses = RarityBonusConfig({
            commonBonusBps: 500,       // 5%
            uncommonBonusBps: 1000,    // 10%
            rareBonusBps: 1500,        // 15%
            epicBonusBps: 2500,        // 25%
            legendaryBonusBps: 4000,   // 40%
            mythicBonusBps: 6000       // 60%
        });
    }

    /**
     * @notice Update rarity bonus configuration (admin only - called via facet)
     * @param config New rarity bonus configuration
     */
    function setRarityBonusConfig(RarityBonusConfig memory config) internal {
        BuildingsStorage storage bs = buildingsStorage();
        bs.rarityBonuses = config;
    }

    /**
     * @notice Get current rarity bonus configuration
     * @return config Current configuration
     */
    function getRarityBonusConfig() internal view returns (RarityBonusConfig memory config) {
        BuildingsStorage storage bs = buildingsStorage();
        return bs.rarityBonuses;
    }

    // ============================================
    // MULTI-SYSTEM CARD HELPERS (v4)
    // ============================================

    /**
     * @notice Check if card type is compatible with a system
     * @param cardTypeId Card type ID
     * @param targetSystem Target game system
     * @return isCompatible True if compatible
     */
    function isCardSystemCompatible(
        uint8 cardTypeId,
        CardCompatibleSystem targetSystem
    ) internal view returns (bool isCompatible) {
        BuildingsStorage storage bs = buildingsStorage();
        CardTypeDefinition storage cardType = bs.cardTypes[cardTypeId];

        if (!cardType.enabled) return false;

        // Universal cards work with everything
        if (cardType.system == CardCompatibleSystem.Universal) return true;

        return cardType.system == targetSystem;
    }

    /**
     * @notice Compute evolution card bonus
     * @param cardTypeId Card type ID
     * @param rarity Card rarity
     * @param collectionId Collection ID
     * @return costReductionBps Cost reduction for evolution
     * @return tierBonus Additional evolution tier boost
     */
    function computeEvolutionCardBonus(
        uint8 cardTypeId,
        CardRarity rarity,
        uint16 collectionId
    ) internal view returns (uint16 costReductionBps, uint8 tierBonus) {
        BuildingsStorage storage bs = buildingsStorage();

        CardTypeDefinition storage cardType = bs.cardTypes[cardTypeId];
        if (!cardType.enabled) return (0, 0);

        // Check system compatibility
        if (cardType.system != CardCompatibleSystem.Evolution &&
            cardType.system != CardCompatibleSystem.Universal) {
            return (0, 0);
        }

        // Base bonus from card type
        uint16 bonus = cardType.baseBonusBps;

        // Add rarity scaling
        bonus += uint16(uint8(rarity)) * cardType.rarityScalingBps;

        // Add rarity base bonus
        bonus += getRarityBaseBonus(rarity);

        // Add collection bonus
        CardCollection storage collection = bs.cardCollections[collectionId];
        if (collection.enabled) {
            bonus += collection.collectionBonusBps;
        }

        // Cap at max
        if (bonus > bs.cardConfig.maxBonusCapBps) {
            bonus = bs.cardConfig.maxBonusCapBps;
        }

        return (bonus, cardType.evolutionTierBonus);
    }

    /**
     * @notice Compute venture card bonus
     * @param cardTypeId Card type ID
     * @param rarity Card rarity
     * @param collectionId Collection ID
     * @return successBoostBps Success rate boost
     * @return rewardBoostBps Reward multiplier boost
     */
    function computeVentureCardBonus(
        uint8 cardTypeId,
        CardRarity rarity,
        uint16 collectionId
    ) internal view returns (uint16 successBoostBps, uint16 rewardBoostBps) {
        BuildingsStorage storage bs = buildingsStorage();

        CardTypeDefinition storage cardType = bs.cardTypes[cardTypeId];
        if (!cardType.enabled) return (0, 0);

        // Check system compatibility
        if (cardType.system != CardCompatibleSystem.Venture &&
            cardType.system != CardCompatibleSystem.Universal) {
            return (0, 0);
        }

        // Success boost from card type definition
        uint16 successBoost = cardType.ventureSuccessBoostBps;

        // Add rarity scaling for success boost
        successBoost += uint16(uint8(rarity)) * (cardType.rarityScalingBps / 2);

        // Reward boost from base bonus and rarity
        uint16 rewardBoost = cardType.baseBonusBps;
        rewardBoost += uint16(uint8(rarity)) * cardType.rarityScalingBps;
        rewardBoost += getRarityBaseBonus(rarity);

        // Add collection bonus to rewards
        CardCollection storage collection = bs.cardCollections[collectionId];
        if (collection.enabled) {
            rewardBoost += collection.collectionBonusBps;
        }

        // Cap at max
        if (successBoost > 2500) successBoost = 2500; // Max 25% success boost
        if (rewardBoost > bs.cardConfig.maxBonusCapBps) {
            rewardBoost = bs.cardConfig.maxBonusCapBps;
        }

        return (successBoost, rewardBoost);
    }

    /**
     * @notice Attach card to specimen for evolution bonuses
     * @param specimenKey Keccak256(collection, tokenId)
     * @param tokenId Card token ID
     * @param collectionId Collection ID
     * @param cardTypeId Card type ID
     * @param rarity Card rarity
     */
    function attachSpecimenCard(
        bytes32 specimenKey,
        uint256 tokenId,
        uint16 collectionId,
        uint8 cardTypeId,
        CardRarity rarity
    ) internal {
        BuildingsStorage storage bs = buildingsStorage();

        (uint16 costReduction, uint8 tierBonus) = computeEvolutionCardBonus(
            cardTypeId,
            rarity,
            collectionId
        );

        bs.specimenCards[specimenKey] = SpecimenAttachedCard({
            tokenId: tokenId,
            collectionId: collectionId,
            cardTypeId: cardTypeId,
            rarity: rarity,
            computedBonusBps: costReduction,
            tierBonus: tierBonus,
            attachedAt: uint32(block.timestamp),
            cooldownUntil: uint32(block.timestamp) + bs.cardConfig.attachCooldownSeconds,
            locked: false
        });

        bs.cardToSpecimen[tokenId] = specimenKey;

        // Update statistics
        bs.totalSpecimenCardsAttached++;
        bs.cardsPerSystem[CardCompatibleSystem.Evolution]++;
        bs.cardsPerCollection[collectionId]++;
        bs.cardsPerType[cardTypeId]++;
    }

    /**
     * @notice Detach card from specimen
     * @param specimenKey Keccak256(collection, tokenId)
     * @return card The detached card data
     */
    function detachSpecimenCard(
        bytes32 specimenKey
    ) internal returns (SpecimenAttachedCard memory card) {
        BuildingsStorage storage bs = buildingsStorage();

        card = bs.specimenCards[specimenKey];

        if (card.tokenId != 0) {
            // Update statistics
            if (bs.cardsPerCollection[card.collectionId] > 0) {
                bs.cardsPerCollection[card.collectionId]--;
            }
            if (bs.cardsPerType[card.cardTypeId] > 0) {
                bs.cardsPerType[card.cardTypeId]--;
            }
            if (bs.cardsPerSystem[CardCompatibleSystem.Evolution] > 0) {
                bs.cardsPerSystem[CardCompatibleSystem.Evolution]--;
            }

            delete bs.cardToSpecimen[card.tokenId];
        }

        delete bs.specimenCards[specimenKey];

        return card;
    }

    /**
     * @notice Get specimen card data
     * @param specimenKey Keccak256(collection, tokenId)
     * @return card Full card data
     */
    function getSpecimenCard(
        bytes32 specimenKey
    ) internal view returns (SpecimenAttachedCard memory card) {
        BuildingsStorage storage bs = buildingsStorage();
        return bs.specimenCards[specimenKey];
    }

    /**
     * @notice Check if specimen has card attached
     * @param specimenKey Keccak256(collection, tokenId)
     * @return hasCard True if card is attached
     */
    function hasSpecimenCard(bytes32 specimenKey) internal view returns (bool hasCard) {
        BuildingsStorage storage bs = buildingsStorage();
        return bs.specimenCards[specimenKey].tokenId != 0;
    }

    /**
     * @notice Attach card to venture slot for success/reward bonuses
     * @param user User address
     * @param ventureType Venture type (0-3)
     * @param tokenId Card token ID
     * @param collectionId Collection ID
     * @param cardTypeId Card type ID
     * @param rarity Card rarity
     */
    function attachVentureCard(
        address user,
        uint8 ventureType,
        uint256 tokenId,
        uint16 collectionId,
        uint8 cardTypeId,
        CardRarity rarity
    ) internal {
        BuildingsStorage storage bs = buildingsStorage();

        (uint16 successBoost, uint16 rewardBoost) = computeVentureCardBonus(
            cardTypeId,
            rarity,
            collectionId
        );

        bs.ventureCards[user][ventureType] = VentureAttachedCard({
            tokenId: tokenId,
            collectionId: collectionId,
            cardTypeId: cardTypeId,
            rarity: rarity,
            successBoostBps: successBoost,
            rewardBoostBps: rewardBoost,
            attachedAt: uint32(block.timestamp),
            cooldownUntil: uint32(block.timestamp) + bs.cardConfig.attachCooldownSeconds,
            locked: false
        });

        bs.cardToVentureUser[tokenId] = user;
        bs.cardToVentureType[tokenId] = ventureType;

        // Update statistics
        bs.totalVentureCardsAttached++;
        bs.cardsPerSystem[CardCompatibleSystem.Venture]++;
        bs.cardsPerCollection[collectionId]++;
        bs.cardsPerType[cardTypeId]++;
    }

    /**
     * @notice Detach card from venture slot
     * @param user User address
     * @param ventureType Venture type
     * @return card The detached card data
     */
    function detachVentureCard(
        address user,
        uint8 ventureType
    ) internal returns (VentureAttachedCard memory card) {
        BuildingsStorage storage bs = buildingsStorage();

        card = bs.ventureCards[user][ventureType];

        if (card.tokenId != 0) {
            // Update statistics
            if (bs.cardsPerCollection[card.collectionId] > 0) {
                bs.cardsPerCollection[card.collectionId]--;
            }
            if (bs.cardsPerType[card.cardTypeId] > 0) {
                bs.cardsPerType[card.cardTypeId]--;
            }
            if (bs.cardsPerSystem[CardCompatibleSystem.Venture] > 0) {
                bs.cardsPerSystem[CardCompatibleSystem.Venture]--;
            }

            delete bs.cardToVentureUser[card.tokenId];
            delete bs.cardToVentureType[card.tokenId];
        }

        delete bs.ventureCards[user][ventureType];

        return card;
    }

    /**
     * @notice Get venture card data
     * @param user User address
     * @param ventureType Venture type
     * @return card Full card data
     */
    function getVentureCard(
        address user,
        uint8 ventureType
    ) internal view returns (VentureAttachedCard memory card) {
        BuildingsStorage storage bs = buildingsStorage();
        return bs.ventureCards[user][ventureType];
    }

    /**
     * @notice Check if venture slot has card attached
     * @param user User address
     * @param ventureType Venture type
     * @return hasCard True if card is attached
     */
    function hasVentureCard(address user, uint8 ventureType) internal view returns (bool hasCard) {
        BuildingsStorage storage bs = buildingsStorage();
        return bs.ventureCards[user][ventureType].tokenId != 0;
    }

    /**
     * @notice Lock/unlock specimen card during evolution
     * @param specimenKey Keccak256(collection, tokenId)
     * @param locked Whether to lock or unlock
     */
    function setSpecimenCardLocked(bytes32 specimenKey, bool locked) internal {
        BuildingsStorage storage bs = buildingsStorage();
        if (bs.specimenCards[specimenKey].tokenId != 0) {
            bs.specimenCards[specimenKey].locked = locked;
        }
    }

    /**
     * @notice Lock/unlock venture card during active venture
     * @param user User address
     * @param ventureType Venture type
     * @param locked Whether to lock or unlock
     */
    function setVentureCardLocked(address user, uint8 ventureType, bool locked) internal {
        BuildingsStorage storage bs = buildingsStorage();
        if (bs.ventureCards[user][ventureType].tokenId != 0) {
            bs.ventureCards[user][ventureType].locked = locked;
        }
    }

    /**
     * @notice Get total bonus from all evolution-compatible cards for a user's specimens
     * @param specimenKeys Array of specimen keys
     * @return totalBonusBps Total cost reduction bonus
     * @return totalTierBonus Total tier bonus
     */
    function getEvolutionCardBonuses(
        bytes32[] memory specimenKeys
    ) internal view returns (uint16 totalBonusBps, uint8 totalTierBonus) {
        BuildingsStorage storage bs = buildingsStorage();

        uint256 bonusSum = 0;
        uint8 tierSum = 0;

        for (uint256 i = 0; i < specimenKeys.length; i++) {
            SpecimenAttachedCard storage card = bs.specimenCards[specimenKeys[i]];
            if (card.tokenId != 0) {
                bonusSum += card.computedBonusBps;
                tierSum += card.tierBonus;
            }
        }

        // Cap bonuses
        if (bonusSum > bs.cardConfig.maxBonusCapBps) {
            bonusSum = bs.cardConfig.maxBonusCapBps;
        }
        if (tierSum > 5) {
            tierSum = 5; // Max tier bonus
        }

        return (uint16(bonusSum), tierSum);
    }

    /**
     * @notice Get total bonus from all venture-compatible cards for a user
     * @param user User address
     * @return totalSuccessBoostBps Total success rate boost
     * @return totalRewardBoostBps Total reward multiplier boost
     */
    function getVentureCardBonuses(
        address user
    ) internal view returns (uint16 totalSuccessBoostBps, uint16 totalRewardBoostBps) {
        BuildingsStorage storage bs = buildingsStorage();

        uint256 successSum = 0;
        uint256 rewardSum = 0;

        // Check all 4 venture types
        for (uint8 i = 0; i < 4; i++) {
            VentureAttachedCard storage card = bs.ventureCards[user][i];
            if (card.tokenId != 0) {
                successSum += card.successBoostBps;
                rewardSum += card.rewardBoostBps;
            }
        }

        // Cap bonuses
        if (successSum > 2500) successSum = 2500; // Max 25% success boost
        if (rewardSum > bs.cardConfig.maxBonusCapBps) {
            rewardSum = bs.cardConfig.maxBonusCapBps;
        }

        return (uint16(successSum), uint16(rewardSum));
    }

    /**
     * @notice Initialize multi-system card defaults
     */
    function initializeMultiSystemCardDefaults() internal {
        BuildingsStorage storage bs = buildingsStorage();

        // Set defaults for multi-system cards
        if (bs.maxCardsPerSpecimen == 0) {
            bs.maxCardsPerSpecimen = 1; // One card per specimen
        }
        if (bs.maxCardsPerVentureSlot == 0) {
            bs.maxCardsPerVentureSlot = 1; // One card per venture slot
        }
    }
}
