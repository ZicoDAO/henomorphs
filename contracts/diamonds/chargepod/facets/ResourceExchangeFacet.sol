// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibMeta} from "../../shared/libraries/LibMeta.sol";
import {LibResourceStorage} from "../libraries/LibResourceStorage.sol";
import {LibColonyWarsStorage} from "../libraries/LibColonyWarsStorage.sol";
import {LibBuildingsStorage} from "../libraries/LibBuildingsStorage.sol";
import {LibProgressionStorage} from "../libraries/LibProgressionStorage.sol";
import {LibStakingStorage} from "../../staking/libraries/LibStakingStorage.sol";
import {ResourceHelper} from "../libraries/ResourceHelper.sol";
import {AccessControlBase} from "../../common/facets/AccessControlBase.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @notice Interface for mintable reward token (YLW)
 */
interface IRewardToken is IERC20 {
    function mint(address to, uint256 amount, string calldata reason) external;
}

/**
 * @title ResourceExchangeFacet
 * @notice Protocol-level exchange: burn resources → receive YLW at dynamic "pawn shop" rate
 * @dev Exchange rates are deliberately LOW so that gameplay mechanics (ventures, buildings,
 *      processing, marketplace) are ALWAYS more profitable than direct exchange.
 *
 *      DESIGN PHILOSOPHY:
 *      - Exchange exists as an overflow/emergency valve, NOT a primary income source
 *      - All multipliers combined can boost rate by max ~+80% (never competitive with gameplay)
 *      - Active events PENALIZE exchange rate to encourage participation in gameplay
 *      - Aggressive daily cooldown prevents dump-and-sell loops
 *      - Resources are permanently burned (decremented from global supply)
 *      - YLW is distributed via treasury-first pattern (mint as fallback)
 *
 *      RATE FORMULA:
 *      effectiveRate = baseRate[type]
 *          × scarcityFactor      (0.8x - 1.2x)  supply utilization
 *          × activityFactor      (0.8x - 1.1x)  recent resource activity
 *          × tradeHubFactor      (1.0x - 1.15x) Trade Hub building level
 *          × eventPenalty        (0.5x - 1.0x)  active events = WORSE rate
 *          × cooldownPenalty     (0.7x - 1.0x)  repeated exchanges/day
 *          × volumeFactor        (1.0x - 1.1x)  lifetime exchange loyalty
 *          × ventureStreakFactor  (1.0x - 1.05x) consecutive venture successes
 *
 * @author rutilicus.eth (ArchXS)
 */
