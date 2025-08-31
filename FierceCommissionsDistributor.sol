// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./IFierceStaking.sol";
import "./FierceToken.sol";

/**
 * @title Fierce Commission Distributor with Blacklist
 * @dev Distributes commissions with blacklist system for policy compliance
 */
contract FierceCommissionDistributor is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ===== CONSTANTS & IMMUTABLES =====
    uint256 public constant PRECISION = 1e18;
    
    IFierceStaking public immutable fierceStaking;
    FierceToken public immutable fierceToken;

    // ===== STATE VARIABLES =====
    struct DepositSnapshot {
        uint256 totalStakedAtDeposit;
        uint256 timestamp;
        address token;
        uint256 amount;
        uint256 totalEligibleStake; // Total stake of non-blacklisted users
    }

    struct UserSnapshot {
        uint256 userStakedAtDeposit;
        uint256 claimedAmount;
        bool wasBlacklisted; // If the user was blacklisted at deposit time
    }

    // Mappings for snapshots and blacklist
    mapping(uint256 => DepositSnapshot) public depositSnapshots;
    mapping(uint256 => mapping(address => UserSnapshot)) public userSnapshots;
    mapping(address => bool) public isBlacklisted;
    mapping(address => string) public blacklistReasons;
    mapping(address => uint256) public blacklistTimestamps;
    
    // Lists for tracking
    address[] public blacklistedAddresses;
    
    // Counters
    uint256 public depositCounter;
    uint256 public totalDistributed;
    
    // Staking in new contract (post-36 months)
    mapping(address => uint256) public newContractStakes;
    uint256 public totalNewContractStakes;
    
    // State control
    bool public emissionPeriodOver;
    uint256 public emissionEndBlock;

    // ===== EVENTS =====
    event CommissionDeposited(
        uint256 indexed depositId,
        address indexed token,
        uint256 amount,
        uint256 totalStakedSnapshot,
        uint256 totalEligibleStake
    );
    event CommissionClaimed(
        address indexed user,
        uint256 indexed depositId,
        address indexed token,
        uint256 amount
    );
    event AllCommissionsClaimed(
        address indexed user,
        uint256 totalAmount,
        uint256 depositsClaimed
    );
    event NewStakeDeposited(address indexed user, uint256 amount);
    event NewStakeWithdrawn(address indexed user, uint256 amount);
    event EmissionPeriodEnded(uint256 blockNumber);
    event AddressBlacklisted(address indexed wallet, string reason);
    event AddressWhitelisted(address indexed wallet);
    event BlacklistEnforced(uint256 depositId, address[] excludedAddresses);

    // ===== MODIFIERS =====
    modifier onlyAfterEmission() {
        require(emissionPeriodOver, "Emission period not ended");
        _;
    }

    modifier notBlacklisted(address account) {
        require(!isBlacklisted[account], "Address is blacklisted");
        _;
    }

    // ===== CONSTRUCTOR =====
    constructor(
        address _fierceStaking,
        address _fierceToken,
        address initialOwner
    ) Ownable(initialOwner) {
        fierceStaking = IFierceStaking(_fierceStaking);
        fierceToken = FierceToken(_fierceToken);
        emissionEndBlock = fierceStaking.emissionEndBlock();
    }

    // ===== MAIN FUNCTIONS =====

    /**
     * @dev Deposit commissions for distribution (considering blacklist)
     */
    function depositCommissions(uint256 amount, address erc20Token) 
        external 
        payable 
        nonReentrant 
    {
        require(amount > 0 || msg.value > 0, "Amount must be > 0");
        
        uint256 depositAmount;
        if (erc20Token == address(0)) {
            depositAmount = msg.value;
        } else {
            require(amount > 0, "Amount must be > 0");
            depositAmount = amount;
            IERC20(erc20Token).safeTransferFrom(
                msg.sender, 
                address(this), 
                depositAmount
            );
        }

        // Take snapshot of current state considering blacklist
        uint256 currentTotalStaked = getTotalStakedInEcosystem();
        uint256 currentEligibleStake = getTotalEligibleStake();
        
        depositSnapshots[depositCounter] = DepositSnapshot({
            totalStakedAtDeposit: currentTotalStaked,
            timestamp: block.timestamp,
            token: erc20Token,
            amount: depositAmount,
            totalEligibleStake: currentEligibleStake
        });

        emit CommissionDeposited(
            depositCounter,
            erc20Token,
            depositAmount,
            currentTotalStaked,
            currentEligibleStake
        );

        depositCounter++;
        totalDistributed += depositAmount;
    }

    /**
     * @dev Claim all pending commissions from all deposits (RWA-earnings style)
     */
    function claimAllCommissions() external nonReentrant notBlacklisted(msg.sender) {
        uint256 totalClaimable = 0;
        uint256 depositsClaimed = 0;
        
        // Temporary storage for gas optimization
        address currentToken;
        uint256 currentAmount;
        
        for (uint256 i = 0; i < depositCounter; i++) {
            DepositSnapshot storage deposit = depositSnapshots[i];
            if (deposit.amount == 0) continue;

            UserSnapshot storage userSnapshot = userSnapshots[i][msg.sender];
            if (userSnapshot.wasBlacklisted) continue;

            uint256 userShare = calculateUserShare(
                userSnapshot.userStakedAtDeposit,
                deposit.totalEligibleStake
            );
            
            uint256 userReward = (deposit.amount * userShare) / PRECISION;
            if (userReward > userSnapshot.claimedAmount) {
                uint256 claimableAmount = userReward - userSnapshot.claimedAmount;
                
                // Batch same token transfers
                if (deposit.token == currentToken) {
                    currentAmount += claimableAmount;
                } else {
                    // Transfer previous batch
                    if (currentAmount > 0) {
                        _transferTokens(currentToken, msg.sender, currentAmount);
                    }
                    currentToken = deposit.token;
                    currentAmount = claimableAmount;
                }
                
                totalClaimable += claimableAmount;
                userSnapshot.claimedAmount = userReward;
                depositsClaimed++;
            }
        }
        
        // Transfer final batch
        if (currentAmount > 0) {
            _transferTokens(currentToken, msg.sender, currentAmount);
        }

        require(totalClaimable > 0, "No rewards to claim");
        
        emit AllCommissionsClaimed(msg.sender, totalClaimable, depositsClaimed);
    }

    /**
     * @dev Claim commissions from a specific deposit (backward compatibility)
     */
    function claimCommission(uint256 depositId) external nonReentrant notBlacklisted(msg.sender) {
        require(depositId < depositCounter, "Invalid deposit ID");
        
        DepositSnapshot storage deposit = depositSnapshots[depositId];
        require(deposit.amount > 0, "Deposit already fully claimed");

        UserSnapshot storage userSnapshot = userSnapshots[depositId][msg.sender];
        require(!userSnapshot.wasBlacklisted, "User was blacklisted at deposit time");

        // Calculate user share
        uint256 userShare = calculateUserShare(
            userSnapshot.userStakedAtDeposit,
            deposit.totalEligibleStake
        );
        
        uint256 userReward = (deposit.amount * userShare) / PRECISION;
        require(userReward > 0, "No rewards to claim");
        require(userReward > userSnapshot.claimedAmount, "Already claimed");

        uint256 claimableAmount = userReward - userSnapshot.claimedAmount;
        
        // Update claimed amounts
        userSnapshot.claimedAmount = userReward;
        
        // Distribute reward
        _transferTokens(deposit.token, msg.sender, claimableAmount);

        emit CommissionClaimed(
            msg.sender,
            depositId,
            deposit.token,
            claimableAmount
        );
    }

    // ===== BLACKLIST SYSTEM =====

    /**
     * @dev Add address to blacklist
     */
    function addToBlacklist(address wallet, string memory reason) external onlyOwner {
        require(!isBlacklisted[wallet], "Already blacklisted");
        
        isBlacklisted[wallet] = true;
        blacklistReasons[wallet] = reason;
        blacklistTimestamps[wallet] = block.timestamp;
        blacklistedAddresses.push(wallet);
        
        emit AddressBlacklisted(wallet, reason);
    }

    /**
     * @dev Remove address from blacklist
     */
    function removeFromBlacklist(address wallet) external onlyOwner {
        require(isBlacklisted[wallet], "Not blacklisted");
        
        isBlacklisted[wallet] = false;
        blacklistReasons[wallet] = "";
        
        emit AddressWhitelisted(wallet);
    }

    /**
     * @dev Apply blacklist retroactively to a specific deposit
     */
    function enforceBlacklistOnDeposit(uint256 depositId, address[] memory wallets) external onlyOwner {
        require(depositId < depositCounter, "Invalid deposit ID");
        
        for (uint256 i = 0; i < wallets.length; i++) {
            address wallet = wallets[i];
            if (userSnapshots[depositId][wallet].userStakedAtDeposit > 0) {
                userSnapshots[depositId][wallet].wasBlacklisted = true;
            }
        }
        
        emit BlacklistEnforced(depositId, wallets);
    }

    // ===== POST-36 MONTHS STAKING FUNCTIONS =====

    /**
     * @dev Stake in new contract (only non-blacklisted users)
     */
    function stakeInNewContract(uint256 amount) external onlyAfterEmission nonReentrant notBlacklisted(msg.sender) {
        require(amount > 0, "Amount must be > 0");
        
        fierceToken.transferFrom(msg.sender, address(this), amount);
        
        newContractStakes[msg.sender] += amount;
        totalNewContractStakes += amount;
        
        emit NewStakeDeposited(msg.sender, amount);
    }

    /**
     * @dev Unstake from new contract
     */
    function unstakeFromNewContract(uint256 amount) external onlyAfterEmission nonReentrant {
        require(amount > 0, "Amount must be > 0");
        require(newContractStakes[msg.sender] >= amount, "Insufficient stake");
        
        newContractStakes[msg.sender] -= amount;
        totalNewContractStakes -= amount;
        
        fierceToken.transfer(msg.sender, amount);
        
        emit NewStakeWithdrawn(msg.sender, amount);
    }

    // ===== INTERNAL FUNCTIONS =====

    /**
     * @dev Internal function for token transfer
     */
    function _transferTokens(address token, address to, uint256 amount) internal {
        if (token == address(0)) {
            (bool success, ) = to.call{value: amount}("");
            require(success, "MATIC transfer failed");
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }

    // ===== ADMIN FUNCTIONS =====

    /**
     * @dev Mark the end of emission period
     */
    function markEmissionPeriodEnded() external onlyOwner {
        require(!emissionPeriodOver, "Emission already ended");
        require(block.number >= emissionEndBlock, "Emission not finished");
        
        emissionPeriodOver = true;
        emit EmissionPeriodEnded(block.number);
    }

    /**
     * @dev Emergency withdraw tokens
     */
    function emergencyWithdraw(address token, uint256 amount) external onlyOwner {
        if (token == address(0)) {
            (bool success, ) = owner().call{value: amount}("");
            require(success, "MATIC transfer failed");
        } else {
            IERC20(token).safeTransfer(owner(), amount);
        }
    }

    // ===== VIEW FUNCTIONS =====

    /**
     * @dev Get total eligible stake (excluding blacklisted)
     */
    function getTotalEligibleStake() public view returns (uint256) {
        uint256 totalStake = getTotalStakedInEcosystem();
        uint256 blacklistedStake = 0;
        
        for (uint256 i = 0; i < blacklistedAddresses.length; i++) {
            address wallet = blacklistedAddresses[i];
            if (isBlacklisted[wallet]) {
                blacklistedStake += getUserTotalStake(wallet);
            }
        }
        
        return totalStake - blacklistedStake;
    }

    /**
     * @dev Get user's total stake
     */
    function getUserTotalStake(address user) public view returns (uint256) {
        if (isBlacklisted[user]) return 0;
        
        uint256 legacyStake = emissionPeriodOver ? 0 : fierceStaking.userStakedAmount(user);
        return legacyStake + newContractStakes[user];
    }

    /**
     * @dev Get total stake in ecosystem
     */
    function getTotalStakedInEcosystem() public view returns (uint256) {
        uint256 legacyTotal = emissionPeriodOver ? 0 : fierceStaking.getTotalStaked();
        return legacyTotal + totalNewContractStakes;
    }

    /**
     * @dev Calculate user share
     */
    function calculateUserShare(uint256 userStake, uint256 totalStake) 
        public 
        pure 
        returns (uint256) 
    {
        if (totalStake == 0 || userStake == 0) return 0;
        return (userStake * PRECISION) / totalStake;
    }

    /**
     * @dev Check user's blacklist status
     */
    function getBlacklistStatus(address wallet) external view returns (
        bool blacklisted, 
        string memory reason, 
        uint256 timestamp
    ) {
        return (
            isBlacklisted[wallet],
            blacklistReasons[wallet],
            blacklistTimestamps[wallet]
        );
    }

    /**
     * @dev Get all blacklisted addresses
     */
    function getAllBlacklistedAddresses() external view returns (address[] memory) {
        return blacklistedAddresses;
    }

    /**
     * @dev Calculate user's pending rewards
     */
    function getPendingRewards(address user) external view returns (uint256 totalPending) {
        if (isBlacklisted[user]) return 0;
        
        for (uint256 i = 0; i < depositCounter; i++) {
            DepositSnapshot storage deposit = depositSnapshots[i];
            if (deposit.amount == 0) continue;

            UserSnapshot memory userSnapshot = userSnapshots[i][user];
            if (userSnapshot.wasBlacklisted) continue;

            uint256 userShare = calculateUserShare(
                userSnapshot.userStakedAtDeposit,
                deposit.totalEligibleStake
            );
            
            uint256 totalReward = (deposit.amount * userShare) / PRECISION;
            uint256 pending = totalReward - userSnapshot.claimedAmount;
            
            totalPending += pending;
        }
        return totalPending;
    }

    /**
     * @dev Get user snapshot for a specific deposit
     */
    function getUserSnapshot(address user, uint256 depositId) 
        external 
        view 
        returns (UserSnapshot memory) 
    {
        return userSnapshots[depositId][user];
    }

    /**
     * @dev Get estimated gas for claimAllCommissions
     */
    function estimateClaimGas(address user) external view returns (uint256) {
        // Base gas + per deposit gas estimation
        uint256 baseGas = 21000;
        uint256 perDepositGas = 3000;
        
        return baseGas + (depositCounter * perDepositGas);
    }

    // ===== RECEIVE FUNCTION =====
    receive() external payable {}
}