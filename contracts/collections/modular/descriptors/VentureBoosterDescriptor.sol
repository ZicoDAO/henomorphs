// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IBoosterSystemDescriptor} from "../interfaces/IBoosterSystemDescriptor.sol";

/**
 * @title VentureBoosterDescriptor
 * @notice Generates icons and info for Venture system booster cards
 * @dev 4 subtypes: Scout, Harvester, Trader, Guardian
 * @author rutilicus.eth (ArchXS)
 */
contract VentureBoosterDescriptor is IBoosterSystemDescriptor {

    /// @inheritdoc IBoosterSystemDescriptor
    function generateIcon(
        uint8 subType,
        uint8 rarity,
        string memory rPrimary,
        string memory rSecondary
    ) external pure override returns (string memory) {
        string memory animClass = rarity >= 3 ? ' class="pulse"' : '';

        if (subType == 0) return _generateScoutIcon(animClass, rPrimary, rSecondary);
        if (subType == 1) return _generateHarvesterIcon(animClass, rPrimary, rSecondary);
        if (subType == 2) return _generateTraderIcon(animClass, rPrimary, rSecondary);
        return _generateGuardianIcon(animClass, rPrimary, rSecondary);
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
            "VENTURE",
            unicode"⚔",
            "SUCC",
            "RWD"
        );
    }

    // ============ COLORS ============

    function _getColors(uint8 subType) private pure returns (string memory) {
        if (subType == 0) return "#FF6F00,#FF8F00,#FFAB00"; // Scout - Amber
        if (subType == 1) return "#E65100,#EF6C00,#F57C00"; // Harvester - Deep Orange
        if (subType == 2) return "#FF5722,#FF7043,#FF8A65"; // Trader - Orange
        return "#BF360C,#D84315,#E64A19"; // Guardian - Deep red-orange
    }

    function _getSubTypeName(uint8 subType) private pure returns (string memory) {
        if (subType == 0) return "SCOUT";
        if (subType == 1) return "HARVESTER";
        if (subType == 2) return "TRADER";
        return "GUARDIAN";
    }

    // ============ ICON GENERATION ============

    function _generateScoutIcon(
        string memory animClass,
        string memory rPrimary,
        string memory rSecondary
    ) private pure returns (string memory) {
        // Compass
        return string.concat(
            '<g transform="translate(150, 170)">',
            '<circle cx="0" cy="0" r="50" fill="none" stroke="', rPrimary, '" stroke-width="3"/>',
            '<circle cx="0" cy="0" r="45" fill="none" stroke="', rSecondary, '" stroke-width="1"/>',
            '<text x="0" y="-35" text-anchor="middle" fill="', rPrimary, '" font-size="12" font-weight="bold">N</text>',
            '<text x="35" y="5" text-anchor="middle" fill="', rSecondary, '" font-size="10">E</text>',
            '<text x="0" y="42" text-anchor="middle" fill="', rSecondary, '" font-size="10">S</text>',
            '<text x="-35" y="5" text-anchor="middle" fill="', rSecondary, '" font-size="10">W</text>',
            '<polygon points="0,-30 5,5 0,15 -5,5" fill="', rPrimary, '"', animClass, '/>',
            '<polygon points="0,30 5,-5 0,-15 -5,-5" fill="', rSecondary, '" opacity="0.7"/>',
            '<circle cx="0" cy="0" r="6" fill="', rPrimary, '"/>',
            '<circle cx="0" cy="0" r="3" fill="#FFF"/>',
            '</g>'
        );
    }

    function _generateHarvesterIcon(
        string memory animClass,
        string memory rPrimary,
        string memory rSecondary
    ) private pure returns (string memory) {
        // Treasure chest with gems
        return string.concat(
            '<g transform="translate(150, 170)">',
            '<rect x="-45" y="-20" width="90" height="60" fill="#8D6E63" stroke="', rPrimary, '" stroke-width="2" rx="4"/>',
            '<rect x="-40" y="-15" width="80" height="50" fill="#A1887F"/>',
            '<path d="M-45,-20 Q0,-50 45,-20" fill="#6D4C41" stroke="', rPrimary, '" stroke-width="2"/>',
            '<rect x="-10" y="-25" width="20" height="15" fill="', rPrimary, '" rx="2"/>',
            '<circle cx="0" cy="-18" r="5" fill="', rSecondary, '"/>',
            '<polygon points="-20,5 -10,-15 0,5" fill="#E91E63"', animClass, '/>',
            '<polygon points="0,10 10,-10 20,10" fill="#00BCD4"', animClass, '/>',
            '<polygon points="15,5 25,-5 30,5" fill="#FFEB3B"', animClass, '/>',
            '<circle cx="-25" cy="15" r="8" fill="', rPrimary, '"', animClass, '/>',
            '</g>'
        );
    }

    function _generateTraderIcon(
        string memory animClass,
        string memory rPrimary,
        string memory rSecondary
    ) private pure returns (string memory) {
        // Scales/balance
        return string.concat(
            '<g transform="translate(150, 170)">',
            '<line x1="0" y1="-50" x2="0" y2="30" stroke="', rPrimary, '" stroke-width="4"/>',
            '<line x1="-50" y1="-30" x2="50" y2="-30" stroke="', rPrimary, '" stroke-width="3"/>',
            '<line x1="-50" y1="-30" x2="-50" y2="0" stroke="', rSecondary, '" stroke-width="2"/>',
            '<line x1="50" y1="-30" x2="50" y2="0" stroke="', rSecondary, '" stroke-width="2"/>',
            '<path d="M-65,0 Q-50,15 -35,0 Z" fill="', rSecondary, '" stroke="', rPrimary, '" stroke-width="1"', animClass, '/>',
            '<path d="M35,0 Q50,15 65,0 Z" fill="', rSecondary, '" stroke="', rPrimary, '" stroke-width="1"', animClass, '/>',
            '<circle cx="-50" cy="8" r="6" fill="', rPrimary, '"/>',
            '<circle cx="50" cy="8" r="6" fill="', rPrimary, '"/>',
            '<polygon points="0,-55 -8,-45 8,-45" fill="', rPrimary, '"/>',
            '<rect x="-15" y="30" width="30" height="10" fill="', rSecondary, '" rx="2"/>',
            '</g>'
        );
    }

    function _generateGuardianIcon(
        string memory animClass,
        string memory rPrimary,
        string memory rSecondary
    ) private pure returns (string memory) {
        // Shield
        return string.concat(
            '<g transform="translate(150, 170)">',
            '<path d="M0,-55 L45,-35 L45,15 Q45,50 0,60 Q-45,50 -45,15 L-45,-35 Z" fill="', rSecondary, '" stroke="', rPrimary, '" stroke-width="3"/>',
            '<path d="M0,-45 L35,-28 L35,12 Q35,40 0,48 Q-35,40 -35,12 L-35,-28 Z" fill="', rPrimary, '" opacity="0.3"/>',
            '<path d="M0,-30 L-20,0 L0,30 L20,0 Z" fill="', rPrimary, '"', animClass, '/>',
            '<circle cx="0" cy="0" r="10" fill="', rSecondary, '"/>',
            '<text x="0" y="5" text-anchor="middle" fill="', rPrimary, '" font-size="14" font-weight="bold">G</text>',
            '</g>'
        );
    }
}