contract ResourceExchangeFacet is AccessControlBase {
    using SafeERC20 for IERC20;

    // ============================================
    // CONSTANTS
    // ============================================

    uint256 private constant BPS = 10000;
    uint8 private constant MAX_DAILY_EXCHANGES = 10;

    // ============================================
    // EVENTS
    // ============================================

    event ResourcesExchanged(
        address indexed user,
        uint8 indexed resourceType,
        uint256 resourceAmount,
        uint256 ylwGross,
        uint256 ylwFee,
        uint256 ylwNet,
        uint256 effectiveRate
    );

    event ExchangeConfigUpdated(
        bool enabled,
        uint16 feeBps,
        uint256 dailyLimit
    );

    event ExchangeBaseRatesUpdated(uint256[4] rates);
    event ExchangeMinAmountsUpdated(uint256[4] amounts);

    // ============================================
    // ERRORS
    // ============================================

    error ExchangeDisabled();
    error InvalidResourceType(uint8 resourceType);
    error InsufficientResources(uint8 resourceType, uint256 required, uint256 available);
    error BelowMinimumAmount(uint8 resourceType, uint256 minimum, uint256 provided);
    error DailyYlwLimitExceeded(uint256 requested, uint256 available);
    error DailyExchangeCountExceeded(uint8 maxCount);
    error ZeroAmount();
    error ZeroRate();
    error YlwTokenNotConfigured();
    error InvalidFeeBps(uint16 feeBps);
    error InvalidBaseRate(uint8 resourceType, uint256 rate);

    // ============================================
    // INTERNAL STRUCTS (stack depth optimization)
    // ============================================

    struct ExchangeParams {
        address user;
        address ylwToken;
        uint8 resourceType;
        uint256 amount;
        uint32 today;
        uint8 countToday;
    }

    struct ExchangeResult {
        uint256 effectiveRate;
        uint256 ylwGross;
        uint256 ylwFee;
        uint256 ylwNet;
    }

    // ============================================
    // MAIN EXCHANGE FUNCTION
    // ============================================

    /**
     * @notice Exchange resources for YLW at dynamic protocol rate
     * @dev Resources are burned (removed from global supply).
     *      YLW distributed via treasury-first, mint-fallback pattern.
     *      Rate is deliberately low - gameplay is ALWAYS more profitable.
     * @param resourceType Resource type (0=Basic, 1=Energy, 2=Bio, 3=Rare)
     * @param amount Amount of resources to exchange
     * @return ylwReceived Net YLW received after fees
     */
    function exchangeResourcesForYlw(
        uint8 resourceType,
        uint256 amount
    ) external whenNotPaused nonReentrant returns (uint256 ylwReceived) {
        if (amount == 0) revert ZeroAmount();
        if (resourceType > 3) revert InvalidResourceType(resourceType);

        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        if (!rs.exchangeEnabled) revert ExchangeDisabled();

        ExchangeParams memory p;
        p.ylwToken = ResourceHelper.getAuxiliaryCurrency();
        if (p.ylwToken == address(0)) revert YlwTokenNotConfigured();
        p.resourceType = resourceType;
        p.amount = amount;
        p.user = LibMeta.msgSender();
        p.today = uint32(block.timestamp / 86400);

        // Minimum amount check
        _validateMinAmount(rs, p.resourceType, p.amount);

        // Daily exchange count check
        p.countToday = rs.dailyExchangeCount[p.user][p.today];
        if (p.countToday >= MAX_DAILY_EXCHANGES) {
            revert DailyExchangeCountExceeded(MAX_DAILY_EXCHANGES);
        }

        // Apply decay and verify balance
        LibResourceStorage.applyResourceDecay(p.user);
        uint256 available = rs.userResources[p.user][p.resourceType];
        if (available < p.amount) {
            revert InsufficientResources(p.resourceType, p.amount, available);
        }

        // Calculate exchange amounts
        ExchangeResult memory r = _calculateExchange(rs, p);
        if (r.ylwNet == 0) revert ZeroAmount();

        // Check daily limits
        _checkDailyLimits(rs, p.user, p.today, r.ylwNet);

        // Execute exchange
        _executeExchange(rs, p, r, available);

        return r.ylwNet;
    }

    /**
     * @notice Validate minimum exchange amount
     */
    function _validateMinAmount(
        LibResourceStorage.ResourceStorage storage rs,
        uint8 resourceType,
        uint256 amount
    ) internal view {
        uint256 minAmount = rs.resourceExchangeMinAmounts[resourceType];
        if (minAmount > 0 && amount < minAmount) {
            revert BelowMinimumAmount(resourceType, minAmount, amount);
        }
    }

    /**
     * @notice Calculate exchange result with all multipliers
     */
    function _calculateExchange(
        LibResourceStorage.ResourceStorage storage rs,
        ExchangeParams memory p
    ) internal view returns (ExchangeResult memory r) {
        r.effectiveRate = _calculateEffectiveRate(p.user, p.resourceType);
        if (r.effectiveRate == 0) revert ZeroRate();

        r.ylwGross = p.amount * r.effectiveRate;
        r.ylwFee = (r.ylwGross * rs.exchangeFeeBps) / BPS;
        r.ylwNet = r.ylwGross - r.ylwFee;
    }

    /**
     * @notice Check both exchange-specific and global YLW daily limits
     */
    function _checkDailyLimits(
        LibResourceStorage.ResourceStorage storage rs,
        address user,
        uint32 today,
        uint256 ylwNet
    ) internal view {
        // Exchange-specific daily limit
        uint256 dailyUsed = rs.dailyExchangeVolume[user][today];
        if (rs.exchangeDailyLimitYlw > 0 && dailyUsed + ylwNet > rs.exchangeDailyLimitYlw) {
            revert DailyYlwLimitExceeded(ylwNet, rs.exchangeDailyLimitYlw - dailyUsed);
        }

        // Shared global YLW daily limit (consistent with TokenSwapFacet)
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        uint256 globalAvailable = LibStakingStorage.getAvailableYlwLimit(ss, user);
        if (ylwNet > globalAvailable) {
            revert DailyYlwLimitExceeded(ylwNet, globalAvailable);
        }
    }

    /**
     * @notice Execute the exchange: burn resources, distribute YLW, update stats
     */
    function _executeExchange(
        LibResourceStorage.ResourceStorage storage rs,
        ExchangeParams memory p,
        ExchangeResult memory r,
        uint256 availableBefore
    ) internal {
        // 1. Burn resources from user balance
        rs.userResources[p.user][p.resourceType] = availableBefore - p.amount;

        // 2. Decrement global supply (resources leave circulation permanently)
        LibResourceStorage.decrementGlobalSupply(p.resourceType, p.amount);

        // 3. Distribute YLW to user (treasury-first, mint-fallback)
        _distributeYlw(p.ylwToken, p.user, r.ylwNet);

        // 4. Consume from shared daily YLW limit
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        LibStakingStorage.checkAndConsumeYlwLimit(ss, p.user, r.ylwNet);

        // 5. Update exchange statistics
        rs.dailyExchangeVolume[p.user][p.today] += r.ylwNet;
        rs.dailyExchangeCount[p.user][p.today] = p.countToday + 1;
        rs.totalExchangeVolume[p.user] += r.ylwNet;
        rs.lastExchangeTime[p.user] = uint32(block.timestamp);
        rs.totalResourcesBurnedByExchange[p.resourceType] += p.amount;
        rs.totalYlwMintedByExchange += r.ylwNet;

        emit ResourcesExchanged(
            p.user,
            p.resourceType,
            p.amount,
            r.ylwGross,
            r.ylwFee,
            r.ylwNet,
            r.effectiveRate
        );
    }

    // ============================================
    // RATE CALCULATION - ALL GAMIFICATION FACTORS
    // ============================================

    /**
     * @notice Calculate the effective exchange rate for a user and resource type
     * @dev Combines 7 independent multipliers, each expressed in basis points (10000 = 1.0x)
     *      Max combined bonus: ~+84% | Max combined penalty: ~-78%
     *      All factors are designed to reward active gameplay and penalize dump behavior
     * @param user User address
     * @param resourceType Resource type (0-3)
     * @return effectiveRate YLW wei per resource unit after all multipliers
     */
    function _calculateEffectiveRate(
        address user,
        uint8 resourceType
    ) internal view returns (uint256 effectiveRate) {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();

        effectiveRate = rs.resourceExchangeBaseRates[resourceType];
        if (effectiveRate == 0) return 0;

        // Factor 1: Supply scarcity (0.8x - 1.2x)
        // Resources closer to supply cap are slightly more valuable
        effectiveRate = (effectiveRate * _scarcityFactor(rs, resourceType)) / BPS;

        // Factor 2: User activity (0.8x - 1.1x)
        // Recently active users get better rates
        effectiveRate = (effectiveRate * _activityFactor(rs, user)) / BPS;

        // Factor 3: Trade Hub building (1.0x - 1.15x)
        // Investing in Trade Hub infrastructure rewards the player
        effectiveRate = (effectiveRate * _tradeHubFactor(user)) / BPS;

        // Factor 4: Active event PENALTY (0.5x - 1.0x)
        // During events, exchange rate drops to encourage gameplay participation
        effectiveRate = (effectiveRate * _eventPenalty(rs)) / BPS;

        // Factor 5: Daily cooldown PENALTY (0.7x - 1.0x)
        // More exchanges per day = worse rate (anti-dump)
        effectiveRate = (effectiveRate * _cooldownPenalty(rs, user)) / BPS;

        // Factor 6: Lifetime volume loyalty (1.0x - 1.1x)
        // Consistent exchangers get a small bonus
        effectiveRate = (effectiveRate * _volumeFactor(rs, user)) / BPS;

        // Factor 7: Venture streak (1.0x - 1.05x)
        // Active venture participants get a small bonus
        effectiveRate = (effectiveRate * _ventureStreakFactor(user)) / BPS;
    }

    // ============================================
    // INDIVIDUAL MULTIPLIER FUNCTIONS
    // ============================================

    /**
     * @notice Supply scarcity factor based on global supply utilization
     * @dev Higher utilization = slightly higher rate (resource is scarcer)
     *      But capped at 1.2x to prevent exchange becoming attractive when scarce
     *      (scarce resources should be USED in gameplay, not exchanged)
     * @return bps Multiplier in basis points (8000-12000)
     */
    function _scarcityFactor(
        LibResourceStorage.ResourceStorage storage rs,
        uint8 resourceType
    ) internal view returns (uint256 bps) {
        if (!rs.supplyCapEnabled) return BPS; // 1.0x if caps disabled

        uint256 cap = rs.resourceSupplyCaps[resourceType];
        if (cap == 0) return BPS; // 1.0x if unlimited

        uint256 supply = rs.resourceGlobalSupply[resourceType];
        uint256 utilization = (supply * BPS) / cap; // 0-10000

        if (utilization < 2500) {
            return 8000;  // < 25% used: resource is abundant → 0.8x
        } else if (utilization < 5000) {
            return 9000;  // 25-50% → 0.9x
        } else if (utilization < 7500) {
            return 10500; // 50-75% → 1.05x
        } else if (utilization < 9000) {
            return 11000; // 75-90% → 1.1x
        } else {
            return 12000; // > 90% → 1.2x (mild premium, NOT 3x)
        }
    }

    /**
     * @notice User activity factor based on recent resource interactions
     * @dev Rewards users who are actively harvesting/processing/trading
     *      Penalizes dormant accounts trying to dump stale resources
     * @return bps Multiplier in basis points (8000-11000)
     */
    function _activityFactor(
        LibResourceStorage.ResourceStorage storage rs,
        address user
    ) internal view returns (uint256 bps) {
        uint32 lastUpdate = rs.userResourcesLastUpdate[user];

        if (lastUpdate == 0) return 8000; // Never active → 0.8x

        uint32 currentTime = uint32(block.timestamp);
        if (lastUpdate > currentTime) return 8000; // Corrupted timestamp → 0.8x

        uint32 daysSinceActivity = (currentTime - lastUpdate) / 86400;

        if (daysSinceActivity == 0) {
            return 11000; // Active today → 1.1x
        } else if (daysSinceActivity <= 1) {
            return 10500; // Active yesterday → 1.05x
        } else if (daysSinceActivity <= 3) {
            return 10000; // Active within 3 days → 1.0x
        } else if (daysSinceActivity <= 7) {
            return 9000;  // Active within week → 0.9x
        } else {
            return 8000;  // Dormant (>7 days) → 0.8x
        }
    }

    /**
     * @notice Trade Hub building factor
     * @dev Players who invested in Trade Hub infrastructure get better exchange rates
     *      Trade Hub L1: +3%, L2: +6%, L3: +9%, L4: +12%, L5: +15%
     *      This makes building investment more valuable
     * @return bps Multiplier in basis points (10000-11500)
     */
    function _tradeHubFactor(address user) internal view returns (uint256 bps) {
        bytes32 colonyId = LibColonyWarsStorage.getUserPrimaryColony(user);
        if (colonyId == bytes32(0)) return BPS; // No colony → 1.0x (no bonus)

        LibBuildingsStorage.ColonyBuildingEffects memory effects =
            LibBuildingsStorage.getColonyBuildingEffectsWithCards(colonyId);

        // marketFeeReductionBps: Trade Hub L1=500, L2=1000, L3=1500, L4=2500, L5=4000
        // Scale to exchange bonus: max 4000 → +15% (1500 bps bonus)
        // Formula: bonus = marketFeeReductionBps * 1500 / 4000 = marketFeeReductionBps * 3 / 8
        uint256 bonus = (uint256(effects.marketFeeReductionBps) * 3) / 8;

        // Cap at 1500 bps (+15%)
        if (bonus > 1500) bonus = 1500;

        return BPS + bonus;
    }

    /**
     * @notice Active event PENALTY factor
     * @dev During active events, exchange rate DECREASES to encourage gameplay
     *      This is the opposite of the production bonus during events:
     *      - Events boost production → play more, earn more resources
     *      - Events penalize exchange → don't dump resources, USE them in event
     *      - Resource Rush: -50% exchange rate
     *      - Processing Frenzy: -30% exchange rate
     *      - Crafting Festival: -20% exchange rate
     * @return bps Multiplier in basis points (5000-10000)
     */
    function _eventPenalty(
        LibResourceStorage.ResourceStorage storage rs
    ) internal view returns (uint256 bps) {
        bps = BPS; // Start at 1.0x

        // Find strongest active event penalty
        for (uint256 i = 0; i < rs.activeEventIds.length; i++) {
            bytes32 eventHash = keccak256(bytes(rs.activeEventIds[i]));
            LibResourceStorage.ResourceEvent storage evt = rs.resourceEvents[eventHash];

            if (evt.active && block.timestamp >= evt.startTime && block.timestamp <= evt.endTime) {
                uint256 penalty;
                if (evt.eventType == 1) {
                    // Resource Rush → strongest penalty (exchange is worst option during rush)
                    penalty = 5000; // 0.5x
                } else if (evt.eventType == 2) {
                    // Processing Frenzy → moderate penalty
                    penalty = 7000; // 0.7x
                } else if (evt.eventType == 3) {
                    // Crafting Festival → mild penalty
                    penalty = 8000; // 0.8x
                } else {
                    // Per-resource or other events → mild penalty
                    penalty = 8500; // 0.85x
                }

                // Use the strongest penalty (lowest value)
                if (penalty < bps) {
                    bps = penalty;
                }
            }
        }
    }

    /**
     * @notice Daily exchange cooldown PENALTY
     * @dev Each additional exchange per day gets a worse rate
     *      Prevents harvest-and-dump loops where player harvests → exchanges immediately
     *      1st exchange: 1.0x (full rate)
     *      2nd: 0.95x
     *      3rd: 0.85x
     *      4th+: 0.70x (severe penalty)
     * @return bps Multiplier in basis points (7000-10000)
     */
    function _cooldownPenalty(
        LibResourceStorage.ResourceStorage storage rs,
        address user
    ) internal view returns (uint256 bps) {
        uint32 today = uint32(block.timestamp / 86400);
        uint8 countToday = rs.dailyExchangeCount[user][today];

        if (countToday == 0) return BPS;     // 1st exchange → 1.0x
        if (countToday == 1) return 9500;    // 2nd → 0.95x
        if (countToday == 2) return 8500;    // 3rd → 0.85x
        return 7000;                          // 4th+ → 0.70x
    }

    /**
     * @notice Lifetime volume loyalty factor
     * @dev Small bonus for consistent use of the exchange system
     *      Rewards loyal players who regularly convert small amounts
     *      NOT large enough to incentivize exchange over gameplay
     * @return bps Multiplier in basis points (10000-11000)
     */
    function _volumeFactor(
        LibResourceStorage.ResourceStorage storage rs,
        address user
    ) internal view returns (uint256 bps) {
        uint256 totalVolume = rs.totalExchangeVolume[user];

        if (totalVolume < 100 ether) return BPS;          // < 100 YLW → 1.0x
        if (totalVolume < 500 ether) return 10200;         // 100-500 → 1.02x
        if (totalVolume < 2500 ether) return 10500;        // 500-2500 → 1.05x
        if (totalVolume < 10000 ether) return 10800;       // 2500-10k → 1.08x
        return 11000;                                       // >10k → 1.1x
    }

    /**
     * @notice Venture streak factor
     * @dev Players with active venture success streaks get a small bonus
     *      Rewards diverse gameplay - venturing AND exchanging complement each other
     *      Streak 0: 1.0x | 3+: 1.02x | 5+: 1.03x | 10+: 1.05x
     * @return bps Multiplier in basis points (10000-10500)
     */
    function _ventureStreakFactor(address user) internal view returns (uint256 bps) {
        LibProgressionStorage.ProgressionStorage storage ps = LibProgressionStorage.progressionStorage();
        uint32 streak = ps.userStats[user].currentStreak;

        if (streak < 3) return BPS;            // 0-2 → 1.0x
        if (streak < 5) return 10200;          // 3-4 → 1.02x
        if (streak < 10) return 10300;         // 5-9 → 1.03x
        return 10500;                           // 10+ → 1.05x
    }

    // ============================================
    // YLW DISTRIBUTION
    // ============================================

    /**
     * @notice Distribute YLW using treasury-first, mint-fallback pattern
     * @dev Consistent with ResourceEconomyFacet._distributeYlwReward
     * @param ylwToken YLW token address
     * @param recipient Recipient address
     * @param amount Amount of YLW to distribute
     */
    function _distributeYlw(
        address ylwToken,
        address recipient,
        uint256 amount
    ) internal {
        address treasury = ResourceHelper.getTreasuryAddress();

        uint256 treasuryBalance = IERC20(ylwToken).balanceOf(treasury);
        uint256 allowance = IERC20(ylwToken).allowance(treasury, address(this));

        if (treasuryBalance >= amount && allowance >= amount) {
            // Pay from treasury (preferred - sustainable)
            IERC20(ylwToken).safeTransferFrom(treasury, recipient, amount);
        } else if (treasuryBalance > 0 && allowance > 0) {
            // Partial from treasury, rest from mint
            uint256 fromTreasury = treasuryBalance < allowance ? treasuryBalance : allowance;
            IERC20(ylwToken).safeTransferFrom(treasury, recipient, fromTreasury);

            uint256 shortfall = amount - fromTreasury;
            IRewardToken(ylwToken).mint(recipient, shortfall, "resource_exchange");
        } else {
            // Fallback: Mint new tokens
            IRewardToken(ylwToken).mint(recipient, amount, "resource_exchange");
        }
    }

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    /**
     * @notice Get exchange quote with full breakdown of multipliers
     * @param user User address (for personalized rate)
     * @param resourceType Resource type (0-3)
     * @param amount Amount of resources to exchange
     * @return ylwGross Gross YLW before fees
     * @return ylwFee Fee amount (burned, not minted)
     * @return ylwNet Net YLW user would receive
     * @return effectiveRate Effective rate (YLW wei per resource unit)
     * @return multiplierBreakdown Array of 7 multipliers in BPS [scarcity, activity, tradeHub, event, cooldown, volume, streak]
     */
    function getExchangeQuote(
        address user,
        uint8 resourceType,
        uint256 amount
    ) external view returns (
        uint256 ylwGross,
        uint256 ylwFee,
        uint256 ylwNet,
        uint256 effectiveRate,
        uint256[7] memory multiplierBreakdown
    ) {
        if (resourceType > 3) revert InvalidResourceType(resourceType);

        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();

        effectiveRate = rs.resourceExchangeBaseRates[resourceType];
        if (effectiveRate == 0) return (0, 0, 0, 0, multiplierBreakdown);

        // Calculate each factor individually for breakdown
        multiplierBreakdown[0] = _scarcityFactor(rs, resourceType);
        multiplierBreakdown[1] = _activityFactor(rs, user);
        multiplierBreakdown[2] = _tradeHubFactor(user);
        multiplierBreakdown[3] = _eventPenalty(rs);
        multiplierBreakdown[4] = _cooldownPenalty(rs, user);
        multiplierBreakdown[5] = _volumeFactor(rs, user);
        multiplierBreakdown[6] = _ventureStreakFactor(user);

        // Apply all multipliers
        for (uint256 i = 0; i < 7; i++) {
            effectiveRate = (effectiveRate * multiplierBreakdown[i]) / BPS;
        }

        ylwGross = amount * effectiveRate;
        ylwFee = (ylwGross * rs.exchangeFeeBps) / BPS;
        ylwNet = ylwGross - ylwFee;
    }

    /**
     * @notice Get exchange system info for a user
     * @param user User address
     * @return enabled Whether exchange is enabled
     * @return feeBps Fee in basis points
     * @return dailyLimitYlw Max YLW per day
     * @return dailyUsedYlw YLW exchanged today
     * @return exchangeCountToday Number of exchanges today
     * @return maxDailyExchanges Max exchanges per day
     * @return totalLifetimeVolume User's total lifetime exchange volume
     * @return baseRates Base rates per resource type [basic, energy, bio, rare]
     * @return minAmounts Minimum exchange amounts per type
     */
    function getExchangeInfo(address user) external view returns (
        bool enabled,
        uint16 feeBps,
        uint256 dailyLimitYlw,
        uint256 dailyUsedYlw,
        uint8 exchangeCountToday,
        uint8 maxDailyExchanges,
        uint256 totalLifetimeVolume,
        uint256[4] memory baseRates,
        uint256[4] memory minAmounts
    ) {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();

        enabled = rs.exchangeEnabled;
        feeBps = rs.exchangeFeeBps;
        dailyLimitYlw = rs.exchangeDailyLimitYlw;
        maxDailyExchanges = MAX_DAILY_EXCHANGES;
        totalLifetimeVolume = rs.totalExchangeVolume[user];

        uint32 today = uint32(block.timestamp / 86400);
        dailyUsedYlw = rs.dailyExchangeVolume[user][today];
        exchangeCountToday = rs.dailyExchangeCount[user][today];

        baseRates = rs.resourceExchangeBaseRates;
        minAmounts = rs.resourceExchangeMinAmounts;
    }

    /**
     * @notice Get global exchange statistics
     * @return totalBurnedByType Total resources burned per type
     * @return totalYlwMinted Total YLW minted through exchange
     * @return enabled Whether exchange is enabled
     */
    function getExchangeStats() external view returns (
        uint256[4] memory totalBurnedByType,
        uint256 totalYlwMinted,
        bool enabled
    ) {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();

        totalBurnedByType = rs.totalResourcesBurnedByExchange;
        totalYlwMinted = rs.totalYlwMintedByExchange;
        enabled = rs.exchangeEnabled;
    }

    /**
     * @notice Get effective exchange rates for all resource types for a user
     * @param user User address
     * @return rates Effective rate per resource type (YLW wei per unit)
     * @return baseRates Base rate per resource type (before multipliers)
     */
    function getEffectiveRates(address user) external view returns (
        uint256[4] memory rates,
        uint256[4] memory baseRates
    ) {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();

        for (uint8 i = 0; i < 4; i++) {
            baseRates[i] = rs.resourceExchangeBaseRates[i];
            rates[i] = _calculateEffectiveRate(user, i);
        }
    }

    // ============================================
    // ADMIN FUNCTIONS
    // ============================================

    /**
     * @notice Initialize exchange system with default values
     * @dev Call once after deploying the facet. Safe to call multiple times (idempotent for rates).
     *
     *      Default base rates (YLW per resource unit):
     *      - BASIC:  0.002 YLW → 1200/day = 2.4 YLW (12% of harvest income)
     *      - ENERGY: 0.005 YLW → proportional to 2x rarity
     *      - BIO:    0.012 YLW → proportional to 4x rarity
     *      - RARE:   0.035 YLW → proportional to 10x rarity
     */
    function initializeExchangeDefaults() external onlyAuthorized {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();

        rs.exchangeEnabled = false; // Start disabled, admin enables when ready
        rs.exchangeFeeBps = 500;    // 5% fee (burned, deflationary)
        rs.exchangeDailyLimitYlw = 50 ether; // 50 YLW max per user per day

        // Base rates: deliberately low "pawn shop" rates
        rs.resourceExchangeBaseRates[0] = 2e15;   // BASIC:  0.002 YLW
        rs.resourceExchangeBaseRates[1] = 5e15;   // ENERGY: 0.005 YLW
        rs.resourceExchangeBaseRates[2] = 12e15;  // BIO:    0.012 YLW
        rs.resourceExchangeBaseRates[3] = 35e15;  // RARE:   0.035 YLW

        // Minimum exchange amounts (prevent dust transactions)
        rs.resourceExchangeMinAmounts[0] = 100;   // 100 Basic minimum
        rs.resourceExchangeMinAmounts[1] = 50;    // 50 Energy minimum
        rs.resourceExchangeMinAmounts[2] = 25;    // 25 Bio minimum
        rs.resourceExchangeMinAmounts[3] = 5;     // 5 Rare minimum
    }

    /**
     * @notice Configure exchange system parameters
     * @param enabled Master switch
     * @param feeBps Fee in basis points (max 2000 = 20%)
     * @param dailyLimitYlw Max YLW per user per day (0 = unlimited)
     */
    function setExchangeConfig(
        bool enabled,
        uint16 feeBps,
        uint256 dailyLimitYlw
    ) external onlyAuthorized {
        if (feeBps > 2000) revert InvalidFeeBps(feeBps);

        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        rs.exchangeEnabled = enabled;
        rs.exchangeFeeBps = feeBps;
        rs.exchangeDailyLimitYlw = dailyLimitYlw;

        emit ExchangeConfigUpdated(enabled, feeBps, dailyLimitYlw);
    }

    /**
     * @notice Set base exchange rates for all resource types
     * @dev Rates should be kept LOW to ensure gameplay is always more profitable
     * @param rates Array of 4 rates in YLW wei per resource unit [basic, energy, bio, rare]
     */
    function setExchangeBaseRates(uint256[4] calldata rates) external onlyAuthorized {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();

        for (uint8 i = 0; i < 4; i++) {
            if (rates[i] == 0) revert InvalidBaseRate(i, rates[i]);
            rs.resourceExchangeBaseRates[i] = rates[i];
        }

        emit ExchangeBaseRatesUpdated(rates);
    }

    /**
     * @notice Set minimum exchange amounts per resource type
     * @param amounts Array of 4 minimum amounts [basic, energy, bio, rare]
     */
    function setExchangeMinAmounts(uint256[4] calldata amounts) external onlyAuthorized {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();

        for (uint8 i = 0; i < 4; i++) {
            rs.resourceExchangeMinAmounts[i] = amounts[i];
        }

        emit ExchangeMinAmountsUpdated(amounts);
    }
}
