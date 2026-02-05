// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BoosterSVGLib} from "../../../diamonds/modular/libraries/BoosterSVGLib.sol";

/// @title IBoosterDescriptor
/// @notice Interface for Booster Card metadata and SVG generation
/// @dev External contract pattern - descriptor can be upgraded independently
/// @author rutilicus.eth (ArchXS)
interface IBoosterDescriptor {

    /// @notice Metadata structure for booster tokens
    struct BoosterMetadata {
        uint256 tokenId;
        BoosterSVGLib.TargetSystem targetSystem;
        uint8 subType;
        BoosterSVGLib.Rarity rarity;
        uint16 primaryBonusBps;
        uint16 secondaryBonusBps;
        uint8 level;
        bool isBlueprint;
        bool isAttached;
        bytes32 attachmentKey;  // Generic attachment identifier
    }

    /// @notice Generate complete token URI with metadata and SVG
    /// @param metadata Booster metadata
    /// @return uri Complete data URI with JSON and embedded SVG
    function tokenURI(BoosterMetadata memory metadata) external view returns (string memory uri);

    /// @notice Generate SVG image for booster token
    /// @param metadata Booster metadata
    /// @return svg Complete SVG as string
    function generateSVG(BoosterMetadata memory metadata) external view returns (string memory svg);

    /// @notice Generate collection metadata URI (OpenSea contractURI)
    /// @return uri Collection metadata data URI
    function contractURI() external view returns (string memory uri);
}
