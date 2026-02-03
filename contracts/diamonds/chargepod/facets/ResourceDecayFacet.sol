// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibResourceStorage} from "../libraries/LibResourceStorage.sol";
import {AccessControlBase} from "../../common/facets/AccessControlBase.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title ResourceDecayFacet
 * @notice Manages automated resource decay mechanics
 * @dev Batch processing for resource decay
 * @author rutilicus.eth (ArchXS)
 */
contract ResourceDecayFacet is AccessControlBase {
    
    event DecayApplied(address indexed user, uint32 daysPassed, uint256[4] decayedAmounts);
    event DecayBatchProcessed(uint256 usersProcessed, uint256 totalDecayApplied);
    event DecayConfigUpdated(bool enabled, uint16 baseRate);
    
    error DecayDisabled();
    error InvalidDecayRate(uint16 rate);
    error EmptyBatch();
    
    // ==================== ADMIN ====================
    
    function setDecayEnabled(bool enabled) external onlyAuthorized {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        rs.config.resourceDecayEnabled = enabled;
        emit DecayConfigUpdated(enabled, rs.config.baseResourceDecayRate);
    }
    
    function setDecayRate(uint16 baseRate) external onlyAuthorized {
        if (baseRate > 1000) revert InvalidDecayRate(baseRate); // Max 10% per day

        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        rs.config.baseResourceDecayRate = baseRate;
        emit DecayConfigUpdated(rs.config.resourceDecayEnabled, baseRate);
    }

    /**
     * @notice Fix corrupted decay timestamp for user
     * @param user User address
     */
    function fixUserResourceDecay(address user) external onlyAuthorized {
        LibResourceStorage.resourceStorage().lastDecayUpdate[user] = uint32(block.timestamp);
    }

    /**
     * @notice Batch fix decay timestamps
     * @param users User addresses
     */
    function fixUserResourceDecayBatch(address[] calldata users) external onlyAuthorized {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        uint32 t = uint32(block.timestamp);
        for (uint256 i = 0; i < users.length; i++) {
            rs.lastDecayUpdate[users[i]] = t;
        }
    }

    // ==================== DECAY EXECUTION ====================
    
    function applyDecayToUser(address user) external {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        if (!rs.config.resourceDecayEnabled) revert DecayDisabled();
        
        uint256[4] memory beforeAmounts;
        for (uint8 i = 0; i < 4; i++) {
            beforeAmounts[i] = rs.userResources[user][i];
        }
        
        LibResourceStorage.applyResourceDecay(user);
        
        uint256[4] memory decayedAmounts;
        uint32 lastUpdate = rs.lastDecayUpdate[user];
        uint32 currentTime = uint32(block.timestamp);
        uint32 daysPassed = currentTime > lastUpdate ? (currentTime - lastUpdate) / 86400 : 0;
        
        for (uint8 i = 0; i < 4; i++) {
            uint256 afterAmount = rs.userResources[user][i];
            decayedAmounts[i] = beforeAmounts[i] > afterAmount ? beforeAmounts[i] - afterAmount : 0;
        }
        
        emit DecayApplied(user, daysPassed, decayedAmounts);
    }
    
    function batchApplyDecay(address[] calldata users) external onlyAuthorized {
        if (users.length == 0) revert EmptyBatch();
        
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        if (!rs.config.resourceDecayEnabled) revert DecayDisabled();
        
        uint256 totalDecayApplied = 0;
        uint256 usersProcessed = 0;
        
        for (uint256 i = 0; i < users.length; i++) {
            address user = users[i];
            
            uint32 lastUpdate = rs.lastDecayUpdate[user];
            // Skip if decay was applied recently (< 1 day) or timestamp is corrupted (future)
            if (lastUpdate > 0 && (lastUpdate >= block.timestamp || block.timestamp - lastUpdate < 86400)) {
                continue;
            }
            
            uint256[4] memory beforeAmounts;
            for (uint8 j = 0; j < 4; j++) {
                beforeAmounts[j] = rs.userResources[user][j];
            }
            
            LibResourceStorage.applyResourceDecay(user);
            
            for (uint8 j = 0; j < 4; j++) {
                uint256 afterAmount = rs.userResources[user][j];
                if (beforeAmounts[j] > afterAmount) {
                    totalDecayApplied += (beforeAmounts[j] - afterAmount);
                }
            }
            
            usersProcessed++;
        }
        
        emit DecayBatchProcessed(usersProcessed, totalDecayApplied);
    }
    
    // ==================== VIEW ====================
    
    function checkDecayNeeded(address user) external view returns (bool needsDecay, uint32 daysSinceLastUpdate) {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();

        if (!rs.config.resourceDecayEnabled) return (false, 0);

        uint32 lastUpdate = rs.lastDecayUpdate[user];
        if (lastUpdate == 0) return (false, 0);

        uint32 currentTime = uint32(block.timestamp);
        // Handle corrupted future timestamp
        if (currentTime <= lastUpdate) return (false, 0);

        uint32 timePassed = currentTime - lastUpdate;
        daysSinceLastUpdate = timePassed / 86400;
        needsDecay = timePassed >= 86400;
    }
    
    /**
     * @notice Estimate decay using SQRT formula
     * @dev Uses same formula as LibResourceStorage.applyResourceDecay:
     *      decayAmount = sqrt(currentAmount) * rate * days / 100
     */
    function estimateDecay(address user) external view returns (uint256[4] memory estimatedDecay) {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();

        if (!rs.config.resourceDecayEnabled || rs.config.baseResourceDecayRate == 0) {
            return estimatedDecay;
        }

        uint32 lastUpdate = rs.lastDecayUpdate[user];
        if (lastUpdate == 0) return estimatedDecay;

        uint32 currentTime = uint32(block.timestamp);
        // Handle corrupted future timestamp
        if (currentTime <= lastUpdate) return estimatedDecay;

        uint32 timePassed = currentTime - lastUpdate;
        if (timePassed < 86400) return estimatedDecay;

        uint32 daysPassed = timePassed / 86400;

        for (uint8 i = 0; i < 4; i++) {
            uint256 currentAmount = rs.userResources[user][i];
            if (currentAmount > 0) {
                // SQRT-based decay formula (same as LibResourceStorage)
                uint256 sqrtAmount = Math.sqrt(currentAmount);
                uint256 decayAmount = (sqrtAmount * rs.config.baseResourceDecayRate * daysPassed) / 100;

                // Minimum decay of 1
                if (decayAmount == 0 && currentAmount > 0) {
                    decayAmount = 1;
                }

                estimatedDecay[i] = decayAmount > currentAmount ? currentAmount : decayAmount;
            }
        }
    }
    
    function getDecayConfig() external view returns (bool enabled, uint16 baseRate) {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        return (rs.config.resourceDecayEnabled, rs.config.baseResourceDecayRate);
    }
    
    function getLastDecayUpdate(address user) external view returns (uint32 lastUpdate, uint32 timeSince) {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        lastUpdate = rs.lastDecayUpdate[user];
        uint32 currentTime = uint32(block.timestamp);
        // Handle corrupted future timestamp - return 0 for timeSince
        if (lastUpdate > 0 && currentTime > lastUpdate) {
            timeSince = currentTime - lastUpdate;
        }
    }
}
