// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/**
 * @title IColonyReserveNotes
 * @notice Interface for Colony Reserve Notes - YLW-backed banknote NFT collection
 * @dev ERC-721 collection with configurable series, denominations, and rarity variants
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 */
interface IColonyReserveNotes {
    // ============================================
    // ENUMS
    // ============================================

    /**
     * @notice Rarity levels for notes
     * @dev Each rarity has different probability and may have bonus multiplier
     */
    enum Rarity {
        Common,
        Uncommon,
        Rare,
        Epic,
        Legendary
    }

    // ============================================
    // STRUCTS
    // ============================================

    /**
     * @notice Collection-level configuration
     */
    struct CollectionConfig {
        string name;              // Collection name (e.g., "Colony Reserve Notes")
        string symbol;            // Token symbol (e.g., "CRN")
        string description;       // Collection description
        string externalLink;      // Website URL
        string image;             // Collection logo image (IPFS/URL)
        address ylwToken;         // YLW token address
        address treasury;         // Treasury address for YLW backing
    }

    /**
     * @notice Reward system configuration (IRewardRedeemable)
     */
    struct RewardConfig {
        bytes2 rewardSeries;      // Default series for reward minting (e.g., "AA" = 0x4141)
        bool enabled;             // Whether reward system is enabled
    }

    /**
     * @notice Series configuration - each series has its own base image URI
     * @dev seriesId is bytes2 encoding two ASCII chars: "AA"=0x4141, "AB"=0x4142, "BA"=0x4241
     */
    struct SeriesConfig {
        bytes2 seriesId;          // Series identifier ("AA"=0x4141, "AB"=0x4142, "BA"=0x4241, etc.)
        string name;              // Series name (e.g., "Genesis Series")
        string baseImageUri;      // IPFS base URL for this series
        uint32 maxSupply;         // Max supply for entire series (0 = unlimited)
        uint32 mintedCount;       // Current minted count
        uint32 startTime;         // Series start timestamp (0 = immediate)
        uint32 endTime;           // Series end timestamp (0 = no end)
        bool active;              // Is series active
    }

    /**
     * @notice Denomination configuration - defines YLW value and image subpath
     */
    struct DenominationConfig {
        uint8 denominationId;     // Denomination ID (0, 1, 2, ...)
        string name;              // Denomination name (e.g., "Bronze Note", "Gold Note")
        uint256 ylwValue;         // Value in YLW (in wei, e.g., 1000e18)
        string imageSubpath;      // Image subpath (e.g., "1000-ylw")
        uint32 serialOffset;      // Offset for serial numbers (e.g., Bronze=0, Silver=350, Gold=525)
        bool active;              // Is denomination active
    }

    /**
     * @notice Rarity configuration - defines probability and visual variant
     */
    struct RarityConfig {
        Rarity rarity;            // Rarity level
        string name;              // Display name (e.g., "Common", "Holographic")
        string imageSuffix;       // Image suffix (e.g., "-common", "-legendary")
        uint16 weightBps;         // Weight in basis points (sum of all = 10000)
        uint16 bonusMultiplierBps; // Bonus multiplier (10000 = 100%, 11000 = 110%)
    }

    /**
     * @notice Individual note data stored per token
     */
    struct NoteData {
        uint8 denominationId;     // Reference to DenominationConfig
        bytes2 seriesId;          // Reference to SeriesConfig ("AA"=0x4141, etc.)
        Rarity rarity;            // Rolled rarity
        uint32 serialNumber;      // Sequential per series+denomination
        uint32 mintedAt;          // Mint timestamp
    }

    // ============================================
    // EVENTS
    // ============================================

    event NoteMinted(
        uint256 indexed tokenId,
        address indexed to,
        uint8 denominationId,
        bytes2 seriesId,
        Rarity rarity,
        uint32 serialNumber
    );

    event NoteRedeemed(
        uint256 indexed tokenId,
        address indexed redeemer,
        uint256 ylwAmount,
        Rarity rarity
    );

    event CollectionConfigured(string name, string symbol);
    event SeriesConfigured(bytes2 indexed seriesId, string name, string baseImageUri);
    event SeriesActiveChanged(bytes2 indexed seriesId, bool active);
    event DenominationConfigured(uint8 indexed denominationId, string name, uint256 ylwValue);
    event DenominationActiveChanged(uint8 indexed denominationId, bool active);
    event RarityConfigured(Rarity indexed rarity, string name, uint16 weightBps, uint16 bonusMultiplierBps);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event YlwTokenUpdated(address indexed oldToken, address indexed newToken);
    event RewardSystemConfigured(bytes2 rewardSeries, bool enabled);
    event RewardTierConfigured(uint256 indexed tierId, uint256 rewardValue);
    event RewardSupplyLimitSet(uint8 indexed denominationId, uint32 limit);

    // ============================================
    // ERRORS
    // ============================================

    error NotOwner();
    error TokenDoesNotExist(uint256 tokenId);
    error SeriesNotFound(bytes2 seriesId);
    error SeriesNotActive(bytes2 seriesId);
    error SeriesMaxSupplyReached(bytes2 seriesId);
    error SeriesNotStarted(bytes2 seriesId);
    error SeriesEnded(bytes2 seriesId);
    error DenominationNotFound(uint8 denominationId);
    error DenominationNotActive(uint8 denominationId);
    error RarityNotConfigured(Rarity rarity);
    error InvalidAddress();
    error InvalidRarityWeights();
    error AlreadyInitialized();
    error NotInitialized();
    error InsufficientTreasuryBalance(uint256 required, uint256 available);
    error RewardSystemDisabled();
    error InvalidTier();
    error TierNotConfigured(uint256 tierId);
    error InsufficientRewardSupply(uint8 denominationId, uint32 required, uint32 available);
    error CannotDecomposeReward(uint256 rewardValue);
    error ArrayLengthMismatch();
    error InvalidAmount();

