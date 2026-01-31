// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibMeta} from "../../shared/libraries/LibMeta.sol";
import {LibColonyWarsStorage} from "../libraries/LibColonyWarsStorage.sol";
import {LibHenomorphsStorage} from "../libraries/LibHenomorphsStorage.sol";
import {LibFeeCollection} from "../libraries/LibFeeCollection.sol";
import {ResourceHelper} from "../libraries/ResourceHelper.sol";
import {AccessControlBase} from "./AccessControlBase.sol";
import {ColonyHelper} from "../libraries/ColonyHelper.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IColonyResourceCards} from "../interfaces/IColonyResourceCards.sol";
import {LibResourceStorage} from "../libraries/LibResourceStorage.sol";

/**
 * @notice Interface for mintable reward token (YLW)
 */
interface IRewardToken is IERC20 {
    function mint(address to, uint256 amount, string calldata reason) external;
}

/**
 * @title ResourceEconomyFacet
 * @notice Manages resource nodes, harvesting, and colony resource balances
 * @dev MODUŁ 6 - Dual Token Economy Implementation
 *
 * NOTE: This facet uses economyResourceNodes (keyed by auto-increment economyNodeId),
 * separate from territoryResourceNodes used by TerritoryResourceFacet (keyed by territoryId).
 *
 * TOKEN ALLOCATION:
 * - ZICO (Premium): Node creation, node upgrades, strategic investments
 * - YLW (Utility): Maintenance payments, harvesting rewards, daily operations
 *
 * ECONOMIC FLOW:
 * - Players earn YLW through harvesting resources
 * - Players spend YLW on node maintenance
 * - Players spend ZICO on node creation and upgrades (long-term investments)
 */
