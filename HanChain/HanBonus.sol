// SPDX-License-Identifier: MIT
pragma solidity ^0.7.0;
pragma abicoder v2;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "./LiquidityReward_4.sol";

contract HanBonus is ReentrancyGuard, Ownable, Pausable {

    IERC20 public constant HAN = IERC20(0x50Bce64397C75488465253c0A034b8097FeA6578);
    LiquidityReward_4 public constant LIQUIDITY_REWARD = LiquidityReward_4(0x1df78bAc48eA78Be969370765a6238C91e5Ce6c2);

    // Structure to store the information of a liquidity Referrer.
    struct Referrer {
        uint256 amount; // Amount of HAN token staked
        uint256 lastClaimedTime; // Last time rewards were claimed.
        uint256 withdrawalTime; // Time when the withdrawal is available
    }
    mapping(address => Referrer) private referrers; // Mapping to store the information of a liquidity referrers.
    mapping(address => Referrer[]) private referrerArray; // Mapping to store the information of a liquidity referrerArray.

    // structure to store the total information of a liquidity TotalReferrerInfo.
    struct TotalReferrerInfo {
        uint256 totalRewardReleased;
        uint256 totalStakedAmount;
        uint256 totalReferrerRewardAmount;
        uint256 unclaimedRewards;
    }
    mapping(address => TotalReferrerInfo) public totalReferrer; // Mapping to store the total information of a liquidity totalReferrer.
    
    uint256 public constant YEAR = 31536000; // Time in seconds for one year.
    uint256 private constant WEI_MULTIPLIER = 1e18; // Constant for Ethereum unit conversion.
    uint256 public constant REWARD_PER_SECOND = 43189120370; // 1 HAN token per second

    uint256 public totalSupply; // Total amount of HAN token staked
    address[] private referrerList; // Array to store the information of a liquidity referrerList.
    mapping(address => uint256) public referrerRewardAmount; // Mapping to store the information of a liquidity referrerRewardAmount.

    // Function to add the address of a liquidity referrer.
    function addReferrerList(address[] memory _accounts) public onlyOwner {
        for (uint i = 0; i < _accounts.length; i++) {

            address user = _accounts[i];
            for (uint j = 0; j < i; j++) {
                require(_accounts[j] != user, "Duplicate accounts are not allowed");
            }

            bool isExisting = false;
            for (uint k = 0; k < referrerList.length; k++) {
                if (referrerList[k] == user) {
                    isExisting = true;
                    break;
                }
            }
            if (!isExisting) {
                referrerList.push(user);
                emit ReferrerAdded(user);
            }

            uint256 amount;
            (,,,,,uint256 referrerReward,) = LIQUIDITY_REWARD.totalLiquidityInfo(user);
            if(referrerReward == 0) {
                revert("don't have any reward");
            }

            amount = LIQUIDITY_REWARD.registrationV1(user);
            referrerRewardAmount[user] += amount;
            emit RewardUpdated(user, amount);
        }
    }

    // Function to stake HAN token.
    function stake() public nonReentrant whenNotPaused {
        Referrer memory referrer = referrers[msg.sender];
        TotalReferrerInfo storage totalInfo = totalReferrer[msg.sender];
        require(HAN.balanceOf(address(this)) > referrerRewardAmount[msg.sender] * REWARD_PER_SECOND * YEAR / WEI_MULTIPLIER, "Total amount of rewards is too high");
        require(referrerRewardAmount[msg.sender] > 0, "Not a whitelisted user");
        uint256 amount = referrerRewardAmount[msg.sender];

        referrer.amount = amount;
        referrer.lastClaimedTime = block.timestamp;
        referrer.withdrawalTime = block.timestamp + YEAR;

        referrerArray[msg.sender].push(referrer);

        totalInfo.totalStakedAmount += amount;
        totalInfo.totalReferrerRewardAmount += amount;
        totalSupply += amount;

        delete referrerRewardAmount[msg.sender];
        removeAddress(referrerList, msg.sender);
        emit Staked(msg.sender, amount);
    }

    // Function to withdraw HAN token.
    function withdraw(uint256 _index) public nonReentrant whenNotPaused {
        Referrer memory referrer = referrerArray[msg.sender][_index];
        TotalReferrerInfo storage totalInfo = totalReferrer[msg.sender];
        require(block.timestamp > referrer.withdrawalTime, "It's not the time to withdraw");

        totalSupply -= referrer.amount;

        totalInfo.totalStakedAmount -= referrer.amount;
        totalInfo.unclaimedRewards += _calculateRewards(msg.sender, _index);

        HAN.transfer(msg.sender, referrer.amount);
        emit Withdrawn(msg.sender, referrer.amount);
        removeReferrer(_index);    
    }

    function claimRewards() external nonReentrant whenNotPaused {
        TotalReferrerInfo storage totalInfo = totalReferrer[msg.sender];
        uint256 reward;

        for(uint i = 0; i < referrerArray[msg.sender].length; i++) {
            Referrer storage referrer = referrerArray[msg.sender][i];
            uint256 rewardValue = _calculateRewards(msg.sender, i); // Calculate the reward for the liquidity provider.
            if (rewardValue > 0) {
                reward += rewardValue;
                referrer.lastClaimedTime = block.timestamp;
            }
        }
        require(reward + totalInfo.unclaimedRewards > 0, "No rewards to claim"); // Check if there are rewards to claim.

        HAN.transfer(msg.sender, reward + totalInfo.unclaimedRewards); // Transfer the calculated rewards.

        totalInfo.totalRewardReleased += reward + totalInfo.unclaimedRewards; // Update the total amount of rewards released.
        totalInfo.unclaimedRewards = 0; // Reset the unclaimed rewards.

        emit RewardPaid(msg.sender, reward);
    }

    // Function to return to reward amount.
    function rewardView(address _user) public view returns(uint256) {
        uint256 reward = 0;
        for(uint i = 0; i < referrerArray[_user].length; i++) {
            uint256 rewardValue = _calculateRewards(_user, i);
            if (rewardValue > 0) {
                reward += rewardValue;
            }
        }
        return reward;
    }

    // Function to return to remaining duration.
    function remainingDuration(address _user ,uint256 _index) public view returns (uint256) {
        Referrer memory referrer = referrerArray[_user][_index];
        if(referrer.withdrawalTime > block.timestamp) {
            return referrer.withdrawalTime - block.timestamp;
        } else {
            return 0;
        }
    }

    // Function to return to referrer data.
    function getReferrerData(address _user) public view returns(Referrer[] memory) {
        return referrerArray[_user];
    }

    // Function to return to referrer list.
    function getReferrerList() public view returns(address[] memory) {
        return referrerList;
    }

    // private function to calculate rewards for a user.
    function _calculateRewards(address _user, uint256 _index) private view returns (uint256) {
        Referrer memory referrer = referrerArray[_user][_index];
        uint256 reward;
        uint256 stakedTime = block.timestamp - referrer.lastClaimedTime; // Calculate the time elapsed since the last reward claim.
        reward = referrer.amount * stakedTime * REWARD_PER_SECOND / WEI_MULTIPLIER; // Calculate the reward based on elapsed time.
        return reward;
    }

    // Functions to pause or unpause the contract.
    function pause() public onlyOwner {
        _pause();
    }
    function unpause() public onlyOwner {
        _unpause();
    }

    // Functions to recover wrong tokens or Ether sent to the contract.
    function recoverERC20(address _tokenAddress, uint256 _tokenAmount) external onlyOwner {
        IERC20(_tokenAddress).transfer(msg.sender, _tokenAmount);
        emit RecoveredERC20(_tokenAddress, _tokenAmount);
    }
    function recoverERC721(address _tokenAddress, uint256 _tokenId) external onlyOwner {
        IERC721(_tokenAddress).safeTransferFrom(address(this),msg.sender,_tokenId);
        emit RecoveredERC721(_tokenAddress, _tokenId);
    }
    function recoverEther(address payable _recipient, uint256 _ethAmount) external onlyOwner nonReentrant{
        _recipient.transfer(_ethAmount);
        emit RecoveredEther(_recipient, _ethAmount);
    }

    function removeReferrer(uint256 _index) private {
        require(_index < referrerArray[msg.sender].length, "Invalid index");
        referrerArray[msg.sender][_index] = referrerArray[msg.sender][referrerArray[msg.sender].length - 1];
        referrerArray[msg.sender].pop();
    }

    function removeAddress(address[] storage _array, address _address) private {
        for (uint256 i = 0; i < _array.length; i++) {
            if (_array[i] == _address) {
                _array[i] = _array[_array.length - 1];
                _array.pop();
                break;
            }
        }
    }

    // ------------------ EVENTS ------------------ //
    event ReferrerAdded(address indexed user);
    event RewardUpdated(address indexed user, uint256 amount);
    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);
    event RecoveredERC20(address token, uint256 amount);
    event RecoveredERC721(address token, uint256 tokenId);
    event RecoveredEther(address indexed to, uint256 amount);
}
