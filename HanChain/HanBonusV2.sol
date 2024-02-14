// SPDX-License-Identifier: MIT
pragma solidity ^0.7.0;
pragma abicoder v2;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "./LiquidityReward_4.sol";

contract HanBonusV2 is ReentrancyGuard, Ownable, Pausable {

    IERC20 public constant HAN = IERC20(0x50Bce64397C75488465253c0A034b8097FeA6578);
    LiquidityReward_4 public constant LIQUIDITY_REWARD = LiquidityReward_4(0x23f2fBF0A4F814d5B45741749e2fb589f061c24A);

    // Structure to store the information of a liquidity provider.
    struct LiquidityProvider {
        uint256 amount;
        uint256 lastClaimedTime;
        uint256 withdrawalTime;
    }
    mapping(address => LiquidityProvider[]) private providerArray; // Mapping to store the information of a liquidity providerArray.

    // structure to store the total information of a liquidity TotalProviderInfo.
    struct TotalProviderInfo {
        uint256 totalRewardReleased;
        uint256 totalStakedAmount;
        uint256 totalProviderRewardAmount;
        uint256 unclaimedRewards;
    }
    mapping(address => TotalProviderInfo) public totalProvider; // Mapping to store the total information of a liquidity totalProvider.
    
    uint256 public constant YEAR = 31536000; // Time in seconds for one year.
    uint256 private constant WEI_MULTIPLIER = 1e18; // Constant for Ethereum unit conversion.
    uint256 public constant REWARD_PER_SECOND = 43189120370; // 1 HAN token per second

    uint256 public totalSupply; // Total amount of HAN token staked
    address[] private providerList; // Array to store the information of a liquidity providerList.
    mapping (address => bool) public isProvider; // Mapping to store the information of a liquidity isProvider.
    mapping(address => uint256) public providerRewardAmount; // Mapping to store the information of a liquidity providerRewardAmount.

    // Function to add the address of a liquidity provider.
    function addWhitelist(address[] memory _accounts, uint256[] memory _amounts) public onlyOwner {
        require(_accounts.length == _amounts.length, "Accounts and amounts arrays must have the same length");

        for (uint i = 0; i < _accounts.length; i++) {
            address user = _accounts[i];

            for (uint j = 0; j < i; j++) {
                require(_accounts[j] != user, "Duplicate accounts are not allowed");
            }

            if (!isProvider[user]) {
                isProvider[user] = true;
                providerList.push(user);
                ProviderAdded(user);
            }
            providerRewardAmount[user] += _amounts[i];
            RewardUpdated(user, _amounts[i]);
        }
    }

    // Function to stake HAN token.
    function stake() public nonReentrant whenNotPaused {
        TotalProviderInfo storage totalInfo = totalProvider[msg.sender];
        require(HAN.balanceOf(address(this)) > providerRewardAmount[msg.sender] * REWARD_PER_SECOND * YEAR / WEI_MULTIPLIER, "Total amount of rewards is too high");
        require(providerRewardAmount[msg.sender] > 0, "Not a whitelisted user");
        uint256 amount = providerRewardAmount[msg.sender];

        _addToProviderArray(msg.sender, amount);
        LIQUIDITY_REWARD.registrationV2(msg.sender);
        
        totalInfo.totalStakedAmount += amount;
        totalInfo.totalProviderRewardAmount += amount;
        totalSupply += amount;

        delete providerRewardAmount[msg.sender];
        _removeAddress(providerList, msg.sender);
        emit Staked(msg.sender, amount);
    }

    // Function to withdraw HAN token.
    function withdraw(uint256 _index) public nonReentrant whenNotPaused {
        LiquidityProvider memory provider = providerArray[msg.sender][_index];
        TotalProviderInfo storage totalInfo = totalProvider[msg.sender];
        require(block.timestamp > provider.withdrawalTime, "It's not the time to withdraw");

        totalSupply -= provider.amount;

        totalInfo.totalStakedAmount -= provider.amount;
        totalInfo.unclaimedRewards += _calculateRewards(msg.sender, _index);

        HAN.transfer(msg.sender, provider.amount);
        emit Withdrawn(msg.sender, provider.amount);
        _removeProvider(_index);    
    }

    // Function to claim rewards.
    function claimRewards() external nonReentrant whenNotPaused {
        TotalProviderInfo storage totalInfo = totalProvider[msg.sender];
        uint256 reward;

        for(uint i = 0; i < providerArray[msg.sender].length; i++) {
            LiquidityProvider storage provider = providerArray[msg.sender][i];
            uint256 rewardValue = _calculateRewards(msg.sender, i);
            if (rewardValue > 0) {
                reward += rewardValue;
                provider.lastClaimedTime = block.timestamp;
            }
        }
        require(reward + totalInfo.unclaimedRewards > 0, "No rewards to claim");

        HAN.transfer(msg.sender, reward + totalInfo.unclaimedRewards);

        totalInfo.totalRewardReleased += reward + totalInfo.unclaimedRewards;
        totalInfo.unclaimedRewards = 0;

        emit RewardPaid(msg.sender, reward);
    }

    // Function to return to reward amount.
    function rewardView(address _user) public view returns(uint256) {
        uint256 reward = 0;
        for(uint i = 0; i < providerArray[_user].length; i++) {
            uint256 rewardValue = _calculateRewards(_user, i);
            if (rewardValue > 0) {
                reward += rewardValue;
            }
        }
        return reward;
    }

    // Function to return to remaining duration.
    function remainingDuration(address _user ,uint256 _index) public view returns (uint256) {
        LiquidityProvider memory provider = providerArray[_user][_index];
        if(provider.withdrawalTime > block.timestamp) {
            return provider.withdrawalTime - block.timestamp;
        } else {
            return 0;
        }
    }

    // Function to return to provider data.
    function getProviderData(address _user) public view returns(LiquidityProvider[] memory) {
        return providerArray[_user];
    }

    // Function to return to provider list.
    function getProviderList() public view returns(address[] memory) {
        return providerList;
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

    // private function to calculate rewards for a user.
    function _calculateRewards(address _user, uint256 _index) private view returns (uint256) {
        LiquidityProvider memory provider = providerArray[_user][_index];
        uint256 reward;
        uint256 stakedTime = block.timestamp - provider.lastClaimedTime; // Calculate the time elapsed since the last reward claim.
        reward = provider.amount * stakedTime * REWARD_PER_SECOND / WEI_MULTIPLIER; // Calculate the reward based on elapsed time.
        return reward;
    }

    // private function to add a liquidity provider to the array.
    function _addToProviderArray(address _user, uint256 _amount) private {
        LiquidityProvider memory newProvider = LiquidityProvider({
            amount: _amount,
            lastClaimedTime: block.timestamp,
            withdrawalTime: block.timestamp + YEAR
        });
        providerArray[_user].push(newProvider);
    }

    // private function to remove a liquidity provider from the array.
    function _removeProvider(uint256 _index) private {
        require(_index < providerArray[msg.sender].length, "Invalid index");
        providerArray[msg.sender][_index] = providerArray[msg.sender][providerArray[msg.sender].length - 1];
        providerArray[msg.sender].pop();
    }

    // private function to remove an address from an array.
    function _removeAddress(address[] storage _array, address _address) private {
        for (uint256 i = 0; i < _array.length; i++) {
            if (_array[i] == _address) {
                _array[i] = _array[_array.length - 1];
                _array.pop();
                break;
            }
        }
    }

    // ------------------ EVENTS ------------------ //
    event ProviderAdded(address indexed user);
    event RewardUpdated(address indexed user, uint256 amount);
    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);
    event RecoveredERC20(address token, uint256 amount);
    event RecoveredERC721(address token, uint256 tokenId);
    event RecoveredEther(address indexed to, uint256 amount);
}
