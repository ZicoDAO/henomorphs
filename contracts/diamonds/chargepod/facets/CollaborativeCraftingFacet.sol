// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibMeta} from "../../shared/libraries/LibMeta.sol";
import {LibResourceStorage} from "../libraries/LibResourceStorage.sol";
import {LibColonyWarsStorage} from "../libraries/LibColonyWarsStorage.sol";
import {LibFeeCollection} from "../../staking/libraries/LibFeeCollection.sol";
import {AccessControlBase} from "../../common/facets/AccessControlBase.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LibAchievementTrigger} from "../libraries/LibAchievementTrigger.sol";
import {IResourcePodFacet} from "../../staking/interfaces/IStakingInterfaces.sol";

/**
 * @notice Colony authorization interface
 */
interface IColonyAuthorization {
    function isColonyMember(bytes32 colonyId, address user) external view returns (bool);
}

/**
 * @notice Reward collection NFT interface (IRewardRedeemable compatible)
 */
interface IRewardRedeemable {
    function mintReward(uint256 collectionId, uint256 tierId, address to, uint256 amount) external returns (uint256 tokenId);
    function canMintReward(uint256 collectionId, uint256 tierId, uint256 amount) external view returns (bool);
}

/**
 * @notice Interface for mintable reward token (YLW)
 */
interface IRewardToken is IERC20 {
    function mint(address to, uint256 amount, string calldata reason) external;
}

/**
 * @title CollaborativeCraftingFacet
 * @notice Manages multi-user collaborative crafting projects
 * @dev Focuses on project lifecycle, contribution tracking, and reward distribution
 *      Uses generic token naming (governanceToken, utilityToken, paymentToken)
 */
