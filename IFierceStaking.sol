// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./FierceToken.sol";

/**
 * @title Fierce Staking System - Polygon Network (Improved Version)
 * @dev Block-based staking system optimized for Polygon with proper tracking and validation
 */
contract FierceStaking is Ownable, ReentrancyGuard, Pausable {
    FierceToken public token;

    // BlockStake staking structure
    struct BlockStake {
        uint256 amount;
        uint256 rewardDebt;
        uint256 stakeBlock;
        bool active;
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
        uint256 totalDistributed;
        bool sufficientFunding;
    }

    // ===== STATE VARIABLES =====
    bool public claimsEnabled;

    // Constants
    uint256 public constant TOKENS_PER_BLOCK = 21.71 * 10**18;
    uint256 public constant EMISSION_DURATION_BLOCKS = 41215304; // ~36 months on Polygon
    uint256 public constant PRECISION = 1e12;
    uint256 public constant POLYGON_BLOCKS_PER_YEAR = 13711304;
    uint256 public constant MINIMUM_INITIAL_FUNDING = 800_000_000 * 10**18; // 800M minimum
    uint256 public constant TOTAL_EXPECTED_EMISSION = 894_784_550 * 10**18; // 894.78M total

    // State variables
    bool public useBlockStakeSystem = false;
    uint256 public emissionStartBlock;
    uint256 public emissionEndBlock;
    uint256 public totalStakedTokens;
    uint256 public lastUpdateBlock;
    uint256 public accTokensPerShare;
    uint256 public totalEmittedTokens; // Tokens teóricamente emitidos
    uint256 public totalDistributedTokens; // Tokens realmente distribuidos
    uint256 public missedEmissions; // Tokens no distribuidos por falta de fondos

    // Mappings
    mapping(address => BlockStake[]) public blockStakes;
    mapping(address => uint256) public userStakedAmount;
    mapping(address => uint256) public userPendingRewards;
    mapping(address => bool) public autoCompoundEnabled; // Auto-compound preference

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
    event RewardsCompounded(address indexed user, uint256 amount);
    event PoolUpdated(
        uint256 blockNumber,
        uint256 accTokensPerShare,
        uint256 totalStaked,
        uint256 distributed
    );
    event EmissionStarted(uint256 startBlock, uint256 endBlock, uint256 initialFunding);
    event StakingSystemChanged(bool useBlockStake);
    event InsufficientFunds(uint256 required, uint256 available, uint256 blockNumber);
    event RewardsDistributed(uint256 amount, uint256 blockNumber, uint256 totalEmitted);
    event AutoCompoundToggled(address indexed user, bool enabled);
    event FundingValidated(uint256 balance, uint256 required, bool sufficient);

    // Modifiers
    modifier onlyActiveEmission() {
        require(useBlockStakeSystem, "BlockStake system not active");
        require(block.number >= emissionStartBlock, "Emission not started");
        require(block.number <= emissionEndBlock, "Emission ended");
        _;
    }

    modifier onlyWhenClaimsEnabled() {
        require(claimsEnabled, "Claims are currently disabled");
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

    // ===== AUTO-COMPOUND MANAGEMENT =====
    
    /**
     * @dev Toggle auto-compound for caller
     * @param _enabled True to enable auto-compound, false to disable
     */
    function setAutoCompound(bool _enabled) external {
        autoCompoundEnabled[msg.sender] = _enabled;
        emit AutoCompoundToggled(msg.sender, _enabled);
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
     * @dev Start BlockStake emission system with proper validation
     * Can only be called once
     */
    function startBlockStakeEmission() external onlyOwner {
        require(emissionStartBlock == 0, "Emission already started");
        require(useBlockStakeSystem, "BlockStake system not enabled");
        
        // Validate initial funding
        uint256 contractBalance = token.balanceOf(address(this));
        require(contractBalance >= MINIMUM_INITIAL_FUNDING, 
                "Insufficient initial funding (min 800M required)");
        
        emissionStartBlock = block.number;
        emissionEndBlock = block.number + EMISSION_DURATION_BLOCKS;
        lastUpdateBlock = block.number;
        
        emit EmissionStarted(emissionStartBlock, emissionEndBlock, contractBalance);
        emit FundingValidated(contractBalance, MINIMUM_INITIAL_FUNDING, true);
    }

    // ===== POOL UPDATE WITH PROPER TRACKING =====

    /**
     * @dev Update pool rewards with proper tracking and validation
     */
    function updatePool() public {
        if (!useBlockStakeSystem || emissionStartBlock == 0) return;

        uint256 currentBlock = block.number;
        if (currentBlock <= lastUpdateBlock || totalStakedTokens == 0) return;

        uint256 blocksToReward = (
            currentBlock > emissionEndBlock ? emissionEndBlock : currentBlock
        ) - lastUpdateBlock;
        if (blocksToReward == 0) return;

        uint256 theoreticalReward = blocksToReward * TOKENS_PER_BLOCK;
        uint256 contractBalance = token.balanceOf(address(this));
        uint256 actualReward = theoreticalReward;
        
        // Track theoretical emissions
        totalEmittedTokens += theoreticalReward;
        
        // Check if we have sufficient funds
        if (theoreticalReward > contractBalance) {
            actualReward = contractBalance;
            missedEmissions += (theoreticalReward - actualReward);
            emit InsufficientFunds(theoreticalReward, contractBalance, currentBlock);
        }
        
        // Only distribute what we actually have
        if (actualReward > 0) {
            accTokensPerShare += (actualReward * PRECISION) / totalStakedTokens;
            totalDistributedTokens += actualReward;
            emit RewardsDistributed(actualReward, currentBlock, totalEmittedTokens);
        }
        
        lastUpdateBlock = currentBlock;
        emit PoolUpdated(currentBlock, accTokensPerShare, totalStakedTokens, actualReward);
    }

    // ===== STAKING FUNCTIONS =====

/**
@dev Stake tokens in BlockStake system on behalf of another user (Owner only)
@param user Address of the user to stake for
@param amount Amount of tokens to stake
*/
function blockStakeFromMint(address user, uint256 amount)
    external
    onlyOwner
    whenNotPaused
    nonReentrant
    onlyActiveEmission{
    require(amount >= token.MIN_STAKING_AMOUNT(), "Amount below minimum");
    require(token.balanceOf(msg.sender) >= amount, "Insufficient balance");
        updatePool();

        uint256 pending = calculatePendingRewards(user);
        if (pending > 0) {
            userPendingRewards[user] += pending;
        }

        token.transferFrom(msg.sender, address(this), amount);

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

        totalStakedTokens -= totalAmountToUnstake;
        userStakedAmount[msg.sender] -= totalAmountToUnstake;
        userPendingRewards[msg.sender] = 0;

        uint256 totalAmount = totalAmountToUnstake + totalRewards;
        token.transfer(msg.sender, totalAmount);

        emit BlockStakeUnstaked(
            msg.sender,
            type(uint256).max,
            totalAmountToUnstake,
            totalRewards
        );
    }

    /**
     * @dev Claim accumulated rewards - with option to auto-compound
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

        // Update reward debt for all active stakes
        for (uint256 i = 0; i < blockStakes[msg.sender].length; i++) {
            BlockStake storage stake = blockStakes[msg.sender][i];
            if (stake.active) {
                stake.rewardDebt = (stake.amount * accTokensPerShare) / PRECISION;
            }
        }

        userPendingRewards[msg.sender] = 0;

        // Check if user has auto-compound enabled
        if (autoCompoundEnabled[msg.sender]) {
            // Auto-compound: stake the rewards
            blockStakes[msg.sender].push(
                BlockStake({
                    amount: totalPending,
                    rewardDebt: (totalPending * accTokensPerShare) / PRECISION,
                    stakeBlock: block.number,
                    active: true
                })
            );

            totalStakedTokens += totalPending;
            userStakedAmount[msg.sender] += totalPending;

            emit RewardsCompounded(msg.sender, totalPending);
            emit BlockStakeStaked(
                msg.sender,
                blockStakes[msg.sender].length - 1,
                totalPending,
                block.number
            );
        } else {
            // Normal claim: transfer to user
            token.transfer(msg.sender, totalPending);
            emit BlockStakeRewardsClaimed(msg.sender, totalPending);
        }
    }

    /**
     * @dev Claim and compound rewards in one transaction
     * Explicit function for users who want to compound without enabling auto-compound
     */
    function claimAndCompound()
        external
        whenNotPaused
        nonReentrant
        onlyWhenClaimsEnabled
    {
        require(useBlockStakeSystem, "BlockStake system not active");
        require(emissionStartBlock > 0 && block.number >= emissionStartBlock, 
                "Emission not started");

        updatePool();

        uint256 totalPending = calculatePendingRewards(msg.sender) + 
                               userPendingRewards[msg.sender];
        require(totalPending > 0, "No rewards to compound");

        // Update reward debt for all active stakes
        for (uint256 i = 0; i < blockStakes[msg.sender].length; i++) {
            BlockStake storage stake = blockStakes[msg.sender][i];
            if (stake.active) {
                stake.rewardDebt = (stake.amount * accTokensPerShare) / PRECISION;
            }
        }

        userPendingRewards[msg.sender] = 0;

        // Compound the rewards
        blockStakes[msg.sender].push(
            BlockStake({
                amount: totalPending,
                rewardDebt: (totalPending * accTokensPerShare) / PRECISION,
                stakeBlock: block.number,
                active: true
            })
        );

        totalStakedTokens += totalPending;
        userStakedAmount[msg.sender] += totalPending;

        emit RewardsCompounded(msg.sender, totalPending);
        emit BlockStakeStaked(
            msg.sender,
            blockStakes[msg.sender].length - 1,
            totalPending,
            block.number
        );
    }

    // ===== VIEW FUNCTIONS =====

    /**
     * @dev Calculate pending rewards for a user
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
                uint256 theoreticalReward = blocksToReward * TOKENS_PER_BLOCK;
                uint256 contractBalance = token.balanceOf(address(this));
                uint256 actualReward = theoreticalReward > contractBalance 
                    ? contractBalance 
                    : theoreticalReward;
                    
                if (actualReward > 0) {
                    tempAccTokensPerShare += (actualReward * PRECISION) / totalStakedTokens;
                }
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
     */
    function getCurrentAPY() external view returns (uint256) {
        if (!useBlockStakeSystem || totalStakedTokens == 0) return 0;

        uint256 annualEmission = TOKENS_PER_BLOCK * POLYGON_BLOCKS_PER_YEAR;
        return (annualEmission * 10000) / totalStakedTokens; // Returns APY with 2 decimals (e.g., 2500 = 25.00%)
    }

    /**
     * @dev Get comprehensive system information
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
            uint256 annualEmission = TOKENS_PER_BLOCK * POLYGON_BLOCKS_PER_YEAR;
            systemInfo.currentAPY = (annualEmission * 10000) / totalStakedTokens;
        }

        systemInfo.tokensPerBlock = TOKENS_PER_BLOCK;

        if (emissionStartBlock > 0 && block.number < emissionEndBlock) {
            systemInfo.blocksRemaining = emissionEndBlock - block.number;
        }

        systemInfo.totalEmitted = totalEmittedTokens;
        systemInfo.totalDistributed = totalDistributedTokens;
        
        uint256 contractBalance = token.balanceOf(address(this));
        uint256 blocksLeft = systemInfo.blocksRemaining;
        uint256 fundsNeeded = blocksLeft * TOKENS_PER_BLOCK;
        systemInfo.sufficientFunding = contractBalance >= fundsNeeded;
    }

    /**
     * @dev Get emission health status
     */
    function getEmissionHealth() 
        external 
        view 
        returns (
            uint256 theoreticalEmissions,
            uint256 actualDistributions,
            uint256 missed,
            uint256 efficiency,
            bool isHealthy
        ) 
    {
        theoreticalEmissions = totalEmittedTokens;
        actualDistributions = totalDistributedTokens;
        missed = missedEmissions;
        
        if (theoreticalEmissions > 0) {
            efficiency = (actualDistributions * 10000) / theoreticalEmissions; // Percentage with 2 decimals
        } else {
            efficiency = 10000; // 100%
        }
        
        isHealthy = efficiency >= 9900; // 99% or better is considered healthy
    }

    /**
     * @dev Check funding status
     */
    function checkFundingStatus() 
        external 
        view 
        returns (
            uint256 currentBalance,
            uint256 requiredForCompletion,
            uint256 blocksUntilEmpty,
            bool needsRefunding
        ) 
    {
        currentBalance = token.balanceOf(address(this));
        
        if (emissionEndBlock > block.number) {
            uint256 remainingBlocks = emissionEndBlock - block.number;
            requiredForCompletion = remainingBlocks * TOKENS_PER_BLOCK;
        }
        
        if (totalStakedTokens > 0 && TOKENS_PER_BLOCK > 0) {
            blocksUntilEmpty = currentBalance / TOKENS_PER_BLOCK;
        }
        
        needsRefunding = currentBalance < requiredForCompletion;
    }

    /**
     * @dev Get user's auto-compound status
     */
    function isAutoCompoundEnabled(address user) external view returns (bool) {
        return autoCompoundEnabled[user];
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
            uint256 totalDistributed,
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
            totalDistributedTokens,
            TOKENS_PER_BLOCK,
            accTokensPerShare
        );
    }

    /**
     * @dev Get user's BlockStake stakes count
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
     */
    function getBlockStakeInfo(address user, uint256 stakeIndex)
        external
        view
        returns (BlockStake memory)
    {
        return blockStakes[user][stakeIndex];
    }

    /**
     * @dev Get emission progress with detailed metrics
     */
    function getEmissionProgress()
        external
        view
        returns (
            uint256 blocksCompleted,
            uint256 totalBlocks,
            uint256 percentComplete,
            uint256 blocksRemaining,
            uint256 estimatedCompletionTimestamp
        )
    {
        if (emissionStartBlock == 0) {
            return (0, EMISSION_DURATION_BLOCKS, 0, EMISSION_DURATION_BLOCKS, 0);
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
            
        // Estimate completion time (2.3 seconds per block on Polygon)
        if (blocksRemaining > 0) {
            estimatedCompletionTimestamp = block.timestamp + (blocksRemaining * 23 / 10);
        }
    }

    /**
     * @dev Emergency function to update pool manually
     */
    function forceUpdatePool() external onlyOwner {
        updatePool();
    }

    /**
     * @dev Get remaining rewards in contract
     */
    function remainingRewards() external view returns (uint256) {
        return token.balanceOf(address(this)) - totalStakedTokens;
    }

    /**
     * @dev Get available rewards balance (excluding staked tokens)
     */
    function getAvailableRewardsBalance() external view returns (uint256) {
        uint256 totalBalance = token.balanceOf(address(this));
        if (totalBalance > totalStakedTokens) {
            return totalBalance - totalStakedTokens;
        }
        return 0;
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

    /**
     * @dev Emergency withdraw - only in extreme cases
     */
    function emergencyWithdraw() external onlyOwner {
        require(totalStakedTokens == 0, "Cannot withdraw with active stakes");
        uint256 balance = token.balanceOf(address(this));
        require(balance > 0, "No funds to withdraw");
        token.transfer(owner(), balance);
        _pause();
    }

    /**
     * @dev Validate initial funding before deployment
     */
    function validateFunding() external view returns (bool sufficient, string memory message) {
        uint256 balance = token.balanceOf(address(this));
        
        if (balance >= TOTAL_EXPECTED_EMISSION) {
            return (true, "Funding sufficient for complete emission period");
        } else if (balance >= MINIMUM_INITIAL_FUNDING) {
            return (true, "Funding meets minimum requirements");
        } else {
            return (false, "Insufficient funding - minimum 800M required");
        }
    }

    // Agregar estas funciones para facilitar la lectura
function getTotalStaked() external view returns (uint256) {
    return totalStakedTokens;
}

function getUserStakeInfo(address user) external view returns (uint256 amount, bool hasActiveStakes) {
    return (userStakedAmount[user], userStakedAmount[user] > 0);
}
}