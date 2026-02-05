// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/utils/Base64.sol";
import {BoosterSVGLib} from "../../../diamonds/modular/libraries/BoosterSVGLib.sol";
import {BoosterSVGCommonLib} from "../../../diamonds/modular/libraries/BoosterSVGCommonLib.sol";
import {IBoosterDescriptor} from "./../interfaces/IBoosterDescriptor.sol";
import {IBoosterSystemDescriptor} from "./../interfaces/IBoosterSystemDescriptor.sol";

/**
 * @title BoosterDescriptor
 * @notice Router contract for on-chain metadata and SVG generation of Booster Cards
 * @dev Delegates icon generation to per-system descriptors, uses BoosterSVGCommonLib for
 *      common SVG elements. This architecture keeps each contract under the EIP-3860
 *      initcode size limit (49,152 bytes).
 * @author rutilicus.eth (ArchXS)
 * @custom:version 2.0.0
 */
contract BoosterDescriptor is IBoosterDescriptor, Ownable {
    using Strings for uint256;
    using Strings for uint8;
    using Strings for uint16;

    // Per-system descriptor contracts
    mapping(uint8 => IBoosterSystemDescriptor) public systemDescriptors;

    // Collection metadata
    string public collectionName;
    string public collectionDescription;
    string public collectionImageUrl;
    string public collectionExternalUrl;

    event CollectionMetadataUpdated(
        string name,
        string description,
        string imageUrl,
        string externalUrl
    );

    event SystemDescriptorUpdated(uint8 indexed system, address descriptor);

    constructor(
        string memory _name,
        string memory _description,
        string memory _imageUrl,
        string memory _externalUrl,
        address _owner,
        IBoosterSystemDescriptor _buildingDesc,
        IBoosterSystemDescriptor _evolutionDesc,
        IBoosterSystemDescriptor _ventureDesc,
        IBoosterSystemDescriptor _universalDesc
    ) Ownable(_owner) {
        collectionName = _name;
        collectionDescription = _description;
        collectionImageUrl = _imageUrl;
        collectionExternalUrl = _externalUrl;

        systemDescriptors[0] = _buildingDesc;   // Buildings
        systemDescriptors[1] = _evolutionDesc;   // Evolution
        systemDescriptors[2] = _ventureDesc;     // Venture
        systemDescriptors[3] = _universalDesc;   // Universal
    }

    /// @inheritdoc IBoosterDescriptor
    function tokenURI(BoosterMetadata memory metadata) external view override returns (string memory) {
        string memory svg = generateSVG(metadata);
        string memory attributes = _generateAttributes(metadata);
        string memory name = _generateName(metadata);
        string memory description = _generateDescription(metadata);

        string memory json = string.concat(
            '{"name":"', name,
            '","description":"', description,
            '","image":"data:image/svg+xml;base64,', Base64.encode(bytes(svg)),
            '","external_url":"', collectionExternalUrl,
            '","attributes":', attributes,
            '}'
        );

        return string.concat(
            "data:application/json;base64,",
            Base64.encode(bytes(json))
        );
    }

    /// @inheritdoc IBoosterDescriptor
    function generateSVG(BoosterMetadata memory metadata) public view override returns (string memory) {
        uint8 systemId = uint8(metadata.targetSystem);
        IBoosterSystemDescriptor systemDesc = systemDescriptors[systemId];
        require(address(systemDesc) != address(0), "No descriptor for system");

        // Get system-specific info
        (
            string memory typeColors,
            string memory subTypeName,
            string memory systemName,
            string memory systemIcon,
            string memory primaryLabel,
            string memory secondaryLabel
        ) = systemDesc.getSystemInfo(metadata.subType);

        // Get rarity colors
        (string memory rPrimary, string memory rSecondary, string memory rGlow) =
            BoosterSVGCommonLib.getRarityColors(uint8(metadata.rarity));

        // Get system-specific icon
        string memory icon = systemDesc.generateIcon(
            metadata.subType,
            uint8(metadata.rarity),
            rPrimary,
            rSecondary
        );

        // Assemble full SVG using common library
        return BoosterSVGCommonLib.assembleSVG(
            BoosterSVGCommonLib.SVGParams({
                tokenId: metadata.tokenId,
                typeColors: typeColors,
                rPrimary: rPrimary,
                rSecondary: rSecondary,
                rGlow: rGlow,
                rarity: uint8(metadata.rarity),
                level: metadata.level,
                primaryBonusBps: metadata.primaryBonusBps,
                secondaryBonusBps: metadata.secondaryBonusBps,
                isBlueprint: metadata.isBlueprint,
                icon: icon,
                subTypeName: subTypeName,
                systemName: systemName,
                systemIcon: systemIcon,
                primaryLabel: primaryLabel,
                secondaryLabel: secondaryLabel
            })
        );
    }

    /// @inheritdoc IBoosterDescriptor
    function contractURI() external view override returns (string memory) {
        string memory json = string.concat(
            '{"name":"', collectionName,
            '","description":"', collectionDescription,
            '","image":"', collectionImageUrl,
            '","external_link":"', collectionExternalUrl, '"}'
        );

        return string.concat(
            "data:application/json;base64,",
            Base64.encode(bytes(json))
        );
    }

    // ============ ADMIN FUNCTIONS ============

    function setSystemDescriptor(uint8 system, IBoosterSystemDescriptor desc) external onlyOwner {
        require(system <= 3, "Invalid system");
        require(address(desc) != address(0), "Zero address");
        systemDescriptors[system] = desc;
        emit SystemDescriptorUpdated(system, address(desc));
    }

    function setCollectionMetadata(
        string memory _name,
        string memory _description,
        string memory _imageUrl,
        string memory _externalUrl
    ) external onlyOwner {
        collectionName = _name;
        collectionDescription = _description;
        collectionImageUrl = _imageUrl;
        collectionExternalUrl = _externalUrl;

        emit CollectionMetadataUpdated(_name, _description, _imageUrl, _externalUrl);
    }

    function setCollectionName(string memory _name) external onlyOwner {
        collectionName = _name;
    }

    function setCollectionDescription(string memory _description) external onlyOwner {
        collectionDescription = _description;
    }

    function setCollectionImageUrl(string memory _imageUrl) external onlyOwner {
        collectionImageUrl = _imageUrl;
    }

    function setCollectionExternalUrl(string memory _externalUrl) external onlyOwner {
        collectionExternalUrl = _externalUrl;
    }

    // ============ INTERNAL FUNCTIONS ============

    function _generateName(BoosterMetadata memory metadata) private pure returns (string memory) {
        return string.concat(
            _getSystemName(metadata.targetSystem),
            " ",
            _getSubTypeName(metadata.targetSystem, metadata.subType),
            " #",
            metadata.tokenId.toString()
        );
    }

    function _generateDescription(BoosterMetadata memory metadata) private pure returns (string memory) {
        string memory systemDesc = _getSystemDescription(metadata.targetSystem);
        string memory rarityName = _getRarityName(metadata.rarity);

        return string.concat(
            rarityName,
            " ",
            _getSubTypeName(metadata.targetSystem, metadata.subType),
            " booster card. ",
            systemDesc,
            metadata.isBlueprint ? " (Blueprint - requires activation)" : "",
            metadata.isAttached ? " (Currently attached)" : ""
        );
    }

    function _generateAttributes(BoosterMetadata memory metadata) private pure returns (string memory) {
        return string.concat(
            '[',
            _attr("System", _getSystemName(metadata.targetSystem), true),
            ',', _attr("Type", _getSubTypeName(metadata.targetSystem, metadata.subType), true),
            ',', _attr("Rarity", _getRarityName(metadata.rarity), true),
            ',', _attrNum("Level", metadata.level),
            ',', _attrNum("Primary Bonus", metadata.primaryBonusBps / 100),
            metadata.secondaryBonusBps > 0 ? string.concat(',', _attrNum("Secondary Bonus", metadata.secondaryBonusBps / 100)) : '',
            ',', _attr("Blueprint", metadata.isBlueprint ? "Yes" : "No", true),
            ',', _attr("Attached", metadata.isAttached ? "Yes" : "No", true),
            ']'
        );
    }

    function _attr(string memory trait, string memory value, bool isString) private pure returns (string memory) {
        if (isString) {
            return string.concat('{"trait_type":"', trait, '","value":"', value, '"}');
        }
        return string.concat('{"trait_type":"', trait, '","value":', value, '}');
    }

    function _attrNum(string memory trait, uint256 value) private pure returns (string memory) {
        return string.concat('{"trait_type":"', trait, '","value":', value.toString(), '}');
    }

    function _getSystemName(BoosterSVGLib.TargetSystem system) private pure returns (string memory) {
        if (system == BoosterSVGLib.TargetSystem.Buildings) return "Building";
        if (system == BoosterSVGLib.TargetSystem.Evolution) return "Evolution";
        if (system == BoosterSVGLib.TargetSystem.Venture) return "Venture";
        return "Universal";
    }

    function _getSystemDescription(BoosterSVGLib.TargetSystem system) private pure returns (string memory) {
        if (system == BoosterSVGLib.TargetSystem.Buildings) {
            return "Enhances colony building efficiency and capacity.";
        }
        if (system == BoosterSVGLib.TargetSystem.Evolution) {
            return "Reduces evolution costs and provides tier bonuses.";
        }
        if (system == BoosterSVGLib.TargetSystem.Venture) {
            return "Increases venture success rate and rewards.";
        }
        return "Works with all game systems for universal bonuses.";
    }

    function _getSubTypeName(BoosterSVGLib.TargetSystem system, uint8 subType) private pure returns (string memory) {
        if (system == BoosterSVGLib.TargetSystem.Buildings) {
            if (subType == 0) return "Warehouse";
            if (subType == 1) return "Refinery";
            if (subType == 2) return "Laboratory";
            if (subType == 3) return "Defense Tower";
            if (subType == 4) return "Trade Hub";
            if (subType == 5) return "Energy Plant";
            if (subType == 6) return "Bio Lab";
            return "Mining Outpost";
        }
        if (system == BoosterSVGLib.TargetSystem.Evolution) {
            if (subType == 0) return "Catalyst";
            if (subType == 1) return "Accelerator";
            if (subType == 2) return "Amplifier";
            return "Mutator";
        }
        if (system == BoosterSVGLib.TargetSystem.Venture) {
            if (subType == 0) return "Scout";
            if (subType == 1) return "Harvester";
            if (subType == 2) return "Trader";
            return "Guardian";
        }
        // Universal
        if (subType == 0) return "Booster";
        if (subType == 1) return "Master";
        if (subType == 2) return "Legacy";
        return "Genesis";
    }

    function _getRarityName(BoosterSVGLib.Rarity rarity) private pure returns (string memory) {
        if (rarity == BoosterSVGLib.Rarity.Legendary) return "Legendary";
        if (rarity == BoosterSVGLib.Rarity.Epic) return "Epic";
        if (rarity == BoosterSVGLib.Rarity.Rare) return "Rare";
        if (rarity == BoosterSVGLib.Rarity.Uncommon) return "Uncommon";
        return "Common";
    }
}