contract CollaborativeCraftingFacet is AccessControlBase {
    
    // ==================== EVENTS ====================
    
    event ProjectCreated(bytes32 indexed projectId, bytes32 indexed colonyId, uint8 projectType, address initiator);
    event ResourceContributed(bytes32 indexed projectId, address indexed contributor, uint8 resourceType, uint256 amount);
    event PaymentContributed(bytes32 indexed projectId, address indexed contributor, uint256 amount);
    event ProjectCompleted(bytes32 indexed projectId, uint256 totalContributors, uint256 totalPaymentCollected);
    event ProjectCancelled(bytes32 indexed projectId, address canceller);
    event ProjectDeadlineExtended(bytes32 indexed projectId, uint32 newDeadline);
    event RewardDistributed(bytes32 indexed projectId, address indexed contributor, uint256 rewardAmount);
    
    // ==================== ERRORS ====================
    
    error ProjectNotFound(bytes32 projectId);
    error ProjectNotActive(bytes32 projectId);
    error ProjectAlreadyCompleted(bytes32 projectId);
    error ContributionPeriodEnded(bytes32 projectId);
    error InsufficientResources(uint8 resourceType, uint256 required, uint256 available);
    error InsufficientPermissions(address user, string action);
    error InvalidProjectType(uint8 projectType);
    error InvalidContributionAmount(uint256 amount);
    error RequirementNotMet(uint8 resourceType);
    error NoContributionToWithdraw(address user);
    
    // ==================== PROJECT CREATION ====================
    
    /**
     * @notice Create a new collaborative project
     * @param colonyId Colony initiating the project
     * @param projectType 1=Infrastructure, 2=Research, 3=Defense
     * @param resourceRequirements Array of required resources
     * @param paymentRequirement Payment token amount required from contributors
     * @param duration Project duration in seconds (0 = use default)
     * @return projectId Unique project identifier
     */
    function createProject(
        bytes32 colonyId,
        uint8 projectType,
        LibResourceStorage.ResourceRequirement[] calldata resourceRequirements,
        uint256 paymentRequirement,
        uint32 duration
    ) external whenNotPaused nonReentrant returns (bytes32 projectId) {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        address initiator = LibMeta.msgSender();
        
        // Validate project type
        if (projectType == 0 || projectType > 3) {
            revert InvalidProjectType(projectType);
        }
        
        // Validate requirements
        if (resourceRequirements.length == 0) {
            revert InvalidContributionAmount(0);
        }
        
        // Verify colony authorization
        if (!_hasColonyPermission(colonyId, initiator)) {
            revert InsufficientPermissions(initiator, "create project");
        }
        
        // Pay crafting fee (YELLOW with burn mechanism)
        LibColonyWarsStorage.OperationFee storage craftingFee = LibColonyWarsStorage.getOperationFee(LibColonyWarsStorage.FEE_CRAFTING);
        if (craftingFee.enabled) {
            LibFeeCollection.processConfiguredFee(
                craftingFee,
                initiator,
                "collaborative_crafting_creation"
            );
        }
        
        // Generate unique project ID
        projectId = keccak256(
            abi.encodePacked(
                colonyId,
                projectType,
                block.timestamp,
                initiator,
                resourceRequirements.length
            )
        );
        
        // Set project duration
        uint32 projectDuration = duration > 0 ? duration : rs.config.defaultProjectDuration;
        
        // Create project
        LibResourceStorage.CollaborativeProject storage project = rs.collaborativeProjects[projectId];
        project.colonyId = colonyId;
        project.projectType = projectType;
        project.initiator = initiator;
        project.deadline = uint32(block.timestamp) + projectDuration;
        project.paymentRequirement = paymentRequirement;
        project.status = LibResourceStorage.ProjectStatus.Active;
        
        // Store resource requirements
        for (uint256 i = 0; i < resourceRequirements.length; i++) {
            if (resourceRequirements[i].resourceType > 3) {
                revert InvalidContributionAmount(resourceRequirements[i].resourceType);
            }
            project.resourceRequirements.push(resourceRequirements[i]);
        }
        
        // Add to active projects
        rs.activeProjects.push(projectId);

        emit ProjectCreated(projectId, colonyId, projectType, initiator);

        // Trigger collaborative project achievement
        LibAchievementTrigger.triggerCollaborativeProject(initiator);

        return projectId;
    }
    
    // ==================== CONTRIBUTIONS ====================
    
    /**
     * @notice Contribute resources to a project
     * @param projectId Project to contribute to
     * @param resourceType Type of resource (0-3: Basic, Energy, Bio, Rare)
     * @param amount Amount to contribute
     */
    function contributeResources(
        bytes32 projectId,
        uint8 resourceType,
        uint256 amount
    ) external whenNotPaused nonReentrant {
        if (amount == 0) revert InvalidContributionAmount(0);
        if (resourceType > 3) revert InvalidContributionAmount(resourceType);
        
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        address contributor = LibMeta.msgSender();
        
        // Validate project
        LibResourceStorage.CollaborativeProject storage project = rs.collaborativeProjects[projectId];
        _validateActiveProject(project, projectId);
        
        // Apply resource decay before checking balance
        LibResourceStorage.applyResourceDecay(contributor);
        
        // Check contributor has sufficient resources
        uint256 available = rs.userResources[contributor][resourceType];
        if (available < amount) {
            revert InsufficientResources(resourceType, amount, available);
        }
        
        // Deduct resources from contributor
        rs.userResources[contributor][resourceType] -= amount;
        
        // Track contribution
        rs.projectContributions[projectId][contributor][resourceType] += amount;
        project.totalContributions[resourceType] += amount;
        
        // Add to contributors list if first contribution
        _addContributorIfNew(project, contributor);

        emit ResourceContributed(projectId, contributor, resourceType, amount);

        // Trigger contribution achievement
        LibAchievementTrigger.triggerContribution(contributor);

        // Check if project can be completed
        _checkAndCompleteProject(projectId, project, rs);
    }
    
    /**
     * @notice Contribute payment tokens to a project
     * @param projectId Project to contribute to
     * @param amount Amount of payment tokens
     */
    function contributePayment(
        bytes32 projectId,
        uint256 amount
    ) external whenNotPaused nonReentrant {
        if (amount == 0) revert InvalidContributionAmount(0);

        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        address contributor = LibMeta.msgSender();

        // Validate project
        LibResourceStorage.CollaborativeProject storage project = rs.collaborativeProjects[projectId];
        _validateActiveProject(project, projectId);

        // Check payment requirement exists
        if (project.paymentRequirement == 0) {
            revert InvalidContributionAmount(amount);
        }

        // Transfer project payment from contributor to treasury
        LibFeeCollection.collectFee(
            IERC20(rs.config.utilityToken),
            contributor,
            rs.config.paymentBeneficiary,
            amount,
            "crafting_project_payment"
        );

        // Track payment contribution (v4 storage)
        rs.projectPaymentContributions[projectId][contributor] += amount;
        rs.projectTotalPaymentContributed[projectId] += amount;

        emit PaymentContributed(projectId, contributor, amount);

        // Add to contributors list if first contribution
        _addContributorIfNew(project, contributor);

        // Check if project can be completed (including payment requirement)
        _checkAndCompleteProject(projectId, project, rs);
    }
    
    /**
     * @notice Contribute multiple resource types in one transaction
     * @param projectId Project to contribute to
     * @param resourceTypes Array of resource types
     * @param amounts Array of amounts (must match resourceTypes length)
     */
    function contributeResourceBatch(
        bytes32 projectId,
        uint8[] calldata resourceTypes,
        uint256[] calldata amounts
    ) external whenNotPaused nonReentrant {
        if (resourceTypes.length != amounts.length) {
            revert InvalidContributionAmount(0);
        }
        if (resourceTypes.length == 0) {
            revert InvalidContributionAmount(0);
        }
        
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        address contributor = LibMeta.msgSender();
        
        // Validate project once
        LibResourceStorage.CollaborativeProject storage project = rs.collaborativeProjects[projectId];
        _validateActiveProject(project, projectId);
        
        // Apply resource decay once
        LibResourceStorage.applyResourceDecay(contributor);
        
        // Process all contributions
        for (uint256 i = 0; i < resourceTypes.length; i++) {
            uint8 resourceType = resourceTypes[i];
            uint256 amount = amounts[i];
            
            if (amount == 0) continue;
            if (resourceType > 3) revert InvalidContributionAmount(resourceType);
            
            // Check and deduct resources
            uint256 available = rs.userResources[contributor][resourceType];
            if (available < amount) {
                revert InsufficientResources(resourceType, amount, available);
            }
            
            rs.userResources[contributor][resourceType] -= amount;
            
            // Track contribution
            rs.projectContributions[projectId][contributor][resourceType] += amount;
            project.totalContributions[resourceType] += amount;
            
            emit ResourceContributed(projectId, contributor, resourceType, amount);
        }
        
        // Add to contributors list if first contribution
        _addContributorIfNew(project, contributor);

        // Trigger contribution achievement (v4 fix - was missing in batch)
        LibAchievementTrigger.triggerContribution(contributor);

        // Check if project can be completed
        _checkAndCompleteProject(projectId, project, rs);
    }

    // ==================== PROJECT MANAGEMENT ====================
    
    /**
     * @notice Cancel an active project (only initiator or authorized)
     * @param projectId Project to cancel
     */
    function cancelProject(bytes32 projectId) external whenNotPaused nonReentrant {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        address caller = LibMeta.msgSender();
        
        LibResourceStorage.CollaborativeProject storage project = rs.collaborativeProjects[projectId];
        
        if (project.initiator == address(0)) {
            revert ProjectNotFound(projectId);
        }
        if (project.status != LibResourceStorage.ProjectStatus.Active) {
            revert ProjectNotActive(projectId);
        }
        
        // Only initiator or authorized users can cancel
        if (caller != project.initiator && !_hasColonyPermission(project.colonyId, caller)) {
            revert InsufficientPermissions(caller, "cancel project");
        }
        
        // Update status
        project.status = LibResourceStorage.ProjectStatus.Cancelled;
        
        emit ProjectCancelled(projectId, caller);
        
        // Note: Resources are NOT refunded - contributors must withdraw manually
        // This prevents griefing and gas issues with automatic refunds
    }
    
    /**
     * @notice Extend project deadline (only initiator or authorized)
     * @param projectId Project to extend
     * @param additionalTime Additional seconds to add
     */
    function extendDeadline(
        bytes32 projectId,
        uint32 additionalTime
    ) external whenNotPaused nonReentrant {
        if (additionalTime == 0) revert InvalidContributionAmount(0);
        
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        address caller = LibMeta.msgSender();
        
        LibResourceStorage.CollaborativeProject storage project = rs.collaborativeProjects[projectId];
        
        if (project.initiator == address(0)) {
            revert ProjectNotFound(projectId);
        }
        if (project.status != LibResourceStorage.ProjectStatus.Active) {
            revert ProjectNotActive(projectId);
        }
        
        // Only initiator or authorized users can extend
        if (caller != project.initiator && !_hasColonyPermission(project.colonyId, caller)) {
            revert InsufficientPermissions(caller, "extend deadline");
        }
        
        // Extend deadline
        project.deadline += additionalTime;
        
        emit ProjectDeadlineExtended(projectId, project.deadline);
    }
    
    /**
     * @notice Withdraw contributed resources from cancelled project
     * @param projectId Project to withdraw from
     * @param resourceType Resource type to withdraw (0-3)
     */
    function withdrawFromCancelled(
        bytes32 projectId,
        uint8 resourceType
    ) external whenNotPaused nonReentrant {
        if (resourceType > 3) revert InvalidContributionAmount(resourceType);
        
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        address contributor = LibMeta.msgSender();
        
        LibResourceStorage.CollaborativeProject storage project = rs.collaborativeProjects[projectId];
        
        if (project.initiator == address(0)) {
            revert ProjectNotFound(projectId);
        }
        if (project.status != LibResourceStorage.ProjectStatus.Cancelled) {
            revert ProjectNotActive(projectId);
        }
        
        // Get contribution amount
        uint256 contribution = rs.projectContributions[projectId][contributor][resourceType];
        if (contribution == 0) {
            revert NoContributionToWithdraw(contributor);
        }

        // Clear contribution
        rs.projectContributions[projectId][contributor][resourceType] = 0;

        // Refund via centralized ResourcePodFacet for consistent event tracking
        try IResourcePodFacet(address(this)).awardResourcesDirect(
            contributor,
            resourceType,
            contribution
        ) {} catch {
            // Fallback to direct storage if ResourcePodFacet call fails
            LibResourceStorage.applyResourceDecay(contributor);
            rs.userResources[contributor][resourceType] += contribution;
        }
    }
    
    // ==================== VIEW FUNCTIONS ====================
    
    /**
     * @notice Get detailed project information including payment tracking
     * @param projectId Project identifier
     * @return colonyId Colony that owns this project
     * @return projectType Type of project (1=Infrastructure, 2=Research, 3=Defense)
     * @return initiator Address that created the project
     * @return deadline Unix timestamp when contributions close
     * @return paymentRequirement Required payment token amount
     * @return totalPaymentContributed Actual payment contributed so far (v4)
     * @return status Current project status
     * @return contributorCount Number of unique contributors
     * @return requirements Array of resource requirements
     * @return totalContributions Resources contributed by type [Basic, Energy, Bio, Rare]
     */
    function getProjectDetails(bytes32 projectId) external view returns (
        bytes32 colonyId,
        uint8 projectType,
        address initiator,
        uint32 deadline,
        uint256 paymentRequirement,
        uint256 totalPaymentContributed,
        LibResourceStorage.ProjectStatus status,
        uint256 contributorCount,
        LibResourceStorage.ResourceRequirement[] memory requirements,
        uint256[4] memory totalContributions
    ) {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        LibResourceStorage.CollaborativeProject storage project = rs.collaborativeProjects[projectId];

        if (project.initiator == address(0)) {
            revert ProjectNotFound(projectId);
        }

        // Use named returns to avoid stack too deep
        colonyId = project.colonyId;
        projectType = project.projectType;
        initiator = project.initiator;
        deadline = project.deadline;
        paymentRequirement = project.paymentRequirement;
        totalPaymentContributed = rs.projectTotalPaymentContributed[projectId];
        status = project.status;
        contributorCount = project.contributors.length;
        requirements = project.resourceRequirements;
        totalContributions = project.totalContributions;
    }

    /**
     * @notice Get project payment status (v4)
     * @param projectId Project identifier
     * @return paymentRequirement Required payment token amount
     * @return totalPaymentContributed Actual payment contributed so far
     * @return isPaymentMet Whether payment requirement is fulfilled
     */
    function getProjectPaymentStatus(bytes32 projectId) external view returns (
        uint256 paymentRequirement,
        uint256 totalPaymentContributed,
        bool isPaymentMet
    ) {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        LibResourceStorage.CollaborativeProject storage project = rs.collaborativeProjects[projectId];

        if (project.initiator == address(0)) {
            revert ProjectNotFound(projectId);
        }

        paymentRequirement = project.paymentRequirement;
        totalPaymentContributed = rs.projectTotalPaymentContributed[projectId];
        isPaymentMet = paymentRequirement == 0 || totalPaymentContributed >= paymentRequirement;

        return (paymentRequirement, totalPaymentContributed, isPaymentMet);
    }
    
    /**
     * @notice Get user's contributions to a project (resources + payment)
     * @param projectId Project identifier
     * @param user User address
     * @return resourceContributions Resources contributed by type [Basic, Energy, Bio, Rare]
     * @return paymentContribution Payment tokens contributed (v4)
     */
    function getUserProjectContributions(
        bytes32 projectId,
        address user
    ) external view returns (
        uint256[4] memory resourceContributions,
        uint256 paymentContribution
    ) {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();

        for (uint8 i = 0; i < 4; i++) {
            resourceContributions[i] = rs.projectContributions[projectId][user][i];
        }
        paymentContribution = rs.projectPaymentContributions[projectId][user];

        return (resourceContributions, paymentContribution);
    }
    
    /**
     * @notice Get list of all project contributors
     */
    function getProjectContributors(bytes32 projectId) external view returns (address[] memory) {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        return rs.collaborativeProjects[projectId].contributors;
    }

    /**
     * @notice Get project progress percentage for each resource
     */
    function getProjectProgress(bytes32 projectId) external view returns (
        uint16[4] memory progressPercentages
    ) {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        LibResourceStorage.CollaborativeProject storage project = rs.collaborativeProjects[projectId]; 
        
        for (uint256 i = 0; i < project.resourceRequirements.length; i++) {
            uint8 resourceType = project.resourceRequirements[i].resourceType;
            uint256 required = project.resourceRequirements[i].amount;
            uint256 contributed = project.totalContributions[resourceType];
            
            if (required > 0) {
                progressPercentages[resourceType] = uint16((contributed * 100) / required);
                if (progressPercentages[resourceType] > 100) {
                    progressPercentages[resourceType] = 100;
                }
            }
        }
        
        return progressPercentages;
    }
    
    /**
     * @notice Get all active projects
     */
    function getActiveProjects() external view returns (bytes32[] memory) {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        
        // Filter for active projects only
        uint256 activeCount = 0;
        for (uint256 i = 0; i < rs.activeProjects.length; i++) {
            if (rs.collaborativeProjects[rs.activeProjects[i]].status == LibResourceStorage.ProjectStatus.Active) {
                activeCount++;
            }
        }
        
        bytes32[] memory active = new bytes32[](activeCount);
        uint256 index = 0;
        for (uint256 i = 0; i < rs.activeProjects.length; i++) {
            if (rs.collaborativeProjects[rs.activeProjects[i]].status == LibResourceStorage.ProjectStatus.Active) {
                active[index] = rs.activeProjects[i];
                index++;
            }
        }
        
        return active;
    }
    
    // ==================== INTERNAL FUNCTIONS ====================
    
    /**
     * @notice Validate project is active and not expired
     */
    function _validateActiveProject(
        LibResourceStorage.CollaborativeProject storage project,
        bytes32 projectId
    ) internal view {
        if (project.initiator == address(0)) {
            revert ProjectNotFound(projectId);
        }
        if (project.status != LibResourceStorage.ProjectStatus.Active) {
            revert ProjectNotActive(projectId);
        }
        if (block.timestamp > project.deadline) {
            revert ContributionPeriodEnded(projectId);
        }
    }
    
    /**
     * @notice Add contributor to list if not already present
     */
    function _addContributorIfNew(
        LibResourceStorage.CollaborativeProject storage project,
        address contributor
    ) internal {
        // Check if already a contributor
        for (uint256 i = 0; i < project.contributors.length; i++) {
            if (project.contributors[i] == contributor) {
                return;
            }
        }
        
        // Add new contributor
        project.contributors.push(contributor);
    }
    
    /**
     * @notice Check if all requirements are met (resources AND payment)
     * @param projectId Project identifier (needed for payment tracking lookup)
     * @param project Project storage reference
     */
    function _checkRequirementsMet(
        bytes32 projectId,
        LibResourceStorage.CollaborativeProject storage project
    ) internal view returns (bool) {
        // Check resource requirements
        for (uint256 i = 0; i < project.resourceRequirements.length; i++) {
            uint8 resourceType = project.resourceRequirements[i].resourceType;
            uint256 required = project.resourceRequirements[i].amount;

            if (project.totalContributions[resourceType] < required) {
                return false;
            }
        }

        // Check payment requirement (v4 - payment tracking)
        if (project.paymentRequirement > 0) {
            LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
            if (rs.projectTotalPaymentContributed[projectId] < project.paymentRequirement) {
                return false;
            }
        }

        return true;
    }
    
    /**
     * @notice Check if project is complete and update status
     */
    function _checkAndCompleteProject(
        bytes32 projectId,
        LibResourceStorage.CollaborativeProject storage project,
        LibResourceStorage.ResourceStorage storage rs
    ) internal {
        if (!_checkRequirementsMet(projectId, project)) {
            return;
        }
        
        // Mark as completed
        project.status = LibResourceStorage.ProjectStatus.Completed;
        
        // Distribute rewards
        _distributeProjectRewards(projectId, project, rs);
        
        // Update stats
        unchecked {
            rs.totalProjectsCompleted += 1;
        }
        
        emit ProjectCompleted(projectId, project.contributors.length, 0);
    }
    
    /**
     * @notice Distribute infrastructure bonuses to colony
     */
    function _distributeProjectRewards(
        bytes32 projectId,
        LibResourceStorage.CollaborativeProject storage project,
        LibResourceStorage.ResourceStorage storage rs
    ) internal {
        // Update colony infrastructure based on project type
        if (project.projectType == 1) {
            // Infrastructure project -> Processing Facility
            rs.colonyInfrastructure[project.colonyId][0] += 1;
        } else if (project.projectType == 2) {
            // Research project -> Research Lab
            rs.colonyInfrastructure[project.colonyId][1] += 1;
        } else if (project.projectType == 3) {
            // Defense project -> Defense Structure
            rs.colonyInfrastructure[project.colonyId][2] += 1;
        }
        
        // Mint NFT rewards to contributors
        if (rs.config.rewardCollectionAddress != address(0)) {
            _mintCollaborativeRewards(projectId, project, rs);
        }
        
        // Distribute reward tokens proportionally
        if (rs.config.primaryRewardToken != address(0)) {
            _distributeRewardTokens(projectId, project, rs);
        }
    }
    
    /**
     * @notice Mint NFT rewards to project contributors
     */
    function _mintCollaborativeRewards(
        bytes32 projectId,
        LibResourceStorage.CollaborativeProject storage project,
        LibResourceStorage.ResourceStorage storage rs
    ) internal {
        uint256 totalContributions = 0;
        
        // Calculate total contribution value
        for (uint8 i = 0; i < 4; i++) {
            totalContributions += project.totalContributions[i];
        }
        
        // Reward contributors based on contribution percentage
        // Tier: 1=Bronze (10%+), 2=Silver (25%+), 3=Gold (50%+), 4=Platinum (top contributor)
        uint256 avgContribution = totalContributions / project.contributors.length;
        uint256 topContribution = 0;

        // Find top contributor
        for (uint256 i = 0; i < project.contributors.length; i++) {
            address contributor = project.contributors[i];
            uint256 contributorValue = 0;
            for (uint8 resType = 0; resType < 4; resType++) {
                contributorValue += rs.projectContributions[projectId][contributor][resType];
            }
            if (contributorValue > topContribution) {
                topContribution = contributorValue;
            }
        }

        // Mint rewards with appropriate tier
        for (uint256 i = 0; i < project.contributors.length; i++) {
            address contributor = project.contributors[i];
            uint256 contributorValue = 0;

            for (uint8 resType = 0; resType < 4; resType++) {
                contributorValue += rs.projectContributions[projectId][contributor][resType];
            }

            // Determine tier based on contribution
            uint256 tierId;
            if (contributorValue == topContribution && topContribution > 0) {
                tierId = 4; // Platinum - top contributor
            } else if (contributorValue >= avgContribution * 2) {
                tierId = 3; // Gold - 50%+ above average
            } else if (contributorValue >= avgContribution) {
                tierId = 2; // Silver - above average
            } else if (contributorValue >= avgContribution / 2) {
                tierId = 1; // Bronze - at least 50% of average
            } else {
                continue; // No reward for minimal contribution
            }

            // achievementId = projectType (1=Infrastructure, 2=Research, 3=Defense)
            try IRewardRedeemable(rs.config.rewardCollectionAddress).mintReward(
                project.projectType,  // collectionId/achievementId
                tierId,               // tier (1-4)
                contributor,          // to
                1                     // amount (1 achievement NFT)
            ) {} catch {}
        }
    }
    
    /**
     * @notice Distribute reward tokens to contributors proportionally
     * @dev Uses Treasury â†’ Mint fallback pattern for sustainable token distribution
     */
    function _distributeRewardTokens(
        bytes32 projectId,
        LibResourceStorage.CollaborativeProject storage project,
        LibResourceStorage.ResourceStorage storage rs
    ) internal {
        uint256 totalRewardPool = project.paymentRequirement * project.contributors.length;
        uint256 totalContributions = 0;
        
        // Calculate total contribution weight
        for (uint8 i = 0; i < 4; i++) {
            totalContributions += project.totalContributions[i];
        }
        
        if (totalContributions == 0) return;
        
        // Distribute rewards proportionally
        for (uint256 i = 0; i < project.contributors.length; i++) {
            address contributor = project.contributors[i];
            uint256 contributorValue = 0;
            
            for (uint8 resType = 0; resType < 4; resType++) {
                contributorValue += rs.projectContributions[projectId][contributor][resType];
            }
            
            uint256 rewardAmount = (totalRewardPool * contributorValue) / totalContributions;
            
            if (rewardAmount > 0) {
                // Use Treasury â†’ Mint fallback pattern
                _distributeYlwReward(rs.config.primaryRewardToken, rs.config.paymentBeneficiary, contributor, rewardAmount);
                emit RewardDistributed(projectId, contributor, rewardAmount);
            }
        }
    }
    
    /**
     * @notice Distribute YLW reward with Treasury â†’ Mint fallback
     * @dev Priority: 1) Transfer from treasury, 2) Mint if treasury insufficient
     * @param rewardToken YLW token address
     * @param treasury Treasury address
     * @param recipient User receiving the reward
     * @param amount Amount to distribute
     */
    function _distributeYlwReward(
        address rewardToken,
        address treasury,
        address recipient,
        uint256 amount
    ) internal {
        // Check treasury balance and allowance
        uint256 treasuryBalance = IERC20(rewardToken).balanceOf(treasury);
        uint256 allowance = IERC20(rewardToken).allowance(treasury, address(this));
        
        if (treasuryBalance >= amount && allowance >= amount) {
            // Pay from treasury (preferred - sustainable) using LibFeeCollection
            LibFeeCollection.transferFromTreasury(recipient, amount, "crafting_reward");
        } else if (treasuryBalance > 0 && allowance > 0) {
            // Partial from treasury, rest from mint
            uint256 fromTreasury = treasuryBalance < allowance ? treasuryBalance : allowance;
            LibFeeCollection.transferFromTreasury(recipient, fromTreasury, "crafting_reward_partial");
            
            uint256 shortfall = amount - fromTreasury;
            IRewardToken(rewardToken).mint(recipient, shortfall, "crafting_reward");
        } else {
            // Fallback: Mint new tokens
            IRewardToken(rewardToken).mint(recipient, amount, "crafting_reward");
        }
    }
    
    /**
     * @notice Check if user has colony permission
     */
    function _hasColonyPermission(bytes32 colonyId, address user) internal view returns (bool) {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        
        // Delegate to colony authorization if configured
        if (rs.config.colonyFacetAddress != address(0)) {
            try IColonyAuthorization(rs.config.colonyFacetAddress).isColonyMember(colonyId, user) returns (bool isMember) {
                return isMember;
            } catch {}
        }
        
        // Fallback: allow all if no colony system
        return true;
    }
    
    // ==================== ADDITIONAL VIEW FUNCTIONS ====================

    /**
     * @notice Get user's resource contribution to a project (legacy)
     * @dev Kept for backward compatibility - returns only resources, not payment
     *      Use getUserContributions() for full data including payment
     */
    function getUserProjectContribution(
        bytes32 projectId,
        address user
    ) external view returns (uint256[4] memory contributions) {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        for (uint8 i = 0; i < 4; i++) {
            contributions[i] = rs.projectContributions[projectId][user][i];
        }
        return contributions;
    }


    /**
     * @notice Get project requirements
     */
    function getProjectRequirements(bytes32 projectId) external view returns (
        LibResourceStorage.ResourceRequirement[] memory requirements
    ) {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        LibResourceStorage.CollaborativeProject storage project = rs.collaborativeProjects[projectId];
        
        if (project.initiator == address(0)) {
            revert ProjectNotFound(projectId);
        }
        
        return project.resourceRequirements;
    }
    
    /**
     * @notice Check if project requirements are met
     */
    function isProjectComplete(bytes32 projectId) external view returns (bool) {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        LibResourceStorage.CollaborativeProject storage project = rs.collaborativeProjects[projectId];

        if (project.initiator == address(0)) {
            revert ProjectNotFound(projectId);
        }

        return _checkRequirementsMet(projectId, project);
    }
    
    /**
     * @notice Get collaborative crafting statistics
     */
    function getCraftingStatistics() external view returns (
        uint256 totalProjectsCompleted,
        uint256 totalResourcesGenerated,
        uint256 totalInfrastructureBuilt,
        uint256 activeProjectsCount
    ) {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        
        return (
            rs.totalProjectsCompleted,
            rs.totalResourcesGenerated,
            rs.totalInfrastructureBuilt,
            rs.activeProjects.length
        );
    }
}
