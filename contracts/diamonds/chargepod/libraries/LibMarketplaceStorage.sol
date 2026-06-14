// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/**
 * @title LibMarketplaceStorage
 * @notice Diamond-pattern storage library for the Resource Marketplace
 * @dev Separated from ResourceMarketplaceFacet so that:
 *      1. Storage layout is guaranteed consistent across facet upgrades
 *      2. Other facets can read marketplace state if needed (e.g. analytics)
 *      3. Follows the same pattern as LibResourceStorage, LibBuildingsStorage, etc.
 *
 *      IMPORTANT: This struct is append-only. Never reorder or remove fields.
 *      New fields must be added at the end of MarketplaceStorage.
 *
 * @author rutilicus.eth (ArchXS)
 */
library LibMarketplaceStorage {
    bytes32 constant MARKETPLACE_STORAGE_POSITION = keccak256("henomorphs.marketplace.storage.v1");

    // ============================================
    // STRUCTS
    // ============================================

    /**
     * @notice A single sell order in the marketplace order book
     */
    struct TradeOrder {
        address seller;
        bytes32 sellerColony;
        uint8 resourceType;          // 0=Basic, 1=Energy, 2=Bio, 3=Rare
        uint256 amount;              // Remaining amount (decreases on partial fills)
        uint256 pricePerUnit;        // In utility token (YLW) wei per resource unit
        uint32 expiresAt;            // Timestamp when order expires
        bool active;                 // False after fill/cancel/expiry
    }

    /**
     * @notice Root storage struct for the marketplace system
     * @dev Append-only - never reorder or remove fields
     */
    struct MarketplaceStorage {
        /// @notice Order data keyed by orderId
        mapping(bytes32 => TradeOrder) orders;

        /// @notice Array of order IDs currently in the book (compacted on removal)
        bytes32[] activeOrderIds;

        /// @notice Per-user list of all order IDs ever created (includes inactive)
        mapping(address => bytes32[]) userOrders;

        /// @notice Cumulative fees collected (in utility token wei)
        uint256 totalFeesCollected;

        /// @notice Monotonic nonce for collision-free order ID generation
        uint256 orderNonce;
    }

    // ============================================
    // STORAGE ACCESSOR
    // ============================================

    /**
     * @notice Get marketplace storage reference
     */
    function marketplaceStorage() internal pure returns (MarketplaceStorage storage ms) {
        bytes32 position = MARKETPLACE_STORAGE_POSITION;
        assembly {
            ms.slot := position
        }
    }

    // ============================================
    // HELPER FUNCTIONS
    // ============================================

    /**
     * @notice Remove orderId from activeOrderIds array (swap-and-pop)
     * @dev O(n) scan but keeps the array compact. No-op if not found.
     * @param ms Marketplace storage reference
     * @param orderId Order ID to remove
     */
    function removeFromActiveOrders(MarketplaceStorage storage ms, bytes32 orderId) internal {
        uint256 len = ms.activeOrderIds.length;
        for (uint256 i = 0; i < len; i++) {
            if (ms.activeOrderIds[i] == orderId) {
                ms.activeOrderIds[i] = ms.activeOrderIds[len - 1];
                ms.activeOrderIds.pop();
                return;
            }
        }
    }

    /**
     * @notice Count active (non-cancelled, non-filled) orders for a user
     * @param ms Marketplace storage reference
     * @param user User address
     * @return count Number of currently active orders
     */
    function countActiveOrders(MarketplaceStorage storage ms, address user) internal view returns (uint256 count) {
        bytes32[] storage userOrderIds = ms.userOrders[user];
        for (uint256 i = 0; i < userOrderIds.length; i++) {
            if (ms.orders[userOrderIds[i]].active) count++;
        }
    }
}
