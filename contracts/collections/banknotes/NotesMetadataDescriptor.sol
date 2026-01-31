// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

import {IColonyReserveNotes} from "./IColonyReserveNotes.sol";
import {INotesMetadataDescriptor, INotesDataProvider} from "./INotesMetadataDescriptor.sol";

/**
 * @title NotesMetadataDescriptor
 * @notice Generates on-chain JSON metadata for Colony Reserve Notes NFTs
 * @dev Standalone contract using callback pattern to reduce main contract size
 * @author rutilicus.eth (ArchXS)
 */
contract NotesMetadataDescriptor is INotesMetadataDescriptor, AccessControl {
    using Strings for uint256;
    using Strings for uint32;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    /// @notice Collection attribute name for traits
    string public collectionAttribute;

    event CollectionAttributeUpdated(string name);

    constructor(address admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ADMIN_ROLE, admin);

        collectionAttribute = "Colony Reserve Notes";
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TOKEN URI GENERATION (Callback Pattern)
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @inheritdoc INotesMetadataDescriptor
     * @dev Fetches data from notes contract via INotesDataProvider callback
     */
    function tokenURI(address notes, uint256 tokenId) external view override returns (string memory) {
        INotesDataProvider provider = INotesDataProvider(notes);

        // Fetch data via callbacks
        IColonyReserveNotes.NoteData memory note = provider.getNoteData(tokenId);
        IColonyReserveNotes.DenominationConfig memory denom = provider.getDenominationConfig(note.denominationId);
        IColonyReserveNotes.SeriesConfig memory series = provider.getSeriesConfig(note.seriesId);
        IColonyReserveNotes.RarityConfig memory rarity = provider.getRarityConfig(note.rarity);
        IColonyReserveNotes.CollectionConfig memory config = provider.getCollectionConfig();

        // Build metadata
        string memory serial = _formatSerial(note.seriesId, denom.imageSubpath, note.serialNumber);
        string memory imageUrl = _buildImageUrl(series.baseImageUri, denom.imageSubpath, note.seriesId, note.serialNumber);
        string memory animationUrl = _buildAnimationUrl(series.baseImageUri, denom.imageSubpath, note.seriesId, note.serialNumber);
        uint256 finalValue = (denom.ylwValue * rarity.bonusMultiplierBps) / 10000;

        string memory attributes = _buildAttributes(note, denom, series, rarity, serial, finalValue);

        string memory json = string(abi.encodePacked(
            '{"name":"', config.name, ' #', serial, '",',
            '"description":"', denom.name, ' - ', _formatYlw(finalValue), ' YLW Note",',
            '"image":"', imageUrl, '",',
            '"animation_url":"', animationUrl, '",',
            '"attributes":', attributes, '}'
        ));

        return string(abi.encodePacked(
            "data:application/json;base64,",
            Base64.encode(bytes(json))
        ));
    }

    /**
     * @inheritdoc INotesMetadataDescriptor
     * @dev Fetches collection config from notes contract via INotesDataProvider callback
     */
    function contractURI(address notes) external view override returns (string memory) {
        INotesDataProvider provider = INotesDataProvider(notes);
        IColonyReserveNotes.CollectionConfig memory config = provider.getCollectionConfig();

        string memory json = string(abi.encodePacked(
            '{"name":"', config.name, '",',
            '"description":"', config.description, '",',
            '"image":"', config.image, '",',
            '"external_link":"', config.externalLink, '",',
            '"seller_fee_basis_points":0,',
            '"fee_recipient":"0x0000000000000000000000000000000000000000"}'
        ));

        return string(abi.encodePacked(
            "data:application/json;base64,",
            Base64.encode(bytes(json))
        ));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ADMIN
    // ═══════════════════════════════════════════════════════════════════════════

    function setCollectionAttribute(string calldata name) external onlyRole(ADMIN_ROLE) {
        collectionAttribute = name;
        emit CollectionAttributeUpdated(name);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INTERNAL - FORMATTING
    // ═══════════════════════════════════════════════════════════════════════════

    function _formatSerial(
        bytes2 seriesId,
        string memory subpath,
        uint32 serial
    ) internal pure returns (string memory) {
        return string(abi.encodePacked(
            "CRN-",
            _bytes2ToString(seriesId),
            "-",
            subpath,
            "-",
            _padSerial(serial)
        ));
    }

    function _buildImageUrl(
        string memory baseUri,
        string memory subpath,
        bytes2 seriesId,
        uint32 serial
    ) internal pure returns (string memory) {
        // Format: {baseUri}{subpath}-{seriesId}-{serial}-front.png
        return string(abi.encodePacked(
            baseUri,
            subpath,
            "-",
            _bytes2ToString(seriesId),
            "-",
            _padSerial(serial),
            "-front.png"
        ));
    }

    function _buildAnimationUrl(
        string memory baseUri,
        string memory subpath,
        bytes2 seriesId,
        uint32 serial
    ) internal pure returns (string memory) {
        // Format: {baseUri}{subpath}-{seriesId}-{serial}-flip.gif
        return string(abi.encodePacked(
            baseUri,
            subpath,
            "-",
            _bytes2ToString(seriesId),
            "-",
            _padSerial(serial),
            "-flip.gif"
        ));
    }

    function _buildAttributes(
        IColonyReserveNotes.NoteData memory note,
        IColonyReserveNotes.DenominationConfig memory denom,
        IColonyReserveNotes.SeriesConfig memory series,
        IColonyReserveNotes.RarityConfig memory rarity,
        string memory serial,
        uint256 finalValue
    ) internal view returns (string memory) {
        return string(abi.encodePacked(
            '[{"trait_type":"Denomination","value":"', denom.name, '"},',
            '{"trait_type":"Value","value":"', _formatYlw(finalValue), ' YLW"},',
            '{"trait_type":"Series","value":"', series.name, '"},',
            '{"trait_type":"Rarity","value":"', rarity.name, '"},',
            '{"trait_type":"Serial Number","value":"', serial, '"},',
            '{"trait_type":"Collection","value":"', collectionAttribute, '"},',
            '{"display_type":"date","trait_type":"Minted","value":', uint256(note.mintedAt).toString(), '}]'
        ));
    }

    function _bytes2ToString(bytes2 b) internal pure returns (string memory) {
        bytes memory result = new bytes(2);
        result[0] = b[0];
        result[1] = b[1];
        return string(result);
    }

    function _padSerial(uint32 serial) internal pure returns (string memory) {
        bytes memory buffer = new bytes(6);
        for (uint256 i = 6; i > 0; i--) {
            buffer[i - 1] = bytes1(uint8(48 + serial % 10));
            serial /= 10;
        }
        return string(buffer);
    }

    function _formatYlw(uint256 amountWei) internal pure returns (string memory) {
        return (amountWei / 1e18).toString();
    }
}
