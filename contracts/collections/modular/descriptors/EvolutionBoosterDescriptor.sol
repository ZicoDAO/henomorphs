// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IBoosterSystemDescriptor} from "../interfaces/IBoosterSystemDescriptor.sol";

/**
 * @title EvolutionBoosterDescriptor
 * @notice Generates icons and info for Evolution system booster cards
 * @dev 4 subtypes: Catalyst, Accelerator, Amplifier, Mutator
 * @author rutilicus.eth (ArchXS)
 */
contract EvolutionBoosterDescriptor is IBoosterSystemDescriptor {

    /// @inheritdoc IBoosterSystemDescriptor
    function generateIcon(
        uint8 subType,
        uint8 rarity,
        string memory rPrimary,
        string memory rSecondary
    ) external pure override returns (string memory) {
        string memory animClass = rarity >= 3 ? ' class="pulse"' : '';
        string memory floatClass = rarity >= 3 ? ' class="float"' : '';

        if (subType == 0) return _generateCatalystIcon(animClass, floatClass, rPrimary, rSecondary);
        if (subType == 1) return _generateAcceleratorIcon(animClass, floatClass, rPrimary, rSecondary);
        if (subType == 2) return _generateAmplifierIcon(animClass, floatClass, rPrimary, rSecondary);
        return _generateMutatorIcon(animClass, floatClass, rPrimary, rSecondary);
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
            "EVOLUTION",
            unicode"🧬",
            "COST",
            "TIER"
        );
    }

    // ============ COLORS ============

    function _getColors(uint8 subType) private pure returns (string memory) {
        if (subType == 0) return "#9C27B0,#BA68C8,#E1BEE7"; // Catalyst - Purple
        if (subType == 1) return "#673AB7,#9575CD,#D1C4E9"; // Accelerator - Deep Purple
        if (subType == 2) return "#7B1FA2,#AB47BC,#CE93D8"; // Amplifier - Purple accent
        return "#4A148C,#7B1FA2,#9C27B0"; // Mutator - Dark purple
    }

    function _getSubTypeName(uint8 subType) private pure returns (string memory) {
        if (subType == 0) return "CATALYST";
        if (subType == 1) return "ACCELERATOR";
        if (subType == 2) return "AMPLIFIER";
        return "MUTATOR";
    }

    // ============ ICON GENERATION ============

    function _generateCatalystIcon(
        string memory animClass,
        string memory floatClass,
        string memory rPrimary,
        string memory rSecondary
    ) private pure returns (string memory) {
        // DNA helix with catalyst particles
        return string.concat(
            '<g transform="translate(150, 170)">',
            '<path d="M-30,-50 Q0,-35 30,-50 Q0,-65 -30,-50" fill="none" stroke="', rPrimary, '" stroke-width="3"', animClass, '/>',
            '<path d="M-30,-35 Q0,-20 30,-35 Q0,-50 -30,-35" fill="none" stroke="', rSecondary, '" stroke-width="3"', animClass, '/>',
            '<path d="M-30,-20 Q0,-5 30,-20 Q0,-35 -30,-20" fill="none" stroke="', rPrimary, '" stroke-width="3"', animClass, '/>',
            '<path d="M-30,-5 Q0,10 30,-5 Q0,-20 -30,-5" fill="none" stroke="', rSecondary, '" stroke-width="3"', animClass, '/>',
            '<path d="M-30,10 Q0,25 30,10 Q0,-5 -30,10" fill="none" stroke="', rPrimary, '" stroke-width="3"', animClass, '/>',
            '<path d="M-30,25 Q0,40 30,25 Q0,10 -30,25" fill="none" stroke="', rSecondary, '" stroke-width="3"', animClass, '/>',
            '<circle cx="-20" cy="-42" r="6" fill="', rPrimary, '"', floatClass, '/>',
            '<circle cx="20" cy="-28" r="5" fill="', rSecondary, '"', floatClass, '/>',
            '<circle cx="-15" cy="-12" r="6" fill="', rPrimary, '"', floatClass, '/>',
            '<circle cx="15" cy="2" r="5" fill="', rSecondary, '"', floatClass, '/>',
            '<circle cx="-10" cy="18" r="6" fill="', rPrimary, '"', floatClass, '/>',
            '</g>'
        );
    }

    function _generateAcceleratorIcon(
        string memory animClass,
        string memory floatClass,
        string memory rPrimary,
        string memory rSecondary
    ) private pure returns (string memory) {
        // Fast forward arrows with speed lines
        return string.concat(
            '<g transform="translate(150, 170)">',
            '<polygon points="-40,0 0,-40 0,-20 40,-20 40,20 0,20 0,40" fill="', rPrimary, '" opacity="0.8"', animClass, '/>',
            '<polygon points="-20,0 10,-30 10,-15 50,-15 50,15 10,15 10,30" fill="', rSecondary, '" opacity="0.6"', animClass, '/>',
            '<line x1="-60" y1="-30" x2="-30" y2="-30" stroke="', rPrimary, '" stroke-width="3" opacity="0.5"/>',
            '<line x1="-55" y1="0" x2="-25" y2="0" stroke="', rSecondary, '" stroke-width="3" opacity="0.5"/>',
            '<line x1="-60" y1="30" x2="-30" y2="30" stroke="', rPrimary, '" stroke-width="3" opacity="0.5"/>',
            '<circle cx="55" cy="0" r="10" fill="', rPrimary, '"', floatClass, '/>',
            '</g>'
        );
    }

    function _generateAmplifierIcon(
        string memory animClass,
        string memory floatClass,
        string memory rPrimary,
        string memory rSecondary
    ) private pure returns (string memory) {
        // Expanding circles (power amplification)
        return string.concat(
            '<g transform="translate(150, 170)">',
            '<circle cx="0" cy="0" r="50" fill="none" stroke="', rPrimary, '" stroke-width="2" opacity="0.3"', animClass, '/>',
            '<circle cx="0" cy="0" r="40" fill="none" stroke="', rSecondary, '" stroke-width="2" opacity="0.5"', animClass, '/>',
            '<circle cx="0" cy="0" r="30" fill="none" stroke="', rPrimary, '" stroke-width="3" opacity="0.7"', animClass, '/>',
            '<circle cx="0" cy="0" r="20" fill="', rSecondary, '" opacity="0.8"', animClass, '/>',
            '<circle cx="0" cy="0" r="10" fill="', rPrimary, '"/>',
            '<path d="M-55,0 L-60,-10 L-65,0 L-60,10 Z" fill="', rPrimary, '"', floatClass, '/>',
            '<path d="M55,0 L60,-10 L65,0 L60,10 Z" fill="', rPrimary, '"', floatClass, '/>',
            '<path d="M0,-55 L-10,-60 L0,-65 L10,-60 Z" fill="', rSecondary, '"', floatClass, '/>',
            '<path d="M0,55 L-10,60 L0,65 L10,60 Z" fill="', rSecondary, '"', floatClass, '/>',
            '</g>'
        );
    }

    function _generateMutatorIcon(
        string memory animClass,
        string memory floatClass,
        string memory rPrimary,
        string memory rSecondary
    ) private pure returns (string memory) {
        // DNA mutation symbol with lightning
        return string.concat(
            '<g transform="translate(150, 170)">',
            '<path d="M-20,-50 L-20,50" stroke="', rSecondary, '" stroke-width="4"/>',
            '<path d="M20,-50 L20,50" stroke="', rSecondary, '" stroke-width="4"/>',
            '<path d="M-20,-40 Q0,-30 20,-40" stroke="', rPrimary, '" stroke-width="3" fill="none"/>',
            '<path d="M-20,-20 Q0,-10 20,-20" stroke="', rPrimary, '" stroke-width="3" fill="none"/>',
            '<path d="M-20,0 Q0,10 20,0" stroke="', rPrimary, '" stroke-width="3" fill="none"/>',
            '<path d="M-20,20 Q0,30 20,20" stroke="', rPrimary, '" stroke-width="3" fill="none"/>',
            '<path d="M-20,40 Q0,50 20,40" stroke="', rPrimary, '" stroke-width="3" fill="none"/>',
            '<path d="M0,-60 L-8,-45 L8,-45 L0,-30 L12,-50 L4,-50 Z" fill="', rPrimary, '"', animClass, '/>',
            '<circle cx="-35" cy="0" r="8" fill="', rSecondary, '"', floatClass, '/>',
            '<circle cx="35" cy="0" r="8" fill="', rSecondary, '"', floatClass, '/>',
            '</g>'
        );
    }
}
