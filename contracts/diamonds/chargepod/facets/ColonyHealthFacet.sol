// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibHenomorphsStorage} from "../libraries/LibHenomorphsStorage.sol";
import {LibResourceStorage} from "../libraries/LibResourceStorage.sol";
import {ColonyHelper} from "../libraries/ColonyHelper.sol";
import {LibMeta} from "../../shared/libraries/LibMeta.sol";
import {AccessHelper} from "../libraries/AccessHelper.sol";
import {AccessControlBase} from "./AccessControlBase.sol";
import {LibFeeCollection} from "../libraries/LibFeeCollection.sol";

/**
 * @title ColonyHealthFacet
 * @notice Complete colony health management system
 * @dev Focused on health management - doesn't duplicate view functionality
 */
contract ColonyHealthFacet is AccessControlBase {
    
    event ColonyHealthRestored(bytes32 indexed colonyId, address indexed restorer, uint8 newHealth);
    event ColonyHealthDecayed(bytes32 indexed colonyId, uint8 healthLevel, uint32 daysSinceActivity);
    event ColonyPenaltyApplied(bytes32 indexed colonyId, uint8 penaltySeverity, uint256 membersAffected);
    event ColonyHealedWithBio(bytes32 indexed colonyId, address indexed healer, uint256 bioSpent, uint8 healthRestored);

    error InsufficientBioResources(uint256 required, uint256 available);
    error ColonyAlreadyHealthy();

    struct ColonyHealthSummary {
        bytes32 colonyId;
        string name;
        uint8 healthLevel;
        uint32 daysSinceActivity;
        bool needsAttention;
        uint256 restorationCost;
        bool canRestore;
    }

    /**
     * @notice Restore colony health with different restoration levels
     * @param colonyId Colony ID
     * @param restorationType 1=basic(+50), 2=full(+100), 3=premium(+100 + bonus)
     */
    function restoreColonyHealth(bytes32 colonyId, uint8 restorationType) external nonReentrant whenNotPaused {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        if (bytes(hs.colonyNamesById[colonyId]).length == 0) {
            revert ColonyHelper.ColonyDoesNotExist(colonyId);
        }
        
        if (!ColonyHelper.isAuthorizedForColony(colonyId, hs.stakingSystemAddress)) {
            revert AccessHelper.Unauthorized(LibMeta.msgSender(), "Not authorized");
        }
        
        (uint8 currentHealth,) = ColonyHelper.calculateColonyHealth(colonyId);
        
        if (currentHealth >= 90 && restorationType != 3) {
            revert("Colony already healthy");
        }
        
        // Calculate cost and restoration amount
        uint256 baseCost = hs.chargeFees.colonyMembershipFee.amount;
        uint256 totalCost;
        uint8 healthBonus;
        
        if (restorationType == 1) {      // Basic restoration
            totalCost = baseCost;
            healthBonus = 50;
        } else if (restorationType == 2) { // Full restoration  
            totalCost = baseCost * 2;
            healthBonus = 100;
        } else if (restorationType == 3) { // Premium restoration
            totalCost = baseCost * 3;
            healthBonus = 100;
        } else {
            revert("Invalid restoration type");
        }
        
        // Collect fee
        LibFeeCollection.collectFee(
            hs.chargeFees.colonyMembershipFee.currency,
            LibMeta.msgSender(),
            hs.chargeFees.colonyMembershipFee.beneficiary,
            totalCost,
            "restoreColonyHealth"
        );
        
        // Apply restoration
        LibHenomorphsStorage.ColonyHealth storage health = hs.colonyHealth[colonyId];
        uint8 newHealth = currentHealth + healthBonus;
        if (newHealth > 100) newHealth = 100;
        
        health.healthLevel = newHealth;
        health.lastActivityDay = uint32(block.timestamp / 86400);
        
        // Premium restoration gives temporary boost
        if (restorationType == 3) {
            health.boostEndTime = uint32(block.timestamp + 7 days);
        }
        
        emit ColonyHealthRestored(colonyId, LibMeta.msgSender(), newHealth);
    }

    /**
     * @notice Heal colony using Bio resources instead of payment
     * @dev UNIQUE RESOURCE USE-CASE: Bio → Colony Healing
     *      Consumes Bio Compounds (resourceType=2) to restore colony health
     *      100 Bio = 10 health points restored
     * @param colonyId Colony to heal
     * @param bioAmount Amount of Bio resources to spend
     * @return healthRestored Amount of health points restored
     */
    function healColonyWithBio(
        bytes32 colonyId,
        uint256 bioAmount
    ) external nonReentrant whenNotPaused returns (uint8 healthRestored) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();

        if (bytes(hs.colonyNamesById[colonyId]).length == 0) {
            revert ColonyHelper.ColonyDoesNotExist(colonyId);
        }

        if (!ColonyHelper.isAuthorizedForColony(colonyId, hs.stakingSystemAddress)) {
            revert AccessHelper.Unauthorized(LibMeta.msgSender(), "Not authorized");
        }

        (uint8 currentHealth,) = ColonyHelper.calculateColonyHealth(colonyId);

        if (currentHealth >= 100) {
            revert ColonyAlreadyHealthy();
        }

        address user = LibMeta.msgSender();

        // Apply resource decay before checking balance
        LibResourceStorage.applyResourceDecay(user);

        // Check user has enough Bio (resourceType = 2)
        uint256 availableBio = rs.userResources[user][LibResourceStorage.BIO_COMPOUNDS];
        if (availableBio < bioAmount) {
            revert InsufficientBioResources(bioAmount, availableBio);
        }

        // Calculate health restoration: 100 Bio = 10 health points
        // Formula: healthRestored = bioAmount / 10
        healthRestored = uint8(bioAmount / 10);
        if (healthRestored == 0) {
            revert InsufficientBioResources(10, bioAmount); // Minimum 10 Bio needed
        }

        // Cap to maximum possible restoration
        uint8 maxRestoration = 100 - currentHealth;
        if (healthRestored > maxRestoration) {
            healthRestored = maxRestoration;
            // Adjust bio spent to match actual restoration
            bioAmount = uint256(healthRestored) * 10;
        }

        // Consume Bio resources
        rs.userResources[user][LibResourceStorage.BIO_COMPOUNDS] -= bioAmount;

        // Apply health restoration
        LibHenomorphsStorage.ColonyHealth storage health = hs.colonyHealth[colonyId];
        uint8 newHealth = currentHealth + healthRestored;
        health.healthLevel = newHealth;
        health.lastActivityDay = uint32(block.timestamp / 86400);

        emit ColonyHealedWithBio(colonyId, user, bioAmount, healthRestored);
        emit ColonyHealthRestored(colonyId, user, newHealth);

        return healthRestored;
    }

    /**
     * @notice Estimate Bio healing cost
     * @param colonyId Colony to check
     * @param targetHealth Target health level (1-100)
     * @return bioCost Amount of Bio needed
     * @return actualHealthGain Actual health that would be restored
     */
    function estimateBioHealingCost(
        bytes32 colonyId,
        uint8 targetHealth
    ) external view returns (uint256 bioCost, uint8 actualHealthGain) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();

        if (bytes(hs.colonyNamesById[colonyId]).length == 0) {
            return (0, 0);
        }

        (uint8 currentHealth,) = ColonyHelper.calculateColonyHealth(colonyId);

        if (currentHealth >= 100 || targetHealth <= currentHealth) {
            return (0, 0);
        }

        // Cap target health to 100
        if (targetHealth > 100) {
            targetHealth = 100;
        }

        actualHealthGain = targetHealth - currentHealth;
        bioCost = uint256(actualHealthGain) * 10; // 10 Bio per health point

        return (bioCost, actualHealthGain);
    }

    /**
     * @notice Get detailed colony health status
     * @param colonyId Colony ID
     */
    function getColonyHealthDetails(bytes32 colonyId) external view returns (
        uint8 healthLevel,
        uint32 daysSinceActivity,
        bool needsAttention,
        bool hasPenalties,
        uint256 restorationCost,
        uint32 boostTimeLeft,
        string memory healthDescription
    ) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        if (bytes(hs.colonyNamesById[colonyId]).length == 0) {
            revert ColonyHelper.ColonyDoesNotExist(colonyId);
        }
        
        (healthLevel, daysSinceActivity) = ColonyHelper.calculateColonyHealth(colonyId);
        needsAttention = healthLevel < 50;
        hasPenalties = healthLevel < 30;
        
        // Calculate restoration cost
        if (healthLevel < 90) {
            restorationCost = hs.chargeFees.colonyMembershipFee.amount;
        }
        
        // Check boost time
        LibHenomorphsStorage.ColonyHealth storage health = hs.colonyHealth[colonyId];
        if (health.boostEndTime > block.timestamp) {
            boostTimeLeft = health.boostEndTime - uint32(block.timestamp);
        }
        
        // Health description
        if (healthLevel >= 80) {
            healthDescription = "Excellent";
        } else if (healthLevel >= 60) {
            healthDescription = "Good";
        } else if (healthLevel >= 40) {
            healthDescription = "Fair";
        } else if (healthLevel >= 20) {
            healthDescription = "Poor";
        } else {
            healthDescription = "Critical";
        }
    }

    /**
     * @notice Get unhealthy colonies for user with detailed info
     * @param user User address
     */
    function getUnhealthyUserColonies(address user) external view returns (
        ColonyHealthSummary[] memory unhealthyColonies
    ) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        bytes32[] storage userColonies = hs.userColonies[user];
        
        // Count unhealthy colonies
        uint256 unhealthyCount = 0;
        for (uint256 i = 0; i < userColonies.length; i++) {
            (uint8 health,) = ColonyHelper.calculateColonyHealth(userColonies[i]);
            if (health < 60) { // Include "fair" health colonies
                unhealthyCount++;
            }
        }
        
        // Build detailed result
        unhealthyColonies = new ColonyHealthSummary[](unhealthyCount);
        uint256 resultIndex = 0;
        
        for (uint256 i = 0; i < userColonies.length; i++) {
            bytes32 colonyId = userColonies[i];
            (uint8 health, uint32 daysSince) = ColonyHelper.calculateColonyHealth(colonyId);
            
            if (health < 60) {
                unhealthyColonies[resultIndex] = ColonyHealthSummary({
                    colonyId: colonyId,
                    name: hs.colonyNamesById[colonyId],
                    healthLevel: health,
                    daysSinceActivity: daysSince,
                    needsAttention: health < 50,
                    restorationCost: health < 90 ? hs.chargeFees.colonyMembershipFee.amount : 0,
                    canRestore: ColonyHelper.isAuthorizedForColony(colonyId, hs.stakingSystemAddress)
                });
                resultIndex++;
            }
        }
    }

    /**
     * @notice Get health restoration options and costs
     */
    function getRestorationOptions() external view returns (
        uint256 basicCost,
        uint256 fullCost,
        uint256 premiumCost,
        string memory basicDescription,
        string memory fullDescription,
        string memory premiumDescription
    ) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        uint256 baseCost = hs.chargeFees.colonyMembershipFee.amount;
        
        basicCost = baseCost;
        fullCost = baseCost * 2;
        premiumCost = baseCost * 3;
        
        basicDescription = "Restore +50 health points";
        fullDescription = "Fully restore to 100 health";
        premiumDescription = "Full restore + 7-day boost";
    }

    /**
     * @notice Emergency reset multiple colonies (admin only)
     * @param colonyIds Array of colony IDs to reset
     */
    function emergencyBulkResetHealth(bytes32[] calldata colonyIds) external onlyAuthorized {
        for (uint256 i = 0; i < colonyIds.length && i < 20; i++) { // Limit to 20
            bytes32 colonyId = colonyIds[i];
            LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
            
            if (bytes(hs.colonyNamesById[colonyId]).length > 0) {
                LibHenomorphsStorage.ColonyHealth storage health = hs.colonyHealth[colonyId];
                health.healthLevel = 100;
                health.lastActivityDay = uint32(block.timestamp / 86400);
                health.boostEndTime = 0;
                
                emit ColonyHealthRestored(colonyId, LibMeta.msgSender(), 100);
            }
        }
    }
}