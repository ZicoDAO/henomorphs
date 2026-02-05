// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IBoosterSystemDescriptor} from "../interfaces/IBoosterSystemDescriptor.sol";

/**
 * @title BuildingBoosterDescriptor
 * @notice Generates icons and info for Building system booster cards
 * @dev 8 subtypes: Warehouse, Refinery, Laboratory, DefenseTower, TradeHub, EnergyPlant, BioLab, MiningOutpost
 * @author rutilicus.eth (ArchXS)
 */
contract BuildingBoosterDescriptor is IBoosterSystemDescriptor {

    /// @inheritdoc IBoosterSystemDescriptor
    function generateIcon(
        uint8 subType,
        uint8 rarity,
        string memory rPrimary,
        string memory rSecondary
    ) external pure override returns (string memory) {
        if (subType == 0) return _generateWarehouseIcon(rarity, rPrimary, rSecondary);
        if (subType == 1) return _generateRefineryIcon(rarity, rPrimary, rSecondary);
        if (subType == 2) return _generateLaboratoryIcon(rarity, rPrimary, rSecondary);
        if (subType == 3) return _generateDefenseTowerIcon(rarity, rPrimary, rSecondary);
        if (subType == 4) return _generateTradeHubIcon(rarity, rPrimary, rSecondary);
        if (subType == 5) return _generateEnergyPlantIcon(rarity, rPrimary, rSecondary);
        if (subType == 6) return _generateBioLabIcon(rarity, rPrimary, rSecondary);
        return _generateMiningOutpostIcon(rarity, rPrimary, rSecondary);
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
            "BUILDING",
            unicode"🏗",
            "EFF",
            "CAP"
        );
    }

    // ============ COLORS ============

    function _getColors(uint8 subType) private pure returns (string memory) {
        if (subType == 0) return "#8B4513,#A0522D,#CD853F"; // Warehouse - Browns
        if (subType == 1) return "#FF6B35,#FF8C42,#FFB347"; // Refinery - Oranges
        if (subType == 2) return "#00CED1,#20B2AA,#48D1CC"; // Laboratory - Cyan
        if (subType == 3) return "#DC143C,#B22222,#FF4500"; // DefenseTower - Reds
        if (subType == 4) return "#FFD700,#FFA500,#DAA520"; // TradeHub - Golds
        if (subType == 5) return "#00BFFF,#1E90FF,#4169E1"; // EnergyPlant - Blues
        if (subType == 6) return "#32CD32,#228B22,#00FF7F"; // BioLab - Greens
        return "#A0522D,#8B4513,#D2691E"; // MiningOutpost - Browns
    }

    function _getSubTypeName(uint8 subType) private pure returns (string memory) {
        if (subType == 0) return "WAREHOUSE";
        if (subType == 1) return "REFINERY";
        if (subType == 2) return "LABORATORY";
        if (subType == 3) return "DEFENSE TOWER";
        if (subType == 4) return "TRADE HUB";
        if (subType == 5) return "ENERGY PLANT";
        if (subType == 6) return "BIO LAB";
        return "MINING OUTPOST";
    }

    // ============ ICON GENERATION ============

    function _generateWarehouseIcon(uint8 rarity, string memory rPrimary, string memory rSecondary)
        private pure returns (string memory)
    {
        string memory animClass = rarity >= 3 ? ' class="pulse"' : '';
        return string.concat(
            '<g transform="translate(150, 170)">',
            '<rect x="-60" y="-40" width="120" height="80" fill="#5D4037" stroke="', rPrimary, '" stroke-width="2" rx="4"/>',
            '<rect x="-55" y="-35" width="110" height="70" fill="#795548"/>',
            '<polygon points="-70,-40 0,-70 70,-40" fill="#3E2723" stroke="', rPrimary, '" stroke-width="2"/>',
            '<polygon points="-65,-40 0,-65 65,-40" fill="#4E342E"/>',
            '<rect x="-25" y="0" width="50" height="40" fill="#3E2723" stroke="', rSecondary, '" stroke-width="1"/>',
            '<line x1="0" y1="0" x2="0" y2="40" stroke="', rSecondary, '" stroke-width="1"/>',
            '<rect x="-50" y="-25" width="18" height="18" fill="#87CEEB" opacity="0.6"', animClass, '/>',
            '<rect x="32" y="-25" width="18" height="18" fill="#87CEEB" opacity="0.6"', animClass, '/>',
            '<rect x="-55" y="45" width="25" height="20" fill="', rSecondary, '" stroke="', rPrimary, '" stroke-width="1"/>',
            '<rect x="30" y="45" width="25" height="20" fill="', rSecondary, '" stroke="', rPrimary, '" stroke-width="1"/>',
            '</g>'
        );
    }

    function _generateRefineryIcon(uint8 rarity, string memory rPrimary, string memory rSecondary)
        private pure returns (string memory)
    {
        string memory animClass = rarity >= 3 ? ' class="pulse"' : '';
        return string.concat(
            '<g transform="translate(150, 170)">',
            '<rect x="-50" y="-30" width="100" height="90" fill="#424242" stroke="', rPrimary, '" stroke-width="2" rx="4"/>',
            '<rect x="-45" y="-25" width="90" height="80" fill="#616161"/>',
            '<rect x="-40" y="-70" width="15" height="45" fill="#757575" stroke="', rSecondary, '" stroke-width="1"/>',
            '<rect x="25" y="-70" width="15" height="45" fill="#757575" stroke="', rSecondary, '" stroke-width="1"/>',
            '<g transform="translate(-20, 10)">',
            '<circle cx="0" cy="0" r="20" fill="', rSecondary, '" stroke="', rPrimary, '" stroke-width="2"',
            rarity == 4 ? ' class="gear"' : '', '/>',
            '<circle cx="0" cy="0" r="8" fill="#424242"/>',
            '</g>',
            '<circle cx="-30" cy="-10" r="4" fill="#4CAF50"', animClass, '/>',
            '<circle cx="30" cy="-10" r="4" fill="', rPrimary, '"', animClass, '/>',
            '</g>'
        );
    }

    function _generateLaboratoryIcon(uint8 rarity, string memory rPrimary, string memory rSecondary)
        private pure returns (string memory)
    {
        string memory animClass = rarity >= 3 ? ' class="pulse"' : '';
        return string.concat(
            '<g transform="translate(150, 170)">',
            '<ellipse cx="0" cy="10" rx="55" ry="40" fill="#1A237E" stroke="', rPrimary, '" stroke-width="2"/>',
            '<ellipse cx="0" cy="10" rx="50" ry="35" fill="#283593"/>',
            '<path d="M-45,-15 Q0,-60 45,-15" fill="#4FC3F7" opacity="0.4" stroke="', rSecondary, '" stroke-width="1"/>',
            '<line x1="0" y1="-50" x2="0" y2="-70" stroke="', rPrimary, '" stroke-width="3"/>',
            '<circle cx="0" cy="-75" r="8" fill="', rSecondary, '"', animClass, '/>',
            '<rect x="-35" y="20" width="8" height="25" fill="#4CAF50" opacity="0.7" rx="2"', animClass, '/>',
            '<rect x="-20" y="25" width="8" height="20" fill="#2196F3" opacity="0.7" rx="2"', animClass, '/>',
            '<rect x="12" y="22" width="8" height="23" fill="#9C27B0" opacity="0.7" rx="2"', animClass, '/>',
            '<rect x="27" y="28" width="8" height="17" fill="#FF9800" opacity="0.7" rx="2"', animClass, '/>',
            '</g>'
        );
    }

    function _generateDefenseTowerIcon(uint8 rarity, string memory rPrimary, string memory rSecondary)
        private pure returns (string memory)
    {
        string memory animClass = rarity >= 3 ? ' class="pulse"' : '';
        return string.concat(
            '<g transform="translate(150, 170)">',
            '<polygon points="-40,60 -50,60 -35,-20 35,-20 50,60 40,60" fill="#37474F" stroke="', rPrimary, '" stroke-width="2"/>',
            '<rect x="-30" y="-60" width="60" height="45" fill="#546E7A" stroke="', rSecondary, '" stroke-width="2" rx="4"/>',
            '<rect x="-8" y="-45" width="16" height="50" fill="#263238" stroke="', rPrimary, '" stroke-width="1"/>',
            '<circle cx="0" cy="-45" r="12" fill="#37474F" stroke="', rPrimary, '" stroke-width="2"/>',
            '<path d="M0,-30 L15,-20 L15,0 L0,10 L-15,0 L-15,-20 Z" fill="', rSecondary, '" opacity="0.8"/>',
            '<circle cx="-20" cy="20" r="5" fill="#F44336"', animClass, '/>',
            '<circle cx="20" cy="20" r="5" fill="#F44336"', animClass, '/>',
            '</g>'
        );
    }

    function _generateTradeHubIcon(uint8 rarity, string memory rPrimary, string memory rSecondary)
        private pure returns (string memory)
    {
        string memory animClass = rarity >= 3 ? ' class="pulse"' : '';
        return string.concat(
            '<g transform="translate(150, 170)">',
            '<rect x="-55" y="-30" width="110" height="80" fill="#F57C00" stroke="', rPrimary, '" stroke-width="2" rx="6"/>',
            '<polygon points="-60,-30 0,-55 60,-30" fill="#E65100" stroke="', rPrimary, '" stroke-width="2"/>',
            '<line x1="0" y1="-45" x2="0" y2="-15" stroke="', rSecondary, '" stroke-width="3"/>',
            '<line x1="-25" y1="-25" x2="25" y2="-25" stroke="', rSecondary, '" stroke-width="3"/>',
            '<polygon points="-30,-20 -20,-20 -25,-5" fill="', rPrimary, '"', animClass, '/>',
            '<polygon points="20,-20 30,-20 25,-5" fill="', rPrimary, '"', animClass, '/>',
            '<rect x="-45" y="5" width="35" height="35" fill="#FFCC80" stroke="', rSecondary, '" stroke-width="1"/>',
            '<rect x="10" y="5" width="35" height="35" fill="#FFCC80" stroke="', rSecondary, '" stroke-width="1"/>',
            '</g>'
        );
    }

    function _generateEnergyPlantIcon(uint8 rarity, string memory rPrimary, string memory rSecondary)
        private pure returns (string memory)
    {
        string memory animClass = rarity >= 3 ? ' class="pulse"' : '';
        return string.concat(
            '<g transform="translate(150, 170)">',
            '<circle cx="0" cy="0" r="45" fill="#0D47A1" stroke="', rPrimary, '" stroke-width="3"/>',
            '<circle cx="0" cy="0" r="40" fill="#1565C0"/>',
            '<circle cx="0" cy="0" r="30" fill="#1976D2"/>',
            '<circle cx="0" cy="0" r="20" fill="', rSecondary, '" opacity="0.9"', animClass, '/>',
            '<circle cx="0" cy="0" r="12" fill="', rPrimary, '"', animClass, '/>',
            '<circle cx="0" cy="0" r="5" fill="#FFF" opacity="0.8"/>',
            '<ellipse cx="0" cy="0" rx="55" ry="20" fill="none" stroke="', rPrimary, '" stroke-width="2" opacity="0.5"',
            rarity == 4 ? ' class="rotate"' : '', '/>',
            '<path d="M-50,-40 L-40,-30 L-50,-20" stroke="', rPrimary, '" stroke-width="3" fill="none"', animClass, '/>',
            '<path d="M50,-40 L40,-30 L50,-20" stroke="', rPrimary, '" stroke-width="3" fill="none"', animClass, '/>',
            '</g>'
        );
    }

    function _generateBioLabIcon(uint8 rarity, string memory rPrimary, string memory rSecondary)
        private pure returns (string memory)
    {
        string memory animClass = rarity >= 3 ? ' class="pulse"' : '';
        return string.concat(
            '<g transform="translate(150, 170)">',
            '<path d="M-50,40 Q-55,-20 0,-50 Q55,-20 50,40 Z" fill="#1B5E20" stroke="', rPrimary, '" stroke-width="2"/>',
            '<path d="M-45,35 Q-50,-15 0,-45 Q50,-15 45,35 Z" fill="#2E7D32"/>',
            '<path d="M-35,30 Q-38,-10 0,-35 Q38,-10 35,30 Z" fill="#4CAF50" opacity="0.3"/>',
            '<path d="M-20,40 Q-25,20 -15,0 Q-10,-15 -5,-25" stroke="#8BC34A" stroke-width="3" fill="none"/>',
            '<path d="M0,40 Q5,15 0,-10 Q-5,-25 0,-35" stroke="#4CAF50" stroke-width="4" fill="none"/>',
            '<path d="M20,40 Q25,20 15,0 Q10,-15 5,-25" stroke="#8BC34A" stroke-width="3" fill="none"/>',
            '<ellipse cx="-15" cy="-20" rx="8" ry="5" fill="#8BC34A" transform="rotate(-30 -15 -20)"', animClass, '/>',
            '<ellipse cx="0" cy="-30" rx="10" ry="6" fill="#4CAF50"', animClass, '/>',
            '<ellipse cx="15" cy="-20" rx="8" ry="5" fill="#8BC34A" transform="rotate(30 15 -20)"', animClass, '/>',
            '</g>'
        );
    }

    function _generateMiningOutpostIcon(uint8 rarity, string memory rPrimary, string memory rSecondary)
        private pure returns (string memory)
    {
        string memory animClass = rarity >= 3 ? ' class="pulse"' : '';
        return string.concat(
            '<g transform="translate(150, 170)">',
            '<path d="M-50,50 L-60,50 L-50,-20 L50,-20 L60,50 L50,50 L40,0 L-40,0 Z" fill="#5D4037" stroke="', rPrimary, '" stroke-width="2"/>',
            '<rect x="-30" y="0" width="60" height="50" fill="#1A1A1A"/>',
            '<line x1="-35" y1="-5" x2="-35" y2="50" stroke="#8D6E63" stroke-width="6"/>',
            '<line x1="35" y1="-5" x2="35" y2="50" stroke="#8D6E63" stroke-width="6"/>',
            '<line x1="-40" y1="-5" x2="40" y2="-5" stroke="#8D6E63" stroke-width="8"/>',
            '<rect x="-15" y="35" width="30" height="18" fill="#757575" stroke="', rSecondary, '" stroke-width="1"/>',
            '<circle cx="-8" cy="55" r="5" fill="#424242" stroke="', rPrimary, '" stroke-width="1"/>',
            '<circle cx="8" cy="55" r="5" fill="#424242" stroke="', rPrimary, '" stroke-width="1"/>',
            '<polygon points="-10,35 0,28 10,35" fill="', rPrimary, '"', animClass, '/>',
            '<rect x="-50" y="-35" width="8" height="12" fill="', rPrimary, '" opacity="0.8"', animClass, '/>',
            '<rect x="42" y="-35" width="8" height="12" fill="', rPrimary, '" opacity="0.8"', animClass, '/>',
            '</g>'
        );
    }
}
