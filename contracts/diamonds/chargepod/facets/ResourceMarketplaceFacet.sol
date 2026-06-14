// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibMeta} from "../../shared/libraries/LibMeta.sol";
import {LibResourceStorage} from "../libraries/LibResourceStorage.sol";
import {LibMarketplaceStorage} from "../libraries/LibMarketplaceStorage.sol";
import {LibBuildingsStorage} from "../libraries/LibBuildingsStorage.sol";
import {LibColonyWarsStorage} from "../libraries/LibColonyWarsStorage.sol";
import {AccessControlBase} from "../../common/facets/AccessControlBase.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title ResourceMarketplaceFacet
 * @notice P2P marketplace for resource trading between colonies
 * @dev Implements order book trading with utility token (YLW) settlement.
 *      Storage is in LibMarketplaceStorage (Diamond pattern).
 *
 *      Audit fixes applied:
 *      - BUG-1: resourceType validation (must be 0-3)
 *      - BUG-2: Trade Hub marketFeeReductionBps applied to fees
 *      - BUG-3: Monotonic nonce prevents order ID collisions
 *      - BUG-4: activeOrderIds compacted via swap-and-pop on fill/cancel/cleanup
 *      - ISSUE-6: Decay applied before returning resources on cancel/cleanup
 *      - ISSUE-8: Max 20 active orders per user
 *
 * @author rutilicus.eth (ArchXS)
 */
