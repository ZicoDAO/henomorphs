// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibMeta} from "../../shared/libraries/LibMeta.sol";
import {LibColonyWarsStorage} from "../libraries/LibColonyWarsStorage.sol";
import {LibHenomorphsStorage} from "../libraries/LibHenomorphsStorage.sol";
import {LibFeeCollection} from "../../staking/libraries/LibFeeCollection.sol";
import {AccessControlBase} from "../../common/facets/AccessControlBase.sol";
import {ColonyHelper} from "../../staking/libraries/ColonyHelper.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AccessHelper} from "../../staking/libraries/AccessHelper.sol";

/**
 * @title ColonyWarsRegistrationFacet
 * @notice Handles colony registration, pre-registration, and stake management for Colony Wars
 * @dev Split from ColonyWarsFacet to separate registration logic from battle logic
 */
contract ColonyWarsRegistrationFacet is AccessControlBase {

    // ============ EVENTS ============

    event ColonyRegisteredForSeason(bytes32 indexed colonyId, uint32 indexed seasonId);
    event ColonyUnregisteredFromSeason(
        bytes32 indexed colonyId,
        uint32 indexed seasonId,
        uint256 refundAmount,
        uint256 penaltyAmount
    );
    event StakeChanged(bytes32 indexed colonyId, uint256 newTotal, bool increased, uint256 amount);
    event ColonyPreRegistered(bytes32 indexed colonyId, uint32 indexed targetSeasonId, uint256 stake, address owner);
    event PreRegistrationCancelled(bytes32 indexed colonyId, uint32 indexed targetSeasonId, uint256 refundAmount);
    event PreRegistrationsActivated(uint32 indexed seasonId, uint256 activatedCount, uint256 totalProcessed);

    // ============ ERRORS ============

    error InvalidStake();
    error SeasonNotActive();
    error RegistrationClosed();
    error ColonyNotRegistered();
    error CannotUnregisterDuringBattle();
    error UnregistrationNotAllowed();
    error RateLimitExceeded();
    error InvalidBattleState();
    error PreRegistrationClosed();
    error PreRegistrationNotFound();
    error AlreadyPreRegistered();
    error SeasonNotScheduled();
    error PreRegistrationAlreadyProcessed();

    // ============ MODIFIERS ============

    /**
     * @dev Verifies caller is the creator of the specified colony
     */
    modifier onlyColonyCreator(bytes32 colonyId) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        if (!ColonyHelper.isColonyCreator(colonyId, hs.stakingSystemAddress)) {
            revert AccessHelper.Unauthorized(LibMeta.msgSender(), "Not colony creator");
        }
        _;
    }

    /**
     * @dev Verifies current season is in registration period
     */
    modifier duringRegistrationPeriod() {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibColonyWarsStorage.Season storage season = cws.seasons[cws.currentSeason];
        if (!season.active || block.timestamp < season.startTime || block.timestamp > season.registrationEnd) {
            revert RegistrationClosed();
        }
        _;
    }

    // ============ REGISTRATION FUNCTIONS ============

    /**
     * @notice Register colony for current warfare season
     * @param colonyId Colony identifier to register
     * @param stake ZICO amount to stake for defensive purposes
     */
    function registerForSeason(bytes32 colonyId, uint256 stake)
        external
        whenNotPaused
        nonReentrant
        onlyColonyCreator(colonyId)
        duringRegistrationPeriod
    {
        LibColonyWarsStorage.requireInitialized();
        LibColonyWarsStorage.requireFeatureNotPaused("registration");

        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();

        // Rate limiting
        if (!LibColonyWarsStorage.checkRateLimit(LibMeta.msgSender(), this.registerForSeason.selector, 3600)) {
            revert RateLimitExceeded();
        }

        uint32 currentSeason = cws.currentSeason;
        LibColonyWarsStorage.Season storage season = cws.seasons[currentSeason];

        // Prevent duplicate registrations
        if (cws.colonyWarProfiles[colonyId].registered) {
            revert InvalidBattleState();
        }

        // Validate stake and collect
        _validateStakeAndCollect(stake, "season_registration", cws, hs);

        // Initialize profile, add to season tracking, track user
        _initializeColonyWarProfile(colonyId, stake, currentSeason, cws);
        _addToSeasonTracking(colonyId, stake, currentSeason, season);
        _trackUserColony(colonyId, LibMeta.msgSender(), currentSeason, cws);

        emit ColonyRegisteredForSeason(colonyId, currentSeason);
    }

    /**
     * @notice Unregister colony from current season with refund
     * @param colonyId Colony to unregister
     */
    function unregisterFromSeason(bytes32 colonyId)
        external
        whenNotPaused
        nonReentrant
        onlyColonyCreator(colonyId)
    {
        LibColonyWarsStorage.requireInitialized();
        LibColonyWarsStorage.requireFeatureNotPaused("registration");

        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();

        // Rate limiting - once per hour to prevent spam
        if (!LibColonyWarsStorage.checkRateLimit(LibMeta.msgSender(), this.unregisterFromSeason.selector, 3600)) {
            revert RateLimitExceeded();
        }

        uint32 currentSeason = cws.currentSeason;
        LibColonyWarsStorage.Season storage season = cws.seasons[currentSeason];
        LibColonyWarsStorage.ColonyWarProfile storage profile = cws.colonyWarProfiles[colonyId];

        // Verify colony is registered
        if (!profile.registered) {
            revert ColonyNotRegistered();
        }

        // Check if unregistration is allowed (only during registration period or early warfare)
        uint32 unregistrationDeadline = season.registrationEnd + 3 days; // 3 days grace period
        if (block.timestamp > unregistrationDeadline) {
            revert UnregistrationNotAllowed();
        }

        // Check if colony has active battles - use library function
        if (LibColonyWarsStorage.hasActiveBattles(colonyId, currentSeason)) {
            revert CannotUnregisterDuringBattle();
        }

        // Check if colony is in alliance - require leaving first
        if (LibColonyWarsStorage.isUserInAlliance(LibMeta.msgSender())) {
            bytes32 _userPrimary = LibColonyWarsStorage.getUserPrimaryColony(LibMeta.msgSender());
            if (_userPrimary == colonyId) {
                revert InvalidBattleState(); // Cannot unregister primary colony while in alliance
            }
        }

        // Calculate refund with penalty
        uint256 originalStake = profile.defensiveStake;
        uint256 penalty = _calculateUnregistrationPenalty(originalStake, season, block.timestamp);
        uint256 refundAmount = originalStake - penalty;

        // Remove from season tracking and reset profile
        _removeColonyFromSeason(colonyId, currentSeason, cws);
        _resetColonyWarProfile(colonyId, cws);

        // Remove from user's primary colony if it was primary
        bytes32 userPrimary = LibColonyWarsStorage.getUserPrimaryColony(LibMeta.msgSender());
        if (userPrimary == colonyId) {
            // Set new primary from remaining colonies
            bytes32[] memory userColonies = LibColonyWarsStorage.getUserSeasonColonies(currentSeason, LibMeta.msgSender());
            bytes32 newPrimary = bytes32(0);

            for (uint256 i = 0; i < userColonies.length; i++) {
                if (userColonies[i] != colonyId && cws.colonyWarProfiles[userColonies[i]].registered) {
                    newPrimary = userColonies[i];
                    break;
                }
            }

            LibColonyWarsStorage.setUserPrimaryColony(LibMeta.msgSender(), newPrimary);
            cws.userToColony[LibMeta.msgSender()] = newPrimary;
        }

        // Remove from user's season colonies array
        _removeFromUserSeasonColonies(colonyId, currentSeason, LibMeta.msgSender(), cws);

        // Process refund
        if (refundAmount > 0) {
            LibFeeCollection.transferFromTreasury(
                LibMeta.msgSender(),
                refundAmount,
                "colony_unregistration_refund"
            );
        }

        // Penalty goes to season prize pool
        if (penalty > 0) {
            season.prizePool += penalty;
        }

        emit ColonyUnregisteredFromSeason(colonyId, currentSeason, refundAmount, penalty);
    }

    // ============ PRE-REGISTRATION FUNCTIONS ============

    /**
     * @notice Pre-register colony for an upcoming season before it starts
     * @dev Allows registration outside of active registration period
     * Pre-registrations are activated automatically when season registration period begins
     * @param colonyId Colony to pre-register
     * @param targetSeasonId Season ID to register for (must be scheduled but not yet started)
     * @param stake ZICO amount to stake for defensive purposes
     */
    function preRegisterForSeason(bytes32 colonyId, uint32 targetSeasonId, uint256 stake)
        external
        whenNotPaused
        nonReentrant
        onlyColonyCreator(colonyId)
    {
        LibColonyWarsStorage.requireInitialized();
        LibColonyWarsStorage.requireFeatureNotPaused("registration");

        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();

        // Rate limiting to prevent spam
        if (!LibColonyWarsStorage.checkRateLimit(LibMeta.msgSender(), this.preRegisterForSeason.selector, 3600)) {
            revert RateLimitExceeded();
        }

        // Validate pre-registration timing and eligibility
        _validatePreRegistrationTiming(targetSeasonId, cws);
        _validateNotAlreadyRegistered(colonyId, targetSeasonId, cws);

        // Validate stake and collect
        _validateStakeAndCollect(stake, "season_preregistration", cws, hs);

        // Store pre-registration record and finalize
        _storePreRegistration(colonyId, targetSeasonId, stake, cws);
    }

    /**
     * @notice Validate pre-registration timing requirements
     */
    function _validatePreRegistrationTiming(
        uint32 targetSeasonId,
        LibColonyWarsStorage.ColonyWarsStorage storage cws
    ) internal view {
        LibColonyWarsStorage.Season storage season = cws.seasons[targetSeasonId];

        if (season.startTime > 0) {
            // Scenario 1: Season is scheduled
            if (season.active && block.timestamp >= season.startTime && block.timestamp <= season.registrationEnd) {
                revert PreRegistrationClosed(); // Use registerForSeason instead
            }
            if (season.registrationEnd > 0 && block.timestamp > season.registrationEnd) {
                revert RegistrationClosed();
            }
            if (cws.preRegistrationWindow > 0) {
                uint32 preRegStart = season.startTime > cws.preRegistrationWindow
                    ? season.startTime - cws.preRegistrationWindow
                    : 0;
                if (block.timestamp < preRegStart) {
                    revert PreRegistrationClosed();
                }
            }
        } else {
            // Scenario 2: Season is NOT scheduled yet
            // Allow pre-registration for next season (currentSeason + 1) at any time
            // No requirement for current season to have ended
            if (targetSeasonId != cws.currentSeason + 1) {
                revert SeasonNotScheduled(); // Can only pre-register for next season
            }
            // Pre-registration is always open for unscheduled next season
        }
    }

    /**
     * @notice Validate colony is not already registered or pre-registered
     */
    function _validateNotAlreadyRegistered(
        bytes32 colonyId,
        uint32 targetSeasonId,
        LibColonyWarsStorage.ColonyWarsStorage storage cws
    ) internal view {
        LibColonyWarsStorage.PreRegistration storage existingPreReg = cws.preRegistrations[targetSeasonId][colonyId];
        if (existingPreReg.registeredAt > 0 && !existingPreReg.cancelled) {
            revert AlreadyPreRegistered();
        }

        if (cws.colonyWarProfiles[colonyId].registered) {
            LibColonyWarsStorage.Season storage season = cws.seasons[targetSeasonId];
            for (uint256 i = 0; i < season.registeredColonies.length; i++) {
                if (season.registeredColonies[i] == colonyId) {
                    revert AlreadyPreRegistered();
                }
            }
        }
    }

    /**
     * @notice Store pre-registration record and initialize profile
     */
    function _storePreRegistration(
        bytes32 colonyId,
        uint32 targetSeasonId,
        uint256 stake,
        LibColonyWarsStorage.ColonyWarsStorage storage cws
    ) internal {
        address owner = LibMeta.msgSender();

        cws.preRegistrations[targetSeasonId][colonyId] = LibColonyWarsStorage.PreRegistration({
            colonyId: colonyId,
            owner: owner,
            stake: stake,
            targetSeasonId: targetSeasonId,
            registeredAt: uint32(block.timestamp),
            activated: false,
            cancelled: false
        });
        cws.preRegisteredColonies[targetSeasonId].push(colonyId);

        _initializeColonyWarProfile(colonyId, stake, targetSeasonId, cws);
        _trackUserColony(colonyId, owner, targetSeasonId, cws);

        emit ColonyPreRegistered(colonyId, targetSeasonId, stake, owner);
    }

    /**
     * @notice Cancel pre-registration and receive full refund
     * @dev Can only cancel before season registration period starts
     * @param colonyId Colony to cancel pre-registration for
     * @param targetSeasonId Season ID the pre-registration was for
     */
    function cancelPreRegistration(bytes32 colonyId, uint32 targetSeasonId)
        external
        whenNotPaused
        nonReentrant
        onlyColonyCreator(colonyId)
    {
        LibColonyWarsStorage.requireInitialized();
        LibColonyWarsStorage.requireFeatureNotPaused("registration");

        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibColonyWarsStorage.PreRegistration storage preReg = cws.preRegistrations[targetSeasonId][colonyId];

        // Verify pre-registration exists and is not already processed
        if (preReg.registeredAt == 0) revert PreRegistrationNotFound();
        if (preReg.cancelled) revert PreRegistrationAlreadyProcessed();
        if (preReg.activated) revert PreRegistrationAlreadyProcessed();

        LibColonyWarsStorage.Season storage season = cws.seasons[targetSeasonId];

        // Can only cancel before season registration period starts
        // Once registration period starts, pre-registrations are activated
        if (season.active && block.timestamp >= season.startTime) {
            revert PreRegistrationClosed();
        }

        // Mark as cancelled and get refund amount
        preReg.cancelled = true;
        uint256 refundAmount = preReg.stake;

        // Reset profile and remove from tracking
        _resetColonyWarProfile(colonyId, cws);
        _removeFromUserSeasonColonies(colonyId, targetSeasonId, LibMeta.msgSender(), cws);

        // Full refund - no penalty for cancelling pre-registration
        if (refundAmount > 0) {
            LibFeeCollection.transferFromTreasury(LibMeta.msgSender(), refundAmount, "preregistration_refund");
        }

        emit PreRegistrationCancelled(colonyId, targetSeasonId, refundAmount);
    }

    /**
     * @notice Activate pre-registrations for a season (batch processing)
     * @dev Called automatically by startNewWarsSeason or manually by admin for large batches
     * Processes pre-registrations in batches to avoid gas limits
     * Only callable by admin, operators, or other diamond facets (inter-facet calls)
     * @param seasonId Season to activate pre-registrations for
     * @param batchSize Maximum number of pre-registrations to process (0 = process all)
     * @return activatedCount Number of pre-registrations successfully activated
     * @return remainingCount Number of pre-registrations still pending
     */
    function activatePreRegistrations(uint32 seasonId, uint256 batchSize)
        public
        whenNotPaused
        onlyTrusted
        returns (uint256 activatedCount, uint256 remainingCount)
    {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibColonyWarsStorage.Season storage season = cws.seasons[seasonId];

        // Season must be in registration period (active and within time bounds)
        // This allows activation when season starts registration period
        if (!season.active || block.timestamp < season.startTime) {
            revert SeasonNotActive();
        }

        bytes32[] storage colonies = cws.preRegisteredColonies[seasonId];
        uint256 startIndex = cws.preRegistrationProcessingIndex[seasonId];
        uint256 totalColonies = colonies.length;

        if (startIndex >= totalColonies) {
            return (0, 0); // All already processed
        }

        uint256 endIndex = batchSize == 0
            ? totalColonies
            : (startIndex + batchSize > totalColonies ? totalColonies : startIndex + batchSize);

        activatedCount = 0;

        for (uint256 i = startIndex; i < endIndex; i++) {
            bytes32 colonyId = colonies[i];
            LibColonyWarsStorage.PreRegistration storage preReg = cws.preRegistrations[seasonId][colonyId];

            // Skip if already processed (activated or cancelled)
            if (preReg.activated || preReg.cancelled) {
                continue;
            }

            // Activate the pre-registration
            _activatePreRegistration(colonyId, preReg, seasonId, season);
            preReg.activated = true;
            activatedCount++;
        }

        // Update processing index
        cws.preRegistrationProcessingIndex[seasonId] = endIndex;
        remainingCount = totalColonies - endIndex;

        emit PreRegistrationsActivated(seasonId, activatedCount, endIndex - startIndex);
    }

    // ============ STAKE MANAGEMENT FUNCTIONS ============

    /**
     * @notice Increase defensive stake for current season
     * @param colonyId Colony to increase stake for
     * @param additionalAmount ZICO amount to add to stake
     */
    function increaseDefensiveStake(bytes32 colonyId, uint256 additionalAmount)
        external
        whenNotPaused
        nonReentrant
        onlyColonyCreator(colonyId)
        duringRegistrationPeriod
    {
        LibColonyWarsStorage.requireInitialized();

        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        LibColonyWarsStorage.Season storage season = cws.seasons[cws.currentSeason];
        LibColonyWarsStorage.ColonyWarProfile storage profile = cws.colonyWarProfiles[colonyId];
        if (!profile.registered) {
            revert SeasonNotActive();
        }

        // Validate new total doesn't exceed maximum
        uint256 newTotal = profile.defensiveStake + additionalAmount;
        if (newTotal > cws.config.maxStakeAmount) {
            revert InvalidStake();
        }

        if (additionalAmount == 0) {
            revert InvalidStake();
        }

        // Transfer additional stake
        address currency = hs.chargeTreasury.treasuryCurrency;
        LibFeeCollection.collectFee(
            IERC20(currency),
            LibMeta.msgSender(),
            hs.chargeTreasury.treasuryAddress,
            additionalAmount,
            "stake_increase"
        );

        // Update profile
        profile.defensiveStake = newTotal;

        // Add to season prize pool (5% of increase)
        season.prizePool += additionalAmount / 20;
        emit StakeChanged(colonyId, newTotal, true, additionalAmount);
    }

    /**
     * @notice Decrease defensive stake (with limitations)
     * @param colonyId Colony to decrease stake for
     * @param reductionAmount ZICO amount to remove from stake
     */
    function decreaseDefensiveStake(bytes32 colonyId, uint256 reductionAmount)
        external
        whenNotPaused
        nonReentrant
        onlyColonyCreator(colonyId)
        duringRegistrationPeriod
    {
        LibColonyWarsStorage.requireInitialized();

        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibColonyWarsStorage.Season storage season = cws.seasons[cws.currentSeason];

        // Rate limiting - once per day to prevent manipulation
        if (!LibColonyWarsStorage.checkRateLimit(LibMeta.msgSender(), this.decreaseDefensiveStake.selector, 86400)) {
            revert RateLimitExceeded();
        }

        LibColonyWarsStorage.ColonyWarProfile storage profile = cws.colonyWarProfiles[colonyId];
        if (!profile.registered) {
            revert SeasonNotActive();
        }

        if (reductionAmount == 0 || reductionAmount > profile.defensiveStake) {
            revert InvalidStake();
        }

        // Validate new total meets minimum requirements
        uint256 newTotal = profile.defensiveStake - reductionAmount;
        if (newTotal < cws.config.minStakeAmount) {
            revert InvalidStake();
        }

        // Check if colony has active battles - cannot reduce during active battles
        bytes32[] storage seasonBattles = cws.seasonBattles[season.seasonId];

        for (uint256 i = 0; i < seasonBattles.length; i++) {
            LibColonyWarsStorage.BattleInstance storage battle = cws.battles[seasonBattles[i]];
            if ((battle.attackerColony == colonyId || battle.defenderColony == colonyId) &&
                battle.battleState < 2 && !cws.battleResolved[seasonBattles[i]]) {
                revert InvalidBattleState();
            }
        }

        // Apply penalty for stake reduction (10% penalty)
        uint256 penalty = reductionAmount / 10;
        uint256 refundAmount = reductionAmount - penalty;

        // Update profile
        profile.defensiveStake = newTotal;

        // Transfer refund to colony owner
        LibFeeCollection.transferFromTreasury(LibMeta.msgSender(), refundAmount, "stake_reduction");

        // Penalty goes to season prize pool
        season.prizePool += penalty;

        emit StakeChanged(colonyId, newTotal, false, reductionAmount);
    }

    // ============ VIEW FUNCTIONS ============

    /**
     * @notice Get pre-registration details for a colony
     * @param seasonId Season ID
     * @param colonyId Colony ID
     * @return stake Staked amount
     * @return owner Pre-registration owner
     * @return registeredAt Timestamp of pre-registration
     * @return activated Whether activated
     * @return cancelled Whether cancelled
     */
    function getPreRegistration(uint32 seasonId, bytes32 colonyId)
        external
        view
        returns (
            uint256 stake,
            address owner,
            uint32 registeredAt,
            bool activated,
            bool cancelled
        )
    {
        LibColonyWarsStorage.PreRegistration storage preReg =
            LibColonyWarsStorage.colonyWarsStorage().preRegistrations[seasonId][colonyId];

        return (
            preReg.stake,
            preReg.owner,
            preReg.registeredAt,
            preReg.activated,
            preReg.cancelled
        );
    }

    /**
     * @notice Get count of pre-registered colonies for a season
     * @param seasonId Season ID
     * @return total Total pre-registrations
     * @return processed Number already processed
     * @return pending Number pending activation
     */
    function getPreRegistrationStats(uint32 seasonId)
        external
        view
        returns (uint256 total, uint256 processed, uint256 pending)
    {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        total = cws.preRegisteredColonies[seasonId].length;
        processed = cws.preRegistrationProcessingIndex[seasonId];
        pending = total > processed ? total - processed : 0;
    }

    /**
     * @notice Check if pre-registration is currently allowed for a season
     * @param targetSeasonId Season to check
     * @return allowed Whether pre-registration is allowed
     * @return reason Explanation if not allowed
     */
    function canPreRegister(uint32 targetSeasonId)
        external
        view
        returns (bool allowed, string memory reason)
    {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibColonyWarsStorage.Season storage season = cws.seasons[targetSeasonId];
        LibColonyWarsStorage.Season storage currentSeasonData = cws.seasons[cws.currentSeason];

        bool isSeasonScheduled = season.startTime > 0;
        bool isCurrentSeasonEnded = !currentSeasonData.active ||
            (currentSeasonData.warfareEnd > 0 && block.timestamp > currentSeasonData.warfareEnd);
        bool isNextSeason = targetSeasonId == cws.currentSeason + 1;

        if (isSeasonScheduled) {
            // Scenario 1: Season is scheduled
            if (season.registrationEnd > 0 && block.timestamp > season.registrationEnd) {
                return (false, "Registration period ended");
            }

            if (season.active && block.timestamp >= season.startTime && block.timestamp <= season.registrationEnd) {
                return (false, "Use registerForSeason instead");
            }

            if (cws.preRegistrationWindow > 0) {
                uint32 preRegStart = season.startTime > cws.preRegistrationWindow
                    ? season.startTime - cws.preRegistrationWindow
                    : 0;
                if (block.timestamp < preRegStart) {
                    return (false, "Pre-registration window not open yet");
                }
            }

            return (true, "Pre-registration allowed (scheduled season)");
        } else {
            // Scenario 2: Season is NOT scheduled yet
            if (!isNextSeason) {
                return (false, "Can only pre-register for next season");
            }

            if (!isCurrentSeasonEnded && cws.currentSeason > 0) {
                return (false, "Current season still active");
            }

            return (true, "Pre-registration allowed (next season)");
        }
    }

    /**
     * @notice Get colony war profile
     * @param colonyId Colony to query
     * @return Colony war profile
     */
    function getColonyWarProfile(bytes32 colonyId) external view returns (LibColonyWarsStorage.ColonyWarProfile memory) {
        return LibColonyWarsStorage.colonyWarsStorage().colonyWarProfiles[colonyId];
    }

    /**
     * @notice Get current stake information for colony
     * @param colonyId Colony to check
     * @return currentStake Current defensive stake amount
     * @return canIncrease Whether stake can be increased
     * @return canDecrease Whether stake can be decreased
     * @return maxIncrease Maximum amount that can be added
     * @return maxDecrease Maximum amount that can be removed
     */
    function getDefensiveStakeInfo(bytes32 colonyId)
        external
        view
        returns (
            uint256 currentStake,
            bool canIncrease,
            bool canDecrease,
            uint256 maxIncrease,
            uint256 maxDecrease
        )
    {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibColonyWarsStorage.ColonyWarProfile storage profile = cws.colonyWarProfiles[colonyId];

        currentStake = profile.defensiveStake;

        if (!profile.registered) {
            return (currentStake, false, false, 0, 0);
        }

        // Check increase capability
        maxIncrease = cws.config.maxStakeAmount > currentStake ?
            cws.config.maxStakeAmount - currentStake : 0;
        canIncrease = maxIncrease > 0;

        // Check decrease capability - use library function
        maxDecrease = currentStake > cws.config.minStakeAmount ?
            currentStake - cws.config.minStakeAmount : 0;
        canDecrease = maxDecrease > 0 && !LibColonyWarsStorage.hasActiveBattles(colonyId, cws.currentSeason);

        return (currentStake, canIncrease, canDecrease, maxIncrease, maxDecrease);
    }

    /**
     * @notice Get current season information
     * @return seasonId Current season ID
     * @return startTime Season start timestamp
     * @return registrationEnd Registration period end
     * @return warfareEnd Warfare period end
     * @return resolutionEnd Season resolution end
     */
    function getLastWarsSeason() external view returns (uint32 seasonId, uint32 startTime, uint32 registrationEnd, uint32 warfareEnd, uint32 resolutionEnd) {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibColonyWarsStorage.Season storage season = cws.seasons[cws.currentSeason];
        
        return (season.seasonId, season.startTime, season.registrationEnd, season.warfareEnd, season.resolutionEnd);
    }

    // ============ INTERNAL FUNCTIONS ============

    /**
     * @notice Validate stake bounds and collect fee
     * @dev Shared validation for registerForSeason and preRegisterForSeason
     */
    function _validateStakeAndCollect(
        uint256 stake,
        string memory feeLabel,
        LibColonyWarsStorage.ColonyWarsStorage storage cws,
        LibHenomorphsStorage.HenomorphsStorage storage hs
    ) internal {
        // Validate stake bounds
        if (stake < cws.config.minStakeAmount || stake > cws.config.maxStakeAmount) {
            revert InvalidStake();
        }

        // Collect stake
        LibFeeCollection.collectFee(
            IERC20(hs.chargeTreasury.treasuryCurrency),
            LibMeta.msgSender(),
            hs.chargeTreasury.treasuryAddress,
            stake,
            feeLabel
        );
    }

    /**
     * @notice Initialize colony war profile with stake and registration data
     */
    function _initializeColonyWarProfile(
        bytes32 colonyId,
        uint256 stake,
        uint32 seasonId,
        LibColonyWarsStorage.ColonyWarsStorage storage cws
    ) internal {
        LibColonyWarsStorage.ColonyWarProfile storage profile = cws.colonyWarProfiles[colonyId];
        profile.defensiveStake = stake;
        profile.acceptingChallenges = true;
        profile.reputation = 0;
        profile.registered = true;
        profile.registeredSeasonId = seasonId;
    }

    /**
     * @notice Track user's colony association for a season
     */
    function _trackUserColony(
        bytes32 colonyId,
        address owner,
        uint32 seasonId,
        LibColonyWarsStorage.ColonyWarsStorage storage cws
    ) internal {
        if (LibColonyWarsStorage.getUserPrimaryColony(owner) == bytes32(0)) {
            LibColonyWarsStorage.setUserPrimaryColony(owner, colonyId);
        }
        cws.userToColony[owner] = colonyId;
        LibColonyWarsStorage.addUserSeasonColony(seasonId, owner, colonyId);
    }

    /**
     * @notice Add colony to season tracking (registered colonies list, score, prize pool)
     */
    function _addToSeasonTracking(
        bytes32 colonyId,
        uint256 stake,
        uint32 seasonId,
        LibColonyWarsStorage.Season storage season
    ) internal {
        season.prizePool += stake / 20;  // 5% to prize pool
        season.registeredColonies.push(colonyId);
        LibColonyWarsStorage.setColonyScore(seasonId, colonyId, 0);
    }

    /**
     * @notice Reset colony war profile (for unregistration/cancellation)
     */
    function _resetColonyWarProfile(
        bytes32 colonyId,
        LibColonyWarsStorage.ColonyWarsStorage storage cws
    ) internal {
        LibColonyWarsStorage.ColonyWarProfile storage profile = cws.colonyWarProfiles[colonyId];
        profile.defensiveStake = 0;
        profile.acceptingChallenges = false;
        profile.registered = false;
        profile.registeredSeasonId = 0;
    }

    /**
     * @notice Remove colony from season registered colonies array
     */
    function _removeColonyFromSeason(
        bytes32 colonyId,
        uint32 seasonId,
        LibColonyWarsStorage.ColonyWarsStorage storage cws
    ) internal {
        LibColonyWarsStorage.Season storage season = cws.seasons[seasonId];

        // Find and remove colony from season.registeredColonies
        for (uint256 i = 0; i < season.registeredColonies.length; i++) {
            if (season.registeredColonies[i] == colonyId) {
                season.registeredColonies[i] = season.registeredColonies[season.registeredColonies.length - 1];
                season.registeredColonies.pop();
                break;
            }
        }

        // Reset colony score
        LibColonyWarsStorage.setColonyScore(seasonId, colonyId, 0);
    }

    /**
     * @notice Remove colony from user's season colonies array
     */
    function _removeFromUserSeasonColonies(
        bytes32 colonyId,
        uint32 seasonId,
        address user,
        LibColonyWarsStorage.ColonyWarsStorage storage cws
    ) internal {
        bytes32[] storage userColonies = cws.userSeasonColonies[seasonId][user];

        // Find and remove colony from user's season colonies
        for (uint256 i = 0; i < userColonies.length; i++) {
            if (userColonies[i] == colonyId) {
                userColonies[i] = userColonies[userColonies.length - 1];
                userColonies.pop();
                break;
            }
        }
    }

    /**
     * @notice Calculate unregistration penalty based on timing
     */
    function _calculateUnregistrationPenalty(
        uint256 originalStake,
        LibColonyWarsStorage.Season storage season,
        uint256 currentTime
    ) internal view returns (uint256 penalty) {
        // No penalty during registration period
        if (currentTime <= season.registrationEnd) {
            return 0;
        }

        // Progressive penalty after registration ends
        uint256 timeAfterRegistration = currentTime - season.registrationEnd;

        if (timeAfterRegistration <= 1 days) {
            penalty = originalStake * 5 / 100;  // 5% penalty first day
        } else if (timeAfterRegistration <= 2 days) {
            penalty = originalStake * 10 / 100; // 10% penalty second day
        } else {
            penalty = originalStake * 15 / 100; // 15% penalty third day
        }

        return penalty;
    }

    /**
     * @notice Internal function to activate a single pre-registration
     */
    function _activatePreRegistration(
        bytes32 colonyId,
        LibColonyWarsStorage.PreRegistration storage preReg,
        uint32 seasonId,
        LibColonyWarsStorage.Season storage season
    ) internal {
        // Add to season tracking (prize pool, registered list, score)
        _addToSeasonTracking(colonyId, preReg.stake, seasonId, season);
        emit ColonyRegisteredForSeason(colonyId, seasonId);
    }
}
