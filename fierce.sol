// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title Fierce Token
 * @dev ERC20 token with dynamic staking and burn mechanisms, including reward structures and flexible supply control
 */
contract Fierce is ERC20, Ownable, ReentrancyGuard {
    // Staking structure
    struct StakeInfo {
        uint256 amount; // Staked amount
        uint256 startTime; // Timestamp when the stake started
        uint256 duration; // Duration of staking period
        uint256 rewardRate; // Initial rate of rewards for this stake
        bool active;
        uint256 lastRewardCalculation; // Last reward calculation timestamp to update accumulated rewards efficiently
        uint256 accumulatedRewards; // Accumulated rewards calculated up to the last update time
    }

    // Constants
    uint256 public immutable MAX_SUPPLY = 10000000000 * 10**18; // 10 billion tokens (optimized as immutable)

    // State variables
    uint256 public mintedTokens; // Total tokens minted
    uint256 public burnedTokens; // Total number of tokens that have been burned so far
    uint256 public MIN_STAKING_AMOUNT; // Minimum amount required for staking
    bool public BURNING_ACTIVE; // Flag to enable/disable token burning
    uint256 public dynamicBurnRate; // Dynamic burn rate (base 10000)

    // Mappings
    mapping(address => mapping(uint256 => bool)) public stakingIdExists;
    mapping(address => StakeInfo[]) public userStakes;
    mapping(uint256 => uint256) public durationRewards;

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
    event FundsWithdrawn(uint256 amount);
    event APRUpdated(uint256 duration, uint256 newRate, uint256 oldRate);
    event RewardsCalculated(address user, uint256 stakeIndex, uint256 rewards);

    /**
     * @dev Contract constructor
     * @param _initialMinStakingAmount Initial minimum amount required for staking
     * @param _initialOwner Address of the initial contract owner
     */
    constructor(uint256 _initialMinStakingAmount, address _initialOwner)
        ERC20("Fierce", "Fierce")
        Ownable(_initialOwner)
    {
        MIN_STAKING_AMOUNT = _initialMinStakingAmount;
        dynamicBurnRate = 150; // Initial 1.5%
    }

    function updateAPR(uint256 duration, uint256 newRate) external onlyOwner {
        require(newRate <= 300, "Rate too high"); // Máximo 30% APR

        // Emitir evento con el cambio
        emit APRUpdated(duration, newRate, durationRewards[duration]);

        // Actualizar la tasa
        durationRewards[duration] = newRate;
    }

    function calculateCurrentRewards(address user, uint256 stakeIndex) public {
        StakeInfo storage stakeData = userStakes[user][stakeIndex];
        require(stakeData.active, "Stake not active");

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
     * @dev Implements FIERCE DYNAMIC MINT
     * Allows minting tokens based on specific activities
     * @param to Address to receive the minted tokens
     * @param amount Amount of tokens to mint
     * @param reason Description of the minting reason
     */
    function mintForActivity(
        address to,
        uint256 amount,
        string memory reason
    ) external onlyOwner {
        require(mintedTokens + amount <= MAX_SUPPLY, "Exceeds maximum supply");
        _mint(to, amount);
        mintedTokens += amount;
        emit TokensMinted(to, amount, reason);
    }

    function stake(uint256 amount, uint256 duration) external {
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
    }

    function viewCurrentRewards(address user, uint256 stakeIndex)
        external
        view
        returns (uint256)
    {
        // Cambiar el nombre de la variable stake a stakeData
        StakeInfo memory stakeData = userStakes[user][stakeIndex];
        if (!stakeData.active) return 0;

        uint256 timeElapsed = block.timestamp - stakeData.lastRewardCalculation;
        uint256 newRewards = (stakeData.amount *
            stakeData.rewardRate *
            timeElapsed) / (365 days * 1000);

        return stakeData.accumulatedRewards + newRewards;
    }

    /**
     * @dev Updates the dynamic burn rate
     * @param newRate New burn rate (base 10000, max 1000 or 10%)
     */
    function updateDynamicBurnRate(uint256 newRate) external onlyOwner {
        require(newRate <= 1000, "Rate too high"); // Max 10%
        dynamicBurnRate = newRate;
    }

    /**
     * @dev Enables or disables token burning
     * @param isActive New state for burning mechanism
     */
    function toggleBurning(bool isActive) external onlyOwner {
        BURNING_ACTIVE = isActive;
    }

    /**
     * @dev Override of the transfer function to implement dynamic burning
     * @param sender Address sending tokens
     * @param recipient Address receiving tokens
     * @param amount Amount of tokens to transfer
     */
    function _transfer(
        address sender,
        address recipient,
        uint256 amount
    ) internal virtual override nonReentrant {
        require(amount > 0, "Transfer amount must be greater than zero");

        if (BURNING_ACTIVE && sender != owner() && recipient != address(this)) {
            uint256 burnAmount = (amount * dynamicBurnRate) / 10000;
            super._burn(sender, burnAmount);
            burnedTokens += burnAmount;
            super._transfer(sender, recipient, amount - burnAmount);
            emit TokensBurned(sender, burnAmount);
        } else {
            super._transfer(sender, recipient, amount);
        }
    }

    function unstake(uint256 stakeIndex) external {
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
    }

    /**
     * @dev Updates the minimum staking amount
     * @param newAmount New minimum amount required for staking
     */
    function updateMinStakingAmount(uint256 newAmount) external onlyOwner {
        require(newAmount > 0, "Invalid amount");
        MIN_STAKING_AMOUNT = newAmount;
    }

    /**
     * @dev Withdraws ETH/MATIC from the contract
     * Only callable by contract owner
     */
    function withdrawFunds() external onlyOwner {
        uint256 balance = address(this).balance;
        require(balance > 0, "No funds available");
        payable(owner()).transfer(balance);
        emit FundsWithdrawn(balance);
    }
}
