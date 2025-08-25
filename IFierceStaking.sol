// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./FierceToken.sol";

/**
 * @title Fierce Staking System - Polygon Network
 * @dev Block-based staking system optimized for Polygon
 */
contract FierceStaking is Ownable, ReentrancyGuard, Pausable {
    FierceToken public token;

    // BlockStake staking structure
    struct BlockStake {
        uint256 amount; // Amount staked
        uint256 rewardDebt; // Reward debt for calculations
        uint256 stakeBlock; // Block when staked
        bool active; // Active status
    }

    // System info structure
    struct SystemInfo {
        bool blockStakeActive;
        uint256 currentBlock;
        uint256 emissionStart;
        uint256 emissionEnd;
        uint256 totalStaked;
        uint256 currentAPY;
        uint256 tokensPerBlock;
        uint256 blocksRemaining;
        uint256 totalEmitted;
    }

    // ===== STATE VARIABLE =====
    bool public claimsEnabled; //Enable claims

    // Constants
    uint256 public constant TOKENS_PER_BLOCK = 21.71 * 10**18;
    uint256 public constant EMISSION_DURATION_BLOCKS = 41215304; // ~36 months on Polygon (~2.3s blocks)
    uint256 public constant PRECISION = 1e12; // Precision for reward calculations
    uint256 public constant POLYGON_BLOCKS_PER_YEAR = 13711304;

    // State variables
    bool public useBlockStakeSystem = false;
    uint256 public emissionStartBlock;
    uint256 public emissionEndBlock;
    uint256 public totalStakedTokens;
    uint256 public lastUpdateBlock;
    uint256 public accTokensPerShare;
    uint256 public totalEmittedTokens;

    // Mappings
    mapping(address => BlockStake[]) public blockStakes;
    mapping(address => uint256) public userStakedAmount;
    mapping(address => uint256) public userPendingRewards;

    // Events
    event BlockStakeStaked(
        address indexed user,
        uint256 stakeId,
        uint256 amount,
        uint256 blockNumber
    );
    event BlockStakeUnstaked(
        address indexed user,
        uint256 stakeId,
        uint256 amount,
        uint256 rewards
    );
    event BlockStakeRewardsClaimed(address indexed user, uint256 amount);
    event PoolUpdated(
        uint256 blockNumber,
        uint256 accTokensPerShare,
        uint256 totalStaked
    );
    event EmissionStarted(uint256 startBlock, uint256 endBlock);
    event StakingSystemChanged(bool useBlockStake);

    // Modifiers
    modifier onlyActiveEmission() {
        require(useBlockStakeSystem, "BlockStake system not active");
        require(block.number >= emissionStartBlock, "Emission not started");
        require(block.number <= emissionEndBlock, "Emission ended");
        _;
    }

    modifier onlyWhenClaimsEnabled() {
        require(claimsEnabled, "Claim de recompensas deshabilitado");
        _;
    }

    constructor(address _token) Ownable(msg.sender) {
        token = FierceToken(_token);
        lastUpdateBlock = block.number;
    }

    // ===== CONTROL CLAIMS =====
    function setClaimsEnabled(bool _enabled) external onlyOwner {
        claimsEnabled = _enabled;
    }

    // ===== STAKING SYSTEM MANAGEMENT =====

    /**
     * @dev Toggle between original staking system and BlockStake system
     * @param _useBlockStake True to enable BlockStake system, false for original
     */
    function setStakingSystem(bool _useBlockStake) external onlyOwner {
        useBlockStakeSystem = _useBlockStake;
        emit StakingSystemChanged(_useBlockStake);
    }

    /**
     * @dev Start BlockStake emission system
     * Can only be called once
     */
    function startBlockStakeEmission() external onlyOwner {
        require(emissionStartBlock == 0, "Emission already started");
        require(useBlockStakeSystem, "BlockStake system not enabled");

        emissionStartBlock = block.number;
        emissionEndBlock = block.number + EMISSION_DURATION_BLOCKS;
        lastUpdateBlock = block.number;

        emit EmissionStarted(emissionStartBlock, emissionEndBlock);
    }

    // ===== STAKING FUNCTIONS =====

    /**
     * @dev Update pool rewards - calculates and distributes block rewards
     * Should be called before any stake/unstake operation
     */
    function updatePool() public {
        if (!useBlockStakeSystem || emissionStartBlock == 0) return;

        uint256 currentBlock = block.number;
        if (currentBlock <= lastUpdateBlock || totalStakedTokens == 0) return;

        uint256 blocksToReward = (
            currentBlock > emissionEndBlock ? emissionEndBlock : currentBlock
        ) - lastUpdateBlock;
        if (blocksToReward == 0) return;

        uint256 totalReward = blocksToReward * TOKENS_PER_BLOCK;
        uint256 contractBalance = token.balanceOf(address(this));

        // Ajusta las recompensas si el balance del contrato es insuficiente
        if (totalReward > contractBalance) {
            totalReward = contractBalance; // Usa solo lo disponible
        }

        accTokensPerShare += (totalReward * PRECISION) / totalStakedTokens;
        lastUpdateBlock = currentBlock;
        emit PoolUpdated(currentBlock, accTokensPerShare, totalStakedTokens);
    }

    /**
     * @dev Stake tokens in BlockStake system
     * @param amount Amount of tokens to stake
     */
    function blockStake(uint256 amount)
        external
        whenNotPaused
        nonReentrant
        onlyActiveEmission
    {
        require(amount >= token.MIN_STAKING_AMOUNT(), "Amount below minimum");
        require(token.balanceOf(msg.sender) >= amount, "Insufficient balance");

        updatePool();

        uint256 pending = calculatePendingRewards(msg.sender);
        if (pending > 0) {
            userPendingRewards[msg.sender] += pending;
        }

        token.transferFrom(msg.sender, address(this), amount);

        blockStakes[msg.sender].push(
            BlockStake({
                amount: amount,
                rewardDebt: (amount * accTokensPerShare) / PRECISION,
                stakeBlock: block.number,
                active: true
            })
        );

        totalStakedTokens += amount;
        userStakedAmount[msg.sender] += amount;

        emit BlockStakeStaked(
            msg.sender,
            blockStakes[msg.sender].length - 1,
            amount,
            block.number
        );
    }

    /**
     * @dev Stake tokens in BlockStake system on behalf of another user (Owner only)
     * @param user Address of the user to stake for
     * @param amount Amount of tokens to stake
     */
    function blockStakeFor(address user, uint256 amount)
        external
        onlyOwner
        whenNotPaused
        nonReentrant
        onlyActiveEmission
    {
        require(amount >= token.MIN_STAKING_AMOUNT(), "Amount below minimum");
        require(token.balanceOf(user) >= amount, "Insufficient balance");

        updatePool();

        uint256 pending = calculatePendingRewards(user);
        if (pending > 0) {
            userPendingRewards[user] += pending;
        }

        token.transferFrom(user, address(this), amount);

        blockStakes[user].push(
            BlockStake({
                amount: amount,
                rewardDebt: (amount * accTokensPerShare) / PRECISION,
                stakeBlock: block.number,
                active: true
            })
        );

        totalStakedTokens += amount;
        userStakedAmount[user] += amount;

        emit BlockStakeStaked(
            user,
            blockStakes[user].length - 1,
            amount,
            block.number
        );
    }

    /**
     * @dev Unstake tokens from BlockStake system
     * @param stakeId Index of the stake to unstake
     */
    function blockUnstake(uint256 stakeId) external whenNotPaused nonReentrant {
        require(useBlockStakeSystem, "BlockStake system not active");
        require(stakeId < blockStakes[msg.sender].length, "Invalid stake ID");

        BlockStake storage stake = blockStakes[msg.sender][stakeId];
        require(stake.active, "Stake not active");

        updatePool();

        uint256 stakeRewards = ((stake.amount * accTokensPerShare) /
            PRECISION) - stake.rewardDebt;
        uint256 totalRewards = stakeRewards + userPendingRewards[msg.sender];

        stake.active = false;
        totalStakedTokens -= stake.amount;
        userStakedAmount[msg.sender] -= stake.amount;
        userPendingRewards[msg.sender] = 0;

        uint256 totalAmount = stake.amount + totalRewards;
        token.transfer(msg.sender, totalAmount);

        emit BlockStakeUnstaked(
            msg.sender,
            stakeId,
            stake.amount,
            totalRewards
        );
    }

    /**
     * @dev Unstake all active stakes from BlockStake system
     */
    function blockUnstakeAll() external whenNotPaused nonReentrant {
        require(useBlockStakeSystem, "BlockStake system not active");
        require(blockStakes[msg.sender].length > 0, "No stakes found");

        updatePool();

        uint256 totalAmountToUnstake = 0;
        uint256 totalRewards = userPendingRewards[msg.sender];
        uint256 activeStakesCount = 0;

        // Calculate total rewards from all active stakes
        for (uint256 i = 0; i < blockStakes[msg.sender].length; i++) {
            BlockStake storage stake = blockStakes[msg.sender][i];
            if (stake.active) {
                uint256 stakeRewards = ((stake.amount * accTokensPerShare) /
                    PRECISION) - stake.rewardDebt;
                totalRewards += stakeRewards;
                totalAmountToUnstake += stake.amount;
                stake.active = false;
                activeStakesCount++;
            }
        }

        require(activeStakesCount > 0, "No active stakes to unstake");

        // Update state variables
        totalStakedTokens -= totalAmountToUnstake;
        userStakedAmount[msg.sender] -= totalAmountToUnstake;
        userPendingRewards[msg.sender] = 0;

        // Transfer all tokens and rewards
        uint256 totalAmount = totalAmountToUnstake + totalRewards;
        token.transfer(msg.sender, totalAmount);

        emit BlockStakeUnstaked(
            msg.sender,
            type(uint256).max, // Special ID indicating "all stakes"
            totalAmountToUnstake,
            totalRewards
        );
    }

    /**
     * @dev Claim accumulated rewards without unstaking
     */
    function claimBlockStakeRewards()
        external
        whenNotPaused
        nonReentrant
        onlyWhenClaimsEnabled
    {
        require(useBlockStakeSystem, "BlockStake system not active");

        updatePool();

        uint256 totalPending = calculatePendingRewards(msg.sender) +
            userPendingRewards[msg.sender];
        require(totalPending > 0, "No rewards to claim");

        for (uint256 i = 0; i < blockStakes[msg.sender].length; i++) {
            BlockStake storage stake = blockStakes[msg.sender][i];
            if (stake.active) {
                stake.rewardDebt =
                    (stake.amount * accTokensPerShare) /
                    PRECISION;
            }
        }

        userPendingRewards[msg.sender] = 0;
        token.transfer(msg.sender, totalPending);

        emit BlockStakeRewardsClaimed(msg.sender, totalPending);
    }

/**
 * @dev Claim and automatically restake rewards for a user (Owner only)
 * @param user Address of the user to claim and restake for
 */
function claimAndStake(address user)
    external
    onlyOwner
    whenNotPaused
    nonReentrant
    onlyWhenClaimsEnabled
{
    require(useBlockStakeSystem, "BlockStake system not active");
    
    updatePool();

    uint256 totalPending = calculatePendingRewards(user) + userPendingRewards[user];
    require(totalPending > 0, "No rewards to claim and stake");

    // Reset pending rewards and update reward debt for all active stakes
    for (uint256 i = 0; i < blockStakes[user].length; i++) {
        BlockStake storage stake = blockStakes[user][i];
        if (stake.active) {
            stake.rewardDebt = (stake.amount * accTokensPerShare) / PRECISION;
        }
    }

    userPendingRewards[user] = 0;

    // Instead of transferring, we create a new stake with the rewards
    blockStakes[user].push(
        BlockStake({
            amount: totalPending,
            rewardDebt: (totalPending * accTokensPerShare) / PRECISION,
            stakeBlock: block.number,
            active: true
        })
    );

    totalStakedTokens += totalPending;
    userStakedAmount[user] += totalPending;

    emit BlockStakeStaked(
        user,
        blockStakes[user].length - 1,
        totalPending,
        block.number
    );
    
    // Emit additional event to indicate auto-restaking
    emit BlockStakeRewardsClaimed(user, totalPending);
}

    // ===== VIEW FUNCTIONS =====

    /**
     * @dev Calculate pending rewards for a user in BlockStake system
     * @param user Address to calculate rewards for
     * @return Total pending rewards
     */
    function calculatePendingRewards(address user)
        public
        view
        returns (uint256)
    {
        if (!useBlockStakeSystem || totalStakedTokens == 0) return 0;

        uint256 tempAccTokensPerShare = accTokensPerShare;

        if (block.number > lastUpdateBlock && totalStakedTokens > 0) {
            uint256 currentBlock = block.number;
            uint256 endBlock = currentBlock > emissionEndBlock
                ? emissionEndBlock
                : currentBlock;
            uint256 blocksToReward = endBlock - lastUpdateBlock;

            if (blocksToReward > 0) {
                uint256 totalReward = blocksToReward * TOKENS_PER_BLOCK;
                tempAccTokensPerShare +=
                    (totalReward * PRECISION) /
                    totalStakedTokens;
            }
        }

        uint256 totalPending = 0;
        for (uint256 i = 0; i < blockStakes[user].length; i++) {
            BlockStake memory stake = blockStakes[user][i];
            if (stake.active) {
                uint256 stakePending = ((stake.amount * tempAccTokensPerShare) /
                    PRECISION) - stake.rewardDebt;
                totalPending += stakePending;
            }
        }

        return totalPending;
    }

    /**
     * @dev Get current APY for BlockStake system
     * @return Current APY as percentage (scaled by 100)
     */
    function getCurrentAPY() external view returns (uint256) {
        if (!useBlockStakeSystem || totalStakedTokens == 0) return 0;

        uint256 annualEmission = TOKENS_PER_BLOCK * POLYGON_BLOCKS_PER_YEAR;
        return (annualEmission * 100) / totalStakedTokens;
    }

    /**
     * @dev Get BlockStake system stats
     */
    function getBlockStakeStats()
        external
        view
        returns (
            bool active,
            uint256 startBlock,
            uint256 endBlock,
            uint256 currentBlock,
            uint256 totalStaked,
            uint256 totalEmitted,
            uint256 tokensPerBlock,
            uint256 accPerShare
        )
    {
        return (
            useBlockStakeSystem,
            emissionStartBlock,
            emissionEndBlock,
            block.number,
            totalStakedTokens,
            totalEmittedTokens,
            TOKENS_PER_BLOCK,
            accTokensPerShare
        );
    }

    /**
     * @dev Get user's BlockStake stakes count
     * @param user Address to check
     * @return Number of stakes
     */
    function getUserBlockStakesCount(address user)
        external
        view
        returns (uint256)
    {
        return blockStakes[user].length;
    }

    /**
     * @dev Get detailed info about a specific stake
     * @param user Address of the staker
     * @param stakeIndex Index of the stake
     * @return Stake information
     */
    function getBlockStakeInfo(address user, uint256 stakeIndex)
        external
        view
        returns (BlockStake memory)
    {
        return blockStakes[user][stakeIndex];
    }

    /**
     * @dev Get comprehensive system information
     * @return systemInfo Struct containing all relevant system data
     */
    function getSystemInfo()
        external
        view
        returns (SystemInfo memory systemInfo)
    {
        systemInfo.blockStakeActive = useBlockStakeSystem;
        systemInfo.currentBlock = block.number;
        systemInfo.emissionStart = emissionStartBlock;
        systemInfo.emissionEnd = emissionEndBlock;
        systemInfo.totalStaked = totalStakedTokens;

        if (useBlockStakeSystem && totalStakedTokens > 0) {
            uint256 secondsPerYear = 365 days;
            uint256 blocksPerYear = (secondsPerYear * 100) / 23; // 2.3 seconds per block
            uint256 annualTokensEmitted = blocksPerYear * TOKENS_PER_BLOCK;
            systemInfo.currentAPY =
                (annualTokensEmitted * 10000) /
                totalStakedTokens;
        }

        systemInfo.tokensPerBlock = TOKENS_PER_BLOCK;

        if (emissionStartBlock > 0 && block.number < emissionEndBlock) {
            systemInfo.blocksRemaining = emissionEndBlock - block.number;
        }

        systemInfo.totalEmitted = totalEmittedTokens;
    }

    /**
     * @dev Get emission progress
     * @return blocksCompleted Blocks completed since emission start
     * @return totalBlocks Total blocks in emission period
     * @return percentComplete Percentage complete (scaled by 100)
     * @return blocksRemaining Blocks remaining
     */
    function getEmissionProgress()
        external
        view
        returns (
            uint256 blocksCompleted,
            uint256 totalBlocks,
            uint256 percentComplete,
            uint256 blocksRemaining
        )
    {
        if (emissionStartBlock == 0) {
            return (0, EMISSION_DURATION_BLOCKS, 0, EMISSION_DURATION_BLOCKS);
        }

        totalBlocks = EMISSION_DURATION_BLOCKS;

        if (block.number < emissionStartBlock) {
            blocksCompleted = 0;
            blocksRemaining = totalBlocks;
        } else if (block.number >= emissionEndBlock) {
            blocksCompleted = totalBlocks;
            blocksRemaining = 0;
        } else {
            blocksCompleted = block.number - emissionStartBlock;
            blocksRemaining = emissionEndBlock - block.number;
        }

        percentComplete = totalBlocks > 0
            ? (blocksCompleted * 10000) / totalBlocks
            : 0;
    }

    /**
     * @dev Emergency function to update pool manually
     * Useful for maintenance or if automatic updates fail
     */
    function forceUpdatePool() external onlyOwner {
        updatePool();
    }

    function remainingRewards() external view returns (uint256) {
        return token.balanceOf(address(this));
    }

    /**
     * @dev Pause contract functionality
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @dev Unpause contract functionality
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    function checkInitialFunding() external view returns (uint256) {
        return token.balanceOf(address(this));
    }

    function emergencyWithdraw() external onlyOwner {
        uint256 balance = token.balanceOf(address(this));
        require(balance > 0, "No funds to withdraw");
        token.transfer(owner(), balance);
        _pause();
    }
}
