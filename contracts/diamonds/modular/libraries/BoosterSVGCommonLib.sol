// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/utils/Strings.sol";

/**
 * @title BoosterSVGCommonLib
 * @notice Common SVG elements for Booster Card generation
 * @dev Extracted from BoosterSVGLib for contract size optimization.
 *      Uses uint8 for rarity to avoid circular dependency with BoosterSVGLib enums.
 *      Rarity mapping: 0=Common, 1=Uncommon, 2=Rare, 3=Epic, 4=Legendary
 * @author rutilicus.eth (ArchXS)
 * @custom:version 1.0.0
 */
library BoosterSVGCommonLib {
    using Strings for uint256;

    struct SVGParams {
        uint256 tokenId;
        string typeColors;
        string rPrimary;
        string rSecondary;
        string rGlow;
        uint8 rarity;
        uint8 level;
        uint16 primaryBonusBps;
        uint16 secondaryBonusBps;
        bool isBlueprint;
        string icon;
        string subTypeName;
        string systemName;
        string systemIcon;
        string primaryLabel;
        string secondaryLabel;
    }

    function assembleSVG(SVGParams memory p) internal pure returns (string memory) {
        string memory part1 = string.concat(
            '<svg viewBox="0 0 300 400" xmlns="http://www.w3.org/2000/svg">',
            '<defs>', _generateDefs(p.typeColors, p.rPrimary, p.rSecondary, p.rGlow, p.rarity, p.tokenId), '</defs>',
            _generateBackground(p.typeColors, p.tokenId),
            _generateRarityFrame(p.rarity, p.rPrimary, p.rGlow, p.tokenId),
            _generateGrid(p.typeColors, p.rarity, p.rPrimary),
            p.icon
        );

        string memory part2 = string.concat(
            _generateParticles(p.rarity, p.rPrimary),
            _generateCyborgChickenWorkers(p.typeColors, p.rarity, p.rPrimary),
            _generateRaritySymbol(p.rarity, p.rPrimary),
            _generateLevelStars(p.level, p.rPrimary)
        );

        string memory part3 = string.concat(
            _generateStatsBadges(p.primaryBonusBps, p.secondaryBonusBps, p.rPrimary, p.primaryLabel, p.secondaryLabel),
            _generateSystemBadge(p.typeColors, p.subTypeName, p.systemName, p.systemIcon),
            p.isBlueprint ? _generateBlueprintOverlay(p.rPrimary) : '',
            '</svg>'
        );

        return string.concat(part1, part2, part3);
    }

    function getRarityColors(uint8 rarity)
        internal pure returns (string memory primary, string memory secondary, string memory glow)
    {
        if (rarity == 4) return ("#FFD700", "#FFED4E", "#FFAA00"); // Legendary
        if (rarity == 3) return ("#9B59B6", "#C39BD3", "#8E44AD"); // Epic
        if (rarity == 2) return ("#3498DB", "#5DADE2", "#2980B9"); // Rare
        if (rarity == 1) return ("#2ECC71", "#58D68D", "#27AE60"); // Uncommon
        return ("#95A5A6", "#BDC3C7", "#7F8C8D"); // Common
    }

    // ============ SVG GENERATION ============

    function _generateDefs(
        string memory typeColors,
        string memory rPrimary,
        string memory rSecondary,
        string memory rGlow,
        uint8 rarity,
        uint256 tokenId
    ) private pure returns (string memory) {
        (string memory c1, string memory c2, ) = splitColors(typeColors);
        string memory id = tokenId.toString();

        string memory gradients = string.concat(
            '<radialGradient id="bg-', id, '" cx="50%" cy="30%">',
            '<stop offset="0%" stop-color="', c1, '" stop-opacity="0.4"/>',
            '<stop offset="100%" stop-color="', c2, '" stop-opacity="0.15"/>',
            '</radialGradient>',
            '<linearGradient id="frame-', id, '" x1="0%" y1="0%" x2="100%" y2="100%">',
            '<stop offset="0%" stop-color="', rPrimary, '"/>',
            '<stop offset="50%" stop-color="', rSecondary, '"/>',
            '<stop offset="100%" stop-color="', rGlow, '"/>',
            '</linearGradient>'
        );

        string memory filter = string.concat(
            '<filter id="glow-', id, '">',
            '<feGaussianBlur stdDeviation="', rarity == 4 ? "5" : rarity == 3 ? "4" : "3", '" result="blur"/>',
            '<feMerge><feMergeNode in="blur"/><feMergeNode in="SourceGraphic"/></feMerge>',
            '</filter>'
        );

        return string.concat(gradients, filter, _generateAnimationStyles(rarity));
    }

    function _generateAnimationStyles(uint8 rarity) private pure returns (string memory) {
        if (rarity == 4) { // Legendary
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
        if (rarity == 3) { // Epic
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
        uint8 rarity,
        string memory rPrimary,
        string memory rGlow,
        uint256 tokenId
    ) private pure returns (string memory) {
        string memory id = tokenId.toString();
        uint8 strokeWidth = rarity == 4 ? 4 : rarity == 3 ? 3 : rarity == 2 ? 2 : 1;

        string memory frame = string.concat(
            '<rect x="5" y="5" width="290" height="390" rx="10" fill="none" ',
            'stroke="url(#frame-', id, ')" stroke-width="', Strings.toString(uint256(strokeWidth)), '"',
            rarity == 4 ? ' filter="url(#glow-' : '',
            rarity == 4 ? string.concat(id, ')"') : '',
            '/>'
        );

        if (rarity >= 3) { // Epic or Legendary
            frame = string.concat(
                frame,
                '<rect x="8" y="8" width="284" height="384" rx="8" fill="none" ',
                'stroke="', rGlow, '" stroke-width="1" opacity="0.5"/>'
            );
        }

        if (rarity == 4) { // Legendary corner decorations
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

    function _generateGrid(string memory typeColors, uint8 rarity, string memory rPrimary)
        private pure returns (string memory)
    {
        (string memory c1, , ) = splitColors(typeColors);
        string memory gridColor = rarity >= 3 ? rPrimary : c1;

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

    function _generateParticles(uint8 rarity, string memory rPrimary)
        private pure returns (string memory)
    {
        if (rarity < 2) return ''; // Below Rare

        uint8 count = rarity == 4 ? 8 : rarity == 3 ? 5 : 3;
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

    function _generateCyborgChickenWorkers(string memory typeColors, uint8 rarity, string memory rPrimary)
        private pure returns (string memory)
    {
        (string memory c1, string memory c2, ) = splitColors(typeColors);
        string memory chickenBorder = rarity >= 3 ? rPrimary : c1;

        string memory chicken1 = string.concat(
            '<g transform="translate(45, 355) scale(0.75)">',
            '<ellipse cx="0" cy="0" rx="12" ry="14" fill="', c2, '" stroke="', chickenBorder, '" stroke-width="1"/>',
            '<circle cx="0" cy="-16" r="9" fill="', c1, '" stroke="', chickenBorder, '" stroke-width="1"/>',
            '<circle cx="-3" cy="-17" r="2" fill="#000"/>',
            '<circle cx="3" cy="-17" r="2" fill="#000"/>',
            '<polygon points="7,-16 10,-13 7,-10" fill="#FF9800"/>',
            '<path d="M-8,-24 Q0,-30 8,-24" fill="', rPrimary, '"/>',
            '<rect x="-10" y="-24" width="20" height="4" fill="', rPrimary, '" rx="1"/>',
            '</g>'
        );

        string memory chicken2 = string.concat(
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

        return string.concat(chicken1, chicken2);
    }

    function _generateRaritySymbol(uint8 rarity, string memory color)
        private pure returns (string memory)
    {
        string memory symbol;

        if (rarity == 4) symbol = unicode"⚙";
        else if (rarity == 3) symbol = unicode"★";
        else if (rarity == 2) symbol = unicode"◆";
        else if (rarity == 1) symbol = unicode"▲";
        else symbol = unicode"●";

        return string.concat(
            '<text x="25" y="35" text-anchor="middle" fill="', color,
            '" font-size="22" font-weight="900"',
            rarity == 4 ? ' class="shimmer"' : '',
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
                '<text x="', uint256(70 + uint256(i) * 18).toString(),
                '" y="55" fill="', color, '" font-size="14">', unicode'★', '</text>'
            );
        }

        for (uint8 i = lvl; i < 5; i++) {
            stars = string.concat(
                stars,
                '<text x="', uint256(70 + uint256(i) * 18).toString(),
                '" y="55" fill="#444" font-size="14">', unicode'☆', '</text>'
            );
        }

        return string.concat(
            '<text x="25" y="55" fill="#888" font-size="10">LEVEL</text>',
            stars
        );
    }

    function _generateStatsBadges(
        uint16 primaryBonusBps,
        uint16 secondaryBonusBps,
        string memory rPrimary,
        string memory primaryLabel,
        string memory secondaryLabel
    ) private pure returns (string memory) {
        return string.concat(
            '<g transform="translate(185, 25)">',
            '<rect x="0" y="0" width="95" height="24" fill="rgba(10,10,20,0.6)" rx="12" stroke="', rPrimary, '" stroke-width="1" stroke-opacity="0.7"/>',
            '<text x="48" y="16" text-anchor="middle" fill="', rPrimary, '" font-size="10" font-weight="bold">',
            _formatBps(primaryBonusBps), ' ', primaryLabel, '</text>',
            '</g>',
            secondaryBonusBps > 0 ? string.concat(
                '<g transform="translate(185, 55)">',
                '<rect x="0" y="0" width="95" height="20" fill="rgba(10,10,20,0.5)" rx="10" stroke="', rPrimary, '" stroke-width="1" stroke-opacity="0.5"/>',
                '<text x="48" y="14" text-anchor="middle" fill="', rPrimary, '" font-size="9">+',
                _formatBps(secondaryBonusBps), ' ', secondaryLabel, '</text>',
                '</g>'
            ) : ''
        );
    }

    function _generateSystemBadge(
        string memory typeColors,
        string memory typeName,
        string memory systemName,
        string memory systemIcon
    ) private pure returns (string memory) {
        (string memory c1, , ) = splitColors(typeColors);

        return string.concat(
            '<g transform="translate(150, 285)">',
            '<rect x="-60" y="-12" width="120" height="24" rx="12" fill="rgba(0,0,0,0.7)" stroke="', c1, '" stroke-width="1"/>',
            '<text x="0" y="5" text-anchor="middle" fill="', c1, '" font-size="10" font-weight="bold">', typeName, '</text>',
            '</g>',
            '<g transform="translate(25, 310)">',
            '<rect x="0" y="0" width="80" height="24" rx="12" fill="rgba(0,0,0,0.6)" stroke="', c1, '" stroke-width="1"/>',
            '<text x="15" y="17" fill="', c1, '" font-size="14">', systemIcon, '</text>',
            '<text x="35" y="16" fill="', c1, '" font-size="8" font-weight="bold">', systemName, '</text>',
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
            '<text x="150" y="340" text-anchor="middle" fill="#AAA" font-size="10">Requires activation</text>'
        );
    }

    // ============ UTILITY FUNCTIONS ============

    function _formatBps(uint16 bps) private pure returns (string memory) {
        uint256 pct = uint256(bps) / 100;
        return string.concat(pct.toString(), "%");
    }

    function splitColors(string memory colors)
        internal pure returns (string memory c1, string memory c2, string memory c3)
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
}
