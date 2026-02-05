// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibMeta} from "../../shared/libraries/LibMeta.sol";
import {LibResourceStorage} from "../libraries/LibResourceStorage.sol";
import {LibColonyWarsStorage} from "../libraries/LibColonyWarsStorage.sol";
import {LibBuildingsStorage} from "../libraries/LibBuildingsStorage.sol";
import {LibFeeCollection} from "../../staking/libraries/LibFeeCollection.sol";
import {AccessControlBase} from "../../common/facets/AccessControlBase.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/**
 * @title ColonyBuildingsFacet
 * @notice Manages colony buildings that provide various bonuses
 * @dev Consumes resources to construct and maintain buildings
 * @author rutilicus.eth (ArchXS)
 */
contract ColonyBuildingsFacet is AccessControlBase {
    using SafeERC20 for IERC20;

    // ============================================
    // EVENTS
    // ============================================

    event BuildingConstructionStarted(
        bytes32 indexed colonyId,
        uint8 indexed buildingType,
        address indexed builder,
        uint32 completionTime
    );

    event BuildingConstructionCompleted(
        bytes32 indexed colonyId,
        uint8 indexed buildingType,
        uint8 level
    );

    event BuildingUpgradeStarted(
        bytes32 indexed colonyId,
        uint8 indexed buildingType,
        uint8 fromLevel,
        uint8 toLevel,
        uint32 completionTime
    );

    event BuildingMaintenancePaid(
        bytes32 indexed colonyId,
        uint8 indexed buildingType,
        uint256 amount,
        uint32 paidUntil
    );

    event PassiveResourcesClaimed(
        bytes32 indexed colonyId,
        address indexed claimer,
        uint256 basicMaterials,
        uint256 energyCrystals,
        uint256 bioCompounds
    );

    event BuildingDemolished(
        bytes32 indexed colonyId,
        uint8 indexed buildingType,
        uint8 level
    );

    event BuildingsSystemToggled(bool enabled);

    event BuildingCardAttached(
        bytes32 indexed colonyId,
        uint8 indexed buildingType,
        uint256 indexed tokenId,
        address owner,
        uint16 rarityBonusBps
    );

    event BuildingCardDetached(
        bytes32 indexed colonyId,
        uint8 indexed buildingType,
        uint256 indexed tokenId,
        address owner
    );

    event BuildingCardsContractUpdated(address indexed oldAddress, address indexed newAddress);

    // Multi-system card events
    event CardSystemInitialized();
    event CardSystemConfigUpdated();
    event RarityBonusConfigUpdated();
    event CardCollectionRegistered(uint16 indexed collectionId, address contractAddress, string name);
    event CardCollectionToggled(uint16 indexed collectionId, bool enabled);
    event CardTypeRegistered(uint8 indexed typeId, string name, uint8 system);
    event CardTypeToggled(uint8 indexed typeId, bool enabled);
    event MultiSystemCardConfigUpdated(uint8 maxCardsPerSpecimen, uint8 maxCardsPerVentureSlot);

    // ============================================
    // ERRORS
    // ============================================

    error BuildingsSystemDisabled();
    error InvalidBuildingType(uint8 buildingType);
    error BuildingAlreadyExists(bytes32 colonyId, uint8 buildingType);
    error BuildingUnderConstruction(bytes32 colonyId, uint8 buildingType);
    error BuildingNotFound(bytes32 colonyId, uint8 buildingType);
    error MaxBuildingsReached(bytes32 colonyId);
    error InsufficientResources(uint8 resourceType, uint256 required, uint256 available);
    error InsufficientTokens(uint256 required, uint256 available);
    error ConstructionNotComplete(uint32 remainingSeconds);
    error AlreadyMaxLevel(uint8 currentLevel);
    error NotColonyOwner();
    error NothingToClaim();
    error BuildingTypeNotEnabled(uint8 buildingType);
    error CardModeDisabled();
    error BuildingCardsContractNotSet();
    error CardAlreadyAttached(uint256 tokenId);
    error CardNotAttached(bytes32 colonyId, uint8 buildingType);
    error NotCardOwner(uint256 tokenId);
    error CardTypeMismatch(uint8 expected, uint8 actual);
    error CardNotConstructed();

    // ============================================
    // MAIN FUNCTIONS
    // ============================================

    /**
     * @notice Start construction of a new building
     * @param buildingType Type of building to construct (0-7)
     */
    function constructBuilding(uint8 buildingType) external whenNotPaused nonReentrant {
        LibBuildingsStorage.BuildingsStorage storage bs = LibBuildingsStorage.buildingsStorage();
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();

        address caller = LibMeta.msgSender();
        bytes32 colonyId = LibColonyWarsStorage.getUserPrimaryColony(caller);
        require(colonyId != bytes32(0), "No colony");

        // Validate
        (bool canBuild, string memory reason) = LibBuildingsStorage.canColonyBuild(colonyId, buildingType);
        if (!canBuild) {
            if (keccak256(bytes(reason)) == keccak256("Buildings system disabled")) {
                revert BuildingsSystemDisabled();
            } else if (keccak256(bytes(reason)) == keccak256("Invalid building type")) {
                revert InvalidBuildingType(buildingType);
            } else if (keccak256(bytes(reason)) == keccak256("Building type not enabled")) {
                revert BuildingTypeNotEnabled(buildingType);
            } else if (keccak256(bytes(reason)) == keccak256("Building already exists")) {
                revert BuildingAlreadyExists(colonyId, buildingType);
            } else if (keccak256(bytes(reason)) == keccak256("Building under construction")) {
                revert BuildingUnderConstruction(colonyId, buildingType);
            } else if (keccak256(bytes(reason)) == keccak256("Max buildings reached")) {
                revert MaxBuildingsReached(colonyId);
            }
            revert(reason);
        }

        LibBuildingsStorage.BuildingBlueprint storage blueprint = bs.blueprints[buildingType];

        // Consume resources (level 1 costs)
        for (uint8 i = 0; i < 4; i++) {
            uint256 required = blueprint.resourceCosts[i];
            if (required > 0) {
                uint256 available = rs.userResources[caller][i];
                if (available < required) {
                    revert InsufficientResources(i, required, available);
                }
                rs.userResources[caller][i] -= required;
                LibResourceStorage.decrementGlobalSupply(i, required);
            }
        }

        // Consume tokens via LibFeeCollection
        if (blueprint.tokenCost > 0) {
            _collectBuildingFee(caller, blueprint.tokenCost, "building_construction");
        }

        // Create building (under construction)
        LibBuildingsStorage.Building storage building = bs.colonyBuildings[colonyId][buildingType];
        building.buildingType = buildingType;
        building.level = 1;
        building.constructionStart = uint32(block.timestamp);
        building.constructionEnd = uint32(block.timestamp) + blueprint.constructionTime;
        building.lastMaintenancePaid = uint32(block.timestamp);
        building.active = false;
        building.underConstruction = true;

        bs.colonyBuildingCount[colonyId]++;
        bs.totalBuildingsConstructed++;
        bs.buildingsPerType[buildingType]++;

        emit BuildingConstructionStarted(colonyId, buildingType, caller, building.constructionEnd);
    }

    /**
     * @notice Complete construction of a building
     * @param buildingType Type of building to complete
     */
    function completeConstruction(uint8 buildingType) external whenNotPaused nonReentrant {
        LibBuildingsStorage.BuildingsStorage storage bs = LibBuildingsStorage.buildingsStorage();

        address caller = LibMeta.msgSender();
        bytes32 colonyId = LibColonyWarsStorage.getUserPrimaryColony(caller);
        require(colonyId != bytes32(0), "No colony");

        LibBuildingsStorage.Building storage building = bs.colonyBuildings[colonyId][buildingType];

        if (!building.underConstruction) {
            revert BuildingNotFound(colonyId, buildingType);
        }

        if (block.timestamp < building.constructionEnd) {
            revert ConstructionNotComplete(building.constructionEnd - uint32(block.timestamp));
        }

        // Complete construction
        building.active = true;
        building.underConstruction = false;
        building.constructionStart = 0;
        building.constructionEnd = 0;

        emit BuildingConstructionCompleted(colonyId, buildingType, building.level);
    }

    /**
     * @notice Upgrade an existing building
     * @param buildingType Type of building to upgrade
     */
    function upgradeBuilding(uint8 buildingType) external whenNotPaused nonReentrant {
        LibBuildingsStorage.BuildingsStorage storage bs = LibBuildingsStorage.buildingsStorage();
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();

        address caller = LibMeta.msgSender();
        bytes32 colonyId = LibColonyWarsStorage.getUserPrimaryColony(caller);
        require(colonyId != bytes32(0), "No colony");

        // Validate
        (bool canUpgrade, string memory reason) = LibBuildingsStorage.canUpgradeBuilding(colonyId, buildingType);
        if (!canUpgrade) {
            if (keccak256(bytes(reason)) == keccak256("Building does not exist")) {
                revert BuildingNotFound(colonyId, buildingType);
            } else if (keccak256(bytes(reason)) == keccak256("Building under construction")) {
                revert BuildingUnderConstruction(colonyId, buildingType);
            } else if (keccak256(bytes(reason)) == keccak256("Already at max level")) {
                LibBuildingsStorage.Building storage b = bs.colonyBuildings[colonyId][buildingType];
                revert AlreadyMaxLevel(b.level);
            }
            revert(reason);
        }

        LibBuildingsStorage.Building storage building = bs.colonyBuildings[colonyId][buildingType];
        LibBuildingsStorage.BuildingBlueprint storage blueprint = bs.blueprints[buildingType];

        uint8 currentLevel = building.level;
        uint8 nextLevel = currentLevel + 1;

        // Calculate upgrade cost (increases per level)
        uint256 levelMultiplier = nextLevel;

        // Consume resources
        for (uint8 i = 0; i < 4; i++) {
            uint256 required = blueprint.resourceCosts[i] * levelMultiplier;
            if (required > 0) {
                uint256 available = rs.userResources[caller][i];
                if (available < required) {
                    revert InsufficientResources(i, required, available);
                }
                rs.userResources[caller][i] -= required;
                LibResourceStorage.decrementGlobalSupply(i, required);
            }
        }

        // Consume tokens via LibFeeCollection
        uint256 tokenCost = blueprint.tokenCost * levelMultiplier;
        if (tokenCost > 0) {
            _collectBuildingFee(caller, tokenCost, "building_upgrade");
        }

        // Start upgrade (building remains active during upgrade in this design)
        building.level = nextLevel;
        building.underConstruction = true;
        building.constructionStart = uint32(block.timestamp);
        building.constructionEnd = uint32(block.timestamp + uint256(blueprint.constructionTime) * levelMultiplier);

        bs.totalUpgradesPerformed++;

        emit BuildingUpgradeStarted(colonyId, buildingType, currentLevel, nextLevel, building.constructionEnd);
    }

    /**
     * @notice Pay maintenance for a colony building
     * @param buildingType Type of building (0-7)
     */
    function payBuildingMaintenance(uint8 buildingType) external whenNotPaused nonReentrant {
        LibBuildingsStorage.BuildingsStorage storage bs = LibBuildingsStorage.buildingsStorage();

        address caller = LibMeta.msgSender();
        bytes32 colonyId = LibColonyWarsStorage.getUserPrimaryColony(caller);
        require(colonyId != bytes32(0), "No colony");

        LibBuildingsStorage.Building storage building = bs.colonyBuildings[colonyId][buildingType];

        if (!building.active) {
            revert BuildingNotFound(colonyId, buildingType);
        }

        LibBuildingsStorage.BuildingBlueprint storage blueprint = bs.blueprints[buildingType];

        // Maintenance cost scales with level
        uint256 maintenanceCost = blueprint.maintenanceCost * building.level;

        // Collect maintenance fee via LibFeeCollection
        _collectBuildingFee(caller, maintenanceCost, "building_maintenance");

        // Update maintenance timestamp
        building.lastMaintenancePaid = uint32(block.timestamp);
        bs.totalMaintenancePaid += maintenanceCost;

        uint32 paidUntil = uint32(block.timestamp) + bs.config.maintenancePeriod;

        emit BuildingMaintenancePaid(colonyId, buildingType, maintenanceCost, paidUntil);
    }

    /**
     * @notice Pay maintenance for all buildings in colony
     */
    function payAllBuildingsMaintenance() external whenNotPaused nonReentrant {
        LibBuildingsStorage.BuildingsStorage storage bs = LibBuildingsStorage.buildingsStorage();

        address caller = LibMeta.msgSender();
        bytes32 colonyId = LibColonyWarsStorage.getUserPrimaryColony(caller);
        require(colonyId != bytes32(0), "No colony");

        uint256 totalCost = 0;

        // Calculate total maintenance
        for (uint8 i = 0; i <= LibBuildingsStorage.MAX_BUILDING_TYPE; i++) {
            LibBuildingsStorage.Building storage building = bs.colonyBuildings[colonyId][i];
            if (building.active && !building.underConstruction) {
                LibBuildingsStorage.BuildingBlueprint storage blueprint = bs.blueprints[i];
                totalCost += blueprint.maintenanceCost * building.level;
            }
        }

        if (totalCost == 0) {
            revert NothingToClaim();
        }

        // Collect maintenance fee via LibFeeCollection
        _collectBuildingFee(caller, totalCost, "building_maintenance_all");

        // Update all maintenance timestamps
        for (uint8 i = 0; i <= LibBuildingsStorage.MAX_BUILDING_TYPE; i++) {
            LibBuildingsStorage.Building storage building = bs.colonyBuildings[colonyId][i];
            if (building.active && !building.underConstruction) {
                building.lastMaintenancePaid = uint32(block.timestamp);
            }
        }

        bs.totalMaintenancePaid += totalCost;
    }

    /**
     * @notice Claim passive resources from buildings
     */
    function claimPassiveResources() external whenNotPaused nonReentrant {
        LibBuildingsStorage.BuildingsStorage storage bs = LibBuildingsStorage.buildingsStorage();
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();

        address caller = LibMeta.msgSender();
        bytes32 colonyId = LibColonyWarsStorage.getUserPrimaryColony(caller);
        require(colonyId != bytes32(0), "No colony");

        uint32 lastClaim = bs.lastPassiveClaimTime[colonyId];
        if (lastClaim == 0) {
            lastClaim = uint32(block.timestamp) - 86400; // Default to 1 day if never claimed
        }

        uint32 timePassed = uint32(block.timestamp) - lastClaim;
        if (timePassed < 3600) { // Minimum 1 hour between claims
            revert NothingToClaim();
        }

        // Cap at 7 days of accumulation
        if (timePassed > 604800) {
            timePassed = 604800;
        }

        LibBuildingsStorage.ColonyBuildingEffects memory effects =
            LibBuildingsStorage.getColonyBuildingEffects(colonyId);

        // Calculate passive generation (per day values / 86400 * timePassed)
        uint256 basicAmount = (effects.passiveBasicPerDay * timePassed) / 86400;
        uint256 energyAmount = (effects.passiveEnergyPerDay * timePassed) / 86400;
        uint256 bioAmount = (effects.passiveBioPerDay * timePassed) / 86400;

        if (basicAmount == 0 && energyAmount == 0 && bioAmount == 0) {
            revert NothingToClaim();
        }

        // Check supply caps and add resources
        if (basicAmount > 0 && LibResourceStorage.checkSupplyCap(0, basicAmount)) {
            rs.userResources[caller][0] += basicAmount;
            LibResourceStorage.incrementGlobalSupply(0, basicAmount);
        }

        if (energyAmount > 0 && LibResourceStorage.checkSupplyCap(1, energyAmount)) {
            rs.userResources[caller][1] += energyAmount;
            LibResourceStorage.incrementGlobalSupply(1, energyAmount);
        }

        if (bioAmount > 0 && LibResourceStorage.checkSupplyCap(2, bioAmount)) {
            rs.userResources[caller][2] += bioAmount;
            LibResourceStorage.incrementGlobalSupply(2, bioAmount);
        }

        bs.lastPassiveClaimTime[colonyId] = uint32(block.timestamp);

        emit PassiveResourcesClaimed(colonyId, caller, basicAmount, energyAmount, bioAmount);
    }

    /**
     * @notice Demolish a building (no refund)
     * @param buildingType Type of building to demolish
     */
    function demolishBuilding(uint8 buildingType) external whenNotPaused nonReentrant {
        LibBuildingsStorage.BuildingsStorage storage bs = LibBuildingsStorage.buildingsStorage();

        address caller = LibMeta.msgSender();
        bytes32 colonyId = LibColonyWarsStorage.getUserPrimaryColony(caller);
        require(colonyId != bytes32(0), "No colony");

        LibBuildingsStorage.Building storage building = bs.colonyBuildings[colonyId][buildingType];

        if (!building.active && !building.underConstruction) {
            revert BuildingNotFound(colonyId, buildingType);
        }

        uint8 level = building.level;

        // Reset building
        delete bs.colonyBuildings[colonyId][buildingType];
        bs.colonyBuildingCount[colonyId]--;

        emit BuildingDemolished(colonyId, buildingType, level);
    }

    // ============================================
    // BUILDING CARDS FUNCTIONS
    // ============================================

    /**
     * @notice Attach a building card to enhance a colony building
     * @param tokenId Building card token ID
     * @param buildingType Type of building to attach to
     * @param rarityBonusBps Rarity bonus in basis points (from card traits)
     */
    function attachBuildingCard(
        uint256 tokenId,
        uint8 buildingType,
        uint16 rarityBonusBps
    ) external whenNotPaused nonReentrant {
        LibBuildingsStorage.BuildingsStorage storage bs = LibBuildingsStorage.buildingsStorage();

        if (!bs.cardModeEnabled) revert CardModeDisabled();
        if (bs.buildingCardsContract == address(0)) revert BuildingCardsContractNotSet();
        if (buildingType > LibBuildingsStorage.MAX_BUILDING_TYPE) {
            revert InvalidBuildingType(buildingType);
        }

        address caller = LibMeta.msgSender();
        bytes32 colonyId = LibColonyWarsStorage.getUserPrimaryColony(caller);
        require(colonyId != bytes32(0), "No colony");

        // Verify caller owns the card
        IERC721 buildingCards = IERC721(bs.buildingCardsContract);
        if (buildingCards.ownerOf(tokenId) != caller) {
            revert NotCardOwner(tokenId);
        }

        // Check card is not already attached somewhere
        if (bs.cardToColony[tokenId] != bytes32(0)) {
            revert CardAlreadyAttached(tokenId);
        }

        // Building must exist and be active
        LibBuildingsStorage.Building storage building = bs.colonyBuildings[colonyId][buildingType];
        if (!building.active) {
            revert BuildingNotFound(colonyId, buildingType);
        }

        // Attach the card
        LibBuildingsStorage.attachBuildingCard(colonyId, buildingType, tokenId, rarityBonusBps);

        emit BuildingCardAttached(colonyId, buildingType, tokenId, caller, rarityBonusBps);
    }

    /**
     * @notice Detach a building card from a colony building
     * @param buildingType Type of building to detach from
     */
    function detachBuildingCard(uint8 buildingType) external whenNotPaused nonReentrant {
        if (buildingType > LibBuildingsStorage.MAX_BUILDING_TYPE) {
            revert InvalidBuildingType(buildingType);
        }

        address caller = LibMeta.msgSender();
        bytes32 colonyId = LibColonyWarsStorage.getUserPrimaryColony(caller);
        require(colonyId != bytes32(0), "No colony");

        // Check card is attached
        uint256 tokenId = LibBuildingsStorage.getAttachedCard(colonyId, buildingType);
        if (tokenId == 0) {
            revert CardNotAttached(colonyId, buildingType);
        }

        // Detach the card
        LibBuildingsStorage.detachBuildingCard(colonyId, buildingType);

        emit BuildingCardDetached(colonyId, buildingType, tokenId, caller);
    }

    /**
     * @notice Get attached building card info
     * @param colonyId Colony identifier
     * @param buildingType Building type
     * @return tokenId Attached card token ID (0 if none)
     * @return rarityBonusBps Rarity bonus in basis points
     */
    function getAttachedBuildingCard(
        bytes32 colonyId,
        uint8 buildingType
    ) external view returns (uint256 tokenId, uint16 rarityBonusBps) {
        tokenId = LibBuildingsStorage.getAttachedCard(colonyId, buildingType);
        rarityBonusBps = LibBuildingsStorage.getCardRarityBonus(colonyId, buildingType);
        return (tokenId, rarityBonusBps);
    }

    /**
     * @notice Get colony building effects including card bonuses
     * @param colonyId Colony identifier
     * @return effects Building effects with card bonuses applied
     */
    function getColonyBuildingEffectsWithCards(bytes32 colonyId) external view returns (
        LibBuildingsStorage.ColonyBuildingEffects memory effects
    ) {
        return LibBuildingsStorage.getColonyBuildingEffectsWithCards(colonyId);
    }

    // ============================================
    // ADMIN FUNCTIONS
    // ============================================

    /**
     * @notice Initialize buildings system
     */
    function initializeBuildingsSystem() external onlyAuthorized {
        LibBuildingsStorage.initializeDefaultBlueprints();
    }

    /**
     * @notice Enable/disable buildings system
     */
    function setBuildingsSystemEnabled(bool enabled) external onlyAuthorized {
        LibBuildingsStorage.BuildingsStorage storage bs = LibBuildingsStorage.buildingsStorage();
        bs.config.systemEnabled = enabled;
        emit BuildingsSystemToggled(enabled);
    }

    /**
     * @notice Set building cards contract address
     * @param buildingCardsContract Address of ColonyBuildingCards contract
     */
    function setBuildingCardsContract(address buildingCardsContract) external onlyAuthorized {
        LibBuildingsStorage.BuildingsStorage storage bs = LibBuildingsStorage.buildingsStorage();

        address oldAddress = bs.buildingCardsContract;
        bs.buildingCardsContract = buildingCardsContract;

        emit BuildingCardsContractUpdated(oldAddress, buildingCardsContract);
    }

    /**
     * @notice Enable/disable card mode
     * @param enabled Whether card attachment is enabled
     */
    function setCardModeEnabled(bool enabled) external onlyAuthorized {
        LibBuildingsStorage.BuildingsStorage storage bs = LibBuildingsStorage.buildingsStorage();
        bs.cardModeEnabled = enabled;
    }

    /**
     * @notice Configure buildings system
     */
    function setBuildingsConfig(
        uint8 maxBuildingsPerColony,
        uint32 maintenancePeriod,
        uint16 maintenancePenaltyBps,
        address utilityToken,
        address beneficiary
    ) external onlyAuthorized {
        LibBuildingsStorage.BuildingsStorage storage bs = LibBuildingsStorage.buildingsStorage();

        bs.config.maxBuildingsPerColony = maxBuildingsPerColony;
        bs.config.maintenancePeriod = maintenancePeriod;
        bs.config.maintenancePenaltyBps = maintenancePenaltyBps;
        bs.config.utilityToken = utilityToken;
        bs.config.beneficiary = beneficiary;
    }

    /**
     * @notice Update building blueprint
     */
    function setBuildingBlueprint(
        uint8 buildingType,
        uint256[4] calldata resourceCosts,
        uint256 tokenCost,
        uint32 constructionTime,
        uint16[5] calldata effectValues,
        uint256 maintenanceCost,
        bool enabled
    ) external onlyAuthorized {
        require(buildingType <= LibBuildingsStorage.MAX_BUILDING_TYPE, "Invalid building type");

        LibBuildingsStorage.BuildingsStorage storage bs = LibBuildingsStorage.buildingsStorage();

        bs.blueprints[buildingType] = LibBuildingsStorage.BuildingBlueprint({
            resourceCosts: resourceCosts,
            tokenCost: tokenCost,
            constructionTime: constructionTime,
            effectValues: effectValues,
            maintenanceCost: maintenanceCost,
            enabled: enabled
        });
    }

    // ============================================
    // MULTI-SYSTEM CARD ADMIN FUNCTIONS
    // ============================================

    /**
     * @notice Initialize the multi-system card system with defaults
     */
    function initializeCardSystem() external onlyAuthorized {
        LibBuildingsStorage.initializeCardSystemDefaults();
        LibBuildingsStorage.initializeMultiSystemCardDefaults();
        emit CardSystemInitialized();
    }

    /**
     * @notice Initialize multi-system card support (Buildings, Evolution, Venture)
     * @dev Single call to configure all card system parameters
     */
    function initializeMultiSystemCards(
        // Card system config
        bool systemEnabled,
        uint32 attachCooldownSeconds,
        uint32 detachCooldownSeconds,
        uint16 maxBonusCapBps,
        uint8 maxCardsPerColony,
        // Rarity bonuses [common, uncommon, rare, epic, legendary, mythic]
        uint16[6] calldata rarityBonuses,
        // Multi-system config
        uint8 maxCardsPerSpecimen,
        uint8 maxCardsPerVentureSlot
    ) external onlyAuthorized {
        LibBuildingsStorage.BuildingsStorage storage bs = LibBuildingsStorage.buildingsStorage();

        // Set card system config
        bs.cardConfig = LibBuildingsStorage.CardSystemConfig({
            systemEnabled: systemEnabled,
            attachCooldownSeconds: attachCooldownSeconds,
            detachCooldownSeconds: detachCooldownSeconds,
            maxBonusCapBps: maxBonusCapBps,
            maxCardsPerColony: maxCardsPerColony,
            requireOwnership: true,
            verifierContract: address(0)
        });

        // Set rarity bonuses
        bs.rarityBonuses = LibBuildingsStorage.RarityBonusConfig({
            commonBonusBps: rarityBonuses[0],
            uncommonBonusBps: rarityBonuses[1],
            rareBonusBps: rarityBonuses[2],
            epicBonusBps: rarityBonuses[3],
            legendaryBonusBps: rarityBonuses[4],
            mythicBonusBps: rarityBonuses[5]
        });

        // Set multi-system config
        bs.maxCardsPerSpecimen = maxCardsPerSpecimen;
        bs.maxCardsPerVentureSlot = maxCardsPerVentureSlot;

        emit CardSystemInitialized();
        emit CardSystemConfigUpdated();
        emit RarityBonusConfigUpdated();
        emit MultiSystemCardConfigUpdated(maxCardsPerSpecimen, maxCardsPerVentureSlot);
    }

    /**
     * @notice Configure card system settings
     */
    function setCardSystemConfig(
        bool systemEnabled,
        uint32 attachCooldownSeconds,
        uint32 detachCooldownSeconds,
        uint16 maxBonusCapBps,
        uint8 maxCardsPerColony,
        bool requireOwnership,
        address verifierContract
    ) external onlyAuthorized {
        LibBuildingsStorage.BuildingsStorage storage bs = LibBuildingsStorage.buildingsStorage();

        bs.cardConfig = LibBuildingsStorage.CardSystemConfig({
            systemEnabled: systemEnabled,
            attachCooldownSeconds: attachCooldownSeconds,
            detachCooldownSeconds: detachCooldownSeconds,
            maxBonusCapBps: maxBonusCapBps,
            maxCardsPerColony: maxCardsPerColony,
            requireOwnership: requireOwnership,
            verifierContract: verifierContract
        });

        emit CardSystemConfigUpdated();
    }

    /**
     * @notice Configure rarity bonus values
     */
    function setRarityBonusConfig(
        uint16 commonBonusBps,
        uint16 uncommonBonusBps,
        uint16 rareBonusBps,
        uint16 epicBonusBps,
        uint16 legendaryBonusBps,
        uint16 mythicBonusBps
    ) external onlyAuthorized {
        LibBuildingsStorage.BuildingsStorage storage bs = LibBuildingsStorage.buildingsStorage();

        bs.rarityBonuses = LibBuildingsStorage.RarityBonusConfig({
            commonBonusBps: commonBonusBps,
            uncommonBonusBps: uncommonBonusBps,
            rareBonusBps: rareBonusBps,
            epicBonusBps: epicBonusBps,
            legendaryBonusBps: legendaryBonusBps,
            mythicBonusBps: mythicBonusBps
        });

        emit RarityBonusConfigUpdated();
    }

    /**
     * @notice Register a new card collection
     * @return collectionId The assigned collection ID
     */
    function registerCardCollection(
        address contractAddress,
        string calldata name,
        bool enabled,
        bool requiresVerification,
        uint16 collectionBonusBps
    ) external onlyAuthorized returns (uint16 collectionId) {
        require(contractAddress != address(0), "Invalid contract address");

        LibBuildingsStorage.BuildingsStorage storage bs = LibBuildingsStorage.buildingsStorage();

        collectionId = bs.cardCollectionCounter;
        bs.cardCollectionCounter++;

        bs.cardCollections[collectionId] = LibBuildingsStorage.CardCollection({
            contractAddress: contractAddress,
            name: name,
            enabled: enabled,
            requiresVerification: requiresVerification,
            collectionBonusBps: collectionBonusBps,
            registeredAt: uint32(block.timestamp)
        });

        emit CardCollectionRegistered(collectionId, contractAddress, name);
        return collectionId;
    }

    /**
     * @notice Enable/disable a card collection
     */
    function setCardCollectionEnabled(uint16 collectionId, bool enabled) external onlyAuthorized {
        LibBuildingsStorage.BuildingsStorage storage bs = LibBuildingsStorage.buildingsStorage();
        require(collectionId < bs.cardCollectionCounter, "Invalid collection ID");

        bs.cardCollections[collectionId].enabled = enabled;
        emit CardCollectionToggled(collectionId, enabled);
    }

    /**
     * @notice Register a new card type
     * @return typeId The assigned type ID
     */
    function registerCardType(
        string calldata name,
        uint8 compatibleBuildingType,
        uint8 minRarity,
        uint16 baseBonusBps,
        uint16 rarityScalingBps,
        bool stackable,
        bool enabled,
        uint8 system,
        uint8 evolutionTierBonus,
        uint16 ventureSuccessBoostBps
    ) external onlyAuthorized returns (uint8 typeId) {
        require(system <= 3, "Invalid system type"); // 0-3 are valid
        require(minRarity <= 5, "Invalid min rarity"); // 0-5 are valid

        LibBuildingsStorage.BuildingsStorage storage bs = LibBuildingsStorage.buildingsStorage();

        typeId = bs.cardTypeCounter;
        bs.cardTypeCounter++;

        bs.cardTypes[typeId] = LibBuildingsStorage.CardTypeDefinition({
            name: name,
            compatibleBuildingType: compatibleBuildingType,
            minRarity: LibBuildingsStorage.CardRarity(minRarity),
            baseBonusBps: baseBonusBps,
            rarityScalingBps: rarityScalingBps,
            stackable: stackable,
            enabled: enabled,
            system: LibBuildingsStorage.CardCompatibleSystem(system),
            evolutionTierBonus: evolutionTierBonus,
            ventureSuccessBoostBps: ventureSuccessBoostBps
        });

        emit CardTypeRegistered(typeId, name, system);
        return typeId;
    }

    /**
     * @notice Enable/disable a card type
     */
    function setCardTypeEnabled(uint8 typeId, bool enabled) external onlyAuthorized {
        LibBuildingsStorage.BuildingsStorage storage bs = LibBuildingsStorage.buildingsStorage();
        require(typeId < bs.cardTypeCounter, "Invalid type ID");

        bs.cardTypes[typeId].enabled = enabled;
        emit CardTypeToggled(typeId, enabled);
    }

    /**
     * @notice Batch register multiple card types in one transaction
     * @dev More gas efficient for initial setup
     * @param names Array of card type names
     * @param configs Array of [compatibleBuildingType, minRarity, system, evolutionTierBonus]
     * @param bonuses Array of [baseBonusBps, rarityScalingBps, ventureSuccessBoostBps]
     */
    function batchRegisterCardTypes(
        string[] calldata names,
        uint8[4][] calldata configs,
        uint16[3][] calldata bonuses
    ) external onlyAuthorized {
        require(names.length == configs.length && names.length == bonuses.length, "Array length mismatch");
        require(names.length <= 20, "Max 20 types per batch");

        LibBuildingsStorage.BuildingsStorage storage bs = LibBuildingsStorage.buildingsStorage();

        for (uint256 i = 0; i < names.length; i++) {
            uint8 typeId = bs.cardTypeCounter;
            bs.cardTypeCounter++;

            bs.cardTypes[typeId] = LibBuildingsStorage.CardTypeDefinition({
                name: names[i],
                compatibleBuildingType: configs[i][0],
                minRarity: LibBuildingsStorage.CardRarity(configs[i][1]),
                baseBonusBps: bonuses[i][0],
                rarityScalingBps: bonuses[i][1],
                stackable: false,
                enabled: true,
                system: LibBuildingsStorage.CardCompatibleSystem(configs[i][2]),
                evolutionTierBonus: configs[i][3],
                ventureSuccessBoostBps: bonuses[i][2]
            });

            emit CardTypeRegistered(typeId, names[i], configs[i][2]);
        }
    }

    /**
     * @notice Configure multi-system card limits
     */
    function setMultiSystemCardConfig(
        uint8 maxCardsPerSpecimen,
        uint8 maxCardsPerVentureSlot
    ) external onlyAuthorized {
        LibBuildingsStorage.BuildingsStorage storage bs = LibBuildingsStorage.buildingsStorage();

        bs.maxCardsPerSpecimen = maxCardsPerSpecimen;
        bs.maxCardsPerVentureSlot = maxCardsPerVentureSlot;

        emit MultiSystemCardConfigUpdated(maxCardsPerSpecimen, maxCardsPerVentureSlot);
    }

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    /**
     * @notice Get building status
     */
    function getBuilding(
        bytes32 colonyId,
        uint8 buildingType
    ) external view returns (
        uint8 level,
        bool active,
        bool underConstruction,
        uint32 constructionEnd,
        uint32 lastMaintenancePaid,
        uint16 effectivenessMultiplier
    ) {
        LibBuildingsStorage.BuildingsStorage storage bs = LibBuildingsStorage.buildingsStorage();
        LibBuildingsStorage.Building storage building = bs.colonyBuildings[colonyId][buildingType];

        uint16 multiplier = 10000;
        if (building.active) {
            multiplier = LibBuildingsStorage.getMaintenanceMultiplier(building, bs.config);
        }

        return (
            building.level,
            building.active,
            building.underConstruction,
            building.constructionEnd,
            building.lastMaintenancePaid,
            multiplier
        );
    }

    /**
     * @notice Get all buildings for a colony
     */
    function getColonyBuildings(bytes32 colonyId) external view returns (
        uint8[8] memory levels,
        bool[8] memory active,
        bool[8] memory underConstruction
    ) {
        LibBuildingsStorage.BuildingsStorage storage bs = LibBuildingsStorage.buildingsStorage();

        for (uint8 i = 0; i <= LibBuildingsStorage.MAX_BUILDING_TYPE; i++) {
            LibBuildingsStorage.Building storage building = bs.colonyBuildings[colonyId][i];
            levels[i] = building.level;
            active[i] = building.active;
            underConstruction[i] = building.underConstruction;
        }

        return (levels, active, underConstruction);
    }

    /**
     * @notice Get colony building effects
     */
    function getColonyBuildingEffects(bytes32 colonyId) external view returns (
        LibBuildingsStorage.ColonyBuildingEffects memory effects
    ) {
        return LibBuildingsStorage.getColonyBuildingEffects(colonyId);
    }

    /**
     * @notice Get building blueprint
     */
    function getBuildingBlueprint(uint8 buildingType) external view returns (
        uint256[4] memory resourceCosts,
        uint256 tokenCost,
        uint32 constructionTime,
        uint16[5] memory effectValues,
        uint256 maintenanceCost,
        bool enabled
    ) {
        LibBuildingsStorage.BuildingsStorage storage bs = LibBuildingsStorage.buildingsStorage();
        LibBuildingsStorage.BuildingBlueprint storage blueprint = bs.blueprints[buildingType];

        return (
            blueprint.resourceCosts,
            blueprint.tokenCost,
            blueprint.constructionTime,
            blueprint.effectValues,
            blueprint.maintenanceCost,
            blueprint.enabled
        );
    }

    /**
     * @notice Get pending passive resources
     */
    function getPendingPassiveResources(bytes32 colonyId) external view returns (
        uint256 basicMaterials,
        uint256 energyCrystals,
        uint256 bioCompounds
    ) {
        LibBuildingsStorage.BuildingsStorage storage bs = LibBuildingsStorage.buildingsStorage();

        uint32 lastClaim = bs.lastPassiveClaimTime[colonyId];
        if (lastClaim == 0) {
            lastClaim = uint32(block.timestamp) - 86400;
        }

        uint32 timePassed = uint32(block.timestamp) - lastClaim;
        if (timePassed > 604800) {
            timePassed = 604800; // Cap at 7 days
        }

        LibBuildingsStorage.ColonyBuildingEffects memory effects =
            LibBuildingsStorage.getColonyBuildingEffects(colonyId);

        basicMaterials = (effects.passiveBasicPerDay * timePassed) / 86400;
        energyCrystals = (effects.passiveEnergyPerDay * timePassed) / 86400;
        bioCompounds = (effects.passiveBioPerDay * timePassed) / 86400;

        return (basicMaterials, energyCrystals, bioCompounds);
    }

    /**
     * @notice Get construction cost for building
     */
    function getConstructionCost(uint8 buildingType, uint8 level) external view returns (
        uint256[4] memory resourceCosts,
        uint256 tokenCost
    ) {
        LibBuildingsStorage.BuildingsStorage storage bs = LibBuildingsStorage.buildingsStorage();
        LibBuildingsStorage.BuildingBlueprint storage blueprint = bs.blueprints[buildingType];

        uint256 multiplier = level == 0 ? 1 : level;

        for (uint8 i = 0; i < 4; i++) {
            resourceCosts[i] = blueprint.resourceCosts[i] * multiplier;
        }
        tokenCost = blueprint.tokenCost * multiplier;

        return (resourceCosts, tokenCost);
    }

    /**
     * @notice Get buildings system statistics
     */
    function getBuildingsStats() external view returns (
        uint256 totalBuilt,
        uint256 totalUpgrades,
        uint256 totalMaintenance,
        bool systemEnabled
    ) {
        LibBuildingsStorage.BuildingsStorage storage bs = LibBuildingsStorage.buildingsStorage();

        return (
            bs.totalBuildingsConstructed,
            bs.totalUpgradesPerformed,
            bs.totalMaintenancePaid,
            bs.config.systemEnabled
        );
    }

    // ============================================
    // CARD SYSTEM VIEW FUNCTIONS
    // ============================================

    /**
     * @notice Get card system configuration
     */
    function getCardSystemConfig() external view returns (
        bool systemEnabled,
        uint32 attachCooldownSeconds,
        uint32 detachCooldownSeconds,
        uint16 maxBonusCapBps,
        uint8 maxCardsPerColony,
        bool requireOwnership
    ) {
        LibBuildingsStorage.BuildingsStorage storage bs = LibBuildingsStorage.buildingsStorage();

        return (
            bs.cardConfig.systemEnabled,
            bs.cardConfig.attachCooldownSeconds,
            bs.cardConfig.detachCooldownSeconds,
            bs.cardConfig.maxBonusCapBps,
            bs.cardConfig.maxCardsPerColony,
            bs.cardConfig.requireOwnership
        );
    }

    /**
     * @notice Get rarity bonus configuration
     */
    function getRarityBonusConfig() external view returns (
        uint16 commonBonusBps,
        uint16 uncommonBonusBps,
        uint16 rareBonusBps,
        uint16 epicBonusBps,
        uint16 legendaryBonusBps,
        uint16 mythicBonusBps
    ) {
        LibBuildingsStorage.RarityBonusConfig memory config = LibBuildingsStorage.getRarityBonusConfig();

        return (
            config.commonBonusBps,
            config.uncommonBonusBps,
            config.rareBonusBps,
            config.epicBonusBps,
            config.legendaryBonusBps,
            config.mythicBonusBps
        );
    }

    /**
     * @notice Get card collection details
     */
    function getCardCollection(uint16 collectionId) external view returns (
        address contractAddress,
        string memory name,
        bool enabled,
        bool requiresVerification,
        uint16 collectionBonusBps,
        uint32 registeredAt
    ) {
        LibBuildingsStorage.BuildingsStorage storage bs = LibBuildingsStorage.buildingsStorage();
        LibBuildingsStorage.CardCollection storage coll = bs.cardCollections[collectionId];

        return (
            coll.contractAddress,
            coll.name,
            coll.enabled,
            coll.requiresVerification,
            coll.collectionBonusBps,
            coll.registeredAt
        );
    }

    /**
     * @notice Get card type details
     */
    function getCardType(uint8 typeId) external view returns (
        string memory name,
        uint8 compatibleBuildingType,
        uint8 minRarity,
        uint16 baseBonusBps,
        uint16 rarityScalingBps,
        bool stackable,
        bool enabled,
        uint8 system,
        uint8 evolutionTierBonus,
        uint16 ventureSuccessBoostBps
    ) {
        LibBuildingsStorage.BuildingsStorage storage bs = LibBuildingsStorage.buildingsStorage();
        LibBuildingsStorage.CardTypeDefinition storage cardType = bs.cardTypes[typeId];

        return (
            cardType.name,
            cardType.compatibleBuildingType,
            uint8(cardType.minRarity),
            cardType.baseBonusBps,
            cardType.rarityScalingBps,
            cardType.stackable,
            cardType.enabled,
            uint8(cardType.system),
            cardType.evolutionTierBonus,
            cardType.ventureSuccessBoostBps
        );
    }

    /**
     * @notice Get card collection count
     */
    function getCardCollectionCount() external view returns (uint16) {
        LibBuildingsStorage.BuildingsStorage storage bs = LibBuildingsStorage.buildingsStorage();
        return bs.cardCollectionCounter;
    }

    /**
     * @notice Get card type count
     */
    function getCardTypeCount() external view returns (uint8) {
        LibBuildingsStorage.BuildingsStorage storage bs = LibBuildingsStorage.buildingsStorage();
        return bs.cardTypeCounter;
    }

    /**
     * @notice Get multi-system card statistics
     */
    function getCardSystemStats() external view returns (
        uint256 totalCardsAttached,
        uint256 totalCardDetachments,
        uint256 totalSpecimenCardsAttached,
        uint256 totalVentureCardsAttached
    ) {
        LibBuildingsStorage.BuildingsStorage storage bs = LibBuildingsStorage.buildingsStorage();

        return (
            bs.totalCardsAttached,
            bs.totalCardDetachments,
            bs.totalSpecimenCardsAttached,
            bs.totalVentureCardsAttached
        );
    }

    // ============================================
    // INTERNAL HELPER FUNCTIONS
    // ============================================

    /**
     * @notice Collect building fee using LibFeeCollection
     * @dev Supports both transfer and burn modes based on config
     * @param payer Address paying the fee
     * @param amount Fee amount
     * @param operation Operation identifier for events
     */
    function _collectBuildingFee(address payer, uint256 amount, string memory operation) internal {
        if (amount == 0) return;

        LibBuildingsStorage.BuildingsStorage storage bs = LibBuildingsStorage.buildingsStorage();

        // Validate balance first
        IERC20 token = IERC20(bs.config.utilityToken);
        uint256 balance = token.balanceOf(payer);
        if (balance < amount) {
            revert InsufficientTokens(amount, balance);
        }

        // Use LibFeeCollection for consistent fee handling
        if (bs.config.burnOnCollect) {
            // Burn tokens (YLW deflationary mechanism)
            LibFeeCollection.collectAndBurnFee(
                token,
                payer,
                bs.config.beneficiary,
                amount,
                operation
            );
        } else {
            // Transfer to beneficiary
            LibFeeCollection.collectFee(
                token,
                payer,
                bs.config.beneficiary,
                amount,
                operation
            );
        }
    }
}
