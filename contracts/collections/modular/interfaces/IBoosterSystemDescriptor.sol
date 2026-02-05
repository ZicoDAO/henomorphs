// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IBoosterSystemDescriptor
/// @notice Interface for per-system booster icon and info generation
/// @dev Uses uint8 for rarity/system to avoid circular dependency with BoosterSVGLib enums
/// @author rutilicus.eth (ArchXS)
interface IBoosterSystemDescriptor {
    /// @notice Generate the system-specific icon SVG
    /// @param subType SubType within the system (0-7 for buildings, 0-3 for others)
    /// @param rarity Rarity as uint8 (0=Common, 1=Uncommon, 2=Rare, 3=Epic, 4=Legendary)
    /// @param rPrimary Primary rarity color hex string
    /// @param rSecondary Secondary rarity color hex string
    /// @return icon SVG string for the icon element
    function generateIcon(
        uint8 subType,
        uint8 rarity,
        string memory rPrimary,
        string memory rSecondary
    ) external pure returns (string memory icon);

    /// @notice Get all system information for a given subType
    /// @param subType SubType within the system
    /// @return colors Comma-separated color string (e.g., "#8B4513,#A0522D,#CD853F")
    /// @return subTypeName Display name for the subtype (e.g., "WAREHOUSE")
    /// @return systemName Display name for the system (e.g., "BUILDING")
    /// @return systemIcon Unicode icon for the system (e.g., unicode crane)
    /// @return primaryLabel Primary bonus label (e.g., "EFF")
    /// @return secondaryLabel Secondary bonus label (e.g., "CAP")
    function getSystemInfo(uint8 subType) external pure returns (
        string memory colors,
        string memory subTypeName,
        string memory systemName,
        string memory systemIcon,
        string memory primaryLabel,
        string memory secondaryLabel
    );
}
