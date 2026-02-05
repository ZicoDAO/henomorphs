// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/utils/Strings.sol";

/**
 * @title BuildingSVGLib
 * @notice Library for generating Building Card SVG graphics - Hendom Visual Style
 * @dev Based on ResourceSVGLib and TerritorySVGLib visual patterns
 * @author rutilicus.eth (ArchXS)
 * @custom:version 1.0.0
 */
library BuildingSVGLib {
    using Strings for uint256;

    enum BuildingType {
        Warehouse,        // 0 - Reduces resource decay
        Refinery,         // 1 - Increases processing efficiency
        Laboratory,       // 2 - Tech level bonus
        DefenseTower,     // 3 - Raid protection
        TradeHub,         // 4 - Marketplace fee reduction
        EnergyPlant,      // 5 - Passive energy generation
        BioLab,           // 6 - Passive bio compound generation
        MiningOutpost     // 7 - Passive basic materials generation
    }

    enum Rarity { Common, Uncommon, Rare, Epic, Legendary }

    struct BuildingTraits {
        BuildingType buildingType;
        Rarity rarity;
        uint8 efficiencyBonus;    // Efficiency multiplier (100-200%)
        uint8 durabilityLevel;    // Durability tier (1-5)
        uint16 capacityBonus;     // Capacity bonus percentage
        bool isBlueprint;         // True if unbuilt blueprint
    }

    /**
     * @notice Generate complete SVG for building card
     */
    function generateSVG(uint256 tokenId, BuildingTraits memory traits)
        internal pure returns (string memory)
    {
        string memory typeColors = _getTypeColorScheme(traits.buildingType);
        (string memory rPrimary, string memory rSecondary, string memory rGlow) = _getRarityColors(traits.rarity);

        return string.concat(
            '<svg viewBox="0 0 300 400" xmlns="http://www.w3.org/2000/svg">',
            '<defs>', _generateDefs(typeColors, rPrimary, rSecondary, rGlow, traits.rarity, tokenId), '</defs>',
            _generateBackground(typeColors, tokenId),
            _generateRarityFrame(traits.rarity, rPrimary, rGlow, tokenId),
            _generateGrid(typeColors, traits.rarity, rPrimary),
            _generateBuildingIcon(traits, rPrimary, rSecondary),
            _generateParticles(traits.rarity, rPrimary, tokenId),
            _generateCyborgChickenWorkers(traits, rPrimary),
            _generateRaritySymbol(traits.rarity, rPrimary),
            _generateDurabilityStars(traits.durabilityLevel, rPrimary),
            _generateStatsBadges(traits, rPrimary, rSecondary),
            _generateTypeBadge(traits.buildingType, typeColors),
            traits.isBlueprint ? _generateBlueprintOverlay(rPrimary) : '',
            '</svg>'
        );
    }

    // ============ COLOR SCHEMES ============

    function _getTypeColorScheme(BuildingType bType) private pure returns (string memory) {
        if (bType == BuildingType.Warehouse) {
            return "#8B4513,#A0522D,#CD853F"; // Browns (storage)
        }
        if (bType == BuildingType.Refinery) {
            return "#FF6B35,#FF8C42,#FFB347"; // Oranges (industrial)
        }
        if (bType == BuildingType.Laboratory) {
            return "#00CED1,#20B2AA,#48D1CC"; // Cyan (science)
        }
        if (bType == BuildingType.DefenseTower) {
            return "#DC143C,#B22222,#FF4500"; // Reds (defense)
        }
        if (bType == BuildingType.TradeHub) {
            return "#FFD700,#FFA500,#DAA520"; // Golds (commerce)
        }
        if (bType == BuildingType.EnergyPlant) {
            return "#00BFFF,#1E90FF,#4169E1"; // Blues (energy)
        }
        if (bType == BuildingType.BioLab) {
            return "#32CD32,#228B22,#00FF7F"; // Greens (bio)
        }
        return "#A0522D,#8B4513,#D2691E"; // Browns (mining)
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
                '.smoke{animation:smoke 3s ease-out infinite}'
                '@keyframes smoke{0%{opacity:0.8;transform:translateY(0)}100%{opacity:0;transform:translateY(-20px)}}'
                '</style>';
        }
        if (rarity == Rarity.Epic) {
            return '<style>'
                '.pulse{animation:pulse 3s ease-in-out infinite}'
                '@keyframes pulse{0%,100%{opacity:0.5}50%{opacity:0.9}}'
                '.gear{animation:gear 12s linear infinite;transform-origin:center}'
                '@keyframes gear{from{transform:rotate(0)}to{transform:rotate(-360deg)}}'
                '.smoke{animation:smoke 4s ease-out infinite}'
                '@keyframes smoke{0%{opacity:0.6;transform:translateY(0)}100%{opacity:0;transform:translateY(-15px)}}'
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

        // Corner gears for Legendary buildings
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

    function _generateBuildingIcon(
        BuildingTraits memory traits,
        string memory rPrimary,
        string memory rSecondary
    ) private pure returns (string memory) {
        if (traits.buildingType == BuildingType.Warehouse) {
            return _generateWarehouseIcon(traits.rarity, rPrimary, rSecondary);
        }
        if (traits.buildingType == BuildingType.Refinery) {
            return _generateRefineryIcon(traits.rarity, rPrimary, rSecondary);
        }
        if (traits.buildingType == BuildingType.Laboratory) {
            return _generateLaboratoryIcon(traits.rarity, rPrimary, rSecondary);
        }
        if (traits.buildingType == BuildingType.DefenseTower) {
            return _generateDefenseTowerIcon(traits.rarity, rPrimary, rSecondary);
        }
        if (traits.buildingType == BuildingType.TradeHub) {
            return _generateTradeHubIcon(traits.rarity, rPrimary, rSecondary);
        }
        if (traits.buildingType == BuildingType.EnergyPlant) {
            return _generateEnergyPlantIcon(traits.rarity, rPrimary, rSecondary);
        }
        if (traits.buildingType == BuildingType.BioLab) {
            return _generateBioLabIcon(traits.rarity, rPrimary, rSecondary);
        }
        return _generateMiningOutpostIcon(traits.rarity, rPrimary, rSecondary);
    }

    function _generateWarehouseIcon(Rarity rarity, string memory rPrimary, string memory rSecondary)
        private pure returns (string memory)
    {
        string memory animClass = rarity >= Rarity.Epic ? ' class="pulse"' : '';

        return string.concat(
            '<g transform="translate(150, 170)">',
            // Main warehouse structure
            '<rect x="-60" y="-40" width="120" height="80" fill="#5D4037" stroke="', rPrimary, '" stroke-width="2" rx="4"/>',
            '<rect x="-55" y="-35" width="110" height="70" fill="#795548"/>',
            // Roof
            '<polygon points="-70,-40 0,-70 70,-40" fill="#3E2723" stroke="', rPrimary, '" stroke-width="2"/>',
            '<polygon points="-65,-40 0,-65 65,-40" fill="#4E342E"/>',
            // Large door
            '<rect x="-25" y="0" width="50" height="40" fill="#3E2723" stroke="', rSecondary, '" stroke-width="1"/>',
            '<line x1="0" y1="0" x2="0" y2="40" stroke="', rSecondary, '" stroke-width="1"/>',
            // Windows
            '<rect x="-50" y="-25" width="18" height="18" fill="#87CEEB" opacity="0.6"', animClass, '/>',
            '<rect x="32" y="-25" width="18" height="18" fill="#87CEEB" opacity="0.6"', animClass, '/>',
            // Crates
            '<rect x="-55" y="45" width="25" height="20" fill="', rSecondary, '" stroke="', rPrimary, '" stroke-width="1"/>',
            '<rect x="-25" y="50" width="20" height="15" fill="', rPrimary, '" opacity="0.8"/>',
            '<rect x="30" y="45" width="25" height="20" fill="', rSecondary, '" stroke="', rPrimary, '" stroke-width="1"/>',
            '</g>'
        );
    }

    function _generateRefineryIcon(Rarity rarity, string memory rPrimary, string memory rSecondary)
        private pure returns (string memory)
    {
        string memory animClass = rarity >= Rarity.Epic ? ' class="pulse"' : '';
        string memory smokeClass = rarity >= Rarity.Epic ? ' class="smoke"' : '';

        return string.concat(
            '<g transform="translate(150, 170)">',
            // Main structure
            '<rect x="-50" y="-30" width="100" height="90" fill="#424242" stroke="', rPrimary, '" stroke-width="2" rx="4"/>',
            '<rect x="-45" y="-25" width="90" height="80" fill="#616161"/>',
            // Smokestacks
            '<rect x="-40" y="-70" width="15" height="45" fill="#757575" stroke="', rSecondary, '" stroke-width="1"/>',
            '<rect x="25" y="-70" width="15" height="45" fill="#757575" stroke="', rSecondary, '" stroke-width="1"/>',
            // Smoke particles
            '<circle cx="-32" cy="-80" r="8" fill="#9E9E9E" opacity="0.6"', smokeClass, '/>',
            '<circle cx="33" cy="-85" r="6" fill="#9E9E9E" opacity="0.5"', smokeClass, '/>',
            // Gears
            '<g transform="translate(-20, 10)">',
            '<circle cx="0" cy="0" r="20" fill="', rSecondary, '" stroke="', rPrimary, '" stroke-width="2"',
            rarity == Rarity.Legendary ? ' class="gear"' : '', '/>',
            '<circle cx="0" cy="0" r="8" fill="#424242"/>',
            '</g>',
            '<g transform="translate(25, 20)">',
            '<circle cx="0" cy="0" r="15" fill="', rPrimary, '" opacity="0.8"',
            rarity == Rarity.Legendary ? ' class="gear"' : '', '/>',
            '<circle cx="0" cy="0" r="6" fill="#424242"/>',
            '</g>',
            // Pipes
            '<path d="M-50,30 L-65,30 L-65,50 L-50,50" fill="none" stroke="', rSecondary, '" stroke-width="4"/>',
            '<path d="M50,20 L65,20 L65,45 L50,45" fill="none" stroke="', rSecondary, '" stroke-width="4"/>',
            // Indicator lights
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
            // Main dome
            '<ellipse cx="0" cy="10" rx="55" ry="40" fill="#1A237E" stroke="', rPrimary, '" stroke-width="2"/>',
            '<ellipse cx="0" cy="10" rx="50" ry="35" fill="#283593"/>',
            // Glass dome top
            '<path d="M-45,-15 Q0,-60 45,-15" fill="#4FC3F7" opacity="0.4" stroke="', rSecondary, '" stroke-width="1"/>',
            // Antenna/Satellite dish
            '<line x1="0" y1="-50" x2="0" y2="-70" stroke="', rPrimary, '" stroke-width="3"/>',
            '<circle cx="0" cy="-75" r="8" fill="', rSecondary, '"', animClass, '/>',
            '<ellipse cx="0" cy="-65" rx="15" ry="5" fill="none" stroke="', rPrimary, '" stroke-width="2"/>',
            // Test tubes/beakers
            '<rect x="-35" y="20" width="8" height="25" fill="#4CAF50" opacity="0.7" rx="2"', animClass, '/>',
            '<rect x="-20" y="25" width="8" height="20" fill="#2196F3" opacity="0.7" rx="2"', animClass, '/>',
            '<rect x="12" y="22" width="8" height="23" fill="#9C27B0" opacity="0.7" rx="2"', animClass, '/>',
            '<rect x="27" y="28" width="8" height="17" fill="#FF9800" opacity="0.7" rx="2"', animClass, '/>',
            // DNA helix decoration
            '<path d="M-55,0 Q-45,-15 -55,-30 Q-45,-45 -55,-60" stroke="', rSecondary, '" stroke-width="2" fill="none" opacity="0.6"/>',
            '<path d="M55,0 Q45,-15 55,-30 Q45,-45 55,-60" stroke="', rSecondary, '" stroke-width="2" fill="none" opacity="0.6"/>',
            // Floating particles
            '<circle cx="-10" cy="-30" r="3" fill="', rPrimary, '"', animClass, '/>',
            '<circle cx="15" cy="-25" r="2" fill="', rSecondary, '"', animClass, '/>',
            '<circle cx="5" cy="-40" r="4" fill="', rPrimary, '"', animClass, '/>',
            '</g>'
        );
    }

    function _generateDefenseTowerIcon(Rarity rarity, string memory rPrimary, string memory rSecondary)
        private pure returns (string memory)
    {
        string memory animClass = rarity >= Rarity.Epic ? ' class="pulse"' : '';

        return string.concat(
            '<g transform="translate(150, 170)">',
            // Tower base
            '<polygon points="-40,60 -50,60 -35,-20 35,-20 50,60 40,60" fill="#37474F" stroke="', rPrimary, '" stroke-width="2"/>',
            '<polygon points="-35,55 -45,55 -30,-15 30,-15 45,55 35,55" fill="#455A64"/>',
            // Turret
            '<rect x="-30" y="-60" width="60" height="45" fill="#546E7A" stroke="', rSecondary, '" stroke-width="2" rx="4"/>',
            '<rect x="-25" y="-55" width="50" height="35" fill="#607D8B"/>',
            // Cannon
            '<rect x="-8" y="-45" width="16" height="50" fill="#263238" stroke="', rPrimary, '" stroke-width="1"/>',
            '<circle cx="0" cy="-45" r="12" fill="#37474F" stroke="', rPrimary, '" stroke-width="2"/>',
            // Shield emblem
            '<path d="M0,-30 L15,-20 L15,0 L0,10 L-15,0 L-15,-20 Z" fill="', rSecondary, '" opacity="0.8"/>',
            '<path d="M0,-25 L10,-17 L10,-3 L0,5 L-10,-3 L-10,-17 Z" fill="', rPrimary, '"/>',
            // Warning lights
            '<circle cx="-20" cy="20" r="5" fill="#F44336"', animClass, '/>',
            '<circle cx="20" cy="20" r="5" fill="#F44336"', animClass, '/>',
            // Radar dish
            '<ellipse cx="35" cy="-50" rx="12" ry="8" fill="none" stroke="', rSecondary, '" stroke-width="2"',
            rarity == Rarity.Legendary ? ' class="rotate"' : '', '/>',
            '<line x1="35" y1="-50" x2="35" y2="-35" stroke="', rSecondary, '" stroke-width="2"/>',
            '</g>'
        );
    }

    function _generateTradeHubIcon(Rarity rarity, string memory rPrimary, string memory rSecondary)
        private pure returns (string memory)
    {
        string memory animClass = rarity >= Rarity.Epic ? ' class="pulse"' : '';

        return string.concat(
            '<g transform="translate(150, 170)">',
            // Main building
            '<rect x="-55" y="-30" width="110" height="80" fill="#F57C00" stroke="', rPrimary, '" stroke-width="2" rx="6"/>',
            '<rect x="-50" y="-25" width="100" height="70" fill="#FF9800"/>',
            // Awning
            '<polygon points="-60,-30 0,-55 60,-30" fill="#E65100" stroke="', rPrimary, '" stroke-width="2"/>',
            // Trade symbol (scales)
            '<line x1="0" y1="-45" x2="0" y2="-15" stroke="', rSecondary, '" stroke-width="3"/>',
            '<line x1="-25" y1="-25" x2="25" y2="-25" stroke="', rSecondary, '" stroke-width="3"/>',
            '<polygon points="-30,-20 -20,-20 -25,-5" fill="', rPrimary, '"', animClass, '/>',
            '<polygon points="20,-20 30,-20 25,-5" fill="', rPrimary, '"', animClass, '/>',
            // Windows/shop fronts
            '<rect x="-45" y="5" width="35" height="35" fill="#FFCC80" stroke="', rSecondary, '" stroke-width="1"/>',
            '<rect x="10" y="5" width="35" height="35" fill="#FFCC80" stroke="', rSecondary, '" stroke-width="1"/>',
            // Coins decoration
            '<circle cx="-55" cy="55" r="8" fill="', rPrimary, '"', animClass, '/>',
            '<circle cx="-40" cy="60" r="6" fill="', rSecondary, '"', animClass, '/>',
            '<circle cx="55" cy="55" r="8" fill="', rPrimary, '"', animClass, '/>',
            '<circle cx="40" cy="60" r="6" fill="', rSecondary, '"', animClass, '/>',
            // Banner
            '<rect x="-20" y="-48" width="40" height="12" fill="', rPrimary, '" rx="2"/>',
            '<text x="0" y="-39" text-anchor="middle" fill="#000" font-size="8" font-weight="bold">TRADE</text>',
            '</g>'
        );
    }

    function _generateEnergyPlantIcon(Rarity rarity, string memory rPrimary, string memory rSecondary)
        private pure returns (string memory)
    {
        string memory animClass = rarity >= Rarity.Epic ? ' class="pulse"' : '';

        return string.concat(
            '<g transform="translate(150, 170)">',
            // Main reactor core
            '<circle cx="0" cy="0" r="45" fill="#0D47A1" stroke="', rPrimary, '" stroke-width="3"/>',
            '<circle cx="0" cy="0" r="40" fill="#1565C0"/>',
            '<circle cx="0" cy="0" r="30" fill="#1976D2"/>',
            // Energy core
            '<circle cx="0" cy="0" r="20" fill="', rSecondary, '" opacity="0.9"', animClass, '/>',
            '<circle cx="0" cy="0" r="12" fill="', rPrimary, '"', animClass, '/>',
            '<circle cx="0" cy="0" r="5" fill="#FFF" opacity="0.8"/>',
            // Energy rings
            '<ellipse cx="0" cy="0" rx="55" ry="20" fill="none" stroke="', rPrimary, '" stroke-width="2" opacity="0.5"',
            rarity == Rarity.Legendary ? ' class="rotate"' : '', '/>',
            '<ellipse cx="0" cy="0" rx="60" ry="25" fill="none" stroke="', rSecondary, '" stroke-width="1" opacity="0.3"',
            rarity == Rarity.Legendary ? ' class="rotate"' : '', '/>',
            // Lightning bolts
            '<path d="M-50,-40 L-40,-30 L-50,-20" stroke="', rPrimary, '" stroke-width="3" fill="none"', animClass, '/>',
            '<path d="M50,-40 L40,-30 L50,-20" stroke="', rPrimary, '" stroke-width="3" fill="none"', animClass, '/>',
            // Power conduits
            '<rect x="-65" y="-8" width="20" height="16" fill="#0D47A1" stroke="', rSecondary, '" stroke-width="1"/>',
            '<rect x="45" y="-8" width="20" height="16" fill="#0D47A1" stroke="', rSecondary, '" stroke-width="1"/>',
            // Energy sparks
            '<circle cx="-30" cy="-35" r="4" fill="', rPrimary, '"', animClass, '/>',
            '<circle cx="30" cy="-35" r="4" fill="', rPrimary, '"', animClass, '/>',
            '<circle cx="-30" cy="35" r="4" fill="', rSecondary, '"', animClass, '/>',
            '<circle cx="30" cy="35" r="4" fill="', rSecondary, '"', animClass, '/>',
            '</g>'
        );
    }

    function _generateBioLabIcon(Rarity rarity, string memory rPrimary, string memory rSecondary)
        private pure returns (string memory)
    {
        string memory animClass = rarity >= Rarity.Epic ? ' class="pulse"' : '';

        return string.concat(
            '<g transform="translate(150, 170)">',
            // Bio dome
            '<path d="M-50,40 Q-55,-20 0,-50 Q55,-20 50,40 Z" fill="#1B5E20" stroke="', rPrimary, '" stroke-width="2"/>',
            '<path d="M-45,35 Q-50,-15 0,-45 Q50,-15 45,35 Z" fill="#2E7D32"/>',
            // Glass panels
            '<path d="M-35,30 Q-38,-10 0,-35 Q38,-10 35,30 Z" fill="#4CAF50" opacity="0.3"/>',
            // Plants inside
            '<path d="M-20,40 Q-25,20 -15,0 Q-10,-15 -5,-25" stroke="#8BC34A" stroke-width="3" fill="none"/>',
            '<path d="M0,40 Q5,15 0,-10 Q-5,-25 0,-35" stroke="#4CAF50" stroke-width="4" fill="none"/>',
            '<path d="M20,40 Q25,20 15,0 Q10,-15 5,-25" stroke="#8BC34A" stroke-width="3" fill="none"/>',
            // Leaves
            '<ellipse cx="-15" cy="-20" rx="8" ry="5" fill="#8BC34A" transform="rotate(-30 -15 -20)"', animClass, '/>',
            '<ellipse cx="0" cy="-30" rx="10" ry="6" fill="#4CAF50"', animClass, '/>',
            '<ellipse cx="15" cy="-20" rx="8" ry="5" fill="#8BC34A" transform="rotate(30 15 -20)"', animClass, '/>',
            // Bio containers
            '<rect x="-55" y="45" width="20" height="25" fill="#81C784" stroke="', rSecondary, '" stroke-width="1" rx="3"/>',
            '<rect x="35" y="45" width="20" height="25" fill="#81C784" stroke="', rSecondary, '" stroke-width="1" rx="3"/>',
            // DNA symbol
            '<path d="M-60,-30 Q-50,-20 -60,-10 Q-50,0 -60,10" stroke="', rPrimary, '" stroke-width="2" fill="none"/>',
            '<path d="M60,-30 Q50,-20 60,-10 Q50,0 60,10" stroke="', rPrimary, '" stroke-width="2" fill="none"/>',
            // Floating spores
            '<circle cx="-25" cy="-40" r="3" fill="', rSecondary, '"', animClass, '/>',
            '<circle cx="25" cy="-45" r="2" fill="', rPrimary, '"', animClass, '/>',
            '<circle cx="0" cy="-55" r="4" fill="', rSecondary, '"', animClass, '/>',
            '</g>'
        );
    }

    function _generateMiningOutpostIcon(Rarity rarity, string memory rPrimary, string memory rSecondary)
        private pure returns (string memory)
    {
        string memory animClass = rarity >= Rarity.Epic ? ' class="pulse"' : '';

        return string.concat(
            '<g transform="translate(150, 170)">',
            // Mine entrance
            '<path d="M-50,50 L-60,50 L-50,-20 L50,-20 L60,50 L50,50 L40,0 L-40,0 Z" fill="#5D4037" stroke="', rPrimary, '" stroke-width="2"/>',
            '<path d="M-45,45 L-55,45 L-45,-15 L45,-15 L55,45 L45,45 L35,-5 L-35,-5 Z" fill="#6D4C41"/>',
            // Dark tunnel
            '<rect x="-30" y="0" width="60" height="50" fill="#1A1A1A"/>',
            // Support beams
            '<line x1="-35" y1="-5" x2="-35" y2="50" stroke="#8D6E63" stroke-width="6"/>',
            '<line x1="35" y1="-5" x2="35" y2="50" stroke="#8D6E63" stroke-width="6"/>',
            '<line x1="-40" y1="-5" x2="40" y2="-5" stroke="#8D6E63" stroke-width="8"/>',
            // Mining cart
            '<rect x="-15" y="35" width="30" height="18" fill="#757575" stroke="', rSecondary, '" stroke-width="1"/>',
            '<circle cx="-8" cy="55" r="5" fill="#424242" stroke="', rPrimary, '" stroke-width="1"/>',
            '<circle cx="8" cy="55" r="5" fill="#424242" stroke="', rPrimary, '" stroke-width="1"/>',
            // Ore in cart
            '<polygon points="-10,35 0,28 10,35" fill="', rPrimary, '"', animClass, '/>',
            '<polygon points="-5,33 5,33 0,25" fill="', rSecondary, '"', animClass, '/>',
            // Pickaxe
            '<line x1="-55" y1="-30" x2="-40" y2="-10" stroke="#8D6E63" stroke-width="4"/>',
            '<polygon points="-60,-35 -50,-35 -55,-25" fill="#9E9E9E"/>',
            // Lanterns
            '<rect x="-50" y="-35" width="8" height="12" fill="', rPrimary, '" opacity="0.8"', animClass, '/>',
            '<rect x="42" y="-35" width="8" height="12" fill="', rPrimary, '" opacity="0.8"', animClass, '/>',
            // Rock deposits
            '<polygon points="50,20 60,35 55,50 45,45 45,30" fill="#8D6E63"/>',
            '<circle cx="52" cy="35" r="4" fill="', rSecondary, '"', animClass, '/>',
            '</g>'
        );
    }

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

    function _generateCyborgChickenWorkers(BuildingTraits memory traits, string memory rPrimary)
        private pure returns (string memory)
    {
        (string memory c1, string memory c2, ) = _splitColors(_getTypeColorScheme(traits.buildingType));
        string memory chickenBorder = traits.rarity >= Rarity.Epic ? rPrimary : c1;

        return string.concat(
            // Left worker chicken
            '<g transform="translate(45, 355) scale(0.75)">',
            '<ellipse cx="0" cy="0" rx="12" ry="14" fill="', c2, '" stroke="', chickenBorder, '" stroke-width="1"/>',
            '<circle cx="0" cy="-16" r="9" fill="', c1, '" stroke="', chickenBorder, '" stroke-width="1"/>',
            '<circle cx="-3" cy="-17" r="2" fill="#000"/>',
            '<circle cx="3" cy="-17" r="2" fill="#000"/>',
            '<polygon points="7,-16 10,-13 7,-10" fill="#FF9800"/>',
            // Hard hat
            '<path d="M-8,-24 Q0,-30 8,-24" fill="', rPrimary, '"/>',
            '<rect x="-10" y="-24" width="20" height="4" fill="', rPrimary, '" rx="1"/>',
            '</g>',
            // Right worker chicken
            '<g transform="translate(255, 355) scale(0.75)">',
            '<ellipse cx="0" cy="0" rx="12" ry="14" fill="', c1, '" stroke="', chickenBorder, '" stroke-width="1"/>',
            '<circle cx="0" cy="-16" r="9" fill="', c2, '" stroke="', chickenBorder, '" stroke-width="1"/>',
            '<circle cx="-3" cy="-17" r="2" fill="#000"/>',
            '<circle cx="3" cy="-17" r="2" fill="#000"/>',
            '<polygon points="-7,-16 -10,-13 -7,-10" fill="#FF9800"/>',
            // Wrench tool
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

    function _generateDurabilityStars(uint8 durabilityLevel, string memory color)
        private pure returns (string memory)
    {
        string memory stars = '';
        uint8 level = durabilityLevel > 5 ? 5 : durabilityLevel;

        for (uint8 i = 0; i < level; i++) {
            stars = string.concat(
                stars,
                '<text x="', uint256(70 + i * 18).toString(),
                '" y="55" fill="', color, '" font-size="14">', unicode'★', '</text>'
            );
        }

        for (uint8 i = level; i < 5; i++) {
            stars = string.concat(
                stars,
                '<text x="', uint256(70 + i * 18).toString(),
                '" y="55" fill="#444" font-size="14">', unicode'☆', '</text>'
            );
        }

        return string.concat(
            '<text x="25" y="55" fill="#888" font-size="10">DURABILITY</text>',
            stars
        );
    }

    function _generateStatsBadges(BuildingTraits memory traits, string memory rPrimary, string memory)
        private pure returns (string memory)
    {
        return string.concat(
            // Efficiency badge
            '<g transform="translate(185, 25)">',
            '<rect x="0" y="0" width="95" height="24" fill="rgba(10,10,20,0.6)" rx="12" stroke="', rPrimary, '" stroke-width="1" stroke-opacity="0.7"/>',
            '<text x="48" y="16" text-anchor="middle" fill="', rPrimary, '" font-size="10" font-weight="bold">',
            uint256(traits.efficiencyBonus).toString(), '% EFF</text>',
            '</g>',
            // Capacity badge
            traits.capacityBonus > 0 ? string.concat(
                '<g transform="translate(185, 55)">',
                '<rect x="0" y="0" width="95" height="20" fill="rgba(10,10,20,0.5)" rx="10" stroke="', rPrimary, '" stroke-width="1" stroke-opacity="0.5"/>',
                '<text x="48" y="14" text-anchor="middle" fill="', rPrimary, '" font-size="9">+',
                uint256(traits.capacityBonus).toString(), '% CAP</text>',
                '</g>'
            ) : ''
        );
    }

    function _generateTypeBadge(BuildingType bType, string memory typeColors)
        private pure returns (string memory)
    {
        (string memory c1, , ) = _splitColors(typeColors);
        string memory typeName = _getTypeName(bType);

        return string.concat(
            '<g transform="translate(150, 285)">',
            '<rect x="-60" y="-12" width="120" height="24" rx="12" fill="rgba(0,0,0,0.7)" stroke="', c1, '" stroke-width="1"/>',
            '<text x="0" y="5" text-anchor="middle" fill="', c1, '" font-size="10" font-weight="bold">', typeName, '</text>',
            '</g>',
            '<text x="150" y="388" text-anchor="middle" fill="#444" font-size="9" letter-spacing="8" font-weight="300">HENOMORPHS</text>'
        );
    }

    function _generateBlueprintOverlay(string memory rPrimary)
        private pure returns (string memory)
    {
        return string.concat(
            '<rect x="0" y="0" width="300" height="400" fill="rgba(0,50,100,0.3)" rx="12"/>',
            '<text x="150" y="320" text-anchor="middle" fill="', rPrimary, '" font-size="16" font-weight="bold">BLUEPRINT</text>',
            '<text x="150" y="340" text-anchor="middle" fill="#AAA" font-size="10">Requires construction</text>'
        );
    }

    function _getTypeName(BuildingType bType) private pure returns (string memory) {
        if (bType == BuildingType.Warehouse) return "WAREHOUSE";
        if (bType == BuildingType.Refinery) return "REFINERY";
        if (bType == BuildingType.Laboratory) return "LABORATORY";
        if (bType == BuildingType.DefenseTower) return "DEFENSE TOWER";
        if (bType == BuildingType.TradeHub) return "TRADE HUB";
        if (bType == BuildingType.EnergyPlant) return "ENERGY PLANT";
        if (bType == BuildingType.BioLab) return "BIO LAB";
        return "MINING OUTPOST";
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
