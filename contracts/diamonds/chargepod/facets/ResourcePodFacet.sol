// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibMeta} from "../../shared/libraries/LibMeta.sol";
import {LibResourceStorage} from "../libraries/LibResourceStorage.sol";
import {LibColonyWarsStorage} from "../libraries/LibColonyWarsStorage.sol";
import {LibGamingStorage} from "../libraries/LibGamingStorage.sol";
import {LibFeeCollection} from "../libraries/LibFeeCollection.sol";
import {LibHenomorphsStorage} from "../libraries/LibHenomorphsStorage.sol";
import {ColonyHelper} from "../libraries/ColonyHelper.sol";
import {LibAchievementTrigger} from "../libraries/LibAchievementTrigger.sol";
import {AccessControlBase} from "./AccessControlBase.sol";
import {PodsUtils} from "../../libraries/PodsUtils.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IColonyTerritoryCards} from "../interfaces/IColonyTerritoryCards.sol";
import {IStakingSystem} from "../interfaces/IStakingInterfaces.sol";

/**
 * @title ResourcePodFacet
 * @notice Passive resource generation from NFT activity integration
 * @dev Integrates with Chargepod/Biopod systems for automatic resource generation
 *      Territory bonuses applied during generation
 * @custom:version 2.0.0 - Cleaned version (collaborative projects → CollaborativeCraftingFacet)
 */
