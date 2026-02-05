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
import {BuildingSVGLib} from "../../diamonds/modular/libraries/BuildingSVGLib.sol";
import {IBuildingDescriptor} from "./interfaces/IBuildingDescriptor.sol";

/**
 * @title ColonyBuildingCards
 * @notice Building NFT Cards for Colony infrastructure system
 * @dev UUPS upgradeable ERC721 with on-chain SVG generation
 *
 * Building Types:
 * - Warehouse: 500 supply (Storage)
 * - Refinery: 400 supply (Processing)
 * - Laboratory: 300 supply (Research)
 * - DefenseTower: 350 supply (Defense)
 * - TradeHub: 400 supply (Commerce)
 * - EnergyPlant: 350 supply (Energy)
 * - BioLab: 300 supply (Bio)
 * - MiningOutpost: 400 supply (Mining)
 * Total: 3000 NFTs
 *
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 */
contract ColonyBuildingCards is
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
    // Role definitions inherited from ModularMerit:
    // ADMIN_ROLE, MINTER_ROLE, COLONY_WARS_ROLE, DIAMOND_ROLE

    // Rarity thresholds (out of 10000)
    uint256 private constant LEGENDARY_THRESHOLD = 100;   // 1%
    uint256 private constant EPIC_THRESHOLD = 600;        // 5%
    uint256 private constant RARE_THRESHOLD = 2100;       // 15%
    uint256 private constant UNCOMMON_THRESHOLD = 5100;   // 30%
    // Common = remaining 49%

    mapping(uint256 => BuildingSVGLib.BuildingTraits) private _buildingTraits;
    mapping(uint256 => bytes32) private _attachedToColony;
    mapping(uint256 => bool) private _isAttached;

    // Conditional transfer storage
    mapping(uint256 => address) private _approvedTransferTarget;

    mapping(address => uint256) private _walletMintCount;

    uint256 private _tokenIdCounter;

    /// @notice External metadata renderer contract
    IBuildingDescriptor public metadataRenderer;

    /// @notice Maximum total supply
    uint256 public maxSupply;

    /// @notice Maximum mints per wallet
    uint256 public maxMintsPerWallet;

    // Supply limits per building type
    mapping(BuildingSVGLib.BuildingType => uint256) public typeMaxSupply;
    mapping(BuildingSVGLib.BuildingType => uint256) public typeMinted;

    // ==================== EVENTS ====================

    event BuildingMinted(
        uint256 indexed tokenId,
        address indexed recipient,
        BuildingSVGLib.BuildingType buildingType,
        BuildingSVGLib.Rarity rarity
    );
    event BuildingAttached(uint256 indexed tokenId, bytes32 indexed colonyId);
    event BuildingDetached(uint256 indexed tokenId, bytes32 indexed colonyId);
    event BuildingsUpgraded(uint256[] burnedTokens, uint256 indexed newTokenId);
    event BlueprintConstructed(uint256 indexed tokenId, address indexed owner);
    event MetadataRendererUpdated(address indexed oldRenderer, address indexed newRenderer);

    // ==================== ERRORS ====================

    error MaxSupplyReached();
    error TypeMaxSupplyReached();
    error InvalidBuildingType();
    error InvalidRarity();
    error BuildingAlreadyAttached();
    error BuildingNotAttached();
    error CannotTransferWhileAttached();
    error InvalidUpgradeInput();
    error InvalidMetadataRenderer();
    error StillBlueprint();
    error NotBlueprint();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() { _disableInitializers(); }

    function initialize(
        string memory name_,
        string memory symbol_,
        address diamondAddress,
        uint256 collectionId_,
        IBuildingDescriptor _metadataRenderer,
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

        // Set supply limits per building type
        typeMaxSupply[BuildingSVGLib.BuildingType.Warehouse] = 500;
        typeMaxSupply[BuildingSVGLib.BuildingType.Refinery] = 400;
        typeMaxSupply[BuildingSVGLib.BuildingType.Laboratory] = 300;
        typeMaxSupply[BuildingSVGLib.BuildingType.DefenseTower] = 350;
        typeMaxSupply[BuildingSVGLib.BuildingType.TradeHub] = 400;
        typeMaxSupply[BuildingSVGLib.BuildingType.EnergyPlant] = 350;
        typeMaxSupply[BuildingSVGLib.BuildingType.BioLab] = 300;
        typeMaxSupply[BuildingSVGLib.BuildingType.MiningOutpost] = 400;
    }

    // ============ MINTING FUNCTIONS ============

    /**
     * @notice Mint a building card with specific traits
     * @param to Recipient address
     * @param buildingType Type of building
     * @param rarity Rarity tier
     * @param isBlueprint Whether this is an unbuilt blueprint
     */
    function mintBuilding(
        address to,
        BuildingSVGLib.BuildingType buildingType,
        BuildingSVGLib.Rarity rarity,
        bool isBlueprint
    ) external onlyRole(MINTER_ROLE) nonReentrant whenNotPaused returns (uint256) {
        _validateMint(to, 1, buildingType);

        uint256 tokenId = ++_tokenIdCounter;
        typeMinted[buildingType]++;
        _walletMintCount[to]++;

        _buildingTraits[tokenId] = BuildingSVGLib.BuildingTraits({
            buildingType: buildingType,
            rarity: rarity,
            efficiencyBonus: _calculateEfficiencyBonus(buildingType, rarity),
            durabilityLevel: _calculateDurabilityLevel(rarity),
            capacityBonus: _calculateCapacityBonus(buildingType, rarity),
            isBlueprint: isBlueprint
        });

        _safeMint(to, tokenId);
        emit BuildingMinted(tokenId, to, buildingType, rarity);

        return tokenId;
    }

    /**
     * @notice Mint a building card with random rarity
     * @param to Recipient address
     * @param buildingType Type of building
     * @param isBlueprint Whether this is an unbuilt blueprint
     */
    function mintRandomBuilding(
        address to,
        BuildingSVGLib.BuildingType buildingType,
        bool isBlueprint
    ) external onlyRole(MINTER_ROLE) nonReentrant whenNotPaused returns (uint256) {
        _validateMint(to, 1, buildingType);

        uint256 tokenId = ++_tokenIdCounter;
        typeMinted[buildingType]++;
        _walletMintCount[to]++;

        BuildingSVGLib.Rarity rarity = _calculateRarity(tokenId, buildingType, msg.sender);

        _buildingTraits[tokenId] = BuildingSVGLib.BuildingTraits({
            buildingType: buildingType,
            rarity: rarity,
            efficiencyBonus: _calculateEfficiencyBonus(buildingType, rarity),
            durabilityLevel: _calculateDurabilityLevel(rarity),
            capacityBonus: _calculateCapacityBonus(buildingType, rarity),
            isBlueprint: isBlueprint
        });

        _safeMint(to, tokenId);
        emit BuildingMinted(tokenId, to, buildingType, rarity);

        return tokenId;
    }

    /**
     * @notice Batch mint buildings
     */
    function batchMintBuildings(
        address to,
        BuildingSVGLib.BuildingType[] calldata types,
        BuildingSVGLib.Rarity[] calldata rarities,
        bool[] calldata blueprints
    ) external onlyRole(MINTER_ROLE) nonReentrant whenNotPaused returns (uint256[] memory) {
        require(types.length == rarities.length && types.length == blueprints.length, "Length mismatch");
        uint256[] memory tokenIds = new uint256[](types.length);

        for (uint256 i = 0; i < types.length; i++) {
            _validateMint(to, 1, types[i]);

            uint256 tokenId = ++_tokenIdCounter;
            typeMinted[types[i]]++;
            _walletMintCount[to]++;

            _buildingTraits[tokenId] = BuildingSVGLib.BuildingTraits({
                buildingType: types[i],
                rarity: rarities[i],
                efficiencyBonus: _calculateEfficiencyBonus(types[i], rarities[i]),
                durabilityLevel: _calculateDurabilityLevel(rarities[i]),
                capacityBonus: _calculateCapacityBonus(types[i], rarities[i]),
                isBlueprint: blueprints[i]
            });

            _safeMint(to, tokenId);
            tokenIds[i] = tokenId;

            emit BuildingMinted(tokenId, to, types[i], rarities[i]);
        }

        return tokenIds;
    }

    function _validateMint(address to, uint256 amount, BuildingSVGLib.BuildingType buildingType) private view {
        if (_tokenIdCounter + amount > maxSupply) revert MaxSupplyReached();
        if (typeMinted[buildingType] + amount > typeMaxSupply[buildingType]) revert TypeMaxSupplyReached();
        if (_walletMintCount[to] + amount > maxMintsPerWallet) revert MaxSupplyReached();
        if (uint8(buildingType) > 7) revert InvalidBuildingType();
    }

    // ============ ATTACHMENT FUNCTIONS ============

    /**
     * @notice Attach building to a colony
     * @param tokenId Building token ID
     * @param colonyId Colony to attach to
     */
    function attachToColony(uint256 tokenId, bytes32 colonyId)
        external
        onlyRole(COLONY_WARS_ROLE)
        nonReentrant
    {
        if (colonyId == bytes32(0)) revert InvalidBuildingType();
        if (_isAttached[tokenId]) revert BuildingAlreadyAttached();
        if (_buildingTraits[tokenId].isBlueprint) revert StillBlueprint();

        _isAttached[tokenId] = true;
        _attachedToColony[tokenId] = colonyId;

        emit BuildingAttached(tokenId, colonyId);
    }

    /**
     * @notice Detach building from colony
     * @param tokenId Building token ID
     */
    function detachFromColony(uint256 tokenId)
        external
        onlyRole(COLONY_WARS_ROLE)
        nonReentrant
    {
        if (!_isAttached[tokenId]) revert BuildingNotAttached();

        bytes32 colonyId = _attachedToColony[tokenId];
        _isAttached[tokenId] = false;
        delete _attachedToColony[tokenId];

        emit BuildingDetached(tokenId, colonyId);
    }

    // ============ BLUEPRINT CONSTRUCTION ============

    /**
     * @notice Construct a blueprint (converts to actual building)
     * @param tokenId Blueprint token ID
     */
    function constructBlueprint(uint256 tokenId)
        external
        onlyRole(COLONY_WARS_ROLE)
        nonReentrant
        whenNotPaused
    {
        if (!_buildingTraits[tokenId].isBlueprint) revert NotBlueprint();

        _buildingTraits[tokenId].isBlueprint = false;

        emit BlueprintConstructed(tokenId, ownerOf(tokenId));
    }

    // ============ UPGRADE FUNCTION ============

    /**
     * @notice Combine 3 buildings of same type and rarity to upgrade
     * @param tokenIds Array of 3 token IDs to combine
     */
    function upgradeBuildings(uint256[] calldata tokenIds)
        external
        onlyRole(COLONY_WARS_ROLE)
        nonReentrant
        whenNotPaused
        returns (uint256)
    {
        if (tokenIds.length != 3) revert InvalidUpgradeInput();

        BuildingSVGLib.BuildingType bType = _buildingTraits[tokenIds[0]].buildingType;
        BuildingSVGLib.Rarity baseRarity = _buildingTraits[tokenIds[0]].rarity;

        // Validate all tokens
        for (uint256 i = 1; i < 3; i++) {
            if (_buildingTraits[tokenIds[i]].buildingType != bType) revert InvalidUpgradeInput();
            if (_buildingTraits[tokenIds[i]].rarity != baseRarity) revert InvalidUpgradeInput();
            if (_isAttached[tokenIds[i]]) revert CannotTransferWhileAttached();
            if (_buildingTraits[tokenIds[i]].isBlueprint) revert StillBlueprint();
        }

        // Cannot upgrade Legendary
        if (baseRarity == BuildingSVGLib.Rarity.Legendary) revert InvalidUpgradeInput();
        address tokenOwner = ownerOf(tokenIds[0]);

        // Burn old tokens
        for (uint256 i = 0; i < 3; i++) {
            _burn(tokenIds[i]);
        }

        // Mint upgraded token
        BuildingSVGLib.Rarity newRarity = BuildingSVGLib.Rarity(uint8(baseRarity) + 1);
        uint256 newTokenId = ++_tokenIdCounter;

        _buildingTraits[newTokenId] = BuildingSVGLib.BuildingTraits({
            buildingType: bType,
            rarity: newRarity,
            efficiencyBonus: _calculateEfficiencyBonus(bType, newRarity),
            durabilityLevel: _calculateDurabilityLevel(newRarity),
            capacityBonus: _calculateCapacityBonus(bType, newRarity),
            isBlueprint: false
        });

        _safeMint(tokenOwner, newTokenId);
        emit BuildingsUpgraded(tokenIds, newTokenId);

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

        BuildingSVGLib.BuildingTraits memory traits = _buildingTraits[tokenId];

        IBuildingDescriptor.BuildingMetadata memory metadata = IBuildingDescriptor.BuildingMetadata({
            tokenId: tokenId,
            buildingType: traits.buildingType,
            rarity: traits.rarity,
            efficiencyBonus: traits.efficiencyBonus,
            durabilityLevel: traits.durabilityLevel,
            capacityBonus: traits.capacityBonus,
            isBlueprint: traits.isBlueprint,
            isAttached: _isAttached[tokenId],
            attachedToColony: _attachedToColony[tokenId]
        });

        return metadataRenderer.tokenURI(metadata);
    }

    function contractURI() public view returns (string memory) {
        return metadataRenderer.contractURI();
    }

    function walletMintCount(address wallet) external view returns (uint256) {
        return _walletMintCount[wallet];
    }

    function getTraits(uint256 tokenId)
        external
        view
        returns (BuildingSVGLib.BuildingTraits memory)
    {
        _requireOwned(tokenId);
        return _buildingTraits[tokenId];
    }

    function getAttachedColony(uint256 tokenId) external view returns (bytes32) {
        return _attachedToColony[tokenId];
    }

    function isAttached(uint256 tokenId) external view returns (bool) {
        return _isAttached[tokenId];
    }

    function isBlueprint(uint256 tokenId) external view returns (bool) {
        return _buildingTraits[tokenId].isBlueprint;
    }

    /**
     * @notice Get total efficiency bonus for a building
     */
    function getTotalEfficiency(uint256 tokenId) external view returns (uint256) {
        BuildingSVGLib.BuildingTraits memory traits = _buildingTraits[tokenId];
        return uint256(traits.efficiencyBonus) * uint256(traits.durabilityLevel);
    }

    // ============ TRANSFER FUNCTIONS (Model D via ModularMerit) ============

    function requestTransfer(uint256 tokenId, address to) external {
        _requestTransfer(tokenId, to);
    }

    function approveTransfer(uint256 tokenId, address to)
        external
        onlyRole(COLONY_WARS_ROLE)
    {
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
        return uint256(_attachedToColony[tokenId]);
    }

    // ============ ADMIN FUNCTIONS ============

    function setMetadataRenderer(IBuildingDescriptor _metadataRenderer) external onlyRole(ADMIN_ROLE) {
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

    function pause() external onlyRole(ADMIN_ROLE) { _pause(); }
    function unpause() external onlyRole(ADMIN_ROLE) { _unpause(); }

    function updateTypeMaxSupply(
        BuildingSVGLib.BuildingType buildingType,
        uint256 newMax
    ) external onlyRole(ADMIN_ROLE) {
        require(newMax >= typeMinted[buildingType], "Cannot set below minted");
        typeMaxSupply[buildingType] = newMax;
    }

    // ============ INTERNAL FUNCTIONS ============

    function _calculateRarity(
        uint256 tokenId,
        BuildingSVGLib.BuildingType buildingType,
        address minter
    ) private view returns (BuildingSVGLib.Rarity) {
        uint256 randomSeed = uint256(
            keccak256(
                abi.encodePacked(
                    block.prevrandao,
                    tokenId,
                    minter,
                    block.timestamp,
                    buildingType,
                    block.number
                )
            )
        );

        uint256 roll = randomSeed % 10000;

        if (roll < LEGENDARY_THRESHOLD) return BuildingSVGLib.Rarity.Legendary;
        if (roll < EPIC_THRESHOLD) return BuildingSVGLib.Rarity.Epic;
        if (roll < RARE_THRESHOLD) return BuildingSVGLib.Rarity.Rare;
        if (roll < UNCOMMON_THRESHOLD) return BuildingSVGLib.Rarity.Uncommon;
        return BuildingSVGLib.Rarity.Common;
    }

    /**
     * @notice Calculate efficiency bonus based on type and rarity
     */
    function _calculateEfficiencyBonus(
        BuildingSVGLib.BuildingType bType,
        BuildingSVGLib.Rarity rarity
    ) private pure returns (uint8) {
        uint8 baseEfficiency;

        // Base efficiency by building type (100 = 100%)
        if (bType == BuildingSVGLib.BuildingType.Warehouse) {
            baseEfficiency = 100;
        } else if (bType == BuildingSVGLib.BuildingType.Refinery) {
            baseEfficiency = 105;
        } else if (bType == BuildingSVGLib.BuildingType.Laboratory) {
            baseEfficiency = 110;
        } else if (bType == BuildingSVGLib.BuildingType.DefenseTower) {
            baseEfficiency = 100;
        } else if (bType == BuildingSVGLib.BuildingType.TradeHub) {
            baseEfficiency = 108;
        } else if (bType == BuildingSVGLib.BuildingType.EnergyPlant) {
            baseEfficiency = 106;
        } else if (bType == BuildingSVGLib.BuildingType.BioLab) {
            baseEfficiency = 107;
        } else {
            baseEfficiency = 104; // MiningOutpost
        }

        // Rarity multiplier
        if (rarity == BuildingSVGLib.Rarity.Legendary) return baseEfficiency + 50;
        if (rarity == BuildingSVGLib.Rarity.Epic) return baseEfficiency + 35;
        if (rarity == BuildingSVGLib.Rarity.Rare) return baseEfficiency + 20;
        if (rarity == BuildingSVGLib.Rarity.Uncommon) return baseEfficiency + 10;
        return baseEfficiency;
    }

    /**
     * @notice Calculate durability level based on rarity
     */
    function _calculateDurabilityLevel(BuildingSVGLib.Rarity rarity) private pure returns (uint8) {
        if (rarity == BuildingSVGLib.Rarity.Legendary) return 5;
        if (rarity == BuildingSVGLib.Rarity.Epic) return 4;
        if (rarity == BuildingSVGLib.Rarity.Rare) return 3;
        if (rarity == BuildingSVGLib.Rarity.Uncommon) return 2;
        return 1;
    }

    /**
     * @notice Calculate capacity bonus based on type and rarity
     */
    function _calculateCapacityBonus(
        BuildingSVGLib.BuildingType bType,
        BuildingSVGLib.Rarity rarity
    ) private pure returns (uint16) {
        uint16 baseCapacity;

        // Only storage/production buildings get capacity bonus
        if (bType == BuildingSVGLib.BuildingType.Warehouse) {
            baseCapacity = 50; // 50% base capacity
        } else if (bType == BuildingSVGLib.BuildingType.EnergyPlant ||
                   bType == BuildingSVGLib.BuildingType.BioLab ||
                   bType == BuildingSVGLib.BuildingType.MiningOutpost) {
            baseCapacity = 25; // 25% base for generators
        } else {
            baseCapacity = 0; // Other buildings don't have capacity
        }

        if (baseCapacity == 0) return 0;

        // Apply rarity multiplier
        if (rarity == BuildingSVGLib.Rarity.Legendary) return baseCapacity * 3;
        if (rarity == BuildingSVGLib.Rarity.Epic) return baseCapacity * 2 + baseCapacity / 2;
        if (rarity == BuildingSVGLib.Rarity.Rare) return baseCapacity * 2;
        if (rarity == BuildingSVGLib.Rarity.Uncommon) return baseCapacity + baseCapacity / 2;
        return baseCapacity;
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
        // Block transfer of attached buildings (except burn)
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
