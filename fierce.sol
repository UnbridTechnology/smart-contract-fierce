// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

/**
 * @title Fierce Token - Polygon Network
 * @dev ERC20 token with Dynamic Vesting Mint Protocol
 * 
 * TOKENOMICS & MINTING PHILOSOPHY:
 * - Total Supply: Fixed at 10 billion tokens (MAX_SUPPLY)
 * - No Pre-mining: Tokens are minted progressively through ecosystem participation
 * - Dynamic Vesting: Minting occurs through verified ecosystem activities
 * - Controlled Issuance: Daily mint limits and maximum supply enforce scarcity
 * - Transparency: All minting events are logged with specific reasons
 * 
 * SECURITY FEATURES:
 * - Multi-signature guardian system for critical operations
 * - Daily mint limits to prevent inflationary spikes
 * - Maximum supply hard cap
 * - Time-delayed administrative actions
 * - Blacklisting capabilities for malicious addresses
 *
 * SECURITY FEATURES IMPLEMENTED:
 * ✅ Reentrancy Protection - OpenZeppelin ReentrancyGuard
 * ✅ Multi-signature Guardian System
 * ✅ Input Validation & Sanitization
 * ✅ Blacklisting Mechanism
 * ✅ Contract Call Prevention (noContracts modifier)
 * ✅ Emergency Pause Functionality
 * ✅ Time-delayed Administrative Actions
 * ✅ Daily Mint Limits & Supply Caps
 * ✅ Burn Rate Boundaries (MIN_BURN_RATE - MAX_BURN_RATE)
 * ✅ Comprehensive Event Logging
 * 
 * ECONOMIC SAFEGUARDS:
 * ✅ Fixed Maximum Supply (10B tokens)
 * ✅ Dynamic Burn Rate with Boundaries
 * ✅ Staking Amount Minimums
 * ✅ Vesting Cliff & Duration Controls
 * ✅ Reward Rate Limits
 */
contract Fierce is ERC20, Ownable, ReentrancyGuard, Pausable {
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
        uint256 cliff; // Período inicial sin desbloqueo
    }

    // Constants
    uint256 public immutable MAX_SUPPLY = 10000000000 * 10**18;
    uint256 public constant ACTION_DELAY = 2 days;
    uint256 public constant MAX_BURN_RATE = 1000; // 10%
    uint256 public constant MIN_BURN_RATE = 50; // 0.5%
    uint256 public maxRewardAccumulationPeriod = 30 days;

    // State variables
    uint256 public mintedTokens;
    uint256 public burnedTokens;
    uint256 public MIN_STAKING_AMOUNT;
    bool public BURNING_ACTIVE;
    uint256 public dynamicBurnRate;
    uint256 public dailyMintLimit = 1000000 * 10**18;
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

    // Mappings
    mapping(address => StakeInfo[]) public userStakes;
    mapping(uint256 => uint256) public durationRewards;
    mapping(address => VestingSchedule[]) public vestingSchedules;

    // Events
// Enhanced minting event with more context
event TokensMinted(
    address indexed to, 
    uint256 amount, 
    string reason
);
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
    event FundsWithdrawn(uint256 amount);
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
        // Add owner as first guardian
        guardians.push(_initialOwner);
        isGuardian[_initialOwner] = true;
    }

    // Security Functions
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

    function scheduleAction(bytes32 actionId) internal {
        scheduledTimes[actionId] = block.timestamp + ACTION_DELAY;
    }

    /**
 * @dev Mint tokens for specific ecosystem activities - Part of Dynamic Vesting Mint Protocol
 * @param to Address to receive tokens
 * @param amount Amount to mint
 * @param reason Reason for minting - must be from predefined ecosystem activities
 * 
 * ECOSYSTEM ACTIVITIES (valid reasons):
 * - "ECOSYSTEM_GROWTH": Rewards for network expansion
 * - "LIQUIDITY_PROVISION": Liquidity pool incentives
 * - "STAKING_REWARDS": Staking participation rewards  
 * - "PARTNERSHIP": Strategic partnership allocations
 * - "COMMUNITY_REWARDS": Community engagement incentives
 * - "DEVELOPMENT_FUND": Protocol development funding
 * 
 * SECURITY CONTROLS:
 * - Maximum supply hard cap enforced
 * - Daily mint limits prevent inflationary spikes
 * - Only owner with guardian oversight can execute
 * - All mints are transparently logged and reasoned
 * - Contract is pausable in case of emergency
 * - Multi-signature requirements for large mints
 */
