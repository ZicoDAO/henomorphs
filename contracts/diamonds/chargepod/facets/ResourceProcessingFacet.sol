// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibMeta} from "../../shared/libraries/LibMeta.sol";
import {LibHenomorphsStorage} from "../libraries/LibHenomorphsStorage.sol";
import {LibColonyWarsStorage} from "../libraries/LibColonyWarsStorage.sol";
import {LibFeeCollection} from "../../staking/libraries/LibFeeCollection.sol";
import {ResourceHelper} from "../libraries/ResourceHelper.sol";
import {AccessControlBase} from "../../common/facets/AccessControlBase.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title ResourceProcessingFacet
 * @notice Handles resource processing and refining
 * @dev Converts basic resources into advanced materials
 */
contract ResourceProcessingFacet is AccessControlBase {
    using LibColonyWarsStorage for LibColonyWarsStorage.ColonyWarsStorage;

    // Custom Errors
    error RecipeNotFound();
    error InsufficientResources();
    error InsufficientYLW();
    error InsufficientTechLevel();
    error ProcessingNotComplete();
    error OrderAlreadyClaimed();
    error OrderNotFound();
    error InvalidConversionRatio();

    // Events
    event RecipeCreated(uint8 indexed recipeId, uint256 ylwCost, uint32 processingTime);
    event ProcessingStarted(
        bytes32 indexed orderId,
        bytes32 indexed colonyId,
        uint8 recipeId,
        uint256 inputAmount,
        uint32 completionTime
    );
    event ProcessingCompleted(bytes32 indexed orderId, bytes32 indexed colonyId, uint256 outputAmount);
    event ProcessingCancelled(
        bytes32 indexed orderId,
        bytes32 indexed colonyId,
        address indexed canceller,
        uint256 resourcesReturned
    );
    event ResourcesProcessed(
        bytes32 indexed colonyId,
        LibColonyWarsStorage.ResourceType inputType,
        LibColonyWarsStorage.ResourceType outputType,
        uint256 inputAmount,
        uint256 outputAmount
    );

    /**
     * @notice Start processing order
     * @param recipeId Recipe to use (0-based)
     * @param inputAmount Amount of input resources
     */
    function startProcessing(uint8 recipeId, uint256 inputAmount) external whenNotPaused nonReentrant returns (bytes32 orderId) {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        
        address caller = LibMeta.msgSender();
        bytes32 colonyId = LibColonyWarsStorage.getUserPrimaryColony(caller);
        require(colonyId != bytes32(0), "No colony");
        
        // Get recipe
        LibColonyWarsStorage.ProcessingRecipe storage recipe = cws.processingRecipes[recipeId];
        if (!recipe.active) revert RecipeNotFound();

        // Check tech level requirement
        if (recipe.requiredTechLevel > 0) {
            uint8 colonyTechLevel = _getColonyTechLevel(colonyId, cws);
            if (colonyTechLevel < recipe.requiredTechLevel) {
                revert InsufficientTechLevel();
            }
        }

        // Calculate costs
        uint256 totalInputNeeded = recipe.inputAmount * (inputAmount / recipe.outputAmount);
        
        // Verify and deduct resources using ResourceHelper
        LibColonyWarsStorage.ResourceBalance storage balance = cws.colonyResources[colonyId];
        ResourceHelper.requireAndDeduct(balance, recipe.inputType, totalInputNeeded);

        // Pay configured processing fee (uses YELLOW token with burn)
        LibColonyWarsStorage.OperationFee storage processingFee = LibColonyWarsStorage.getOperationFee(LibColonyWarsStorage.FEE_PROCESSING);
        if (processingFee.enabled) {
            LibFeeCollection.processConfiguredFee(
                processingFee,
                LibMeta.msgSender(),
                "resource_processing"
            );
        }

        // Create processing order
        orderId = keccak256(abi.encodePacked(colonyId, recipeId, block.timestamp, ++cws.processingOrderCounter));
        LibColonyWarsStorage.ProcessingOrder storage order = cws.processingOrders[orderId];
        order.colonyId = colonyId;
        order.recipeId = recipeId;
        order.inputAmount = inputAmount;
        order.startTime = uint32(block.timestamp);
        order.completionTime = uint32(block.timestamp + recipe.processingTime);
        order.completed = false;
        order.claimed = false;

        // Track order for UI/user queries
        cws.colonyProcessingOrders[colonyId].push(orderId);

        emit ProcessingStarted(orderId, colonyId, recipeId, inputAmount, order.completionTime);

        return orderId;
    }

    /**
     * @notice Complete and claim processing order
     * @param orderId Order to complete
     */
    function completeProcessing(bytes32 orderId) external whenNotPaused nonReentrant {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibColonyWarsStorage.ProcessingOrder storage order = cws.processingOrders[orderId];
        
        if (order.colonyId == bytes32(0)) revert OrderNotFound();
        if (order.claimed) revert OrderAlreadyClaimed();
        
        // Verify caller is colony owner
        address caller = LibMeta.msgSender();
        bytes32 colonyId = LibColonyWarsStorage.getUserPrimaryColony(caller);
        require(order.colonyId == colonyId, "Not your order");
        
        // Check if processing complete
        if (block.timestamp < order.completionTime) revert ProcessingNotComplete();
        
        // Get recipe
        LibColonyWarsStorage.ProcessingRecipe storage recipe = cws.processingRecipes[order.recipeId];
        
        // Calculate output
        uint256 outputAmount = (order.inputAmount / recipe.inputAmount) * recipe.outputAmount;
        
        // Add output resources to colony using ResourceHelper
        LibColonyWarsStorage.ResourceBalance storage balance = cws.colonyResources[colonyId];
        ResourceHelper.addResources(balance, recipe.outputType, outputAmount);
        
        // Mark as claimed
        order.completed = true;
        order.claimed = true;
        
        emit ProcessingCompleted(orderId, colonyId, outputAmount);
        emit ResourcesProcessed(colonyId, recipe.inputType, recipe.outputType, order.inputAmount, outputAmount);
    }

    /**
     * @notice Get processing order info
     * @param orderId Order to query
     * @return Processing order struct
     */
    function getProcessingOrder(bytes32 orderId) 
        external 
        view 
        returns (LibColonyWarsStorage.ProcessingOrder memory) 
    {
        return LibColonyWarsStorage.colonyWarsStorage().processingOrders[orderId];
    }

    /**
     * @notice Get recipe info
     * @param recipeId Recipe to query
     * @return Processing recipe struct
     */
    function getProcessingRecipe(uint8 recipeId) 
        external 
        view 
        returns (LibColonyWarsStorage.ProcessingRecipe memory) 
    {
        return LibColonyWarsStorage.colonyWarsStorage().processingRecipes[recipeId];
    }

    /**
     * @notice Admin: Create or update processing recipe
     * @param recipeId Recipe ID
     * @param inputType Input resource type
     * @param outputType Output resource type
     * @param inputAmount Input amount required
     * @param outputAmount Output amount produced
     * @param auxCost Auxiliary cost for processing
     * @param processingTime Time required in seconds
     * @param requiredTechLevel Minimum tech level
     */
    function setProcessingRecipe(
        uint8 recipeId,
        LibColonyWarsStorage.ResourceType inputType,
        LibColonyWarsStorage.ResourceType outputType,
        uint256 inputAmount,
        uint256 outputAmount,
        uint256 auxCost,
        uint32 processingTime,
        uint8 requiredTechLevel
    ) external onlyAuthorized {
        // Minimal validation: output cannot exceed input (prevents resource multiplication)
        if (outputAmount > inputAmount) {
            revert InvalidConversionRatio();
        }

        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibColonyWarsStorage.ProcessingRecipe storage recipe = cws.processingRecipes[recipeId];

        recipe.recipeId = recipeId;
        recipe.inputType = inputType;
        recipe.outputType = outputType;
        recipe.inputAmount = inputAmount;
        recipe.outputAmount = outputAmount;
        recipe.auxCost = auxCost;
        recipe.processingTime = processingTime;
        recipe.requiredTechLevel = requiredTechLevel;
        recipe.active = true;

        emit RecipeCreated(recipeId, auxCost, processingTime);
    }

    /**
     * @notice Get all active processing recipes
     * @return recipeIds Array of active recipe IDs
     * @return recipes Array of recipe details
     */
    function getAllProcessingRecipes() external view returns (
        uint8[] memory recipeIds,
        LibColonyWarsStorage.ProcessingRecipe[] memory recipes
    ) {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();

        // Count active recipes
        uint256 count = 0;
        for (uint8 i = 0; i < 255; i++) {
            if (cws.processingRecipes[i].active) {
                count++;
            }
        }

        // Populate arrays
        recipeIds = new uint8[](count);
        recipes = new LibColonyWarsStorage.ProcessingRecipe[](count);

        uint256 index = 0;
        for (uint8 i = 0; i < 255; i++) {
            if (cws.processingRecipes[i].active) {
                recipeIds[index] = i;
                recipes[index] = cws.processingRecipes[i];
                index++;
            }
        }

        return (recipeIds, recipes);
    }

    /**
     * @notice Get user's processing orders
     * @param user User address
     * @return orderIds Array of order IDs
     * @return orders Array of order details
     */
    function getUserProcessingOrders(address user) external view returns (
        bytes32[] memory orderIds,
        LibColonyWarsStorage.ProcessingOrder[] memory orders
    ) {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();

        // Get user's colony
        bytes32 colonyId = LibColonyWarsStorage.getUserPrimaryColony(user);
        if (colonyId == bytes32(0)) {
            return (new bytes32[](0), new LibColonyWarsStorage.ProcessingOrder[](0));
        }

        bytes32[] storage colonyOrders = cws.colonyProcessingOrders[colonyId];

        // Count active (non-claimed) orders
        uint256 count = 0;
        for (uint256 i = 0; i < colonyOrders.length; i++) {
            LibColonyWarsStorage.ProcessingOrder storage order = cws.processingOrders[colonyOrders[i]];
            if (!order.claimed) {
                count++;
            }
        }

        // Populate arrays
        orderIds = new bytes32[](count);
        orders = new LibColonyWarsStorage.ProcessingOrder[](count);

        uint256 index = 0;
        for (uint256 i = 0; i < colonyOrders.length; i++) {
            bytes32 orderId = colonyOrders[i];
            LibColonyWarsStorage.ProcessingOrder storage order = cws.processingOrders[orderId];
            if (!order.claimed) {
                orderIds[index] = orderId;
                orders[index] = order;
                index++;
            }
        }

        return (orderIds, orders);
    }

    /**
     * @notice Cancel active processing order and return resources
     * @param orderId Order to cancel
     */
    function cancelProcessingOrder(bytes32 orderId) external whenNotPaused nonReentrant {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibColonyWarsStorage.ProcessingOrder storage order = cws.processingOrders[orderId];

        if (order.colonyId == bytes32(0)) revert OrderNotFound();
        if (order.claimed) revert OrderAlreadyClaimed();

        // Verify caller is colony owner
        address caller = LibMeta.msgSender();
        bytes32 colonyId = LibColonyWarsStorage.getUserPrimaryColony(caller);
        require(order.colonyId == colonyId, "Not your order");

        // Get recipe to calculate resources to return
        LibColonyWarsStorage.ProcessingRecipe storage recipe = cws.processingRecipes[order.recipeId];

        // Calculate input resources used
        uint256 totalInputNeeded = recipe.inputAmount * (order.inputAmount / recipe.outputAmount);

        // Return resources to colony using ResourceHelper
        LibColonyWarsStorage.ResourceBalance storage balance = cws.colonyResources[colonyId];
        ResourceHelper.addResources(balance, recipe.inputType, totalInputNeeded);

        // Mark as claimed to prevent completeProcessing()
        order.claimed = true;

        emit ProcessingCancelled(orderId, colonyId, caller, totalInputNeeded);
    }

    // ==================== VIEW FUNCTIONS ====================

    /**
     * @notice Get colony's effective tech level (max across all territories)
     * @param colonyId Colony to check
     * @return techLevel Maximum tech bonus from colony's territories
     */
    function getColonyTechLevel(bytes32 colonyId) external view returns (uint8 techLevel) {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        return _getColonyTechLevel(colonyId, cws);
    }

    // ==================== INTERNAL HELPERS ====================

    /**
     * @dev Internal helper to get colony tech level
     */
    function _getColonyTechLevel(
        bytes32 colonyId,
        LibColonyWarsStorage.ColonyWarsStorage storage cws
    ) private view returns (uint8 techLevel) {
        uint256[] storage territoryIds = cws.colonyTerritories[colonyId];

        for (uint256 i = 0; i < territoryIds.length; i++) {
            LibColonyWarsStorage.TerritoryEquipment storage equipment = cws.territoryEquipment[territoryIds[i]];
            if (equipment.totalTechBonus > techLevel) {
                techLevel = equipment.totalTechBonus;
            }
        }

        return techLevel;
    }
}
