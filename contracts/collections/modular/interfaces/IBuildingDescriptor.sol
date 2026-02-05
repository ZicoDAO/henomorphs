// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BuildingSVGLib} from "../../../diamonds/modular/libraries/BuildingSVGLib.sol";

/// @title IBuildingDescriptor
/// @notice Interface for Building Card metadata and SVG generation
/// @dev External contract pattern - descriptor can be upgraded independently
interface IBuildingDescriptor {

    /// @notice Metadata structure for building tokens
    struct BuildingMetadata {
        uint256 tokenId;
        BuildingSVGLib.BuildingType buildingType;
        BuildingSVGLib.Rarity rarity;
        uint8 efficiencyBonus;
        uint8 durabilityLevel;
        uint16 capacityBonus;
        bool isBlueprint;
        bool isAttached;
        bytes32 attachedToColony;
    }

    /// @notice Generate complete token URI with metadata and SVG
    /// @param metadata Building metadata
    /// @return uri Complete data URI with JSON and embedded SVG
    function tokenURI(BuildingMetadata memory metadata) external view returns (string memory uri);

    /// @notice Generate SVG image for building token
    /// @param metadata Building metadata
    /// @return svg Complete SVG as string
    function generateSVG(BuildingMetadata memory metadata) external view returns (string memory svg);

    /// @notice Generate collection metadata URI (OpenSea contractURI)
    /// @return uri Collection metadata data URI
    function contractURI() external view returns (string memory uri);
}