contract ResourceMarketplaceFacet is AccessControlBase {
    using SafeERC20 for IERC20;

    // ==================== EVENTS ====================

    event OrderCreated(bytes32 indexed orderId, address indexed seller, uint8 resourceType, uint256 amount, uint256 pricePerUnit);
    event OrderCancelled(bytes32 indexed orderId, address indexed seller);
    event OrderFilled(bytes32 indexed orderId, address indexed buyer, address indexed seller, uint256 amount, uint256 totalPrice);
    event OrderPartiallyFilled(bytes32 indexed orderId, address indexed buyer, uint256 amountFilled, uint256 amountRemaining);

    // ==================== ERRORS ====================

    error OrderNotFound(bytes32 orderId);
    error OrderExpired(bytes32 orderId);
    error OrderInactive(bytes32 orderId);
    error InsufficientResources(uint8 resourceType, uint256 required, uint256 available);
    error InsufficientPayment(uint256 required, uint256 provided);
    error InvalidAmount(uint256 amount);
    error InvalidPrice(uint256 price);
    error UnauthorizedCancellation(address caller, address seller);
    error SelfTrade(address user);
    error InvalidResourceType(uint8 resourceType);
    error MaxActiveOrdersReached(address user, uint8 maxOrders);

    // ==================== CONSTANTS ====================

    uint16 constant BASE_MARKET_FEE_BPS = 200;    // 2% base fee (reduced by Trade Hub)
    uint32 constant MAX_ORDER_DURATION = 7 days;
    uint8 constant MAX_ACTIVE_ORDERS_PER_USER = 20;

    // ==================== ORDER MANAGEMENT ====================

    /**
     * @notice List resources for sale on the marketplace
     * @param resourceType Type of resource to sell (0=Basic, 1=Energy, 2=Bio, 3=Rare)
     * @param amount Amount to sell
     * @param pricePerUnit Price per unit in YLW (wei)
     * @param duration Listing duration in seconds (max 7 days)
     * @return listingId Unique listing identifier
     */
    function listResources(
        uint8 resourceType,
        uint256 amount,
        uint256 pricePerUnit,
        uint32 duration
    ) external whenNotPaused nonReentrant returns (bytes32 listingId) {
        if (resourceType > 3) revert InvalidResourceType(resourceType);
        if (amount == 0) revert InvalidAmount(amount);
        if (pricePerUnit == 0) revert InvalidPrice(pricePerUnit);
        if (duration > MAX_ORDER_DURATION) duration = MAX_ORDER_DURATION;

        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        LibMarketplaceStorage.MarketplaceStorage storage ms = LibMarketplaceStorage.marketplaceStorage();
        address seller = LibMeta.msgSender();

        // Enforce max active orders per user
        if (LibMarketplaceStorage.countActiveOrders(ms, seller) >= MAX_ACTIVE_ORDERS_PER_USER) {
            revert MaxActiveOrdersReached(seller, MAX_ACTIVE_ORDERS_PER_USER);
        }

        // Apply decay before checking/locking resources
        LibResourceStorage.applyResourceDecay(seller);

        // Verify seller has resources
        uint256 available = rs.userResources[seller][resourceType];
        if (available < amount) {
            revert InsufficientResources(resourceType, amount, available);
        }

        // Lock resources (deduct from user balance)
        rs.userResources[seller][resourceType] = available - amount;

        // Get seller's colony
        bytes32 sellerColony = _getUserColony(seller);

        // Create listing with monotonic nonce to prevent ID collisions
        uint256 nonce = ++ms.orderNonce;
        listingId = keccak256(abi.encodePacked(
            seller,
            resourceType,
            amount,
            pricePerUnit,
            block.timestamp,
            nonce
        ));

        LibMarketplaceStorage.TradeOrder storage order = ms.orders[listingId];
        order.seller = seller;
        order.sellerColony = sellerColony;
        order.resourceType = resourceType;
        order.amount = amount;
        order.pricePerUnit = pricePerUnit;
        order.expiresAt = uint32(block.timestamp) + duration;
        order.active = true;

        ms.activeOrderIds.push(listingId);
        ms.userOrders[seller].push(listingId);

        emit OrderCreated(listingId, seller, resourceType, amount, pricePerUnit);
    }

    /**
     * @notice Buy resources from a marketplace listing
     * @param listingId Listing to buy from
     * @param amount Amount to buy (0 = buy all remaining)
     */
    function buyResources(
        bytes32 listingId,
        uint256 amount
    ) external whenNotPaused nonReentrant {
        LibMarketplaceStorage.MarketplaceStorage storage ms = LibMarketplaceStorage.marketplaceStorage();
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();

        LibMarketplaceStorage.TradeOrder storage order = ms.orders[listingId];

        // Validations
        if (order.seller == address(0)) revert OrderNotFound(listingId);
        if (!order.active) revert OrderInactive(listingId);
        if (block.timestamp > order.expiresAt) revert OrderExpired(listingId);

        address buyer = LibMeta.msgSender();
        if (buyer == order.seller) revert SelfTrade(buyer);

        // Determine fill amount
        uint256 fillAmount = amount == 0 ? order.amount : amount;
        if (fillAmount > order.amount) fillAmount = order.amount;
        if (fillAmount == 0) revert InvalidAmount(0);

        // Apply decay to buyer before awarding resources
        LibResourceStorage.applyResourceDecay(buyer);

        // Calculate payment with Trade Hub fee reduction for buyer
        uint256 totalPrice = fillAmount * order.pricePerUnit;
        uint256 feeBps = _getEffectiveFeeBps(buyer);
        uint256 fee = (totalPrice * feeBps) / 10000;
        uint256 sellerProceeds = totalPrice - fee;

        // Verify buyer has payment
        IERC20 utilityToken = IERC20(rs.config.utilityToken);
        if (utilityToken.balanceOf(buyer) < totalPrice) {
            revert InsufficientPayment(totalPrice, utilityToken.balanceOf(buyer));
        }

        // Transfer payment
        utilityToken.safeTransferFrom(buyer, order.seller, sellerProceeds);
        if (fee > 0) {
            utilityToken.safeTransferFrom(buyer, rs.config.paymentBeneficiary, fee);
        }

        // Transfer resources to buyer
        rs.userResources[buyer][order.resourceType] += fillAmount;

        // Update order
        order.amount -= fillAmount;
        ms.totalFeesCollected += fee;

        if (order.amount == 0) {
            order.active = false;
            LibMarketplaceStorage.removeFromActiveOrders(ms, listingId);
            emit OrderFilled(listingId, buyer, order.seller, fillAmount, totalPrice);
        } else {
            emit OrderPartiallyFilled(listingId, buyer, fillAmount, order.amount);
        }
    }

    /**
     * @notice Cancel a listing and return locked resources to seller
     * @param listingId Listing to cancel
     */
    function cancelListing(bytes32 listingId) external whenNotPaused nonReentrant {
        LibMarketplaceStorage.MarketplaceStorage storage ms = LibMarketplaceStorage.marketplaceStorage();
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();

        LibMarketplaceStorage.TradeOrder storage order = ms.orders[listingId];

        if (order.seller == address(0)) revert OrderNotFound(listingId);
        if (!order.active) revert OrderInactive(listingId);

        address caller = LibMeta.msgSender();
        if (caller != order.seller) revert UnauthorizedCancellation(caller, order.seller);

        uint256 returnAmount = order.amount;

        // Deactivate and compact array
        order.active = false;
        order.amount = 0;
        LibMarketplaceStorage.removeFromActiveOrders(ms, listingId);

        // Apply decay before returning resources (prevents decay bypass exploit)
        LibResourceStorage.applyResourceDecay(order.seller);

        // Return locked resources
        rs.userResources[order.seller][order.resourceType] += returnAmount;

        emit OrderCancelled(listingId, order.seller);
    }

    /**
     * @notice Batch cleanup expired listings and return resources (anyone can call)
     * @param listingIds Array of listing IDs to clean up
     */
    function cleanupExpiredListings(bytes32[] calldata listingIds) external {
        LibMarketplaceStorage.MarketplaceStorage storage ms = LibMarketplaceStorage.marketplaceStorage();
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();

        uint32 currentTime = uint32(block.timestamp);

        for (uint256 i = 0; i < listingIds.length; i++) {
            LibMarketplaceStorage.TradeOrder storage order = ms.orders[listingIds[i]];

            if (order.active && currentTime > order.expiresAt) {
                uint256 returnAmount = order.amount;
                address seller = order.seller;
                uint8 rType = order.resourceType;

                // Deactivate and compact array
                order.active = false;
                order.amount = 0;
                LibMarketplaceStorage.removeFromActiveOrders(ms, listingIds[i]);

                // Apply decay before returning resources (prevents decay bypass)
                LibResourceStorage.applyResourceDecay(seller);

                // Return resources to seller
                rs.userResources[seller][rType] += returnAmount;

                emit OrderCancelled(listingIds[i], seller);
            }
        }
    }

    // ==================== VIEW FUNCTIONS ====================

    /**
     * @notice Get listing details
     */
    function getListing(bytes32 listingId) external view returns (
        address seller,
        bytes32 sellerColony,
        uint8 resourceType,
        uint256 amount,
        uint256 pricePerUnit,
        uint32 expiresAt,
        bool active
    ) {
        LibMarketplaceStorage.MarketplaceStorage storage ms = LibMarketplaceStorage.marketplaceStorage();
        LibMarketplaceStorage.TradeOrder storage order = ms.orders[listingId];

        if (order.seller == address(0)) revert OrderNotFound(listingId);

        return (
            order.seller,
            order.sellerColony,
            order.resourceType,
            order.amount,
            order.pricePerUnit,
            order.expiresAt,
            order.active
        );
    }

    /**
     * @notice Get all active listings for a resource type
     */
    function getListingsByType(uint8 resourceType) external view returns (
        bytes32[] memory orderIds,
        LibMarketplaceStorage.TradeOrder[] memory orders
    ) {
        LibMarketplaceStorage.MarketplaceStorage storage ms = LibMarketplaceStorage.marketplaceStorage();

        // Count matching orders
        uint256 count = 0;
        for (uint256 i = 0; i < ms.activeOrderIds.length; i++) {
            LibMarketplaceStorage.TradeOrder storage order = ms.orders[ms.activeOrderIds[i]];
            if (order.active && order.resourceType == resourceType && block.timestamp <= order.expiresAt) {
                count++;
            }
        }

        // Populate arrays
        orderIds = new bytes32[](count);
        orders = new LibMarketplaceStorage.TradeOrder[](count);

        uint256 index = 0;
        for (uint256 i = 0; i < ms.activeOrderIds.length; i++) {
            bytes32 oid = ms.activeOrderIds[i];
            LibMarketplaceStorage.TradeOrder storage order = ms.orders[oid];
            if (order.active && order.resourceType == resourceType && block.timestamp <= order.expiresAt) {
                orderIds[index] = oid;
                orders[index] = order;
                index++;
            }
        }
    }

    /**
     * @notice Get all active listings for a user
     */
    function getUserListings(address user) external view returns (
        bytes32[] memory orderIds,
        LibMarketplaceStorage.TradeOrder[] memory orders
    ) {
        LibMarketplaceStorage.MarketplaceStorage storage ms = LibMarketplaceStorage.marketplaceStorage();
        bytes32[] storage userOrderIds = ms.userOrders[user];

        // Count active orders
        uint256 count = 0;
        for (uint256 i = 0; i < userOrderIds.length; i++) {
            if (ms.orders[userOrderIds[i]].active) count++;
        }

        // Populate arrays
        orderIds = new bytes32[](count);
        orders = new LibMarketplaceStorage.TradeOrder[](count);

        uint256 index = 0;
        for (uint256 i = 0; i < userOrderIds.length; i++) {
            bytes32 oid = userOrderIds[i];
            LibMarketplaceStorage.TradeOrder storage order = ms.orders[oid];
            if (order.active) {
                orderIds[index] = oid;
                orders[index] = order;
                index++;
            }
        }
    }

    /**
     * @notice Get lowest listed price for a resource type
     */
    function getLowestPrice(uint8 resourceType) external view returns (uint256 lowestPrice, bytes32 listingId) {
        LibMarketplaceStorage.MarketplaceStorage storage ms = LibMarketplaceStorage.marketplaceStorage();

        lowestPrice = type(uint256).max;

        for (uint256 i = 0; i < ms.activeOrderIds.length; i++) {
            bytes32 oid = ms.activeOrderIds[i];
            LibMarketplaceStorage.TradeOrder storage order = ms.orders[oid];

            if (order.active &&
                order.resourceType == resourceType &&
                block.timestamp <= order.expiresAt &&
                order.pricePerUnit < lowestPrice) {
                lowestPrice = order.pricePerUnit;
                listingId = oid;
            }
        }

        if (lowestPrice == type(uint256).max) lowestPrice = 0;
    }

    /**
     * @notice Get marketplace statistics
     */
    function getMarketStats() external view returns (
        uint256 totalActiveOrders,
        uint256 totalFeesCollected,
        uint256[4] memory ordersByResourceType
    ) {
        LibMarketplaceStorage.MarketplaceStorage storage ms = LibMarketplaceStorage.marketplaceStorage();

        totalFeesCollected = ms.totalFeesCollected;

        for (uint256 i = 0; i < ms.activeOrderIds.length; i++) {
            LibMarketplaceStorage.TradeOrder storage order = ms.orders[ms.activeOrderIds[i]];
            if (order.active && block.timestamp <= order.expiresAt) {
                totalActiveOrders++;
                ordersByResourceType[order.resourceType]++;
            }
        }
    }

    /**
     * @notice Get effective marketplace fee for a buyer (after Trade Hub reduction)
     * @param buyer Buyer address
     * @return feeBps Effective fee in basis points
     */
    function getEffectiveMarketFee(address buyer) external view returns (uint256 feeBps) {
        return _getEffectiveFeeBps(buyer);
    }

    // ==================== INTERNAL HELPERS ====================

    /**
     * @notice Calculate effective marketplace fee with Trade Hub reduction
     * @dev Trade Hub marketFeeReductionBps (L1=500..L5=4000) reduces the base 2% fee
     *      Example: Trade Hub L5 = 4000 bps reduction â†’ 200 * 4000 / 10000 = 80 â†’ fee = 120 bps (1.2%)
     * @param buyer Buyer address (fee payer)
     * @return feeBps Effective fee in basis points
     */
    function _getEffectiveFeeBps(address buyer) internal view returns (uint256 feeBps) {
        feeBps = BASE_MARKET_FEE_BPS;

        bytes32 colonyId = LibColonyWarsStorage.getUserPrimaryColony(buyer);
        if (colonyId == bytes32(0)) return feeBps;

        LibBuildingsStorage.ColonyBuildingEffects memory effects =
            LibBuildingsStorage.getColonyBuildingEffectsWithCards(colonyId);

        if (effects.marketFeeReductionBps > 0) {
            uint256 reduction = (feeBps * effects.marketFeeReductionBps) / 10000;
            feeBps = feeBps > reduction ? feeBps - reduction : 0;
        }
    }

    /**
     * @notice Get user's colony via staking system or colony facet
     * @dev Defensive - catches reverts from external contracts
     */
    function _getUserColony(address user) internal view returns (bytes32) {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();

        // Try staking system
        if (rs.config.stakingSystemAddress != address(0)) {
            try IStakingSystem(rs.config.stakingSystemAddress).getUserColony(user) returns (bytes32 colonyId) {
                if (colonyId != bytes32(0)) return colonyId;
            } catch {}
        }

        // Try colony facet
        if (rs.config.colonyFacetAddress != address(0)) {
            try IColonyFacet(rs.config.colonyFacetAddress).getUserPrimaryColony(user) returns (bytes32 colonyId) {
                if (colonyId != bytes32(0)) return colonyId;
            } catch {}
        }

        return bytes32(0);
    }
}

interface IStakingSystem {
    function getUserColony(address user) external view returns (bytes32);
}

interface IColonyFacet {
    function getUserPrimaryColony(address user) external view returns (bytes32);
}
