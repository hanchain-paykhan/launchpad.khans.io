// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

// The StakingLunchpadMusiKhan contract allows users to stake Musikhan NFTs and receive rewards based on the staking duration.
contract StakingLaunchpadMusiKhan is Ownable, ReentrancyGuard, Pausable {
    // The address of the NFT token to be used for staking
    IERC721 public constant STAKING_TOKEN = IERC721(0xA7333Ec665D8F3f617a4C1e9F299ad05Bda908B7); // Musikhan NFT Optimism
    // IERC721 public constant STAKING_TOKEN = IERC721(0x462B4C6546300b20d62016e44ABf9d8F03A2cEB1); // Musikhan NFT Optimism Goerli
    // The address of the ERC20 token to be used for rewards
    IERC20 public constant REWARD_TOKEN = IERC20(0xC3248A1bd9D72fa3DA6E6ba701E58CbF818354eB); // HANePlatform token Optimism
    // IERC20 public constant REWARD_TOKEN = IERC20(0xE947Af98dC5c2FCfcc2D2F89325812ba5d332b41); // HANePlatform token Optimism Goerli

    // Structure to store staker's information
    struct Staker {
        uint256[] tokenIds; // List of staked token IDs
        uint256 totalReward; // Total rewards received
        uint256 unclaimedRewards; // Unclaimed rewards
        uint256 countStaked; // Number of staked tokens
        uint256 lastClaimedTime; // The time when the last reward claim was completed
    }

    // Reward per second
    uint256 public constant REWARD_PER_SECOND = 1041666666666;
    // Value converted from 1 year to seconds
    uint256 public constant ONE_YEAR = 365 days;

    // Total number of currently staked tokens
    uint256 public totalSupply;
    // List of all staked token IDs
    uint256[] private totalTokenIds;

    // Mapping to store staker's information for each address
    mapping(address => Staker) private stakers;

    // Function to return staker's information for a given address
    function getStakerData(address _user) public view returns (Staker memory) {
        return stakers[_user];
    }

    // Function to return the list of all staked token IDs
    function getTotalTokenIds() public view returns (uint256[] memory) {
        return totalTokenIds;
    }

    // Function to stake a token with a given token ID
    function stake(uint256 _tokenId) public nonReentrant {
        // Check if the balance of the reward token is sufficient
        uint256 expectedAnnualReward = ONE_YEAR * (totalSupply * REWARD_PER_SECOND);
        uint256 currentBalance = REWARD_TOKEN.balanceOf(address(this));
        uint256 minimalBalanceRequired = expectedAnnualReward + ONE_YEAR * REWARD_PER_SECOND;
        require(currentBalance >= minimalBalanceRequired, "Insufficient reward token balance"); // The contract must have a minimum balance of reward tokens to continue staking.
        // Check if the owner of the token is the address requesting the stake
        require(STAKING_TOKEN.ownerOf(_tokenId) == msg.sender, "Only the owner of the token can stake");

        // Get the staker's information
        Staker storage staker = stakers[msg.sender];
        // Process differently depending on whether the staker is staking for the first time or not
        if (staker.countStaked == 0) {
            _stake(_tokenId);
        } else {
            // Calculate and add unclaimed rewards
            staker.unclaimedRewards += _calculateRewards(msg.sender);
            _stake(_tokenId);
        }
    }

    // Internal function to stake a token
    function _stake(uint256 _tokenId) internal {
        // Get the staker's information
        Staker storage staker = stakers[msg.sender];
        // Set the last update time to the current time
        staker.lastClaimedTime = block.timestamp;
        // Add the token ID to the list of staked tokens
        staker.tokenIds.push(_tokenId);
        // Increase the number of staked tokens
        staker.countStaked++;
        // Add the token ID to the list of all staked tokens
        totalTokenIds.push(_tokenId);
        // Increase the total number of staked tokens
        totalSupply++;
        // Transfer the token from the staker to the contract
        STAKING_TOKEN.transferFrom(msg.sender, address(this), _tokenId);
        // Emit an event to notify that a token has been staked
        emit Staked(msg.sender, _tokenId);
    }

    // Function to unstake a token with a given token ID
    function unstake(uint256 _tokenId) public nonReentrant {
        // Check if the owner of the token is the address requesting the unstake
        require(STAKING_TOKEN.ownerOf(_tokenId) == msg.sender, "Only the owner of the token can unstake");
        // Get the staker's information
        Staker storage staker = stakers[msg.sender];
        // Calculate and add unclaimed rewards
        staker.unclaimedRewards += _calculateRewards(msg.sender);
        // Set the last update time to the current time
        staker.lastClaimedTime = block.timestamp;
        // Decrease the number of staked tokens
        staker.countStaked--;
        // Decrease the total number of staked tokens
        totalSupply--;
        // Remove the token ID from the list of staked tokens
        _removeTokenById(_tokenId, staker.tokenIds);
        _removeTokenById(_tokenId, totalTokenIds);

        // Transfer the token from the contract to the staker
        STAKING_TOKEN.transferFrom(address(this), msg.sender, _tokenId);
        // Emit an event to notify that a token has been unstaked
        emit Unstaked(msg.sender, _tokenId);
    }

    // Function to claim rewards
    function claimRewards() public nonReentrant {
        // Get the staker's information
        Staker storage staker = stakers[msg.sender];
        // Calculate and add unclaimed rewards
        uint256 reward = staker.unclaimedRewards + _calculateRewards(msg.sender);
        // Check if there are any rewards
        require(reward > 0, "You have no rewards to claim");
        // Check if there are enough reward tokens
        require(reward < REWARD_TOKEN.balanceOf(address(this)), "Not enough tokens");
        // Reset unclaimed rewards
        staker.unclaimedRewards = 0;
        // Update the last claimed time to the current time
        staker.lastClaimedTime = block.timestamp;
        // Add the claimed rewards to the total rewards
        staker.totalReward += reward;
        // Transfer the reward tokens to the staker
        REWARD_TOKEN.transfer(msg.sender, reward);
        // Emit an event to notify that rewards have been paid
        emit RewardPaid(msg.sender, reward);
    }

    // Function to view rewards
    function rewardView(address _user) public view returns (uint256) {
        // Calculate rewards
        uint256 rewards = _calculateRewards(_user) + stakers[_user].unclaimedRewards;
        // Return rewards
        return rewards;
    }

    // Function to pause the contract (only the owner can call)
    function pause() public onlyOwner {
        _pause();
    }

    // Function to restart the contract (only the owner can call)
    function unpause() public onlyOwner {
        _unpause();
    }

    // Function to recover ERC20 tokens (only the owner can call)
    function recoverERC20(address _tokenAddress, uint256 _tokenAmount) external onlyOwner {
        IERC20(_tokenAddress).transfer(msg.sender, _tokenAmount);
        emit RecoveredERC20(_tokenAddress, _tokenAmount);
    }

    // Function to recover ERC721 tokens (only the owner can call)
    function recoverERC721(address _tokenAddress, uint256 _tokenId) external onlyOwner {
        IERC721(_tokenAddress).safeTransferFrom(address(this), msg.sender, _tokenId);
        emit RecoveredERC721(_tokenAddress, _tokenId);
    }

    // Internal function to calculate rewards
    function _calculateRewards(address _user) private view returns (uint256) {
        // Get the staker's information
        Staker storage staker = stakers[_user];
        // Calculate rewards
        uint256 reward;
        uint256 stakedTime = block.timestamp - staker.lastClaimedTime;
        reward = stakedTime * (staker.countStaked * REWARD_PER_SECOND);
        // Return rewards
        return reward;
    }

    // Internal function to find the index of a token by token ID
    function _findTokenIndex(uint256 value, uint256[] storage tokenIds) private view returns (uint256) {
        uint256 i = 0;
        while (tokenIds[i] != value) {
            i++;
        }
        return i;
    }

    // Internal function to remove a token from the list by index
    function _removeTokenByIndex(uint256 i, uint256[] storage tokenIds) private {
        // Check if the index is within the range of the array
        require(i < tokenIds.length, "Index out of bounds");

        // Move the last element to the position to be removed
        if (i != tokenIds.length - 1) {
            tokenIds[i] = tokenIds[tokenIds.length - 1];
        }
        // Reduce the size of the array
        tokenIds.pop();
    }

    // Internal function to remove a token from the list by token ID
    function _removeTokenById(uint256 value, uint256[] storage tokenIds) private {
        // Find the index of the token by token ID
        uint256 i = _findTokenIndex(value, tokenIds);
        // Remove the token from the list by index
        _removeTokenByIndex(i, tokenIds);
    }

    // Event to notify that a token has been unstaked
    event Unstaked(address owner, uint256 tokenId);
    // Event to notify that a token has been staked
    event Staked(address owner, uint256 tokenId);
    // Event to notify that rewards have been paid
    event RewardPaid(address indexed user, uint256 reward);
    // Event to notify that ERC20 tokens have been recovered
    event RecoveredERC20(address token, uint256 amount);
    // Event to notify that ERC721 tokens have been recovered
    event RecoveredERC721(address token, uint256 tokenId);
}
