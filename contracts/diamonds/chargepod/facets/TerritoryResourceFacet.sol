// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibMeta} from "../../shared/libraries/LibMeta.sol";
import {LibResourceStorage} from "../libraries/LibResourceStorage.sol";
import {LibColonyWarsStorage} from "../libraries/LibColonyWarsStorage.sol";
import {AccessControlBase} from "./AccessControlBase.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LibFeeCollection} from "../libraries/LibFeeCollection.sol";
import {IResourcePodFacet} from "../interfaces/IStakingInterfaces.sol";
import {IColonyResourceCards} from "../interfaces/IColonyResourceCards.sol";
import {IColonyTerritoryCards} from "../interfaces/IColonyTerritoryCards.sol";

/**
 * @title TerritoryResourceFacet
 * @notice Integrates resource system with territory control
 * @dev Uses LibColonyWarsStorage.territoryResourceNodes mapping for safe Diamond storage
 * NOTE: This facet uses territoryResourceNodes (keyed by territoryId), separate from
 * economyResourceNodes used by ResourceEconomyFacet (keyed by auto-increment nodeId)
 */
contract TerritoryResourceFacet is AccessControlBase {

    // ==================== EVENTS ====================

    event ResourceNodePlaced(uint256 indexed territoryId, bytes32 indexed colonyId, uint8 resourceType, uint8 nodeLevel);
    event ResourceNodeUpgraded(uint256 indexed territoryId, uint8 oldLevel, uint8 newLevel);
    event ResourceNodeHarvested(uint256 indexed territoryId, bytes32 indexed colonyId, uint8 resourceType, uint256 amount);
    event MaintenancePaid(uint256 indexed territoryId, address indexed payer, uint256 amount, uint32 paidUntil);
    event ResourceCardEquipped(uint256 indexed territoryId, uint256 indexed cardTokenId, address indexed owner);
    event ResourceCardUnequipped(uint256 indexed territoryId, uint256 indexed cardTokenId, address indexed owner);

    // ==================== ERRORS ====================

    error TerritoryNotControlled(uint256 territoryId, bytes32 colonyId);
    error ResourceNodeAlreadyExists(uint256 territoryId);
    error ResourceNodeNotFound(uint256 territoryId);
    error InvalidNodeLevel(uint8 level);
    error InsufficientResourcesForUpgrade(uint8 resourceType, uint256 required, uint256 available);
    error HarvestCooldownActive(uint256 territoryId, uint32 remainingTime);
    error InvalidTerritoryForResourceType(uint256 territoryId, uint8 resourceType);
    error InsufficientPermissions(address user);
    error MaintenanceOverdue(uint256 territoryId, uint32 overdueTime);
    error MaxResourceCardsPerNodeReached(uint256 territoryId);
    error ResourceCardNotOwned(uint256 cardTokenId);
    error ResourceCardAlreadyEquipped(uint256 cardTokenId);
    error ResourceCardNotEquippedToNode(uint256 cardTokenId, uint256 territoryId);
    error ResourceTypeMismatch(uint256 cardTokenId, uint8 nodeType, uint8 cardType);
    error ResourceCardsContractNotSet();

    // ==================== CONSTANTS ====================

    uint32 constant MAINTENANCE_PERIOD = 7 days;  // Maintenance must be paid every 7 days
    uint256 constant BASE_MAINTENANCE_COST = 10 ether;  // 10 YLW per level per period
    uint8 constant MAX_RESOURCE_CARDS_PER_NODE = 3;  // Max resource cards per node
    
    // ==================== RESOURCE NODE MANAGEMENT ====================

    /**
     * @notice Place resource node on controlled territory
     * @param territoryId Territory to place node on
     * @param resourceType Type of resource node (0-3)
     */
    function placeResourceNode(
        uint256 territoryId,
        uint8 resourceType
    ) external whenNotPaused {
        bytes32 colonyId = _getCallerColonyId();
        _requireTerritoryControl(territoryId, colonyId);

        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();

        // Check if node already exists (use territoryId as nodeId)
        if (cws.territoryResourceNodes[territoryId].active) {
            revert ResourceNodeAlreadyExists(territoryId);
        }

        // Validate resource type matches territory type
        LibColonyWarsStorage.Territory storage territory = cws.territories[territoryId];
        if (!_isValidResourceTypeForTerritory(territory.territoryType, resourceType)) {
            revert InvalidTerritoryForResourceType(territoryId, resourceType);
        }

        // Cost: governance token only (resources earned from harvesting, not required to start)
        uint256 placementCost = _calculateNodePlacementCost(1);
        _chargeGovernanceToken(placementCost);

        // Create node using LibColonyWarsStorage.ResourceNode
        cws.territoryResourceNodes[territoryId] = LibColonyWarsStorage.ResourceNode({
            territoryId: territoryId,
            resourceType: LibColonyWarsStorage.ResourceType(resourceType),
            nodeLevel: 1,
            accumulatedResources: 0,
            lastHarvestTime: uint32(block.timestamp),
            lastMaintenancePaid: uint32(block.timestamp),
            active: true
        });

        emit ResourceNodePlaced(territoryId, colonyId, resourceType, 1);
    }

    /**
     * @notice Upgrade existing resource node
     * @param territoryId Territory with node to upgrade
     */
    function upgradeResourceNode(uint256 territoryId) external whenNotPaused {
        bytes32 colonyId = _getCallerColonyId();
        _requireTerritoryControl(territoryId, colonyId);

        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibColonyWarsStorage.ResourceNode storage node = cws.territoryResourceNodes[territoryId];

        if (!node.active) revert ResourceNodeNotFound(territoryId);
        if (node.nodeLevel >= 10) revert InvalidNodeLevel(node.nodeLevel);

        uint8 newLevel = node.nodeLevel + 1;
        uint256 upgradeCost = _calculateNodePlacementCost(newLevel);
        uint256 resourceCost = 100 * newLevel;

        _chargeGovernanceToken(upgradeCost);
        address sender = LibMeta.msgSender();
        _consumeResources(sender, uint8(node.resourceType), resourceCost);

        uint8 oldLevel = node.nodeLevel;
        node.nodeLevel = newLevel;

        emit ResourceNodeUpgraded(territoryId, oldLevel, newLevel);
    }

    /**
     * @notice Pay maintenance for resource node (YLW)
     * @param territoryId Territory with node to maintain
     */
    function maintainTerritoryNode(uint256 territoryId) external whenNotPaused {
        bytes32 colonyId = _getCallerColonyId();
        _requireTerritoryControl(territoryId, colonyId);

        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibColonyWarsStorage.ResourceNode storage node = cws.territoryResourceNodes[territoryId];

        if (!node.active) revert ResourceNodeNotFound(territoryId);

        // Calculate maintenance cost based on node level
        uint256 maintenanceCost = BASE_MAINTENANCE_COST * node.nodeLevel;

        // Charge YLW (utility token)
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        address sender = LibMeta.msgSender();

        LibFeeCollection.collectFee(
            IERC20(rs.config.utilityToken),
            sender,
            rs.config.paymentBeneficiary,
            maintenanceCost,
            "nodeMaintenanceFee"
        );

        // Update maintenance timestamp
        uint32 currentTime = uint32(block.timestamp);
        node.lastMaintenancePaid = currentTime;

        emit MaintenancePaid(territoryId, sender, maintenanceCost, currentTime + MAINTENANCE_PERIOD);
    }

    /**
     * @notice Harvest resources from territory node
     * @param territoryId Territory to harvest from
     */
    function harvestResourceNode(uint256 territoryId) external whenNotPaused returns (uint256 harvestedAmount) {
        bytes32 colonyId = _getCallerColonyId();
        _requireTerritoryControl(territoryId, colonyId);

        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibColonyWarsStorage.ResourceNode storage node = cws.territoryResourceNodes[territoryId];

        if (!node.active) revert ResourceNodeNotFound(territoryId);

        // Check cooldown (24h)
        uint32 currentTime = uint32(block.timestamp);
        uint32 cooldown = 86400; // 24 hours
        if (currentTime < node.lastHarvestTime + cooldown) {
            uint32 remaining = (node.lastHarvestTime + cooldown) - currentTime;
            revert HarvestCooldownActive(territoryId, remaining);
        }

        // Calculate production with bonuses
        harvestedAmount = _calculateHarvestAmount(colonyId, node);

        // Apply maintenance penalty if overdue (50% reduction per week overdue, min 10%)
        if (currentTime > node.lastMaintenancePaid + MAINTENANCE_PERIOD) {
            uint32 overdueTime = currentTime - (node.lastMaintenancePaid + MAINTENANCE_PERIOD);
            uint256 weeksOverdue = overdueTime / MAINTENANCE_PERIOD;
            uint256 penaltyPercent = 50 * (weeksOverdue + 1); // 50%, 100%, 150%...
            if (penaltyPercent > 90) penaltyPercent = 90; // Cap at 90% penalty (10% yield)
            harvestedAmount = harvestedAmount * (100 - penaltyPercent) / 100;
        }

        // Update harvest timestamp
        node.lastHarvestTime = currentTime;

        // Award resources to harvester
        address sender = LibMeta.msgSender();
        _awardResources(sender, uint8(node.resourceType), harvestedAmount);

        emit ResourceNodeHarvested(territoryId, colonyId, uint8(node.resourceType), harvestedAmount);
    }
    
    // ==================== VIEW FUNCTIONS ====================

    /**
     * @notice Get production bonus from controlled territories
     * @param colonyId Colony ID
     * @param resourceType Resource type
     * @param territoryId Territory ID (for card bonus calculation)
     * @return bonusPercent Bonus percentage (100 = no bonus, 150 = 50% bonus)
     */
    function getTerritoryProductionBonus(
        bytes32 colonyId,
        uint8 resourceType,
        uint256 territoryId
    ) external view returns (uint16 bonusPercent) {
        return _calculateTerritoryBonus(colonyId, resourceType, territoryId);
    }

    /**
     * @notice Get node maintenance status
     * @param territoryId Territory to check
     * @return maintenanceDue When maintenance is due (timestamp)
     * @return isOverdue Whether maintenance is overdue
     * @return maintenanceCost Cost to pay maintenance (YLW)
     * @return currentPenalty Current harvest penalty percent (0-90)
     */
    function getNodeMaintenanceStatus(uint256 territoryId) external view returns (
        uint32 maintenanceDue,
        bool isOverdue,
        uint256 maintenanceCost,
        uint256 currentPenalty
    ) {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibColonyWarsStorage.ResourceNode storage node = cws.territoryResourceNodes[territoryId];

        if (!node.active) revert ResourceNodeNotFound(territoryId);

        maintenanceDue = node.lastMaintenancePaid + MAINTENANCE_PERIOD;
        uint32 currentTime = uint32(block.timestamp);
        isOverdue = currentTime > maintenanceDue;
        maintenanceCost = BASE_MAINTENANCE_COST * node.nodeLevel;

        if (isOverdue) {
            uint32 overdueTime = currentTime - maintenanceDue;
            uint256 weeksOverdue = overdueTime / MAINTENANCE_PERIOD;
            currentPenalty = 50 * (weeksOverdue + 1);
            if (currentPenalty > 90) currentPenalty = 90;
        } else {
            currentPenalty = 0;
        }
    }

    /**
     * @notice Get all resource nodes for colony's territories
     * @param colonyId Colony ID
     * @return territoryIds Array of territory IDs with nodes
     * @return nodes Array of resource node data
     */
    function getColonyResourceNodes(bytes32 colonyId) external view returns (
        uint256[] memory territoryIds,
        LibColonyWarsStorage.ResourceNode[] memory nodes
    ) {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        uint256[] memory controlled = cws.colonyTerritories[colonyId];

        uint256 count = 0;
        for (uint256 i = 0; i < controlled.length; i++) {
            if (cws.territoryResourceNodes[controlled[i]].active) count++;
        }

        territoryIds = new uint256[](count);
        nodes = new LibColonyWarsStorage.ResourceNode[](count);

        uint256 index = 0;
        for (uint256 i = 0; i < controlled.length; i++) {
            if (cws.territoryResourceNodes[controlled[i]].active) {
                territoryIds[index] = controlled[i];
                nodes[index] = cws.territoryResourceNodes[controlled[i]];
                index++;
            }
        }
    }

    /**
     * @notice Get resource node info for specific territory
     * @param territoryId Territory ID
     */
    function getResourceNodeInfo(uint256 territoryId) external view returns (
        bool exists,
        uint8 resourceType,
        uint8 nodeLevel,
        uint32 lastHarvest,
        uint32 nextHarvestTime,
        uint256 estimatedProduction
    ) {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibColonyWarsStorage.ResourceNode storage node = cws.territoryResourceNodes[territoryId];

        exists = node.active;

        if (exists) {
            resourceType = uint8(node.resourceType);
            nodeLevel = node.nodeLevel;
            lastHarvest = node.lastHarvestTime;
            nextHarvestTime = node.lastHarvestTime + 86400; // 24h cooldown
            estimatedProduction = _calculateBaseProduction(node.nodeLevel);
        }
    }

    // ==================== INTERNAL HELPERS ====================

    function _calculateBaseProduction(uint8 level) private pure returns (uint256) {
        return 100 * level; // Linear scaling
    }

    function _calculateNodePlacementCost(uint8 level) private pure returns (uint256) {
        return 50 ether * level; // governance token cost
    }

    function _calculateHarvestAmount(
        bytes32 colonyId,
        LibColonyWarsStorage.ResourceNode storage node
    ) private view returns (uint256) {
        uint256 baseAmount = _calculateBaseProduction(node.nodeLevel);

        // 1. Apply territory bonus (existing territory.bonusValue + NEW: Territory Card productionBonus)
        uint16 territoryBonus = _calculateTerritoryBonus(colonyId, uint8(node.resourceType), node.territoryId);
        uint256 bonusAmount = (baseAmount * territoryBonus) / 100;

        // 2. Apply colony infrastructure bonus (existing - from built structures)
        uint16 colonyInfraBonus = LibResourceStorage.getInfrastructureBonus(colonyId, 0);
        bonusAmount = (bonusAmount * colonyInfraBonus) / 100;

        // 3. NEW: Apply Infrastructure Card equipment bonus (from TerritoryEquipment)
        uint16 infraCardBonus = _getInfrastructureCardBonus(node.territoryId);
        bonusAmount = (bonusAmount * infraCardBonus) / 100;

        // 4. NEW: Apply Resource Card bonus (from cards staked to this node)
        uint16 resourceCardBonus = _getResourceCardBonus(node.territoryId, uint8(node.resourceType));
        uint256 finalAmount = (bonusAmount * resourceCardBonus) / 100;

        return finalAmount;
    }

    function _calculateTerritoryBonus(
        bytes32 colonyId,
        uint8 resourceType,
        uint256 nodesTerritoryId
    ) private view returns (uint16 bonusPercent) {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        uint256[] memory territories = cws.colonyTerritories[colonyId];

        bonusPercent = 100; // Base 100% (no bonus)

        for (uint256 i = 0; i < territories.length; i++) {
            LibColonyWarsStorage.Territory storage territory = cws.territories[territories[i]];

            if (_isValidResourceTypeForTerritory(territory.territoryType, resourceType)) {
                // Existing: territory.bonusValue
                bonusPercent += territory.bonusValue / 10;

                // NEW: Add Territory Card productionBonus (only for the node's territory)
                if (territories[i] == nodesTerritoryId) {
                    uint256 cardId = cws.territoryToCard[territories[i]];
                    if (cardId != 0 && cws.cardContracts.territoryCards != address(0)) {
                        try IColonyTerritoryCards(cws.cardContracts.territoryCards).getTerritoryTraits(cardId) returns (
                            IColonyTerritoryCards.TerritoryTraits memory traits
                        ) {
                            bonusPercent += traits.productionBonus;
                        } catch {
                            // Card may not exist or contract call failed - continue without bonus
                        }
                    }
                }
            }
        }
    }

    function _isValidResourceTypeForTerritory(
        uint8 territoryType,
        uint8 resourceType
    ) private pure returns (bool) {
        // Territory type 1 (Mining) -> Basic Materials (0)
        // Territory type 2 (Energy) -> Energy Crystals (1)
        // Territory type 3 (Research) -> Bio Compounds (2)
        // Territory type 4 (Production) -> Rare Elements (3)
        // Territory type 5 (Strategic) -> All types
        if (territoryType == 5) return true;
        return territoryType == resourceType + 1;
    }

    function _requireTerritoryControl(uint256 territoryId, bytes32 colonyId) private view {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        if (cws.territories[territoryId].controllingColony != colonyId) {
            revert TerritoryNotControlled(territoryId, colonyId);
        }
    }

    function _getCallerColonyId() private view returns (bytes32) {
        // Use LibColonyWarsStorage directly - simpler approach
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        address user = LibMeta.msgSender();

        bytes32 colonyId = cws.userToColony[user];
        if (colonyId == bytes32(0)) {
            colonyId = cws.userPrimaryColony[user];
        }
        if (colonyId == bytes32(0)) {
            revert InsufficientPermissions(user);
        }
        return colonyId;
    }

    function _chargeGovernanceToken(uint256 amount) private {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();

        LibFeeCollection.collectFee(
            IERC20(rs.config.governanceToken),
            LibMeta.msgSender(),
            rs.config.paymentBeneficiary,
            amount,
            "territory_resource"
        );
    }

    function _consumeResources(address user, uint8 resourceType, uint256 amount) private {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();

        // Apply decay before consuming resources
        LibResourceStorage.applyResourceDecay(user);

        uint256 available = rs.userResources[user][resourceType];
        if (available < amount) {
            revert InsufficientResourcesForUpgrade(resourceType, amount, available);
        }
        rs.userResources[user][resourceType] = available - amount;
    }

    function _awardResources(address user, uint8 resourceType, uint256 amount) private {
        // Delegate to ResourcePodFacet for centralized resource management
        // Includes: decay, event emission, global stats tracking
        try IResourcePodFacet(address(this)).awardResourcesDirect(
            user,
            resourceType,
            amount
        ) {} catch {
            // Fallback to direct storage if ResourcePodFacet call fails
            LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
            LibResourceStorage.applyResourceDecay(user);
            rs.userResources[user][resourceType] += amount;
        }
    }

    // ==================== RESOURCE CARD EQUIPMENT ====================

    /**
     * @notice Equip a Resource Card to a resource node for production bonus
     * @param territoryId Territory with the resource node
     * @param cardTokenId Resource Card token ID to equip
     * @dev Card must match node's resource type. Max 3 cards per node.
     */
    function equipResourceCard(
        uint256 territoryId,
        uint256 cardTokenId
    ) external whenNotPaused {
        bytes32 colonyId = _getCallerColonyId();
        _requireTerritoryControl(territoryId, colonyId);

        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibColonyWarsStorage.ResourceNode storage node = cws.territoryResourceNodes[territoryId];

        // Verify node exists
        if (!node.active) revert ResourceNodeNotFound(territoryId);

        // Check slot limit
        if (cws.nodeStakedResourceCards[territoryId].length >= MAX_RESOURCE_CARDS_PER_NODE) {
            revert MaxResourceCardsPerNodeReached(territoryId);
        }

        // Get resource cards contract
        address resourceCardsAddr = cws.cardContracts.resourceCards;
        if (resourceCardsAddr == address(0)) revert ResourceCardsContractNotSet();

        IColonyResourceCards resourceContract = IColonyResourceCards(resourceCardsAddr);
        address sender = LibMeta.msgSender();

        // Verify ownership
        if (resourceContract.ownerOf(cardTokenId) != sender) revert ResourceCardNotOwned(cardTokenId);

        // Verify not already equipped
        if (resourceContract.isStaked(cardTokenId)) revert ResourceCardAlreadyEquipped(cardTokenId);

        // Verify resource type matches node type
        IColonyResourceCards.ResourceTraits memory traits = resourceContract.getTraits(cardTokenId);
        if (uint8(traits.resourceType) != uint8(node.resourceType)) {
            revert ResourceTypeMismatch(cardTokenId, uint8(node.resourceType), uint8(traits.resourceType));
        }

        // Equip card via NFT contract
        resourceContract.stakeToNode(cardTokenId, territoryId);

        // Track in storage
        cws.nodeStakedResourceCards[territoryId].push(cardTokenId);
        cws.resourceCardStakedToNode[cardTokenId] = territoryId;

        emit ResourceCardEquipped(territoryId, cardTokenId, sender);
    }

    /**
     * @notice Unequip a Resource Card from a resource node
     * @param territoryId Territory with the resource node
     * @param cardTokenId Resource Card token ID to unequip
     */
    function unequipResourceCard(
        uint256 territoryId,
        uint256 cardTokenId
    ) external whenNotPaused {
        bytes32 colonyId = _getCallerColonyId();
        _requireTerritoryControl(territoryId, colonyId);

        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();

        // Verify card is equipped to this node
        if (cws.resourceCardStakedToNode[cardTokenId] != territoryId) {
            revert ResourceCardNotEquippedToNode(cardTokenId, territoryId);
        }

        // Get resource cards contract
        address resourceCardsAddr = cws.cardContracts.resourceCards;
        if (resourceCardsAddr == address(0)) revert ResourceCardsContractNotSet();

        IColonyResourceCards resourceContract = IColonyResourceCards(resourceCardsAddr);
        address sender = LibMeta.msgSender();

        // Unequip via NFT contract
        resourceContract.unstakeFromNode(cardTokenId);

        // Remove from storage array
        uint256[] storage equippedCards = cws.nodeStakedResourceCards[territoryId];
        for (uint256 i = 0; i < equippedCards.length; i++) {
            if (equippedCards[i] == cardTokenId) {
                equippedCards[i] = equippedCards[equippedCards.length - 1];
                equippedCards.pop();
                break;
            }
        }

        // Clear reverse mapping
        delete cws.resourceCardStakedToNode[cardTokenId];

        emit ResourceCardUnequipped(territoryId, cardTokenId, sender);
    }

    /**
     * @notice Get all Resource Cards equipped to a node
     * @param territoryId Territory ID
     * @return cardTokenIds Array of equipped card token IDs
     */
    function getEquippedResourceCards(uint256 territoryId) external view returns (uint256[] memory cardTokenIds) {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        return cws.nodeStakedResourceCards[territoryId];
    }

    /**
     * @notice Get total production bonus from all card sources for a node
     * @param territoryId Territory ID
     * @return infraCardBonus Bonus from Infrastructure Cards (100 = no bonus)
     * @return resourceCardBonus Bonus from Resource Cards (100 = no bonus)
     * @return territoryCardBonus Additional bonus from Territory Card productionBonus
     */
    function getNodeCardBonuses(uint256 territoryId) external view returns (
        uint16 infraCardBonus,
        uint16 resourceCardBonus,
        uint8 territoryCardBonus
    ) {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibColonyWarsStorage.ResourceNode storage node = cws.territoryResourceNodes[territoryId];

        infraCardBonus = _getInfrastructureCardBonus(territoryId);
        resourceCardBonus = node.active ? _getResourceCardBonus(territoryId, uint8(node.resourceType)) : 100;

        // Get Territory Card bonus
        uint256 cardId = cws.territoryToCard[territoryId];
        if (cardId != 0 && cws.cardContracts.territoryCards != address(0)) {
            try IColonyTerritoryCards(cws.cardContracts.territoryCards).getTerritoryTraits(cardId) returns (
                IColonyTerritoryCards.TerritoryTraits memory traits
            ) {
                territoryCardBonus = traits.productionBonus;
            } catch {
                territoryCardBonus = 0;
            }
        }
    }

    // ==================== CARD BONUS HELPER FUNCTIONS ====================

    /**
     * @notice Get Infrastructure Card equipment bonus for a territory
     * @param territoryId Territory ID
     * @return bonus Bonus percentage (100 = no bonus, 150 = 50% bonus)
     */
    function _getInfrastructureCardBonus(uint256 territoryId) private view returns (uint16 bonus) {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibColonyWarsStorage.TerritoryEquipment storage equipment = cws.territoryEquipment[territoryId];

        // Base 100% + equipment production bonus
        bonus = 100 + equipment.totalProductionBonus;
    }

    /**
     * @notice Get Resource Card bonus for a node
     * @param territoryId Territory ID (node ID)
     * @param nodeResourceType Resource type of the node
     * @return bonus Bonus percentage (100 = no bonus)
     */
    function _getResourceCardBonus(uint256 territoryId, uint8 nodeResourceType) private view returns (uint16 bonus) {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        uint256[] storage stakedCards = cws.nodeStakedResourceCards[territoryId];

        if (stakedCards.length == 0) return 100; // No bonus

        address resourceCardsAddr = cws.cardContracts.resourceCards;
        if (resourceCardsAddr == address(0)) return 100;

        IColonyResourceCards resourceContract = IColonyResourceCards(resourceCardsAddr);
        bonus = 100;

        for (uint256 i = 0; i < stakedCards.length; i++) {
            try resourceContract.getTraits(stakedCards[i]) returns (IColonyResourceCards.ResourceTraits memory traits) {
                // Only count cards matching the node's resource type
                if (uint8(traits.resourceType) == nodeResourceType) {
                    // Calculate card bonus: yieldBonus × rarityMultiplier × qualityMultiplier
                    uint16 cardBonus = traits.yieldBonus;

                    // Apply rarity multiplier: Common=100, Uncommon=120, Rare=150, Epic=200, Legendary=300
                    cardBonus = (cardBonus * _getRarityMultiplier(uint8(traits.rarity))) / 100;

                    // Apply quality multiplier: +4% per quality level (1-5)
                    cardBonus = (cardBonus * (100 + uint16(traits.qualityLevel) * 4)) / 100;

                    bonus += cardBonus;
                }
            } catch {
                // Card may have been burned or contract call failed - skip
                continue;
            }
        }
    }

    /**
     * @notice Get rarity multiplier for bonus calculation
     * @param rarity Rarity enum value (0-4)
     * @return multiplier Multiplier percentage (100 = 1x, 300 = 3x)
     */
    function _getRarityMultiplier(uint8 rarity) private pure returns (uint16 multiplier) {
        if (rarity == 0) return 100;  // Common: 1.0x
        if (rarity == 1) return 120;  // Uncommon: 1.2x
        if (rarity == 2) return 150;  // Rare: 1.5x
        if (rarity == 3) return 200;  // Epic: 2.0x
        return 300;                    // Legendary: 3.0x
    }
}