contract ResourcePodFacet is AccessControlBase {
    
    // ==================== EVENTS ====================

    event ResourceGenerated(
        address indexed user,
        uint256 indexed collectionId,
        uint256 indexed tokenId,
        uint8 resourceType,
        uint256 amount
    );
    event ResourcesProcessed(address indexed user, uint8 resourceType, uint256 inputAmount, uint256 outputAmount);
    event InfrastructureBuilt(bytes32 indexed colonyId, uint8 infrastructureType, uint256 cost, address builder);
    event ResourceConfigUpdated(address indexed updater, string configType);
    event PassiveTrickleClaimed(address indexed user, uint256 basicAmount, uint32 hoursSinceLastClaim);
    event FortificationBuilt(uint256 indexed territoryId, address indexed builder, uint256 defenseBonus);
    event ResearchFunded(bytes32 indexed colonyId, address indexed funder, uint8 researchType, uint256 resourcesSpent);
    event ExpeditionLaunched(address indexed user, uint256 expeditionId, uint256 rareResourcesSpent);

    // ==================== ERRORS ====================

    error InvalidConfiguration(string parameter);
    error InsufficientPermissions(address user, string action);
    error InsufficientResources(uint8 resourceType, uint256 required, uint256 available);
    error InvalidProcessingRecipe(uint8 inputType, uint8 outputType);
    error InvalidInfrastructureType(uint8 infrastructureType);
    error TrickleNotReady(uint32 hoursRemaining);
    error InvalidResearchType(uint8 researchType);
    error TerritoryNotOwned(uint256 territoryId);
    error ExpeditionOnCooldown(uint32 cooldownRemaining);
    
    // ==================== INITIALIZATION ====================
    
    /**
     * @notice Initialize resource system configuration
     * @param governanceToken Premium token address (e.g., ZICO)
     * @param utilityToken Daily operations token address (e.g., YLW)
     * @param paymentBeneficiary Treasury address for payments
     */
    function initializeResourceConfig(
        address governanceToken,
        address utilityToken,
        address paymentBeneficiary
    ) external onlyAuthorized {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        
        if (governanceToken == address(0) || utilityToken == address(0) || paymentBeneficiary == address(0)) {
            revert InvalidConfiguration("zero address");
        }
        
        rs.config.governanceToken = governanceToken;
        rs.config.utilityToken = utilityToken;
        rs.config.paymentBeneficiary = paymentBeneficiary;
        
        // Initialize default settings if not already set
        LibResourceStorage.initializeStorage();
        
        emit ResourceConfigUpdated(LibMeta.msgSender(), "initialization");
    }
    
    /**
     * @notice Set reward tokens for resource generation
     * @param primaryRewardToken Main reward token
     * @param secondaryRewardToken Bonus reward token (optional)
     */
    function setRewardTokens(
        address primaryRewardToken,
        address secondaryRewardToken
    ) external onlyAuthorized {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        
        rs.config.primaryRewardToken = primaryRewardToken;
        rs.config.secondaryRewardToken = secondaryRewardToken;
        
        emit ResourceConfigUpdated(LibMeta.msgSender(), "reward tokens");
    }

    /**
     * @notice Set reward collection address for CollaborativeCraftingFacet
     * @param rewardCollection NFT collection implementing IRewardCollection
     */
    function setRewardCollectionAddress(address rewardCollection) external onlyAuthorized {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        rs.config.rewardCollectionAddress = rewardCollection;
        emit ResourceConfigUpdated(LibMeta.msgSender(), "reward collection");
    }

    /**
     * @notice Configure NFT collection for resource generation
     * @param collectionId Internal collection ID
     * @param collectionAddress NFT contract address
     * @param primaryResourceType Primary resource type (0-3)
     * @param secondaryResourceType Secondary resource type (0-3)
     * @param secondaryChance Chance for secondary resource (0-100%), 0 = disabled
     * @param generationMultiplier Production multiplier (100 = 1.0x)
     */
    function configureProductionCollection(
        uint256 collectionId,
        address collectionAddress,
        uint8 primaryResourceType,
        uint8 secondaryResourceType,
        uint8 secondaryChance,
        uint16 generationMultiplier
    ) external onlyAuthorized {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();

        if (collectionAddress == address(0)) revert InvalidConfiguration("collection address");
        if (primaryResourceType > 3) revert InvalidConfiguration("primary resource type");
        if (secondaryResourceType > 3) revert InvalidConfiguration("secondary resource type");
        if (secondaryChance > 100) revert InvalidConfiguration("secondary chance exceeds 100");

        rs.collectionConfigs[collectionId] = LibResourceStorage.CollectionConfig({
            collectionAddress: collectionAddress,
            baseResourceType: primaryResourceType,
            generationMultiplier: generationMultiplier,
            enablesResourceGeneration: true,
            enablesProjectParticipation: true,
            secondaryResourceType: secondaryResourceType,
            secondaryResourceChance: secondaryChance
        });

        rs.collectionAddresses[collectionId] = collectionAddress;

        emit ResourceConfigUpdated(LibMeta.msgSender(), "collection config");
    }
    
    /**
     * @notice Authorize external address to call resource generation
     * @param caller Address to authorize (e.g., ChargeFacet, BiopodFacet)
     * @param authorized Authorization status
     */
    function setAuthorizedCaller(address caller, bool authorized) external onlyAuthorized {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        rs.authorizedCallers[caller] = authorized;
        
        emit ResourceConfigUpdated(LibMeta.msgSender(), "authorized caller");
    }
    
    /**
     * @notice Set resource decay configuration
     * @param enabled Whether decay is active
     * @param decayRate Decay rate per day (basis points, 10000 = 100%)
     */
    function setResourceDecay(bool enabled, uint16 decayRate) external onlyAuthorized {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        
        if (decayRate > 10000) revert InvalidConfiguration("decay rate too high");
        
        rs.config.resourceDecayEnabled = enabled;
        rs.config.baseResourceDecayRate = decayRate;
        
        emit ResourceConfigUpdated(LibMeta.msgSender(), "resource decay");
    }

    /**
     * @notice Set infrastructure cost configuration
     * @param infrastructureType Type (0=Processing, 1=Research, 2=Defense)
     * @param paymentCost Payment token cost
     * @param buildTime Build time in seconds
     * @param enabled Whether this infrastructure type is enabled
     * @param resourceTypes Array of required resource types
     * @param resourceAmounts Array of required resource amounts
     */
    function setInfrastructureCost(
        uint8 infrastructureType,
        uint256 paymentCost,
        uint32 buildTime,
        bool enabled,
        uint8[] calldata resourceTypes,
        uint256[] calldata resourceAmounts
    ) external onlyAuthorized {
        if (infrastructureType > 2) revert InvalidConfiguration("infrastructure type");
        if (resourceTypes.length != resourceAmounts.length) revert InvalidConfiguration("array length mismatch");

        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        LibResourceStorage.InfrastructureCost storage cost = rs.infrastructureCosts[infrastructureType];

        cost.paymentCost = paymentCost;
        cost.buildTime = buildTime;
        cost.enabled = enabled;

        // Clear existing requirements
        delete cost.resourceRequirements;

        // Add new requirements
        for (uint256 i = 0; i < resourceTypes.length; i++) {
            if (resourceTypes[i] > 3) revert InvalidConfiguration("resource type");
            cost.resourceRequirements.push(LibResourceStorage.ResourceRequirement({
                resourceType: resourceTypes[i],
                amount: resourceAmounts[i]
            }));
        }

        emit ResourceConfigUpdated(LibMeta.msgSender(), "infrastructure cost");
    }

    /**
     * @notice Admin function to grant resources to a user
     * @param user Address to receive resources
     * @param resourceType Type of resource (0=Basic, 1=Energy, 2=Bio, 3=Rare)
     * @param amount Amount of resources to grant
     */
    function grantResources(
        address user,
        uint8 resourceType,
        uint256 amount
    ) external onlyAuthorized {
        if (user == address(0)) revert InvalidConfiguration("zero address");
        if (resourceType > 3) revert InvalidConfiguration("resource type");

        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();

        // Apply decay before adding resources
        LibResourceStorage.applyResourceDecay(user);

        rs.userResources[user][resourceType] += amount;
        rs.userResourcesLastUpdate[user] = uint32(block.timestamp);

        emit ResourceConfigUpdated(LibMeta.msgSender(), "grant resources");
    }

    /**
     * @notice Admin function to batch grant resources to a user
     * @param user Address to receive resources
     * @param amounts Array of amounts for each resource type [Basic, Energy, Bio, Rare]
     */
    function grantResourcesBatch(
        address user,
        uint256[4] calldata amounts
    ) external onlyAuthorized {
        if (user == address(0)) revert InvalidConfiguration("zero address");

        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();

        // Apply decay before adding resources
        LibResourceStorage.applyResourceDecay(user);

        for (uint8 i = 0; i < 4; i++) {
            if (amounts[i] > 0) {
                rs.userResources[user][i] += amounts[i];
            }
        }
        rs.userResourcesLastUpdate[user] = uint32(block.timestamp);

        emit ResourceConfigUpdated(LibMeta.msgSender(), "grant resources batch");
    }

    // ==================== RESOURCE GENERATION ====================
    
    /**
     * @notice Generate resources based on token activity
     * @dev Called by existing action systems (ChargeFacet, BiopodFacet)
     * @param collectionId Collection ID of the token
     * @param tokenId Token ID
     * @param actionType Type of action performed (from existing systems)
     * @param baseAmount Base amount from existing calculation
     * @return resourceAmount Amount of resources generated
     */
    function generateResources(
        uint256 collectionId,
        uint256 tokenId,
        uint8 actionType,
        uint256 baseAmount
    ) external whenNotPaused returns (uint256 resourceAmount) {
        // Only allow calls from authorized system facets
        if (!_isAuthorizedSystemCall()) {
            revert InsufficientPermissions(LibMeta.msgSender(), "generateResources");
        }
        
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        
        // Get token's resource generation parameters
        uint8 resourceType = _calculateResourceType(collectionId, actionType, tokenId);
        uint256 generationRate = _calculateGenerationRate(collectionId, tokenId, baseAmount);
        
        if (generationRate > 0) {
            uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
            address tokenOwner = _getTokenOwner(collectionId, tokenId);
            
            if (tokenOwner == address(0)) return 0;
            
            // Apply Territory Card bonuses
            generationRate = _applyTerritoryBonuses(tokenOwner, generationRate);

            // Apply decay before adding new resources
            LibResourceStorage.applyResourceDecay(tokenOwner);

            // Update user resources
            rs.userResources[tokenOwner][resourceType] += generationRate;
            rs.userResourcesLastUpdate[tokenOwner] = uint32(block.timestamp);
            
            // Update token generation stats
            rs.tokenResourceGeneration[combinedId][resourceType] += generationRate;
            rs.tokenLastGeneration[combinedId] = uint32(block.timestamp);
            
            // Update global stats
            unchecked {
                rs.totalResourcesGenerated += generationRate;
            }
            
            emit ResourceGenerated(tokenOwner, collectionId, tokenId, resourceType, generationRate);
            return generationRate;
        }
        
        return 0;
    }

    /**
     * @notice Award resources directly to a user (without token context)
     * @dev Used by TerritoryResourceFacet and other systems that don't use collectionConfig
     *      Only callable by authorized system facets via address(this)
     * @param user User address to receive resources
     * @param resourceType Type of resource (0-3)
     * @param amount Amount of resources to award
     * @return success Whether the operation succeeded
     */
    function awardResourcesDirect(
        address user,
        uint8 resourceType,
        uint256 amount
    ) external whenNotPaused returns (bool success) {
        // Only allow calls from authorized system facets
        if (!_isAuthorizedSystemCall()) {
            revert InsufficientPermissions(LibMeta.msgSender(), "awardResourcesDirect");
        }

        if (user == address(0) || amount == 0) return false;
        if (resourceType > 3) revert InvalidConfiguration("resource type");

        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();

        // Apply decay before adding new resources
        LibResourceStorage.applyResourceDecay(user);

        // Update user resources
        rs.userResources[user][resourceType] += amount;
        rs.userResourcesLastUpdate[user] = uint32(block.timestamp);

        // Update global stats
        unchecked {
            rs.totalResourcesGenerated += amount;
        }

        // Emit event with collectionId=0, tokenId=0 to indicate direct award
        emit ResourceGenerated(user, 0, 0, resourceType, amount);

        return true;
    }

    // ==================== RESOURCE PROCESSING ====================

    /**
     * @notice Process resources to create refined materials
     * @param resourceType Input resource type (0-3)
     * @param amount Amount to process
     * @param targetType Output resource type (0-3)
     * @return outputAmount Amount of processed resources
     */
    function processResources(
        uint8 resourceType,
        uint256 amount,
        uint8 targetType
    ) external whenNotPaused nonReentrant returns (uint256 outputAmount) {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        address user = LibMeta.msgSender();

        LibResourceStorage.applyResourceDecay(user);

        if (rs.userResources[user][resourceType] < amount) {
            revert InsufficientResources(resourceType, amount, rs.userResources[user][resourceType]);
        }

        LibResourceStorage.ProcessingRecipe memory recipe = rs.processingRecipes[resourceType][targetType];
        if (recipe.outputMultiplier == 0 || !recipe.enabled) {
            revert InvalidProcessingRecipe(resourceType, targetType);
        }

        // Collect processing operation fee (configured YELLOW, burned)
        LibColonyWarsStorage.OperationFee storage processingFee = LibColonyWarsStorage.getOperationFee(LibColonyWarsStorage.FEE_PROCESSING);
        LibFeeCollection.processConfiguredFee(
            processingFee,
            user,
            "resource_processing"
        );

        rs.userResources[user][resourceType] -= amount;
        outputAmount = (amount * recipe.outputMultiplier) / 100;
        rs.userResources[user][targetType] += outputAmount;

        emit ResourcesProcessed(user, resourceType, amount, outputAmount);

        // Trigger resource processing achievement
        LibAchievementTrigger.triggerResourceProcessing(user);

        return outputAmount;
    }

    // ==================== INFRASTRUCTURE ====================

    /**
     * @notice Build colony infrastructure
     * @param colonyId Colony to build in
     * @param infrastructureType Type of infrastructure (0=Processing, 1=Research, 2=Defense)
     */
    function buildInfrastructure(
        bytes32 colonyId,
        uint8 infrastructureType
    ) external whenNotPaused nonReentrant {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        address user = LibMeta.msgSender();

        if (!_isAuthorizedForColony(colonyId, user)) {
            revert InsufficientPermissions(user, "build infrastructure");
        }

        LibResourceStorage.InfrastructureCost storage cost = rs.infrastructureCosts[infrastructureType];
        if (!cost.enabled) {
            revert InvalidInfrastructureType(infrastructureType);
        }

        LibResourceStorage.applyResourceDecay(user);

        // Check and consume resources
        for (uint256 i = 0; i < cost.resourceRequirements.length; i++) {
            uint8 resType = cost.resourceRequirements[i].resourceType;
            uint256 required = cost.resourceRequirements[i].amount;

            if (rs.userResources[user][resType] < required) {
                revert InsufficientResources(resType, required, rs.userResources[user][resType]);
            }
            rs.userResources[user][resType] -= required;
        }

        // Collect payment
        if (cost.paymentCost > 0 && rs.config.utilityToken != address(0)) {
            LibFeeCollection.collectFee(
                IERC20(rs.config.utilityToken),
                user,
                rs.config.paymentBeneficiary,
                cost.paymentCost,
                "buildInfrastructure"
            );
        }

        rs.colonyInfrastructure[colonyId][infrastructureType] += 1;
        rs.totalInfrastructureBuilt += 1;

        emit InfrastructureBuilt(colonyId, infrastructureType, cost.paymentCost, user);

        // Trigger infrastructure building achievement
        LibAchievementTrigger.triggerInfrastructureBuild(user);
    }

    // ==================== PASSIVE TRICKLE ====================

    /**
     * @notice Claim passive resource trickle
     * @dev PASSIVE RESOURCE GENERATION: All active users receive small Basic resource income
     *      - Minimum 4 hours between claims
     *      - 10 Basic resources per hour since last claim
     *      - Maximum 240 Basic per claim (24 hours cap)
     * @return basicAmount Amount of Basic resources claimed
     */
    function claimPassiveTrickle() external whenNotPaused nonReentrant returns (uint256 basicAmount) {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        address user = LibMeta.msgSender();

        // Get last trickle time
        uint32 lastTrickle = rs.userResourcesLastUpdate[user];
        uint32 currentTime = uint32(block.timestamp);

        // First-time users initialize their trickle timestamp
        if (lastTrickle == 0) {
            rs.userResourcesLastUpdate[user] = currentTime;
            return 0;
        }

        // Minimum 4 hours between claims
        uint32 hoursSinceLastClaim = (currentTime - lastTrickle) / 3600;
        if (hoursSinceLastClaim < 4) {
            uint32 hoursRemaining = 4 - hoursSinceLastClaim;
            revert TrickleNotReady(hoursRemaining);
        }

        // Cap at 24 hours
        if (hoursSinceLastClaim > 24) {
            hoursSinceLastClaim = 24;
        }

        // Calculate trickle: 10 Basic per hour
        basicAmount = uint256(hoursSinceLastClaim) * 10;

        // Apply decay before adding resources
        LibResourceStorage.applyResourceDecay(user);

        // Grant Basic resources
        rs.userResources[user][LibResourceStorage.BASIC_MATERIALS] += basicAmount;
        rs.userResourcesLastUpdate[user] = currentTime;

        emit PassiveTrickleClaimed(user, basicAmount, hoursSinceLastClaim);
        emit ResourceGenerated(user, 0, 0, LibResourceStorage.BASIC_MATERIALS, basicAmount);

        return basicAmount;
    }

    /**
     * @notice Get pending passive trickle amount
     * @param user User address
     * @return pendingBasic Amount of Basic resources claimable
     * @return canClaim Whether claim is available
     * @return hoursUntilNextClaim Hours until next claim available (0 if ready)
     */
    function getPendingTrickle(address user) external view returns (
        uint256 pendingBasic,
        bool canClaim,
        uint32 hoursUntilNextClaim
    ) {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();

        uint32 lastTrickle = rs.userResourcesLastUpdate[user];
        if (lastTrickle == 0) {
            return (0, false, 0);
        }

        uint32 hoursSince = (uint32(block.timestamp) - lastTrickle) / 3600;

        if (hoursSince < 4) {
            hoursUntilNextClaim = 4 - hoursSince;
            return (0, false, hoursUntilNextClaim);
        }

        // Cap at 24 hours
        if (hoursSince > 24) {
            hoursSince = 24;
        }

        pendingBasic = uint256(hoursSince) * 10;
        canClaim = true;
        hoursUntilNextClaim = 0;

        return (pendingBasic, canClaim, hoursUntilNextClaim);
    }

    // ==================== RESOURCE SINKS ====================

    /**
     * @notice Build territory fortification (Resource Sink)
     * @dev RESOURCE SINK: Spend Basic + Energy to improve territory defense
     *      - Costs: 500 Basic + 200 Energy per level
     *      - Provides defense bonus to territory
     * @param territoryId Territory to fortify
     * @return defenseBonus Defense points added
     */
    function buildFortification(uint256 territoryId) external whenNotPaused nonReentrant returns (uint256 defenseBonus) {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        address user = LibMeta.msgSender();

        // Verify territory ownership
        LibColonyWarsStorage.Territory storage territory = cws.territories[territoryId];
        bytes32 colonyId = cws.userToColony[user];

        if (territory.controllingColony != colonyId || colonyId == bytes32(0)) {
            revert TerritoryNotOwned(territoryId);
        }

        // Apply decay before checking resources
        LibResourceStorage.applyResourceDecay(user);

        // Cost: 500 Basic + 200 Energy
        uint256 basicCost = 500;
        uint256 energyCost = 200;

        if (rs.userResources[user][LibResourceStorage.BASIC_MATERIALS] < basicCost) {
            revert InsufficientResources(LibResourceStorage.BASIC_MATERIALS, basicCost, rs.userResources[user][LibResourceStorage.BASIC_MATERIALS]);
        }
        if (rs.userResources[user][LibResourceStorage.ENERGY_CRYSTALS] < energyCost) {
            revert InsufficientResources(LibResourceStorage.ENERGY_CRYSTALS, energyCost, rs.userResources[user][LibResourceStorage.ENERGY_CRYSTALS]);
        }

        // Consume resources
        rs.userResources[user][LibResourceStorage.BASIC_MATERIALS] -= basicCost;
        rs.userResources[user][LibResourceStorage.ENERGY_CRYSTALS] -= energyCost;

        // Apply defense bonus to territory (10 fortification per upgrade, capped at 100)
        uint16 currentFortification = territory.fortificationLevel;
        uint16 maxBonus = currentFortification >= 100 ? 0 : 100 - currentFortification;
        uint16 actualBonus = maxBonus > 10 ? 10 : maxBonus;

        territory.fortificationLevel = currentFortification + actualBonus;
        defenseBonus = uint256(actualBonus);

        emit FortificationBuilt(territoryId, user, defenseBonus);

        return defenseBonus;
    }

    /**
     * @notice Fund colony research project (Resource Sink)
     * @dev RESOURCE SINK: Spend Bio + Rare to unlock colony bonuses
     *      - Research types: 0=Production, 1=Defense, 2=Economy
     *      - Costs: 300 Bio + 50 Rare per research
     * @param colonyId Colony to fund research for
     * @param researchType Type of research (0-2)
     */
    function fundResearch(bytes32 colonyId, uint8 researchType) external whenNotPaused nonReentrant {
        if (researchType > 2) {
            revert InvalidResearchType(researchType);
        }

        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        address user = LibMeta.msgSender();

        if (!_isAuthorizedForColony(colonyId, user)) {
            revert InsufficientPermissions(user, "fund research");
        }

        // Apply decay before checking resources
        LibResourceStorage.applyResourceDecay(user);

        // Cost: 300 Bio + 50 Rare
        uint256 bioCost = 300;
        uint256 rareCost = 50;

        if (rs.userResources[user][LibResourceStorage.BIO_COMPOUNDS] < bioCost) {
            revert InsufficientResources(LibResourceStorage.BIO_COMPOUNDS, bioCost, rs.userResources[user][LibResourceStorage.BIO_COMPOUNDS]);
        }
        if (rs.userResources[user][LibResourceStorage.RARE_ELEMENTS] < rareCost) {
            revert InsufficientResources(LibResourceStorage.RARE_ELEMENTS, rareCost, rs.userResources[user][LibResourceStorage.RARE_ELEMENTS]);
        }

        // Consume resources
        rs.userResources[user][LibResourceStorage.BIO_COMPOUNDS] -= bioCost;
        rs.userResources[user][LibResourceStorage.RARE_ELEMENTS] -= rareCost;

        // Apply research bonus to colony infrastructure
        // Research type maps to infrastructure type
        rs.colonyInfrastructure[colonyId][researchType] += 1;
        rs.totalInfrastructureBuilt += 1;

        emit ResearchFunded(colonyId, user, researchType, bioCost + rareCost);
    }

    /**
     * @notice Launch expedition for rewards (Resource Sink)
     * @dev RESOURCE SINK: Spend Rare resources for chance at premium rewards
     *      - Costs: 100 Rare resources
     *      - 24-hour cooldown between expeditions
     *      - Rewards distributed via event (off-chain processing)
     * @return expeditionId Unique expedition ID
     */
    function launchExpedition() external whenNotPaused nonReentrant returns (uint256 expeditionId) {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        address user = LibMeta.msgSender();

        // Check expedition cooldown (24 hours)
        uint256 lastExpedition = gs.userLastActivityTime[user];
        if (lastExpedition > 0 && block.timestamp < lastExpedition + 86400) {
            uint32 cooldownRemaining = uint32((lastExpedition + 86400) - block.timestamp);
            revert ExpeditionOnCooldown(cooldownRemaining);
        }

        // Apply decay before checking resources
        LibResourceStorage.applyResourceDecay(user);

        // Cost: 100 Rare resources
        uint256 rareCost = 100;

        if (rs.userResources[user][LibResourceStorage.RARE_ELEMENTS] < rareCost) {
            revert InsufficientResources(LibResourceStorage.RARE_ELEMENTS, rareCost, rs.userResources[user][LibResourceStorage.RARE_ELEMENTS]);
        }

        // Consume resources
        rs.userResources[user][LibResourceStorage.RARE_ELEMENTS] -= rareCost;

        // Generate expedition ID
        expeditionId = uint256(keccak256(abi.encodePacked(
            user,
            block.timestamp,
            block.prevrandao,
            rareCost
        )));

        // Update last activity for cooldown tracking
        gs.userLastActivityTime[user] = block.timestamp;

        emit ExpeditionLaunched(user, expeditionId, rareCost);

        return expeditionId;
    }

    /**
     * @notice Get resource sink costs
     * @return fortificationBasic Basic cost for fortification
     * @return fortificationEnergy Energy cost for fortification
     * @return researchBio Bio cost for research
     * @return researchRare Rare cost for research
     * @return expeditionRare Rare cost for expedition
     */
    function getResourceSinkCosts() external pure returns (
        uint256 fortificationBasic,
        uint256 fortificationEnergy,
        uint256 researchBio,
        uint256 researchRare,
        uint256 expeditionRare
    ) {
        return (500, 200, 300, 50, 100);
    }

    // ==================== VIEW FUNCTIONS ====================
    
    /**
     * @notice Get user's resource balances
     * @param user Address to check
     * @return resources Array of [Basic, Energy, Bio, Rare] balances
     */
    function getUserResources(address user) external view returns (uint256[4] memory resources) {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        
        for (uint8 i = 0; i < 4; i++) {
            resources[i] = rs.userResources[user][i];
        }
        
        return resources;
    }
    
    /**
     * @notice Get resource system configuration
     */
    function getResourceConfig() external view returns (
        address governanceToken,
        address utilityToken,
        address primaryRewardToken,
        address secondaryRewardToken,
        address paymentBeneficiary,
        address rewardCollectionAddress,
        uint16 baseResourceDecayRate,
        bool resourceDecayEnabled
    ) {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();

        return (
            rs.config.governanceToken,
            rs.config.utilityToken,
            rs.config.primaryRewardToken,
            rs.config.secondaryRewardToken,
            rs.config.paymentBeneficiary,
            rs.config.rewardCollectionAddress,
            rs.config.baseResourceDecayRate,
            rs.config.resourceDecayEnabled
        );
    }
    
    /**
     * @notice Get collection configuration
     */
    function getProductionCollectionConfig(uint256 collectionId) external view returns (
        address collectionAddress,
        uint8 baseResourceType,
        uint16 generationMultiplier,
        bool enablesResourceGeneration,
        uint8 secondaryResourceType,
        uint8 secondaryResourceChance
    ) {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        LibResourceStorage.CollectionConfig memory config = rs.collectionConfigs[collectionId];

        return (
            config.collectionAddress,
            config.baseResourceType,
            config.generationMultiplier,
            config.enablesResourceGeneration,
            config.secondaryResourceType,
            config.secondaryResourceChance
        );
    }
    
    /**
     * @notice Check if address is authorized caller
     */
    function isAuthorizedCaller(address caller) external view returns (bool) {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        return rs.authorizedCallers[caller];
    }
    
    /**
     * @notice Get total resources generated (global stat)
     */
    function getTotalResourcesGenerated() external view returns (uint256) {
        return LibResourceStorage.resourceStorage().totalResourcesGenerated;
    }

    /**
     * @notice Get colony infrastructure levels
     * @param colonyId Colony to check
     * @return infrastructure Array of [Processing, Research, Defense] levels
     */
    function getColonyInfrastructure(bytes32 colonyId) external view returns (uint256[3] memory infrastructure) {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        for (uint8 i = 0; i < 3; i++) {
            infrastructure[i] = rs.colonyInfrastructure[colonyId][i];
        }
    }

    /**
     * @notice Get infrastructure cost configuration
     * @param infrastructureType Type (0=Processing, 1=Research, 2=Defense)
     */
    function getInfrastructureCost(uint8 infrastructureType) external view returns (
        uint256 paymentCost,
        uint32 buildTime,
        bool enabled,
        uint8[] memory resourceTypes,
        uint256[] memory resourceAmounts
    ) {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        LibResourceStorage.InfrastructureCost storage cost = rs.infrastructureCosts[infrastructureType];

        paymentCost = cost.paymentCost;
        buildTime = cost.buildTime;
        enabled = cost.enabled;

        uint256 reqLength = cost.resourceRequirements.length;
        resourceTypes = new uint8[](reqLength);
        resourceAmounts = new uint256[](reqLength);

        for (uint256 i = 0; i < reqLength; i++) {
            resourceTypes[i] = cost.resourceRequirements[i].resourceType;
            resourceAmounts[i] = cost.resourceRequirements[i].amount;
        }
    }

    // ==================== INTERNAL FUNCTIONS ====================
    
    /**
     * @notice Check if caller is authorized system contract
     * @dev Allows calls from:
     *      1. Diamond proxy itself (inter-facet calls via address(this))
     *      2. Explicitly authorized callers (set via setAuthorizedCaller)
     */
    function _isAuthorizedSystemCall() internal view returns (bool) {
        // Allow inter-facet calls (ChargeFacet, BiopodFacet calling via address(this))
        // When facet A calls IFacetB(address(this)).method(), msg.sender = Diamond proxy
        if (msg.sender == address(this)) {
            return true;
        }

        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        return rs.authorizedCallers[LibMeta.msgSender()];
    }
    
    /**
     * @notice Calculate resource type based on collection and action
     * @dev Uses pseudo-random selection for secondary resource based on configured chance
     */
    function _calculateResourceType(
        uint256 collectionId,
        uint8 actionType,
        uint256 tokenId
    ) internal view returns (uint8) {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();

        LibResourceStorage.CollectionConfig memory config = rs.collectionConfigs[collectionId];

        if (!config.enablesResourceGeneration) {
            // Fallback: Simple mapping based on collection ID
            return uint8(collectionId % 4);
        }

        // Check if secondary resource is configured
        if (config.secondaryResourceChance > 0) {
            // Pseudo-random based on block data and token context
            uint256 random = uint256(keccak256(abi.encodePacked(
                block.timestamp,
                block.prevrandao,
                collectionId,
                tokenId,
                actionType
            ))) % 100;

            if (random < config.secondaryResourceChance) {
                return config.secondaryResourceType;
            }
        }

        return config.baseResourceType;
    }
    
    /**
     * @notice Calculate resource generation rate
     */
    function _calculateGenerationRate(
        uint256 collectionId, 
        uint256, /* tokenId - unused but kept for interface compatibility */
        uint256 baseAmount
    ) internal view returns (uint256) {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        
        // Use collection multiplier if configured
        LibResourceStorage.CollectionConfig memory config = rs.collectionConfigs[collectionId];
        if (config.enablesResourceGeneration && config.generationMultiplier > 0) {
            return (baseAmount * config.generationMultiplier) / 100;
        }
        
        // Default: 10% of base reward as resources
        return baseAmount / 10;
    }
    
    /**
     * @notice Get token owner or staker (checks staking first, then NFT ownership)
     * @dev Checks staking system first for staked tokens, falls back to direct ownership
     */
    function _getTokenOwner(uint256 collectionId, uint256 tokenId) internal view returns (address) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();

        // Get collection address from LibHenomorphsStorage (primary source)
        address collectionAddress;
        if (collectionId > 0 && collectionId <= hs.collectionCounter) {
            collectionAddress = hs.specimenCollections[collectionId].collectionAddress;
        }

        // Fallback to LibResourceStorage if not in HenomorphsStorage
        if (collectionAddress == address(0)) {
            LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
            collectionAddress = rs.collectionAddresses[collectionId];
        }

        if (collectionAddress == address(0)) {
            return address(0);
        }

        // Check staking system first - if token is staked, return staker address
        address stakingSystem = hs.stakingSystemAddress;
        if (stakingSystem != address(0)) {
            try IStakingSystem(stakingSystem).isSpecimenStaked(collectionId, tokenId) returns (bool isStaked) {
                if (isStaked) {
                    try IStakingSystem(stakingSystem).getTokenStaker(collectionAddress, tokenId) returns (address staker) {
                        if (staker != address(0)) {
                            return staker;
                        }
                    } catch {}
                }
            } catch {}
        }

        // Fallback to direct NFT ownership
        try IERC721(collectionAddress).ownerOf(tokenId) returns (address owner) {
            return owner;
        } catch {
            return address(0);
        }
    }
    
    /**
     * @notice Apply territory bonuses to resource generation
     * @dev Direct integration with LibColonyWarsStorage for territory bonuses
     *      Includes: territory.bonusValue, TerritoryEquipment, Territory Card productionBonus
     */
    function _applyTerritoryBonuses(
        address user,
        uint256 baseAmount
    ) internal view returns (uint256 boostedAmount) {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();

        // Get user's colony directly from storage
        bytes32 colonyId = cws.userToColony[user];
        if (colonyId == bytes32(0)) {
            return baseAmount;
        }

        // Get colony's territories directly from storage
        uint256[] memory territoryIds = cws.colonyTerritories[colonyId];
        if (territoryIds.length == 0) {
            return baseAmount;
        }

        // Calculate total bonus from all territories
        uint256 totalBonusPercent = 0;
        for (uint256 i = 0; i < territoryIds.length; i++) {
            LibColonyWarsStorage.Territory storage territory = cws.territories[territoryIds[i]];

            // Each territory provides production bonus based on bonusValue
            // bonusValue is in basis points (100 = 1%)
            totalBonusPercent += territory.bonusValue;

            // Check for equipped Infrastructure Cards bonus
            LibColonyWarsStorage.TerritoryEquipment storage equipment = cws.territoryEquipment[territoryIds[i]];
            if (equipment.totalProductionBonus > 0) {
                totalBonusPercent += equipment.totalProductionBonus;
            }

            // NEW: Add Territory Card productionBonus
            uint256 cardId = cws.territoryToCard[territoryIds[i]];
            if (cardId != 0 && cws.cardContracts.territoryCards != address(0)) {
                try IColonyTerritoryCards(cws.cardContracts.territoryCards).getTerritoryTraits(cardId) returns (
                    IColonyTerritoryCards.TerritoryTraits memory traits
                ) {
                    // productionBonus is 0-100, convert to basis points (* 100)
                    totalBonusPercent += uint256(traits.productionBonus) * 100;
                } catch {
                    // Card may not exist or contract call failed - continue without bonus
                }
            }
        }

        // Apply accumulated bonus (basis points: 10000 = 100%)
        if (totalBonusPercent > 0) {
            boostedAmount = baseAmount + (baseAmount * totalBonusPercent) / 10000;
        } else {
            boostedAmount = baseAmount;
        }

        return boostedAmount;
    }

    /**
     * @notice Check if user is authorized for colony operations
     * @param colonyId Colony to check
     */
    function _isAuthorizedForColony(bytes32 colonyId, address /* user */) internal view returns (bool) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        return ColonyHelper.isColonyCreator(colonyId, hs.stakingSystemAddress);
    }
}
