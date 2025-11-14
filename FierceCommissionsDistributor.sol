// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./RewardStaking.sol";
import "./FierceToken.sol";

/**
 * @title Fierce Commission Distributor - Acumulative Version
 * @dev An efficient system for commission distribution without per-deposit snapshots.
 * @notice This contract has been modified to operate more automatically,
 * syncing with the staking contract to register stakers and distribute
 * commissions based on an accumulated model.
 */
contract FierceCommissionDistributor is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ===== CONSTANTS & IMMUTABLES =====
    uint256 public constant PRECISION = 1e18;

    RewardStaking public immutable fierceStaking;
    FierceToken public immutable fierceToken;

    // ===== STATE VARIABLES =====
    // Ganancias acumuladas por token
    mapping(address => uint256) public totalCommissionsByToken;

    // Cantidad reclamada por usuario y token
    mapping(address => mapping(address => uint256)) public totalClaimedByTokenAndUser;

    // Stake total elegible en el momento del depósito
    mapping(address => uint256) public totalEligibleStakeByToken;

    // Gestión de Stakers
    address[] public allStakers;
    mapping(address => bool) public registeredStakers;
    mapping(address => bool) public isBlacklisted;
    // STATE VARIABLES - AGREGAR
    mapping(address => uint256) public totalWeightSnapshotByToken;
    mapping(address => mapping(address => uint256)) public userStakeSnapshotByToken;

    // Lógica para el período de emisión de FierceStaking
    bool public emissionPeriodOver;

    // ===== EVENTS =====
    event CommissionsDeposited(
        address indexed token,
        uint256 amount,
        uint256 totalEligibleStake
    );
    event RewardsClaimed(
        address indexed user,
        address indexed token,
        uint256 amount
    );
    event StakerRegistered(address indexed staker);
    event StakerUnregistered(address indexed staker);
    event StakerBlacklisted(address indexed staker);
    event StakerUnblacklisted(address indexed staker);

    // ===== CONSTRUCTOR =====
    constructor(
        address _fierceStaking,
        address _fierceToken
    ) Ownable(msg.sender) {
        fierceStaking = RewardStaking(_fierceStaking);
        fierceToken = FierceToken(_fierceToken);
    }

    // ===== MANAGEMENT FUNCTIONS (OWNER ONLY) =====

    /**
     * [cite_start]@dev Function to register a staker[cite: 18].
     * [cite_start]@param staker The address of the staker to register[cite: 19].
     */
    function registerStaker(address staker) external {
        if (!registeredStakers[staker]) {
            registeredStakers[staker] = true;
            allStakers.push(staker);
            emit StakerRegistered(staker);
        }
    }

    /**
     * [cite_start]@dev Manually unregisters a staker, useful for management[cite: 22].
     * [cite_start]@param staker The address of the staker to unregister[cite: 23].
     */
    function unregisterStaker(address staker) external onlyOwner {
        require(registeredStakers[staker], "Staker is not registered");
        registeredStakers[staker] = false;
        for (uint i = 0; i < allStakers.length; i++) {
            if (allStakers[i] == staker) {
                allStakers[i] = allStakers[allStakers.length - 1];
                allStakers.pop();
                break;
            }
        }
        emit StakerUnregistered(staker);
    }

    /**
     * [cite_start]@dev Blacklists a staker, excluding them from commissions[cite: 28].
     * [cite_start]@param staker The address of the staker to blacklist[cite: 29].
     */
    function blacklistStaker(address staker) external onlyOwner {
        require(!isBlacklisted[staker], "Staker is already blacklisted");
        isBlacklisted[staker] = true;
        emit StakerBlacklisted(staker);
    }

    /**
     * [cite_start]@dev Removes a staker from the blacklist[cite: 31].
     * [cite_start]@param staker The address of the staker to un-blacklist[cite: 32].
     */
    function unblacklistStaker(address staker) external onlyOwner {
        require(isBlacklisted[staker], "Staker is not blacklisted");
        isBlacklisted[staker] = false;
        emit StakerUnblacklisted(staker);
    }

    /**
     * [cite_start]@dev Enables/disables the FierceStaking contract's emission period[cite: 34].
     * [cite_start]@param _emissionPeriodOver True if the period is over, false otherwise[cite: 35].
     */
    function setEmissionPeriodOver(bool _emissionPeriodOver) external onlyOwner {
        emissionPeriodOver = _emissionPeriodOver;
    }

    // ===== MAIN FUNCTIONS =====

    /**
     * [cite_start]@dev Deposits commissions into the contract[cite: 37].
     * [cite_start]@param _token The address of the token to deposit[cite: 37].
     * [cite_start]@param _amount The amount of the token[cite: 38].
     */
    function depositCommissions(address _token, uint256 _amount) external nonReentrant {
        require(_amount > 0, "Amount must be greater than 0");

        IERC20 tokenContract = IERC20(_token);
        tokenContract.safeTransferFrom(msg.sender, address(this), _amount);

        uint256 totalEligibleStake = _calculateTotalEligibleStake();

        // AGREGAR: Tomar snapshot de todos los stakers registrados
        for (uint i = 0; i < allStakers.length; i++) {
            address staker = allStakers[i];
            if (registeredStakers[staker] && !isBlacklisted[staker]) {
                userStakeSnapshotByToken[_token][staker] = getUserTotalStake(staker);
            }
        }
    
    // Agregar al total acumulado de comisiones y actualizar el stake total elegible
    totalCommissionsByToken[_token] += _amount;
    totalEligibleStakeByToken[_token] = totalEligibleStake;
    totalWeightSnapshotByToken[_token] = totalEligibleStake; // ✅ Snapshot del peso total

    emit CommissionsDeposited(_token, _amount, totalEligibleStake);
}

    /**
     * @dev Claims pending rewards for a user for a specific token.
     * @param _token The address of the token to claim from.
     */
    function claimRewards(address _token) external nonReentrant {
        uint256 pendingRewards = getPendingRewards(msg.sender, _token);
        require(pendingRewards > 0, "No pending rewards to claim");
        require(userStakeSnapshotByToken[_token][msg.sender] > 0, "No eligible stake at deposit time");
    
        userStakeSnapshotByToken[_token][msg.sender] = 0;
        
        totalClaimedByTokenAndUser[_token][msg.sender] += pendingRewards;
    
        IERC20 tokenContract = IERC20(_token);
        tokenContract.safeTransfer(msg.sender, pendingRewards);
    
        emit RewardsClaimed(msg.sender, _token, pendingRewards);
    }

    // ===== VIEW FUNCTIONS =====

    /**
     * @dev Calculates a user's total pending rewards for a given token.
     * @param user The address of the user.
     * @param token The address of the token.
     * @return The amount of pending rewards.
     */
    function getPendingRewards(address user, address token) public view returns (uint256) {
        uint256 totalEarnings = totalCommissionsByToken[token];
        uint256 totalEligible = totalWeightSnapshotByToken[token]; // ✅ Usar snapshot

        if (totalEarnings == 0 || totalEligible == 0) {
            return 0;
        }

        // ✅ Usar snapshot del usuario en lugar del stake actual
        uint256 userStake = userStakeSnapshotByToken[token][user];

        if (isBlacklisted[user] || userStake == 0) {
            return 0;
        }

        // Calcula la parte de las ganancias que le corresponde al usuario
        uint256 userShare = (userStake * PRECISION) / totalEligible;
        uint256 totalUserEarnings = (totalEarnings * userShare) / PRECISION;

        // Restar lo que ya se ha reclamado
        uint256 claimedAmount = totalClaimedByTokenAndUser[token][user];
        if (totalUserEarnings <= claimedAmount) {
            return 0;
        }

        return totalUserEarnings - claimedAmount;
    }

    /**
     * [cite_start]@dev Calculates the total eligible stake, excluding blacklisted stakers[cite: 62].
     * [cite_start]@return The total amount of eligible stake[cite: 62].
     */
    function _calculateTotalEligibleStake() internal view returns (uint256) {
        uint256 totalStake = getTotalStakedInEcosystem();
        uint256 blacklistedStake = 0;
        
        for (uint256 i = 0; i < allStakers.length; i++) {
            address wallet = allStakers[i];
            if (isBlacklisted[wallet] && registeredStakers[wallet]) {
                blacklistedStake += getUserTotalStake(wallet);
            }
        }
        
        return totalStake - blacklistedStake;
    }

    /**
     * [cite_start]@dev Gets a user's total stake across the entire ecosystem[cite: 67].
     * [cite_start]@param user The address of the user[cite: 67].
     * [cite_start]@return The user's total stake[cite: 68].
     */
    function getUserTotalStake(address user) public view returns (uint256) {
        if (isBlacklisted[user]) return 0;
        uint256 legacyStake = emissionPeriodOver ? 0 : fierceStaking.userStakedAmount(user);
        uint256 newStake = fierceToken.balanceOf(user);
        
        return legacyStake + newStake;
    }

    /**
     * [cite_start]@dev Gets the total stake across the entire ecosystem[cite: 72].
     * [cite_start]@return The total stake in both contracts[cite: 72].
     */
    function getTotalStakedInEcosystem() public view returns (uint256) {
        uint256 legacyTotal = emissionPeriodOver ? 0 : fierceStaking.getTotalStaked();
        uint256 newContractTotal = fierceToken.balanceOf(address(this));
        
        return legacyTotal + newContractTotal;
    }

    /**
     * [cite_start]@dev Calculates a user's share[cite: 75].
     * [cite_start]@param userStake The user's stake[cite: 75].
     * [cite_start]@param totalStake The total eligible stake[cite: 75].
     * [cite_start]@return The user's share[cite: 76].
     */
    function calculateUserShare(uint256 userStake, uint256 totalStake)
        public
        pure
        returns (uint256)
    {
        if (totalStake == 0 || userStake == 0) return 0;
        return (userStake * PRECISION) / totalStake;
    }
}