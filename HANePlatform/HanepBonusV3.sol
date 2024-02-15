// SPDX-License-Identifier: MIT
pragma solidity ^0.7.0;
pragma abicoder v2;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC721/IERC721.sol';
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "./interface/ILiquidityReward_HANeP_4.sol";

/**
 * @title HanepBonusV3
 * @dev A smart contract for distributing rewards to liquidity providers and referrers.
 * This contract enhances security and management functionality by inheriting ReentrancyGuard, Ownable, and Pausable.
 */
contract HanepBonusV3 is ReentrancyGuard, Ownable, Pausable {
    IERC20 public constant HANeP = IERC20(0x68bc2D1FF776B9ffD1271518FEE4E34e4A22064C);
    ILiquidityReward_HANeP_4 public constant LIQUIDITY_REWARD_HANeP_4 = ILiquidityReward_HANeP_4(0x5E5df53b9D6d2855351182A08A6dC818f16dD04D);

    // A structure to store the information of a staker.
    struct Staker {
        uint256 amount; // Amount staked
        uint256 startTime; // Start time of staking
        uint256 lastClaimedTime; // The last time rewards were claimed
        uint256 withdrawalTime; // Time when the staking can be withdrawn
    }
    mapping(address => Staker[]) private stakerArray; // Mapping each address to an array of Stakers.

    // A structure to store the total information.
    struct TotalInfo {
        uint256 totalDividendAmount; // Total dividend amount
        uint256 totalproviderDividendAmount; // Total dividend amount for providers
        uint256 totalStakedAmount; // Total staked amount
        uint256 totalRewardReleased; // Total rewards released
        uint256 unclaimedRewards; // Unclaimed rewards
    }
    mapping(address => TotalInfo) public totalInfo; // Mapping each address to TotalInfo.

    uint256 public constant YEAR = 31536000; // Time in seconds for one year.
    uint256 public constant REWARD_PER_SECOND = 43189120370; // 1 HANeP token per second
    uint256 private constant WEI_MULTIPLIER = 10 ** 18; // Constant for converting HANeP to wei
    uint256 public totalSupply; // Total amount of HANeP staked in the contract

    /**
     * @dev Adds rewards for referrers. Only the owner can call this function.
     * @param _providers Array of addresses of liquidity providers.
     * @param _referrers Array of addresses of referrers corresponding to the providers.
     */
    function addReferrerList(address[] memory _providers, address[] memory _referrers) external nonReentrant onlyOwner {
        require(_providers.length == _referrers.length, "The lengths of the _providers and _referrers arrays must be equal");
        for (uint i = 0; i < _providers.length; i++) {
            address provider = _providers[i];
            address referrer = _referrers[i];
            uint256 amount;
            require(provider != referrer, "Provider and referrer addresses must not be the same");
            for (uint j = 0; j < i; j++) {
                require(_providers[j] != provider, "Duplicate accounts are not allowed");
                require(_referrers[j] != referrer, "Duplicate accounts in _referrers are not allowed");
            }
            (,,,,,uint256 referrerReward,) = LIQUIDITY_REWARD_HANeP_4.totalLiquidityInfo(provider);
            if(referrerReward == 0) {
                revert("don't have any reward");
            }
            amount = LIQUIDITY_REWARD_HANeP_4.registrationReferrer(provider);
            totalInfo[referrer].totalDividendAmount += amount;
            emit RewardUpdated(referrer, amount);
        }
    }

    /**
     * @dev Adds rewards for liquidity providers. Only the owner can call this function.
     * @param _providers Array of addresses of liquidity providers.
     * @param _amounts Array of amounts to be rewarded to the providers.
     */
    function addProviderList(address[] memory _providers, uint256[] memory _amounts) external nonReentrant onlyOwner {
        require(_providers.length == _amounts.length, "The lengths of the _providers and _amounts arrays must be equal");
        for (uint i = 0; i < _providers.length; i++) {
            address provider = _providers[i];
            uint256 amount = _amounts[i];
            uint256 totalLiquidityProvider;
            for (uint j = 0; j < i; j++) {
                require(_providers[j] != provider, "Duplicate accounts are not allowed");
            }
            (totalLiquidityProvider, , , , , ,) = LIQUIDITY_REWARD_HANeP_4.totalLiquidityInfo(provider);
            if(totalLiquidityProvider > 0) {
                totalInfo[provider].totalproviderDividendAmount += amount;
                emit RewardUpdated(provider, amount);
            }else {
                revert("You don't have permission");
            }
        }
    }

    /**
     * @dev Adds addresses to the whitelist and assigns rewards to them. Only the contract owner can call this function.
     * @param _accounts Array of addresses to be whitelisted.
     * @param _amounts Array of reward amounts for each whitelisted address.
     */
    function addWhitelist(address[] memory _accounts, uint256[] memory _amounts) external nonReentrant onlyOwner {
        require(_accounts.length == _amounts.length, "Accounts and amounts arrays must have the same length");
        for (uint i = 0; i < _accounts.length; i++) {
            address user = _accounts[i];
            for (uint j = 0; j < i; j++) {
                require(_accounts[j] != user, "Duplicate accounts are not allowed");
            }
            totalInfo[user].totalDividendAmount += _amounts[i];
            emit RewardUpdated(user, _amounts[i]);
        }
    }

    /**
     * @dev Allows liquidity providers to stake their dividend rewards.
     * This function can only be called by dividend reward eligible liquidity providers. The staked amount is added to the total supply.
     */
    function stakeProviderDividends() public nonReentrant whenNotPaused {
        TotalInfo storage total = totalInfo[msg.sender];
        uint256 amount = total.totalproviderDividendAmount;
        require(HANeP.balanceOf(address(this)) > amount * REWARD_PER_SECOND * YEAR / WEI_MULTIPLIER, "Total amount of rewards is too high");
        require(amount > 0, "Not a whitelisted user");
        _addToStakerArray(msg.sender, amount);
        LIQUIDITY_REWARD_HANeP_4.registrationProvider(msg.sender);
        total.totalStakedAmount += amount;
        totalSupply += amount;
        delete total.totalproviderDividendAmount;
        emit Staked(msg.sender, amount);
    }

    /**
     * @dev Allows liquidity providers to stake their dividends.
     * This function can only be called by dividend-eligible liquidity providers. The staked amount is added to the total supply.
     */
    function stakeDividends() public nonReentrant whenNotPaused {
        TotalInfo storage total = totalInfo[msg.sender];
        uint256 amount = total.totalDividendAmount;
        require(HANeP.balanceOf(address(this)) > amount * REWARD_PER_SECOND * YEAR / WEI_MULTIPLIER, "Total amount of rewards is too high");
        require(amount > 0, "Not a whitelisted user");
        _addToStakerArray(msg.sender, amount);
        total.totalStakedAmount += amount;
        totalSupply += amount;
        delete total.totalDividendAmount;
        emit Staked(msg.sender, amount);
    }

    /**
     * @dev Allows users to stake HANeP tokens.
     * @param _amount The amount of HANeP tokens to stake.
     */
    function stake(uint256 _amount) public nonReentrant whenNotPaused {
        TotalInfo storage total = totalInfo[msg.sender];
        uint256 amount = _amount;
        require(HANeP.balanceOf(address(this)) > amount * REWARD_PER_SECOND * YEAR / WEI_MULTIPLIER, "Total amount of rewards is too high");
        require(amount > 0, "Not a whitelisted user");
        _addToStakerArray(msg.sender, amount);
        HANeP.transferFrom(msg.sender, address(this), amount);
        total.totalStakedAmount += amount;
        totalSupply += amount;
        emit Staked(msg.sender, amount);
    }

    /**
     * @dev Allows users to withdraw their staked HANeP tokens after a certain period.
     * @param _index The index of the staking entry to withdraw.
     */
    function withdraw(uint256 _index) public nonReentrant whenNotPaused {
        Staker memory staker = stakerArray[msg.sender][_index];
        TotalInfo storage total = totalInfo[msg.sender];
        require(block.timestamp > staker.withdrawalTime, "It's not the time to withdraw");
        totalSupply -= staker.amount;
        total.totalStakedAmount -= staker.amount;
        total.unclaimedRewards += _calculateRewards(msg.sender, _index);
        HANeP.transfer(msg.sender, staker.amount);
        emit Withdrawn(msg.sender, staker.amount);
        _removeStaker(_index);
    }

    /**
     * @dev Allows users to claim their accumulated rewards.
     */
    function claimRewards() external nonReentrant whenNotPaused {
        TotalInfo storage total = totalInfo[msg.sender];
        uint256 reward = 0;
        for(uint i = 0; i < stakerArray[msg.sender].length; i++) {
            Staker storage staker = stakerArray[msg.sender][i];
            uint256 rewardValue = _calculateRewards(msg.sender, i);
            if (rewardValue > 0) {
                reward += rewardValue; 
                staker.lastClaimedTime = block.timestamp;
            }
        }
        require(reward + total.unclaimedRewards > 0, "No rewards to claim");
        HANeP.transfer(msg.sender, reward + total.unclaimedRewards);
        total.totalRewardReleased += reward + total.unclaimedRewards;
        total.unclaimedRewards = 0;
        emit RewardPaid(msg.sender, reward);
    }

    /**
     * @dev Views the total rewards payable to a user.
     * @param _user The address of the user to view rewards for.
     * @return reward The total rewards payable to the user.
     */
    function rewardView(address _user) public view returns(uint256) {
        uint256 reward = 0;
        for(uint i = 0; i < stakerArray[_user].length; i++) {
            uint256 rewardValue = _calculateRewards(_user, i);
            if (rewardValue > 0) {
                reward += rewardValue;
            }
        }
        return reward;
    }

    /**
     * @dev Views the remaining lock-up period for a user's staking entry.
     * @param _user The address of the user.
     * @param _index The index of the staking entry.
     * @return The remaining lock-up period in seconds. Returns 0 if the period has expired.
     */
    function remainingDuration(address _user ,uint _index) public view returns (uint256) {
        Staker storage staker = stakerArray[_user][_index];
        if(staker.withdrawalTime > block.timestamp) {
            return staker.withdrawalTime - block.timestamp;
        } else {
            return 0;
        }
    }

    /**
     * @dev Retrieves all staking entries for a user.
     * @param _user The address of the user.
     * @return An array of staking entries for the user.
     */
    function getStakerArray(address _user) public view returns(Staker[] memory) {
        return stakerArray[_user];
    }

    /**
     * @notice Adds a new staker entry to the array for a user.
     * @dev This is an internal function called during staking operations.
     * @param _user The address of the staker.
     * @param _amount The amount of HAN tokens being staked.
     */
    function _addToStakerArray(address _user, uint256 _amount) private {
        Staker memory newStaker = Staker({
        amount : _amount,
        startTime : block.timestamp,
        lastClaimedTime: block.timestamp,
        withdrawalTime : block.timestamp + YEAR
        });
        stakerArray[_user].push(newStaker);
    }

    /**
     * @notice Removes a staker entry from the array at a specific index.
     * @dev This is an internal function called during withdrawal operations.
     * @param _index The index of the staker entry to remove.
     */
    function _removeStaker(uint256 _index) private {
        require(_index < stakerArray[msg.sender].length, "Invalid index");
        stakerArray[msg.sender][_index] = stakerArray[msg.sender][stakerArray[msg.sender].length - 1];
        stakerArray[msg.sender].pop();
    }

    /**
     * @notice Calculates the rewards for a staker based on the staked amount and time.
     * @dev This is an internal view function used to calculate rewards for claiming.
     * @param _user The address of the staker.
     * @param _index The index of the staker entry for which to calculate rewards.
     * @return The calculated reward amount.
     */
    function _calculateRewards(address _user, uint256 _index) internal view returns (uint256) {
        Staker memory staker = stakerArray[_user][_index];
        uint256 reward;
        uint256 stakedTime = block.timestamp - staker.lastClaimedTime;
        reward = staker.amount * stakedTime * REWARD_PER_SECOND / WEI_MULTIPLIER;
        return reward;
    }

    /**
     * @notice Temporarily pauses all staking, withdrawal, and reward claiming operations.
     * @dev Can only be called by the contract owner. Utilizes the Pausable contract's _pause function.
     */
    function pause() external nonReentrant onlyOwner {
        _pause();
    }

    /**
     * @notice Resumes all operations after being paused.
     * @dev Can only be called by the contract owner. Utilizes the Pausable contract's _unpause function.
     */
    function unpause() external nonReentrant onlyOwner {
        _unpause();
    }

    /**
     * @notice Recovers any ERC20 tokens sent to the contract by mistake.
     * @dev Can only be called by the contract owner. This function provides a safeguard against accidental token transfers to the contract.
     * @param _tokenAddress The address of the ERC20 token to recover.
     * @param _tokenAmount The amount of the ERC20 token to recover.
     */
    function recoverERC20(address _tokenAddress, uint256 _tokenAmount) external nonReentrant onlyOwner {
        IERC20(_tokenAddress).transfer(msg.sender, _tokenAmount);
        emit RecoveredERC20(_tokenAddress, _tokenAmount);
    }

    /**
     * @notice Recovers any ERC721 tokens sent to the contract by mistake.
     * @dev Can only be called by the contract owner. Similar to recoverERC20, but for ERC721 tokens.
     * @param _tokenAddress The address of the ERC721 token to recover.
     * @param _tokenId The ID of the ERC721 token to recover.
     */
    function recoverERC721(address _tokenAddress, uint256 _tokenId) external nonReentrant onlyOwner {
        IERC721(_tokenAddress).safeTransferFrom(address(this),msg.sender,_tokenId);
        emit RecoveredERC721(_tokenAddress, _tokenId);
    }

    // Event declarations to log actions within the contract
    event RewardUpdated(address indexed user, uint256 amount);
    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);
    event RecoveredERC20(address token, uint256 amount);
    event RecoveredERC721(address token, uint256 tokenId);
}
