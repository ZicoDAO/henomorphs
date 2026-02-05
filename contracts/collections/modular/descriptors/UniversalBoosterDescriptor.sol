// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IBoosterSystemDescriptor} from "../interfaces/IBoosterSystemDescriptor.sol";

/**
 * @title UniversalBoosterDescriptor
 * @notice Generates icons and info for Universal system booster cards
 * @dev 4 subtypes: Booster, Master, Legacy, Genesis
 * @author rutilicus.eth (ArchXS)
 */
contract UniversalBoosterDescriptor is IBoosterSystemDescriptor {

    /// @inheritdoc IBoosterSystemDescriptor
    function generateIcon(
        uint8 subType,
        uint8 rarity,
        string memory rPrimary,
        string memory rSecondary
    ) external pure override returns (string memory) {
        string memory animClass = ' class="pulse"'; // Universal always animated
        string memory rotateClass = ' class="rotate"';

        if (subType == 0) return _generateBoosterIcon(animClass, rotateClass, rPrimary, rSecondary);
        if (subType == 1) return _generateMasterIcon(animClass, rPrimary, rSecondary);
        if (subType == 2) return _generateLegacyIcon(animClass, rPrimary, rSecondary);
        return _generateGenesisIcon(animClass, rotateClass, rPrimary, rSecondary);
    }

    /// @inheritdoc IBoosterSystemDescriptor
    function getSystemInfo(uint8 subType) external pure override returns (
        string memory colors,
        string memory subTypeName,
        string memory systemName,
        string memory systemIcon,
        string memory primaryLabel,
        string memory secondaryLabel
    ) {
        return (
            _getColors(subType),
            _getSubTypeName(subType),
            "UNIVERSAL",
            unicode"✧",
            "ALL",
            "MULT"
        );
    }

    // ============ COLORS ============

    function _getColors(uint8 subType) private pure returns (string memory) {
        if (subType == 0) return "#FFD700,#FFA500,#FF6347"; // Booster - Gold to red
        if (subType == 1) return "#00BCD4,#4CAF50,#CDDC39"; // Master - Teal to green
        if (subType == 2) return "#E91E63,#9C27B0,#673AB7"; // Legacy - Pink to purple
        return "#FFD700,#00BCD4,#E91E63"; // Genesis - Rainbow
    }

    function _getSubTypeName(uint8 subType) private pure returns (string memory) {
        if (subType == 0) return "BOOSTER";
        if (subType == 1) return "MASTER";
        if (subType == 2) return "LEGACY";
        return "GENESIS";
    }

    // ============ ICON GENERATION ============

    function _generateBoosterIcon(
        string memory animClass,
        string memory rotateClass,
        string memory rPrimary,
        string memory rSecondary
    ) private pure returns (string memory) {
        // Star burst
        return string.concat(
            '<g transform="translate(150, 170)">',
            '<circle cx="0" cy="0" r="55" fill="none" stroke="', rPrimary, '" stroke-width="1" opacity="0.3"', rotateClass, '/>',
            '<circle cx="0" cy="0" r="50" fill="none" stroke="', rSecondary, '" stroke-width="1" opacity="0.4"', rotateClass, '/>',
            '<circle cx="0" cy="0" r="45" fill="none" stroke="', rPrimary, '" stroke-width="1" opacity="0.5"/>',
            '<polygon points="0,-40 8,-15 35,-15 15,5 22,35 0,18 -22,35 -15,5 -35,-15 -8,-15" ',
            'fill="', rPrimary, '" stroke="', rSecondary, '" stroke-width="2"', animClass, '/>',
            '<polygon points="0,-20 5,-8 18,-8 8,2 12,18 0,10 -12,18 -8,2 -18,-8 -5,-8" ',
            'fill="', rSecondary, '"', animClass, '/>',
            '<circle cx="0" cy="0" r="8" fill="#FFF" opacity="0.9"/>',
            '<circle cx="0" cy="0" r="4" fill="', rPrimary, '"/>',
            '</g>'
        );
    }

    function _generateMasterIcon(
        string memory animClass,
        string memory rPrimary,
        string memory rSecondary
    ) private pure returns (string memory) {
        // Infinity symbol with orbs
        return string.concat(
            '<g transform="translate(150, 170)">',
            '<path d="M-40,0 C-40,-30 -10,-30 0,0 C10,30 40,30 40,0 C40,-30 10,-30 0,0 C-10,30 -40,30 -40,0 Z" ',
            'fill="none" stroke="', rPrimary, '" stroke-width="4"/>',
            '<path d="M-35,0 C-35,-25 -10,-25 0,0 C10,25 35,25 35,0 C35,-25 10,-25 0,0 C-10,25 -35,25 -35,0 Z" ',
            'fill="none" stroke="', rSecondary, '" stroke-width="2" opacity="0.6"', animClass, '/>',
            '<circle cx="-40" cy="0" r="10" fill="', rPrimary, '"', animClass, '/>',
            '<circle cx="40" cy="0" r="10" fill="', rPrimary, '"', animClass, '/>',
            '<circle cx="0" cy="0" r="12" fill="', rSecondary, '"/>',
            '<text x="0" y="5" text-anchor="middle" fill="', rPrimary, '" font-size="14" font-weight="bold">M</text>',
            '</g>'
        );
    }

    function _generateLegacyIcon(
        string memory animClass,
        string memory rPrimary,
        string memory rSecondary
    ) private pure returns (string memory) {
        // Crown
        return string.concat(
            '<g transform="translate(150, 170)">',
            '<path d="M-50,20 L-40,-30 L-20,0 L0,-40 L20,0 L40,-30 L50,20 Z" ',
            'fill="', rPrimary, '" stroke="', rSecondary, '" stroke-width="2"/>',
            '<rect x="-45" y="20" width="90" height="20" fill="', rSecondary, '" stroke="', rPrimary, '" stroke-width="2"/>',
            '<circle cx="-40" cy="-30" r="8" fill="', rSecondary, '"', animClass, '/>',
            '<circle cx="0" cy="-40" r="10" fill="', rSecondary, '"', animClass, '/>',
            '<circle cx="40" cy="-30" r="8" fill="', rSecondary, '"', animClass, '/>',
            '<circle cx="-20" cy="0" r="6" fill="#E91E63"/>',
            '<circle cx="20" cy="0" r="6" fill="#00BCD4"/>',
            '<rect x="-5" y="25" width="10" height="10" fill="', rPrimary, '"/>',
            '</g>'
        );
    }

    function _generateGenesisIcon(
        string memory animClass,
        string memory rotateClass,
        string memory rPrimary,
        string memory rSecondary
    ) private pure returns (string memory) {
        // Cosmic orb
        string memory part1 = string.concat(
            '<g transform="translate(150, 170)">',
            '<circle cx="0" cy="0" r="50" fill="url(#genesis-grad)" stroke="', rPrimary, '" stroke-width="2"/>',
            '<defs><radialGradient id="genesis-grad">',
            '<stop offset="0%" stop-color="', rPrimary, '"/>',
            '<stop offset="50%" stop-color="', rSecondary, '"/>',
            '<stop offset="100%" stop-color="#000"/>',
            '</radialGradient></defs>'
        );

        string memory part2 = string.concat(
            '<ellipse cx="0" cy="0" rx="55" ry="20" fill="none" stroke="', rSecondary, '" stroke-width="2" opacity="0.5"', rotateClass, '/>',
            '<ellipse cx="0" cy="0" rx="20" ry="55" fill="none" stroke="', rPrimary, '" stroke-width="2" opacity="0.5"', rotateClass, '/>',
            '<circle cx="0" cy="0" r="15" fill="#FFF" opacity="0.3"', animClass, '/>',
            '<circle cx="-5" cy="-5" r="5" fill="#FFF" opacity="0.8"/>',
            '<circle cx="-30" cy="-25" r="3" fill="', rPrimary, '"', animClass, '/>',
            '<circle cx="25" cy="-30" r="2" fill="', rSecondary, '"', animClass, '/>',
            '<circle cx="35" cy="20" r="3" fill="', rPrimary, '"', animClass, '/>',
            '<circle cx="-20" cy="30" r="2" fill="', rSecondary, '"', animClass, '/>',
            '</g>'
        );

        return string.concat(part1, part2);
    }
}
