// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import {ERC721EnumerableUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721EnumerableUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {IColonyReserveNotes, IRewardRedeemable} from "./IColonyReserveNotes.sol";
import {INotesMetadataDescriptor, INotesDataProvider} from "./INotesMetadataDescriptor.sol";

/**
 * @title IYellowToken
 * @notice Interface for YLW token with mint capability
 */
interface IYellowToken is IERC20 {
    function mint(address to, uint256 amount, string calldata reason) external;
}

/**
 * @title ColonyReserveNotes
 * @notice ERC-721 NFT collection representing YLW-backed banknotes
 * @dev OpenZeppelin v5+ contracts-upgradeable with UUPS proxy pattern
 *      Features:
 *      - Configurable collection metadata
 *      - Multiple series with individual base image URIs
 *      - Configurable denominations with YLW values
 *      - Configurable rarity variants with probability weights
 *      - On-chain metadata generation (tokenURI, contractURI)
 *      - Treasury + Mint fallback for YLW redemption
 *      - IRewardRedeemable integration for CollaborativeCraftingFacet
 *
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 */
contract ColonyReserveNotes is
    Initializable,
    ERC721Upgradeable,
    ERC721EnumerableUpgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable,
    IColonyReserveNotes,
    IRewardRedeemable,
    INotesDataProvider
{
    using SafeERC20 for IERC20;
    using Strings for uint256;
    using Strings for uint32;

    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTANTS - Roles
    // ═══════════════════════════════════════════════════════════════════════════

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    // ═══════════════════════════════════════════════════════════════════════════
    // STORAGE
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Collection metadata configuration (includes ylwToken, treasury)
    CollectionConfig private _collectionConfig;

    /// @notice Reward system configuration
    RewardConfig private _rewardConfig;

    /// @notice Next token ID counter
    uint256 private _nextTokenId;

    /// @notice Series configurations: seriesId => config
    mapping(bytes2 => SeriesConfig) private _series;

    /// @notice List of all series IDs ("AA"=0x4141, "AB"=0x4142, etc.)
    bytes2[] private _seriesIds;

    /// @notice Denomination configurations: denominationId => config
    mapping(uint8 => DenominationConfig) private _denominations;

    /// @notice List of all denomination IDs
    uint8[] private _denominationIds;

    /// @notice Denomination IDs sorted by value descending (for greedy decomposition)
    uint8[] private _sortedDenomIdsByValue;

    /// @notice Rarity configurations: rarity => config
    mapping(Rarity => RarityConfig) private _rarityConfigs;

    /// @notice Note data per token: tokenId => NoteData
    mapping(uint256 => NoteData) private _notes;

    /// @notice Serial counters: seriesId => denominationId => counter
    mapping(bytes2 => mapping(uint8 => uint32)) public serialCounters;

    // === Reward System (IRewardRedeemable) ===

    /// @notice Tier to reward value mapping: tierId => YLW value in wei
    mapping(uint256 => uint256) public tierToRewardValue;

    /// @notice Reward supply limits per denomination: denominationId => max supply
    mapping(uint8 => uint32) public rewardSupplyLimits;

    /// @notice Reward mint counts per denomination: denominationId => minted count
    mapping(uint8 => uint32) public rewardMintCounts;

    /// @notice External metadata descriptor contract
    INotesMetadataDescriptor public metadataDescriptor;

    // ═══════════════════════════════════════════════════════════════════════════
    // MODIFIERS
    // ═══════════════════════════════════════════════════════════════════════════

    modifier tokenExists(uint256 tokenId) {
        if (_ownerOf(tokenId) == address(0)) revert TokenDoesNotExist(tokenId);
        _;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INITIALIZER
    // ═══════════════════════════════════════════════════════════════════════════

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the contract
     * @param name_ Token name
     * @param symbol_ Token symbol
     * @param ylwToken_ YLW token address
     * @param treasury_ Treasury address
     * @param admin_ Default admin address
     */
    function initialize(
        string memory name_,
        string memory symbol_,
        address ylwToken_,
        address treasury_,
        address admin_
    ) external initializer {
        if (ylwToken_ == address(0)) revert InvalidAddress();
        if (treasury_ == address(0)) revert InvalidAddress();
        if (admin_ == address(0)) revert InvalidAddress();

        __ERC721_init(name_, symbol_);
        __ERC721Enumerable_init();
        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        // Setup roles
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(ADMIN_ROLE, admin_);

        // Initialize storage
        _collectionConfig.name = name_;
        _collectionConfig.symbol = symbol_;
        _collectionConfig.ylwToken = ylwToken_;
        _collectionConfig.treasury = treasury_;
        _nextTokenId = 1;

        // Initialize default rarity configs
        _initializeDefaultRarities();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ADMIN: COLLECTION CONFIG
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Configure collection metadata
     */
    function configureCollection(CollectionConfig calldata config) external onlyRole(ADMIN_ROLE) {
        _collectionConfig = config;
        emit CollectionConfigured(config.name, config.symbol);
    }

    /**
     * @notice Set metadata descriptor contract
     */
    function setMetadataDescriptor(address descriptor) external onlyRole(ADMIN_ROLE) {
        if (descriptor == address(0)) revert InvalidAddress();
        metadataDescriptor = INotesMetadataDescriptor(descriptor);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ADMIN: SERIES CONFIG
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Configure a series
     * @dev seriesId is bytes2 encoding two ASCII chars: "AA"=0x4141, "AB"=0x4142, "BA"=0x4241
     */
    function configureSeries(SeriesConfig calldata config) external onlyRole(ADMIN_ROLE) {
        bytes2 seriesId = config.seriesId;

        // Track new series
        if (_series[seriesId].seriesId == 0) {
            _seriesIds.push(seriesId);
        }

        _series[seriesId] = config;
        emit SeriesConfigured(seriesId, config.name, config.baseImageUri);
    }

    /**
     * @notice Set series active status
     */
    function setSeriesActive(bytes2 seriesId, bool active) external onlyRole(ADMIN_ROLE) {
        if (_series[seriesId].seriesId == 0) revert SeriesNotFound(seriesId);
        _series[seriesId].active = active;
        emit SeriesActiveChanged(seriesId, active);
    }

    /**
     * @notice Update series base image URI
     */
    function setSeriesBaseImageUri(bytes2 seriesId, string calldata baseImageUri) external onlyRole(ADMIN_ROLE) {
        if (_series[seriesId].seriesId == 0) revert SeriesNotFound(seriesId);
        _series[seriesId].baseImageUri = baseImageUri;
        emit SeriesConfigured(seriesId, _series[seriesId].name, baseImageUri);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ADMIN: DENOMINATION CONFIG
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Configure a denomination
     */
    function configureDenomination(DenominationConfig calldata config) external onlyRole(ADMIN_ROLE) {
        uint8 denomId = config.denominationId;

        // Track new denomination
        bool exists = false;
        for (uint256 i = 0; i < _denominationIds.length; i++) {
            if (_denominationIds[i] == denomId) {
                exists = true;
                break;
            }
        }
        if (!exists) {
            _denominationIds.push(denomId);
        }

        _denominations[denomId] = config;

        // Rebuild sorted array (only done during configuration, not at runtime)
        _rebuildSortedDenominations();

        emit DenominationConfigured(denomId, config.name, config.ylwValue);
    }

    /**
     * @notice Set denomination active status
     */
    function setDenominationActive(uint8 denominationId, bool active) external onlyRole(ADMIN_ROLE) {
                if (bytes(_denominations[denominationId].name).length == 0) {
            revert DenominationNotFound(denominationId);
        }
        _denominations[denominationId].active = active;
        emit DenominationActiveChanged(denominationId, active);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ADMIN: RARITY CONFIG
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Configure a rarity level
     * @dev Sum of all weights should equal 10000 for proper probability distribution
     */
    function configureRarity(RarityConfig calldata config) external onlyRole(ADMIN_ROLE) {
        _rarityConfigs[config.rarity] = config;
        emit RarityConfigured(config.rarity, config.name, config.weightBps, config.bonusMultiplierBps);
    }

    /**
     * @notice Batch configure all rarities
     * @dev Validates that total weight equals 10000
     */
    function configureRarities(RarityConfig[] calldata configs) external onlyRole(ADMIN_ROLE) {
        uint16 newTotalWeight = 0;

        for (uint256 i = 0; i < configs.length; i++) {
            _rarityConfigs[configs[i].rarity] = configs[i];
            newTotalWeight += configs[i].weightBps;
            emit RarityConfigured(
                configs[i].rarity,
                configs[i].name,
                configs[i].weightBps,
                configs[i].bonusMultiplierBps
            );
        }

        if (newTotalWeight != 10000) revert InvalidRarityWeights();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ADMIN: TREASURY & TOKEN CONFIG
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Set treasury address
     */
    function setTreasuryAddress(address newTreasury) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newTreasury == address(0)) revert InvalidAddress();
        address oldTreasury = _collectionConfig.treasury;
        _collectionConfig.treasury = newTreasury;
        emit TreasuryUpdated(oldTreasury, newTreasury);
    }

    /**
     * @notice Set YLW token address
     */
    function setYlwTokenAddress(address newYlwToken) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newYlwToken == address(0)) revert InvalidAddress();
        address oldToken = _collectionConfig.ylwToken;
        _collectionConfig.ylwToken = newYlwToken;
        emit YlwTokenUpdated(oldToken, newYlwToken);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ADMIN: REWARD SYSTEM CONFIG (IRewardRedeemable)
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Configure a reward tier
     * @param tierId Tier ID from CollaborativeCraftingFacet (1-4)
     * @param rewardValue Total YLW value for this tier
     */
    function configureRewardTier(uint256 tierId, uint256 rewardValue) external onlyRole(ADMIN_ROLE) {
        if (tierId == 0) revert InvalidTier();
        tierToRewardValue[tierId] = rewardValue;
        emit RewardTierConfigured(tierId, rewardValue);
    }

    /**
     * @notice Batch configure reward tiers
     */
    function configureRewardTiersBatch(
        uint256[] calldata tierIds,
        uint256[] calldata rewardValues
    ) external onlyRole(ADMIN_ROLE) {
        if (tierIds.length != rewardValues.length) revert ArrayLengthMismatch();

                for (uint256 i = 0; i < tierIds.length; i++) {
            if (tierIds[i] == 0) revert InvalidTier();
            tierToRewardValue[tierIds[i]] = rewardValues[i];
            emit RewardTierConfigured(tierIds[i], rewardValues[i]);
        }
    }

    /**
     * @notice Set the series used for reward minting
     */
    function setRewardSeries(bytes2 seriesId) external onlyRole(ADMIN_ROLE) {
        if (_series[seriesId].seriesId == 0) revert SeriesNotFound(seriesId);
        _rewardConfig.rewardSeries = seriesId;
        emit RewardSystemConfigured(seriesId, _rewardConfig.enabled);
    }

    /**
     * @notice Set supply limit for a denomination in reward system
     * @param denominationId Denomination ID
     * @param limit Max supply (0 = unlimited)
     */
    function setRewardSupplyLimit(uint8 denominationId, uint32 limit) external onlyRole(ADMIN_ROLE) {
        rewardSupplyLimits[denominationId] = limit;
        emit RewardSupplyLimitSet(denominationId, limit);
    }

    /**
     * @notice Enable/disable reward system
     */
    function setRewardSystemEnabled(bool enabled) external onlyRole(ADMIN_ROLE) {
        _rewardConfig.enabled = enabled;
        emit RewardSystemConfigured(_rewardConfig.rewardSeries, enabled);
    }

    /**
     * @notice Reset reward mint counts (new season)
     */
    function resetRewardMintCounts() external onlyRole(ADMIN_ROLE) {
        for (uint256 i = 0; i < _denominationIds.length; i++) {
            rewardMintCounts[_denominationIds[i]] = 0;
        }
    }

    /**
     * @notice Correct serial number for an existing note (migration/fix)
     * @param tokenId Token ID to correct
     * @param newSerialNumber New serial number to set
     */
    function correctNoteSerialNumber(uint256 tokenId, uint32 newSerialNumber) external onlyRole(ADMIN_ROLE) {
        if (_ownerOf(tokenId) == address(0)) revert TokenDoesNotExist(tokenId);
        _notes[tokenId].serialNumber = newSerialNumber;
    }

    /**
     * @notice Batch correct serial numbers for multiple notes
     * @param tokenIds Array of token IDs
     * @param newSerialNumbers Array of new serial numbers
     */
    function correctNoteSerialNumbers(
        uint256[] calldata tokenIds,
        uint32[] calldata newSerialNumbers
    ) external onlyRole(ADMIN_ROLE) {
        if (tokenIds.length != newSerialNumbers.length) revert ArrayLengthMismatch();

        for (uint256 i = 0; i < tokenIds.length; i++) {
            if (_ownerOf(tokenIds[i]) == address(0)) revert TokenDoesNotExist(tokenIds[i]);
            _notes[tokenIds[i]].serialNumber = newSerialNumbers[i];
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ADMIN: PAUSABLE
    // ═══════════════════════════════════════════════════════════════════════════

    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MINTING
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @inheritdoc IColonyReserveNotes
     */
    function mintNote(
        address to,
        uint8 denominationId,
        bytes2 seriesId
    ) external onlyRole(MINTER_ROLE) whenNotPaused returns (uint256 tokenId) {
        _validateMintParams(denominationId, seriesId);

        uint256 seed = _generateSeed(to, _nextTokenId);
        Rarity rarity = _selectRarity(seed);

        return _mintNote(to, denominationId, seriesId, rarity);
    }

    /**
     * @inheritdoc IColonyReserveNotes
     */
    function mintNoteWithRarity(
        address to,
        uint8 denominationId,
        bytes2 seriesId,
        Rarity rarity
    ) external onlyRole(MINTER_ROLE) whenNotPaused returns (uint256 tokenId) {
        _validateMintParams(denominationId, seriesId);
        if (_rarityConfigs[rarity].weightBps == 0) revert RarityNotConfigured(rarity);

        return _mintNote(to, denominationId, seriesId, rarity);
    }

    /**
     * @inheritdoc IColonyReserveNotes
     */
    function mintNoteBatch(
        address to,
        uint8 denominationId,
        bytes2 seriesId,
        uint32 count
    ) external onlyRole(MINTER_ROLE) whenNotPaused returns (uint256[] memory tokenIds) {
        if (count == 0) revert InvalidAmount();
        _validateMintParams(denominationId, seriesId);

        tokenIds = new uint256[](count);

        for (uint32 i = 0; i < count; i++) {
            uint256 seed = _generateSeed(to, _nextTokenId + i);
            Rarity rarity = _selectRarity(seed);

            tokenIds[i] = _mintNote(to, denominationId, seriesId, rarity);
        }

        return tokenIds;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // IRewardRedeemable IMPLEMENTATION
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @inheritdoc IRewardRedeemable
     * @dev Mints banknotes to recipient based on tier reward value
     *      Decomposes the reward value into optimal banknote denominations
     */
    function mintReward(
        uint256 /* collectionId */,
        uint256 tierId,
        address to,
        uint256 /* amount */
    ) external onlyRole(MINTER_ROLE) whenNotPaused returns (uint256 tokenId) {
        if (!_rewardConfig.enabled) revert RewardSystemDisabled();
        if (tierId == 0) revert InvalidTier();

        uint256 rewardValue = tierToRewardValue[tierId];
        if (rewardValue == 0) revert TierNotConfigured(tierId);

        // Decompose reward into banknotes
        (uint8[] memory denomIds, uint32[] memory counts) = _decomposeToNotes(rewardValue);

        // Mint all notes, return first tokenId
        uint256 firstTokenId = 0;
        bytes2 seriesId = _rewardConfig.rewardSeries;

        for (uint256 i = 0; i < denomIds.length; i++) {
            for (uint32 j = 0; j < counts[i]; j++) {
                uint256 seed = _generateSeed(to, _nextTokenId);
                Rarity rarity = _selectRarity(seed);
                uint256 newTokenId = _mintNote(to, denomIds[i], seriesId, rarity);

                // Track reward mint counts
                rewardMintCounts[denomIds[i]]++;

                if (firstTokenId == 0) {
                    firstTokenId = newTokenId;
                }
            }
        }

        return firstTokenId;
    }

    /**
     * @inheritdoc IRewardRedeemable
     */
    function batchMintReward(
        uint256 collectionId,
        uint256[] calldata tierIds,
        address to,
        uint256[] calldata /* amounts */
    ) external onlyRole(MINTER_ROLE) whenNotPaused returns (uint256[] memory tokenIds) {
        tokenIds = new uint256[](tierIds.length);

        for (uint256 i = 0; i < tierIds.length; i++) {
            tokenIds[i] = this.mintReward(collectionId, tierIds[i], to, 1);
        }

        return tokenIds;
    }

    /**
     * @inheritdoc IRewardRedeemable
     */
    function canMintReward(
        uint256 /* collectionId */,
        uint256 tierId,
        uint256 /* amount */
    ) external view returns (bool canMint) {
        if (!_rewardConfig.enabled) return false;
        if (tierId == 0) return false;

        uint256 rewardValue = tierToRewardValue[tierId];
        if (rewardValue == 0) return false;

        // Check if we can decompose
        (uint8[] memory denomIds, uint32[] memory counts) = _decomposeToNotes(rewardValue);

        // Check supply limits
        for (uint256 i = 0; i < denomIds.length; i++) {
            uint32 limit = rewardSupplyLimits[denomIds[i]];
            if (limit > 0) {
                uint32 minted = rewardMintCounts[denomIds[i]];
                if (minted + counts[i] > limit) {
                    return false;
                }
            }
        }

        return true;
    }

    /**
     * @inheritdoc IRewardRedeemable
     */
    function getRemainingSupply(
        uint256 /* collectionId */,
        uint256 tierId
    ) external view returns (uint256 remaining) {
        
        uint256 rewardValue = tierToRewardValue[tierId];
        if (rewardValue == 0) return 0;

        (uint8[] memory denomIds, uint32[] memory counts) = _decomposeToNotes(rewardValue);

        // Find the minimum remaining across all denominations
        remaining = type(uint256).max;
        for (uint256 i = 0; i < denomIds.length; i++) {
            uint32 limit = rewardSupplyLimits[denomIds[i]];
            if (limit > 0) {
                uint32 minted = rewardMintCounts[denomIds[i]];
                uint32 available = minted >= limit ? 0 : limit - minted;
                uint256 canMintTimes = counts[i] > 0 ? available / counts[i] : type(uint256).max;
                if (canMintTimes < remaining) {
                    remaining = canMintTimes;
                }
            }
        }

        if (remaining == type(uint256).max) {
            remaining = 0; // Indicates unlimited
        }

        return remaining;
    }

    /**
     * @notice Preview how a reward value will be decomposed into notes
     * @param rewardValue Total YLW value to decompose
     * @return denomIds Denomination IDs
     * @return counts Number of each denomination
     */
    function previewDecomposeReward(uint256 rewardValue)
        external
        view
        returns (uint8[] memory denomIds, uint32[] memory counts)
    {
        return _decomposeToNotes(rewardValue);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // REDEMPTION
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @inheritdoc IColonyReserveNotes
     */
    function redeemNote(uint256 tokenId) external nonReentrant whenNotPaused tokenExists(tokenId) {
        if (ownerOf(tokenId) != msg.sender) revert NotOwner();

                NoteData memory note = _notes[tokenId];
        uint256 ylwAmount = _calculateNoteValue(note);

        // Burn NFT first
        _burn(tokenId);
        delete _notes[tokenId];

        // Send YLW with Treasury + Mint fallback
        _sendYlwWithFallback(msg.sender, ylwAmount);

        emit NoteRedeemed(tokenId, msg.sender, ylwAmount, note.rarity);
    }

    /**
     * @notice Redeem a note on behalf of the owner (for facet delegation)
     * @dev Called by AchievementRewardFacet via Diamond. Recipient must be the token owner.
     * @param tokenId Token to redeem
     * @param recipient Address to receive YLW (must be token owner)
     * @return ylwAmount Amount of YLW sent
     */
    function redeemReward(
        uint256 tokenId,
        address recipient
    ) external onlyRole(MINTER_ROLE) nonReentrant whenNotPaused tokenExists(tokenId) returns (uint256 ylwAmount) {
        // Verify recipient is the owner
        if (ownerOf(tokenId) != recipient) revert NotOwner();

        NoteData memory note = _notes[tokenId];
        ylwAmount = _calculateNoteValue(note);

        // Burn NFT first
        _burn(tokenId);
        delete _notes[tokenId];

        // Send YLW to recipient
        _sendYlwWithFallback(recipient, ylwAmount);

        emit NoteRedeemed(tokenId, recipient, ylwAmount, note.rarity);
    }

    /**
     * @notice Get the YLW value of a reward token (alias for getNoteValue)
     * @param tokenId Token to query
     * @return ylwAmount YLW value in wei
     */
    function getRewardValue(uint256 tokenId) external view tokenExists(tokenId) returns (uint256 ylwAmount) {
        return _calculateNoteValue(_notes[tokenId]);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @inheritdoc IColonyReserveNotes
     */
    function getNoteValue(uint256 tokenId) external view tokenExists(tokenId) returns (uint256 ylwAmount) {
        return _calculateNoteValue(_notes[tokenId]);
    }

    /**
     * @inheritdoc IColonyReserveNotes
     */
    function getNoteData(uint256 tokenId)
        external
        view
        override(IColonyReserveNotes, INotesDataProvider)
        tokenExists(tokenId)
        returns (NoteData memory data)
    {
        return _notes[tokenId];
    }

    /**
     * @inheritdoc IColonyReserveNotes
     */
    function getSerialNumber(uint256 tokenId) external view tokenExists(tokenId) returns (string memory serial) {
        return _formatSerialNumber(_notes[tokenId]);
    }

    /**
     * @inheritdoc IColonyReserveNotes
     */
    function getSeriesConfig(bytes2 seriesId)
        external
        view
        override(IColonyReserveNotes, INotesDataProvider)
        returns (SeriesConfig memory config)
    {
        return _series[seriesId];
    }

    /**
     * @inheritdoc IColonyReserveNotes
     */
    function getDenominationConfig(uint8 denominationId)
        external
        view
        override(IColonyReserveNotes, INotesDataProvider)
        returns (DenominationConfig memory config)
    {
        return _denominations[denominationId];
    }

    /**
     * @inheritdoc IColonyReserveNotes
     */
    function getRarityConfig(Rarity rarity)
        external
        view
        override(IColonyReserveNotes, INotesDataProvider)
        returns (RarityConfig memory config)
    {
        return _rarityConfigs[rarity];
    }

    /**
     * @inheritdoc IColonyReserveNotes
     */
    function getActiveSeriesIds() external view returns (bytes2[] memory seriesIds) {
        uint256 activeCount = 0;
        for (uint256 i = 0; i < _seriesIds.length; i++) {
            if (_series[_seriesIds[i]].active) activeCount++;
        }

        seriesIds = new bytes2[](activeCount);
        uint256 index = 0;
        for (uint256 i = 0; i < _seriesIds.length; i++) {
            if (_series[_seriesIds[i]].active) {
                seriesIds[index++] = _seriesIds[i];
            }
        }
    }

    /**
     * @inheritdoc IColonyReserveNotes
     */
    function getActiveDenominationIds() external view returns (uint8[] memory denominationIds) {
                uint256 activeCount = 0;
        for (uint256 i = 0; i < _denominationIds.length; i++) {
            if (_denominations[_denominationIds[i]].active) activeCount++;
        }

        denominationIds = new uint8[](activeCount);
        uint256 index = 0;
        for (uint256 i = 0; i < _denominationIds.length; i++) {
            if (_denominations[_denominationIds[i]].active) {
                denominationIds[index++] = _denominationIds[i];
            }
        }
    }

    /// @notice Get collection configuration
    function getCollectionConfig() external view override(INotesDataProvider) returns (CollectionConfig memory) {
        return _collectionConfig;
    }

    /// @notice Get reward system configuration
    function getRewardConfig() external view returns (RewardConfig memory) {
        return _rewardConfig;
    }

    /// @notice Get tier reward value
    function getTierRewardValue(uint256 tierId) external view returns (uint256) {
        return tierToRewardValue[tierId];
    }

    /// @notice Get reward supply info for denomination
    function getRewardSupplyInfo(uint8 denominationId) external view returns (uint32 limit, uint32 minted) {
                return (rewardSupplyLimits[denominationId], rewardMintCounts[denominationId]);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // METADATA (DELEGATED TO NotesMetadataDescriptor)
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Generate token metadata URI
     * @dev Delegates to external metadata descriptor using callback pattern
     */
    function tokenURI(uint256 tokenId)
        public
        view
        override(ERC721Upgradeable, IColonyReserveNotes)
        tokenExists(tokenId)
        returns (string memory)
    {
        require(address(metadataDescriptor) != address(0), "Metadata descriptor not set");
        return metadataDescriptor.tokenURI(address(this), tokenId);
    }

    /**
     * @notice Generate collection metadata URI
     * @dev Delegates to external metadata descriptor using callback pattern
     */
    function contractURI() external view returns (string memory) {
        require(address(metadataDescriptor) != address(0), "Metadata descriptor not set");
        return metadataDescriptor.contractURI(address(this));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INTERNAL FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    function _initializeDefaultRarities() internal {
        _rarityConfigs[Rarity.Common] = RarityConfig(Rarity.Common, "Common", "-common", 6000, 10000);
        _rarityConfigs[Rarity.Uncommon] = RarityConfig(Rarity.Uncommon, "Uncommon", "-uncommon", 2500, 10000);
        _rarityConfigs[Rarity.Rare] = RarityConfig(Rarity.Rare, "Rare", "-rare", 1000, 10250);
        _rarityConfigs[Rarity.Epic] = RarityConfig(Rarity.Epic, "Epic", "-epic", 400, 10500);
        _rarityConfigs[Rarity.Legendary] = RarityConfig(Rarity.Legendary, "Legendary", "-legendary", 100, 11000);
    }

    function _validateMintParams(
        uint8 denominationId,
        bytes2 seriesId
    ) internal view {
        SeriesConfig memory seriesConf = _series[seriesId];
        if (seriesConf.seriesId == 0) revert SeriesNotFound(seriesId);
        if (!seriesConf.active) revert SeriesNotActive(seriesId);

        // Check series timing
        if (seriesConf.startTime > 0 && block.timestamp < seriesConf.startTime) {
            revert SeriesNotActive(seriesId);
        }
        if (seriesConf.endTime > 0 && block.timestamp > seriesConf.endTime) {
            revert SeriesNotActive(seriesId);
        }

        // Check series max supply
        if (seriesConf.maxSupply > 0 && seriesConf.mintedCount >= seriesConf.maxSupply) {
            revert SeriesMaxSupplyReached(seriesId);
        }

        DenominationConfig memory denomConf = _denominations[denominationId];
        if (bytes(denomConf.name).length == 0) revert DenominationNotFound(denominationId);
        if (!denomConf.active) revert DenominationNotActive(denominationId);
    }

    function _mintNote(
        address to,
        uint8 denominationId,
        bytes2 seriesId,
        Rarity rarity
    ) internal returns (uint256 tokenId) {
        tokenId = _nextTokenId++;

        // Increment serial counter and apply denomination offset for global serial
        uint32 serialNumber = _denominations[denominationId].serialOffset + ++serialCounters[seriesId][denominationId];

        // Increment series minted count
        _series[seriesId].mintedCount++;

        // Store note data
        _notes[tokenId] = NoteData({
            denominationId: denominationId,
            seriesId: seriesId,
            rarity: rarity,
            serialNumber: serialNumber,
            mintedAt: uint32(block.timestamp)
        });

        _safeMint(to, tokenId);

        emit NoteMinted(tokenId, to, denominationId, seriesId, rarity, serialNumber);

        return tokenId;
    }

    function _calculateNoteValue(
        NoteData memory note
    ) internal view returns (uint256) {
        uint256 baseValue = _denominations[note.denominationId].ylwValue;
        uint16 bonusMultiplier = _rarityConfigs[note.rarity].bonusMultiplierBps;
        return (baseValue * bonusMultiplier) / 10000;
    }

    function _sendYlwWithFallback(
        address recipient,
        uint256 amount
    ) internal {
        address ylw = _collectionConfig.ylwToken;
        address treasuryAddr = _collectionConfig.treasury;

        uint256 treasuryBalance = IERC20(ylw).balanceOf(treasuryAddr);

        if (treasuryBalance >= amount) {
            IERC20(ylw).safeTransferFrom(treasuryAddr, recipient, amount);
        } else {
            if (treasuryBalance > 0) {
                IERC20(ylw).safeTransferFrom(treasuryAddr, recipient, treasuryBalance);
            }
            uint256 shortfall = amount - treasuryBalance;
            IYellowToken(ylw).mint(recipient, shortfall, "note_redeem");
        }
    }

    function _selectRarity(uint256 seed) internal view returns (Rarity) {
        uint256 roll = seed % 10000;
        uint256 cumulative = 0;

        for (uint8 i = 0; i <= uint8(Rarity.Legendary); i++) {
            Rarity r = Rarity(i);
            cumulative += _rarityConfigs[r].weightBps;
            if (roll < cumulative) {
                return r;
            }
        }
        return Rarity.Common;
    }

    function _generateSeed(address to, uint256 tokenId) internal view returns (uint256) {
        return uint256(keccak256(abi.encodePacked(
            block.timestamp,
            block.prevrandao,
            to,
            tokenId
        )));
    }

    /**
     * @notice Rebuild sorted denomination IDs array (descending by value)
     * @dev Called only during configuration, not at runtime
     */
    function _rebuildSortedDenominations() internal {
        uint256 numDenoms = _denominationIds.length;

        // Clear and rebuild
        delete _sortedDenomIdsByValue;

        // Copy to memory for sorting
        uint8[] memory tempIds = new uint8[](numDenoms);
        uint256[] memory tempValues = new uint256[](numDenoms);

        for (uint256 i = 0; i < numDenoms; i++) {
            tempIds[i] = _denominationIds[i];
            tempValues[i] = _denominations[_denominationIds[i]].ylwValue;
        }

        // Bubble sort descending by value
        for (uint256 i = 0; i < numDenoms; i++) {
            for (uint256 j = i + 1; j < numDenoms; j++) {
                if (tempValues[j] > tempValues[i]) {
                    (tempValues[i], tempValues[j]) = (tempValues[j], tempValues[i]);
                    (tempIds[i], tempIds[j]) = (tempIds[j], tempIds[i]);
                }
            }
        }

        // Store sorted IDs
        for (uint256 i = 0; i < numDenoms; i++) {
            _sortedDenomIdsByValue.push(tempIds[i]);
        }
    }

    /**
     * @notice Decompose reward value into optimal banknote denominations
     * @dev Greedy algorithm using pre-sorted denominations (largest first)
     */
    function _decomposeToNotes(
        uint256 rewardValue
    ) internal view returns (uint8[] memory denomIds, uint32[] memory counts) {
        uint256 numDenoms = _sortedDenomIdsByValue.length;

        // Greedy decomposition using pre-sorted array
        uint256 remaining = rewardValue;
        uint32[] memory tempCounts = new uint32[](numDenoms);

        for (uint256 i = 0; i < numDenoms && remaining > 0; i++) {
            uint8 denomId = _sortedDenomIdsByValue[i];
            DenominationConfig memory denom = _denominations[denomId];

            if (denom.ylwValue == 0 || !denom.active) continue;

            uint32 count = uint32(remaining / denom.ylwValue);
            if (count > 0) {
                // Check supply limit
                uint32 limit = rewardSupplyLimits[denomId];
                if (limit > 0) {
                    uint32 minted = rewardMintCounts[denomId];
                    uint32 available = minted >= limit ? 0 : limit - minted;
                    if (count > available) {
                        count = available;
                    }
                }

                tempCounts[i] = count;
                remaining -= uint256(count) * denom.ylwValue;
            }
        }

        // If we couldn't fully decompose, revert
        if (remaining > 0) revert CannotDecomposeReward(rewardValue);

        // Count non-zero entries
        uint256 nonZeroCount = 0;
        for (uint256 i = 0; i < numDenoms; i++) {
            if (tempCounts[i] > 0) nonZeroCount++;
        }

        // Build result arrays
        denomIds = new uint8[](nonZeroCount);
        counts = new uint32[](nonZeroCount);
        uint256 idx = 0;
        for (uint256 i = 0; i < numDenoms; i++) {
            if (tempCounts[i] > 0) {
                denomIds[idx] = _sortedDenomIdsByValue[i];
                counts[idx] = tempCounts[i];
                idx++;
            }
        }

        return (denomIds, counts);
    }

    function _formatSerialNumber(NoteData memory note) internal view returns (string memory) {
        return string(abi.encodePacked(
            "HCRN-",
            _bytes2ToString(note.seriesId),
            "-",
            _denominations[note.denominationId].imageSubpath,
            "-",
            _padSerialNumber(note.serialNumber)
        ));
    }

    /**
     * @notice Convert bytes2 to string (e.g., 0x4141 -> "AA")
     */
    function _bytes2ToString(bytes2 b) internal pure returns (string memory) {
        bytes memory result = new bytes(2);
        result[0] = b[0];
        result[1] = b[1];
        return string(result);
    }

    function _padSerialNumber(uint32 serial) internal pure returns (string memory) {
        bytes memory buffer = new bytes(6);
        for (uint256 i = 6; i > 0; i--) {
            buffer[i - 1] = bytes1(uint8(48 + serial % 10));
            serial /= 10;
        }
        return string(buffer);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // REQUIRED OVERRIDES
    // ═══════════════════════════════════════════════════════════════════════════

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(ADMIN_ROLE) {}

    function _update(address to, uint256 tokenId, address auth)
        internal
        override(ERC721Upgradeable, ERC721EnumerableUpgradeable)
        returns (address)
    {
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
