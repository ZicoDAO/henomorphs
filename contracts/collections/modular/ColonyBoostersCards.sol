// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721BurnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721EnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ModularMerit} from "../../diamonds/modular/base/ModularMerit.sol";
import {IMeritCollection} from "../../diamonds/modular/interfaces/IMeritCollection.sol";
import {BoosterSVGLib} from "../../diamonds/modular/libraries/BoosterSVGLib.sol";
import {IBoosterDescriptor} from "./interfaces/IBoosterDescriptor.sol";

/**
 * @title ColonyBoostersCards
 * @notice Universal Booster NFT Cards supporting multiple game systems
 * @dev UUPS upgradeable ERC721 with multi-system support
 *
 * Target Systems:
 * - Buildings (0): Colony building enhancement
 * - Evolution (1): Specimen evolution bonuses
 * - Venture (2): Resource venture bonuses
 * - Universal (3): Works with all systems (explicit attachment required)
 *
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 */
contract ColonyBoostersCards is
    Initializable,
    ERC721Upgradeable,
    ERC721EnumerableUpgradeable,
    ERC721BurnableUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable,
    ModularMerit,
    IMeritCollection
{
    using BoosterSVGLib for BoosterSVGLib.BoosterTraits;

    // Role definitions inherited from ModularMerit:
    // ADMIN_ROLE, MINTER_ROLE, COLONY_WARS_ROLE, DIAMOND_ROLE

    // Rarity thresholds (out of 10000)
    uint256 private constant LEGENDARY_THRESHOLD = 100;   // 1%
    uint256 private constant EPIC_THRESHOLD = 600;        // 5%
    uint256 private constant RARE_THRESHOLD = 2100;       // 15%
    uint256 private constant UNCOMMON_THRESHOLD = 5100;   // 30%
    // Common = remaining 49%

    // Universal boosters have better rarity rates
    uint256 private constant UNIVERSAL_LEGENDARY_THRESHOLD = 200;  // 2%
    uint256 private constant UNIVERSAL_EPIC_THRESHOLD = 1000;      // 8%

    /// @notice Attachment target structure for multi-system support
    struct AttachmentTarget {
        BoosterSVGLib.TargetSystem system;
        bytes32 colonyId;           // Buildings: colony identifier
        uint8 buildingType;         // Buildings: building type (0-7)
        uint256 collectionId;       // Evolution: specimen collection ID
        uint256 tokenId;            // Evolution: specimen token ID
        address user;               // Venture/Universal: user address
        uint8 ventureType;          // Venture: venture type (0-4)
    }

    /// @notice Attachment record with metadata
    struct BoosterAttachment {
        AttachmentTarget target;
        uint32 attachedAt;
        uint32 cooldownUntil;
        uint16 computedBonusBps;
        bool locked;
    }

    // Core NFT data
    mapping(uint256 => BoosterSVGLib.BoosterTraits) private _boosterTraits;
    uint256 private _tokenIdCounter;

    // Attachment system
    mapping(uint256 => BoosterAttachment) private _attachments;
    mapping(bytes32 => uint256) private _targetToBooster;  // targetKey => tokenId
    mapping(uint256 => bool) private _isAttached;

    // Transfer model D (from ModularMerit)
    mapping(uint256 => address) private _approvedTransferTarget;

    // Supply management (modular: system + subType)
    mapping(address => uint256) private _walletMintCount;
    mapping(bytes32 => uint256) public typeMaxSupply;   // _typeKey(system, subType) => max
    mapping(bytes32 => uint256) public typeMinted;      // _typeKey(system, subType) => minted

    // Configuration
    IBoosterDescriptor public metadataRenderer;
    uint256 public maxSupply;
    uint256 public maxMintsPerWallet;
    uint32 public attachCooldownSeconds;
    uint32 public detachCooldownSeconds;

    // ==================== EVENTS ====================

    event BoosterMinted(
        uint256 indexed tokenId,
        address indexed recipient,
        BoosterSVGLib.TargetSystem targetSystem,
        uint8 subType,
        BoosterSVGLib.Rarity rarity
    );

    event BoosterAttached(
        uint256 indexed tokenId,
        BoosterSVGLib.TargetSystem indexed system,
        bytes32 targetKey,
        address indexed owner
    );

    event BoosterDetached(
        uint256 indexed tokenId,
        BoosterSVGLib.TargetSystem indexed system,
        bytes32 targetKey,
        address indexed owner
    );

    event BoostersUpgraded(uint256[] burnedTokens, uint256 indexed newTokenId);
    event BlueprintActivated(uint256 indexed tokenId, address indexed owner);
    event MetadataRendererUpdated(address indexed oldRenderer, address indexed newRenderer);
    event TypeMaxSupplyUpdated(BoosterSVGLib.TargetSystem system, uint8 subType, uint256 maxSupply);

    // ==================== ERRORS ====================

    error MaxSupplyReached();
    error TypeMaxSupplyReached();
    error InvalidTargetSystem();
    error InvalidSubType();
    error InvalidRarity();
    error BoosterAlreadyAttached();
    error BoosterNotAttached();
    error CannotTransferWhileAttached();
    error InvalidUpgradeInput();
    error InvalidMetadataRenderer();
    error StillBlueprint();
    error NotBlueprint();
    error IncompatibleSystem();
    error TargetAlreadyHasBooster();
    error AttachmentInCooldown();
    error BoosterLocked();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() { _disableInitializers(); }

    function initialize(
        string memory name_,
        string memory symbol_,
        address diamondAddress,
        uint256 collectionId_,
        IBoosterDescriptor _metadataRenderer,
        uint256 _maxSupply,
        uint256 _maxMintsPerWallet
    ) public initializer {
        if (address(_metadataRenderer) == address(0)) revert InvalidMetadataRenderer();

        __ERC721_init(name_, symbol_);
        __ERC721Enumerable_init();
        __ERC721Burnable_init();
        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();
        __UUPSUpgradeable_init();
        __ModularMerit_init(diamondAddress, collectionId_);

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(MINTER_ROLE, msg.sender);
        _grantRole(DIAMOND_ROLE, msg.sender);

        metadataRenderer = _metadataRenderer;
        maxSupply = _maxSupply;
        maxMintsPerWallet = _maxMintsPerWallet;
        attachCooldownSeconds = 3600;   // 1 hour default
        detachCooldownSeconds = 86400;  // 24 hours default
    }

    // ============ MINTING FUNCTIONS ============

    /**
     * @notice Mint a booster card with specific traits
     * @param to Recipient address
     * @param targetSystem Target system (Buildings, Evolution, Venture, Universal)
     * @param subType SubType within system (0-7)
     * @param rarity Rarity tier
     * @param isBlueprint Whether this is an unactivated blueprint
     */
    function mintBooster(
        address to,
        BoosterSVGLib.TargetSystem targetSystem,
        uint8 subType,
        BoosterSVGLib.Rarity rarity,
        bool isBlueprint
    ) external onlyRole(MINTER_ROLE) nonReentrant whenNotPaused returns (uint256) {
        _validateMint(to, 1, targetSystem, subType);

        uint256 tokenId = ++_tokenIdCounter;
        bytes32 typeKey = _typeKey(targetSystem, subType);
        typeMinted[typeKey]++;
        _walletMintCount[to]++;

        _boosterTraits[tokenId] = BoosterSVGLib.BoosterTraits({
            targetSystem: targetSystem,
            subType: subType,
            rarity: rarity,
            primaryBonusBps: _calculatePrimaryBonus(targetSystem, subType, rarity),
            secondaryBonusBps: _calculateSecondaryBonus(targetSystem, subType, rarity),
            level: _calculateLevel(rarity),
            isBlueprint: isBlueprint
        });

        _safeMint(to, tokenId);
        emit BoosterMinted(tokenId, to, targetSystem, subType, rarity);

        return tokenId;
    }

    /**
     * @notice Mint a booster card with random rarity
     * @param to Recipient address
     * @param targetSystem Target system
     * @param subType SubType within system
     * @param isBlueprint Whether this is an unactivated blueprint
     */
    function mintRandomBooster(
        address to,
        BoosterSVGLib.TargetSystem targetSystem,
        uint8 subType,
        bool isBlueprint
    ) external onlyRole(MINTER_ROLE) nonReentrant whenNotPaused returns (uint256) {
        _validateMint(to, 1, targetSystem, subType);

        uint256 tokenId = ++_tokenIdCounter;
        bytes32 typeKey = _typeKey(targetSystem, subType);
        typeMinted[typeKey]++;
        _walletMintCount[to]++;

        BoosterSVGLib.Rarity rarity = _calculateRarity(tokenId, targetSystem, subType, msg.sender);

        _boosterTraits[tokenId] = BoosterSVGLib.BoosterTraits({
            targetSystem: targetSystem,
            subType: subType,
            rarity: rarity,
            primaryBonusBps: _calculatePrimaryBonus(targetSystem, subType, rarity),
            secondaryBonusBps: _calculateSecondaryBonus(targetSystem, subType, rarity),
            level: _calculateLevel(rarity),
            isBlueprint: isBlueprint
        });

        _safeMint(to, tokenId);
        emit BoosterMinted(tokenId, to, targetSystem, subType, rarity);

        return tokenId;
    }

    /**
     * @notice Batch mint boosters
     */
    function batchMintBoosters(
        address to,
        BoosterSVGLib.TargetSystem[] calldata systems,
        uint8[] calldata subTypes,
        BoosterSVGLib.Rarity[] calldata rarities,
        bool[] calldata blueprints
    ) external onlyRole(MINTER_ROLE) nonReentrant whenNotPaused returns (uint256[] memory) {
        require(
            systems.length == subTypes.length &&
            systems.length == rarities.length &&
            systems.length == blueprints.length,
            "Length mismatch"
        );

        uint256[] memory tokenIds = new uint256[](systems.length);

        for (uint256 i = 0; i < systems.length; i++) {
            _validateMint(to, 1, systems[i], subTypes[i]);

            uint256 tokenId = ++_tokenIdCounter;
            bytes32 typeKey = _typeKey(systems[i], subTypes[i]);
            typeMinted[typeKey]++;
            _walletMintCount[to]++;

            _boosterTraits[tokenId] = BoosterSVGLib.BoosterTraits({
                targetSystem: systems[i],
                subType: subTypes[i],
                rarity: rarities[i],
                primaryBonusBps: _calculatePrimaryBonus(systems[i], subTypes[i], rarities[i]),
                secondaryBonusBps: _calculateSecondaryBonus(systems[i], subTypes[i], rarities[i]),
                level: _calculateLevel(rarities[i]),
                isBlueprint: blueprints[i]
            });

            _safeMint(to, tokenId);
            tokenIds[i] = tokenId;

            emit BoosterMinted(tokenId, to, systems[i], subTypes[i], rarities[i]);
        }

        return tokenIds;
    }

    function _validateMint(
        address to,
        uint256 amount,
        BoosterSVGLib.TargetSystem targetSystem,
        uint8 subType
    ) private view {
        if (_tokenIdCounter + amount > maxSupply) revert MaxSupplyReached();
        if (_walletMintCount[to] + amount > maxMintsPerWallet) revert MaxSupplyReached();

        bytes32 typeKey = _typeKey(targetSystem, subType);
        uint256 maxForType = typeMaxSupply[typeKey];
        if (maxForType > 0 && typeMinted[typeKey] + amount > maxForType) {
            revert TypeMaxSupplyReached();
        }

        _validateSubType(targetSystem, subType);
    }

    function _validateSubType(BoosterSVGLib.TargetSystem system, uint8 subType) private pure {
        if (system == BoosterSVGLib.TargetSystem.Buildings) {
            if (subType > 7) revert InvalidSubType();
        } else {
            if (subType > 3) revert InvalidSubType();
        }
    }

    // ============ ATTACHMENT FUNCTIONS ============

    /**
     * @notice Attach booster to a target
     * @param tokenId Booster token ID
     * @param target Attachment target details
     */
    function attachBooster(
        uint256 tokenId,
        AttachmentTarget calldata target
    ) external onlyRole(COLONY_WARS_ROLE) nonReentrant {
        BoosterSVGLib.BoosterTraits storage traits = _boosterTraits[tokenId];

        // Validate system compatibility
        if (traits.targetSystem != BoosterSVGLib.TargetSystem.Universal &&
            traits.targetSystem != target.system) {
            revert IncompatibleSystem();
        }

        if (_isAttached[tokenId]) revert BoosterAlreadyAttached();
        if (traits.isBlueprint) revert StillBlueprint();

        bytes32 targetKey = _getAttachmentKey(target);
        if (_targetToBooster[targetKey] != 0) revert TargetAlreadyHasBooster();

        // Create attachment
        _attachments[tokenId] = BoosterAttachment({
            target: target,
            attachedAt: uint32(block.timestamp),
            cooldownUntil: uint32(block.timestamp) + attachCooldownSeconds,
            computedBonusBps: traits.primaryBonusBps,
            locked: false
        });

        _targetToBooster[targetKey] = tokenId;
        _isAttached[tokenId] = true;

        emit BoosterAttached(tokenId, target.system, targetKey, ownerOf(tokenId));
    }

    /**
     * @notice Detach booster from target
     * @param tokenId Booster token ID
     */
    function detachBooster(uint256 tokenId) external onlyRole(COLONY_WARS_ROLE) nonReentrant {
        if (!_isAttached[tokenId]) revert BoosterNotAttached();

        BoosterAttachment storage attachment = _attachments[tokenId];
        if (attachment.locked) revert BoosterLocked();
        if (block.timestamp < attachment.cooldownUntil) revert AttachmentInCooldown();

        bytes32 targetKey = _getAttachmentKey(attachment.target);
        BoosterSVGLib.TargetSystem system = attachment.target.system;

        delete _targetToBooster[targetKey];
        delete _attachments[tokenId];
        _isAttached[tokenId] = false;

        emit BoosterDetached(tokenId, system, targetKey, ownerOf(tokenId));
    }

    /**
     * @notice Legacy function for building attachment (backward compatibility)
     */
    function attachToColony(uint256 tokenId, bytes32 colonyId, uint8 buildingType)
        external
        onlyRole(COLONY_WARS_ROLE)
        nonReentrant
    {
        BoosterSVGLib.BoosterTraits storage traits = _boosterTraits[tokenId];

        if (traits.targetSystem != BoosterSVGLib.TargetSystem.Buildings &&
            traits.targetSystem != BoosterSVGLib.TargetSystem.Universal) {
            revert IncompatibleSystem();
        }

        AttachmentTarget memory target = AttachmentTarget({
            system: BoosterSVGLib.TargetSystem.Buildings,
            colonyId: colonyId,
            buildingType: buildingType,
            collectionId: 0,
            tokenId: 0,
            user: address(0),
            ventureType: 0
        });

        if (_isAttached[tokenId]) revert BoosterAlreadyAttached();
        if (traits.isBlueprint) revert StillBlueprint();

        bytes32 targetKey = _getAttachmentKey(target);
        if (_targetToBooster[targetKey] != 0) revert TargetAlreadyHasBooster();

        _attachments[tokenId] = BoosterAttachment({
            target: target,
            attachedAt: uint32(block.timestamp),
            cooldownUntil: uint32(block.timestamp) + attachCooldownSeconds,
            computedBonusBps: traits.primaryBonusBps,
            locked: false
        });

        _targetToBooster[targetKey] = tokenId;
        _isAttached[tokenId] = true;

        emit BoosterAttached(tokenId, BoosterSVGLib.TargetSystem.Buildings, targetKey, ownerOf(tokenId));
    }

    /**
     * @notice Detach booster from colony (legacy)
     */
    function detachFromColony(uint256 tokenId) external onlyRole(COLONY_WARS_ROLE) nonReentrant {
        if (!_isAttached[tokenId]) revert BoosterNotAttached();

        BoosterAttachment storage attachment = _attachments[tokenId];
        if (attachment.locked) revert BoosterLocked();

        bytes32 targetKey = _getAttachmentKey(attachment.target);

        delete _targetToBooster[targetKey];
        delete _attachments[tokenId];
        _isAttached[tokenId] = false;

        emit BoosterDetached(tokenId, attachment.target.system, targetKey, ownerOf(tokenId));
    }

    function _getAttachmentKey(AttachmentTarget memory target) internal pure returns (bytes32) {
        if (target.system == BoosterSVGLib.TargetSystem.Buildings) {
            return keccak256(abi.encodePacked(uint8(0), target.colonyId, target.buildingType));
        } else if (target.system == BoosterSVGLib.TargetSystem.Evolution) {
            return keccak256(abi.encodePacked(uint8(1), target.collectionId, target.tokenId));
        } else if (target.system == BoosterSVGLib.TargetSystem.Venture) {
            return keccak256(abi.encodePacked(uint8(2), target.user, target.ventureType));
        } else {
            // Universal - keyed by user
            return keccak256(abi.encodePacked(uint8(3), target.user));
        }
    }

    // ============ BLUEPRINT ACTIVATION ============

    /**
     * @notice Activate a blueprint (converts to active booster)
     * @param tokenId Blueprint token ID
     */
    function activateBlueprint(uint256 tokenId) external onlyRole(COLONY_WARS_ROLE) nonReentrant whenNotPaused {
        if (!_boosterTraits[tokenId].isBlueprint) revert NotBlueprint();

        _boosterTraits[tokenId].isBlueprint = false;

        emit BlueprintActivated(tokenId, ownerOf(tokenId));
    }

    // ============ UPGRADE FUNCTION ============

    /**
     * @notice Combine 3 boosters of same system, subType and rarity to upgrade
     * @param tokenIds Array of 3 token IDs to combine
     */
    function upgradeBoosters(uint256[] calldata tokenIds)
        external
        onlyRole(COLONY_WARS_ROLE)
        nonReentrant
        whenNotPaused
        returns (uint256)
    {
        if (tokenIds.length != 3) revert InvalidUpgradeInput();

        BoosterSVGLib.BoosterTraits storage firstTraits = _boosterTraits[tokenIds[0]];
        BoosterSVGLib.TargetSystem system = firstTraits.targetSystem;
        uint8 subType = firstTraits.subType;
        BoosterSVGLib.Rarity baseRarity = firstTraits.rarity;

        // Cannot upgrade Legendary
        if (baseRarity == BoosterSVGLib.Rarity.Legendary) revert InvalidUpgradeInput();

        // Validate all tokens
        for (uint256 i = 0; i < 3; i++) {
            BoosterSVGLib.BoosterTraits storage traits = _boosterTraits[tokenIds[i]];
            if (traits.targetSystem != system) revert InvalidUpgradeInput();
            if (traits.subType != subType) revert InvalidUpgradeInput();
            if (traits.rarity != baseRarity) revert InvalidUpgradeInput();
            if (_isAttached[tokenIds[i]]) revert CannotTransferWhileAttached();
            if (traits.isBlueprint) revert StillBlueprint();
        }

        address tokenOwner = ownerOf(tokenIds[0]);

        // Burn old tokens
        for (uint256 i = 0; i < 3; i++) {
            _burn(tokenIds[i]);
        }

        // Mint upgraded token
        BoosterSVGLib.Rarity newRarity = BoosterSVGLib.Rarity(uint8(baseRarity) + 1);
        uint256 newTokenId = ++_tokenIdCounter;

        _boosterTraits[newTokenId] = BoosterSVGLib.BoosterTraits({
            targetSystem: system,
            subType: subType,
            rarity: newRarity,
            primaryBonusBps: _calculatePrimaryBonus(system, subType, newRarity),
            secondaryBonusBps: _calculateSecondaryBonus(system, subType, newRarity),
            level: _calculateLevel(newRarity),
            isBlueprint: false
        });

        _safeMint(tokenOwner, newTokenId);
        emit BoostersUpgraded(tokenIds, newTokenId);

        return newTokenId;
    }

    // ============ VIEW FUNCTIONS ============

    function tokenURI(uint256 tokenId)
        public
        view
        override(ERC721Upgradeable)
        returns (string memory)
    {
        _requireOwned(tokenId);

        BoosterSVGLib.BoosterTraits memory traits = _boosterTraits[tokenId];
        BoosterAttachment storage attachment = _attachments[tokenId];

        IBoosterDescriptor.BoosterMetadata memory metadata = IBoosterDescriptor.BoosterMetadata({
            tokenId: tokenId,
            targetSystem: traits.targetSystem,
            subType: traits.subType,
            rarity: traits.rarity,
            primaryBonusBps: traits.primaryBonusBps,
            secondaryBonusBps: traits.secondaryBonusBps,
            level: traits.level,
            isBlueprint: traits.isBlueprint,
            isAttached: _isAttached[tokenId],
            attachmentKey: _isAttached[tokenId] ? _getAttachmentKey(attachment.target) : bytes32(0)
        });

        return metadataRenderer.tokenURI(metadata);
    }

    function contractURI() public view returns (string memory) {
        return metadataRenderer.contractURI();
    }

    function walletMintCount(address wallet) external view returns (uint256) {
        return _walletMintCount[wallet];
    }

    function getTraits(uint256 tokenId) external view returns (BoosterSVGLib.BoosterTraits memory) {
        _requireOwned(tokenId);
        return _boosterTraits[tokenId];
    }

    function getAttachment(uint256 tokenId) external view returns (BoosterAttachment memory) {
        return _attachments[tokenId];
    }

    function isAttached(uint256 tokenId) external view returns (bool) {
        return _isAttached[tokenId];
    }

    function isBlueprint(uint256 tokenId) external view returns (bool) {
        return _boosterTraits[tokenId].isBlueprint;
    }

    function getBoosterByTarget(bytes32 targetKey) external view returns (uint256) {
        return _targetToBooster[targetKey];
    }

    /**
     * @notice Get bonuses for a building target
     */
    function getBuildingBonus(bytes32 colonyId, uint8 buildingType)
        external view returns (uint16 primaryBps, uint16 secondaryBps)
    {
        bytes32 targetKey = keccak256(abi.encodePacked(uint8(0), colonyId, buildingType));
        uint256 tokenId = _targetToBooster[targetKey];
        if (tokenId == 0) return (0, 0);

        BoosterSVGLib.BoosterTraits memory traits = _boosterTraits[tokenId];
        return (traits.primaryBonusBps, traits.secondaryBonusBps);
    }

    /**
     * @notice Get bonuses for an evolution target
     */
    function getEvolutionBonus(uint256 collectionId, uint256 specimenTokenId)
        external view returns (uint16 costReductionBps, uint8 tierBonus)
    {
        bytes32 targetKey = keccak256(abi.encodePacked(uint8(1), collectionId, specimenTokenId));
        uint256 tokenId = _targetToBooster[targetKey];
        if (tokenId == 0) return (0, 0);

        BoosterSVGLib.BoosterTraits memory traits = _boosterTraits[tokenId];
        return (traits.primaryBonusBps, uint8(traits.secondaryBonusBps / 100));
    }

    /**
     * @notice Get bonuses for a venture target
     */
    function getVentureBonus(address user, uint8 ventureType)
        external view returns (uint16 successBps, uint16 rewardBps)
    {
        bytes32 targetKey = keccak256(abi.encodePacked(uint8(2), user, ventureType));
        uint256 tokenId = _targetToBooster[targetKey];
        if (tokenId == 0) return (0, 0);

        BoosterSVGLib.BoosterTraits memory traits = _boosterTraits[tokenId];
        return (traits.primaryBonusBps, traits.secondaryBonusBps);
    }

    // ============ TRANSFER FUNCTIONS (Model D via ModularMerit) ============

    function requestTransfer(uint256 tokenId, address to) external {
        _requestTransfer(tokenId, to);
    }

    function approveTransfer(uint256 tokenId, address to) external onlyRole(COLONY_WARS_ROLE) {
        _approveTransfer(tokenId, to);
    }

    function completeTransfer(address from, address to, uint256 tokenId)
        external
        onlyRole(COLONY_WARS_ROLE)
    {
        if (_completeTransfer(from, to, tokenId)) {
            _transfer(from, to, tokenId);
        }
    }

    function rejectTransfer(uint256 tokenId, string calldata reason)
        external
        onlyRole(COLONY_WARS_ROLE)
    {
        _rejectTransfer(tokenId, reason);
    }

    // ============ COLONY INTEGRATION (IMeritCollection) ============

    /// @inheritdoc IMeritCollection
    function isAssigned(uint256 tokenId) external view override returns (bool) {
        return _isAttached[tokenId];
    }

    /// @inheritdoc IMeritCollection
    function getAssignmentTarget(uint256 tokenId) external view override returns (uint256) {
        if (!_isAttached[tokenId]) return 0;
        return uint256(_getAttachmentKey(_attachments[tokenId].target));
    }

    // ============ ADMIN FUNCTIONS ============

    function setMetadataRenderer(IBoosterDescriptor _metadataRenderer) external onlyRole(ADMIN_ROLE) {
        if (address(_metadataRenderer) == address(0)) revert InvalidMetadataRenderer();

        address oldRenderer = address(metadataRenderer);
        metadataRenderer = _metadataRenderer;

        emit MetadataRendererUpdated(oldRenderer, address(_metadataRenderer));
    }

    function setMaxSupply(uint256 newMaxSupply) external onlyRole(ADMIN_ROLE) {
        require(newMaxSupply >= _tokenIdCounter, "Cannot set below current supply");
        maxSupply = newMaxSupply;
    }

    function setMaxMintsPerWallet(uint256 newLimit) external onlyRole(ADMIN_ROLE) {
        maxMintsPerWallet = newLimit;
    }

    function setCooldowns(uint32 _attachCooldown, uint32 _detachCooldown) external onlyRole(ADMIN_ROLE) {
        attachCooldownSeconds = _attachCooldown;
        detachCooldownSeconds = _detachCooldown;
    }

    function updateTypeMaxSupply(
        BoosterSVGLib.TargetSystem system,
        uint8 subType,
        uint256 _maxSupply
    ) external onlyRole(ADMIN_ROLE) {
        bytes32 key = _typeKey(system, subType);
        require(_maxSupply >= typeMinted[key], "Cannot set below minted");
        typeMaxSupply[key] = _maxSupply;
        emit TypeMaxSupplyUpdated(system, subType, _maxSupply);
    }

    function updateTypeMaxSupplyBatch(
        BoosterSVGLib.TargetSystem[] calldata systems,
        uint8[] calldata subTypes,
        uint256[] calldata maxSupplies
    ) external onlyRole(ADMIN_ROLE) {
        require(systems.length == subTypes.length && systems.length == maxSupplies.length, "Length mismatch");

        for (uint256 i = 0; i < systems.length; i++) {
            bytes32 key = _typeKey(systems[i], subTypes[i]);
            require(maxSupplies[i] >= typeMinted[key], "Cannot set below minted");
            typeMaxSupply[key] = maxSupplies[i];
            emit TypeMaxSupplyUpdated(systems[i], subTypes[i], maxSupplies[i]);
        }
    }

    function updateTypeMinted(
        BoosterSVGLib.TargetSystem system,
        uint8 subType,
        uint256 newMinted
    ) external onlyRole(ADMIN_ROLE) {
        bytes32 key = _typeKey(system, subType);
        require(newMinted <= typeMaxSupply[key], "Cannot exceed max supply");
        typeMinted[key] = newMinted;
    }

    function pause() external onlyRole(ADMIN_ROLE) { _pause(); }
    function unpause() external onlyRole(ADMIN_ROLE) { _unpause(); }

    // ============ INTERNAL FUNCTIONS ============

    function _typeKey(BoosterSVGLib.TargetSystem system, uint8 subType) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(uint8(system), subType));
    }

    function _calculateRarity(
        uint256 tokenId,
        BoosterSVGLib.TargetSystem targetSystem,
        uint8 subType,
        address minter
    ) private view returns (BoosterSVGLib.Rarity) {
        uint256 randomSeed = uint256(
            keccak256(
                abi.encodePacked(
                    block.prevrandao,
                    tokenId,
                    minter,
                    block.timestamp,
                    targetSystem,
                    subType,
                    block.number
                )
            )
        );

        uint256 roll = randomSeed % 10000;

        // Universal boosters have better rates
        if (targetSystem == BoosterSVGLib.TargetSystem.Universal) {
            if (roll < UNIVERSAL_LEGENDARY_THRESHOLD) return BoosterSVGLib.Rarity.Legendary;
            if (roll < UNIVERSAL_EPIC_THRESHOLD) return BoosterSVGLib.Rarity.Epic;
        } else {
            if (roll < LEGENDARY_THRESHOLD) return BoosterSVGLib.Rarity.Legendary;
            if (roll < EPIC_THRESHOLD) return BoosterSVGLib.Rarity.Epic;
        }

        if (roll < RARE_THRESHOLD) return BoosterSVGLib.Rarity.Rare;
        if (roll < UNCOMMON_THRESHOLD) return BoosterSVGLib.Rarity.Uncommon;
        return BoosterSVGLib.Rarity.Common;
    }

    function _calculatePrimaryBonus(
        BoosterSVGLib.TargetSystem system,
        uint8,
        BoosterSVGLib.Rarity rarity
    ) private pure returns (uint16) {
        // Base bonus per rarity (in basis points)
        uint16 base;
        if (rarity == BoosterSVGLib.Rarity.Legendary) base = 5000;      // 50%
        else if (rarity == BoosterSVGLib.Rarity.Epic) base = 3500;      // 35%
        else if (rarity == BoosterSVGLib.Rarity.Rare) base = 2000;      // 20%
        else if (rarity == BoosterSVGLib.Rarity.Uncommon) base = 1000;  // 10%
        else base = 500;                                                 // 5%

        // Universal boosters get a small bonus
        if (system == BoosterSVGLib.TargetSystem.Universal) {
            base = base * 110 / 100; // +10%
        }

        return base;
    }

    function _calculateSecondaryBonus(
        BoosterSVGLib.TargetSystem system,
        uint8,
        BoosterSVGLib.Rarity rarity
    ) private pure returns (uint16) {
        // Secondary bonus is typically 40-60% of primary
        uint16 base;
        if (rarity == BoosterSVGLib.Rarity.Legendary) base = 3000;      // 30%
        else if (rarity == BoosterSVGLib.Rarity.Epic) base = 2000;      // 20%
        else if (rarity == BoosterSVGLib.Rarity.Rare) base = 1000;      // 10%
        else if (rarity == BoosterSVGLib.Rarity.Uncommon) base = 500;   // 5%
        else base = 0;                                                   // Common has no secondary

        // Universal boosters have multiplier bonus
        if (system == BoosterSVGLib.TargetSystem.Universal && base > 0) {
            base = base + 500; // Extra 5%
        }

        return base;
    }

    function _calculateLevel(BoosterSVGLib.Rarity rarity) private pure returns (uint8) {
        if (rarity == BoosterSVGLib.Rarity.Legendary) return 5;
        if (rarity == BoosterSVGLib.Rarity.Epic) return 4;
        if (rarity == BoosterSVGLib.Rarity.Rare) return 3;
        if (rarity == BoosterSVGLib.Rarity.Uncommon) return 2;
        return 1;
    }

    // ============ MODULAR MERIT OVERRIDES ============

    function _checkDiamondPermission() internal view override {
        _checkRole(DIAMOND_ROLE);
    }

    function _tokenExists(uint256 tokenId) internal view override returns (bool) {
        return _ownerOf(tokenId) != address(0);
    }

    function _isTokenOwner(uint256 tokenId, address account) internal view override returns (bool) {
        return _ownerOf(tokenId) == account;
    }

    function _checkTransferRestrictions(uint256 tokenId) internal view override {
        if (_isAttached[tokenId]) revert CannotTransferWhileAttached();
    }

    function _getApprovedTarget(uint256 tokenId) internal view override returns (address) {
        return _approvedTransferTarget[tokenId];
    }

    function _setApprovedTarget(uint256 tokenId, address target) internal override {
        _approvedTransferTarget[tokenId] = target;
    }

    function _authorizeUpgrade(address) internal override onlyRole(ADMIN_ROLE) {}

    function _update(address to, uint256 tokenId, address auth)
        internal
        override(ERC721Upgradeable, ERC721EnumerableUpgradeable)
        returns (address)
    {
        // Block transfer of attached boosters (except burn)
        if (to != address(0) && _isAttached[tokenId]) {
            revert CannotTransferWhileAttached();
        }
        return super._update(to, tokenId, auth);
    }

    function _increaseBalance(address account, uint128 value)
        internal
        override(ERC721Upgradeable, ERC721EnumerableUpgradeable)
    {
        super._increaseBalance(account, value);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721Upgradeable, ERC721EnumerableUpgradeable, AccessControlUpgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
