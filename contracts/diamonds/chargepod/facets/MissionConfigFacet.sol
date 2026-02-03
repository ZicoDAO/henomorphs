// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibMissionStorage} from "../libraries/LibMissionStorage.sol";
import {LibHenomorphsStorage} from "../libraries/LibHenomorphsStorage.sol";
import {AccessHelper} from "../../staking/libraries/AccessHelper.sol";
import {ControlFee} from "../../../libraries/HenomorphsModel.sol";
import {AccessControlBase} from "../../common/facets/AccessControlBase.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title MissionConfigFacet
 * @notice Administrative configuration facet for Mission System
 * @dev Handles mission pass registration, variant configuration, and system settings
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 */
contract MissionConfigFacet is AccessControlBase {

    // ============================================================
    // EVENTS
    // ============================================================

    event MissionSystemPaused(bool paused);
    event MissionRewardTokenSet(address indexed token);
    event MissionFeeConfigSet(address indexed recipient, uint16 feeBps);
    event MissionPassCollectionRegistered(
        uint16 indexed collectionId,
        address indexed collectionAddress,
        string name
    );
    event MissionPassCollectionEnabled(uint16 indexed collectionId, bool enabled);
    event MissionPassEligibleCollectionsUpdated(uint16 indexed collectionId, uint16[] eligibleCollections);
    event MissionVariantConfigured(
        uint16 indexed collectionId,
        uint8 indexed variantId,
        string name,
        uint256 baseReward
    );
    event MissionVariantEnabled(uint16 indexed collectionId, uint8 indexed variantId, bool enabled);
    event MissionVariantObjectiveTemplatesSet(uint16 indexed collectionId, uint8 indexed variantId, uint8 templateCount);
    event MissionVariantEventTemplatesSet(uint16 indexed collectionId, uint8 indexed variantId, uint8 templateCount);
    event MissionVariantRestConfigSet(uint16 indexed collectionId, uint8 indexed variantId, uint8 maxUses, uint8 chargeRestore);

    // Recharge events
    event RechargeConfigSet(uint16 indexed collectionId, uint96 pricePerUse, uint16 discountBps);
    event RechargeEnabled(uint16 indexed collectionId, bool enabled);
    event RechargeSystemPaused(bool paused);

    // Lending events
    event LendingConfigSet(address indexed paymentToken, uint16 platformFeeBps);
    event LendingSystemPaused(bool paused);

    // ============================================================
    // ERRORS
    // ============================================================

    error InvalidCollectionAddress();
    error InvalidFeeConfiguration();
    error InvalidVariantConfiguration();
    error CollectionNotRegistered(uint16 collectionId);
    error CollectionAlreadyRegistered(address collection);
    error CollectionIdAlreadyUsed(uint16 collectionId);
    error InvalidRewardAmount();
    error InvalidDuration();
    error InvalidMapSize();
    error TooManyVariants();
    error VariantNotConfigured(uint16 collectionId, uint8 variantId);
    error TooManyTemplates();
    error InvalidTemplateConfig();

    // Recharge errors
    error InvalidRechargeConfig();
    error DiscountTooHigh();

    // Lending errors
    error InvalidLendingConfig();
    error PlatformFeeTooHigh();
    error InvalidDurationRange();
    error RewardShareTooHigh();

    // ============================================================
    // SYSTEM CONFIGURATION
    // ============================================================

    /**
     * @notice Pause or unpause the mission system
     * @param paused New pause state
     */
    function setMissionSystemPaused(bool paused) external onlyAuthorized {
        LibMissionStorage.MissionStorage storage ms = LibMissionStorage.missionStorage();
        ms.systemPaused = paused;
        emit MissionSystemPaused(paused);
    }

    /**
     * @notice Set the reward token for missions (YLW)
     * @param token ERC20 token address for rewards
     */
    function setMissionRewardToken(address token) external onlyAuthorized whenNotPaused {
        if (token == address(0)) {
            revert InvalidCollectionAddress();
        }

        LibMissionStorage.MissionStorage storage ms = LibMissionStorage.missionStorage();
        ms.rewardToken = token;
        emit MissionRewardTokenSet(token);
    }

    /**
     * @notice Configure fee collection for missions
     * @param recipient Address receiving fees
     * @param feeBps Fee in basis points (e.g., 500 = 5%)
     */
    function setMissionFeeConfig(address recipient, uint16 feeBps) external onlyAuthorized whenNotPaused {
        if (recipient == address(0)) {
            revert InvalidFeeConfiguration();
        }
        if (feeBps > 3000) { // Max 30% fee
            revert InvalidFeeConfiguration();
        }

        LibMissionStorage.MissionStorage storage ms = LibMissionStorage.missionStorage();
        ms.feeRecipient = recipient;
        ms.feeBps = feeBps;
        emit MissionFeeConfigSet(recipient, feeBps);
    }

    // ============================================================
    // MISSION PASS COLLECTION MANAGEMENT
    // ============================================================

    /**
     * @notice Register a Mission Pass collection with a specific ID
     * @param collectionId Desired collection ID (must be unique, cannot be 0)
     * @param collectionAddress ERC721/ERC1155 contract address
     * @param name Human readable collection name
     * @param variantCount Number of mission variants available
     * @param maxUsesPerToken Maximum uses per pass token (0 = unlimited)
     * @param globalCooldown Cooldown between missions in seconds
     * @param minHenomorphs Minimum Henomorphs per mission
     * @param maxHenomorphs Maximum Henomorphs per mission
     * @param minChargePercent Minimum charge percentage to participate
     * @param eligibleCollections Array of specimen collection IDs that can participate
     * @param entryFee Fee configuration for starting missions
     */
    function registerMissionPassCollection(
        uint16 collectionId,
        address collectionAddress,
        string calldata name,
        uint8 variantCount,
        uint16 maxUsesPerToken,
        uint32 globalCooldown,
        uint8 minHenomorphs,
        uint8 maxHenomorphs,
        uint8 minChargePercent,
        uint16[] calldata eligibleCollections,
        ControlFee calldata entryFee
    ) external onlyAuthorized whenNotPaused {
        if (collectionId == 0) {
            revert CollectionNotRegistered(collectionId);
        }
        if (collectionAddress == address(0)) {
            revert InvalidCollectionAddress();
        }
        if (variantCount == 0 || variantCount > 10) {
            revert TooManyVariants();
        }
        if (minHenomorphs == 0 || minHenomorphs > maxHenomorphs) {
            revert InvalidVariantConfiguration();
        }
        if (maxHenomorphs > LibMissionStorage.MAX_PARTICIPANTS) {
            revert InvalidVariantConfiguration();
        }
        if (minChargePercent > 100) {
            revert InvalidVariantConfiguration();
        }

        LibMissionStorage.MissionStorage storage ms = LibMissionStorage.missionStorage();

        // Check if address already registered
        if (ms.passCollectionByAddress[collectionAddress] != 0) {
            revert CollectionAlreadyRegistered(collectionAddress);
        }

        // Check if ID already used
        if (ms.passCollections[collectionId].collectionAddress != address(0)) {
            revert CollectionIdAlreadyUsed(collectionId);
        }

        // Update counter if needed to maintain consistency
        if (collectionId > ms.passCollectionCounter) {
            ms.passCollectionCounter = collectionId;
        }

        _registerPassCollection(ms, collectionId, collectionAddress, name, variantCount,
            maxUsesPerToken, globalCooldown, minHenomorphs, maxHenomorphs,
            minChargePercent, eligibleCollections, entryFee);
    }

    /**
     * @dev Internal function to register a pass collection
     */
    function _registerPassCollection(
        LibMissionStorage.MissionStorage storage ms,
        uint16 collectionId,
        address collectionAddress,
        string calldata name,
        uint8 variantCount,
        uint16 maxUsesPerToken,
        uint32 globalCooldown,
        uint8 minHenomorphs,
        uint8 maxHenomorphs,
        uint8 minChargePercent,
        uint16[] calldata eligibleCollections,
        ControlFee calldata entryFee
    ) internal {
        ms.passCollections[collectionId] = LibMissionStorage.MissionPassCollection({
            collectionAddress: collectionAddress,
            name: name,
            variantCount: variantCount,
            maxUsesPerToken: maxUsesPerToken,
            enabled: true,
            globalCooldown: globalCooldown,
            minHenomorphs: minHenomorphs,
            maxHenomorphs: maxHenomorphs,
            minChargePercent: minChargePercent,
            eligibleCollections: eligibleCollections,
            entryFee: entryFee
        });

        // Update reverse mappings
        ms.passCollectionByAddress[collectionAddress] = collectionId;
        for (uint256 i = 0; i < eligibleCollections.length; i++) {
            ms.passesForSpecimen[eligibleCollections[i]].push(collectionId);
        }

        emit MissionPassCollectionRegistered(collectionId, collectionAddress, name);
    }

    /**
     * @notice Enable or disable a Mission Pass collection
     * @param collectionId Collection ID to modify
     * @param enabled New enabled state
     */
    function setMissionPassEnabled(uint16 collectionId, bool enabled) external onlyAuthorized whenNotPaused {
        LibMissionStorage.MissionStorage storage ms = LibMissionStorage.missionStorage();

        if (collectionId == 0 || collectionId > ms.passCollectionCounter) {
            revert CollectionNotRegistered(collectionId);
        }

        ms.passCollections[collectionId].enabled = enabled;
        emit MissionPassCollectionEnabled(collectionId, enabled);
    }

    /**
     * @notice Update Mission Pass collection entry fee
     * @param collectionId Collection ID to modify
     * @param entryFee New fee configuration
     */
    function setMissionPassEntryFee(uint16 collectionId, ControlFee calldata entryFee) external onlyAuthorized whenNotPaused {
        LibMissionStorage.MissionStorage storage ms = LibMissionStorage.missionStorage();

        if (collectionId == 0 || collectionId > ms.passCollectionCounter) {
            revert CollectionNotRegistered(collectionId);
        }

        ms.passCollections[collectionId].entryFee = entryFee;
    }

    /**
     * @notice Update eligible specimen collections for a Mission Pass collection
     * @dev Sets which specimen collections can participate in missions using this pass
     * @param collectionId Mission Pass collection ID to modify
     * @param eligibleCollections Array of specimen collection IDs that can participate
     */
    function setMissionPassEligibleCollections(
        uint16 collectionId,
        uint16[] calldata eligibleCollections
    ) external onlyAuthorized whenNotPaused {
        LibMissionStorage.MissionStorage storage ms = LibMissionStorage.missionStorage();

        if (collectionId == 0 || collectionId > ms.passCollectionCounter) {
            revert CollectionNotRegistered(collectionId);
        }

        // Remove from old reverse mappings
        uint16[] storage oldEligible = ms.passCollections[collectionId].eligibleCollections;
        for (uint256 i = 0; i < oldEligible.length; i++) {
            _removePassFromSpecimen(ms, oldEligible[i], collectionId);
        }

        // Update eligible collections
        ms.passCollections[collectionId].eligibleCollections = eligibleCollections;

        // Add to new reverse mappings
        for (uint256 i = 0; i < eligibleCollections.length; i++) {
            ms.passesForSpecimen[eligibleCollections[i]].push(collectionId);
        }

        emit MissionPassEligibleCollectionsUpdated(collectionId, eligibleCollections);
    }

    /**
     * @dev Remove a pass collection from specimen's reverse mapping (swap and pop)
     */
    function _removePassFromSpecimen(
        LibMissionStorage.MissionStorage storage ms,
        uint16 specimenCollectionId,
        uint16 passCollectionId
    ) internal {
        uint16[] storage passes = ms.passesForSpecimen[specimenCollectionId];
        for (uint256 i = 0; i < passes.length; i++) {
            if (passes[i] == passCollectionId) {
                passes[i] = passes[passes.length - 1];
                passes.pop();
                break;
            }
        }
    }

    /**
     * @notice Update Mission Pass collection parameters
     * @param collectionId Collection ID to modify
     * @param maxUsesPerToken New max uses (0 = unlimited)
     * @param globalCooldown New cooldown in seconds
     * @param minHenomorphs New minimum participants
     * @param maxHenomorphs New maximum participants
     * @param minChargePercent New minimum charge percentage
     */
    function updateMissionPassParams(
        uint16 collectionId,
        uint16 maxUsesPerToken,
        uint32 globalCooldown,
        uint8 minHenomorphs,
        uint8 maxHenomorphs,
        uint8 minChargePercent
    ) external onlyAuthorized whenNotPaused {
        LibMissionStorage.MissionStorage storage ms = LibMissionStorage.missionStorage();

        if (collectionId == 0 || collectionId > ms.passCollectionCounter) {
            revert CollectionNotRegistered(collectionId);
        }
        if (minHenomorphs == 0 || minHenomorphs > maxHenomorphs) {
            revert InvalidVariantConfiguration();
        }
        if (maxHenomorphs > LibMissionStorage.MAX_PARTICIPANTS) {
            revert InvalidVariantConfiguration();
        }

        LibMissionStorage.MissionPassCollection storage collection = ms.passCollections[collectionId];
        collection.maxUsesPerToken = maxUsesPerToken;
        collection.globalCooldown = globalCooldown;
        collection.minHenomorphs = minHenomorphs;
        collection.maxHenomorphs = maxHenomorphs;
        collection.minChargePercent = minChargePercent;
    }

    // ============================================================
    // MISSION VARIANT CONFIGURATION
    // ============================================================

    /**
     * @notice Configure a mission variant for a collection
     * @param collectionId Mission Pass collection ID
     * @param variantId Variant ID (1-based)
     * @param config Full variant configuration
     */
    function configureMissionVariant(
        uint16 collectionId,
        uint8 variantId,
        LibMissionStorage.MissionVariantConfig calldata config
    ) external onlyAuthorized whenNotPaused {
        LibMissionStorage.MissionStorage storage ms = LibMissionStorage.missionStorage();

        if (collectionId == 0 || collectionId > ms.passCollectionCounter) {
            revert CollectionNotRegistered(collectionId);
        }
        if (variantId == 0 || variantId > ms.passCollections[collectionId].variantCount) {
            revert TooManyVariants();
        }

        // Validate configuration
        if (config.maxDurationBlocks <= config.minDurationBlocks) {
            revert InvalidDuration();
        }
        if (config.mapSize == 0 || config.mapSize > LibMissionStorage.MAX_MAP_NODES) {
            revert InvalidMapSize();
        }
        if (config.baseReward == 0) {
            revert InvalidRewardAmount();
        }

        ms.variantConfigs[collectionId][variantId] = config;

        emit MissionVariantConfigured(collectionId, variantId, config.name, config.baseReward);
    }

    /**
     * @notice Enable or disable a mission variant
     * @param collectionId Mission Pass collection ID
     * @param variantId Variant ID
     * @param enabled New enabled state
     */
    function setMissionVariantEnabled(
        uint16 collectionId,
        uint8 variantId,
        bool enabled
    ) external onlyAuthorized whenNotPaused {
        LibMissionStorage.MissionStorage storage ms = LibMissionStorage.missionStorage();

        if (collectionId == 0 || collectionId > ms.passCollectionCounter) {
            revert CollectionNotRegistered(collectionId);
        }
        if (variantId == 0 || variantId > ms.passCollections[collectionId].variantCount) {
            revert VariantNotConfigured(collectionId, variantId);
        }

        ms.variantConfigs[collectionId][variantId].enabled = enabled;
        emit MissionVariantEnabled(collectionId, variantId, enabled);
    }

    /**
     * @notice Update variant reward configuration
     * @param collectionId Mission Pass collection ID
     * @param variantId Variant ID
     * @param baseReward New base reward amount
     * @param difficultyMultiplier New difficulty multiplier (basis points)
     */
    function setMissionVariantRewards(
        uint16 collectionId,
        uint8 variantId,
        uint256 baseReward,
        uint16 difficultyMultiplier
    ) external onlyAuthorized whenNotPaused {
        LibMissionStorage.MissionStorage storage ms = LibMissionStorage.missionStorage();

        if (collectionId == 0 || collectionId > ms.passCollectionCounter) {
            revert CollectionNotRegistered(collectionId);
        }
        if (variantId == 0 || variantId > ms.passCollections[collectionId].variantCount) {
            revert VariantNotConfigured(collectionId, variantId);
        }
        if (baseReward == 0) {
            revert InvalidRewardAmount();
        }

        LibMissionStorage.MissionVariantConfig storage config = ms.variantConfigs[collectionId][variantId];
        config.baseReward = baseReward;
        config.difficultyMultiplier = difficultyMultiplier;
    }

    /**
     * @notice Update variant bonus configuration
     * @param collectionId Mission Pass collection ID
     * @param variantId Variant ID
     * @param multiParticipantBonus Bonus per extra participant (basis points)
     * @param colonyBonus Bonus for same-colony participants (basis points)
     * @param streakBonusPerDay Bonus per streak day (basis points)
     * @param maxStreakBonus Maximum streak bonus cap (basis points)
     * @param weekendBonus Weekend bonus (basis points)
     * @param perfectCompletionBonus Perfect completion bonus (basis points)
     */
    function setMissionVariantBonuses(
        uint16 collectionId,
        uint8 variantId,
        uint16 multiParticipantBonus,
        uint16 colonyBonus,
        uint16 streakBonusPerDay,
        uint16 maxStreakBonus,
        uint16 weekendBonus,
        uint16 perfectCompletionBonus
    ) external onlyAuthorized whenNotPaused {
        LibMissionStorage.MissionStorage storage ms = LibMissionStorage.missionStorage();

        if (collectionId == 0 || collectionId > ms.passCollectionCounter) {
            revert CollectionNotRegistered(collectionId);
        }
        if (variantId == 0 || variantId > ms.passCollections[collectionId].variantCount) {
            revert VariantNotConfigured(collectionId, variantId);
        }

        LibMissionStorage.MissionVariantConfig storage config = ms.variantConfigs[collectionId][variantId];
        config.multiParticipantBonus = multiParticipantBonus;
        config.colonyBonus = colonyBonus;
        config.streakBonusPerDay = streakBonusPerDay;
        config.maxStreakBonus = maxStreakBonus;
        config.weekendBonus = weekendBonus;
        config.perfectCompletionBonus = perfectCompletionBonus;
    }

    /**
     * @notice Configure objective templates for a mission variant
     * @dev Templates define how objectives are generated with randomized targets
     * @param collectionId Mission Pass collection ID
     * @param variantId Variant ID
     * @param templates Array of objective templates (max 8)
     */
    function setMissionVariantObjectiveTemplates(
        uint16 collectionId,
        uint8 variantId,
        LibMissionStorage.ObjectiveTemplate[] calldata templates
    ) external onlyAuthorized whenNotPaused {
        LibMissionStorage.MissionStorage storage ms = LibMissionStorage.missionStorage();

        if (collectionId == 0 || collectionId > ms.passCollectionCounter) {
            revert CollectionNotRegistered(collectionId);
        }
        if (variantId == 0 || variantId > ms.passCollections[collectionId].variantCount) {
            revert VariantNotConfigured(collectionId, variantId);
        }
        if (templates.length > LibMissionStorage.MAX_OBJECTIVES) {
            revert TooManyTemplates();
        }

        LibMissionStorage.MissionVariantConfig storage config = ms.variantConfigs[collectionId][variantId];

        // Validate and copy templates
        for (uint8 i = 0; i < templates.length; i++) {
            LibMissionStorage.ObjectiveTemplate calldata t = templates[i];
            // Validate template
            if (t.minTarget > t.maxTarget) {
                revert InvalidTemplateConfig();
            }
            config.objectiveTemplates[i] = t;
        }

        // Clear remaining slots if new array is shorter
        for (uint8 i = uint8(templates.length); i < LibMissionStorage.MAX_OBJECTIVES; i++) {
            config.objectiveTemplates[i] = LibMissionStorage.ObjectiveTemplate({
                objectiveType: LibMissionStorage.ObjectiveType.Collect,
                minTarget: 0,
                maxTarget: 0,
                isRequired: false,
                bonusRewardBps: 0,
                enabled: false
            });
        }

        config.objectiveTemplateCount = uint8(templates.length);

        emit MissionVariantObjectiveTemplatesSet(collectionId, variantId, uint8(templates.length));
    }

    /**
     * @notice Configure event templates for a mission variant
     * @dev Templates define which events can occur and with what frequency
     * @param collectionId Mission Pass collection ID
     * @param variantId Variant ID
     * @param templates Array of event templates (max 8)
     */
    function setMissionVariantEventTemplates(
        uint16 collectionId,
        uint8 variantId,
        LibMissionStorage.EventTemplate[] calldata templates
    ) external onlyAuthorized whenNotPaused {
        LibMissionStorage.MissionStorage storage ms = LibMissionStorage.missionStorage();

        if (collectionId == 0 || collectionId > ms.passCollectionCounter) {
            revert CollectionNotRegistered(collectionId);
        }
        if (variantId == 0 || variantId > ms.passCollections[collectionId].variantCount) {
            revert VariantNotConfigured(collectionId, variantId);
        }
        if (templates.length > 8) {
            revert TooManyTemplates();
        }

        LibMissionStorage.MissionVariantConfig storage config = ms.variantConfigs[collectionId][variantId];

        // Validate and copy templates
        for (uint8 i = 0; i < templates.length; i++) {
            LibMissionStorage.EventTemplate calldata t = templates[i];
            // Validate template
            if (t.minDifficulty > t.maxDifficulty) {
                revert InvalidTemplateConfig();
            }
            if (t.weight == 0 || t.weight > 100) {
                revert InvalidTemplateConfig();
            }
            config.eventTemplates[i] = t;
        }

        // Clear remaining slots if new array is shorter
        for (uint8 i = uint8(templates.length); i < 8; i++) {
            config.eventTemplates[i] = LibMissionStorage.EventTemplate({
                eventType: LibMissionStorage.EventType.Patrol,
                minDifficulty: 0,
                maxDifficulty: 0,
                weight: 0,
                penaltyBps: 0,
                enabled: false
            });
        }

        config.eventTemplateCount = uint8(templates.length);

        emit MissionVariantEventTemplatesSet(collectionId, variantId, uint8(templates.length));
    }

    /**
     * @notice Configure Rest action parameters for a variant
     * @dev Allows players to recover charge during missions
     * @param collectionId Mission Pass collection ID
     * @param variantId Variant ID
     * @param maxUses Maximum Rest uses per mission (0 = disabled)
     * @param chargeRestore Charge amount restored per Rest action
     */
    function setMissionVariantRestConfig(
        uint16 collectionId,
        uint8 variantId,
        uint8 maxUses,
        uint8 chargeRestore
    ) external onlyAuthorized whenNotPaused {
        LibMissionStorage.MissionStorage storage ms = LibMissionStorage.missionStorage();

        if (collectionId == 0 || collectionId > ms.passCollectionCounter) {
            revert CollectionNotRegistered(collectionId);
        }
        if (variantId == 0 || variantId > ms.passCollections[collectionId].variantCount) {
            revert VariantNotConfigured(collectionId, variantId);
        }

        LibMissionStorage.MissionVariantConfig storage config = ms.variantConfigs[collectionId][variantId];
        config.maxRestUsesPerMission = maxUses;
        config.restChargeRestore = chargeRestore;

        emit MissionVariantRestConfigSet(collectionId, variantId, maxUses, chargeRestore);
    }

    // ============================================================
    // VIEW FUNCTIONS
    // ============================================================

    /**
     * @notice Check if mission system is paused
     * @return paused Current pause state
     */
    function isMissionSystemPaused() external view returns (bool paused) {
        return LibMissionStorage.missionStorage().systemPaused;
    }

    /**
     * @notice Get reward token address
     * @return token Reward token address
     */
    function getMissionRewardToken() external view returns (address token) {
        return LibMissionStorage.missionStorage().rewardToken;
    }

    /**
     * @notice Get fee configuration
     * @return recipient Fee recipient address
     * @return feeBps Fee in basis points
     */
    function getMissionFeeConfig() external view returns (address recipient, uint16 feeBps) {
        LibMissionStorage.MissionStorage storage ms = LibMissionStorage.missionStorage();
        return (ms.feeRecipient, ms.feeBps);
    }

    /**
     * @notice Get Mission Pass collection details by ID
     * @param collectionId Collection ID
     * @return collection Full collection configuration
     */
    function getMissionPassCollection(uint16 collectionId)
        external
        view
        returns (LibMissionStorage.MissionPassCollection memory collection)
    {
        LibMissionStorage.MissionStorage storage ms = LibMissionStorage.missionStorage();
        if (collectionId == 0 || collectionId > ms.passCollectionCounter) {
            revert CollectionNotRegistered(collectionId);
        }
        return ms.passCollections[collectionId];
    }

    /**
     * @notice Get Mission Pass collection ID by contract address
     * @param collectionAddress The NFT contract address
     * @return collectionId Collection ID (0 if not registered)
     */
    function getMissionPassCollectionByAddress(address collectionAddress)
        external
        view
        returns (uint16 collectionId)
    {
        return LibMissionStorage.missionStorage().passCollectionByAddress[collectionAddress];
    }

    /**
     * @notice Get mission variant configuration
     * @param collectionId Collection ID
     * @param variantId Variant ID
     * @return config Full variant configuration
     */
    function getMissionVariantConfig(uint16 collectionId, uint8 variantId)
        external
        view
        returns (LibMissionStorage.MissionVariantConfig memory config)
    {
        LibMissionStorage.MissionStorage storage ms = LibMissionStorage.missionStorage();
        if (collectionId == 0 || collectionId > ms.passCollectionCounter) {
            revert CollectionNotRegistered(collectionId);
        }
        return ms.variantConfigs[collectionId][variantId];
    }

    /**
     * @notice Get total registered Mission Pass collections count
     * @return count Number of registered collections
     */
    function getMissionPassCollectionCount() external view returns (uint16 count) {
        return LibMissionStorage.missionStorage().passCollectionCounter;
    }

    /**
     * @notice Get eligible specimen collections for a Mission Pass collection
     * @param collectionId Mission Pass collection ID
     * @return eligibleCollections Array of specimen collection IDs that can participate
     */
    function getMissionPassEligibleCollections(uint16 collectionId)
        external
        view
        returns (uint16[] memory eligibleCollections)
    {
        LibMissionStorage.MissionStorage storage ms = LibMissionStorage.missionStorage();
        if (collectionId == 0 || collectionId > ms.passCollectionCounter) {
            revert CollectionNotRegistered(collectionId);
        }
        return ms.passCollections[collectionId].eligibleCollections;
    }

    /**
     * @notice Check if a specimen collection can use a specific Mission Pass
     * @param passCollectionId Mission Pass collection ID
     * @param specimenCollectionId Specimen collection ID to check
     * @return canUse True if the specimen collection can do missions with this pass
     */
    function canSpecimenUseMissionPass(uint16 passCollectionId, uint16 specimenCollectionId)
        external
        view
        returns (bool canUse)
    {
        LibMissionStorage.MissionStorage storage ms = LibMissionStorage.missionStorage();
        if (passCollectionId == 0 || passCollectionId > ms.passCollectionCounter) {
            revert CollectionNotRegistered(passCollectionId);
        }

        uint16[] storage eligible = ms.passCollections[passCollectionId].eligibleCollections;
        for (uint256 i = 0; i < eligible.length; i++) {
            if (eligible[i] == specimenCollectionId) {
                return true;
            }
        }
        return false;
    }

    /**
     * @notice Get all Mission Pass collections configured for a specimen collection
     * @param specimenCollectionId Specimen collection ID
     * @return passCollectionIds Array of pass collection IDs that support this specimen
     */
    function getMissionPassesForSpecimen(uint16 specimenCollectionId)
        external
        view
        returns (uint16[] memory passCollectionIds)
    {
        return LibMissionStorage.missionStorage().passesForSpecimen[specimenCollectionId];
    }

    /**
     * @notice Check if any Mission Pass is configured for a specimen collection
     * @param specimenCollectionId Specimen collection ID
     * @return configured True if at least one pass supports this specimen
     */
    function hasMissionPassConfigured(uint16 specimenCollectionId)
        external
        view
        returns (bool configured)
    {
        return LibMissionStorage.missionStorage().passesForSpecimen[specimenCollectionId].length > 0;
    }

    /**
     * @notice Get objective templates for a mission variant
     * @param collectionId Mission Pass collection ID
     * @param variantId Variant ID
     * @return templates Fixed-size array of objective templates
     * @return count Number of active templates
     */
    function getMissionVariantObjectiveTemplates(
        uint16 collectionId,
        uint8 variantId
    ) external view returns (
        LibMissionStorage.ObjectiveTemplate[8] memory templates,
        uint8 count
    ) {
        LibMissionStorage.MissionStorage storage ms = LibMissionStorage.missionStorage();
        if (collectionId == 0 || collectionId > ms.passCollectionCounter) {
            revert CollectionNotRegistered(collectionId);
        }
        if (variantId == 0 || variantId > ms.passCollections[collectionId].variantCount) {
            revert VariantNotConfigured(collectionId, variantId);
        }

        LibMissionStorage.MissionVariantConfig storage config = ms.variantConfigs[collectionId][variantId];
        return (config.objectiveTemplates, config.objectiveTemplateCount);
    }

    /**
     * @notice Get event templates for a mission variant
     * @param collectionId Mission Pass collection ID
     * @param variantId Variant ID
     * @return templates Fixed-size array of event templates
     * @return count Number of active templates
     */
    function getMissionVariantEventTemplates(
        uint16 collectionId,
        uint8 variantId
    ) external view returns (
        LibMissionStorage.EventTemplate[8] memory templates,
        uint8 count
    ) {
        LibMissionStorage.MissionStorage storage ms = LibMissionStorage.missionStorage();
        if (collectionId == 0 || collectionId > ms.passCollectionCounter) {
            revert CollectionNotRegistered(collectionId);
        }
        if (variantId == 0 || variantId > ms.passCollections[collectionId].variantCount) {
            revert VariantNotConfigured(collectionId, variantId);
        }

        LibMissionStorage.MissionVariantConfig storage config = ms.variantConfigs[collectionId][variantId];
        return (config.eventTemplates, config.eventTemplateCount);
    }

    /**
     * @notice Get Rest action configuration for a mission variant
     * @param collectionId Mission Pass collection ID
     * @param variantId Variant ID
     * @return maxUses Maximum Rest uses per mission (0 = disabled)
     * @return chargeRestore Charge amount restored per Rest action
     */
    function getMissionVariantRestConfig(
        uint16 collectionId,
        uint8 variantId
    ) external view returns (uint8 maxUses, uint8 chargeRestore) {
        LibMissionStorage.MissionStorage storage ms = LibMissionStorage.missionStorage();
        if (collectionId == 0 || collectionId > ms.passCollectionCounter) {
            revert CollectionNotRegistered(collectionId);
        }
        if (variantId == 0 || variantId > ms.passCollections[collectionId].variantCount) {
            revert VariantNotConfigured(collectionId, variantId);
        }

        LibMissionStorage.MissionVariantConfig storage config = ms.variantConfigs[collectionId][variantId];
        return (config.maxRestUsesPerMission, config.restChargeRestore);
    }

    /**
     * @notice Get global mission statistics
     * @return totalCreated Total missions created
     * @return totalCompleted Total missions completed
     * @return totalFailed Total missions failed/abandoned
     */
    function getMissionGlobalStats() external view returns (
        uint64 totalCreated,
        uint64 totalCompleted,
        uint64 totalFailed
    ) {
        LibMissionStorage.MissionStorage storage ms = LibMissionStorage.missionStorage();
        return (
            ms.totalSessionsCreated,
            ms.totalSessionsCompleted,
            ms.totalSessionsFailed
        );
    }

    // ============================================================
    // RECHARGE CONFIGURATION
    // ============================================================

    /**
     * @notice Configure recharge settings for a Mission Pass collection
     * @param collectionId Collection ID to configure
     * @param paymentToken ERC20 token for recharge payments
     * @param paymentBeneficiary Address receiving recharge payments
     * @param pricePerUse Price per use in payment token (wei)
     * @param discountBps Discount in basis points (0-10000, e.g., 1000 = 10% off)
     * @param maxRechargePerTx Maximum uses rechargeable per transaction (0 = unlimited)
     * @param cooldownSeconds Cooldown between recharges in seconds
     * @param burnOnCollect Whether to burn tokens instead of transferring
     */
    function setPassRechargeConfig(
        uint16 collectionId,
        address paymentToken,
        address paymentBeneficiary,
        uint96 pricePerUse,
        uint16 discountBps,
        uint16 maxRechargePerTx,
        uint32 cooldownSeconds,
        bool burnOnCollect
    ) external onlyAuthorized whenNotPaused {
        LibMissionStorage.MissionStorage storage ms = LibMissionStorage.missionStorage();

        if (collectionId == 0 || collectionId > ms.passCollectionCounter) {
            revert CollectionNotRegistered(collectionId);
        }
        if (paymentToken == address(0) || paymentBeneficiary == address(0)) {
            revert InvalidRechargeConfig();
        }
        if (pricePerUse == 0) {
            revert InvalidRechargeConfig();
        }
        if (discountBps > 10000) {
            revert DiscountTooHigh();
        }

        ms.passRechargeConfigs[collectionId] = LibMissionStorage.RechargeConfig({
            paymentToken: paymentToken,
            paymentBeneficiary: paymentBeneficiary,
            pricePerUse: pricePerUse,
            discountBps: discountBps,
            maxRechargePerTx: maxRechargePerTx,
            cooldownSeconds: cooldownSeconds,
            enabled: true,
            burnOnCollect: burnOnCollect
        });

        emit RechargeConfigSet(collectionId, pricePerUse, discountBps);
    }

    /**
     * @notice Enable or disable recharge for a collection
     * @param collectionId Collection ID to modify
     * @param enabled New enabled state
     */
    function setPassRechargeEnabled(uint16 collectionId, bool enabled) external onlyAuthorized whenNotPaused {
        LibMissionStorage.MissionStorage storage ms = LibMissionStorage.missionStorage();

        if (collectionId == 0 || collectionId > ms.passCollectionCounter) {
            revert CollectionNotRegistered(collectionId);
        }

        ms.passRechargeConfigs[collectionId].enabled = enabled;
        emit RechargeEnabled(collectionId, enabled);
    }

    /**
     * @notice Pause or unpause the recharge system globally
     * @param paused New pause state
     */
    function setPassRechargeSystemPaused(bool paused) external onlyAuthorized {
        LibMissionStorage.MissionStorage storage ms = LibMissionStorage.missionStorage();
        ms.rechargeSystemPaused = paused;
        emit RechargeSystemPaused(paused);
    }

    /**
     * @notice Get recharge configuration for a collection
     * @param collectionId Collection ID
     * @return config Recharge configuration
     */
    function getPassRechargeConfig(uint16 collectionId)
        external
        view
        returns (LibMissionStorage.RechargeConfig memory config)
    {
        LibMissionStorage.MissionStorage storage ms = LibMissionStorage.missionStorage();
        if (collectionId == 0 || collectionId > ms.passCollectionCounter) {
            revert CollectionNotRegistered(collectionId);
        }
        return ms.passRechargeConfigs[collectionId];
    }

    /**
     * @notice Check if recharge system is paused
     * @return paused Current pause state
     */
    function isPassRechargeSystemPaused() external view returns (bool paused) {
        return LibMissionStorage.missionStorage().rechargeSystemPaused;
    }

    // ============================================================
    // LENDING CONFIGURATION
    // ============================================================

    /**
     * @notice Configure global lending system settings
     * @param paymentToken ERC20 token for lending payments and collateral
     * @param beneficiary Address receiving platform fees
     * @param platformFeeBps Platform fee in basis points (max 1000 = 10%)
     * @param minDuration Minimum rental duration in seconds
     * @param maxDuration Maximum rental duration in seconds
     * @param maxRewardShareBps Maximum reward share for lender (max 5000 = 50%)
     * @param burnPlatformFee If true, burn platform fee instead of transfer (for YLW tokens)
     */
    function setPassLendingConfig(
        address paymentToken,
        address beneficiary,
        uint16 platformFeeBps,
        uint32 minDuration,
        uint32 maxDuration,
        uint16 maxRewardShareBps,
        bool burnPlatformFee
    ) external onlyAuthorized whenNotPaused {
        if (paymentToken == address(0) || beneficiary == address(0)) {
            revert InvalidLendingConfig();
        }
        if (platformFeeBps > 1000) { // Max 10% platform fee
            revert PlatformFeeTooHigh();
        }
        if (minDuration >= maxDuration || maxDuration == 0) {
            revert InvalidDurationRange();
        }
        if (maxRewardShareBps > 5000) { // Max 50% reward share
            revert RewardShareTooHigh();
        }

        LibMissionStorage.MissionStorage storage ms = LibMissionStorage.missionStorage();

        ms.lendingConfig = LibMissionStorage.LendingConfig({
            paymentToken: paymentToken,
            beneficiary: beneficiary,
            platformFeeBps: platformFeeBps,
            minDuration: minDuration,
            maxDuration: maxDuration,
            maxRewardShareBps: maxRewardShareBps,
            enabled: true,
            burnPlatformFee: burnPlatformFee
        });

        emit LendingConfigSet(paymentToken, platformFeeBps);
    }

    /**
     * @notice Enable or disable the lending system globally
     * @param enabled New enabled state
     */
    function setPassLendingEnabled(bool enabled) external onlyAuthorized whenNotPaused {
        LibMissionStorage.MissionStorage storage ms = LibMissionStorage.missionStorage();
        ms.lendingConfig.enabled = enabled;
    }

    /**
     * @notice Pause or unpause the lending system globally
     * @param paused New pause state
     */
    function setPassLendingSystemPaused(bool paused) external onlyAuthorized {
        LibMissionStorage.MissionStorage storage ms = LibMissionStorage.missionStorage();
        ms.lendingSystemPaused = paused;
        emit LendingSystemPaused(paused);
    }

    /**
     * @notice Get lending system configuration
     * @return config Lending configuration
     */
    function getPassLendingConfig()
        external
        view
        returns (LibMissionStorage.LendingConfig memory config)
    {
        return LibMissionStorage.missionStorage().lendingConfig;
    }

    /**
     * @notice Check if lending system is paused
     * @return paused Current pause state
     */
    function isPassLendingSystemPaused() external view returns (bool paused) {
        return LibMissionStorage.missionStorage().lendingSystemPaused;
    }
}