contract ResourceEconomyFacet is AccessControlBase {
    using LibColonyWarsStorage for LibColonyWarsStorage.ColonyWarsStorage;
    using SafeERC20 for IERC20;

    // Custom Errors
    error TerritoryNotControlled();
    error ResourceNodeNotFound();
    error NodeMaintenanceRequired();
    error HarvestCooldownActive();
    error InvalidNodeLevel();
    error NodeAlreadyExists();
    error InsufficientZICO();
    error InsufficientAuxiliaryToken();
    error AuxiliaryTokenNotConfigured();
    error ResourceCardsNotSet();
    error InvalidResourceType();
    error ResourceMaxSupplyReached();
    error NodeHasStakedCards(uint256 nodeId, uint256 cardCount);

    // Events
    event ResourceNodeCreated(
        uint256 indexed nodeId,
        uint256 indexed territoryId,
        LibColonyWarsStorage.ResourceType resourceType,
        uint8 nodeLevel,
        uint256 primaryCost
    );
    event ResourcesHarvested(
        uint256 indexed nodeId,
        bytes32 indexed colonyId,
        LibColonyWarsStorage.ResourceType resourceType,
        uint256 amount,
        uint256 tokenReward
    );
    event NodeMaintenancePaid(
        uint256 indexed nodeId, 
        bytes32 indexed colonyId, 
        uint256 auxilaryCost
    );
    event NodeUpgraded(
        uint256 indexed nodeId, 
        uint8 newLevel, 
        uint256 primaryCost
    );
    event ResourceDecay(
        bytes32 indexed colonyId,
        LibColonyWarsStorage.ResourceType resourceType,
        uint256 decayAmount
    );
    event ResourceCardMinted(uint256 indexed tokenId, address indexed recipient, uint8 resourceType, uint8 rarity);
    event EconomyNodeRemoved(uint256 indexed nodeId, uint256 indexed territoryId, bytes32 indexed colonyId, uint8 nodeLevel, uint256 unharvestedResources);
    event EconomyNodeForceRemoved(uint256 indexed nodeId, address indexed admin, string reason);

    // Constants - Resource Economics
    uint256 constant DAILY_MAINTENANCE_COST_AUX = 10 ether; // 10 YLW per day per node
    uint32 constant HARVEST_COOLDOWN = 8 hours;
    uint256 constant BASE_PRODUCTION_RATE = 10; // Resources per hour
    uint256 constant TOKEN_HARVEST_REWARD_BASE = 5 ether; // 5 YLW base reward
    uint8 constant MAX_NODE_LEVEL = 10;
    
    // Constants - Node Costs (ZICO)
    uint256 constant NODE_CREATION_COST_PER_LEVEL = 100 ether; // 100 ZICO per level
    uint256 constant NODE_UPGRADE_COST_MULTIPLIER = 200 ether; // 200 ZICO * current level

    // ============================================================================
    // RESOURCE NODE MANAGEMENT - ZICO OPERATIONS
    // ============================================================================

    /**
     * @notice Create new resource node on territory (COSTS ZICO)
     * @param territoryId Territory where node will be placed
     * @param resourceType Type of resource to produce
     * @param nodeLevel Initial node level (1-10)
     * @dev Premium operation: Requires ZICO payment
     */
    function createResourceNode(
        uint256 territoryId,
        LibColonyWarsStorage.ResourceType resourceType,
        uint8 nodeLevel
    ) external whenNotPaused nonReentrant {
        LibColonyWarsStorage.requireInitialized();
        
        if (nodeLevel == 0 || nodeLevel > MAX_NODE_LEVEL) revert InvalidNodeLevel();
        
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        // Verify territory ownership
        LibColonyWarsStorage.Territory storage territory = cws.territories[territoryId];
        bytes32 colonyId = LibColonyWarsStorage.getUserPrimaryColony(LibMeta.msgSender());
        
        if (territory.controllingColony != colonyId) revert TerritoryNotControlled();
        
        // Verify colony ownership
        if (!ColonyHelper.isColonyCreator(colonyId, hs.stakingSystemAddress)) {
            revert TerritoryNotControlled();
        }
        
        // Calculate primary currency cost: 100 per node level
        uint256 creationCost = uint256(nodeLevel) * NODE_CREATION_COST_PER_LEVEL;

        // Collect primary currency fee (Premium token for strategic investments)
        LibFeeCollection.collectFee(
            IERC20(ResourceHelper.getPrimaryCurrency()),
            LibMeta.msgSender(),
            ResourceHelper.getTreasuryAddress(),
            creationCost,
            "node_creation"
        );
        
        // Create node
        uint256 nodeId = ++cws.economyNodeCounter;
        LibColonyWarsStorage.ResourceNode storage node = cws.economyResourceNodes[nodeId];
        node.territoryId = territoryId;
        node.resourceType = resourceType;
        node.nodeLevel = nodeLevel;
        node.accumulatedResources = 0;
        node.lastHarvestTime = uint32(block.timestamp);
        node.lastMaintenancePaid = uint32(block.timestamp);
        node.active = true;
        
        emit ResourceNodeCreated(nodeId, territoryId, resourceType, nodeLevel, creationCost);
    }

    /**
     * @notice Upgrade resource node level (COSTS ZICO)
     * @param nodeId Node to upgrade
     * @dev Premium operation: Requires ZICO payment
     */
    function upgradeEconomyNode(uint256 nodeId) external whenNotPaused nonReentrant {
        LibColonyWarsStorage.requireInitialized();
        
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        LibColonyWarsStorage.ResourceNode storage node = cws.economyResourceNodes[nodeId];
        
        if (!node.active) revert ResourceNodeNotFound();
        if (node.nodeLevel >= MAX_NODE_LEVEL) revert InvalidNodeLevel();
        
        // Verify territory ownership
        LibColonyWarsStorage.Territory storage territory = cws.territories[node.territoryId];
        bytes32 colonyId = LibColonyWarsStorage.getUserPrimaryColony(LibMeta.msgSender());
        
        if (territory.controllingColony != colonyId) revert TerritoryNotControlled();
        
        // Verify colony ownership
        if (!ColonyHelper.isColonyCreator(colonyId, hs.stakingSystemAddress)) {
            revert TerritoryNotControlled();
        }
        
        // Calculate ZICO cost: 200 ZICO * current level
        uint256 upgradeCost = uint256(node.nodeLevel) * NODE_UPGRADE_COST_MULTIPLIER;

        // Collect primary currency fee (Premium token for upgrades)
        LibFeeCollection.collectFee(
            IERC20(ResourceHelper.getPrimaryCurrency()),
            LibMeta.msgSender(),
            ResourceHelper.getTreasuryAddress(),
            upgradeCost,
            "node_upgrade"
        );
        
        node.nodeLevel++;
        
        emit NodeUpgraded(nodeId, node.nodeLevel, upgradeCost);
    }

    // ============================================================================
    // RESOURCE HARVESTING - YLW OPERATIONS
    // ============================================================================

    /**
     * @notice Harvest accumulated resources from node (REWARDS YLW)
     * @param nodeId Node to harvest from
     * @dev Utility operation: Rewards YLW for activity
     */
    function harvestResources(uint256 nodeId) external whenNotPaused nonReentrant {
        LibColonyWarsStorage.requireInitialized();
        
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibColonyWarsStorage.ResourceNode storage node = cws.economyResourceNodes[nodeId];
        
        if (!node.active) revert ResourceNodeNotFound();
        
        // Verify territory ownership
        LibColonyWarsStorage.Territory storage territory = cws.territories[node.territoryId];
        bytes32 colonyId = LibColonyWarsStorage.getUserPrimaryColony(LibMeta.msgSender());
        
        if (territory.controllingColony != colonyId) revert TerritoryNotControlled();
        
        // Check harvest cooldown - safe arithmetic
        unchecked {
            if (node.lastHarvestTime > 0 && node.lastHarvestTime <= block.timestamp) {
                uint256 timeSinceHarvest = block.timestamp - node.lastHarvestTime;
                if (timeSinceHarvest < HARVEST_COOLDOWN) {
                    revert HarvestCooldownActive();
                }
            }
            // If lastHarvestTime > block.timestamp (corrupted), allow harvest to fix it
        }

        // Check maintenance status - safe arithmetic
        uint32 daysSinceMaintenance = 0;
        unchecked {
            if (node.lastMaintenancePaid > 0 && node.lastMaintenancePaid <= block.timestamp) {
                daysSinceMaintenance = uint32((block.timestamp - node.lastMaintenancePaid) / 1 days);
            }
        }
        if (daysSinceMaintenance > 0) {
            revert NodeMaintenanceRequired();
        }

        // Calculate accumulated resources - safe arithmetic
        uint256 hoursSinceHarvest = 0;
        unchecked {
            if (node.lastHarvestTime > 0 && node.lastHarvestTime <= block.timestamp) {
                hoursSinceHarvest = (block.timestamp - node.lastHarvestTime) / 1 hours;
            }
        }
        uint256 production = uint256(BASE_PRODUCTION_RATE) * uint256(node.nodeLevel) * hoursSinceHarvest;
        
        // Apply territory equipment bonus
        LibColonyWarsStorage.TerritoryEquipment storage equipment = cws.territoryEquipment[node.territoryId];
        production = (production * (100 + equipment.totalProductionBonus)) / 100;

        // Award resources to USER (primary reward - 100%)
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        address user = LibMeta.msgSender();
        LibResourceStorage.applyResourceDecay(user);
        rs.userResources[user][uint8(node.resourceType)] += production;
        rs.userResourcesLastUpdate[user] = uint32(block.timestamp);

        // Also add 20% bonus to colony treasury (for processing)
        node.accumulatedResources += production;
        uint256 colonyBonus = production * 20 / 100;
        LibColonyWarsStorage.ResourceBalance storage balance = cws.colonyResources[colonyId];
        ResourceHelper.addResources(balance, node.resourceType, colonyBonus);

        node.lastHarvestTime = uint32(block.timestamp);

        // Calculate YLW reward: Base + level bonus
        uint256 tokenReward = TOKEN_HARVEST_REWARD_BASE + (uint256(node.nodeLevel) * 1 ether);

        // Reward auxiliary currency (Utility token for daily activities)
        // Uses Treasury → Mint fallback pattern for sustainable tokenomics
        address auxiliaryCurrency = ResourceHelper.getAuxiliaryCurrency();
        if (auxiliaryCurrency != address(0) && tokenReward > 0) {
            _distributeYlwReward(auxiliaryCurrency, LibMeta.msgSender(), tokenReward);
        }
        
        emit ResourcesHarvested(nodeId, colonyId, node.resourceType, production, tokenReward);
    }

    /**
     * @notice Pay maintenance for resource node (COSTS YLW)
     * @param nodeId Node to pay maintenance for
     * @dev Utility operation: Requires YLW payment for daily upkeep
     */
    function maintainEconomyNode(uint256 nodeId) external whenNotPaused nonReentrant {
        LibColonyWarsStorage.requireInitialized();
        
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibColonyWarsStorage.ResourceNode storage node = cws.economyResourceNodes[nodeId];
        
        if (!node.active) revert ResourceNodeNotFound();

        // Verify territory ownership
        LibColonyWarsStorage.Territory storage territory = cws.territories[node.territoryId];
        bytes32 colonyId = LibColonyWarsStorage.getUserPrimaryColony(LibMeta.msgSender());

        if (territory.controllingColony != colonyId) revert TerritoryNotControlled();

        // Calculate days of maintenance owed - safe arithmetic
        uint32 daysSinceMaintenance = 0;
        unchecked {
            if (node.lastMaintenancePaid > 0 && node.lastMaintenancePaid <= block.timestamp) {
                daysSinceMaintenance = uint32((block.timestamp - node.lastMaintenancePaid) / 1 days);
            }
        }
        if (daysSinceMaintenance == 0) return;

        // Calculate YLW cost
        uint256 maintenanceCost = DAILY_MAINTENANCE_COST_AUX * daysSinceMaintenance;

        // Collect auxiliary currency fee using LibFeeCollection
        LibFeeCollection.collectFee(
            IERC20(ResourceHelper.getAuxiliaryCurrency()),
            LibMeta.msgSender(),
            ResourceHelper.getTreasuryAddress(),
            maintenanceCost,
            "node_maintenance"
        );

        node.lastMaintenancePaid = uint32(block.timestamp);
        
        emit NodeMaintenancePaid(nodeId, colonyId, maintenanceCost);
    }

    // ============================================================================
    // VIEW FUNCTIONS
    // ============================================================================

    /**
     * @notice Get resource node info
     * @param nodeId Node to query
     * @return Resource node struct
     */
    function getResourceNode(uint256 nodeId)
        external
        view
        returns (LibColonyWarsStorage.ResourceNode memory)
    {
        return LibColonyWarsStorage.colonyWarsStorage().economyResourceNodes[nodeId];
    }

    /**
     * @notice Get colony resource balance
     * @param colonyId Colony to query
     * @return balance Resource balance struct
     */
    function getColonyResources(bytes32 colonyId) 
        external 
        view 
        returns (LibColonyWarsStorage.ResourceBalance memory) 
    {
        return LibColonyWarsStorage.colonyWarsStorage().colonyResources[colonyId];
    }

    /**
     * @notice Calculate pending resources for node
     * @param nodeId Node to query
     * @return production Pending resources amount
     * @return tokenReward Expected YLW reward for harvesting
     */
    function getPendingResources(uint256 nodeId) 
        external 
        view 
        returns (uint256 production, uint256 tokenReward) 
    {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibColonyWarsStorage.ResourceNode storage node = cws.economyResourceNodes[nodeId];
        
        if (!node.active) return (0, 0);
        
        // Calculate pending production
        uint256 hoursSinceHarvest = (block.timestamp - node.lastHarvestTime) / 1 hours;
        production = BASE_PRODUCTION_RATE * node.nodeLevel * hoursSinceHarvest;
        
        // Apply equipment bonus
        LibColonyWarsStorage.TerritoryEquipment storage equipment = cws.territoryEquipment[node.territoryId];
        production = (production * (100 + equipment.totalProductionBonus)) / 100;
        
        // Calculate YLW reward
        tokenReward = TOKEN_HARVEST_REWARD_BASE + (uint256(node.nodeLevel) * 1 ether);
        
        return (production, tokenReward);
    }

    /**
     * @notice Get maintenance cost for node
     * @param nodeId Node to query
     * @return maintanaceCost YLW cost for outstanding maintenance
     * @return daysOwed Days of maintenance owed
     */
    function getMaintenanceCost(uint256 nodeId)
        external
        view
        returns (uint256 maintanaceCost, uint32 daysOwed)
    {
        LibColonyWarsStorage.ResourceNode storage node =
            LibColonyWarsStorage.colonyWarsStorage().economyResourceNodes[nodeId];
        
        if (!node.active) return (0, 0);
        
        daysOwed = uint32((block.timestamp - node.lastMaintenancePaid) / 1 days);
        maintanaceCost = DAILY_MAINTENANCE_COST_AUX * daysOwed;
        
        return (maintanaceCost, daysOwed);
    }

    /**
     * @notice Get node creation cost
     * @param nodeLevel Desired node level (1-10)
     * @return zicoCost ZICO cost for creating node
     */
    function getNodeCreationCost(uint8 nodeLevel) 
        external 
        pure 
        returns (uint256 zicoCost) 
    {
        if (nodeLevel == 0 || nodeLevel > MAX_NODE_LEVEL) return 0;
        return uint256(nodeLevel) * NODE_CREATION_COST_PER_LEVEL;
    }

    /**
     * @notice Get node upgrade cost
     * @param nodeId Node to query
     * @return zicoCost ZICO cost for upgrade
     */
    function getNodeUpgradeCost(uint256 nodeId)
        external
        view
        returns (uint256 zicoCost)
    {
        LibColonyWarsStorage.ResourceNode storage node =
            LibColonyWarsStorage.colonyWarsStorage().economyResourceNodes[nodeId];

        if (!node.active || node.nodeLevel >= MAX_NODE_LEVEL) return 0;
        return uint256(node.nodeLevel) * NODE_UPGRADE_COST_MULTIPLIER;
    }

    /**
     * @notice Get comprehensive economy node info (similar to TerritoryResourceFacet.getResourceNodeInfo)
     * @param nodeId Node to query
     * @return exists Whether node exists and is active
     * @return territoryId Territory where node is placed
     * @return resourceType Type of resource (0-3)
     * @return nodeLevel Current node level (1-10)
     * @return lastHarvest Timestamp of last harvest
     * @return nextHarvestTime Timestamp when harvest is available (8h cooldown)
     * @return lastMaintenancePaid Timestamp of last maintenance payment
     * @return maintenanceOverdue Whether maintenance payment is overdue
     * @return estimatedProduction Estimated resources per harvest (with bonuses)
     * @return upgradeCostZico ZICO cost for next upgrade (0 if max level)
     */
    function getEconomyNodeInfo(uint256 nodeId) external view returns (
        bool exists,
        uint256 territoryId,
        uint8 resourceType,
        uint8 nodeLevel,
        uint32 lastHarvest,
        uint32 nextHarvestTime,
        uint32 lastMaintenancePaid,
        bool maintenanceOverdue,
        uint256 estimatedProduction,
        uint256 upgradeCostZico
    ) {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibColonyWarsStorage.ResourceNode storage node = cws.economyResourceNodes[nodeId];

        exists = node.active;

        if (exists) {
            territoryId = node.territoryId;
            resourceType = uint8(node.resourceType);
            nodeLevel = node.nodeLevel;
            lastHarvest = node.lastHarvestTime;
            lastMaintenancePaid = node.lastMaintenancePaid;

            // Safe arithmetic using unchecked
            unchecked {
                // nextHarvestTime - safe overflow check
                uint32 maxSafeHarvestTime = type(uint32).max - HARVEST_COOLDOWN;
                if (node.lastHarvestTime <= maxSafeHarvestTime) {
                    nextHarvestTime = node.lastHarvestTime + HARVEST_COOLDOWN;
                } else {
                    nextHarvestTime = type(uint32).max;
                }

                // maintenanceOverdue - safe overflow check
                uint256 maxSafeMaintenanceTime = type(uint256).max - 1 days;
                if (node.lastMaintenancePaid <= maxSafeMaintenanceTime) {
                    maintenanceOverdue = block.timestamp > node.lastMaintenancePaid + 1 days;
                } else {
                    maintenanceOverdue = false;
                }

                // hoursSinceHarvest - safe underflow check
                uint256 hoursSinceHarvest = 0;
                if (node.lastHarvestTime > 0 && node.lastHarvestTime <= block.timestamp) {
                    hoursSinceHarvest = (block.timestamp - node.lastHarvestTime) / 1 hours;
                }
                estimatedProduction = uint256(BASE_PRODUCTION_RATE) * uint256(node.nodeLevel) * hoursSinceHarvest;
            }

            LibColonyWarsStorage.TerritoryEquipment storage equipment = cws.territoryEquipment[node.territoryId];
            estimatedProduction = (estimatedProduction * (100 + equipment.totalProductionBonus)) / 100;

            // Upgrade cost (0 if already max level)
            if (node.nodeLevel < MAX_NODE_LEVEL) {
                upgradeCostZico = uint256(node.nodeLevel) * NODE_UPGRADE_COST_MULTIPLIER;
            }
        }
    }

    /**
     * @notice Get batch economy nodes info
     * @param nodeIds Array of node IDs to query
     * @return exists Array of whether each node exists and is active
     * @return territoryIds Array of territory IDs where nodes are placed
     * @return resourceTypes Array of resource types (0-3)
     * @return nodeLevels Array of node levels (1-10)
     * @return nextHarvestTimes Array of timestamps when harvest is available
     * @return maintenanceOverdue Array of whether maintenance is overdue
     * @return estimatedProductions Array of estimated resources per harvest
     * @return upgradeCostsZico Array of ZICO costs for next upgrade
     */
    function getEconomyNodesInfoBatch(uint256[] calldata nodeIds) external view returns (
        bool[] memory exists,
        uint256[] memory territoryIds,
        uint8[] memory resourceTypes,
        uint8[] memory nodeLevels,
        uint32[] memory nextHarvestTimes,
        bool[] memory maintenanceOverdue,
        uint256[] memory estimatedProductions,
        uint256[] memory upgradeCostsZico
    ) {
        uint256 length = nodeIds.length;

        exists = new bool[](length);
        territoryIds = new uint256[](length);
        resourceTypes = new uint8[](length);
        nodeLevels = new uint8[](length);
        nextHarvestTimes = new uint32[](length);
        maintenanceOverdue = new bool[](length);
        estimatedProductions = new uint256[](length);
        upgradeCostsZico = new uint256[](length);

        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();

        for (uint256 i = 0; i < length; i++) {
            LibColonyWarsStorage.ResourceNode storage node = cws.economyResourceNodes[nodeIds[i]];

            exists[i] = node.active;

            if (node.active) {
                territoryIds[i] = node.territoryId;
                resourceTypes[i] = uint8(node.resourceType);
                nodeLevels[i] = node.nodeLevel;

                // Safe arithmetic using unchecked
                unchecked {
                    // nextHarvestTime - safe overflow check
                    uint32 maxSafeHarvestTime = type(uint32).max - HARVEST_COOLDOWN;
                    if (node.lastHarvestTime <= maxSafeHarvestTime) {
                        nextHarvestTimes[i] = node.lastHarvestTime + HARVEST_COOLDOWN;
                    } else {
                        nextHarvestTimes[i] = type(uint32).max;
                    }

                    // maintenanceOverdue - safe overflow check
                    uint256 maxSafeMaintenanceTime = type(uint256).max - 1 days;
                    if (node.lastMaintenancePaid <= maxSafeMaintenanceTime) {
                        maintenanceOverdue[i] = block.timestamp > node.lastMaintenancePaid + 1 days;
                    } else {
                        maintenanceOverdue[i] = false;
                    }

                    // hoursSinceHarvest - safe underflow check
                    uint256 hoursSinceHarvest = 0;
                    if (node.lastHarvestTime > 0 && node.lastHarvestTime <= block.timestamp) {
                        hoursSinceHarvest = (block.timestamp - node.lastHarvestTime) / 1 hours;
                    }
                    uint256 production = uint256(BASE_PRODUCTION_RATE) * uint256(node.nodeLevel) * hoursSinceHarvest;

                    LibColonyWarsStorage.TerritoryEquipment storage equipment = cws.territoryEquipment[node.territoryId];
                    estimatedProductions[i] = (production * (100 + equipment.totalProductionBonus)) / 100;
                }

                // Upgrade cost (0 if already max level)
                if (node.nodeLevel < MAX_NODE_LEVEL) {
                    upgradeCostsZico[i] = uint256(node.nodeLevel) * NODE_UPGRADE_COST_MULTIPLIER;
                }
            }
        }
    }

    // ============================================================================
    // INTERNAL HELPERS - YLW Distribution
    // ============================================================================

    /**
     * @notice Distribute YLW reward with Treasury → Mint fallback
     * @dev Priority: 1) Transfer from treasury, 2) Mint if treasury insufficient
     * @param rewardToken YLW token address
     * @param recipient User receiving the reward
     * @param amount Amount to distribute
     */
    function _distributeYlwReward(
        address rewardToken,
        address recipient,
        uint256 amount
    ) internal {
        address treasury = ResourceHelper.getTreasuryAddress();
        
        // Check treasury balance and allowance
        uint256 treasuryBalance = IERC20(rewardToken).balanceOf(treasury);
        uint256 allowance = IERC20(rewardToken).allowance(treasury, address(this));
        
        if (treasuryBalance >= amount && allowance >= amount) {
            // Pay from treasury (preferred - sustainable)
            IERC20(rewardToken).safeTransferFrom(treasury, recipient, amount);
        } else if (treasuryBalance > 0 && allowance > 0) {
            // Partial from treasury, rest from mint
            uint256 fromTreasury = treasuryBalance < allowance ? treasuryBalance : allowance;
            IERC20(rewardToken).safeTransferFrom(treasury, recipient, fromTreasury);
            
            uint256 shortfall = amount - fromTreasury;
            IRewardToken(rewardToken).mint(recipient, shortfall, "harvest_reward");
        } else {
            // Fallback: Mint new tokens
            IRewardToken(rewardToken).mint(recipient, amount, "harvest_reward");
        }
    }

    // ============================================================================
    // RESOURCE CARD MINTING - PUBLIC SALE
    // ============================================================================

    // Rarity thresholds (out of 10000)
    uint256 private constant LEGENDARY_THRESHOLD = 100;   // 1%
    uint256 private constant EPIC_THRESHOLD = 600;        // 5%
    uint256 private constant RARE_THRESHOLD = 2100;       // 15%
    uint256 private constant UNCOMMON_THRESHOLD = 5100;   // 30%

    /**
     * @notice Mint Resource Card (public sale)
     * @param resourceType Resource type (0-3)
     * @return tokenId Minted token ID
     */
    function mintResourceCard(uint8 resourceType) external payable whenNotPaused nonReentrant returns (uint256 tokenId) {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();

        address resourceAddr = cws.cardContracts.resourceCards;
        if (resourceAddr == address(0)) revert ResourceCardsNotSet();
        if (resourceType > 3) revert InvalidResourceType();

        IColonyResourceCards resourceContract = IColonyResourceCards(resourceAddr);

        // Check supply
        if (resourceContract.totalSupply() >= resourceContract.maxSupply()) revert ResourceMaxSupplyReached();

        // Calculate price and collect payment (supports native/ERC20 with discount)
        uint256 price = _calculateResourcePrice(resourceType);
        ResourceHelper.collectCardMintFee(LibMeta.msgSender(), price, "resource_card_mint");

        // Calculate rarity
        uint8 rarity = _calculateResourceRarity(block.timestamp, resourceType, LibMeta.msgSender());

        // Mint to user
        tokenId = resourceContract.mintResource(
            LibMeta.msgSender(),
            IColonyResourceCards.ResourceType(resourceType),
            IColonyResourceCards.Rarity(rarity)
        );

        emit ResourceCardMinted(tokenId, LibMeta.msgSender(), resourceType, rarity);
    }

    /**
     * @notice Mint Resource Card and stake to node
     * @param resourceType Resource type (0-3)
     * @param nodeId Node to stake to
     * @return tokenId Minted token ID
     */
    function mintResourceCardFor(uint8 resourceType, uint256 nodeId) external payable whenNotPaused nonReentrant returns (uint256 tokenId) {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();

        address resourceAddr = cws.cardContracts.resourceCards;
        if (resourceAddr == address(0)) revert ResourceCardsNotSet();
        if (resourceType > 3) revert InvalidResourceType();

        // Verify node ownership
        LibColonyWarsStorage.ResourceNode storage node = cws.economyResourceNodes[nodeId];
        if (!node.active) revert ResourceNodeNotFound();

        LibColonyWarsStorage.Territory storage territory = cws.territories[node.territoryId];
        bytes32 colonyId = LibColonyWarsStorage.getUserPrimaryColony(LibMeta.msgSender());
        if (territory.controllingColony != colonyId) revert TerritoryNotControlled();

        IColonyResourceCards resourceContract = IColonyResourceCards(resourceAddr);

        // Check supply
        if (resourceContract.totalSupply() >= resourceContract.maxSupply()) revert ResourceMaxSupplyReached();

        // Calculate price and collect payment (supports native/ERC20 with discount)
        uint256 price = _calculateResourcePrice(resourceType);
        ResourceHelper.collectCardMintFee(LibMeta.msgSender(), price, "resource_card_mint_stake");

        // Calculate rarity
        uint8 rarity = _calculateResourceRarity(block.timestamp, resourceType, LibMeta.msgSender());

        // Mint to user
        tokenId = resourceContract.mintResource(
            LibMeta.msgSender(),
            IColonyResourceCards.ResourceType(resourceType),
            IColonyResourceCards.Rarity(rarity)
        );

        emit ResourceCardMinted(tokenId, LibMeta.msgSender(), resourceType, rarity);

        // Auto-stake to node
        resourceContract.stakeToNode(tokenId, nodeId);
    }

    /**
     * @notice Calculate mint price for resource type
     * @dev Uses configured price if set, otherwise falls back to defaults
     */
    function _calculateResourcePrice(uint8 resourceType) internal view returns (uint256) {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();

        // Use configured price if initialized
        if (cws.cardMintPricing.initialized && cws.cardMintPricing.resourcePrices[resourceType] > 0) {
            return cws.cardMintPricing.resourcePrices[resourceType];
        }

        // Fallback to defaults
        if (resourceType == 0) return 400 ether;   // BasicMaterials
        if (resourceType == 1) return 600 ether;   // EnergyCrystals
        if (resourceType == 2) return 800 ether;   // BioCompounds
        return 1200 ether;                          // RareElements
    }

    /**
     * @notice Calculate rarity based on pseudo-random seed
     */
    function _calculateResourceRarity(uint256 seed, uint8 itemType, address minter) internal view returns (uint8) {
        uint256 randomSeed = uint256(keccak256(abi.encodePacked(
            block.prevrandao,
            seed,
            minter,
            block.timestamp,
            itemType,
            block.number
        )));

        uint256 roll = randomSeed % 10000;

        if (roll < LEGENDARY_THRESHOLD) return 4;  // Legendary
        if (roll < EPIC_THRESHOLD) return 3;       // Epic
        if (roll < RARE_THRESHOLD) return 2;       // Rare
        if (roll < UNCOMMON_THRESHOLD) return 1;   // Uncommon
        return 0;                                   // Common
    }

    /**
     * @notice Get mint price for resource type
     */
    function getResourcePrice(uint8 resourceType) external view returns (uint256) {
        return _calculateResourcePrice(resourceType);
    }

    // ============================================================================
    // RESOURCE CARD COMBINING
    // ============================================================================

    // Events
    event ResourceCardsCombined(uint256[] burnedTokenIds, uint256 indexed newTokenId, address indexed owner);

    // Errors
    error InsufficientCardsForCombine();
    error CardsMustBeSameType();
    error CardNotOwned();
    error CardIsStaked();

    /**
     * @notice Combine multiple resource cards into one higher rarity card
     * @param tokenIds Array of resource card token IDs to combine (minimum 3)
     * @return newTokenId The newly minted combined card
     * @dev Burns input cards and mints one new card with higher rarity
     *      All cards must be same resource type and owned by caller
     */
    function combineResourceCards(uint256[] calldata tokenIds) external whenNotPaused nonReentrant returns (uint256 newTokenId) {
        if (tokenIds.length < 3) revert InsufficientCardsForCombine();

        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();

        address resourceAddr = cws.cardContracts.resourceCards;
        if (resourceAddr == address(0)) revert ResourceCardsNotSet();

        IColonyResourceCards resourceContract = IColonyResourceCards(resourceAddr);
        address caller = LibMeta.msgSender();

        // Validate all cards are owned by caller and same type
        IColonyResourceCards.ResourceTraits memory firstTraits = resourceContract.getTraits(tokenIds[0]);

        for (uint256 i = 0; i < tokenIds.length; i++) {
            // Check ownership
            if (resourceContract.ownerOf(tokenIds[i]) != caller) revert CardNotOwned();

            // Check not staked
            if (resourceContract.isStaked(tokenIds[i])) revert CardIsStaked();

            // Check same resource type
            if (i > 0) {
                IColonyResourceCards.ResourceTraits memory traits = resourceContract.getTraits(tokenIds[i]);
                if (traits.resourceType != firstTraits.resourceType) revert CardsMustBeSameType();
            }
        }

        // Call combine on NFT contract (burns old cards, mints new one)
        newTokenId = resourceContract.combineResources(tokenIds);

        emit ResourceCardsCombined(tokenIds, newTokenId, caller);
    }

    /**
     * @notice Get number of cards needed to combine for next rarity
     * @param currentRarity Current card rarity (0-4)
     * @return cardsNeeded Number of cards required to combine
     */
    function getCardsNeededForCombine(uint8 currentRarity) external pure returns (uint8 cardsNeeded) {
        // Cannot combine Legendary cards
        if (currentRarity >= 4) return 0;

        // 3 cards of same rarity combine into 1 of next rarity
        return 3;
    }

    /**
     * @notice Check if cards can be combined
     * @param tokenIds Array of token IDs to check
     * @return canCombine Whether combination is possible
     * @return reason Description if cannot combine
     */
    function canCombineCards(uint256[] calldata tokenIds) external view returns (bool canCombine, string memory reason) {
        if (tokenIds.length < 3) return (false, "Need at least 3 cards");

        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();

        address resourceAddr = cws.cardContracts.resourceCards;
        if (resourceAddr == address(0)) return (false, "Resource cards not configured");

        IColonyResourceCards resourceContract = IColonyResourceCards(resourceAddr);
        address caller = LibMeta.msgSender();

        IColonyResourceCards.ResourceTraits memory firstTraits = resourceContract.getTraits(tokenIds[0]);

        // Check Legendary cannot be combined
        if (uint8(firstTraits.rarity) >= 4) return (false, "Cannot combine Legendary cards");

        for (uint256 i = 0; i < tokenIds.length; i++) {
            if (resourceContract.ownerOf(tokenIds[i]) != caller) return (false, "Card not owned");
            if (resourceContract.isStaked(tokenIds[i])) return (false, "Card is staked");

            if (i > 0) {
                IColonyResourceCards.ResourceTraits memory traits = resourceContract.getTraits(tokenIds[i]);
                if (traits.resourceType != firstTraits.resourceType) return (false, "Cards must be same type");
                if (traits.rarity != firstTraits.rarity) return (false, "Cards must be same rarity");
            }
        }

        return (true, "");
    }

    /**
     * @notice Get all economy nodes for a colony
     * @param colonyId Colony ID
     * @return nodeIds Array of node IDs belonging to colony
     * @return nodes Array of node data
     */
    function getColonyEconomyNodes(bytes32 colonyId) external view returns (
        uint256[] memory nodeIds,
        LibColonyWarsStorage.ResourceNode[] memory nodes
    ) {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        uint256[] memory controlled = cws.colonyTerritories[colonyId];

        // Count nodes on colony territories
        uint256 count = 0;
        for (uint256 i = 1; i <= cws.economyNodeCounter; i++) {
            LibColonyWarsStorage.ResourceNode storage node = cws.economyResourceNodes[i];
            if (node.active) {
                for (uint256 j = 0; j < controlled.length; j++) {
                    if (node.territoryId == controlled[j]) {
                        count++;
                        break;
                    }
                }
            }
        }

        nodeIds = new uint256[](count);
        nodes = new LibColonyWarsStorage.ResourceNode[](count);

        uint256 index = 0;
        for (uint256 i = 1; i <= cws.economyNodeCounter && index < count; i++) {
            LibColonyWarsStorage.ResourceNode storage node = cws.economyResourceNodes[i];
            if (node.active) {
                for (uint256 j = 0; j < controlled.length; j++) {
                    if (node.territoryId == controlled[j]) {
                        nodeIds[index] = i;
                        nodes[index] = node;
                        index++;
                        break;
                    }
                }
            }
        }
    }

    // ==================== MIGRATION ====================

    event NodesMigrated(uint256[] ids, bool toEconomy, uint256 migratedCount);

    /**
     * @notice Migrate nodes from old resourceNodes mapping to new mappings
     * @dev ADMIN ONLY - One-time migration from resourceNodes to economyResourceNodes or territoryResourceNodes
     * @param ids Array of IDs to migrate
     * @param toEconomy True = economyResourceNodes, False = territoryResourceNodes
     * @return migratedCount Number of nodes migrated
     */
    function migrateNodes(uint256[] calldata ids, bool toEconomy) external onlyAuthorized returns (uint256 migratedCount) {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();

        for (uint256 i = 0; i < ids.length; i++) {
            uint256 id = ids[i];
            LibColonyWarsStorage.ResourceNode storage oldNode = cws.resourceNodes[id];

            // Skip empty nodes
            if (oldNode.territoryId == 0 && oldNode.nodeLevel == 0 && !oldNode.active) {
                continue;
            }

            LibColonyWarsStorage.ResourceNode storage newNode = toEconomy
                ? cws.economyResourceNodes[id]
                : cws.territoryResourceNodes[id];

            // Skip already migrated
            if (newNode.active) continue;

            // Copy data
            newNode.territoryId = oldNode.territoryId != 0 ? oldNode.territoryId : id;
            newNode.resourceType = oldNode.resourceType;
            newNode.nodeLevel = oldNode.nodeLevel;
            newNode.accumulatedResources = oldNode.accumulatedResources;
            newNode.lastHarvestTime = oldNode.lastHarvestTime;
            newNode.lastMaintenancePaid = oldNode.lastMaintenancePaid;
            newNode.active = oldNode.active;

            // Update counter for economy nodes
            if (toEconomy && id > cws.economyNodeCounter) {
                cws.economyNodeCounter = id;
            }

            migratedCount++;
        }

        emit NodesMigrated(ids, toEconomy, migratedCount);
    }

    // ============================================================================
    // NODE REMOVAL
    // ============================================================================

    /**
     * @notice Remove economy resource node (owner action)
     * @param nodeId Node ID to remove
     * @dev Requires territory control. Unharvested resources are lost.
     *      Use harvestResources() before removing to collect pending resources and YLW rewards.
     */
    function removeEconomyNode(uint256 nodeId) external whenNotPaused nonReentrant {
        LibColonyWarsStorage.requireInitialized();

        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        LibColonyWarsStorage.ResourceNode storage node = cws.economyResourceNodes[nodeId];

        if (!node.active) revert ResourceNodeNotFound();

        // Verify territory ownership
        LibColonyWarsStorage.Territory storage territory = cws.territories[node.territoryId];
        bytes32 colonyId = LibColonyWarsStorage.getUserPrimaryColony(LibMeta.msgSender());

        if (territory.controllingColony != colonyId) revert TerritoryNotControlled();

        // Verify colony ownership
        if (!ColonyHelper.isColonyCreator(colonyId, hs.stakingSystemAddress)) {
            revert TerritoryNotControlled();
        }

        // Store for event
        uint8 nodeLevel = node.nodeLevel;
        uint256 territoryId = node.territoryId;
        uint256 unharvestedResources = _calculatePendingEconomyResources(node);

        // Deactivate node
        node.active = false;
        node.nodeLevel = 0;
        node.accumulatedResources = 0;
        node.lastHarvestTime = 0;
        node.lastMaintenancePaid = 0;
        node.territoryId = 0;

        emit EconomyNodeRemoved(nodeId, territoryId, colonyId, nodeLevel, unharvestedResources);
    }

    /**
     * @notice Admin force remove economy node (emergency use)
     * @param nodeId Node ID to remove
     * @param reason Reason for forced removal (for audit trail)
     * @dev ADMIN ONLY. Use for stuck nodes, exploits, or maintenance.
     */
    function forceRemoveEconomyNode(
        uint256 nodeId,
        string calldata reason
    ) external onlyAuthorized {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibColonyWarsStorage.ResourceNode storage node = cws.economyResourceNodes[nodeId];

        if (!node.active) revert ResourceNodeNotFound();

        // Deactivate node
        node.active = false;
        node.nodeLevel = 0;
        node.accumulatedResources = 0;
        node.lastHarvestTime = 0;
        node.lastMaintenancePaid = 0;
        node.territoryId = 0;

        emit EconomyNodeForceRemoved(nodeId, LibMeta.msgSender(), reason);
    }

    /**
     * @notice Check if economy node can be removed and get removal info
     * @param nodeId Node ID
     * @return canRemove Whether node can be removed
     * @return territoryId Territory where node is placed
     * @return nodeLevel Current node level (0 if no node)
     * @return pendingResources Resources that would be lost
     * @return pendingYlwReward YLW reward that would be lost
     */
    function getEconomyNodeRemovalInfo(uint256 nodeId) external view returns (
        bool canRemove,
        uint256 territoryId,
        uint8 nodeLevel,
        uint256 pendingResources,
        uint256 pendingYlwReward
    ) {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibColonyWarsStorage.ResourceNode storage node = cws.economyResourceNodes[nodeId];

        if (!node.active) {
            return (false, 0, 0, 0, 0);
        }

        canRemove = true;
        territoryId = node.territoryId;
        nodeLevel = node.nodeLevel;
        pendingResources = _calculatePendingEconomyResources(node);
        pendingYlwReward = TOKEN_HARVEST_REWARD_BASE + (uint256(node.nodeLevel) * 1 ether);
    }

    /**
     * @notice Calculate pending resources for an economy node
     * @param node Resource node storage reference
     * @return pending Pending unharvested resources
     */
    function _calculatePendingEconomyResources(
        LibColonyWarsStorage.ResourceNode storage node
    ) internal view returns (uint256 pending) {
        if (!node.active) return 0;

        uint256 hoursSinceHarvest = (block.timestamp - node.lastHarvestTime) / 1 hours;
        pending = BASE_PRODUCTION_RATE * node.nodeLevel * hoursSinceHarvest;
    }

    // ============================================================================
    // RESOURCE-BASED CARD CRAFTING
    // ============================================================================

    event ResourceCardCrafted(
        uint256 indexed tokenId,
        address indexed crafter,
        uint8 resourceType,
        uint256 resourcesConsumed,
        uint8 rarity
    );

    error CardCraftingNotEnabled();
    error InsufficientResourcesForCrafting(uint8 resourceType, uint256 required, uint256 available);
    error CraftingCooldownActive(uint32 remainingSeconds);
    error CraftingAmountBelowMinimum(uint256 provided, uint256 minimum);

    /**
     * @notice Craft Resource Card NFT by consuming game resources
     * @dev RESOURCE SINK: Major sink for accumulated resources
     *      Tiers (default):
     *      - 5,000 resources = Common guaranteed
     *      - 10,000 resources = up to Uncommon
     *      - 25,000 resources = up to Rare
     *      - 50,000 resources = up to Epic
     *      - 100,000 resources = chance at Legendary
     * @param resourceType Type of resource to consume (0-3)
     * @param amount Amount of resources to use
     * @return tokenId Minted card token ID
     * @return rarity Achieved rarity (0-4)
     */
    function craftResourceCardFromResources(
        uint8 resourceType,
        uint256 amount
    ) external whenNotPaused nonReentrant returns (uint256 tokenId, uint8 rarity) {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        LibResourceStorage.CardCraftingConfig storage config = rs.cardCraftingConfig;

        // Check if enabled
        if (!config.enabled) revert CardCraftingNotEnabled();

        // Check minimum amount
        if (amount < config.minResourceAmount) {
            revert CraftingAmountBelowMinimum(amount, config.minResourceAmount);
        }

        // Validate resource type
        if (resourceType > 3) revert InvalidResourceType();

        address user = LibMeta.msgSender();

        // Check cooldown
        uint32 lastCraft = rs.lastResourceCraftTime[user];
        if (lastCraft > 0 && block.timestamp < lastCraft + config.cooldownSeconds) {
            uint32 remaining = (lastCraft + config.cooldownSeconds) - uint32(block.timestamp);
            revert CraftingCooldownActive(remaining);
        }

        // Apply decay before checking balance
        LibResourceStorage.applyResourceDecay(user);

        // Check user has enough resources
        uint256 available = rs.userResources[user][resourceType];
        if (available < amount) {
            revert InsufficientResourcesForCrafting(resourceType, amount, available);
        }

        // Determine max achievable rarity based on amount
        uint8 maxRarity = _getCraftingMaxRarity(amount, rs);

        // Calculate rarity with randomness
        rarity = _calculateCraftingRarity(amount, maxRarity, user, resourceType);

        // Consume resources
        rs.userResources[user][resourceType] -= amount;

        // Update cooldown
        rs.lastResourceCraftTime[user] = uint32(block.timestamp);

        // Mint the card
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        address resourceAddr = cws.cardContracts.resourceCards;
        if (resourceAddr == address(0)) revert ResourceCardsNotSet();

        IColonyResourceCards resourceContract = IColonyResourceCards(resourceAddr);

        // Check supply
        if (resourceContract.totalSupply() >= resourceContract.maxSupply()) revert ResourceMaxSupplyReached();

        // Mint to user
        tokenId = resourceContract.mintResource(
            user,
            IColonyResourceCards.ResourceType(resourceType),
            IColonyResourceCards.Rarity(rarity)
        );

        // Update stats
        rs.totalCardsCrafted++;
        rs.totalResourcesConsumedByBoosts += amount;

        emit ResourceCardCrafted(tokenId, user, resourceType, amount, rarity);
    }

    /**
     * @notice Get max achievable rarity based on resource amount
     */
    function _getCraftingMaxRarity(
        uint256 amount,
        LibResourceStorage.ResourceStorage storage rs
    ) internal view returns (uint8 maxRarity) {
        // Check tiers from highest to lowest
        for (uint8 i = 4; i > 0; i--) {
            if (rs.craftingTiers[i].resourceAmount > 0 && amount >= rs.craftingTiers[i].resourceAmount) {
                return rs.craftingTiers[i].maxRarity;
            }
        }
        // Default to Common if below all tiers or tiers not set
        return 0;
    }

    /**
     * @notice Calculate crafting rarity with randomness
     */
    function _calculateCraftingRarity(
        uint256 amount,
        uint8 maxRarity,
        address user,
        uint8 resourceType
    ) internal view returns (uint8 rarity) {
        // Generate pseudo-random value
        uint256 random = uint256(keccak256(abi.encodePacked(
            block.timestamp,
            block.prevrandao,
            user,
            resourceType,
            amount
        ))) % 10000;

        // Base chances (out of 10000):
        // Common: guaranteed base
        // Higher rarities scale with amount spent
        // More resources = better chance at higher rarity

        if (maxRarity == 0) return 0; // Only Common possible

        // Scale chances based on amount
        // Using similar thresholds to mintResourceCard but affected by amount
        uint256 scaleFactor = amount / 1000; // Scale factor based on resources
        if (scaleFactor > 100) scaleFactor = 100; // Cap at 100

        if (maxRarity >= 4 && random < (LEGENDARY_THRESHOLD * scaleFactor / 10)) {
            return 4; // Legendary
        }
        if (maxRarity >= 3 && random < (EPIC_THRESHOLD * scaleFactor / 10)) {
            return 3; // Epic
        }
        if (maxRarity >= 2 && random < (RARE_THRESHOLD * scaleFactor / 10)) {
            return 2; // Rare
        }
        if (maxRarity >= 1 && random < (UNCOMMON_THRESHOLD * scaleFactor / 10)) {
            return 1; // Uncommon
        }
        return 0; // Common
    }

    /**
     * @notice Preview card crafting
     * @param user User address
     * @param resourceType Resource type to use
     * @param amount Amount to spend
     * @return canCraft Whether crafting is possible
     * @return reason Failure reason
     * @return maxRarity Maximum achievable rarity
     * @return cooldownRemaining Seconds until cooldown ends
     */
    function previewCardCrafting(
        address user,
        uint8 resourceType,
        uint256 amount
    ) external view returns (
        bool canCraft,
        string memory reason,
        uint8 maxRarity,
        uint32 cooldownRemaining
    ) {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        LibResourceStorage.CardCraftingConfig storage config = rs.cardCraftingConfig;

        if (!config.enabled) {
            return (false, "Card crafting not enabled", 0, 0);
        }

        if (resourceType > 3) {
            return (false, "Invalid resource type", 0, 0);
        }

        if (amount < config.minResourceAmount) {
            return (false, "Amount below minimum", 0, 0);
        }

        // Check cooldown
        uint32 lastCraft = rs.lastResourceCraftTime[user];
        if (lastCraft > 0 && block.timestamp < lastCraft + config.cooldownSeconds) {
            cooldownRemaining = (lastCraft + config.cooldownSeconds) - uint32(block.timestamp);
            return (false, "Cooldown active", 0, cooldownRemaining);
        }

        // Check resources
        uint256 available = rs.userResources[user][resourceType];
        if (available < amount) {
            return (false, "Insufficient resources", 0, 0);
        }

        // Check supply
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        address resourceAddr = cws.cardContracts.resourceCards;
        if (resourceAddr == address(0)) {
            return (false, "Resource cards not configured", 0, 0);
        }

        IColonyResourceCards resourceContract = IColonyResourceCards(resourceAddr);
        if (resourceContract.totalSupply() >= resourceContract.maxSupply()) {
            return (false, "Max supply reached", 0, 0);
        }

        maxRarity = _getCraftingMaxRarity(amount, rs);
        canCraft = true;
        reason = "";
    }

    /**
     * @notice Get card crafting configuration
     */
    function getCardCraftingConfig() external view returns (
        uint32 cooldownSeconds,
        uint256 minResourceAmount,
        bool enabled
    ) {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        return (
            rs.cardCraftingConfig.cooldownSeconds,
            rs.cardCraftingConfig.minResourceAmount,
            rs.cardCraftingConfig.enabled
        );
    }

    /**
     * @notice Get crafting tier thresholds
     * @return tierAmounts Array of resource amounts for each tier
     * @return tierMaxRarities Array of max rarities for each tier
     */
    function getCraftingTiers() external view returns (
        uint256[5] memory tierAmounts,
        uint8[5] memory tierMaxRarities
    ) {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        for (uint8 i = 0; i < 5; i++) {
            tierAmounts[i] = rs.craftingTiers[i].resourceAmount;
            tierMaxRarities[i] = rs.craftingTiers[i].maxRarity;
        }
    }

    /**
     * @notice Configure card crafting (ADMIN ONLY)
     */
    function configureCardCrafting(
        uint32 cooldownSeconds,
        uint256 minResourceAmount,
        bool enabled
    ) external onlyAuthorized {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        rs.cardCraftingConfig = LibResourceStorage.CardCraftingConfig({
            cooldownSeconds: cooldownSeconds,
            minResourceAmount: minResourceAmount,
            enabled: enabled
        });
    }

    /**
     * @notice Set crafting tier (ADMIN ONLY)
     * @param tierIndex Tier index (0-4)
     * @param resourceAmount Resources needed for this tier
     * @param maxRarity Max achievable rarity (0-4)
     * @param rarityBoostBps Bonus chance for higher rarity
     */
    function setCraftingTier(
        uint8 tierIndex,
        uint256 resourceAmount,
        uint8 maxRarity,
        uint16 rarityBoostBps
    ) external onlyAuthorized {
        require(tierIndex <= 4, "Invalid tier index");
        require(maxRarity <= 4, "Invalid max rarity");

        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        rs.craftingTiers[tierIndex] = LibResourceStorage.CardCraftingTier({
            resourceAmount: resourceAmount,
            maxRarity: maxRarity,
            rarityBoostBps: rarityBoostBps
        });
    }

    /**
     * @notice Initialize default crafting tiers (ADMIN ONLY)
     * @dev Sets default tier thresholds:
     *      - Tier 0: 5,000 → Common
     *      - Tier 1: 10,000 → Uncommon
     *      - Tier 2: 25,000 → Rare
     *      - Tier 3: 50,000 → Epic
     *      - Tier 4: 100,000 → Legendary
     */
    function initializeCraftingTiers() external onlyAuthorized {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();

        rs.craftingTiers[0] = LibResourceStorage.CardCraftingTier({
            resourceAmount: 5000 ether,
            maxRarity: 0,
            rarityBoostBps: 0
        });
        rs.craftingTiers[1] = LibResourceStorage.CardCraftingTier({
            resourceAmount: 10000 ether,
            maxRarity: 1,
            rarityBoostBps: 1000
        });
        rs.craftingTiers[2] = LibResourceStorage.CardCraftingTier({
            resourceAmount: 25000 ether,
            maxRarity: 2,
            rarityBoostBps: 1500
        });
        rs.craftingTiers[3] = LibResourceStorage.CardCraftingTier({
            resourceAmount: 50000 ether,
            maxRarity: 3,
            rarityBoostBps: 2000
        });
        rs.craftingTiers[4] = LibResourceStorage.CardCraftingTier({
            resourceAmount: 100000 ether,
            maxRarity: 4,
            rarityBoostBps: 2500
        });

        // Also set default config
        rs.cardCraftingConfig = LibResourceStorage.CardCraftingConfig({
            cooldownSeconds: 6 hours,
            minResourceAmount: 5000 ether,
            enabled: true
        });
    }
}
