// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/**
 * @title LibResourceVentureStorage
 * @notice Dedicated storage library for Resource Venture System (Expeditions)
 * @dev Uses Diamond storage pattern with unique position - safe for proxy upgrades
 *      Ventures are risk/reward expeditions where users stake resources
 * @author rutilicus.eth (ArchXS)
 */
library LibResourceVentureStorage {
    bytes32 constant VENTURE_STORAGE_POSITION = keccak256("henomorphs.resource.venture.storage.v1");

    // ============================================
    // VENTURE TYPES
    // ============================================

    uint8 constant VENTURE_RECON = 0;        // Quick, low risk
    uint8 constant VENTURE_SURVEY = 1;       // Medium duration
    uint8 constant VENTURE_EXCAVATION = 2;   // Long, medium risk
    uint8 constant VENTURE_DEEP_DIVE = 3;    // Very long, high risk
    uint8 constant VENTURE_LEGENDARY = 4;    // Extreme, highest rewards

    uint8 constant MAX_VENTURE_TYPE = 4;

    // ============================================
    // ENUMS
    // ============================================

    enum VenturePhase {
        NotStarted,       // 0: No active venture
        InProgress,       // 1: Venture ongoing
        ReadyToClaim,     // 2: Duration complete, awaiting claim
        Completed,        // 3: Successfully claimed
        Failed,           // 4: Abandoned or failed
        Expired           // 5: Deadline passed without claim
    }

    enum VentureOutcome {
        Pending,          // 0: Not yet determined
        CriticalSuccess,  // 1: Jackpot - 3x rewards
        Success,          // 2: Normal success - stake + bonus
        PartialSuccess,   // 3: Reduced rewards - 50% stake back
        Failure,          // 4: Lost portion of stake
        CriticalFailure   // 5: Lost all stake
    }

    // ============================================
    // STRUCTS
    // ============================================

    /**
     * @notice Venture type configuration
     */
    struct VentureConfig {
        uint256[4] minStake;          // Minimum stake per resource type
        uint256[4] maxStake;          // Maximum stake (0 = no max)
        uint32 duration;              // Duration in seconds
        uint16 successRateBps;        // Base success rate (10000 = 100%)
        uint16 criticalSuccessBps;    // Critical success chance (out of success)
        uint16 criticalFailureBps;    // Critical failure chance (out of failure)
        uint16 rewardMultiplierBps;   // Reward multiplier on success (10000 = 1x)
        uint16 partialReturnBps;      // Return on partial success (5000 = 50%)
        uint16 failureLossBps;        // Loss on failure (3000 = 30% lost)
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
        uint64 seed;                  // Randomness seed (set on start)
        uint16 bonusMultiplierBps;    // Applied bonuses (buildings, etc.)
    }

    /**
     * @notice User venture statistics
     */
    struct UserVentureStats {
        uint32 totalVentures;         // Total ventures started
        uint32 successfulVentures;    // Completed successfully
        uint32 failedVentures;        // Failed ventures
        uint32 currentStreak;         // Consecutive successes
        uint32 bestStreak;            // Best streak ever
        uint256 totalResourcesStaked; // Lifetime staked
        uint256 totalResourcesWon;    // Lifetime won
        uint256 totalResourcesLost;   // Lifetime lost
        uint32 lastVentureTime;       // For cooldown tracking
    }

    /**
     * @notice Global venture configuration
     */
    struct GlobalVentureConfig {
        bool systemEnabled;           // Master switch
        uint8 maxActiveVentures;      // Max concurrent ventures per user
        uint32 claimWindow;           // Seconds to claim after completion
        uint16 streakBonusBps;        // Bonus per streak level (max 10)
        uint16 colonyBonusBps;        // Bonus if colony has Laboratory
        address utilityToken;         // YLW address
        address beneficiary;          // Where failed stakes go (treasury)
        // Fee configuration (v2)
        uint16 entryFeeBps;           // Entry fee in basis points (e.g., 100 = 1%)
        uint16 claimFeeBps;           // Claim fee on rewards in basis points
        bool burnOnCollect;           // Whether to burn YLW fees instead of transferring
    }

    // ============================================
    // STORAGE STRUCT
    // ============================================

    struct VentureStorage {
        // Configuration
        GlobalVentureConfig config;

        // Venture type configurations
        mapping(uint8 => VentureConfig) ventureConfigs;

        // Active ventures
        // ventureId => Venture
        mapping(bytes32 => Venture) ventures;

        // User's active venture IDs
        // user => ventureIds[]
        mapping(address => bytes32[]) userActiveVentures;

        // User statistics
        mapping(address => UserVentureStats) userStats;

        // Venture counter for unique IDs
        uint256 ventureCounter;

        // Global statistics
        uint256 totalVenturesStarted;
        uint256 totalVenturesCompleted;
        uint256 totalResourcesStaked;
        uint256 totalResourcesDistributed;
        uint256 totalResourcesBurned;

        // Per-type statistics
        mapping(uint8 => uint256) venturesPerType;
        mapping(uint8 => uint256) successesPerType;

        // Version for upgrades
        uint256 storageVersion;
    }

    // ============================================
    // STORAGE ACCESSOR
    // ============================================

    function ventureStorage() internal pure returns (VentureStorage storage vs) {
        bytes32 position = VENTURE_STORAGE_POSITION;
        assembly {
            vs.slot := position
        }
    }

    // ============================================
    // HELPER FUNCTIONS
    // ============================================

    /**
     * @notice Generate unique venture ID
     * @param user User address
     * @param timestamp Start timestamp
     * @return ventureId Unique identifier
     */
    function generateVentureId(address user, uint256 timestamp) internal view returns (bytes32 ventureId) {
        VentureStorage storage vs = ventureStorage();
        return keccak256(abi.encodePacked(user, timestamp, vs.ventureCounter));
    }

    /**
     * @notice Check if user can start a new venture
     * @param user User address
     * @return canStart True if can start
     * @return reason Reason if cannot
     */
    function canUserStartVenture(address user) internal view returns (bool canStart, string memory reason) {
        VentureStorage storage vs = ventureStorage();

        if (!vs.config.systemEnabled) {
            return (false, "Venture system disabled");
        }

        if (vs.userActiveVentures[user].length >= vs.config.maxActiveVentures) {
            return (false, "Max active ventures reached");
        }

        // Check cooldown
        UserVentureStats storage stats = vs.userStats[user];
        if (stats.lastVentureTime > 0) {
            // Find the shortest cooldown among completed ventures
            // For simplicity, use global cooldown check
            // Individual type cooldowns checked in startVenture
        }

        return (true, "");
    }

    /**
     * @notice Calculate outcome based on seed and config
     * @param seed Random seed
     * @param ventureType Type of venture
     * @param bonusMultiplierBps Additional success bonus
     * @return outcome The venture outcome
     */
    function calculateOutcome(
        uint64 seed,
        uint8 ventureType,
        uint16 bonusMultiplierBps
    ) internal view returns (VentureOutcome outcome) {
        VentureStorage storage vs = ventureStorage();
        VentureConfig storage config = vs.ventureConfigs[ventureType];

        // Apply bonus to success rate (capped at 95%)
        uint256 adjustedSuccessRate = uint256(config.successRateBps) + bonusMultiplierBps;
        if (adjustedSuccessRate > 9500) adjustedSuccessRate = 9500;

        // Roll for success/failure (0-9999)
        uint256 roll = uint256(seed) % 10000;

        if (roll < adjustedSuccessRate) {
            // Success path - check for critical success
            uint256 critRoll = uint256(keccak256(abi.encodePacked(seed, "crit"))) % 10000;
            if (critRoll < config.criticalSuccessBps) {
                return VentureOutcome.CriticalSuccess;
            }
            return VentureOutcome.Success;
        } else {
            // Failure path - check severity
            uint256 failRoll = uint256(keccak256(abi.encodePacked(seed, "fail"))) % 10000;

            if (failRoll < config.criticalFailureBps) {
                return VentureOutcome.CriticalFailure;
            } else if (failRoll < 5000) {
                return VentureOutcome.PartialSuccess; // 50% of failures are partial
            }
            return VentureOutcome.Failure;
        }
    }

    /**
     * @notice Calculate rewards based on outcome
     * @param venture The venture instance
     * @return rewards Resources to return to user
     * @return burned Resources burned (sent to treasury)
     */
    function calculateRewards(
        Venture storage venture
    ) internal view returns (uint256[4] memory rewards, uint256[4] memory burned) {
        VentureStorage storage vs = ventureStorage();
        VentureConfig storage config = vs.ventureConfigs[venture.ventureType];

        if (venture.outcome == VentureOutcome.CriticalSuccess) {
            // 3x stake returned
            for (uint8 i = 0; i < 4; i++) {
                rewards[i] = venture.stakedResources[i] * 3;
            }
        } else if (venture.outcome == VentureOutcome.Success) {
            // stake + bonus multiplier
            for (uint8 i = 0; i < 4; i++) {
                rewards[i] = venture.stakedResources[i] +
                    (venture.stakedResources[i] * config.rewardMultiplierBps) / 10000;
            }
        } else if (venture.outcome == VentureOutcome.PartialSuccess) {
            // Partial return
            for (uint8 i = 0; i < 4; i++) {
                rewards[i] = (venture.stakedResources[i] * config.partialReturnBps) / 10000;
                burned[i] = venture.stakedResources[i] - rewards[i];
            }
        } else if (venture.outcome == VentureOutcome.Failure) {
            // Lose portion
            for (uint8 i = 0; i < 4; i++) {
                burned[i] = (venture.stakedResources[i] * config.failureLossBps) / 10000;
                rewards[i] = venture.stakedResources[i] - burned[i];
            }
        } else if (venture.outcome == VentureOutcome.CriticalFailure) {
            // Lose everything
            for (uint8 i = 0; i < 4; i++) {
                burned[i] = venture.stakedResources[i];
                rewards[i] = 0;
            }
        }

        return (rewards, burned);
    }

    /**
     * @notice Get user's active venture count
     * @param user User address
     * @return count Number of active ventures
     */
    function getUserActiveVentureCount(address user) internal view returns (uint256 count) {
        VentureStorage storage vs = ventureStorage();
        return vs.userActiveVentures[user].length;
    }

    /**
     * @notice Remove venture from user's active list
     * @param user User address
     * @param ventureId Venture to remove
     */
    function removeUserActiveVenture(address user, bytes32 ventureId) internal {
        VentureStorage storage vs = ventureStorage();
        bytes32[] storage userVentures = vs.userActiveVentures[user];

        for (uint256 i = 0; i < userVentures.length; i++) {
            if (userVentures[i] == ventureId) {
                // Swap with last and pop
                userVentures[i] = userVentures[userVentures.length - 1];
                userVentures.pop();
                break;
            }
        }
    }

    /**
     * @notice Initialize default venture configurations
     */
    function initializeDefaultConfigs() internal {
        VentureStorage storage vs = ventureStorage();

        if (vs.storageVersion > 0) return; // Already initialized

        // Recon - Quick, low risk (4h, 85% success)
        vs.ventureConfigs[VENTURE_RECON] = VentureConfig({
            minStake: [uint256(100 ether), 50 ether, 25 ether, 10 ether],
            maxStake: [uint256(1000 ether), 500 ether, 250 ether, 100 ether],
            duration: 14400,              // 4 hours
            successRateBps: 8500,         // 85%
            criticalSuccessBps: 500,      // 5% of successes
            criticalFailureBps: 1000,     // 10% of failures
            rewardMultiplierBps: 2000,    // +20% on success
            partialReturnBps: 7000,       // 70% back on partial
            failureLossBps: 1500,         // 15% lost on failure
            cooldownSeconds: 1800,        // 30 min cooldown
            enabled: true
        });

        // Survey - Medium (12h, 70% success)
        vs.ventureConfigs[VENTURE_SURVEY] = VentureConfig({
            minStake: [uint256(300 ether), 150 ether, 75 ether, 30 ether],
            maxStake: [uint256(3000 ether), 1500 ether, 750 ether, 300 ether],
            duration: 43200,              // 12 hours
            successRateBps: 7000,         // 70%
            criticalSuccessBps: 800,      // 8% of successes
            criticalFailureBps: 1500,     // 15% of failures
            rewardMultiplierBps: 5000,    // +50% on success
            partialReturnBps: 5000,       // 50% back on partial
            failureLossBps: 2500,         // 25% lost on failure
            cooldownSeconds: 3600,        // 1 hour cooldown
            enabled: true
        });

        // Excavation - Long (24h, 55% success)
        vs.ventureConfigs[VENTURE_EXCAVATION] = VentureConfig({
            minStake: [uint256(500 ether), 250 ether, 125 ether, 50 ether],
            maxStake: [uint256(5000 ether), 2500 ether, 1250 ether, 500 ether],
            duration: 86400,              // 24 hours
            successRateBps: 5500,         // 55%
            criticalSuccessBps: 1000,     // 10% of successes
            criticalFailureBps: 2000,     // 20% of failures
            rewardMultiplierBps: 10000,   // +100% on success
            partialReturnBps: 4000,       // 40% back on partial
            failureLossBps: 4000,         // 40% lost on failure
            cooldownSeconds: 7200,        // 2 hour cooldown
            enabled: true
        });

        // Deep Dive - Very long (48h, 40% success)
        vs.ventureConfigs[VENTURE_DEEP_DIVE] = VentureConfig({
            minStake: [uint256(1000 ether), 500 ether, 250 ether, 100 ether],
            maxStake: [uint256(10000 ether), 5000 ether, 2500 ether, 1000 ether],
            duration: 172800,             // 48 hours
            successRateBps: 4000,         // 40%
            criticalSuccessBps: 1500,     // 15% of successes
            criticalFailureBps: 2500,     // 25% of failures
            rewardMultiplierBps: 20000,   // +200% on success
            partialReturnBps: 3000,       // 30% back on partial
            failureLossBps: 5000,         // 50% lost on failure
            cooldownSeconds: 14400,       // 4 hour cooldown
            enabled: true
        });

        // Legendary - Extreme (72h, 25% success)
        vs.ventureConfigs[VENTURE_LEGENDARY] = VentureConfig({
            minStake: [uint256(2500 ether), 1250 ether, 625 ether, 250 ether],
            maxStake: [uint256(25000 ether), 12500 ether, 6250 ether, 2500 ether],
            duration: 259200,             // 72 hours
            successRateBps: 2500,         // 25%
            criticalSuccessBps: 2000,     // 20% of successes (jackpot!)
            criticalFailureBps: 3000,     // 30% of failures
            rewardMultiplierBps: 40000,   // +400% on success
            partialReturnBps: 2000,       // 20% back on partial
            failureLossBps: 6000,         // 60% lost on failure
            cooldownSeconds: 28800,       // 8 hour cooldown
            enabled: true
        });

        // Global config
        vs.config.systemEnabled = true;
        vs.config.maxActiveVentures = 3;
        vs.config.claimWindow = 604800;   // 7 days to claim
        vs.config.streakBonusBps = 100;   // +1% per streak (max 10%)
        vs.config.colonyBonusBps = 500;   // +5% with Laboratory

        vs.storageVersion = 1;
    }
}
