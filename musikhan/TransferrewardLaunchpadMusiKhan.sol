// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

// The TransferrewardLaunchpadMusiKhan contract allows users to receive rewards for a year from the time they transfer their Musikhan NFT.
contract TransferrewardLaunchpadMusiKhan is Ownable, ReentrancyGuard, Pausable {
    // Address of the ERC721 token to be transferred
    IERC721 public constant TRANSFER_TOKEN = IERC721(0xA7333Ec665D8F3f617a4C1e9F299ad05Bda908B7); // Musikhan NFT Optimism
    // IERC721 public constant TRANSFER_TOKEN = IERC721(0x462B4C6546300b20d62016e44ABf9d8F03A2cEB1); // Musikhan NFT Optimism Goerli
    // Address of the ERC20 token to be used for rewards
    IERC20 public constant REWARD_TOKEN = IERC20(0xC3248A1bd9D72fa3DA6E6ba701E58CbF818354eB); // HANePlatform token Optimism
    // IERC20 public constant REWARD_TOKEN = IERC20(0xE947Af98dC5c2FCfcc2D2F89325812ba5d332b41); // HANePlatform token Optimism Goerli

    // Struct to store the information of the transmitter
    struct Transmitter {
        uint256[] tokenIds; // List of transferred token IDs
        uint256 totalReward; // Total rewards received
        uint256 unclaimedRewards; // Unclaimed rewards
        uint256 lastClaimedTime; // Last reward claim completion time
    }

    // Struct to store the information of the token
    struct TokenInfo {
        uint256 tokenTransferTime; // Time when the token was transferred
        uint256 remainingReward; // Remaining reward for the token
    }

    uint256 public constant REWARD_PER_SECOND = 1041666666666; // Reward per second
    uint256 public constant ONE_YEAR = 365 days; // Value of one year converted to seconds

    uint256 public totalSupply; // Total number of currently transferred tokens
    uint256[] private totalTokenIds; // List of all transferred token IDs

    mapping(address => Transmitter) private transmitter; // Mapping to store the information of the transmitter for each address
    mapping(uint256 => TokenInfo) public tokenInfo; // Mapping to store the information for each token ID

    // Function to return the information of the transmitter for the given address
    function getTransmitterData(address _user) public view returns (Transmitter memory) {
        return transmitter[_user];
    }

    // Function to return the list of all transferred token IDs
    function getTotalTokenIds() public view returns (uint256[] memory) {
        return totalTokenIds;
    }

    // Function to transfer the given token ID
    function transferToken(uint256 _tokenId) public nonReentrant {
        // Check if the balance of the reward token is sufficient
        uint256 expectedAnnualReward = ONE_YEAR * (totalSupply * REWARD_PER_SECOND);
        uint256 currentBalance = REWARD_TOKEN.balanceOf(address(this));
        uint256 minimalBalanceRequired = expectedAnnualReward + ONE_YEAR * REWARD_PER_SECOND;
        require(currentBalance >= minimalBalanceRequired, "Insufficient reward token balance"); // The contract must have a minimum balance of the reward token before transferring.
        require(TRANSFER_TOKEN.ownerOf(_tokenId) == msg.sender, "Only the owner of the token can transfer"); // Check the owner address of the token ID

        Transmitter storage sender = transmitter[msg.sender];        
        TokenInfo storage info = tokenInfo[_tokenId];

        sender.unclaimedRewards += _calculateRewards(msg.sender); // If there is a transferred token, save the accumulated rewards in unclaimedRewards
        sender.lastClaimedTime = block.timestamp; // Update the last reward claim completion time to the current time
        sender.tokenIds.push(_tokenId); // Add the token ID to the list of transferred tokens
        totalTokenIds.push(_tokenId); // Add the token ID to the list of all transferred token IDs

        info.remainingReward = REWARD_PER_SECOND * ONE_YEAR; // Save one year's worth of remaining rewards for the token ID
        info.tokenTransferTime = block.timestamp; // Update the staking start time

        totalSupply++; // Increase the number of transferred tokens

        TRANSFER_TOKEN.transferFrom(msg.sender, address(this), _tokenId); // Transfer the token to the contract

        emit Transferred(msg.sender, _tokenId); // Emit an event to notify that the token has been transferred
    }

    // Function to claim rewards
    function claimRewards() public nonReentrant {
        Transmitter storage sender = transmitter[msg.sender];

        uint256 reward = sender.unclaimedRewards + _calculateRewards(msg.sender); // Calculate and add unclaimed rewards

        require(reward > 0, "You have no rewards to claim"); // Check if there are rewards
        require(reward < REWARD_TOKEN.balanceOf(address(this)), "Not enough tokens"); // Check if there are enough reward tokens

        sender.unclaimedRewards = 0; // Reset unclaimed rewards
        sender.lastClaimedTime = block.timestamp; // Update the last claimed time to the current time
        sender.totalReward += reward; // Add the claimed reward to the total reward

        REWARD_TOKEN.transfer(msg.sender, reward); // Transfer the reward tokens to the transmitter
        
        emit RewardPaid(msg.sender, reward); // Emit an event to notify that the reward has been paid
    }

    // Function to view rewards
    function rewardView(address _user) public view returns (uint256) {
        Transmitter storage sender = transmitter[_user];

        uint256 reward = 0; // Set the initial value for calculating the reward
        uint256 stakedTime = block.timestamp - sender.lastClaimedTime; // Calculate the time elapsed since the last reward claim
        // Iterate over all tokens transferred by the transmitter
        for (uint i = 0; i < sender.tokenIds.length; i++) {
            uint256 tokenId = sender.tokenIds[i];
            uint256 potentialReward = stakedTime * REWARD_PER_SECOND; // Calculate the accumulated reward (staking time * reward per second)
            uint256 remainingReward = tokenInfo[tokenId].remainingReward; // Get the remaining reward for the token
            // If the remaining reward is less than or equal to the accumulated reward, add the remaining reward to the reward
            if (remainingReward <= potentialReward) {
                reward += remainingReward;
            } else {
                // Otherwise, add the potential reward to the reward
                reward += potentialReward;
            }
        }
        return reward + sender.unclaimedRewards; // Return the calculated reward plus unclaimed rewards
    }

    // Internal function to calculate rewards
    function _calculateRewards(address _user) internal returns (uint256) {
        Transmitter storage sender = transmitter[_user];

        uint256 reward = 0; // Set the initial value for calculating the reward
        uint256 stakedTime = block.timestamp - sender.lastClaimedTime; // Calculate the time elapsed since the last reward claim

        // If the transmitter has no transferred tokens, return 0
        if(sender.tokenIds.length == 0) {
            return reward;
        }

        // Iterate over all tokens transferred by the transmitter
        for (uint i = 0; i < sender.tokenIds.length; i++) {
            
            uint256 tokenId = sender.tokenIds[i];
            uint256 potentialReward = stakedTime * REWARD_PER_SECOND; // Calculate the accumulated reward (staking time * reward per second)
            uint256 remainingReward = tokenInfo[tokenId].remainingReward; // Get the remaining reward for the token

            // If the remaining reward is less than or equal to the accumulated reward, add the remaining reward to the reward and set the remaining reward for the token to 0
            if (remainingReward <= potentialReward) {
                reward += remainingReward;
                tokenInfo[tokenId].remainingReward = 0;
            } else {
                // Otherwise, add the accumulated reward to the reward and subtract the potential reward from the remaining reward for the token
                reward += potentialReward;
                tokenInfo[tokenId].remainingReward -= potentialReward;
            }
        }
        return reward; // Return the calculated reward
    }

    // Function to pause the contract (only callable by the owner)
    function pause() public onlyOwner {
        _pause();
    }

    // Function to unpause the contract (only callable by the owner)
    function unpause() public onlyOwner {
        _unpause();
    }

    // Function to recover ERC20 tokens (only callable by the owner)
    function recoverERC20(address _tokenAddress, uint256 _tokenAmount) external onlyOwner {
        IERC20(_tokenAddress).transfer(msg.sender, _tokenAmount);
        emit RecoveredERC20(_tokenAddress, _tokenAmount);
    }

    // Function to recover ERC721 tokens (only callable by the owner)
    function recoverERC721(address _tokenAddress, uint256 _tokenId) external onlyOwner {
        IERC721(_tokenAddress).safeTransferFrom(address(this), msg.sender, _tokenId);
        emit RecoveredERC721(_tokenAddress, _tokenId);
    }

    // Event to notify that a token has been transferred
    event Transferred(address owner, uint256 tokenId);
    // Event to notify that a reward has been paid
    event RewardPaid(address indexed user, uint256 reward);
    // Event to notify that an ERC20 token has been recovered
    event RecoveredERC20(address token, uint256 amount);
    // Event to notify that an ERC721 token has been recovered
    event RecoveredERC721(address token, uint256 tokenId);
}
