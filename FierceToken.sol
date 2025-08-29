// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "./IFierceStaking.sol";

/**
 * @title Fierce Token - Polygon Network
 * @dev ERC20 token with staking capabilities
 */
contract FierceToken is ERC20, Ownable, ReentrancyGuard, Pausable {
    // Interfaces
    FierceStaking public stakingContract;

    // Original staking structure
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
    uint256 public immutable MAX_SUPPLY = 10000000000 * 10**18;
    uint256 public constant ACTION_DELAY = 2 days;
    uint256 public constant MAX_BURN_RATE = 1000; // 10%
    uint256 public constant MIN_BURN_RATE = 50; // 0.5%
    uint256 public maxRewardAccumulationPeriod = 30 days;
    uint256 public stakingMinted; // Acumulador
    uint256 public stakingFundsMinted;

    // State variables
    uint256 public mintedTokens;
    uint256 public burnedTokens;
    uint256 public MIN_STAKING_AMOUNT;
    bool public BURNING_ACTIVE;
    uint256 public dynamicBurnRate;
    uint256 public dailyMintLimit = 100000000 * 10**18;
    uint256 public lastMintTime;
    uint256 public mintedInPeriod;
    uint256 public totalVestedTokens;

    // Security structures
    struct PendingChange {
        uint256 newValue;
        uint256 executeAfter;
    }

    mapping(string => PendingChange) public pendingChanges;
    address[] public guardians;
    mapping(address => bool) public isGuardian;
    mapping(address => bool) public isBlacklisted;
    mapping(bytes32 => uint256) public scheduledTimes;

    // Original system mappings
    mapping(address => StakeInfo[]) public userStakes;
    mapping(uint256 => uint256) public durationRewards;
    mapping(address => VestingSchedule[]) public vestingSchedules;

    // Events
    event TokensMinted(address indexed to, uint256 amount, string reason);
    event TokensBurned(address indexed from, uint256 amount);
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
    event BurnRateChanged(uint256 newRate);
    event StakingMinimumChanged(uint256 newAmount);
    event GuardianAdded(address guardian);
    event GuardianRemoved(address guardian);
    event AddressBlacklisted(address wallet);
    event AddressWhitelisted(address wallet);
    event VestingScheduleCreated(
        address beneficiary,
        uint256 totalAmount,
        uint256 duration
    );
    event TokensReleased(address beneficiary, uint256 amount);
    event DailyMintLimitChanged(uint256 newLimit);
    event MinStakingAmountChangedDirect(uint256 newAmount);
    event StakingContractFunded(
        address indexed stakingContract,
        uint256 amount
    );

    // Modifiers
    modifier onlyGuardian() {
        require(isGuardian[msg.sender], "Not guardian");
        _;
    }

    modifier notBlacklisted(address account) {
        require(!isBlacklisted[account], "Address blacklisted");
        _;
    }

    modifier noContracts() {
        require(msg.sender == tx.origin, "No contract calls");
        _;
    }

    modifier scheduledAction(bytes32 actionId) {
        require(
            block.timestamp >= scheduledTimes[actionId],
            "Action not ready"
        );
        _;
    }

    constructor(uint256 _initialMinStakingAmount, address _initialOwner)
        ERC20("Fierce", "Fierce")
        Ownable(_initialOwner)
    {
        MIN_STAKING_AMOUNT = _initialMinStakingAmount;
        dynamicBurnRate = 150; // Initial 1.5%
        guardians.push(_initialOwner);
        isGuardian[_initialOwner] = true;
    }

    // ===== STAKING CONTRACT MANAGEMENT =====

    /**
     * @dev Set the staking contract address
     * @param _stakingContract Address of the staking contract
     */
    function setStakingContract(address _stakingContract) external onlyOwner {
        stakingContract = FierceStaking(_stakingContract);
    }

    /**
     * @dev Toggle between original staking system and BlockStake system
     * @param _useBlockStake True to enable BlockStake system, false for original
     */
    function toggleStakingSystem(bool _useBlockStake) external onlyOwner {
        require(
            address(stakingContract) != address(0),
            "Staking contract not set"
        );
        stakingContract.setStakingSystem(_useBlockStake);
        emit StakingSystemChanged(_useBlockStake);
    }

    // ===== ORIGINAL STAKING FUNCTIONS =====

    /**
     * @dev Stake tokens in original duration-based system
     * @param amount Amount to stake
     * @param duration Duration in seconds
     */
    function stake(uint256 amount, uint256 duration)
        external
        whenNotPaused
        noContracts
        notBlacklisted(msg.sender)
    {
        require(
            address(stakingContract) == address(0) ||
                !stakingContract.useBlockStakeSystem(),
            "Use BlockStake staking"
        );
        require(durationRewards[duration] > 0, "Invalid duration");
        require(amount >= MIN_STAKING_AMOUNT, "Amount too low");

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
        _transfer(msg.sender, address(this), amount);
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
     */
    function calculateCurrentRewards(address user, uint256 stakeIndex) public {
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
            uint256 newRewards = (stakeData.amount *
                stakeData.rewardRate *
                timeElapsed) / (365 days * 1000);
            stakeData.accumulatedRewards += newRewards;
            stakeData.lastRewardCalculation = block.timestamp;
            emit RewardsCalculated(user, stakeIndex, newRewards);
        }
    }

    /**
     * @dev Unstake tokens from original system
     * @param stakeIndex Index of the stake to unstake
     */
    function unstake(uint256 stakeIndex)
        external
        whenNotPaused
        noContracts
        notBlacklisted(msg.sender)
        nonReentrant
    {
        require(
            address(stakingContract) == address(0) ||
                !stakingContract.useBlockStakeSystem(),
            "Use BlockStake unstaking"
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

        _transfer(address(this), msg.sender, totalAmount);
        emit TokensUnstaked(
            msg.sender,
            stakeIndex,
            stakeData.amount,
            stakeData.duration,
            stakeData.accumulatedRewards
        );
    }

    /**
     * @dev Emergency unstake (without rewards)
     * @param stakeIndex Index of the stake to unstake
     */
    function emergencyUnstake(uint256 stakeIndex)
        external
        whenNotPaused
        noContracts
        notBlacklisted(msg.sender)
        nonReentrant
    {
        StakeInfo storage stakeData = userStakes[msg.sender][stakeIndex];
        require(stakeData.active, "Stake not active");

        uint256 amount = stakeData.amount;
        stakeData.active = false;

        _transfer(address(this), msg.sender, amount);
        emit TokensUnstaked(
            msg.sender,
            stakeIndex,
            amount,
            stakeData.duration,
            0
        );
    }

    // ===== TOKEN MANAGEMENT FUNCTIONS =====

    /**
     * @dev Mint tokens for specific activities
     * @param to Address to receive tokens
     * @param amount Amount to mint
     * @param reason Reason for minting
     */
    function mintForActivity(
        address to,
        uint256 amount,
        string memory reason
    ) external onlyOwner whenNotPaused {
        require(mintedTokens + amount <= MAX_SUPPLY, "Exceeds maximum supply");

        if (block.timestamp > lastMintTime + 1 days) {
            mintedInPeriod = 0;
            lastMintTime = block.timestamp;
        }
        require(
            mintedInPeriod + amount <= dailyMintLimit,
            "Daily limit exceeded"
        );

        _mint(to, amount);
        mintedTokens += amount;
        mintedInPeriod += amount;
        emit TokensMinted(to, amount, reason);
    }

    /**
     * @dev Mint tokens for staking
     * @param to Address to receive tokens
     * @param amount Amount to mint
     */
    function mintForStaking(
        address to,
        uint256 amount
    ) external onlyOwner whenNotPaused {
        require(mintedTokens + amount <= MAX_SUPPLY, "Exceeds maximum supply");
        _mint(to, amount);
        mintedTokens += amount;
        mintedInPeriod += amount;
        emit TokensMinted(to, amount, "STAKING_REWARDS");
    }

    /**
     * @dev Override transfer function with burn and security features
     */
    function _transfer(
        address sender,
        address recipient,
        uint256 amount
    )
        internal
        virtual
        override
        nonReentrant
        whenNotPaused
        notBlacklisted(sender)
        notBlacklisted(recipient)
    {
        require(amount > 0, "Transfer amount must be greater than zero");

        if (
            BURNING_ACTIVE &&
            sender != owner() &&
            recipient != address(this) &&
            sender != address(this) &&
            (address(stakingContract) == address(0) ||
                recipient != address(stakingContract))
        ) {
            uint256 burnAmount = (amount * dynamicBurnRate) / 10000;
            super._burn(sender, burnAmount);
            burnedTokens += burnAmount;
            super._transfer(sender, recipient, amount - burnAmount);
            emit TokensBurned(sender, burnAmount);
        } else {
            super._transfer(sender, recipient, amount);
        }
    }

    /**
     * @dev Burn tokens
     * @param amount Amount to burn
     */
    function burn(uint256 amount) external {
        require(balanceOf(msg.sender) >= amount, "Insufficient balance");
        _burn(msg.sender, amount);
        burnedTokens += amount;
        emit TokensBurned(msg.sender, amount);
    }

    /**
     * @dev Update dynamic burn rate
     * @param newRate New burn rate (50 = 0.5%, 1000 = 10%)
     */
    function updateDynamicBurnRate(uint256 newRate) external onlyOwner {
        require(
            newRate <= MAX_BURN_RATE && newRate >= MIN_BURN_RATE,
            "Rate out of bounds"
        );
        dynamicBurnRate = newRate;
        emit BurnRateChanged(newRate);
    }

    /**
     * @dev Toggle burning functionality
     */
    function toggleBurning() external onlyOwner {
        BURNING_ACTIVE = !BURNING_ACTIVE;
    }

    // ===== STAKING CONFIGURATION =====

    /**
     * @dev Set reward rate for a specific duration
     * @param duration Staking duration in seconds
     * @param rewardRate Reward rate (APR * 1000)
     */
    function setDurationReward(uint256 duration, uint256 rewardRate)
        external
        onlyOwner
    {
        uint256 oldRate = durationRewards[duration];
        durationRewards[duration] = rewardRate;
        emit APRUpdated(duration, rewardRate, oldRate);
    }

    /**
     * @dev Set minimum staking amount
     * @param newAmount New minimum amount
     */
    function setMinStakingAmountDirect(uint256 newAmount) external onlyOwner {
        require(newAmount > 0, "Amount must be greater than zero");
        MIN_STAKING_AMOUNT = newAmount;
        emit MinStakingAmountChangedDirect(newAmount);
    }

    /**
     * @dev Set daily mint limit
     * @param newLimit New daily limit
     */
    function setDailyMintLimit(uint256 newLimit) external onlyOwner {
        require(newLimit > 0, "Limit must be greater than zero");
        dailyMintLimit = newLimit;
        emit DailyMintLimitChanged(newLimit);
    }

    // ===== VESTING FUNCTIONS =====

    /**
     * @dev Create a new vesting schedule
     */
    function createVestingSchedule(
        address beneficiary,
        uint256 amount,
        uint256 duration,
        uint256 cliff
    ) external onlyOwner {
        require(mintedTokens + amount <= MAX_SUPPLY, "Exceeds max supply");
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
        mintedTokens += amount;
        _mint(address(this), amount);

        emit VestingScheduleCreated(beneficiary, amount, duration);
    }

    /**
     * @dev Release vested tokens
     * @param scheduleIndex Index of the vesting schedule
     */
    function releaseVestedTokens(uint256 scheduleIndex)
        external
        nonReentrant
        notBlacklisted(msg.sender)
    {
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
        _transfer(address(this), msg.sender, unreleased);

        emit TokensReleased(msg.sender, unreleased);
    }

    /**
     * @dev Calculate releasable amount for a vesting schedule
     */
    function releasableAmount(address beneficiary, uint256 scheduleIndex)
        public
        view
        returns (uint256)
    {
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

    // ===== SECURITY FUNCTIONS =====

    function pause() public onlyOwner {
        _pause();
    }

    function unpause() public onlyOwner {
        _unpause();
    }

    function addGuardian(address guardian) external onlyOwner {
        require(!isGuardian[guardian], "Already guardian");
        guardians.push(guardian);
        isGuardian[guardian] = true;
        emit GuardianAdded(guardian);
    }

    function removeGuardian(address guardian) external onlyOwner {
        require(isGuardian[guardian], "Not guardian");
        isGuardian[guardian] = false;
        emit GuardianRemoved(guardian);
    }

    function blacklistAddress(address wallet) external onlyOwner {
        isBlacklisted[wallet] = true;
        emit AddressBlacklisted(wallet);
    }

    function whitelistAddress(address wallet) external onlyOwner {
        isBlacklisted[wallet] = false;
        emit AddressWhitelisted(wallet);
    }

    // ===== VIEW FUNCTIONS =====

    /**
     * @dev Get contract statistics
     */
    function getContractStats()
        external
        view
        returns (
            uint256 totalSupply_,
            uint256 mintedTokens_,
            uint256 burnedTokens_,
            uint256 contractBalance_,
            uint256 totalVestedTokens_,
            bool burningActive_,
            uint256 dailyMintLimit_,
            uint256 minStakingAmount_,
            bool blockStakeActive_,
            uint256 totalStakedBW_
        )
    {
        return (
            totalSupply(),
            mintedTokens,
            burnedTokens,
            balanceOf(address(this)),
            totalVestedTokens,
            BURNING_ACTIVE,
            dailyMintLimit,
            MIN_STAKING_AMOUNT,
            address(stakingContract) != address(0)
                ? stakingContract.useBlockStakeSystem()
                : false,
            address(stakingContract) != address(0)
                ? stakingContract.totalStakedTokens()
                : 0
        );
    }

    function viewCurrentRewards(address user, uint256 stakeIndex)
        external
        view
        returns (uint256)
    {
        StakeInfo memory stakeData = userStakes[user][stakeIndex];
        if (!stakeData.active) return 0;

        uint256 timeElapsed = block.timestamp - stakeData.lastRewardCalculation;
        uint256 newRewards = (stakeData.amount *
            stakeData.rewardRate *
            timeElapsed) / (365 days * 1000);

        return stakeData.accumulatedRewards + newRewards;
    }

    function getUserStakesCount(address user) external view returns (uint256) {
        return userStakes[user].length;
    }

    function getUserVestingCount(address user) external view returns (uint256) {
        return vestingSchedules[user].length;
    }

    function getGuardians() external view returns (address[] memory) {
        return guardians;
    }

    function getStakeInfo(address user, uint256 stakeIndex)
        external
        view
        returns (StakeInfo memory)
    {
        return userStakes[user][stakeIndex];
    }

    function getVestingInfo(address user, uint256 vestingIndex)
        external
        view
        returns (VestingSchedule memory)
    {
        return vestingSchedules[user][vestingIndex];
    }

    /**
     * @dev Emergency withdraw tokens from contract
     * @param amount Amount to withdraw
     */
    function emergencyWithdraw(uint256 amount) external onlyOwner {
        require(
            balanceOf(address(this)) >= amount,
            "Insufficient contract balance"
        );
        _transfer(address(this), owner(), amount);
    }

}
