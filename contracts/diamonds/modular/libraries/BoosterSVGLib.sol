// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/utils/Strings.sol";

/**
 * @title BoosterSVGLib
 * @notice Library for generating Booster Card SVG graphics - Multi-system support
 * @dev Supports Buildings, Evolution, Venture, and Universal booster cards
 * @author rutilicus.eth (ArchXS)
 * @custom:version 2.0.0
 */
library BoosterSVGLib {
    using Strings for uint256;

    /// @notice Target system - compatible with LibBuildingsStorage.CardCompatibleSystem
    enum TargetSystem {
        Buildings,   // 0 - Colony buildings
        Evolution,   // 1 - Specimen evolution
        Venture,     // 2 - Resource ventures
        Universal    // 3 - All systems (explicit attachment required)
    }

    enum Rarity { Common, Uncommon, Rare, Epic, Legendary }

    /// @notice SubType names per system (for reference)
    // Buildings: 0=Warehouse, 1=Refinery, 2=Laboratory, 3=DefenseTower,
    //            4=TradeHub, 5=EnergyPlant, 6=BioLab, 7=MiningOutpost
    // Evolution: 0=Catalyst, 1=Accelerator, 2=Amplifier, 3=Mutator
    // Venture:   0=Scout, 1=Harvester, 2=Trader, 3=Guardian
    // Universal: 0=Booster, 1=Master, 2=Legacy, 3=Genesis

    struct BoosterTraits {
        TargetSystem targetSystem;    // Buildings(0), Evolution(1), Venture(2), Universal(3)
        uint8 subType;                // 0-7 per system
        Rarity rarity;                // 5 levels

        uint16 primaryBonusBps;       // Main bonus in basis points
        uint16 secondaryBonusBps;     // Secondary bonus
        uint8 level;                  // Level 1-5

        bool isBlueprint;             // Unactivated state
    }

    /**
     * @notice Generate complete SVG for booster card
     */
    function generateSVG(uint256 tokenId, BoosterTraits memory traits)
        internal pure returns (string memory)
    {
        string memory typeColors = _getSystemColorScheme(traits.targetSystem, traits.subType);
        (string memory rPrimary, string memory rSecondary, string memory rGlow) = _getRarityColors(traits.rarity);

        return string.concat(
            '<svg viewBox="0 0 300 400" xmlns="http://www.w3.org/2000/svg">',
            '<defs>', _generateDefs(typeColors, rPrimary, rSecondary, rGlow, traits.rarity, tokenId), '</defs>',
            _generateBackground(typeColors, tokenId),
            _generateRarityFrame(traits.rarity, rPrimary, rGlow, tokenId),
            _generateGrid(typeColors, traits.rarity, rPrimary),
            _generateBoosterIcon(traits, rPrimary, rSecondary),
            _generateParticles(traits.rarity, rPrimary, tokenId),
            _generateCyborgChickenWorkers(traits, rPrimary),
            _generateRaritySymbol(traits.rarity, rPrimary),
            _generateLevelStars(traits.level, rPrimary),
            _generateStatsBadges(traits, rPrimary, rSecondary),
            _generateSystemBadge(traits.targetSystem, traits.subType, typeColors),
            traits.isBlueprint ? _generateBlueprintOverlay(rPrimary) : '',
            '</svg>'
        );
    }

    // ============ COLOR SCHEMES ============

    function _getSystemColorScheme(TargetSystem system, uint8 subType) private pure returns (string memory) {
        if (system == TargetSystem.Buildings) {
            return _getBuildingColors(subType);
        }
        if (system == TargetSystem.Evolution) {
            return _getEvolutionColors(subType);
        }
        if (system == TargetSystem.Venture) {
            return _getVentureColors(subType);
        }
        return _getUniversalColors(subType);
    }

    function _getBuildingColors(uint8 subType) private pure returns (string memory) {
        if (subType == 0) return "#8B4513,#A0522D,#CD853F"; // Warehouse - Browns
        if (subType == 1) return "#FF6B35,#FF8C42,#FFB347"; // Refinery - Oranges
        if (subType == 2) return "#00CED1,#20B2AA,#48D1CC"; // Laboratory - Cyan
        if (subType == 3) return "#DC143C,#B22222,#FF4500"; // DefenseTower - Reds
        if (subType == 4) return "#FFD700,#FFA500,#DAA520"; // TradeHub - Golds
        if (subType == 5) return "#00BFFF,#1E90FF,#4169E1"; // EnergyPlant - Blues
        if (subType == 6) return "#32CD32,#228B22,#00FF7F"; // BioLab - Greens
        return "#A0522D,#8B4513,#D2691E"; // MiningOutpost - Browns
    }

    function _getEvolutionColors(uint8 subType) private pure returns (string memory) {
        if (subType == 0) return "#9C27B0,#BA68C8,#E1BEE7"; // Catalyst - Purple
        if (subType == 1) return "#673AB7,#9575CD,#D1C4E9"; // Accelerator - Deep Purple
        if (subType == 2) return "#7B1FA2,#AB47BC,#CE93D8"; // Amplifier - Purple accent
        return "#4A148C,#7B1FA2,#9C27B0"; // Mutator - Dark purple
    }

    function _getVentureColors(uint8 subType) private pure returns (string memory) {
        if (subType == 0) return "#FF6F00,#FF8F00,#FFAB00"; // Scout - Amber
        if (subType == 1) return "#E65100,#EF6C00,#F57C00"; // Harvester - Deep Orange
        if (subType == 2) return "#FF5722,#FF7043,#FF8A65"; // Trader - Orange
        return "#BF360C,#D84315,#E64A19"; // Guardian - Deep red-orange
    }

    function _getUniversalColors(uint8 subType) private pure returns (string memory) {
        if (subType == 0) return "#FFD700,#FFA500,#FF6347"; // Booster - Gold to red
        if (subType == 1) return "#00BCD4,#4CAF50,#CDDC39"; // Master - Teal to green
        if (subType == 2) return "#E91E63,#9C27B0,#673AB7"; // Legacy - Pink to purple
        return "#FFD700,#00BCD4,#E91E63"; // Genesis - Rainbow
    }

    function _getRarityColors(Rarity rarity)
        private pure returns (string memory primary, string memory secondary, string memory glow)
    {
        if (rarity == Rarity.Legendary) {
            return ("#FFD700", "#FFED4E", "#FFAA00");
        }
        if (rarity == Rarity.Epic) {
            return ("#9B59B6", "#C39BD3", "#8E44AD");
        }
        if (rarity == Rarity.Rare) {
            return ("#3498DB", "#5DADE2", "#2980B9");
        }
        if (rarity == Rarity.Uncommon) {
            return ("#2ECC71", "#58D68D", "#27AE60");
        }
        return ("#95A5A6", "#BDC3C7", "#7F8C8D");
    }

    // ============ SVG GENERATION ============

    function _generateDefs(
        string memory typeColors,
        string memory rPrimary,
        string memory rSecondary,
        string memory rGlow,
        Rarity rarity,
        uint256 tokenId
    ) private pure returns (string memory) {
        (string memory c1, string memory c2, ) = _splitColors(typeColors);
        string memory id = tokenId.toString();

        return string.concat(
            '<radialGradient id="bg-', id, '" cx="50%" cy="30%">',
            '<stop offset="0%" stop-color="', c1, '" stop-opacity="0.4"/>',
            '<stop offset="100%" stop-color="', c2, '" stop-opacity="0.15"/>',
            '</radialGradient>',
            '<linearGradient id="frame-', id, '" x1="0%" y1="0%" x2="100%" y2="100%">',
            '<stop offset="0%" stop-color="', rPrimary, '"/>',
            '<stop offset="50%" stop-color="', rSecondary, '"/>',
            '<stop offset="100%" stop-color="', rGlow, '"/>',
            '</linearGradient>',
            '<filter id="glow-', id, '">',
            '<feGaussianBlur stdDeviation="', rarity == Rarity.Legendary ? "5" : rarity == Rarity.Epic ? "4" : "3", '" result="blur"/>',
            '<feMerge><feMergeNode in="blur"/><feMergeNode in="SourceGraphic"/></feMerge>',
            '</filter>',
            _generateAnimationStyles(rarity)
        );
    }

    function _generateAnimationStyles(Rarity rarity) private pure returns (string memory) {
        if (rarity == Rarity.Legendary) {
            return '<style>'
                '.pulse{animation:pulse 2s ease-in-out infinite}'
                '@keyframes pulse{0%,100%{opacity:0.6}50%{opacity:1}}'
                '.rotate{animation:rotate 20s linear infinite;transform-origin:center}'
                '@keyframes rotate{from{transform:rotate(0)}to{transform:rotate(360deg)}}'
                '.gear{animation:gear 8s linear infinite;transform-origin:center}'
                '@keyframes gear{from{transform:rotate(0)}to{transform:rotate(-360deg)}}'
                '.shimmer{animation:shimmer 2s linear infinite}'
                '@keyframes shimmer{0%{opacity:0.3}50%{opacity:1}100%{opacity:0.3}}'
                '.float{animation:float 3s ease-in-out infinite}'
                '@keyframes float{0%,100%{transform:translateY(0)}50%{transform:translateY(-10px)}}'
                '</style>';
        }
        if (rarity == Rarity.Epic) {
            return '<style>'
                '.pulse{animation:pulse 3s ease-in-out infinite}'
                '@keyframes pulse{0%,100%{opacity:0.5}50%{opacity:0.9}}'
                '.gear{animation:gear 12s linear infinite;transform-origin:center}'
                '@keyframes gear{from{transform:rotate(0)}to{transform:rotate(-360deg)}}'
                '.float{animation:float 4s ease-in-out infinite}'
                '@keyframes float{0%,100%{transform:translateY(0)}50%{transform:translateY(-5px)}}'
                '</style>';
        }
        return '<style>.pulse{animation:pulse 4s ease-in-out infinite}@keyframes pulse{0%,100%{opacity:0.4}50%{opacity:0.7}}</style>';
    }

    function _generateBackground(string memory typeColors, uint256 tokenId)
        private pure returns (string memory)
    {
        string memory id = tokenId.toString();
        return string.concat(
            '<rect width="300" height="400" fill="#0a0a14" rx="12"/>',
            '<rect width="300" height="400" fill="url(#bg-', id, ')" rx="12"/>'
        );
    }

    function _generateRarityFrame(
        Rarity rarity,
        string memory rPrimary,
        string memory rGlow,
        uint256 tokenId
    ) private pure returns (string memory) {
        string memory id = tokenId.toString();
        uint8 strokeWidth = rarity == Rarity.Legendary ? 4 :
                           rarity == Rarity.Epic ? 3 :
                           rarity == Rarity.Rare ? 2 : 1;

        string memory frame = string.concat(
            '<rect x="5" y="5" width="290" height="390" rx="10" fill="none" ',
            'stroke="url(#frame-', id, ')" stroke-width="', _uint8ToString(strokeWidth), '"',
            rarity == Rarity.Legendary ? ' filter="url(#glow-' : '',
            rarity == Rarity.Legendary ? string.concat(id, ')"') : '',
            '/>'
        );

        if (rarity == Rarity.Legendary || rarity == Rarity.Epic) {
            frame = string.concat(
                frame,
                '<rect x="8" y="8" width="284" height="384" rx="8" fill="none" ',
                'stroke="', rGlow, '" stroke-width="1" opacity="0.5"/>'
            );
        }

        // Corner decorations for Legendary
        if (rarity == Rarity.Legendary) {
            frame = string.concat(
                frame,
                '<circle cx="20" cy="20" r="8" fill="none" stroke="', rPrimary, '" stroke-width="2" class="gear"/>',
                '<circle cx="280" cy="20" r="8" fill="none" stroke="', rPrimary, '" stroke-width="2" class="gear"/>',
                '<circle cx="20" cy="380" r="8" fill="none" stroke="', rPrimary, '" stroke-width="2" class="gear"/>',
                '<circle cx="280" cy="380" r="8" fill="none" stroke="', rPrimary, '" stroke-width="2" class="gear"/>'
            );
        }

        return frame;
    }

    function _generateGrid(string memory typeColors, Rarity rarity, string memory rPrimary)
        private pure returns (string memory)
    {
        (string memory c1, , ) = _splitColors(typeColors);
        string memory gridColor = rarity >= Rarity.Epic ? rPrimary : c1;

        string memory lines = '';
        for (uint256 i = 0; i <= 300; i += 25) {
            lines = string.concat(
                lines,
                '<line x1="', i.toString(), '" y1="0" x2="', i.toString(), '" y2="400" ',
                'stroke="', gridColor, '" stroke-width="0.4" opacity="0.12"/>',
                '<line x1="0" y1="', (i * 4 / 3).toString(), '" x2="300" y2="', (i * 4 / 3).toString(), '" ',
                'stroke="', gridColor, '" stroke-width="0.4" opacity="0.12"/>'
            );
        }

        return string.concat('<g>', lines, '</g>');
    }

    function _generateBoosterIcon(
        BoosterTraits memory traits,
        string memory rPrimary,
        string memory rSecondary
    ) private pure returns (string memory) {
        if (traits.targetSystem == TargetSystem.Buildings) {
            return _generateBuildingIcon(traits.subType, traits.rarity, rPrimary, rSecondary);
        }
        if (traits.targetSystem == TargetSystem.Evolution) {
            return _generateEvolutionIcon(traits.subType, traits.rarity, rPrimary, rSecondary);
        }
        if (traits.targetSystem == TargetSystem.Venture) {
            return _generateVentureIcon(traits.subType, traits.rarity, rPrimary, rSecondary);
        }
        return _generateUniversalIcon(traits.subType, traits.rarity, rPrimary, rSecondary);
    }

    // ============ BUILDING ICONS (subType 0-7) ============

    function _generateBuildingIcon(uint8 subType, Rarity rarity, string memory rPrimary, string memory rSecondary)
        private pure returns (string memory)
    {
        if (subType == 0) return _generateWarehouseIcon(rarity, rPrimary, rSecondary);
        if (subType == 1) return _generateRefineryIcon(rarity, rPrimary, rSecondary);
        if (subType == 2) return _generateLaboratoryIcon(rarity, rPrimary, rSecondary);
        if (subType == 3) return _generateDefenseTowerIcon(rarity, rPrimary, rSecondary);
        if (subType == 4) return _generateTradeHubIcon(rarity, rPrimary, rSecondary);
        if (subType == 5) return _generateEnergyPlantIcon(rarity, rPrimary, rSecondary);
        if (subType == 6) return _generateBioLabIcon(rarity, rPrimary, rSecondary);
        return _generateMiningOutpostIcon(rarity, rPrimary, rSecondary);
    }

    function _generateWarehouseIcon(Rarity rarity, string memory rPrimary, string memory rSecondary)
        private pure returns (string memory)
    {
        string memory animClass = rarity >= Rarity.Epic ? ' class="pulse"' : '';
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

    function _generateRefineryIcon(Rarity rarity, string memory rPrimary, string memory rSecondary)
        private pure returns (string memory)
    {
        string memory animClass = rarity >= Rarity.Epic ? ' class="pulse"' : '';
        return string.concat(
            '<g transform="translate(150, 170)">',
            '<rect x="-50" y="-30" width="100" height="90" fill="#424242" stroke="', rPrimary, '" stroke-width="2" rx="4"/>',
            '<rect x="-45" y="-25" width="90" height="80" fill="#616161"/>',
            '<rect x="-40" y="-70" width="15" height="45" fill="#757575" stroke="', rSecondary, '" stroke-width="1"/>',
            '<rect x="25" y="-70" width="15" height="45" fill="#757575" stroke="', rSecondary, '" stroke-width="1"/>',
            '<g transform="translate(-20, 10)">',
            '<circle cx="0" cy="0" r="20" fill="', rSecondary, '" stroke="', rPrimary, '" stroke-width="2"',
            rarity == Rarity.Legendary ? ' class="gear"' : '', '/>',
            '<circle cx="0" cy="0" r="8" fill="#424242"/>',
            '</g>',
            '<circle cx="-30" cy="-10" r="4" fill="#4CAF50"', animClass, '/>',
            '<circle cx="30" cy="-10" r="4" fill="', rPrimary, '"', animClass, '/>',
            '</g>'
        );
    }

    function _generateLaboratoryIcon(Rarity rarity, string memory rPrimary, string memory rSecondary)
        private pure returns (string memory)
    {
        string memory animClass = rarity >= Rarity.Epic ? ' class="pulse"' : '';
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

    function _generateDefenseTowerIcon(Rarity rarity, string memory rPrimary, string memory rSecondary)
        private pure returns (string memory)
    {
        string memory animClass = rarity >= Rarity.Epic ? ' class="pulse"' : '';
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

    function _generateTradeHubIcon(Rarity rarity, string memory rPrimary, string memory rSecondary)
        private pure returns (string memory)
    {
        string memory animClass = rarity >= Rarity.Epic ? ' class="pulse"' : '';
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

    function _generateEnergyPlantIcon(Rarity rarity, string memory rPrimary, string memory rSecondary)
        private pure returns (string memory)
    {
        string memory animClass = rarity >= Rarity.Epic ? ' class="pulse"' : '';
        return string.concat(
            '<g transform="translate(150, 170)">',
            '<circle cx="0" cy="0" r="45" fill="#0D47A1" stroke="', rPrimary, '" stroke-width="3"/>',
            '<circle cx="0" cy="0" r="40" fill="#1565C0"/>',
            '<circle cx="0" cy="0" r="30" fill="#1976D2"/>',
            '<circle cx="0" cy="0" r="20" fill="', rSecondary, '" opacity="0.9"', animClass, '/>',
            '<circle cx="0" cy="0" r="12" fill="', rPrimary, '"', animClass, '/>',
            '<circle cx="0" cy="0" r="5" fill="#FFF" opacity="0.8"/>',
            '<ellipse cx="0" cy="0" rx="55" ry="20" fill="none" stroke="', rPrimary, '" stroke-width="2" opacity="0.5"',
            rarity == Rarity.Legendary ? ' class="rotate"' : '', '/>',
            '<path d="M-50,-40 L-40,-30 L-50,-20" stroke="', rPrimary, '" stroke-width="3" fill="none"', animClass, '/>',
            '<path d="M50,-40 L40,-30 L50,-20" stroke="', rPrimary, '" stroke-width="3" fill="none"', animClass, '/>',
            '</g>'
        );
    }

    function _generateBioLabIcon(Rarity rarity, string memory rPrimary, string memory rSecondary)
        private pure returns (string memory)
    {
        string memory animClass = rarity >= Rarity.Epic ? ' class="pulse"' : '';
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

    function _generateMiningOutpostIcon(Rarity rarity, string memory rPrimary, string memory rSecondary)
        private pure returns (string memory)
    {
        string memory animClass = rarity >= Rarity.Epic ? ' class="pulse"' : '';
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

    // ============ EVOLUTION ICONS (subType 0-3) ============

    function _generateEvolutionIcon(uint8 subType, Rarity rarity, string memory rPrimary, string memory rSecondary)
        private pure returns (string memory)
    {
        string memory animClass = rarity >= Rarity.Epic ? ' class="pulse"' : '';
        string memory floatClass = rarity >= Rarity.Epic ? ' class="float"' : '';

        if (subType == 0) {
            // Catalyst - DNA helix with catalyst particles
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
        if (subType == 1) {
            // Accelerator - Fast forward arrows with speed lines
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
        if (subType == 2) {
            // Amplifier - Expanding circles (power amplification)
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
        // Mutator - DNA mutation symbol with lightning
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

    // ============ VENTURE ICONS (subType 0-3) ============

    function _generateVentureIcon(uint8 subType, Rarity rarity, string memory rPrimary, string memory rSecondary)
        private pure returns (string memory)
    {
        string memory animClass = rarity >= Rarity.Epic ? ' class="pulse"' : '';
        string memory rotateClass = rarity == Rarity.Legendary ? ' class="rotate"' : '';

        if (subType == 0) {
            // Scout - Compass
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
        if (subType == 1) {
            // Harvester - Treasure chest with gems
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
        if (subType == 2) {
            // Trader - Scales/balance
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
        // Guardian - Shield
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

    // ============ UNIVERSAL ICONS (subType 0-3) ============

    function _generateUniversalIcon(uint8 subType, Rarity rarity, string memory rPrimary, string memory rSecondary)
        private pure returns (string memory)
    {
        string memory animClass = ' class="pulse"'; // Universal always animated
        string memory rotateClass = ' class="rotate"';

        if (subType == 0) {
            // Booster - Star burst
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
        if (subType == 1) {
            // Master - Infinity symbol with orbs
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
        if (subType == 2) {
            // Legacy - Crown
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
        // Genesis - Cosmic orb
        return string.concat(
            '<g transform="translate(150, 170)">',
            '<circle cx="0" cy="0" r="50" fill="url(#genesis-grad)" stroke="', rPrimary, '" stroke-width="2"/>',
            '<defs><radialGradient id="genesis-grad">',
            '<stop offset="0%" stop-color="', rPrimary, '"/>',
            '<stop offset="50%" stop-color="', rSecondary, '"/>',
            '<stop offset="100%" stop-color="#000"/>',
            '</radialGradient></defs>',
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
    }

    // ============ COMMON ELEMENTS ============

    function _generateParticles(Rarity rarity, string memory rPrimary, uint256)
        private pure returns (string memory)
    {
        if (rarity < Rarity.Rare) return '';

        uint8 count = rarity == Rarity.Legendary ? 8 : rarity == Rarity.Epic ? 5 : 3;
        string memory particles = '';

        uint16[8] memory xPositions = [uint16(25), 275, 20, 280, 25, 275, 30, 270];
        uint16[8] memory yPositions = [uint16(80), 85, 150, 155, 220, 215, 290, 285];

        for (uint8 i = 0; i < count; i++) {
            particles = string.concat(
                particles,
                '<circle cx="', uint256(xPositions[i]).toString(),
                '" cy="', uint256(yPositions[i]).toString(),
                '" r="3" fill="', rPrimary, '" opacity="0.4" class="pulse"/>'
            );
        }

        return string.concat('<g>', particles, '</g>');
    }

    function _generateCyborgChickenWorkers(BoosterTraits memory traits, string memory rPrimary)
        private pure returns (string memory)
    {
        (string memory c1, string memory c2, ) = _splitColors(_getSystemColorScheme(traits.targetSystem, traits.subType));
        string memory chickenBorder = traits.rarity >= Rarity.Epic ? rPrimary : c1;

        return string.concat(
            '<g transform="translate(45, 355) scale(0.75)">',
            '<ellipse cx="0" cy="0" rx="12" ry="14" fill="', c2, '" stroke="', chickenBorder, '" stroke-width="1"/>',
            '<circle cx="0" cy="-16" r="9" fill="', c1, '" stroke="', chickenBorder, '" stroke-width="1"/>',
            '<circle cx="-3" cy="-17" r="2" fill="#000"/>',
            '<circle cx="3" cy="-17" r="2" fill="#000"/>',
            '<polygon points="7,-16 10,-13 7,-10" fill="#FF9800"/>',
            '<path d="M-8,-24 Q0,-30 8,-24" fill="', rPrimary, '"/>',
            '<rect x="-10" y="-24" width="20" height="4" fill="', rPrimary, '" rx="1"/>',
            '</g>',
            '<g transform="translate(255, 355) scale(0.75)">',
            '<ellipse cx="0" cy="0" rx="12" ry="14" fill="', c1, '" stroke="', chickenBorder, '" stroke-width="1"/>',
            '<circle cx="0" cy="-16" r="9" fill="', c2, '" stroke="', chickenBorder, '" stroke-width="1"/>',
            '<circle cx="-3" cy="-17" r="2" fill="#000"/>',
            '<circle cx="3" cy="-17" r="2" fill="#000"/>',
            '<polygon points="-7,-16 -10,-13 -7,-10" fill="#FF9800"/>',
            '<rect x="8" y="-8" width="3" height="18" fill="#757575"/>',
            '<circle cx="9" cy="-10" r="4" fill="none" stroke="#757575" stroke-width="2"/>',
            '</g>'
        );
    }

    function _generateRaritySymbol(Rarity rarity, string memory color)
        private pure returns (string memory)
    {
        string memory symbol;

        if (rarity == Rarity.Legendary) {
            symbol = unicode"⚙";
        } else if (rarity == Rarity.Epic) {
            symbol = unicode"★";
        } else if (rarity == Rarity.Rare) {
            symbol = unicode"◆";
        } else if (rarity == Rarity.Uncommon) {
            symbol = unicode"▲";
        } else {
            symbol = unicode"●";
        }

        return string.concat(
            '<text x="25" y="35" text-anchor="middle" fill="', color,
            '" font-size="22" font-weight="900"',
            rarity == Rarity.Legendary ? ' class="shimmer"' : '',
            '>', symbol, '</text>'
        );
    }

    function _generateLevelStars(uint8 level, string memory color)
        private pure returns (string memory)
    {
        string memory stars = '';
        uint8 lvl = level > 5 ? 5 : level;

        for (uint8 i = 0; i < lvl; i++) {
            stars = string.concat(
                stars,
                '<text x="', uint256(70 + i * 18).toString(),
                '" y="55" fill="', color, '" font-size="14">', unicode'★', '</text>'
            );
        }

        for (uint8 i = lvl; i < 5; i++) {
            stars = string.concat(
                stars,
                '<text x="', uint256(70 + i * 18).toString(),
                '" y="55" fill="#444" font-size="14">', unicode'☆', '</text>'
            );
        }

        return string.concat(
            '<text x="25" y="55" fill="#888" font-size="10">LEVEL</text>',
            stars
        );
    }

    function _generateStatsBadges(BoosterTraits memory traits, string memory rPrimary, string memory)
        private pure returns (string memory)
    {
        string memory primaryLabel = _getPrimaryBonusLabel(traits.targetSystem);
        string memory secondaryLabel = _getSecondaryBonusLabel(traits.targetSystem);

        return string.concat(
            '<g transform="translate(185, 25)">',
            '<rect x="0" y="0" width="95" height="24" fill="rgba(10,10,20,0.6)" rx="12" stroke="', rPrimary, '" stroke-width="1" stroke-opacity="0.7"/>',
            '<text x="48" y="16" text-anchor="middle" fill="', rPrimary, '" font-size="10" font-weight="bold">',
            _formatBps(traits.primaryBonusBps), ' ', primaryLabel, '</text>',
            '</g>',
            traits.secondaryBonusBps > 0 ? string.concat(
                '<g transform="translate(185, 55)">',
                '<rect x="0" y="0" width="95" height="20" fill="rgba(10,10,20,0.5)" rx="10" stroke="', rPrimary, '" stroke-width="1" stroke-opacity="0.5"/>',
                '<text x="48" y="14" text-anchor="middle" fill="', rPrimary, '" font-size="9">+',
                _formatBps(traits.secondaryBonusBps), ' ', secondaryLabel, '</text>',
                '</g>'
            ) : ''
        );
    }

    function _getPrimaryBonusLabel(TargetSystem system) private pure returns (string memory) {
        if (system == TargetSystem.Buildings) return "EFF";
        if (system == TargetSystem.Evolution) return "COST";
        if (system == TargetSystem.Venture) return "SUCC";
        return "ALL";
    }

    function _getSecondaryBonusLabel(TargetSystem system) private pure returns (string memory) {
        if (system == TargetSystem.Buildings) return "CAP";
        if (system == TargetSystem.Evolution) return "TIER";
        if (system == TargetSystem.Venture) return "RWD";
        return "MULT";
    }

    function _formatBps(uint16 bps) private pure returns (string memory) {
        uint256 pct = uint256(bps) / 100;
        return string.concat(pct.toString(), "%");
    }

    function _generateSystemBadge(TargetSystem system, uint8 subType, string memory typeColors)
        private pure returns (string memory)
    {
        (string memory c1, , ) = _splitColors(typeColors);
        string memory typeName = _getSubTypeName(system, subType);
        string memory systemIcon = _getSystemIcon(system);

        return string.concat(
            '<g transform="translate(150, 285)">',
            '<rect x="-60" y="-12" width="120" height="24" rx="12" fill="rgba(0,0,0,0.7)" stroke="', c1, '" stroke-width="1"/>',
            '<text x="0" y="5" text-anchor="middle" fill="', c1, '" font-size="10" font-weight="bold">', typeName, '</text>',
            '</g>',
            '<g transform="translate(25, 310)">',
            '<rect x="0" y="0" width="80" height="24" rx="12" fill="rgba(0,0,0,0.6)" stroke="', c1, '" stroke-width="1"/>',
            '<text x="15" y="17" fill="', c1, '" font-size="14">', systemIcon, '</text>',
            '<text x="35" y="16" fill="', c1, '" font-size="8" font-weight="bold">', _getSystemName(system), '</text>',
            '</g>',
            '<text x="150" y="388" text-anchor="middle" fill="#444" font-size="9" letter-spacing="8" font-weight="300">HENOMORPHS</text>'
        );
    }

    function _getSystemIcon(TargetSystem system) private pure returns (string memory) {
        if (system == TargetSystem.Buildings) return unicode"🏗";
        if (system == TargetSystem.Evolution) return unicode"🧬";
        if (system == TargetSystem.Venture) return unicode"⚔";
        return unicode"✧";
    }

    function _getSystemName(TargetSystem system) private pure returns (string memory) {
        if (system == TargetSystem.Buildings) return "BUILDING";
        if (system == TargetSystem.Evolution) return "EVOLUTION";
        if (system == TargetSystem.Venture) return "VENTURE";
        return "UNIVERSAL";
    }

    function _getSubTypeName(TargetSystem system, uint8 subType) private pure returns (string memory) {
        if (system == TargetSystem.Buildings) {
            if (subType == 0) return "WAREHOUSE";
            if (subType == 1) return "REFINERY";
            if (subType == 2) return "LABORATORY";
            if (subType == 3) return "DEFENSE TOWER";
            if (subType == 4) return "TRADE HUB";
            if (subType == 5) return "ENERGY PLANT";
            if (subType == 6) return "BIO LAB";
            return "MINING OUTPOST";
        }
        if (system == TargetSystem.Evolution) {
            if (subType == 0) return "CATALYST";
            if (subType == 1) return "ACCELERATOR";
            if (subType == 2) return "AMPLIFIER";
            return "MUTATOR";
        }
        if (system == TargetSystem.Venture) {
            if (subType == 0) return "SCOUT";
            if (subType == 1) return "HARVESTER";
            if (subType == 2) return "TRADER";
            return "GUARDIAN";
        }
        // Universal
        if (subType == 0) return "BOOSTER";
        if (subType == 1) return "MASTER";
        if (subType == 2) return "LEGACY";
        return "GENESIS";
    }

    function _generateBlueprintOverlay(string memory rPrimary)
        private pure returns (string memory)
    {
        return string.concat(
            '<rect x="0" y="0" width="300" height="400" fill="rgba(0,50,100,0.3)" rx="12"/>',
            '<text x="150" y="320" text-anchor="middle" fill="', rPrimary, '" font-size="16" font-weight="bold">BLUEPRINT</text>',
            '<text x="150" y="340" text-anchor="middle" fill="#AAA" font-size="10">Requires activation</text>'
        );
    }

    // ============ UTILITY FUNCTIONS ============

    function _splitColors(string memory colors)
        private pure returns (string memory c1, string memory c2, string memory c3)
    {
        bytes memory b = bytes(colors);
        uint256 firstComma = 0;
        uint256 secondComma = 0;

        for (uint256 i = 0; i < b.length; i++) {
            if (b[i] == ",") {
                if (firstComma == 0) {
                    firstComma = i;
                } else {
                    secondComma = i;
                    break;
                }
            }
        }

        bytes memory color1 = new bytes(firstComma);
        bytes memory color2 = new bytes(secondComma - firstComma - 1);
        bytes memory color3 = new bytes(b.length - secondComma - 1);

        for (uint256 i = 0; i < firstComma; i++) {
            color1[i] = b[i];
        }
        for (uint256 i = 0; i < color2.length; i++) {
            color2[i] = b[firstComma + 1 + i];
        }
        for (uint256 i = 0; i < color3.length; i++) {
            color3[i] = b[secondComma + 1 + i];
        }

        return (string(color1), string(color2), string(color3));
    }

    function _uint8ToString(uint8 value) private pure returns (string memory) {
        return Strings.toString(uint256(value));
    }
}
