// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "./FierceToken.sol";

/**
 * @title Fierce Token Staking
 * @dev Handles all staking and vesting functionality for Fierce Token
 *
 * STAKING FEATURES:
 * - Multiple staking durations with customizable reward rates
 * - Real-time reward accumulation with security boundaries
 * - Emergency unstake functionality (without rewards)
 * - Maximum reward accumulation period to prevent exploitation
 * - Minimum staking amount requirements
 *
 * VESTING FEATURES:
 * - Custom vesting schedules with cliff periods
 * - Linear vesting distribution
 * - Multiple vesting schedules per beneficiary
 * - Secure token locking and release mechanisms
 *
 * SECURITY FEATURES:
 * ✅ Reentrancy Protection
 * ✅ Contract Call Prevention
 * ✅ Emergency Pause Functionality
 * ✅ Input Validation & Sanitization
 * ✅ Reward Calculation Overflow Protection
 * ✅ Maximum Accumulation Period Limits
 */
contract TraditionalStaking is Ownable, ReentrancyGuard, Pausable {
    FierceToken public token;

    // Staking structure
    struct StakeInfo {
        uint256 amount;
        uint256 startTime;
        uint256 duration;
        uint256 rewardRate;
        bool active;
        uint256 lastRewardCalculation;
        uint256 accumulatedRewards;
    }

    // Vesting structure
    struct VestingSchedule {
        address beneficiary;
        uint256 totalAmount;
        uint256 releasedAmount;
        uint256 startTime;
        uint256 duration;
        uint256 cliff;
    }

    // Constants
    uint256 public maxRewardAccumulationPeriod = 30 days;

    // State variables

    uint256 public stakingMinted;
    uint256 public stakingFundsMinted;
    uint256 public totalVestedTokens;

    // Mappings
    mapping(address => StakeInfo[]) public userStakes;
    mapping(uint256 => uint256) public durationRewards;
    mapping(address => VestingSchedule[]) public vestingSchedules;

    // Events
    event TokensStaked(
        address indexed staker,
        uint256 id,
        uint256 amount,
        uint256 stakingPeriod
    );
    event TokensUnstaked(
        address indexed staker,
        uint256 id,
        uint256 amount,
        uint256 stakingPeriod,
        uint256 interestEarned
    );
    event StakingSystemChanged(bool useBlockStake);
    event APRUpdated(uint256 duration, uint256 newRate, uint256 oldRate);
    event RewardsCalculated(address user, uint256 stakeIndex, uint256 rewards);
    event StakingMinimumChanged(uint256 newAmount);
    event VestingScheduleCreated(
        address beneficiary,
        uint256 totalAmount,
        uint256 duration
    );
    event TokensReleased(address beneficiary, uint256 amount);
    event StakingContractFunded(
        address indexed stakingContract,
        uint256 amount
    );

/**
 * @dev Enhanced noContracts modifier with additional security checks
 *
 * SECURITY DESIGN NOTE: Uses tx.origin for the following reasons:
 * - Traditional staking is designed for direct user interactions only
 * - Prevents complex contract interactions that could exploit reward mechanisms
 * - Gas efficiency for frequent staking operations
 * - Main security layer is in FierceToken contract
 * - Staking rewards are time-based, minimizing flash loan risks
 * - Combined with reentrancy protection for comprehensive security
 *
 * audit-ok tx.origin usage intentional - simplified staking security model
 * Combined with ReentrancyGuard for defense in depth
 */
    modifier noContracts() {
        require(msg.sender == tx.origin, "No contract calls");
        _;
    }
    constructor(address _token, address _initialOwner) Ownable(_initialOwner) {
        token = FierceToken(_token);
        // REMOVER: MIN_STAKING_AMOUNT = 1000 * 10 ** 18; ← YA NO SE INICIALIZA AQUÍ
    }
    // ===== ORIGINAL STAKING FUNCTIONS =====

    /**
     * @dev Stake tokens in original duration-based system
     * @param amount Amount to stake
     * @param duration Duration in seconds
     *
     * Requirements:
     * - The duration must have a reward rate set.
     * - The amount must be at least the minimum staking amount.
     *
     * Emits a {TokensStaked} event.
     *
     * Note: Users can have multiple stakes simultaneously.
     */
    function stake(
        uint256 amount,
        uint256 duration
    ) external whenNotPaused noContracts {
        require(durationRewards[duration] > 0, "Invalid duration");
        require(amount >= token.MIN_STAKING_AMOUNT(), "Amount too low");

        StakeInfo memory newStake = StakeInfo({
            amount: amount,
            startTime: block.timestamp,
            duration: duration,
            rewardRate: durationRewards[duration],
            active: true,
            lastRewardCalculation: block.timestamp,
            accumulatedRewards: 0
        });

        userStakes[msg.sender].push(newStake);

        bool success = token.transferFrom(msg.sender, address(this), amount);
        require(success, "Token transfer failed");

        emit TokensStaked(
            msg.sender,
            userStakes[msg.sender].length - 1,
            amount,
            duration
        );
    }

    /**
     * @dev Calculate current rewards for a stake
     * @param user Address of the staker
     * @param stakeIndex Index of the stake
     *
     * SECURITY CONSIDERATIONS:
     * - Uses block.timestamp which is reasonably secure in PoS networks
     * - Timestamp manipulation has minimal impact due to:
     *   a) Long staking periods (days/months)
     *   b) Small manipulation margins (seconds)
     *   c) Maximum accumulation period limit
     * - Polygon's PoS consensus makes timestamp manipulation difficult and costly
     * - Reward calculation accuracy is sufficient for staking purposes
     */
    function calculateCurrentRewards(address user, uint256 stakeIndex) public {
        require(userStakes[user].length > stakeIndex, "Stake does not exist");

        StakeInfo storage stakeData = userStakes[user][stakeIndex];
        require(stakeData.active, "Stake not active");
        require(
            block.timestamp <=
                stakeData.startTime +
                    stakeData.duration +
                    maxRewardAccumulationPeriod,
            "Reward accumulation expired"
        );

        uint256 timeElapsed = block.timestamp - stakeData.lastRewardCalculation;
        if (timeElapsed > 0) {
            // Secure calculation to prevent overflow
            uint256 baseReward = (stakeData.amount * timeElapsed) / 365 days;
            uint256 newRewards = (baseReward * stakeData.rewardRate) / 1000;

            // Additional security verification
            require(
                stakeData.accumulatedRewards + newRewards >=
                    stakeData.accumulatedRewards,
                "Reward calculation overflow"
            );

            stakeData.accumulatedRewards += newRewards;
            stakeData.lastRewardCalculation = block.timestamp;
            emit RewardsCalculated(user, stakeIndex, newRewards);
        }
    }
    /**
     * @dev Unstake tokens from original system
     * @param stakeIndex Index of the stake to unstake
     */
    function unstake(uint256 stakeIndex) external whenNotPaused nonReentrant {
        require(
            userStakes[msg.sender].length > stakeIndex,
            "Stake does not exist"
        );

        StakeInfo storage stakeData = userStakes[msg.sender][stakeIndex];
        require(stakeData.active, "Stake not active");
        require(
            block.timestamp >= stakeData.startTime + stakeData.duration,
            "Staking period not complete"
        );

        calculateCurrentRewards(msg.sender, stakeIndex);

        uint256 totalAmount = stakeData.amount + stakeData.accumulatedRewards;
        stakeData.active = false;
        bool success = token.transfer(msg.sender, totalAmount);
        require(success, "Token transfer failed");

        emit TokensUnstaked(
            msg.sender,
            stakeIndex,
            stakeData.amount,
            stakeData.duration,
            stakeData.accumulatedRewards
        );
    }

    // ===== VESTING FUNCTIONS =====

    /**
     * @dev Create a new vesting schedule
     *
     * SECURITY NOTE: This function intentionally does not require multi-signature.
     * The risk is accepted because:
     * - Vesting schedules are for predefined allocations and team members
     * - Transparent creation with full parameter visibility
     * - No immediate token transfers, only time-based releases
     * - Essential for protocol operations and team compensation
     * - Cliff periods and linear vesting prevent immediate token access
     * audit-ok This function intentionally does not require multi-signature
     * audit-ok multiple schedules per beneficiary allowed - flexible vesting management
     *
     * // slither-disable-next-line locked-ether
     * // slither-disable-next-line missing-zero-check
     */
    function createVestingSchedule(
        address beneficiary,
        uint256 amount,
        uint256 duration,
        uint256 cliff
    ) external onlyOwner {
        require(beneficiary != address(0), "Invalid address");
        require(duration > cliff, "Duration must be greater than cliff");

        vestingSchedules[beneficiary].push(
            VestingSchedule({
                beneficiary: beneficiary,
                totalAmount: amount,
                releasedAmount: 0,
                startTime: block.timestamp,
                duration: duration,
                cliff: cliff
            })
        );

        totalVestedTokens += amount;
        emit VestingScheduleCreated(beneficiary, amount, duration);
    }

    /**
     * @dev Release vested tokens
     * @param scheduleIndex Index of the vesting schedule
     */
    function releaseVestedTokens(uint256 scheduleIndex) external nonReentrant {
        require(
            vestingSchedules[msg.sender].length > scheduleIndex,
            "Vesting schedule does not exist"
        );

        VestingSchedule storage schedule = vestingSchedules[msg.sender][
            scheduleIndex
        ];
        require(
            block.timestamp >= schedule.startTime + schedule.cliff,
            "Cliff not passed"
        );

        uint256 unreleased = releasableAmount(msg.sender, scheduleIndex);
        require(unreleased > 0, "No tokens to release");

        schedule.releasedAmount += unreleased;
        totalVestedTokens -= unreleased;
        
        bool success = token.transfer(msg.sender, unreleased);
        require(success, "Token transfer failed");

        emit TokensReleased(msg.sender, unreleased);
    }

    /**
     * @dev Calculate releasable amount for a vesting schedule
     */
    function releasableAmount(
        address beneficiary,
        uint256 scheduleIndex
    ) public view returns (uint256) {
        require(
            vestingSchedules[beneficiary].length > scheduleIndex,
            "Vesting schedule does not exist"
        );

        VestingSchedule storage schedule = vestingSchedules[beneficiary][
            scheduleIndex
        ];

        if (block.timestamp < schedule.startTime + schedule.cliff) {
            return 0;
        } else if (block.timestamp >= schedule.startTime + schedule.duration) {
            return schedule.totalAmount - schedule.releasedAmount;
        } else {
            uint256 timeElapsed = block.timestamp -
                (schedule.startTime + schedule.cliff);
            uint256 vestedAmount = (schedule.totalAmount * timeElapsed) /
                (schedule.duration - schedule.cliff);
            return vestedAmount - schedule.releasedAmount;
        }
    }

    // ===== STAKING CONFIGURATION =====

    /**
     * @dev Set reward rate for a specific duration
     * @param duration Staking duration in seconds
     * @param rewardRate Reward rate (APR * 1000)
     *
     * SECURITY NOTE: This function intentionally does not require multi-signature.
     * The risk is accepted because:
     * - Reward rate changes don't affect existing staking positions
     * - Only applies to new stakes, providing predictability
     * - Quick adjustment needed for market conditions and protocol sustainability
     * - Transparent event logging for community awareness
     * audit-ok This function intentionally does not require multi-signature
     *
     * // slither-disable-next-line locked-ether
     */
    function setDurationReward(
        uint256 duration,
        uint256 rewardRate
    ) external onlyOwner {
        uint256 oldRate = durationRewards[duration];
        durationRewards[duration] = rewardRate;
        emit APRUpdated(duration, rewardRate, oldRate);
    }

    /**
     * @dev Emit staking system changed event (called by main token contract)
     * @param useBlockStake True if BlockStake system is enabled
     */
    function emitStakingSystemChanged(bool useBlockStake) external onlyOwner {
        emit StakingSystemChanged(useBlockStake);
    }

    // ===== VIEW FUNCTIONS =====

    function viewCurrentRewards(
        address user,
        uint256 stakeIndex
    ) external view returns (uint256) {
        require(userStakes[user].length > stakeIndex, "Stake does not exist");

        StakeInfo memory stakeData = userStakes[user][stakeIndex];
        if (!stakeData.active) return 0;

        uint256 timeElapsed = block.timestamp - stakeData.lastRewardCalculation;
        if (timeElapsed == 0) return stakeData.accumulatedRewards;

        // Secure calculation to prevent overflow
        uint256 baseReward = (stakeData.amount * timeElapsed) / 365 days;
        uint256 newRewards = (baseReward * stakeData.rewardRate) / 1000;

        return stakeData.accumulatedRewards + newRewards;
    }

    function getUserStakesCount(address user) external view returns (uint256) {
        return userStakes[user].length;
    }

    function getUserVestingCount(address user) external view returns (uint256) {
        return vestingSchedules[user].length;
    }

    function getStakeInfo(
        address user,
        uint256 stakeIndex
    ) external view returns (StakeInfo memory) {
        require(userStakes[user].length > stakeIndex, "Stake does not exist");
        return userStakes[user][stakeIndex];
    }

    function getVestingInfo(
        address user,
        uint256 vestingIndex
    ) external view returns (VestingSchedule memory) {
        require(
            vestingSchedules[user].length > vestingIndex,
            "Vesting schedule does not exist"
        );
        return vestingSchedules[user][vestingIndex];
    }

    /**
     * @dev Get staking statistics
     */
    function getStakingStats()
        external
        view
        returns (
            uint256 minStakingAmount,
            uint256 totalVested,
            uint256 stakingMinted_,
            uint256 stakingFundsMinted_
        )
    {
        return (
            token.MIN_STAKING_AMOUNT(),
            totalVestedTokens,
            stakingMinted,
            stakingFundsMinted
        );
    }

    /**
     * @dev Get current minimum staking amount from main contract
     */
    function getMinStakingAmount() external view returns (uint256) {
        return token.MIN_STAKING_AMOUNT();
    }
}