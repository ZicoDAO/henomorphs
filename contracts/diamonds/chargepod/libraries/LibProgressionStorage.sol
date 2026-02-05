// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/**
 * @title LibProgressionStorage
 * @notice Consolidated storage library for Progression Systems (Evolution + Ventures)
 * @dev Combines specimen evolution and resource venture systems into unified storage
 *      Uses Diamond storage pattern with unique position - safe for proxy upgrades
 *      Replaces: LibSpecimenEvolutionStorage + LibResourceVentureStorage
 * @author rutilicus.eth (ArchXS)
 */
library LibProgressionStorage {
    bytes32 constant PROGRESSION_STORAGE_POSITION = keccak256("henomorphs.progression.storage.v1");

    // ============================================
    // CONSTANTS
    // ============================================

    // Evolution levels
    uint8 constant MAX_EVOLUTION_LEVEL = 5;

    // Venture types
    uint8 constant VENTURE_RECON = 0;        // Quick, low risk
    uint8 constant VENTURE_SURVEY = 1;       // Medium duration
    uint8 constant VENTURE_EXCAVATION = 2;   // Long, medium risk
    uint8 constant VENTURE_DEEP_DIVE = 3;    // Very long, high risk
    uint8 constant VENTURE_LEGENDARY = 4;    // Extreme, highest rewards
    uint8 constant MAX_VENTURE_TYPE = 4;

    // ============================================
    // SHARED ENUMS
    // ============================================

    /**
     * @notice Venture phase enum
     */
    enum VenturePhase {
        NotStarted,       // 0: No active venture
        InProgress,       // 1: Venture ongoing
        ReadyToClaim,     // 2: Duration complete, awaiting claim
        Completed,        // 3: Successfully claimed
        Failed,           // 4: Abandoned or failed
        Expired           // 5: Deadline passed without claim
    }

    /**
     * @notice Venture outcome enum
     */
    enum VentureOutcome {
        Pending,          // 0: Not yet determined
        CriticalSuccess,  // 1: Jackpot - 3x rewards
        Success,          // 2: Normal success - stake + bonus
        PartialSuccess,   // 3: Reduced rewards - 50% stake back
        Failure,          // 4: Lost portion of stake
        CriticalFailure   // 5: Lost all stake
    }

    // ============================================
    // SHARED CONFIGURATION
    // ============================================

    /**
     * @notice Unified token and fee configuration (shared by evolution & ventures)
     */
    struct TokenConfig {
        address utilityToken;         // YLW address
        address governanceToken;      // ZICO address
        address beneficiary;          // Where fees/tokens go
        bool useGovernanceToken;      // True = ZICO for premium operations
        bool burnOnCollect;           // Whether to burn YLW (deflationary)
    }

    // ============================================
    // EVOLUTION SYSTEM STRUCTS
    // ============================================

    /**
     * @notice Resource costs and rewards for evolution tier
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
     * @notice Evolution state for a specific specimen (token)
     */
    struct SpecimenEvolution {
        uint8 currentLevel;           // Current evolution level (0 = base, 5 = max)
        uint32 lastEvolutionTime;     // Timestamp of last evolution
        uint16 totalStatBoost;        // Cumulative stat boost from evolutions
        uint16 totalProductionBoost;  // Cumulative production boost
        bool locked;                  // Locked (e.g., during special events)
    }

    /**
     * @notice Evolution system configuration
     */
    struct EvolutionSystemConfig {
        bool systemEnabled;           // Master switch for evolution
        uint8 maxLevel;               // Maximum evolution level (default: 5)
        uint16 failureRefundBps;      // Refund on failure in bps (0 = no failure possible)
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
    // VENTURE SYSTEM STRUCTS
    // ============================================

    /**
     * @notice Venture type configuration
     */
    struct VentureTypeConfig {
        uint256[4] minStake;          // Minimum stake per resource type
        uint256[4] maxStake;          // Maximum stake (0 = no max)
        uint32 duration;              // Duration in seconds
        uint16 successRateBps;        // Base success rate (10000 = 100%)
        uint16 criticalSuccessBps;    // Critical success chance
        uint16 criticalFailureBps;    // Critical failure chance
        uint16 rewardMultiplierBps;   // Reward multiplier on success
        uint16 partialReturnBps;      // Return on partial success
        uint16 failureLossBps;        // Loss on failure
        uint32 cooldownSeconds;       // Cooldown between ventures
        bool enabled;                 // Whether this type is available
    }

    /**
     * @notice Active venture instance
     */
    struct Venture {
        address owner;                // Who started the venture
        bytes32 colonyId;             // Colony association (for bonuses)
        uint8 ventureType;            // Type of venture (0-4)
        VenturePhase phase;           // Current phase
        VentureOutcome outcome;       // Final outcome (set on claim)
        uint256[4] stakedResources;   // Resources at risk
        uint256 stakedTokens;         // YLW at risk (optional)
        uint32 startTime;             // When venture started
        uint32 endTime;               // When venture completes
        uint32 claimDeadline;         // Must claim before this (0 = no deadline)
        uint64 seed;                  // Randomness seed
        uint16 bonusMultiplierBps;    // Applied bonuses
    }

    /**
     * @notice Venture system configuration
     */
    struct VentureSystemConfig {
        bool systemEnabled;           // Master switch for ventures
        uint8 maxActiveVentures;      // Max concurrent ventures per user
        uint32 claimWindow;           // Seconds to claim after completion
        uint16 streakBonusBps;        // Bonus per streak level (max 10)
        uint16 colonyBonusBps;        // Bonus if colony has Laboratory
        uint16 entryFeeBps;           // Entry fee in basis points
        uint16 claimFeeBps;           // Claim fee on rewards
        // Configurable outcome parameters (not hardcoded)
        uint16 maxSuccessRateBps;     // Cap for success rate (default: 9500 = 95%)
        uint16 partialSuccessThresholdBps; // Threshold for partial success (default: 5000 = 50%)
        uint16 criticalSuccessMultiplier;  // Multiplier for critical success rewards (default: 3 = 3x)
    }

    // ============================================
    // UNIFIED USER STATS
    // ============================================

    /**
     * @notice Combined user progression statistics
     */
    struct UserProgressionStats {
        // Evolution stats
        uint32 totalEvolutions;       // Total evolutions performed
        uint32 lastEvolutionTime;     // Last evolution timestamp

        // Venture stats
        uint32 totalVentures;         // Total ventures started
        uint32 successfulVentures;    // Completed successfully
        uint32 failedVentures;        // Failed ventures
        uint32 currentStreak;         // Consecutive successes
        uint32 bestStreak;            // Best streak ever
        uint32 lastVentureTime;       // For cooldown tracking

        // Resource tracking
        uint256 totalResourcesStaked; // Lifetime staked in ventures
        uint256 totalResourcesWon;    // Lifetime won from ventures
        uint256 totalResourcesLost;   // Lifetime lost in ventures
        uint256 totalResourcesSpentOnEvolution; // Spent on evolutions
    }

    // ============================================
    // MAIN STORAGE STRUCT
    // ============================================

    struct ProgressionStorage {
        // ========== SHARED CONFIG ==========
        TokenConfig tokenConfig;

        // ========== EVOLUTION SYSTEM ==========
        EvolutionSystemConfig evolutionConfig;

        // Evolution tiers (level => tier data)
        mapping(uint8 => EvolutionTier) evolutionTiers;

        // Token evolution state: keccak256(collectionId, tokenId) => SpecimenEvolution
        mapping(bytes32 => SpecimenEvolution) specimenEvolutions;

        // Per-collection evolution configuration
        mapping(uint256 => CollectionEvolutionConfig) collectionEvolutionConfigs;

        // Evolution history: specimenKey => timestamps
        mapping(bytes32 => uint32[]) evolutionHistory;

        // ========== VENTURE SYSTEM ==========
        VentureSystemConfig ventureConfig;

        // Venture type configurations
        mapping(uint8 => VentureTypeConfig) ventureTypeConfigs;

        // Active ventures: ventureId => Venture
        mapping(bytes32 => Venture) ventures;

        // User's active venture IDs
        mapping(address => bytes32[]) userActiveVentures;

        // Venture counter for unique IDs
        uint256 ventureCounter;

        // ========== UNIFIED USER STATS ==========
        mapping(address => UserProgressionStats) userStats;

        // ========== GLOBAL STATISTICS ==========
        // Evolution stats
        uint256 totalEvolutionsPerformed;
        uint256 totalEvolutionResourcesConsumed;
        uint256 totalEvolutionTokensConsumed;
        mapping(uint8 => uint256) evolutionsPerLevel;

        // Venture stats
        uint256 totalVenturesStarted;
        uint256 totalVenturesCompleted;
        uint256 totalVentureResourcesStaked;
        uint256 totalVentureResourcesDistributed;
        uint256 totalVentureResourcesBurned;
        mapping(uint8 => uint256) venturesPerType;
        mapping(uint8 => uint256) ventureSuccessesPerType;

        // ========== VERSION ==========
        uint256 storageVersion;
    }

    // ============================================
    // STORAGE ACCESSOR
    // ============================================

    function progressionStorage() internal pure returns (ProgressionStorage storage ps) {
        bytes32 position = PROGRESSION_STORAGE_POSITION;
        assembly {
            ps.slot := position
        }
    }

    // ============================================
    // EVOLUTION HELPER FUNCTIONS
    // ============================================

    /**
     * @notice Generate unique key for specimen (token)
     */
    function getSpecimenKey(uint256 collectionId, uint256 tokenId) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(collectionId, tokenId));
    }

    /**
     * @notice Get specimen's current evolution level
     */
    function getSpecimenLevel(uint256 collectionId, uint256 tokenId) internal view returns (uint8) {
        ProgressionStorage storage ps = progressionStorage();
        bytes32 key = getSpecimenKey(collectionId, tokenId);
        return ps.specimenEvolutions[key].currentLevel;
    }

    /**
     * @notice Check if specimen can evolve to next level
     */
    function canSpecimenEvolve(
        uint256 collectionId,
        uint256 tokenId
    ) internal view returns (bool canEvolve, string memory reason) {
        ProgressionStorage storage ps = progressionStorage();

        if (!ps.evolutionConfig.systemEnabled) {
            return (false, "Evolution system disabled");
        }

        CollectionEvolutionConfig storage collConfig = ps.collectionEvolutionConfigs[collectionId];
        if (!collConfig.evolutionEnabled) {
            return (false, "Collection not evolution-enabled");
        }

        bytes32 key = getSpecimenKey(collectionId, tokenId);
        SpecimenEvolution storage evolution = ps.specimenEvolutions[key];

        if (evolution.locked) {
            return (false, "Specimen evolution locked");
        }

        uint8 maxLevel = collConfig.maxLevelOverride > 0
            ? collConfig.maxLevelOverride
            : ps.evolutionConfig.maxLevel;

        if (evolution.currentLevel >= maxLevel) {
            return (false, "Already at max level");
        }

        uint8 nextLevel = evolution.currentLevel + 1;
        EvolutionTier storage tier = ps.evolutionTiers[nextLevel];

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
     */
    function getSpecimenBoosts(
        uint256 collectionId,
        uint256 tokenId
    ) internal view returns (uint16 statBoostBps, uint16 productionBoostBps) {
        ProgressionStorage storage ps = progressionStorage();
        bytes32 key = getSpecimenKey(collectionId, tokenId);
        SpecimenEvolution storage evolution = ps.specimenEvolutions[key];

        CollectionEvolutionConfig storage collConfig = ps.collectionEvolutionConfigs[collectionId];
        uint16 multiplier = collConfig.bonusMultiplierBps > 0
            ? collConfig.bonusMultiplierBps
            : 10000;

        statBoostBps = uint16((uint256(evolution.totalStatBoost) * multiplier) / 10000);
        productionBoostBps = uint16((uint256(evolution.totalProductionBoost) * multiplier) / 10000);
    }

    // ============================================
    // VENTURE HELPER FUNCTIONS
    // ============================================

    /**
     * @notice Generate unique venture ID
     */
    function generateVentureId(address user, uint256 timestamp) internal view returns (bytes32) {
        ProgressionStorage storage ps = progressionStorage();
        return keccak256(abi.encodePacked(user, timestamp, ps.ventureCounter));
    }

    /**
     * @notice Check if user can start a new venture
     */
    function canUserStartVenture(address user) internal view returns (bool canStart, string memory reason) {
        ProgressionStorage storage ps = progressionStorage();

        if (!ps.ventureConfig.systemEnabled) {
            return (false, "Venture system disabled");
        }

        if (ps.userActiveVentures[user].length >= ps.ventureConfig.maxActiveVentures) {
            return (false, "Max active ventures reached");
        }

        return (true, "");
    }

    /**
     * @notice Calculate venture outcome based on seed
     */
    function calculateVentureOutcome(
        uint64 seed,
        uint8 ventureType,
        uint16 bonusMultiplierBps
    ) internal view returns (VentureOutcome) {
        ProgressionStorage storage ps = progressionStorage();
        VentureTypeConfig storage typeConfig = ps.ventureTypeConfigs[ventureType];
        VentureSystemConfig storage sysConfig = ps.ventureConfig;

        uint256 adjustedSuccessRate = uint256(typeConfig.successRateBps) + bonusMultiplierBps;
        uint16 maxRate = sysConfig.maxSuccessRateBps > 0 ? sysConfig.maxSuccessRateBps : 9500;
        if (adjustedSuccessRate > maxRate) adjustedSuccessRate = maxRate;

        uint256 roll = uint256(seed) % 10000;

        if (roll < adjustedSuccessRate) {
            uint256 critRoll = uint256(keccak256(abi.encodePacked(seed, "crit"))) % 10000;
            if (critRoll < typeConfig.criticalSuccessBps) {
                return VentureOutcome.CriticalSuccess;
            }
            return VentureOutcome.Success;
        } else {
            uint256 failRoll = uint256(keccak256(abi.encodePacked(seed, "fail"))) % 10000;

            if (failRoll < typeConfig.criticalFailureBps) {
                return VentureOutcome.CriticalFailure;
            }
            uint16 partialThreshold = sysConfig.partialSuccessThresholdBps > 0
                ? sysConfig.partialSuccessThresholdBps
                : 5000;
            if (failRoll < partialThreshold) {
                return VentureOutcome.PartialSuccess;
            }
            return VentureOutcome.Failure;
        }
    }

    /**
     * @notice Calculate venture rewards based on outcome
     */
    function calculateVentureRewards(
        Venture storage venture
    ) internal view returns (uint256[4] memory rewards, uint256[4] memory burned) {
        ProgressionStorage storage ps = progressionStorage();
        VentureTypeConfig storage typeConfig = ps.ventureTypeConfigs[venture.ventureType];
        VentureSystemConfig storage sysConfig = ps.ventureConfig;

        if (venture.outcome == VentureOutcome.CriticalSuccess) {
            uint16 multiplier = sysConfig.criticalSuccessMultiplier > 0
                ? sysConfig.criticalSuccessMultiplier
                : 3;
            for (uint8 i = 0; i < 4; i++) {
                rewards[i] = venture.stakedResources[i] * multiplier;
            }
        } else if (venture.outcome == VentureOutcome.Success) {
            for (uint8 i = 0; i < 4; i++) {
                rewards[i] = venture.stakedResources[i] +
                    (venture.stakedResources[i] * typeConfig.rewardMultiplierBps) / 10000;
            }
        } else if (venture.outcome == VentureOutcome.PartialSuccess) {
            for (uint8 i = 0; i < 4; i++) {
                rewards[i] = (venture.stakedResources[i] * typeConfig.partialReturnBps) / 10000;
                burned[i] = venture.stakedResources[i] - rewards[i];
            }
        } else if (venture.outcome == VentureOutcome.Failure) {
            for (uint8 i = 0; i < 4; i++) {
                burned[i] = (venture.stakedResources[i] * typeConfig.failureLossBps) / 10000;
                rewards[i] = venture.stakedResources[i] - burned[i];
            }
        } else if (venture.outcome == VentureOutcome.CriticalFailure) {
            for (uint8 i = 0; i < 4; i++) {
                burned[i] = venture.stakedResources[i];
                rewards[i] = 0;
            }
        }
    }

    /**
     * @notice Get user's active venture count
     */
    function getUserActiveVentureCount(address user) internal view returns (uint256) {
        ProgressionStorage storage ps = progressionStorage();
        return ps.userActiveVentures[user].length;
    }

    /**
     * @notice Remove venture from user's active list
     */
    function removeUserActiveVenture(address user, bytes32 ventureId) internal {
        ProgressionStorage storage ps = progressionStorage();
        bytes32[] storage userVentures = ps.userActiveVentures[user];

        for (uint256 i = 0; i < userVentures.length; i++) {
            if (userVentures[i] == ventureId) {
                userVentures[i] = userVentures[userVentures.length - 1];
                userVentures.pop();
                break;
            }
        }
    }

    // ============================================
    // INITIALIZATION
    // ============================================

    /**
     * @notice Initialize default configurations for both systems
     */
    function initializeDefaults() internal {
        ProgressionStorage storage ps = progressionStorage();

        if (ps.storageVersion > 0) return; // Already initialized

        // ===== EVOLUTION DEFAULTS =====
        ps.evolutionConfig.systemEnabled = true;
        ps.evolutionConfig.maxLevel = 5;
        ps.evolutionConfig.failureRefundBps = 0;

        // Tier 1: Level 0 → 1
        ps.evolutionTiers[1] = EvolutionTier({
            resourceCosts: [uint256(500 ether), 100 ether, 0, 0],
            tokenCost: 10 ether,
            statBoostBps: 500,
            productionBoostBps: 300,
            cooldownSeconds: 0,
            requiresPreviousTier: false,
            enabled: true
        });

        // Tier 2-5 (abbreviated - same pattern as original)
        ps.evolutionTiers[2] = EvolutionTier({
            resourceCosts: [uint256(1000 ether), 300 ether, 200 ether, 0],
            tokenCost: 25 ether,
            statBoostBps: 750,
            productionBoostBps: 500,
            cooldownSeconds: 3600,
            requiresPreviousTier: true,
            enabled: true
        });

        ps.evolutionTiers[3] = EvolutionTier({
            resourceCosts: [uint256(2500 ether), 500 ether, 500 ether, 100 ether],
            tokenCost: 50 ether,
            statBoostBps: 1000,
            productionBoostBps: 750,
            cooldownSeconds: 7200,
            requiresPreviousTier: true,
            enabled: true
        });

        ps.evolutionTiers[4] = EvolutionTier({
            resourceCosts: [uint256(5000 ether), 1000 ether, 1000 ether, 500 ether],
            tokenCost: 100 ether,
            statBoostBps: 1500,
            productionBoostBps: 1000,
            cooldownSeconds: 14400,
            requiresPreviousTier: true,
            enabled: true
        });

        ps.evolutionTiers[5] = EvolutionTier({
            resourceCosts: [uint256(10000 ether), 2000 ether, 2000 ether, 1000 ether],
            tokenCost: 200 ether,
            statBoostBps: 2500,
            productionBoostBps: 1500,
            cooldownSeconds: 28800,
            requiresPreviousTier: true,
            enabled: true
        });

        // ===== VENTURE DEFAULTS =====
        ps.ventureConfig.systemEnabled = true;
        ps.ventureConfig.maxActiveVentures = 3;
        ps.ventureConfig.claimWindow = 604800;
        ps.ventureConfig.streakBonusBps = 100;
        ps.ventureConfig.colonyBonusBps = 500;
        // Configurable outcome parameters (can be changed via admin without code deployment)
        ps.ventureConfig.maxSuccessRateBps = 9500;           // 95% max success rate
        ps.ventureConfig.partialSuccessThresholdBps = 5000;  // 50% threshold for partial
        ps.ventureConfig.criticalSuccessMultiplier = 3;      // 3x rewards on critical success

        // Recon - Quick, low risk
        ps.ventureTypeConfigs[VENTURE_RECON] = VentureTypeConfig({
            minStake: [uint256(100 ether), 50 ether, 25 ether, 10 ether],
            maxStake: [uint256(1000 ether), 500 ether, 250 ether, 100 ether],
            duration: 14400,
            successRateBps: 8500,
            criticalSuccessBps: 500,
            criticalFailureBps: 1000,
            rewardMultiplierBps: 2000,
            partialReturnBps: 7000,
            failureLossBps: 1500,
            cooldownSeconds: 1800,
            enabled: true
        });

        // Survey - Medium
        ps.ventureTypeConfigs[VENTURE_SURVEY] = VentureTypeConfig({
            minStake: [uint256(300 ether), 150 ether, 75 ether, 30 ether],
            maxStake: [uint256(3000 ether), 1500 ether, 750 ether, 300 ether],
            duration: 43200,
            successRateBps: 7000,
            criticalSuccessBps: 800,
            criticalFailureBps: 1500,
            rewardMultiplierBps: 5000,
            partialReturnBps: 5000,
            failureLossBps: 2500,
            cooldownSeconds: 3600,
            enabled: true
        });

        // Excavation - Long
        ps.ventureTypeConfigs[VENTURE_EXCAVATION] = VentureTypeConfig({
            minStake: [uint256(500 ether), 250 ether, 125 ether, 50 ether],
            maxStake: [uint256(5000 ether), 2500 ether, 1250 ether, 500 ether],
            duration: 86400,
            successRateBps: 5500,
            criticalSuccessBps: 1000,
            criticalFailureBps: 2000,
            rewardMultiplierBps: 10000,
            partialReturnBps: 4000,
            failureLossBps: 4000,
            cooldownSeconds: 7200,
            enabled: true
        });

        // Deep Dive - Very long
        ps.ventureTypeConfigs[VENTURE_DEEP_DIVE] = VentureTypeConfig({
            minStake: [uint256(1000 ether), 500 ether, 250 ether, 100 ether],
            maxStake: [uint256(10000 ether), 5000 ether, 2500 ether, 1000 ether],
            duration: 172800,
            successRateBps: 4000,
            criticalSuccessBps: 1500,
            criticalFailureBps: 2500,
            rewardMultiplierBps: 20000,
            partialReturnBps: 3000,
            failureLossBps: 5000,
            cooldownSeconds: 14400,
            enabled: true
        });

        // Legendary - Extreme
        ps.ventureTypeConfigs[VENTURE_LEGENDARY] = VentureTypeConfig({
            minStake: [uint256(2500 ether), 1250 ether, 625 ether, 250 ether],
            maxStake: [uint256(25000 ether), 12500 ether, 6250 ether, 2500 ether],
            duration: 259200,
            successRateBps: 2500,
            criticalSuccessBps: 2000,
            criticalFailureBps: 3000,
            rewardMultiplierBps: 40000,
            partialReturnBps: 2000,
            failureLossBps: 6000,
            cooldownSeconds: 28800,
            enabled: true
        });

        ps.storageVersion = 1;
    }
}
