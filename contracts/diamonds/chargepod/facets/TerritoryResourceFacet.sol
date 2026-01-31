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
    event ResourceNodeRemoved(uint256 indexed territoryId, bytes32 indexed colonyId, uint8 nodeLevel, uint256 unharvestedResources);
    event ResourceNodeForceRemoved(uint256 indexed territoryId, address indexed admin, string reason);

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
    error NodeHasStakedCards(uint256 territoryId, uint256 cardCount);
    error NodeRemovalCooldownActive(uint256 territoryId, uint32 remainingTime);

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
        uint256 upgradeCost = _calculateNodeUpgradeCost(node.nodeLevel);
        uint256 resourceCost = 100 * uint256(newLevel);

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

        // Check cooldown (24h) - using safe arithmetic to prevent uint32 overflow
        uint32 currentTime = uint32(block.timestamp);
        uint32 cooldown = 86400; // 24 hours

        // Safe check: if lastHarvestTime is valid and cooldown hasn't passed
        if (node.lastHarvestTime > 0 && node.lastHarvestTime <= currentTime) {
            uint32 timeSinceHarvest = currentTime - node.lastHarvestTime;
            if (timeSinceHarvest < cooldown) {
                uint32 remaining = cooldown - timeSinceHarvest;
                revert HarvestCooldownActive(territoryId, remaining);
            }
        }
        // Note: if lastHarvestTime > currentTime (corrupted data), we allow harvest to fix it

        // Calculate production with bonuses
        harvestedAmount = _calculateHarvestAmount(colonyId, node);

        // Apply maintenance penalty if overdue (50% reduction per week overdue, min 10%)
        // Safe arithmetic: check if maintenance is overdue without overflow
        if (node.lastMaintenancePaid > 0 && node.lastMaintenancePaid <= currentTime) {
            uint32 timeSinceMaintenance = currentTime - node.lastMaintenancePaid;
            if (timeSinceMaintenance > MAINTENANCE_PERIOD) {
                uint32 overdueTime = timeSinceMaintenance - MAINTENANCE_PERIOD;
                uint256 weeksOverdue = overdueTime / MAINTENANCE_PERIOD;
                uint256 penaltyPercent = 50 * (weeksOverdue + 1); // 50%, 100%, 150%...
                if (penaltyPercent > 90) penaltyPercent = 90; // Cap at 90% penalty (10% yield)
                harvestedAmount = harvestedAmount * (100 - penaltyPercent) / 100;
            }
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

        // Return defaults if node doesn't exist (don't revert for view function)
        if (!node.active) {
            return (0, false, 0, 0);
        }

        uint32 currentTime = uint32(block.timestamp);
        maintenanceCost = BASE_MAINTENANCE_COST * node.nodeLevel;

        // All arithmetic in unchecked block - we validate bounds manually
        unchecked {
            uint32 maxSafeMaintenanceTime = type(uint32).max - MAINTENANCE_PERIOD;

            // Safe arithmetic: check for valid data AND overflow before adding
            // Data is valid if: lastMaintenancePaid > 0, <= currentTime, AND won't overflow when adding MAINTENANCE_PERIOD
            bool isValidData = node.lastMaintenancePaid > 0 &&
                              node.lastMaintenancePaid <= currentTime &&
                              node.lastMaintenancePaid <= maxSafeMaintenanceTime;

            if (isValidData) {
                uint32 timeSinceMaintenance = currentTime - node.lastMaintenancePaid;
                maintenanceDue = node.lastMaintenancePaid + MAINTENANCE_PERIOD; // Safe: checked above

                if (timeSinceMaintenance > MAINTENANCE_PERIOD) {
                    isOverdue = true;
                    uint32 overdueTime = timeSinceMaintenance - MAINTENANCE_PERIOD;
                    uint256 weeksOverdue = overdueTime / MAINTENANCE_PERIOD;
                    currentPenalty = 50 * (weeksOverdue + 1);
                    if (currentPenalty > 90) currentPenalty = 90;
                } else {
                    isOverdue = false;
                    currentPenalty = 0;
                }
            } else {
                // Data is invalid (0, > currentTime, or would overflow) - use safe defaults
                isOverdue = false;
                currentPenalty = 0;
                // Safe maintenanceDue calculation
                if (currentTime <= maxSafeMaintenanceTime) {
                    maintenanceDue = currentTime + MAINTENANCE_PERIOD;
                } else {
                    maintenanceDue = type(uint32).max;
                }
            }
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

        // Use unchecked for all loop arithmetic
        unchecked {
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
    }

    /**
     * @notice Diagnostic: Get raw storage values for a territory node (no arithmetic)
     * @param territoryId Territory ID
     * @return rawTerritoryId Raw territoryId from storage
     * @return rawResourceType Raw resourceType value
     * @return rawNodeLevel Raw nodeLevel value
     * @return rawAccumulated Raw accumulatedResources value
     * @return rawLastHarvest Raw lastHarvestTime value
     * @return rawLastMaintenance Raw lastMaintenancePaid value
     * @return rawActive Raw active flag
     */
    function getRawNodeStorage(uint256 territoryId) external view returns (
        uint256 rawTerritoryId,
        uint8 rawResourceType,
        uint8 rawNodeLevel,
        uint256 rawAccumulated,
        uint32 rawLastHarvest,
        uint32 rawLastMaintenance,
        bool rawActive
    ) {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibColonyWarsStorage.ResourceNode storage node = cws.territoryResourceNodes[territoryId];

        // Just read values directly - no arithmetic
        rawTerritoryId = node.territoryId;
        rawResourceType = uint8(node.resourceType);
        rawNodeLevel = node.nodeLevel;
        rawAccumulated = node.accumulatedResources;
        rawLastHarvest = node.lastHarvestTime;
        rawLastMaintenance = node.lastMaintenancePaid;
        rawActive = node.active;
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
            // Safe arithmetic using unchecked for known-safe operations
            unchecked {
                // type(uint32).max - 86400 = 4294880895, cannot overflow
                // Addition is only done when lastHarvestTime <= 4294880895, so also safe
                if (node.lastHarvestTime <= type(uint32).max - 86400) {
                    nextHarvestTime = node.lastHarvestTime + 86400; // 24h cooldown
                } else {
                    nextHarvestTime = type(uint32).max; // Return max if overflow would occur
                }
            }
            estimatedProduction = _calculateBaseProduction(node.nodeLevel);
        }
    }

    /**
     * @notice Get batch resource nodes info for multiple territories
     * @param territoryIds Array of territory IDs to query
     * @return exists Array of whether each node exists
     * @return resourceTypes Array of resource types (0-3)
     * @return nodeLevels Array of node levels (1-10)
     * @return nextHarvestTimes Array of timestamps when harvest is available
     * @return maintenanceOverdue Array of whether maintenance is overdue
     * @return estimatedProductions Array of estimated production amounts
     * @return upgradeCosts Array of governance token costs for upgrade
     */
    function getResourceNodesInfoBatch(uint256[] calldata territoryIds) external view returns (
        bool[] memory exists,
        uint8[] memory resourceTypes,
        uint8[] memory nodeLevels,
        uint32[] memory nextHarvestTimes,
        bool[] memory maintenanceOverdue,
        uint256[] memory estimatedProductions,
        uint256[] memory upgradeCosts
    ) {
        uint256 length = territoryIds.length;

        exists = new bool[](length);
        resourceTypes = new uint8[](length);
        nodeLevels = new uint8[](length);
        nextHarvestTimes = new uint32[](length);
        maintenanceOverdue = new bool[](length);
        estimatedProductions = new uint256[](length);
        upgradeCosts = new uint256[](length);

        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();

        for (uint256 i = 0; i < length; i++) {
            LibColonyWarsStorage.ResourceNode storage node = cws.territoryResourceNodes[territoryIds[i]];

            exists[i] = node.active;

            if (node.active) {
                resourceTypes[i] = uint8(node.resourceType);
                nodeLevels[i] = node.nodeLevel;

                // Safe arithmetic for nextHarvestTime using unchecked
                unchecked {
                    uint32 maxSafeTime = type(uint32).max - 86400;
                    if (node.lastHarvestTime <= maxSafeTime) {
                        nextHarvestTimes[i] = node.lastHarvestTime + 86400; // 24h cooldown
                    } else {
                        nextHarvestTimes[i] = type(uint32).max;
                    }
                }

                // Safe check for maintenance overdue using unchecked
                unchecked {
                    if (node.lastMaintenancePaid > 0 && node.lastMaintenancePaid <= block.timestamp) {
                        maintenanceOverdue[i] = (block.timestamp - node.lastMaintenancePaid) > MAINTENANCE_PERIOD;
                    } else {
                        maintenanceOverdue[i] = false;
                    }
                }

                estimatedProductions[i] = _calculateBaseProduction(node.nodeLevel);

                // Upgrade cost (0 if already max level)
                if (node.nodeLevel < 10) {
                    upgradeCosts[i] = 50 ether * node.nodeLevel;
                }
            }
        }
    }

    /**
     * @notice Get territory resource node data
     * @param territoryId Territory ID
     * @return node Resource node struct
     */
    function getTerritoryResourceNode(uint256 territoryId)
        external
        view
        returns (LibColonyWarsStorage.ResourceNode memory)
    {
        return LibColonyWarsStorage.colonyWarsStorage().territoryResourceNodes[territoryId];
    }

    /**
     * @notice Get node creation cost for territory resource nodes
     * @param nodeLevel Desired node level (1-10)
     * @return cost Governance token cost
     */
    function getTerritoryNodeCreationCost(uint8 nodeLevel)
        external
        pure
        returns (uint256 cost)
    {
        if (nodeLevel == 0 || nodeLevel > 10) return 0;
        return 50 ether * nodeLevel;
    }

    /**
     * @notice Get node upgrade cost for territory resource node
     * @param territoryId Territory ID with the node
     * @return cost Governance token cost for upgrade
     */
    function getTerritoryNodeUpgradeCost(uint256 territoryId)
        external
        view
        returns (uint256 cost)
    {
        LibColonyWarsStorage.ResourceNode storage node =
            LibColonyWarsStorage.colonyWarsStorage().territoryResourceNodes[territoryId];

        if (!node.active || node.nodeLevel >= 10) return 0;

        // Upgrade cost = 50 ether * currentLevel
        return 50 ether * node.nodeLevel;
    }

    /**
     * @notice Get upgrade requirements for territory resource node
     * @param territoryId Territory ID
     * @param user User address to check resource balance
     * @return currentLevel Current node level
     * @return newLevel Level after upgrade
     * @return tokenCost Governance token cost (ZICO)
     * @return resourceCost Resource units required
     * @return resourceType Resource type needed
     * @return userBalance User's balance of required resource
     * @return canAfford Whether user has enough resources
     */
    function getNodeUpgradeRequirements(uint256 territoryId, address user) external view returns (
        uint8 currentLevel,
        uint8 newLevel,
        uint256 tokenCost,
        uint256 resourceCost,
        uint8 resourceType,
        uint256 userBalance,
        bool canAfford
    ) {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibColonyWarsStorage.ResourceNode storage node = cws.territoryResourceNodes[territoryId];
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();

        currentLevel = node.nodeLevel;
        newLevel = node.nodeLevel + 1;
        tokenCost = 50 ether * node.nodeLevel;
        resourceCost = 100 * uint256(newLevel);
        resourceType = uint8(node.resourceType);
        userBalance = rs.userResources[user][resourceType];
        canAfford = userBalance >= resourceCost;
    }

    /**
     * @notice Diagnose upgrade issues - check all token and storage values
     * @param territoryId Territory ID
     * @param user User address
     * @return governanceToken Governance token address
     * @return beneficiary Payment beneficiary address
     * @return userTokenBalance User's governance token balance
     * @return userAllowance User's allowance to this contract
     * @return upgradeCost Cost in governance tokens
     */
    function diagnoseUpgrade(uint256 territoryId, address user) external view returns (
        address governanceToken,
        address beneficiary,
        uint256 userTokenBalance,
        uint256 userAllowance,
        uint256 upgradeCost
    ) {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibColonyWarsStorage.ResourceNode storage node = cws.territoryResourceNodes[territoryId];
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();

        governanceToken = rs.config.governanceToken;
        beneficiary = rs.config.paymentBeneficiary;
        upgradeCost = 50 ether * node.nodeLevel;

        if (governanceToken != address(0)) {
            userTokenBalance = IERC20(governanceToken).balanceOf(user);
            userAllowance = IERC20(governanceToken).allowance(user, address(this));
        }
    }

    // ==================== INTERNAL HELPERS ====================

    function _calculateBaseProduction(uint8 level) private pure returns (uint256) {
        return uint256(level) * 100; // Linear scaling - cast to uint256 first to avoid uint8 overflow
    }

    function _calculateNodePlacementCost(uint8 level) private pure returns (uint256) {
        return 50 ether * level; // governance token cost
    }

    function _calculateNodeUpgradeCost(uint8 currentLevel) private pure returns (uint256) {
        return 50 ether * currentLevel; // based on current level, not new level
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

        // 5. Apply Rare Catalyst harvest boost (if active)
        finalAmount = LibResourceStorage.applyHarvestBoost(LibMeta.msgSender(), finalAmount);

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
        address user = LibMeta.msgSender();
        bytes32 colonyId = LibColonyWarsStorage.getUserPrimaryColony(user);
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
    ) external whenNotPaused nonReentrant {
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

        // Effects: Update storage BEFORE external call (CEI pattern)
        cws.nodeStakedResourceCards[territoryId].push(cardTokenId);
        cws.resourceCardStakedToNode[cardTokenId] = territoryId;

        // Interactions: External call LAST
        resourceContract.stakeToNode(cardTokenId, territoryId);

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
    ) external whenNotPaused nonReentrant {
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

        // Effects: Update storage BEFORE external call (CEI pattern)
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

        // Interactions: External call LAST
        resourceContract.unstakeFromNode(cardTokenId);

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

    // ==================== NODE REMOVAL ====================

    /**
     * @notice Remove resource node from territory (owner action)
     * @param territoryId Territory with node to remove
     * @param forceUnstakeCards If true, automatically unstake all cards; if false, revert if cards are staked
     * @dev Requires territory control. Unharvested resources are lost.
     *      Use harvestResourceNode() before removing to collect pending resources.
     */
    function removeResourceNode(
        uint256 territoryId,
        bool forceUnstakeCards
    ) external whenNotPaused {
        bytes32 colonyId = _getCallerColonyId();
        _requireTerritoryControl(territoryId, colonyId);

        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibColonyWarsStorage.ResourceNode storage node = cws.territoryResourceNodes[territoryId];

        if (!node.active) revert ResourceNodeNotFound(territoryId);

        // Handle staked resource cards
        uint256[] storage stakedCards = cws.nodeStakedResourceCards[territoryId];
        uint256 cardCount = stakedCards.length;

        if (cardCount > 0) {
            if (!forceUnstakeCards) {
                revert NodeHasStakedCards(territoryId, cardCount);
            }
            // Force unstake all cards
            _forceUnstakeAllCards(territoryId, cws);
        }

        // Store for event
        uint8 nodeLevel = node.nodeLevel;
        uint256 unharvestedResources = _calculatePendingResources(node);

        // Deactivate node
        node.active = false;
        node.nodeLevel = 0;
        node.accumulatedResources = 0;
        node.lastHarvestTime = 0;
        node.lastMaintenancePaid = 0;

        emit ResourceNodeRemoved(territoryId, colonyId, nodeLevel, unharvestedResources);
    }

    /**
     * @notice Admin force remove resource node (emergency use)
     * @param territoryId Territory with node to remove
     * @param reason Reason for forced removal (for audit trail)
     * @dev ADMIN ONLY. Use for stuck nodes, exploits, or maintenance.
     */
    function forceRemoveResourceNode(
        uint256 territoryId,
        string calldata reason
    ) external onlyAuthorized {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibColonyWarsStorage.ResourceNode storage node = cws.territoryResourceNodes[territoryId];

        if (!node.active) revert ResourceNodeNotFound(territoryId);

        // Force unstake all cards (admin override)
        _forceUnstakeAllCards(territoryId, cws);

        // Deactivate node
        node.active = false;
        node.nodeLevel = 0;
        node.accumulatedResources = 0;
        node.lastHarvestTime = 0;
        node.lastMaintenancePaid = 0;

        emit ResourceNodeForceRemoved(territoryId, LibMeta.msgSender(), reason);
    }

    /**
     * @notice Check if node can be removed and get removal info
     * @param territoryId Territory ID
     * @return canRemove Whether node can be removed
     * @return nodeLevel Current node level (0 if no node)
     * @return stakedCardCount Number of cards that would be unstaked
     * @return pendingResources Resources that would be lost
     */
    function getNodeRemovalInfo(uint256 territoryId) external view returns (
        bool canRemove,
        uint8 nodeLevel,
        uint256 stakedCardCount,
        uint256 pendingResources
    ) {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibColonyWarsStorage.ResourceNode storage node = cws.territoryResourceNodes[territoryId];

        if (!node.active) {
            return (false, 0, 0, 0);
        }

        canRemove = true;
        nodeLevel = node.nodeLevel;
        stakedCardCount = cws.nodeStakedResourceCards[territoryId].length;
        pendingResources = _calculatePendingResources(node);
    }

    /**
     * @notice Force unstake all resource cards from a node
     * @param territoryId Territory ID
     * @param cws Colony Wars Storage reference
     */
    function _forceUnstakeAllCards(
        uint256 territoryId,
        LibColonyWarsStorage.ColonyWarsStorage storage cws
    ) internal {
        uint256[] storage stakedCards = cws.nodeStakedResourceCards[territoryId];

        if (stakedCards.length == 0) return;

        address resourceCardsAddr = cws.cardContracts.resourceCards;

        // Unstake each card via NFT contract (if contract exists)
        if (resourceCardsAddr != address(0)) {
            IColonyResourceCards resourceContract = IColonyResourceCards(resourceCardsAddr);

            for (uint256 i = 0; i < stakedCards.length; i++) {
                uint256 cardTokenId = stakedCards[i];

                // Clear reverse mapping
                delete cws.resourceCardStakedToNode[cardTokenId];

                // Unstake via NFT contract
                try resourceContract.unstakeFromNode(cardTokenId) {
                    emit ResourceCardUnequipped(territoryId, cardTokenId, address(0));
                } catch {
                    // Card may already be unstaked or contract issue - continue
                }
            }
        } else {
            // No contract - just clear mappings
            for (uint256 i = 0; i < stakedCards.length; i++) {
                delete cws.resourceCardStakedToNode[stakedCards[i]];
            }
        }

        // Clear the array
        delete cws.nodeStakedResourceCards[territoryId];
    }

    /**
     * @notice Calculate pending resources for a node
     * @param node Resource node storage reference
     * @return pending Pending unharvested resources
     */
    function _calculatePendingResources(
        LibColonyWarsStorage.ResourceNode storage node
    ) internal view returns (uint256 pending) {
        if (!node.active) return 0;

        uint32 currentTime = uint32(block.timestamp);

        // Safe arithmetic: ensure lastHarvestTime is valid
        if (node.lastHarvestTime == 0 || node.lastHarvestTime > currentTime) {
            return 0; // No pending resources if data is invalid
        }

        uint32 timeSinceHarvest = currentTime - node.lastHarvestTime;

        // Base production: 100 * level per 24h
        pending = (uint256(node.nodeLevel) * 100 * timeSinceHarvest) / 86400;
    }

    // ==================== RARE CATALYST BOOST ====================

    event RareCatalystActivated(address indexed user, uint256 rareAmount, uint16 boostMultiplier, uint32 endTime);

    error RareCatalystNotEnabled();
    error InsufficientRareResources(uint256 required, uint256 available);
    error RareCatalystAmountBelowMinimum(uint256 provided, uint256 minimum);

    /**
     * @notice Activate Rare Catalyst to boost harvest yields
     * @dev RESOURCE SINK: Consumes Rare Elements for temporary harvest bonus
     *      Formula: boostMultiplier = rareAmount / resourcePerBasisPoint (capped at maxMultiplier)
     *               duration = rareAmount * durationPerResource
     * @param rareAmount Amount of Rare Elements to consume
     * @return boostMultiplier Bonus in basis points (e.g., 5000 = +50%)
     * @return endTime Timestamp when boost expires
     */
    function activateRareCatalyst(uint256 rareAmount)
        external
        whenNotPaused
        returns (uint16 boostMultiplier, uint32 endTime)
    {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        LibResourceStorage.BoostConfig storage config = rs.rareCatalystConfig;

        // Check if enabled
        if (!config.enabled) revert RareCatalystNotEnabled();

        // Check minimum amount
        if (rareAmount < config.minResourceAmount) {
            revert RareCatalystAmountBelowMinimum(rareAmount, config.minResourceAmount);
        }

        address user = LibMeta.msgSender();

        // Apply decay before checking balance
        LibResourceStorage.applyResourceDecay(user);

        // Check user has enough Rare resources
        uint256 available = rs.userResources[user][LibResourceStorage.RARE_ELEMENTS];
        if (available < rareAmount) {
            revert InsufficientRareResources(rareAmount, available);
        }

        // Calculate boost multiplier (basis points)
        // Formula: rareAmount / resourcePerBasisPoint, capped at maxMultiplier
        uint256 calculatedMultiplier = rareAmount / config.resourcePerBasisPoint;
        if (calculatedMultiplier > config.maxMultiplier) {
            calculatedMultiplier = config.maxMultiplier;
        }
        boostMultiplier = uint16(calculatedMultiplier);

        // Calculate duration
        // Formula: rareAmount * durationPerResource
        uint256 duration = rareAmount * config.durationPerResource;
        endTime = uint32(block.timestamp + duration);

        // If user has existing boost, extend time (additive) but DON'T stack multiplier
        if (rs.harvestBoostEndTime[user] > uint32(block.timestamp)) {
            // Extend existing boost time
            endTime = rs.harvestBoostEndTime[user] + uint32(duration);
            // Keep higher multiplier
            if (rs.harvestBoostMultiplier[user] > boostMultiplier) {
                boostMultiplier = rs.harvestBoostMultiplier[user];
            }
        }

        // Consume Rare resources
        rs.userResources[user][LibResourceStorage.RARE_ELEMENTS] -= rareAmount;

        // Set boost
        rs.harvestBoostEndTime[user] = endTime;
        rs.harvestBoostMultiplier[user] = boostMultiplier;

        // Update stats
        rs.totalBoostsActivated++;
        rs.totalResourcesConsumedByBoosts += rareAmount;

        emit RareCatalystActivated(user, rareAmount, boostMultiplier, endTime);
    }

    /**
     * @notice Get user's current Rare Catalyst boost status
     * @param user User address
     * @return isActive Whether boost is currently active
     * @return multiplier Current boost multiplier (basis points)
     * @return endTime When boost expires (0 if none)
     * @return remainingSeconds Seconds until boost expires
     */
    function getRareCatalystStatus(address user) external view returns (
        bool isActive,
        uint16 multiplier,
        uint32 endTime,
        uint32 remainingSeconds
    ) {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();

        endTime = rs.harvestBoostEndTime[user];
        multiplier = rs.harvestBoostMultiplier[user];

        if (endTime > uint32(block.timestamp)) {
            isActive = true;
            remainingSeconds = endTime - uint32(block.timestamp);
        } else {
            isActive = false;
            remainingSeconds = 0;
        }
    }

    /**
     * @notice Preview Rare Catalyst activation
     * @param user User address
     * @param rareAmount Amount to spend
     * @return canActivate Whether user can activate with this amount
     * @return reason Failure reason if cannot activate
     * @return expectedMultiplier Expected boost multiplier
     * @return expectedEndTime Expected boost end time
     */
    function previewRareCatalyst(address user, uint256 rareAmount) external view returns (
        bool canActivate,
        string memory reason,
        uint16 expectedMultiplier,
        uint32 expectedEndTime
    ) {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        LibResourceStorage.BoostConfig storage config = rs.rareCatalystConfig;

        if (!config.enabled) {
            return (false, "Rare Catalyst not enabled", 0, 0);
        }

        if (rareAmount < config.minResourceAmount) {
            return (false, "Amount below minimum", 0, 0);
        }

        uint256 available = rs.userResources[user][LibResourceStorage.RARE_ELEMENTS];
        if (available < rareAmount) {
            return (false, "Insufficient Rare resources", 0, 0);
        }

        // Calculate expected results
        uint256 calcMultiplier = rareAmount / config.resourcePerBasisPoint;
        if (calcMultiplier > config.maxMultiplier) {
            calcMultiplier = config.maxMultiplier;
        }
        expectedMultiplier = uint16(calcMultiplier);

        uint256 duration = rareAmount * config.durationPerResource;
        expectedEndTime = uint32(block.timestamp + duration);

        // Account for existing boost extension
        if (rs.harvestBoostEndTime[user] > uint32(block.timestamp)) {
            expectedEndTime = rs.harvestBoostEndTime[user] + uint32(duration);
            if (rs.harvestBoostMultiplier[user] > expectedMultiplier) {
                expectedMultiplier = rs.harvestBoostMultiplier[user];
            }
        }

        canActivate = true;
        reason = "";
    }

    /**
     * @notice Get Rare Catalyst configuration
     * @return resourcePerBasisPoint Rare needed per 0.01% bonus
     * @return durationPerResource Seconds per Rare unit
     * @return maxMultiplier Maximum bonus (basis points)
     * @return minResourceAmount Minimum Rare to activate
     * @return enabled Whether feature is enabled
     */
    function getRareCatalystConfig() external view returns (
        uint256 resourcePerBasisPoint,
        uint256 durationPerResource,
        uint16 maxMultiplier,
        uint256 minResourceAmount,
        bool enabled
    ) {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        LibResourceStorage.BoostConfig storage config = rs.rareCatalystConfig;

        return (
            config.resourcePerBasisPoint,
            config.durationPerResource,
            config.maxMultiplier,
            config.minResourceAmount,
            config.enabled
        );
    }

    /**
     * @notice Configure Rare Catalyst parameters (ADMIN ONLY)
     * @param resourcePerBasisPoint Rare needed per 0.01% bonus
     * @param durationPerResource Seconds per Rare unit
     * @param maxMultiplier Maximum bonus (basis points)
     * @param minResourceAmount Minimum Rare to activate
     * @param enabled Whether to enable feature
     */
    function configureRareCatalyst(
        uint256 resourcePerBasisPoint,
        uint256 durationPerResource,
        uint16 maxMultiplier,
        uint256 minResourceAmount,
        bool enabled
    ) external onlyAuthorized {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();

        rs.rareCatalystConfig = LibResourceStorage.BoostConfig({
            resourcePerBasisPoint: resourcePerBasisPoint,
            durationPerResource: durationPerResource,
            maxMultiplier: maxMultiplier,
            minResourceAmount: minResourceAmount,
            enabled: enabled
        });
    }
}