    // ============================================
    // MINTING FUNCTIONS
    // ============================================

    /**
     * @notice Mint a note with random rarity
     * @param to Recipient address
     * @param denominationId Denomination to mint
     * @param seriesId Series to mint from ("AA"=0x4141, etc.)
     * @return tokenId Minted token ID
     */
    function mintNote(
        address to,
        uint8 denominationId,
        bytes2 seriesId
    ) external returns (uint256 tokenId);

    /**
     * @notice Mint a note with specific rarity (for special rewards)
     * @param to Recipient address
     * @param denominationId Denomination to mint
     * @param seriesId Series to mint from ("AA"=0x4141, etc.)
     * @param rarity Specific rarity to assign
     * @return tokenId Minted token ID
     */
    function mintNoteWithRarity(
        address to,
        uint8 denominationId,
        bytes2 seriesId,
        Rarity rarity
    ) external returns (uint256 tokenId);

    /**
     * @notice Batch mint notes of same denomination
     * @param to Recipient address
     * @param denominationId Denomination to mint
     * @param seriesId Series to mint from ("AA"=0x4141, etc.)
     * @param count Number of notes to mint
     * @return tokenIds Array of minted token IDs
     */
    function mintNoteBatch(
        address to,
        uint8 denominationId,
        bytes2 seriesId,
        uint32 count
    ) external returns (uint256[] memory tokenIds);

    // ============================================
    // REDEMPTION FUNCTIONS
    // ============================================

    /**
     * @notice Redeem a note for YLW tokens (burns the NFT)
     * @param tokenId Token to redeem
     */
    function redeemNote(uint256 tokenId) external;

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    /**
     * @notice Get the YLW value of a note (including rarity bonus)
     * @param tokenId Token to query
     * @return ylwAmount YLW value in wei
     */
    function getNoteValue(uint256 tokenId) external view returns (uint256 ylwAmount);

    /**
     * @notice Get complete note data
     * @param tokenId Token to query
     * @return data NoteData struct
     */
    function getNoteData(uint256 tokenId) external view returns (NoteData memory data);

    /**
     * @notice Get formatted serial number
     * @param tokenId Token to query
     * @return serial Formatted serial number string
     */
    function getSerialNumber(uint256 tokenId) external view returns (string memory serial);

    /**
     * @notice Get series configuration
     * @param seriesId Series to query ("AA"=0x4141, etc.)
     * @return config SeriesConfig struct
     */
    function getSeriesConfig(bytes2 seriesId) external view returns (SeriesConfig memory config);

    /**
     * @notice Get denomination configuration
     * @param denominationId Denomination to query
     * @return config DenominationConfig struct
     */
    function getDenominationConfig(uint8 denominationId) external view returns (DenominationConfig memory config);

    /**
     * @notice Get rarity configuration
     * @param rarity Rarity to query
     * @return config RarityConfig struct
     */
    function getRarityConfig(Rarity rarity) external view returns (RarityConfig memory config);

    /**
     * @notice Get all active series IDs
     * @return seriesIds Array of active series IDs ("AA"=0x4141, etc.)
     */
    function getActiveSeriesIds() external view returns (bytes2[] memory seriesIds);

    /**
     * @notice Get all active denomination IDs
     * @return denominationIds Array of active denomination IDs
     */
    function getActiveDenominationIds() external view returns (uint8[] memory denominationIds);

    // ============================================
    // METADATA FUNCTIONS
    // ============================================

    /**
     * @notice Get token metadata URI (ERC-721 standard)
     * @param tokenId Token to query
     * @return uri JSON metadata URI
     */
    function tokenURI(uint256 tokenId) external view returns (string memory uri);

    /**
     * @notice Get collection-level metadata URI (OpenSea standard)
     * @return uri JSON metadata URI
     */
    function contractURI() external view returns (string memory uri);
}

/**
 * @title IRewardRedeemable
 * @notice Interface for external reward systems to mint notes
 * @dev Compatible with CollaborativeCraftingFacet reward mechanism
 */
interface IRewardRedeemable {
    /**
     * @notice Mint reward note
     * @param collectionId Project type (1=Infrastructure, 2=Research, 3=Defense) - maps to series
     * @param tierId Contribution tier (1=Bronze, 2=Silver, 3=Gold, 4=Platinum) - maps to denomination
     * @param to Recipient address
     * @param amount Number of tokens to mint (typically 1)
     * @return tokenId The minted token ID
     */
    function mintReward(
        uint256 collectionId,
        uint256 tierId,
        address to,
        uint256 amount
    ) external returns (uint256 tokenId);

    /**
     * @notice Batch mint reward notes
     * @param collectionId Project type
     * @param tierIds Array of tier IDs
     * @param to Recipient address
     * @param amounts Array of amounts
     * @return tokenIds Array of minted token IDs
     */
    function batchMintReward(
        uint256 collectionId,
        uint256[] calldata tierIds,
        address to,
        uint256[] calldata amounts
    ) external returns (uint256[] memory tokenIds);

    /**
     * @notice Check if reward can be minted
     * @param collectionId Project type
     * @param tierId Tier ID
     * @param amount Amount to mint
     * @return canMint Whether the reward can be minted
     */
    function canMintReward(
        uint256 collectionId,
        uint256 tierId,
        uint256 amount
    ) external view returns (bool canMint);

    /**
     * @notice Get remaining supply for a tier
     * @param collectionId Project type
     * @param tierId Tier ID
     * @return remaining Remaining mintable supply (type(uint256).max if unlimited)
     */
    function getRemainingSupply(
        uint256 collectionId,
        uint256 tierId
    ) external view returns (uint256 remaining);
}
