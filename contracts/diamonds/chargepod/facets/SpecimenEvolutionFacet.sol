// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibMeta} from "../../shared/libraries/LibMeta.sol";
import {LibHenomorphsStorage} from "../libraries/LibHenomorphsStorage.sol";
import {LibResourceStorage} from "../libraries/LibResourceStorage.sol";
import {LibProgressionStorage} from "../libraries/LibProgressionStorage.sol";
import {LibColonyWarsStorage} from "../libraries/LibColonyWarsStorage.sol";
import {LibBuildingsStorage} from "../libraries/LibBuildingsStorage.sol";
import {LibFeeCollection} from "../../staking/libraries/LibFeeCollection.sol";
import {SpecimenCollection} from "../../../libraries/HenomorphsModel.sol";
import {AccessControlBase} from "../../common/facets/AccessControlBase.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title SpecimenEvolutionFacet
 * @notice Handles specimen (token) evolution using resources
 * @dev Consumes resources to upgrade token stats and production bonuses
 * @author rutilicus.eth (ArchXS)
 */
contract SpecimenEvolutionFacet is AccessControlBase {
    using SafeERC20 for IERC20;
    using LibProgressionStorage for *;

    // ============================================
    // EVENTS
    // ============================================

    event SpecimenEvolved(
        uint256 indexed collectionId,
        uint256 indexed tokenId,
        address indexed owner,
        uint8 fromLevel,
        uint8 toLevel,
        uint256[4] resourcesConsumed,
        uint256 tokensConsumed
    );

    event EvolutionTierUpdated(
        uint8 indexed tier,
        uint256[4] resourceCosts,
        uint256 tokenCost,
        uint16 statBoostBps,
        uint16 productionBoostBps
    );

    event CollectionEvolutionConfigured(
        uint256 indexed collectionId,
        bool enabled,
        uint16 bonusMultiplierBps,
        uint8 maxLevelOverride
    );

    event EvolutionSystemToggled(bool enabled);
    event SpecimenLockToggled(uint256 indexed collectionId, uint256 indexed tokenId, bool locked);

    // Card system events
    event EvolutionCardAttached(
        uint256 indexed collectionId,
        uint256 indexed tokenId,
        uint256 cardTokenId,
        uint16 collectionIdCard,
        uint8 cardTypeId,
        uint16 bonusBps
    );

    event EvolutionCardDetached(
        uint256 indexed collectionId,
        uint256 indexed tokenId,
        uint256 cardTokenId
    );

    // ============================================
    // ERRORS
    // ============================================

    error EvolutionSystemDisabled();
    error CollectionNotEvolutionEnabled(uint256 collectionId);
    error SpecimenLocked(uint256 collectionId, uint256 tokenId);
    error AlreadyMaxLevel(uint8 currentLevel, uint8 maxLevel);
    error CooldownNotFinished(uint32 remainingSeconds);
    error TierNotEnabled(uint8 tier);
    error InsufficientResources(uint8 resourceType, uint256 required, uint256 available);
    error InsufficientTokenBalance(uint256 required, uint256 available);
    error NotSpecimenOwner(address caller, address owner);
    error InvalidTier(uint8 tier);
    error InvalidCollectionId(uint256 collectionId);

    // Card system errors
    error CardSystemDisabled();
    error CardAlreadyAttached(bytes32 specimenKey);
    error NoCardAttached(bytes32 specimenKey);
    error CardNotCompatible(uint8 cardTypeId);
    error NotCardOwner(uint256 tokenId);
    error CardInCooldown(uint32 remainingSeconds);
    error CardLocked();
    error InvalidCardCollection(uint16 collectionId);

    // ============================================
    // MAIN EVOLUTION FUNCTION
    // ============================================

    /**
     * @notice Evolve a specimen to the next level
     * @param collectionId Collection ID of the specimen
     * @param tokenId Token ID of the specimen
     */
    function evolveSpecimen(uint256 collectionId, uint256 tokenId) external whenNotPaused nonReentrant {
        _evolveSpecimenInternal(collectionId, tokenId);
    }

    /**
     * @notice Batch evolve multiple specimens
     * @param collectionIds Array of collection IDs
     * @param tokenIds Array of token IDs
     */
    function batchEvolveSpecimens(
        uint256[] calldata collectionIds,
        uint256[] calldata tokenIds
    ) external whenNotPaused nonReentrant {
        require(collectionIds.length == tokenIds.length, "Array length mismatch");
        require(collectionIds.length <= 10, "Max 10 specimens per batch");

        for (uint256 i = 0; i < collectionIds.length; i++) {
            _evolveSpecimenInternal(collectionIds[i], tokenIds[i]);
        }
    }

    // ============================================
    // INTERNAL FUNCTIONS
    // ============================================

    function _validateEvolution(
        uint256 collectionId,
        uint256 tokenId,
        address caller,
        LibProgressionStorage.ProgressionStorage storage ps
    ) internal view {
        // Check system enabled
        if (!ps.evolutionConfig.systemEnabled) {
            revert EvolutionSystemDisabled();
        }

        // Check collection enabled
        LibProgressionStorage.CollectionEvolutionConfig storage collConfig =
            ps.collectionEvolutionConfigs[collectionId];
        if (!collConfig.evolutionEnabled) {
            revert CollectionNotEvolutionEnabled(collectionId);
        }

        // Check ownership
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        SpecimenCollection storage collection = hs.specimenCollections[collectionId];

        if (collection.collectionAddress == address(0)) {
            revert InvalidCollectionId(collectionId);
        }

        address owner = IERC721(collection.collectionAddress).ownerOf(tokenId);
        // Also check if staked
        address stakingAddress = hs.stakingSystemAddress;
        if (caller != owner && caller != stakingAddress) {
            // Check if token is staked by caller
            // This allows staked tokens to be evolved by their staker
            revert NotSpecimenOwner(caller, owner);
        }

        bytes32 specimenKey = LibProgressionStorage.getSpecimenKey(collectionId, tokenId);
        LibProgressionStorage.SpecimenEvolution storage evolution = ps.specimenEvolutions[specimenKey];

        // Check if locked
        if (evolution.locked) {
            revert SpecimenLocked(collectionId, tokenId);
        }

        // Check max level
        uint8 maxLevel = collConfig.maxLevelOverride > 0
            ? collConfig.maxLevelOverride
            : ps.evolutionConfig.maxLevel;

        if (evolution.currentLevel >= maxLevel) {
            revert AlreadyMaxLevel(evolution.currentLevel, maxLevel);
        }

        // Check tier enabled and cooldown
        uint8 nextLevel = evolution.currentLevel + 1;
        LibProgressionStorage.EvolutionTier storage tier = ps.evolutionTiers[nextLevel];

        if (!tier.enabled) {
            revert TierNotEnabled(nextLevel);
        }

        if (evolution.lastEvolutionTime + tier.cooldownSeconds > block.timestamp) {
            uint32 remaining = (evolution.lastEvolutionTime + tier.cooldownSeconds) - uint32(block.timestamp);
            revert CooldownNotFinished(remaining);
        }
    }

    function _evolveSpecimenInternal(uint256 collectionId, uint256 tokenId) internal {
        address caller = LibMeta.msgSender();
        bytes32 specimenKey = LibProgressionStorage.getSpecimenKey(collectionId, tokenId);

        // Get card discount (returns 0 if no card)
        (uint16 discountBps, uint8 cardTierBonus) = _getCardBonus(specimenKey);

        // Perform evolution with card bonus
        (uint8 currentLevel, uint8 nextLevel, uint256[4] memory consumed, uint256 tokenCost) =
            _performEvolution(collectionId, tokenId, caller, specimenKey, discountBps, cardTierBonus);

        emit SpecimenEvolved(collectionId, tokenId, caller, currentLevel, nextLevel, consumed, tokenCost);
    }

    function _getCardBonus(bytes32 specimenKey) internal view returns (uint16 discountBps, uint8 tierBonus) {
        LibBuildingsStorage.SpecimenAttachedCard memory card = LibBuildingsStorage.getSpecimenCard(specimenKey);
        if (card.tokenId != 0) {
            return (card.computedBonusBps, card.tierBonus);
        }
        return (0, 0);
    }

    function _performEvolution(
        uint256 collectionId,
        uint256 tokenId,
        address caller,
        bytes32 specimenKey,
        uint16 discountBps,
        uint8 cardTierBonus
    ) internal returns (uint8 currentLevel, uint8 nextLevel, uint256[4] memory consumed, uint256 tokenCost) {
        LibProgressionStorage.ProgressionStorage storage ps = LibProgressionStorage.progressionStorage();

        _validateEvolution(collectionId, tokenId, caller, ps);

        LibProgressionStorage.SpecimenEvolution storage evolution = ps.specimenEvolutions[specimenKey];
        currentLevel = evolution.currentLevel;
        nextLevel = currentLevel + 1;

        // Consume resources
        (consumed, tokenCost) = _consumeEvolutionResources(caller, nextLevel, discountBps);

        // Update evolution state
        evolution.currentLevel = nextLevel;
        evolution.lastEvolutionTime = uint32(block.timestamp);

        LibProgressionStorage.EvolutionTier storage tier = ps.evolutionTiers[nextLevel];
        evolution.totalStatBoost += tier.statBoostBps;
        evolution.totalProductionBoost += tier.productionBoostBps;

        if (cardTierBonus > 0) {
            evolution.totalStatBoost += uint16(cardTierBonus) * 100;
        }

        // Update statistics
        ps.totalEvolutionsPerformed++;
        ps.evolutionsPerLevel[nextLevel]++;
        ps.totalEvolutionResourcesConsumed += consumed[0] + consumed[1] + consumed[2] + consumed[3];
        ps.totalEvolutionTokensConsumed += tokenCost;
        ps.evolutionHistory[specimenKey].push(uint32(block.timestamp));

        return (currentLevel, nextLevel, consumed, tokenCost);
    }

    function _consumeEvolutionResources(
        address caller,
        uint8 nextLevel,
        uint16 discountBps
    ) internal returns (uint256[4] memory consumed, uint256 tokenCost) {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        LibProgressionStorage.ProgressionStorage storage ps = LibProgressionStorage.progressionStorage();
        LibProgressionStorage.EvolutionTier storage tier = ps.evolutionTiers[nextLevel];

        for (uint8 i = 0; i < 4; i++) {
            uint256 required = tier.resourceCosts[i];
            if (required > 0) {
                if (discountBps > 0) {
                    uint256 discount = (required * discountBps) / 10000;
                    required = required > discount ? required - discount : 0;
                }
                if (required > 0) {
                    require(rs.userResources[caller][i] >= required, "Insufficient resources");
                    rs.userResources[caller][i] -= required;
                    consumed[i] = required;
                    LibResourceStorage.decrementGlobalSupply(i, required);
                }
            }
        }

        tokenCost = tier.tokenCost;
        if (tokenCost > 0) {
            if (discountBps > 0) {
                uint256 discount = (tokenCost * discountBps) / 10000;
                tokenCost = tokenCost > discount ? tokenCost - discount : 0;
            }
            if (tokenCost > 0) {
                _collectEvolutionFee(caller, tokenCost, "specimen_evolution");
            }
        }

        return (consumed, tokenCost);
    }

    // ============================================
    // ADMIN FUNCTIONS
    // ============================================

    /**
     * @notice Initialize the evolution system
     */
    function initializeEvolutionSystem() external onlyAuthorized {
        LibProgressionStorage.initializeDefaults();
    }

    /**
     * @notice Enable or disable the evolution system
     * @param enabled True to enable, false to disable
     */
    function setEvolutionSystemEnabled(bool enabled) external onlyAuthorized {
        LibProgressionStorage.ProgressionStorage storage ps =
            LibProgressionStorage.progressionStorage();
        ps.evolutionConfig.systemEnabled = enabled;
        emit EvolutionSystemToggled(enabled);
    }

    /**
     * @notice Configure evolution tier
     * @param tier Tier number (1-5)
     * @param resourceCosts Resource costs array [basic, energy, bio, rare]
     * @param tokenCost Token cost (YLW/ZICO)
     * @param statBoostBps Stat boost in basis points
     * @param productionBoostBps Production boost in basis points
     * @param cooldownSeconds Cooldown after this evolution
     * @param enabled Whether tier is enabled
     */
    function setEvolutionTier(
        uint8 tier,
        uint256[4] calldata resourceCosts,
        uint256 tokenCost,
        uint16 statBoostBps,
        uint16 productionBoostBps,
        uint32 cooldownSeconds,
        bool enabled
    ) external onlyAuthorized {
        if (tier == 0 || tier > 10) revert InvalidTier(tier);

        LibProgressionStorage.ProgressionStorage storage ps =
            LibProgressionStorage.progressionStorage();

        ps.evolutionTiers[tier] = LibProgressionStorage.EvolutionTier({
            resourceCosts: resourceCosts,
            tokenCost: tokenCost,
            statBoostBps: statBoostBps,
            productionBoostBps: productionBoostBps,
            cooldownSeconds: cooldownSeconds,
            requiresPreviousTier: tier > 1,
            enabled: enabled
        });

        emit EvolutionTierUpdated(tier, resourceCosts, tokenCost, statBoostBps, productionBoostBps);
    }

    /**
     * @notice Configure collection for evolution
     * @param collectionId Collection ID
     * @param enabled Whether evolution is enabled
     * @param bonusMultiplierBps Collection bonus multiplier (10000 = 1x)
     * @param maxLevelOverride Max level override (0 = use global)
     */
    function setCollectionEvolutionConfig(
        uint256 collectionId,
        bool enabled,
        uint16 bonusMultiplierBps,
        uint8 maxLevelOverride
    ) external onlyAuthorized {
        LibProgressionStorage.ProgressionStorage storage ps =
            LibProgressionStorage.progressionStorage();

        ps.collectionEvolutionConfigs[collectionId] = LibProgressionStorage.CollectionEvolutionConfig({
            evolutionEnabled: enabled,
            bonusMultiplierBps: bonusMultiplierBps,
            maxLevelOverride: maxLevelOverride
        });

        emit CollectionEvolutionConfigured(collectionId, enabled, bonusMultiplierBps, maxLevelOverride);
    }

    /**
     * @notice Set token addresses for evolution payments
     * @param governanceToken ZICO token address
     * @param utilityToken YLW token address
     * @param beneficiary Where fees go
     * @param useGovernanceToken True = use ZICO, false = use YLW
     */
    function setEvolutionTokenConfig(
        address governanceToken,
        address utilityToken,
        address beneficiary,
        bool useGovernanceToken
    ) external onlyAuthorized {
        LibProgressionStorage.ProgressionStorage storage ps =
            LibProgressionStorage.progressionStorage();

        ps.tokenConfig.governanceToken = governanceToken;
        ps.tokenConfig.utilityToken = utilityToken;
        ps.tokenConfig.beneficiary = beneficiary;
        ps.tokenConfig.useGovernanceToken = useGovernanceToken;
    }

    /**
     * @notice Lock/unlock specimen evolution (for events, etc.)
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @param locked Lock state
     */
    function setSpecimenLock(uint256 collectionId, uint256 tokenId, bool locked) external onlyAuthorized {
        LibProgressionStorage.ProgressionStorage storage ps =
            LibProgressionStorage.progressionStorage();

        bytes32 key = LibProgressionStorage.getSpecimenKey(collectionId, tokenId);
        ps.specimenEvolutions[key].locked = locked;

        emit SpecimenLockToggled(collectionId, tokenId, locked);
    }

    /**
     * @notice Set max evolution level
     * @param maxLevel New max level (1-10)
     */
    function setMaxLevel(uint8 maxLevel) external onlyAuthorized {
        require(maxLevel > 0 && maxLevel <= 10, "Invalid max level");
        LibProgressionStorage.ProgressionStorage storage ps =
            LibProgressionStorage.progressionStorage();
        ps.evolutionConfig.maxLevel = maxLevel;
    }

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    /**
     * @notice Get specimen's evolution status
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @return currentLevel Current evolution level
     * @return lastEvolutionTime Last evolution timestamp
     * @return totalStatBoost Cumulative stat boost (bps)
     * @return totalProductionBoost Cumulative production boost (bps)
     * @return locked Whether specimen is locked
     */
    function getSpecimenEvolution(
        uint256 collectionId,
        uint256 tokenId
    ) external view returns (
        uint8 currentLevel,
        uint32 lastEvolutionTime,
        uint16 totalStatBoost,
        uint16 totalProductionBoost,
        bool locked
    ) {
        LibProgressionStorage.ProgressionStorage storage ps =
            LibProgressionStorage.progressionStorage();

        bytes32 key = LibProgressionStorage.getSpecimenKey(collectionId, tokenId);
        LibProgressionStorage.SpecimenEvolution storage evolution = ps.specimenEvolutions[key];

        return (
            evolution.currentLevel,
            evolution.lastEvolutionTime,
            evolution.totalStatBoost,
            evolution.totalProductionBoost,
            evolution.locked
        );
    }

    /**
     * @notice Check if specimen can evolve
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @return canEvolve True if can evolve
     * @return reason Reason if cannot
     */
    function canEvolve(
        uint256 collectionId,
        uint256 tokenId
    ) external view returns (bool canEvolve, string memory reason) {
        return LibProgressionStorage.canSpecimenEvolve(collectionId, tokenId);
    }

    /**
     * @notice Get evolution tier details
     * @param tier Tier number (1-5)
     * @return resourceCosts Resource costs
     * @return tokenCost Token cost
     * @return statBoostBps Stat boost
     * @return productionBoostBps Production boost
     * @return cooldownSeconds Cooldown
     * @return enabled Whether enabled
     */
    function getEvolutionTier(uint8 tier) external view returns (
        uint256[4] memory resourceCosts,
        uint256 tokenCost,
        uint16 statBoostBps,
        uint16 productionBoostBps,
        uint32 cooldownSeconds,
        bool enabled
    ) {
        LibProgressionStorage.ProgressionStorage storage ps =
            LibProgressionStorage.progressionStorage();

        LibProgressionStorage.EvolutionTier storage t = ps.evolutionTiers[tier];

        return (
            t.resourceCosts,
            t.tokenCost,
            t.statBoostBps,
            t.productionBoostBps,
            t.cooldownSeconds,
            t.enabled
        );
    }

    /**
     * @notice Get evolution cost for next level
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @return resourceCosts Required resources
     * @return tokenCost Required tokens
     * @return cooldownRemaining Seconds until can evolve (0 if ready)
     */
    function getNextEvolutionCost(
        uint256 collectionId,
        uint256 tokenId
    ) external view returns (
        uint256[4] memory resourceCosts,
        uint256 tokenCost,
        uint32 cooldownRemaining
    ) {
        LibProgressionStorage.ProgressionStorage storage ps =
            LibProgressionStorage.progressionStorage();

        bytes32 key = LibProgressionStorage.getSpecimenKey(collectionId, tokenId);
        LibProgressionStorage.SpecimenEvolution storage evolution = ps.specimenEvolutions[key];

        uint8 nextLevel = evolution.currentLevel + 1;
        LibProgressionStorage.EvolutionTier storage tier = ps.evolutionTiers[nextLevel];

        resourceCosts = tier.resourceCosts;
        tokenCost = tier.tokenCost;

        if (evolution.lastEvolutionTime + tier.cooldownSeconds > block.timestamp) {
            cooldownRemaining = (evolution.lastEvolutionTime + tier.cooldownSeconds) - uint32(block.timestamp);
        }

        return (resourceCosts, tokenCost, cooldownRemaining);
    }

    /**
     * @notice Get evolution system statistics
     * @return totalEvolutions Total evolutions performed
     * @return totalResourcesConsumed Total resources consumed
     * @return totalTokensConsumed Total tokens consumed
     * @return systemEnabled Whether system is enabled
     */
    function getEvolutionStats() external view returns (
        uint256 totalEvolutions,
        uint256 totalResourcesConsumed,
        uint256 totalTokensConsumed,
        bool systemEnabled
    ) {
        LibProgressionStorage.ProgressionStorage storage ps =
            LibProgressionStorage.progressionStorage();

        return (
            ps.totalEvolutionsPerformed,
            ps.totalEvolutionResourcesConsumed,
            ps.totalEvolutionTokensConsumed,
            ps.evolutionConfig.systemEnabled
        );
    }

    /**
     * @notice Get specimen boosts (for integration with other systems)
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @return statBoostBps Stat boost in basis points
     * @return productionBoostBps Production boost in basis points
     */
    function getSpecimenBoosts(
        uint256 collectionId,
        uint256 tokenId
    ) external view returns (uint16 statBoostBps, uint16 productionBoostBps) {
        return LibProgressionStorage.getSpecimenBoosts(collectionId, tokenId);
    }

    /**
     * @notice Get collection evolution config
     * @param collectionId Collection ID
     * @return evolutionEnabled Whether enabled
     * @return bonusMultiplierBps Bonus multiplier
     * @return maxLevelOverride Max level override
     */
    function getCollectionEvolutionConfig(uint256 collectionId) external view returns (
        bool evolutionEnabled,
        uint16 bonusMultiplierBps,
        uint8 maxLevelOverride
    ) {
        LibProgressionStorage.ProgressionStorage storage ps =
            LibProgressionStorage.progressionStorage();

        LibProgressionStorage.CollectionEvolutionConfig storage config =
            ps.collectionEvolutionConfigs[collectionId];

        return (
            config.evolutionEnabled,
            config.bonusMultiplierBps,
            config.maxLevelOverride
        );
    }

    // ============================================
    // CARD SYSTEM FUNCTIONS
    // ============================================

    /**
     * @notice Attach an evolution card to a specimen
     * @param collectionId Specimen collection ID
     * @param tokenId Specimen token ID
     * @param cardTokenId Card NFT token ID
     * @param cardCollectionId Card collection ID (registered in BuildingsStorage)
     * @param cardTypeId Card type ID (must be Evolution or Universal compatible)
     * @param rarity Card rarity level
     */
    function attachEvolutionCard(
        uint256 collectionId,
        uint256 tokenId,
        uint256 cardTokenId,
        uint16 cardCollectionId,
        uint8 cardTypeId,
        LibBuildingsStorage.CardRarity rarity
    ) external whenNotPaused nonReentrant {
        LibBuildingsStorage.BuildingsStorage storage bs = LibBuildingsStorage.buildingsStorage();
        address caller = LibMeta.msgSender();

        // Check card system enabled
        if (!bs.cardConfig.systemEnabled) {
            revert CardSystemDisabled();
        }

        // Verify caller owns the specimen
        _verifySpecimenOwnership(collectionId, tokenId, caller);

        // Verify caller owns the card
        LibBuildingsStorage.CardCollection storage cardColl = bs.cardCollections[cardCollectionId];
        if (!cardColl.enabled) {
            revert InvalidCardCollection(cardCollectionId);
        }

        IERC721 cardContract = IERC721(cardColl.contractAddress);
        if (cardContract.ownerOf(cardTokenId) != caller) {
            revert NotCardOwner(cardTokenId);
        }

        // Check card is compatible with Evolution system
        if (!LibBuildingsStorage.isCardSystemCompatible(cardTypeId, LibBuildingsStorage.CardCompatibleSystem.Evolution)) {
            revert CardNotCompatible(cardTypeId);
        }

        // Get specimen key
        bytes32 specimenKey = LibProgressionStorage.getSpecimenKey(collectionId, tokenId);

        // Check no card already attached
        if (LibBuildingsStorage.hasSpecimenCard(specimenKey)) {
            revert CardAlreadyAttached(specimenKey);
        }

        // Check attach cooldown
        (bool canAttach, uint32 cooldownRemaining) = LibBuildingsStorage.canUserAttachCard(caller);
        if (!canAttach) {
            revert CardInCooldown(cooldownRemaining);
        }

        // Attach card
        LibBuildingsStorage.attachSpecimenCard(
            specimenKey,
            cardTokenId,
            cardCollectionId,
            cardTypeId,
            rarity
        );

        // Get computed bonus for event
        LibBuildingsStorage.SpecimenAttachedCard memory attachedCard =
            LibBuildingsStorage.getSpecimenCard(specimenKey);

        emit EvolutionCardAttached(
            collectionId,
            tokenId,
            cardTokenId,
            cardCollectionId,
            cardTypeId,
            attachedCard.computedBonusBps
        );
    }

    /**
     * @notice Detach an evolution card from a specimen
     * @param collectionId Specimen collection ID
     * @param tokenId Specimen token ID
     */
    function detachEvolutionCard(
        uint256 collectionId,
        uint256 tokenId
    ) external whenNotPaused nonReentrant {
        address caller = LibMeta.msgSender();

        // Verify caller owns the specimen
        _verifySpecimenOwnership(collectionId, tokenId, caller);

        bytes32 specimenKey = LibProgressionStorage.getSpecimenKey(collectionId, tokenId);

        // Check card exists
        if (!LibBuildingsStorage.hasSpecimenCard(specimenKey)) {
            revert NoCardAttached(specimenKey);
        }

        LibBuildingsStorage.SpecimenAttachedCard memory card =
            LibBuildingsStorage.getSpecimenCard(specimenKey);

        // Check not locked
        if (card.locked) {
            revert CardLocked();
        }

        // Check detach cooldown
        if (block.timestamp < card.cooldownUntil) {
            revert CardInCooldown(card.cooldownUntil - uint32(block.timestamp));
        }

        // Detach card
        LibBuildingsStorage.detachSpecimenCard(specimenKey);

        emit EvolutionCardDetached(collectionId, tokenId, card.tokenId);
    }

    /**
     * @notice Get evolution card attached to a specimen
     * @param collectionId Specimen collection ID
     * @param tokenId Specimen token ID
     * @return cardTokenId Card NFT token ID (0 if none)
     * @return cardCollectionId Card collection ID
     * @return cardTypeId Card type ID
     * @return rarity Card rarity
     * @return costReductionBps Cost reduction bonus
     * @return tierBonus Additional tier bonus
     * @return cooldownUntil Cooldown timestamp
     * @return locked Whether card is locked
     */
    function getSpecimenCard(
        uint256 collectionId,
        uint256 tokenId
    ) external view returns (
        uint256 cardTokenId,
        uint16 cardCollectionId,
        uint8 cardTypeId,
        LibBuildingsStorage.CardRarity rarity,
        uint16 costReductionBps,
        uint8 tierBonus,
        uint32 cooldownUntil,
        bool locked
    ) {
        bytes32 specimenKey = LibProgressionStorage.getSpecimenKey(collectionId, tokenId);
        LibBuildingsStorage.SpecimenAttachedCard memory card =
            LibBuildingsStorage.getSpecimenCard(specimenKey);

        return (
            card.tokenId,
            card.collectionId,
            card.cardTypeId,
            card.rarity,
            card.computedBonusBps,
            card.tierBonus,
            card.cooldownUntil,
            card.locked
        );
    }

    /**
     * @notice Check if specimen has evolution card attached
     * @param collectionId Specimen collection ID
     * @param tokenId Specimen token ID
     * @return hasCard True if card attached
     */
    function specimenHasCard(uint256 collectionId, uint256 tokenId) external view returns (bool hasCard) {
        bytes32 specimenKey = LibProgressionStorage.getSpecimenKey(collectionId, tokenId);
        return LibBuildingsStorage.hasSpecimenCard(specimenKey);
    }

    /**
     * @notice Get evolution cost with card discount applied
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @return resourceCosts Required resources (after card discount)
     * @return tokenCost Required tokens (after card discount)
     * @return cooldownRemaining Seconds until can evolve
     * @return cardBonusApplied Whether card bonus was applied
     */
    function getNextEvolutionCostWithCard(
        uint256 collectionId,
        uint256 tokenId
    ) external view returns (
        uint256[4] memory resourceCosts,
        uint256 tokenCost,
        uint32 cooldownRemaining,
        bool cardBonusApplied
    ) {
        LibProgressionStorage.ProgressionStorage storage ps =
            LibProgressionStorage.progressionStorage();

        bytes32 key = LibProgressionStorage.getSpecimenKey(collectionId, tokenId);
        LibProgressionStorage.SpecimenEvolution storage evolution = ps.specimenEvolutions[key];

        uint8 nextLevel = evolution.currentLevel + 1;
        LibProgressionStorage.EvolutionTier storage tier = ps.evolutionTiers[nextLevel];

        // Get base costs
        resourceCosts = tier.resourceCosts;
        tokenCost = tier.tokenCost;

        // Apply card discount if present
        LibBuildingsStorage.SpecimenAttachedCard memory card =
            LibBuildingsStorage.getSpecimenCard(key);

        if (card.tokenId != 0 && card.computedBonusBps > 0) {
            cardBonusApplied = true;
            uint16 discountBps = card.computedBonusBps;

            // Apply discount to each resource cost
            for (uint8 i = 0; i < 4; i++) {
                if (resourceCosts[i] > 0) {
                    uint256 discount = (resourceCosts[i] * discountBps) / 10000;
                    resourceCosts[i] = resourceCosts[i] > discount ? resourceCosts[i] - discount : 0;
                }
            }

            // Apply discount to token cost
            if (tokenCost > 0) {
                uint256 discount = (tokenCost * discountBps) / 10000;
                tokenCost = tokenCost > discount ? tokenCost - discount : 0;
            }
        }

        // Calculate cooldown
        if (evolution.lastEvolutionTime + tier.cooldownSeconds > block.timestamp) {
            cooldownRemaining = (evolution.lastEvolutionTime + tier.cooldownSeconds) - uint32(block.timestamp);
        }

        return (resourceCosts, tokenCost, cooldownRemaining, cardBonusApplied);
    }

    // ============================================
    // INTERNAL HELPER FUNCTIONS
    // ============================================

    /**
     * @notice Verify caller owns the specimen
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @param caller Caller address
     */
    function _verifySpecimenOwnership(
        uint256 collectionId,
        uint256 tokenId,
        address caller
    ) internal view {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        SpecimenCollection storage collection = hs.specimenCollections[collectionId];

        if (collection.collectionAddress == address(0)) {
            revert InvalidCollectionId(collectionId);
        }

        address owner = IERC721(collection.collectionAddress).ownerOf(tokenId);
        address stakingAddress = hs.stakingSystemAddress;

        if (caller != owner && caller != stakingAddress) {
            revert NotSpecimenOwner(caller, owner);
        }
    }

    /**
     * @notice Collect evolution fee using LibFeeCollection
     * @dev Supports YLW/ZICO selection and burn mode
     * @param payer Address paying the fee
     * @param amount Fee amount
     * @param operation Operation identifier for events
     */
    function _collectEvolutionFee(address payer, uint256 amount, string memory operation) internal {
        if (amount == 0) return;

        LibProgressionStorage.ProgressionStorage storage ps =
            LibProgressionStorage.progressionStorage();

        // Select token based on configuration
        address tokenAddress = ps.tokenConfig.useGovernanceToken
            ? ps.tokenConfig.governanceToken
            : ps.tokenConfig.utilityToken;

        IERC20 token = IERC20(tokenAddress);

        // Validate balance
        uint256 balance = token.balanceOf(payer);
        if (balance < amount) {
            revert InsufficientTokenBalance(amount, balance);
        }

        // Use LibFeeCollection for consistent fee handling
        // Only burn for utility token (YLW), not governance token (ZICO)
        if (ps.tokenConfig.burnOnCollect && !ps.tokenConfig.useGovernanceToken) {
            LibFeeCollection.collectAndBurnFee(
                token,
                payer,
                ps.tokenConfig.beneficiary,
                amount,
                operation
            );
        } else {
            LibFeeCollection.collectFee(
                token,
                payer,
                ps.tokenConfig.beneficiary,
                amount,
                operation
            );
        }
    }
}
