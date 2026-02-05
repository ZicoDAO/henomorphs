// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibMeta} from "../../shared/libraries/LibMeta.sol";
import {LibResourceStorage} from "../libraries/LibResourceStorage.sol";
import {LibProgressionStorage} from "../libraries/LibProgressionStorage.sol";
import {LibColonyWarsStorage} from "../libraries/LibColonyWarsStorage.sol";
import {LibBuildingsStorage} from "../libraries/LibBuildingsStorage.sol";
import {LibFeeCollection} from "../../staking/libraries/LibFeeCollection.sol";
import {AccessControlBase} from "../../common/facets/AccessControlBase.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title ResourceVentureFacet
 * @notice Risk/reward expeditions where users stake resources for potential gains
 * @dev Integrates with resource system, buildings, and colonies
 * @author rutilicus.eth (ArchXS)
 */
contract ResourceVentureFacet is AccessControlBase {
    using SafeERC20 for IERC20;
    using LibProgressionStorage for *;

    // ============================================
    // EVENTS
    // ============================================

    event VentureStarted(
        bytes32 indexed ventureId,
        address indexed owner,
        uint8 ventureType,
        uint256[4] stakedResources,
        uint32 endTime
    );

    event VentureClaimed(
        bytes32 indexed ventureId,
        address indexed owner,
        LibProgressionStorage.VentureOutcome outcome,
        uint256[4] rewards,
        uint256[4] burned
    );

    event VentureAbandoned(
        bytes32 indexed ventureId,
        address indexed owner,
        uint256[4] lostResources
    );

    event VentureExpired(
        bytes32 indexed ventureId,
        address indexed owner
    );

    event VentureConfigUpdated(uint8 indexed ventureType);
    event VentureSystemToggled(bool enabled);
    event VentureFeeCollected(address indexed payer, uint256 amount, bool burned, string operation);

    // Card system events
    event VentureCardAttached(
        address indexed user,
        uint8 indexed ventureType,
        uint256 cardTokenId,
        uint16 cardCollectionId,
        uint8 cardTypeId,
        uint16 successBoostBps,
        uint16 rewardBoostBps
    );

    event VentureCardDetached(
        address indexed user,
        uint8 indexed ventureType,
        uint256 cardTokenId
    );

    // ============================================
    // ERRORS
    // ============================================

    error VentureSystemDisabled();
    error InvalidVentureType(uint8 ventureType);
    error VentureTypeDisabled(uint8 ventureType);
    error MaxActiveVenturesReached(uint8 max);
    error InsufficientStake(uint8 resourceType, uint256 required, uint256 provided);
    error StakeExceedsMax(uint8 resourceType, uint256 max, uint256 provided);
    error InsufficientResources(uint8 resourceType, uint256 required, uint256 available);
    error VentureNotFound(bytes32 ventureId);
    error VentureNotReady(bytes32 ventureId, uint32 timeRemaining);
    error VentureAlreadyClaimed(bytes32 ventureId);
    error VentureExpiredError(bytes32 ventureId);
    error NotVentureOwner(bytes32 ventureId);
    error CooldownNotExpired(uint32 remainingSeconds);
    error NoStakeProvided();
    error InsufficientTokenBalance(uint256 required, uint256 available);

    // Card system errors
    error CardSystemDisabled();
    error CardAlreadyAttached(address user, uint8 ventureType);
    error NoCardAttached(address user, uint8 ventureType);
    error CardNotCompatible(uint8 cardTypeId);
    error NotCardOwner(uint256 tokenId);
    error CardInCooldown(uint32 remainingSeconds);
    error CardLocked();
    error InvalidCardCollection(uint16 collectionId);
    error VentureInProgress(address user, uint8 ventureType);

    // ============================================
    // STRUCTS
    // ============================================

    /**
     * @notice Struct to bundle venture reward estimates (avoids stack too deep)
     */
    struct VentureRewardEstimate {
        uint256[4] onSuccess;
        uint256[4] onCriticalSuccess;
        uint256[4] onPartialSuccess;
        uint256[4] onFailure;
    }

    // ============================================
    // MAIN FUNCTIONS
    // ============================================

    /**
     * @notice Start a new resource venture
     * @param ventureType Type of venture (0-4)
     * @param resourceStake Resources to stake [basic, energy, bio, rare]
     */
    function startVenture(
        uint8 ventureType,
        uint256[4] calldata resourceStake
    ) external whenNotPaused nonReentrant returns (bytes32 ventureId) {
        LibProgressionStorage.ProgressionStorage storage ps =
            LibProgressionStorage.progressionStorage();
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();

        address caller = LibMeta.msgSender();

        // Validate system and type
        if (!ps.ventureConfig.systemEnabled) revert VentureSystemDisabled();
        if (ventureType > LibProgressionStorage.MAX_VENTURE_TYPE) {
            revert InvalidVentureType(ventureType);
        }

        LibProgressionStorage.VentureTypeConfig storage config = ps.ventureTypeConfigs[ventureType];
        if (!config.enabled) revert VentureTypeDisabled(ventureType);

        // Check max active ventures
        if (ps.userActiveVentures[caller].length >= ps.ventureConfig.maxActiveVentures) {
            revert MaxActiveVenturesReached(ps.ventureConfig.maxActiveVentures);
        }

        // Check cooldown
        LibProgressionStorage.UserProgressionStats storage stats = ps.userStats[caller];
        if (stats.lastVentureTime > 0) {
            uint32 cooldownEnd = stats.lastVentureTime + config.cooldownSeconds;
            if (block.timestamp < cooldownEnd) {
                revert CooldownNotExpired(cooldownEnd - uint32(block.timestamp));
            }
        }

        // Validate stake amounts
        bool hasStake = false;
        for (uint8 i = 0; i < 4; i++) {
            if (resourceStake[i] > 0) {
                hasStake = true;
                if (resourceStake[i] < config.minStake[i]) {
                    revert InsufficientStake(i, config.minStake[i], resourceStake[i]);
                }
                if (config.maxStake[i] > 0 && resourceStake[i] > config.maxStake[i]) {
                    revert StakeExceedsMax(i, config.maxStake[i], resourceStake[i]);
                }
            }
        }
        if (!hasStake) revert NoStakeProvided();

        // Deduct resources from user
        for (uint8 i = 0; i < 4; i++) {
            if (resourceStake[i] > 0) {
                uint256 available = rs.userResources[caller][i];
                if (available < resourceStake[i]) {
                    revert InsufficientResources(i, resourceStake[i], available);
                }
                rs.userResources[caller][i] -= resourceStake[i];
            }
        }

        // Generate venture ID
        ventureId = LibProgressionStorage.generateVentureId(caller, block.timestamp);
        LibProgressionStorage.Venture storage venture = ps.ventures[ventureId];

        // Setup venture in scoped block to reduce stack
        {
            uint64 seed = uint64(uint256(keccak256(abi.encodePacked(
                block.prevrandao,
                block.timestamp,
                caller,
                ps.ventureCounter
            ))));
            bytes32 colonyId = LibColonyWarsStorage.getUserPrimaryColony(caller);
            uint16 bonusMultiplier = _calculateBonusMultiplier(caller, colonyId, stats);

            venture.owner = caller;
            venture.colonyId = colonyId;
            venture.ventureType = ventureType;
            venture.phase = LibProgressionStorage.VenturePhase.InProgress;
            venture.outcome = LibProgressionStorage.VentureOutcome.Pending;
            venture.stakedResources = resourceStake;
            venture.startTime = uint32(block.timestamp);
            venture.endTime = uint32(block.timestamp) + config.duration;
            venture.claimDeadline = ps.ventureConfig.claimWindow > 0
                ? uint32(block.timestamp) + config.duration + ps.ventureConfig.claimWindow
                : 0;
            venture.seed = seed;
            venture.bonusMultiplierBps = bonusMultiplier;
        }

        // Track
        ps.userActiveVentures[caller].push(ventureId);
        ps.ventureCounter++;
        ps.totalVenturesStarted++;
        ps.venturesPerType[ventureType]++;

        // Update user stats
        stats.totalVentures++;
        stats.lastVentureTime = uint32(block.timestamp);

        // Track total staked and collect entry fee
        {
            uint256 totalStakeValue = 0;
            for (uint8 i = 0; i < 4; i++) {
                stats.totalResourcesStaked += resourceStake[i];
                ps.totalVentureResourcesStaked += resourceStake[i];
                totalStakeValue += resourceStake[i];
            }

            // Collect entry fee (based on stake value)
            if (ps.ventureConfig.entryFeeBps > 0 && ps.tokenConfig.utilityToken != address(0) && totalStakeValue > 0) {
                uint256 entryFee = (totalStakeValue * ps.ventureConfig.entryFeeBps) / 10000;
                if (entryFee > 0) {
                    _collectVentureFee(caller, entryFee, "venture_entry");
                }
            }
        }

        emit VentureStarted(ventureId, caller, ventureType, resourceStake, venture.endTime);

        return ventureId;
    }

    /**
     * @notice Claim rewards from completed venture
     * @param ventureId Venture to claim
     */
    function claimVenture(bytes32 ventureId) external whenNotPaused nonReentrant {
        LibProgressionStorage.ProgressionStorage storage ps =
            LibProgressionStorage.progressionStorage();
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();

        LibProgressionStorage.Venture storage venture = ps.ventures[ventureId];
        address caller = LibMeta.msgSender();

        // Validate
        if (venture.owner == address(0)) revert VentureNotFound(ventureId);
        if (venture.owner != caller) revert NotVentureOwner(ventureId);
        if (venture.phase == LibProgressionStorage.VenturePhase.Completed ||
            venture.phase == LibProgressionStorage.VenturePhase.Failed) {
            revert VentureAlreadyClaimed(ventureId);
        }

        // Check if ready
        if (block.timestamp < venture.endTime) {
            revert VentureNotReady(ventureId, venture.endTime - uint32(block.timestamp));
        }

        // Check expiry
        if (venture.claimDeadline > 0 && block.timestamp > venture.claimDeadline) {
            // Mark as expired
            venture.phase = LibProgressionStorage.VenturePhase.Expired;
            venture.outcome = LibProgressionStorage.VentureOutcome.CriticalFailure;
            LibProgressionStorage.removeUserActiveVenture(caller, ventureId);

            // Burn all staked resources
            for (uint8 i = 0; i < 4; i++) {
                if (venture.stakedResources[i] > 0) {
                    LibResourceStorage.decrementGlobalSupply(i, venture.stakedResources[i]);
                    ps.totalVentureResourcesBurned += venture.stakedResources[i];
                }
            }

            emit VentureExpired(ventureId, caller);
            return;
        }

        // Calculate outcome
        venture.outcome = LibProgressionStorage.calculateVentureOutcome(
            venture.seed,
            venture.ventureType,
            venture.bonusMultiplierBps
        );

        // Calculate rewards and burned amounts
        (uint256[4] memory rewards, uint256[4] memory burned) =
            LibProgressionStorage.calculateVentureRewards(venture);

        // Apply card reward bonus if present
        LibBuildingsStorage.VentureAttachedCard memory card =
            LibBuildingsStorage.getVentureCard(caller, venture.ventureType);
        if (card.tokenId != 0 && card.rewardBoostBps > 0) {
            bool isSuccess = venture.outcome == LibProgressionStorage.VentureOutcome.Success ||
                             venture.outcome == LibProgressionStorage.VentureOutcome.CriticalSuccess ||
                             venture.outcome == LibProgressionStorage.VentureOutcome.PartialSuccess;
            if (isSuccess) {
                for (uint8 i = 0; i < 4; i++) {
                    if (rewards[i] > 0) {
                        uint256 cardBonus = (rewards[i] * card.rewardBoostBps) / 10000;
                        rewards[i] += cardBonus;
                    }
                }
            }
        }

        // Calculate claim fee based on total rewards
        uint256 totalRewardValue = 0;
        for (uint8 i = 0; i < 4; i++) {
            totalRewardValue += rewards[i];
        }

        // Collect claim fee on rewards
        if (ps.ventureConfig.claimFeeBps > 0 && ps.tokenConfig.utilityToken != address(0) && totalRewardValue > 0) {
            uint256 claimFee = (totalRewardValue * ps.ventureConfig.claimFeeBps) / 10000;
            if (claimFee > 0) {
                _collectVentureFee(caller, claimFee, "venture_claim");
            }
        }

        // Distribute rewards
        for (uint8 i = 0; i < 4; i++) {
            if (rewards[i] > 0) {
                // Check supply cap for bonus rewards (original stake doesn't count as new generation)
                uint256 bonusAmount = rewards[i] > venture.stakedResources[i]
                    ? rewards[i] - venture.stakedResources[i]
                    : 0;

                if (bonusAmount > 0) {
                    if (LibResourceStorage.checkSupplyCap(i, bonusAmount)) {
                        LibResourceStorage.incrementGlobalSupply(i, bonusAmount);
                    } else {
                        // Cap exceeded - give back original stake only
                        rewards[i] = venture.stakedResources[i];
                        bonusAmount = 0;
                    }
                }

                rs.userResources[caller][i] += rewards[i];
            }

            if (burned[i] > 0) {
                LibResourceStorage.decrementGlobalSupply(i, burned[i]);
                ps.totalVentureResourcesBurned += burned[i];
            }
        }

        // Update stats
        LibProgressionStorage.UserProgressionStats storage stats = ps.userStats[caller];
        bool isSuccess = venture.outcome == LibProgressionStorage.VentureOutcome.Success ||
                         venture.outcome == LibProgressionStorage.VentureOutcome.CriticalSuccess;

        if (isSuccess) {
            stats.successfulVentures++;
            stats.currentStreak++;
            if (stats.currentStreak > stats.bestStreak) {
                stats.bestStreak = stats.currentStreak;
            }
            ps.ventureSuccessesPerType[venture.ventureType]++;
        } else {
            stats.failedVentures++;
            stats.currentStreak = 0;
        }

        // Track resources
        uint256 totalRewards = 0;
        uint256 totalLost = 0;
        for (uint8 i = 0; i < 4; i++) {
            totalRewards += rewards[i];
            totalLost += burned[i];
        }
        stats.totalResourcesWon += totalRewards;
        stats.totalResourcesLost += totalLost;
        ps.totalVentureResourcesDistributed += totalRewards;

        // Complete venture
        venture.phase = LibProgressionStorage.VenturePhase.Completed;
        ps.totalVenturesCompleted++;
        LibProgressionStorage.removeUserActiveVenture(caller, ventureId);

        emit VentureClaimed(ventureId, caller, venture.outcome, rewards, burned);
    }

    /**
     * @notice Abandon an active venture (lose portion of stake)
     * @param ventureId Venture to abandon
     */
    function abandonVenture(bytes32 ventureId) external whenNotPaused nonReentrant {
        LibProgressionStorage.ProgressionStorage storage ps =
            LibProgressionStorage.progressionStorage();

        LibProgressionStorage.Venture storage venture = ps.ventures[ventureId];
        address caller = LibMeta.msgSender();

        // Validate
        if (venture.owner == address(0)) revert VentureNotFound(ventureId);
        if (venture.owner != caller) revert NotVentureOwner(ventureId);
        if (venture.phase != LibProgressionStorage.VenturePhase.InProgress) {
            revert VentureAlreadyClaimed(ventureId);
        }

        // Calculate how much time has passed (more time = less loss)
        uint32 elapsed = uint32(block.timestamp) - venture.startTime;
        uint32 duration = venture.endTime - venture.startTime;
        uint256 progressBps = (uint256(elapsed) * 10000) / duration;

        // Return portion based on progress (max 50% return even at 100% progress)
        uint256[4] memory returned;
        uint256[4] memory lost;

        for (uint8 i = 0; i < 4; i++) {
            if (venture.stakedResources[i] > 0) {
                // Return up to 50% based on progress
                uint256 returnBps = (progressBps * 5000) / 10000;
                returned[i] = (venture.stakedResources[i] * returnBps) / 10000;
                lost[i] = venture.stakedResources[i] - returned[i];

                // Return to user
                LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
                rs.userResources[caller][i] += returned[i];

                // Burn lost portion
                LibResourceStorage.decrementGlobalSupply(i, lost[i]);
                ps.totalVentureResourcesBurned += lost[i];
            }
        }

        // Update stats
        LibProgressionStorage.UserProgressionStats storage stats = ps.userStats[caller];
        stats.failedVentures++;
        stats.currentStreak = 0;

        uint256 totalLost = 0;
        for (uint8 i = 0; i < 4; i++) {
            totalLost += lost[i];
        }
        stats.totalResourcesLost += totalLost;

        // Complete
        venture.phase = LibProgressionStorage.VenturePhase.Failed;
        venture.outcome = LibProgressionStorage.VentureOutcome.Failure;
        LibProgressionStorage.removeUserActiveVenture(caller, ventureId);

        emit VentureAbandoned(ventureId, caller, lost);
    }

    // ============================================
    // INTERNAL FUNCTIONS
    // ============================================

    /**
     * @notice Collect venture fee using LibFeeCollection
     * @param payer Address paying the fee
     * @param amount Amount to collect
     * @param operation Operation name for tracking
     */
    function _collectVentureFee(address payer, uint256 amount, string memory operation) internal {
        if (amount == 0) return;

        LibProgressionStorage.ProgressionStorage storage ps =
            LibProgressionStorage.progressionStorage();

        IERC20 token = IERC20(ps.tokenConfig.utilityToken);

        uint256 balance = token.balanceOf(payer);
        if (balance < amount) {
            revert InsufficientTokenBalance(amount, balance);
        }

        if (ps.tokenConfig.burnOnCollect) {
            LibFeeCollection.collectAndBurnFee(token, payer, ps.tokenConfig.beneficiary, amount, operation);
        } else {
            LibFeeCollection.collectFee(token, payer, ps.tokenConfig.beneficiary, amount, operation);
        }

        emit VentureFeeCollected(payer, amount, ps.tokenConfig.burnOnCollect, operation);
    }

    function _calculateBonusMultiplier(
        address user,
        bytes32 colonyId,
        LibProgressionStorage.UserProgressionStats storage stats
    ) internal view returns (uint16 bonus) {
        LibProgressionStorage.ProgressionStorage storage ps =
            LibProgressionStorage.progressionStorage();

        // Streak bonus (capped at 10)
        uint32 streak = stats.currentStreak > 10 ? 10 : stats.currentStreak;
        bonus = uint16(streak * ps.ventureConfig.streakBonusBps);

        // Colony Laboratory bonus
        if (colonyId != bytes32(0)) {
            LibBuildingsStorage.ColonyBuildingEffects memory effects =
                LibBuildingsStorage.getColonyBuildingEffects(colonyId);

            if (effects.techLevelBonus > 0) {
                bonus += ps.ventureConfig.colonyBonusBps;
            }
        }

        // Add venture card success boost
        (uint16 cardSuccessBoost, ) = LibBuildingsStorage.getVentureCardBonuses(user);
        if (cardSuccessBoost > 0) {
            bonus += cardSuccessBoost;
        }

        return bonus;
    }

    // ============================================
    // ADMIN FUNCTIONS
    // ============================================

    /**
     * @notice Initialize venture system
     */
    function initializeVentureSystem() external onlyAuthorized {
        LibProgressionStorage.initializeDefaults();
    }

    /**
     * @notice Enable/disable venture system
     */
    function setVentureSystemEnabled(bool enabled) external onlyAuthorized {
        LibProgressionStorage.ProgressionStorage storage ps =
            LibProgressionStorage.progressionStorage();
        ps.ventureConfig.systemEnabled = enabled;
        emit VentureSystemToggled(enabled);
    }

    /**
     * @notice Update venture type stakes configuration
     */
    function setVentureStakes(
        uint8 ventureType,
        uint256[4] calldata minStake,
        uint256[4] calldata maxStake
    ) external onlyAuthorized {
        require(ventureType <= LibProgressionStorage.MAX_VENTURE_TYPE, "Invalid type");
        LibProgressionStorage.ProgressionStorage storage ps =
            LibProgressionStorage.progressionStorage();
        ps.ventureTypeConfigs[ventureType].minStake = minStake;
        ps.ventureTypeConfigs[ventureType].maxStake = maxStake;
        emit VentureConfigUpdated(ventureType);
    }

    /**
     * @notice Update venture type rates configuration
     */
    function setVentureRates(
        uint8 ventureType,
        uint16 successRateBps,
        uint16 criticalSuccessBps,
        uint16 criticalFailureBps,
        uint16 rewardMultiplierBps,
        uint16 partialReturnBps,
        uint16 failureLossBps
    ) external onlyAuthorized {
        require(ventureType <= LibProgressionStorage.MAX_VENTURE_TYPE, "Invalid type");
        require(successRateBps <= 9500, "Success rate too high");
        LibProgressionStorage.ProgressionStorage storage ps =
            LibProgressionStorage.progressionStorage();
        LibProgressionStorage.VentureTypeConfig storage config = ps.ventureTypeConfigs[ventureType];
        config.successRateBps = successRateBps;
        config.criticalSuccessBps = criticalSuccessBps;
        config.criticalFailureBps = criticalFailureBps;
        config.rewardMultiplierBps = rewardMultiplierBps;
        config.partialReturnBps = partialReturnBps;
        config.failureLossBps = failureLossBps;
        emit VentureConfigUpdated(ventureType);
    }

    /**
     * @notice Update venture type timing configuration
     */
    function setVentureTiming(
        uint8 ventureType,
        uint32 duration,
        uint32 cooldownSeconds,
        bool enabled
    ) external onlyAuthorized {
        require(ventureType <= LibProgressionStorage.MAX_VENTURE_TYPE, "Invalid type");
        LibProgressionStorage.ProgressionStorage storage ps =
            LibProgressionStorage.progressionStorage();
        ps.ventureTypeConfigs[ventureType].duration = duration;
        ps.ventureTypeConfigs[ventureType].cooldownSeconds = cooldownSeconds;
        ps.ventureTypeConfigs[ventureType].enabled = enabled;
        emit VentureConfigUpdated(ventureType);
    }

    /**
     * @notice Set global venture configuration
     */
    function setGlobalVentureConfig(
        uint8 maxActiveVentures,
        uint32 claimWindow,
        uint16 streakBonusBps,
        uint16 colonyBonusBps,
        address utilityToken,
        address beneficiary,
        uint16 entryFeeBps,
        uint16 claimFeeBps,
        bool burnOnCollect
    ) external onlyAuthorized {
        LibProgressionStorage.ProgressionStorage storage ps =
            LibProgressionStorage.progressionStorage();

        ps.ventureConfig.maxActiveVentures = maxActiveVentures;
        ps.ventureConfig.claimWindow = claimWindow;
        ps.ventureConfig.streakBonusBps = streakBonusBps;
        ps.ventureConfig.colonyBonusBps = colonyBonusBps;
        ps.tokenConfig.utilityToken = utilityToken;
        ps.tokenConfig.beneficiary = beneficiary;
        ps.ventureConfig.entryFeeBps = entryFeeBps;
        ps.ventureConfig.claimFeeBps = claimFeeBps;
        ps.tokenConfig.burnOnCollect = burnOnCollect;
    }

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    /**
     * @notice Get venture details
     */
    function getVenture(bytes32 ventureId) external view returns (
        address owner,
        bytes32 colonyId,
        uint8 ventureType,
        LibProgressionStorage.VenturePhase phase,
        LibProgressionStorage.VentureOutcome outcome,
        uint256[4] memory stakedResources,
        uint32 startTime,
        uint32 endTime,
        uint32 claimDeadline,
        uint16 bonusMultiplierBps
    ) {
        LibProgressionStorage.ProgressionStorage storage ps =
            LibProgressionStorage.progressionStorage();
        LibProgressionStorage.Venture storage v = ps.ventures[ventureId];

        return (
            v.owner,
            v.colonyId,
            v.ventureType,
            v.phase,
            v.outcome,
            v.stakedResources,
            v.startTime,
            v.endTime,
            v.claimDeadline,
            v.bonusMultiplierBps
        );
    }

    /**
     * @notice Get user's active ventures
     */
    function getUserActiveVentures(address user) external view returns (bytes32[] memory ventureIds) {
        LibProgressionStorage.ProgressionStorage storage ps =
            LibProgressionStorage.progressionStorage();
        return ps.userActiveVentures[user];
    }

    /**
     * @notice Get user's venture statistics
     */
    function getUserVentureStats(address user) external view returns (
        uint32 totalVentures,
        uint32 successfulVentures,
        uint32 failedVentures,
        uint32 currentStreak,
        uint32 bestStreak,
        uint256 totalResourcesStaked,
        uint256 totalResourcesWon,
        uint256 totalResourcesLost
    ) {
        LibProgressionStorage.ProgressionStorage storage ps =
            LibProgressionStorage.progressionStorage();
        LibProgressionStorage.UserProgressionStats storage stats = ps.userStats[user];

        return (
            stats.totalVentures,
            stats.successfulVentures,
            stats.failedVentures,
            stats.currentStreak,
            stats.bestStreak,
            stats.totalResourcesStaked,
            stats.totalResourcesWon,
            stats.totalResourcesLost
        );
    }

    /**
     * @notice Get venture type configuration
     */
    function getVentureConfig(uint8 ventureType) external view returns (
        uint256[4] memory minStake,
        uint256[4] memory maxStake,
        uint32 duration,
        uint16 successRateBps,
        uint16 rewardMultiplierBps,
        uint32 cooldownSeconds,
        bool enabled
    ) {
        LibProgressionStorage.ProgressionStorage storage ps =
            LibProgressionStorage.progressionStorage();
        LibProgressionStorage.VentureTypeConfig storage config = ps.ventureTypeConfigs[ventureType];

        return (
            config.minStake,
            config.maxStake,
            config.duration,
            config.successRateBps,
            config.rewardMultiplierBps,
            config.cooldownSeconds,
            config.enabled
        );
    }

    /**
     * @notice Estimate potential rewards for a venture
     */
    function estimateVentureRewards(
        uint8 ventureType,
        uint256[4] calldata stake
    ) external view returns (VentureRewardEstimate memory estimate) {
        LibProgressionStorage.ProgressionStorage storage ps =
            LibProgressionStorage.progressionStorage();
        LibProgressionStorage.VentureTypeConfig storage config = ps.ventureTypeConfigs[ventureType];

        uint16 critMultiplier = ps.ventureConfig.criticalSuccessMultiplier > 0
            ? ps.ventureConfig.criticalSuccessMultiplier
            : 3;

        for (uint8 i = 0; i < 4; i++) {
            // Critical Success: use configurable multiplier
            estimate.onCriticalSuccess[i] = stake[i] * critMultiplier;

            // Success: stake + bonus
            estimate.onSuccess[i] = stake[i] + (stake[i] * config.rewardMultiplierBps) / 10000;

            // Partial Success
            estimate.onPartialSuccess[i] = (stake[i] * config.partialReturnBps) / 10000;

            // Failure
            uint256 loss = (stake[i] * config.failureLossBps) / 10000;
            estimate.onFailure[i] = stake[i] - loss;
        }

        return estimate;
    }

    /**
     * @notice Check time remaining on venture
     */
    function getVentureTimeRemaining(bytes32 ventureId) external view returns (
        bool isReady,
        uint32 timeRemaining,
        uint32 claimDeadlineRemaining
    ) {
        LibProgressionStorage.ProgressionStorage storage ps =
            LibProgressionStorage.progressionStorage();
        LibProgressionStorage.Venture storage venture = ps.ventures[ventureId];

        isReady = block.timestamp >= venture.endTime;
        timeRemaining = block.timestamp >= venture.endTime
            ? 0
            : venture.endTime - uint32(block.timestamp);

        if (venture.claimDeadline > 0 && block.timestamp < venture.claimDeadline) {
            claimDeadlineRemaining = venture.claimDeadline - uint32(block.timestamp);
        }

        return (isReady, timeRemaining, claimDeadlineRemaining);
    }

    /**
     * @notice Get global venture statistics
     */
    function getVentureGlobalStats() external view returns (
        uint256 totalStarted,
        uint256 totalCompleted,
        uint256 totalResourcesStaked,
        uint256 totalResourcesDistributed,
        uint256 totalResourcesBurned,
        bool systemEnabled
    ) {
        LibProgressionStorage.ProgressionStorage storage ps =
            LibProgressionStorage.progressionStorage();

        return (
            ps.totalVenturesStarted,
            ps.totalVenturesCompleted,
            ps.totalVentureResourcesStaked,
            ps.totalVentureResourcesDistributed,
            ps.totalVentureResourcesBurned,
            ps.ventureConfig.systemEnabled
        );
    }

    /**
     * @notice Check if user can start a specific venture type
     */
    function canStartVenture(
        address user,
        uint8 ventureType
    ) external view returns (bool canStart, string memory reason) {
        LibProgressionStorage.ProgressionStorage storage ps =
            LibProgressionStorage.progressionStorage();

        if (!ps.ventureConfig.systemEnabled) {
            return (false, "Venture system disabled");
        }

        if (ventureType > LibProgressionStorage.MAX_VENTURE_TYPE) {
            return (false, "Invalid venture type");
        }

        if (!ps.ventureTypeConfigs[ventureType].enabled) {
            return (false, "Venture type disabled");
        }

        if (ps.userActiveVentures[user].length >= ps.ventureConfig.maxActiveVentures) {
            return (false, "Max active ventures reached");
        }

        LibProgressionStorage.UserProgressionStats storage stats = ps.userStats[user];
        if (stats.lastVentureTime > 0) {
            uint32 cooldownEnd = stats.lastVentureTime + ps.ventureTypeConfigs[ventureType].cooldownSeconds;
            if (block.timestamp < cooldownEnd) {
                return (false, "Cooldown not expired");
            }
        }

        return (true, "");
    }

    // ============================================
    // CARD SYSTEM FUNCTIONS
    // ============================================

    /**
     * @notice Attach a venture card to a venture slot
     * @param ventureType Venture type (0-3)
     * @param cardTokenId Card NFT token ID
     * @param cardCollectionId Card collection ID (registered in BuildingsStorage)
     * @param cardTypeId Card type ID (must be Venture or Universal compatible)
     * @param rarity Card rarity level
     */
    function attachVentureCard(
        uint8 ventureType,
        uint256 cardTokenId,
        uint16 cardCollectionId,
        uint8 cardTypeId,
        LibBuildingsStorage.CardRarity rarity
    ) external whenNotPaused nonReentrant {
        LibBuildingsStorage.BuildingsStorage storage bs = LibBuildingsStorage.buildingsStorage();
        address caller = LibMeta.msgSender();

        // Check card system enabled
        if (!bs.cardConfig.systemEnabled) {
            revert CardSystemDisabled();
        }

        // Validate venture type
        if (ventureType > LibProgressionStorage.MAX_VENTURE_TYPE) {
            revert InvalidVentureType(ventureType);
        }

        // Verify caller owns the card
        LibBuildingsStorage.CardCollection storage cardColl = bs.cardCollections[cardCollectionId];
        if (!cardColl.enabled) {
            revert InvalidCardCollection(cardCollectionId);
        }

        IERC721 cardContract = IERC721(cardColl.contractAddress);
        if (cardContract.ownerOf(cardTokenId) != caller) {
            revert NotCardOwner(cardTokenId);
        }

        // Check card is compatible with Venture system
        if (!LibBuildingsStorage.isCardSystemCompatible(cardTypeId, LibBuildingsStorage.CardCompatibleSystem.Venture)) {
            revert CardNotCompatible(cardTypeId);
        }

        // Check no card already attached
        if (LibBuildingsStorage.hasVentureCard(caller, ventureType)) {
            revert CardAlreadyAttached(caller, ventureType);
        }

        // Check attach cooldown
        (bool canAttach, uint32 cooldownRemaining) = LibBuildingsStorage.canUserAttachCard(caller);
        if (!canAttach) {
            revert CardInCooldown(cooldownRemaining);
        }

        // Attach card
        LibBuildingsStorage.attachVentureCard(
            caller,
            ventureType,
            cardTokenId,
            cardCollectionId,
            cardTypeId,
            rarity
        );

        // Get computed bonuses for event
        LibBuildingsStorage.VentureAttachedCard memory attachedCard =
            LibBuildingsStorage.getVentureCard(caller, ventureType);

        emit VentureCardAttached(
            caller,
            ventureType,
            cardTokenId,
            cardCollectionId,
            cardTypeId,
            attachedCard.successBoostBps,
            attachedCard.rewardBoostBps
        );
    }

    /**
     * @notice Detach a venture card from a venture slot
     * @param ventureType Venture type (0-3)
     */
    function detachVentureCard(uint8 ventureType) external whenNotPaused nonReentrant {
        address caller = LibMeta.msgSender();

        // Validate venture type
        if (ventureType > LibProgressionStorage.MAX_VENTURE_TYPE) {
            revert InvalidVentureType(ventureType);
        }

        // Check card exists
        if (!LibBuildingsStorage.hasVentureCard(caller, ventureType)) {
            revert NoCardAttached(caller, ventureType);
        }

        LibBuildingsStorage.VentureAttachedCard memory card =
            LibBuildingsStorage.getVentureCard(caller, ventureType);

        // Check not locked (e.g., during active venture)
        if (card.locked) {
            revert CardLocked();
        }

        // Check detach cooldown
        if (block.timestamp < card.cooldownUntil) {
            revert CardInCooldown(card.cooldownUntil - uint32(block.timestamp));
        }

        // Detach card
        LibBuildingsStorage.detachVentureCard(caller, ventureType);

        emit VentureCardDetached(caller, ventureType, card.tokenId);
    }

    /**
     * @notice Get venture card attached to a slot
     * @param user User address
     * @param ventureType Venture type
     * @return cardTokenId Card NFT token ID (0 if none)
     * @return cardCollectionId Card collection ID
     * @return cardTypeId Card type ID
     * @return rarity Card rarity
     * @return successBoostBps Success rate boost
     * @return rewardBoostBps Reward multiplier boost
     * @return cooldownUntil Cooldown timestamp
     * @return locked Whether card is locked
     */
    function getVentureCard(
        address user,
        uint8 ventureType
    ) external view returns (
        uint256 cardTokenId,
        uint16 cardCollectionId,
        uint8 cardTypeId,
        LibBuildingsStorage.CardRarity rarity,
        uint16 successBoostBps,
        uint16 rewardBoostBps,
        uint32 cooldownUntil,
        bool locked
    ) {
        LibBuildingsStorage.VentureAttachedCard memory card =
            LibBuildingsStorage.getVentureCard(user, ventureType);

        return (
            card.tokenId,
            card.collectionId,
            card.cardTypeId,
            card.rarity,
            card.successBoostBps,
            card.rewardBoostBps,
            card.cooldownUntil,
            card.locked
        );
    }

    /**
     * @notice Check if user has venture card attached
     * @param user User address
     * @param ventureType Venture type
     * @return hasCard True if card attached
     */
    function userHasVentureCard(address user, uint8 ventureType) external view returns (bool hasCard) {
        return LibBuildingsStorage.hasVentureCard(user, ventureType);
    }

    /**
     * @notice Get all venture card bonuses for a user
     * @param user User address
     * @return totalSuccessBoostBps Total success rate boost
     * @return totalRewardBoostBps Total reward multiplier boost
     */
    function getUserVentureCardBonuses(address user) external view returns (
        uint16 totalSuccessBoostBps,
        uint16 totalRewardBoostBps
    ) {
        return LibBuildingsStorage.getVentureCardBonuses(user);
    }

    /**
     * @notice Estimate venture rewards with card bonuses applied
     * @param user User address
     * @param ventureType Venture type
     * @param stake Resources to stake
     * @return estimate Struct containing reward estimates for each outcome
     * @return cardBonusApplied Whether card bonus was applied
     */
    function estimateVentureRewardsWithCard(
        address user,
        uint8 ventureType,
        uint256[4] calldata stake
    ) external view returns (
        VentureRewardEstimate memory estimate,
        bool cardBonusApplied
    ) {
        LibProgressionStorage.ProgressionStorage storage ps =
            LibProgressionStorage.progressionStorage();
        LibProgressionStorage.VentureTypeConfig storage config = ps.ventureTypeConfigs[ventureType];

        // Check for card bonus
        LibBuildingsStorage.VentureAttachedCard memory card =
            LibBuildingsStorage.getVentureCard(user, ventureType);

        uint16 rewardBoostBps = card.tokenId != 0 ? card.rewardBoostBps : 0;
        cardBonusApplied = rewardBoostBps > 0;

        uint16 critMultiplier = ps.ventureConfig.criticalSuccessMultiplier > 0
            ? ps.ventureConfig.criticalSuccessMultiplier
            : 3;

        for (uint8 i = 0; i < 4; i++) {
            // Critical Success: use configurable multiplier + card bonus
            estimate.onCriticalSuccess[i] = stake[i] * critMultiplier;
            if (rewardBoostBps > 0) {
                estimate.onCriticalSuccess[i] += (estimate.onCriticalSuccess[i] * rewardBoostBps) / 10000;
            }

            // Success: stake + bonus + card bonus
            estimate.onSuccess[i] = stake[i] + (stake[i] * config.rewardMultiplierBps) / 10000;
            if (rewardBoostBps > 0) {
                estimate.onSuccess[i] += (estimate.onSuccess[i] * rewardBoostBps) / 10000;
            }

            // Partial Success
            estimate.onPartialSuccess[i] = (stake[i] * config.partialReturnBps) / 10000;

            // Failure
            uint256 loss = (stake[i] * config.failureLossBps) / 10000;
            estimate.onFailure[i] = stake[i] - loss;
        }

        return (estimate, cardBonusApplied);
    }
}