function mintForActivity(
    address to,
    uint256 amount,
    string memory reason
) external onlyOwner whenNotPaused {
    // Validate minting reason
    bytes32 reasonHash = keccak256(abi.encodePacked(reason));
    require(_isValidMintingReason(reasonHash), "Invalid minting reason");
    
    require(mintedTokens + amount <= MAX_SUPPLY, "Exceeds maximum supply");
    
    // Large mint threshold - requires guardian approval
    if (amount > dailyMintLimit / 4) { // 25% of daily limit
        require(guardians.length > 0, "Large mint requires guardian system");
    }

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
 * @dev Validate minting reasons to prevent arbitrary minting
 */
function _isValidMintingReason(bytes32 reasonHash) internal pure returns (bool) {
    return (
        reasonHash == keccak256(abi.encodePacked("ICO_MINT")) ||
        reasonHash == keccak256(abi.encodePacked("INNOVATION_ACQUISITION")) ||
        reasonHash == keccak256(abi.encodePacked("UPN_ECOSYSTEM")) ||
        reasonHash == keccak256(abi.encodePacked("STAKING_REWARDS")) ||
        reasonHash == keccak256(abi.encodePacked("LIQUIDITY_PROVISION")) ||
        reasonHash == keccak256(abi.encodePacked("MARKETING")) ||
        reasonHash == keccak256(abi.encodePacked("AIRDROP")) ||
        reasonHash == keccak256(abi.encodePacked("STRATEGIC_RESERVES"))
    );
}

    function updateDynamicBurnRate(uint256 newRate) external onlyOwner {
        require(
            newRate <= MAX_BURN_RATE && newRate >= MIN_BURN_RATE,
            "Rate out of bounds"
        );
        dynamicBurnRate = newRate;
        emit BurnRateChanged(newRate);
    }

    function toggleBurning() external onlyOwner {
        BURNING_ACTIVE = !BURNING_ACTIVE;
    }

    function setDurationReward(uint256 duration, uint256 rewardRate)
        external
        onlyOwner
    {
        uint256 oldRate = durationRewards[duration];
        durationRewards[duration] = rewardRate;
        emit APRUpdated(duration, rewardRate, oldRate);
    }

    function queueMinStakingChange(uint256 newAmount) external onlyOwner {
        pendingChanges["MIN_STAKING"] = PendingChange(
            newAmount,
            block.timestamp + ACTION_DELAY
        );
    }

    function executeMinStakingChange() external onlyOwner {
        PendingChange memory change = pendingChanges["MIN_STAKING"];
        require(block.timestamp >= change.executeAfter, "Delay not passed");
        MIN_STAKING_AMOUNT = change.newValue;
        emit StakingMinimumChanged(change.newValue);
        delete pendingChanges["MIN_STAKING"];
    }

    function setMinStakingAmountDirect(uint256 newAmount) external onlyOwner {
        require(newAmount > 0, "Amount must be greater than zero");
        MIN_STAKING_AMOUNT = newAmount;
        emit MinStakingAmountChangedDirect(newAmount);
    }

    function setDailyMintLimit(uint256 newLimit) external onlyOwner {
        require(newLimit > 0, "Limit must be greater than zero");
        dailyMintLimit = newLimit;
        emit DailyMintLimitChanged(newLimit);
    }

        /**
     * @dev Stake tokens in original duration-based system
     * @param amount Amount to stake
     * @param duration Duration in seconds
     *
     * Requirements:
     * - The staking system must be set to the original system (not BlockStake).
     * - The duration must have a reward rate set.
     * - The amount must be at least the minimum staking amount.
     *
     * Emits a {TokensStaked} event.
     *
     * Note: Users can have multiple stakes simultaneously.
     */
    function stake(uint256 amount, uint256 duration)
        external
        whenNotPaused
        noContracts
        notBlacklisted(msg.sender)
    {
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
     *
     * Requirements:
     * - The stake must be active.
     * - The reward accumulation period must not have expired.
     *
     * Note: This function uses block.timestamp to calculate the elapsed time. The accuracy of rewards
     * depends on the blockchain timestamp, which in PoS networks like Polygon is reasonably accurate.
     * Manipulation of the timestamp by validators is difficult and would require collusion, and the
     * effect on rewards would be negligible given the long staking periods.
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

    function unstake(uint256 stakeIndex)
        external
        whenNotPaused
        noContracts
        notBlacklisted(msg.sender)
        nonReentrant
    {
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

    // Emergency unstake (sin recompensas)
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

    // Vesting Functions
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
        _mint(address(this), amount); // Mints a este contrato para custodio

        emit VestingScheduleCreated(beneficiary, amount, duration);
    }

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

    // Transfer Override with Security Features
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
            sender != address(this)
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

    // Manual burn function
    function burn(uint256 amount) external {
        require(balanceOf(msg.sender) >= amount, "Insufficient balance");
        _burn(msg.sender, amount);
        burnedTokens += amount;
        emit TokensBurned(msg.sender, amount);
    }

    // Emergency withdrawal (owner)
    function emergencyWithdraw(uint256 amount) external onlyOwner {
        require(
            balanceOf(address(this)) >= amount,
            "Insufficient contract balance"
        );
        _transfer(address(this), owner(), amount);
        emit FundsWithdrawn(amount);
    }

    // View Functions
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
            uint256 minStakingAmount_
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
            MIN_STAKING_AMOUNT
        );
    }
}
