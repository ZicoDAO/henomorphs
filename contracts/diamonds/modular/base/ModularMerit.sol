// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ICollectionDiamond} from "../interfaces/ICollectionDiamond.sol";

/**
 * @title ModularMerit
 * @notice Abstract base contract for Colony Merit collections (Territory, Infrastructure, Resources)
 * @dev Provides:
 *      - Conditional Transfer System (Model D) for Colony Wars integration
 *      - Optional Diamond integration (simplified, no augments/variants)
 *      - Common role definitions
 *
 * Storage Layout (compatible with ModularSpecimen upgrade path):
 *      slot 50: diamond (ICollectionDiamond)
 *      slot 51: collectionId (uint256)
 *      Note: defaultTier and defaultIssue from ModularSpecimen are NOT included
 *            as Merit collections don't use variant/augment systems
 *
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 */
abstract contract ModularMerit is Initializable {

    // ==================== ROLE DEFINITIONS ====================
    // These are defined here for consistency across all Merit collections
    // Derived contracts should use these instead of redefining
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant COLONY_WARS_ROLE = keccak256("COLONY_WARS_ROLE");
    bytes32 public constant DIAMOND_ROLE = keccak256("DIAMOND_ROLE");

    // ==================== DIAMOND INTEGRATION (OPTIONAL) ====================
    // Storage slots match ModularSpecimen for upgrade compatibility
    ICollectionDiamond public diamond;      // slot N+0
    uint256 public collectionId;            // slot N+1

    // ==================== STORAGE GAP FOR MODULARSPECIMEN COMPATIBILITY ====================
    // ModularSpecimen has defaultTier (slot N+2) and defaultIssue (slot N+3)
    // We preserve these slots to ensure Colony Cards can upgrade safely
    /// @custom:storage-location deprecated
    uint256 private __deprecated_defaultTier_slot;      // slot N+2 (was defaultTier in ModularSpecimen)
    /// @custom:storage-location deprecated
    uint256 private __deprecated_defaultIssue_slot;     // slot N+3 (was defaultIssue in ModularSpecimen)

    // ==================== CONDITIONAL TRANSFER SYSTEM (Model D) ====================
    // NOTE: _approvedTransferTarget mapping is NOT stored here!
    // Each derived contract maintains its own mapping at the original storage slot
    // to preserve upgrade compatibility. Use _getApprovedTarget/_setApprovedTarget.

    // ==================== EVENTS ====================
    event DiamondUpdated(address indexed oldDiamond, address indexed newDiamond);
    event CollectionIdUpdated(uint256 indexed oldId, uint256 indexed newId);
    event TransferRequested(uint256 indexed tokenId, address indexed from, address indexed to);
    event TransferApproved(uint256 indexed tokenId, address indexed to);
    event TransferRejected(uint256 indexed tokenId, address indexed to, string reason);
    event TransferCleared(uint256 indexed tokenId);

    // ==================== ERRORS ====================
    error DiamondNotSet();
    error InvalidAddress();
    error InvalidCollectionId();
    error TokenNotExists();
    error TransferNotApproved();
    error TransferTargetMismatch();
    error NotTokenOwner();
    error CannotTransferToZeroAddress();
    error TransferRestricted();

    // ==================== MODIFIERS ====================

    /**
     * @notice Requires Diamond to be set
     * @dev Use for functions that need Diamond interaction
     */
    modifier diamondRequired() {
        if (address(diamond) == address(0)) revert DiamondNotSet();
        _;
    }

    // ==================== INITIALIZATION ====================

    /**
     * @notice Initialize Merit base contract
     * @dev Diamond integration is optional - pass address(0) to skip
     * @param diamondAddress Optional Diamond contract address (can be address(0))
     * @param newCollectionId Collection ID in Diamond (ignored if diamondAddress is 0)
     */
    function __ModularMerit_init(
        address diamondAddress,
        uint256 newCollectionId
    ) internal onlyInitializing {
        if (diamondAddress != address(0)) {
            _setDiamond(diamondAddress);
            if (newCollectionId > 0) {
                _setCollectionId(newCollectionId);
            }
        }
    }

    // ==================== DIAMOND MANAGEMENT ====================

    /**
     * @notice Set Diamond contract address
     * @dev Requires DIAMOND_ROLE permission (checked via _checkDiamondPermission)
     * @param diamondAddress New Diamond address
     */
    function setDiamond(address diamondAddress) external virtual {
        _checkDiamondPermission();
        _setDiamond(diamondAddress);
    }

    /**
     * @notice Set collection ID in Diamond system
     * @dev Requires DIAMOND_ROLE permission (checked via _checkDiamondPermission)
     * @param newCollectionId New collection ID
     */
    function setCollectionId(uint256 newCollectionId) external virtual {
        _checkDiamondPermission();
        _setCollectionId(newCollectionId);
    }

    // ==================== CONDITIONAL TRANSFER SYSTEM (Model D) ====================

    /**
     * @notice Request transfer approval from COLONY_WARS_ROLE
     * @dev Called by token owner to initiate transfer request
     *      Derived contracts should wrap this with access control
     * @param tokenId Token to request transfer for
     * @param to Target address for transfer
     */
    function _requestTransfer(uint256 tokenId, address to) internal virtual {
        if (!_tokenExists(tokenId)) revert TokenNotExists();
        if (to == address(0)) revert CannotTransferToZeroAddress();
        if (!_isTokenOwner(tokenId, msg.sender)) revert NotTokenOwner();

        // Check collection-specific transfer restrictions (e.g., staked, equipped)
        _checkTransferRestrictions(tokenId);

        _setApprovedTarget(tokenId, to);
        emit TransferRequested(tokenId, msg.sender, to);
    }

    /**
     * @notice Approve pending transfer request
     * @dev Called by COLONY_WARS_ROLE holder
     *      Derived contracts should wrap this with onlyRole(COLONY_WARS_ROLE)
     * @param tokenId Token to approve
     * @param to Expected target address (must match request)
     */
    function _approveTransfer(uint256 tokenId, address to) internal virtual {
        if (_getApprovedTarget(tokenId) != to) revert TransferTargetMismatch();
        emit TransferApproved(tokenId, to);
    }

    /**
     * @notice Complete approved transfer
     * @dev Called by COLONY_WARS_ROLE after approval
     *      Derived contracts should wrap this with onlyRole(COLONY_WARS_ROLE)
     *      The actual transfer should be performed by the derived contract
     * @param from Source address (for validation)
     * @param to Destination address (must match approved target)
     * @param tokenId Token to transfer
     * @return success Whether transfer was authorized
     */
    function _completeTransfer(
        address from,
        address to,
        uint256 tokenId
    ) internal virtual returns (bool success) {
        if (_getApprovedTarget(tokenId) != to) revert TransferNotApproved();

        // Check collection-specific restrictions again
        _checkTransferRestrictions(tokenId);

        // Clear approval before transfer
        _setApprovedTarget(tokenId, address(0));

        return true;
    }

    /**
     * @notice Reject transfer request with reason
     * @dev Called by COLONY_WARS_ROLE to deny a transfer
     *      Derived contracts should wrap this with onlyRole(COLONY_WARS_ROLE)
     * @param tokenId Token to reject
     * @param reason Rejection reason (for event)
     */
    function _rejectTransfer(uint256 tokenId, string calldata reason) internal virtual {
        address to = _getApprovedTarget(tokenId);
        _setApprovedTarget(tokenId, address(0));
        emit TransferRejected(tokenId, to, reason);
    }

    /**
     * @notice Clear transfer approval without event
     * @dev Used internally when token state changes (burn, etc.)
     * @param tokenId Token to clear
     */
    function _clearTransferApproval(uint256 tokenId) internal virtual {
        if (_getApprovedTarget(tokenId) != address(0)) {
            _setApprovedTarget(tokenId, address(0));
            emit TransferCleared(tokenId);
        }
    }

    /**
     * @notice Get approved transfer target
     * @param tokenId Token ID
     * @return Approved target address (address(0) if none)
     */
    function getApprovedTransferTarget(uint256 tokenId) external view returns (address) {
        return _getApprovedTarget(tokenId);
    }

    /**
     * @notice Check if token has pending transfer request
     * @param tokenId Token ID
     * @return hasPending Whether a transfer is pending
     */
    function hasPendingTransfer(uint256 tokenId) external view returns (bool hasPending) {
        return _getApprovedTarget(tokenId) != address(0);
    }

    // ==================== DIAMOND NOTIFICATION (SIMPLIFIED) ====================

    /**
     * @notice Notify Diamond about token mint (optional)
     * @dev Uses try-catch to prevent mint failures if Diamond is unavailable
     * @param tokenId Token ID
     * @param owner Token owner
     */
    function _notifyTokenMinted(uint256 tokenId, address owner) internal {
        if (address(diamond) != address(0) && collectionId != 0) {
            try diamond.onTokenMinted(collectionId, tokenId, owner) {
                // Success - notification sent
            } catch {
                // Ignore errors - Diamond integration is optional for Merit
            }
        }
    }

    /**
     * @notice Notify Diamond about token transfer (optional)
     * @dev Uses try-catch to prevent transfer failures if Diamond is unavailable
     * @param tokenId Token ID
     * @param from Previous owner
     * @param to New owner
     */
    function _notifyTokenTransferred(uint256 tokenId, address from, address to) internal {
        if (address(diamond) != address(0) && collectionId != 0) {
            try diamond.onTokenTransferred(collectionId, tokenId, from, to) {
                // Success - notification sent
            } catch {
                // Ignore errors - Diamond integration is optional for Merit
            }
        }
    }

    // ==================== ABSTRACT FUNCTIONS ====================
    // These must be implemented by derived contracts

    /**
     * @notice Check if token exists
     * @dev Must be implemented by derived contract (typically: _ownerOf(tokenId) != address(0))
     * @param tokenId Token ID to check
     * @return exists Whether token exists
     */
    function _tokenExists(uint256 tokenId) internal view virtual returns (bool exists);

    /**
     * @notice Check if address is token owner
     * @dev Must be implemented by derived contract (typically: ownerOf(tokenId) == account)
     * @param tokenId Token ID
     * @param account Address to check
     * @return isOwner Whether account owns the token
     */
    function _isTokenOwner(uint256 tokenId, address account) internal view virtual returns (bool isOwner);

    /**
     * @notice Check Diamond management permission
     * @dev Must be implemented by derived contract
     *      Typically: _checkRole(DIAMOND_ROLE) or hasRole(DIAMOND_ROLE, msg.sender)
     */
    function _checkDiamondPermission() internal view virtual;

    /**
     * @notice Check collection-specific transfer restrictions
     * @dev Override in derived contracts to add restrictions
     *      Examples:
     *      - Territory: revert if _territoryActive[tokenId]
     *      - Infrastructure: revert if _isEquipped[tokenId]
     *      - Resources: revert if _isStaked[tokenId]
     * @param tokenId Token to check
     */
    function _checkTransferRestrictions(uint256 tokenId) internal view virtual {
        // Default: no additional restrictions
        // Derived contracts should override to add their specific checks
    }

    /**
     * @notice Get approved transfer target for a token
     * @dev Must be implemented by derived contract using its own storage mapping
     *      This design preserves storage layout compatibility during upgrades
     * @param tokenId Token ID
     * @return target Approved target address (address(0) if none)
     */
    function _getApprovedTarget(uint256 tokenId) internal view virtual returns (address target);

    /**
     * @notice Set approved transfer target for a token
     * @dev Must be implemented by derived contract using its own storage mapping
     *      Use address(0) to clear the approval
     * @param tokenId Token ID
     * @param target Target address (or address(0) to clear)
     */
    function _setApprovedTarget(uint256 tokenId, address target) internal virtual;

    // ==================== PRIVATE FUNCTIONS ====================

    function _setDiamond(address diamondAddress) private {
        if (diamondAddress == address(0)) revert InvalidAddress();

        address oldDiamond = address(diamond);
        diamond = ICollectionDiamond(diamondAddress);

        emit DiamondUpdated(oldDiamond, diamondAddress);
    }

    function _setCollectionId(uint256 newCollectionId) private {
        if (newCollectionId == 0) revert InvalidCollectionId();

        uint256 oldId = collectionId;
        collectionId = newCollectionId;

        emit CollectionIdUpdated(oldId, newCollectionId);
    }
}
