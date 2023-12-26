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
    LiquidityReward_4 public constant LIQUIDITY_REWARD = LiquidityReward_4(0x23f2fBF0A4F814d5B45741749e2fb589f061c24A);

    // Structure to store the information of a liquidity Referrer.
    struct Referrer {
        uint256 amount; // Amount of HAN token staked
        uint256 lastClaimedTime; // Last time rewards were claimed.
        uint256 withdrawalTime; // Time when the withdrawal is available
    }
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
    address[] private providerList; // Array to store the information of a liquidity providerList.
    mapping (address => bool) public isProvider; // Mapping to store the information of a liquidity isProvider.
    mapping (address => bool) public isReferrer; // Mapping to store the information of a liquidity isReferrer.
    mapping(address => uint256) public referrerRewardAmount; // Mapping to store the information of a liquidity referrerRewardAmount.

    // Function to add the address of a liquidity referrer.
    function addReferrerList(address[] memory _providers, address[] memory _referrers) public onlyOwner {
        require(_providers.length == _referrers.length, "The lengths of the _providers and _referrers arrays must be equal");
        for (uint i = 0; i < _providers.length; i++) {
            address provider = _providers[i];
            address referrer = _referrers[i];
            for (uint j = 0; j < i; j++) {
                require(_providers[j] != provider, "Duplicate accounts are not allowed");
                require(_referrers[j] != referrer, "Duplicate accounts in _referrers are not allowed");
            }

            if (!isProvider[provider]) {
                isProvider[provider] = true;
                providerList.push(provider);
                ProviderAdded(provider);
            }

            if (!isReferrer[referrer]) {
                isReferrer[referrer] = true;
                referrerList.push(referrer);
                ReferrerAdded(referrer);
            }

            uint256 amount;
            (,,,,,uint256 referrerReward,) = LIQUIDITY_REWARD.totalLiquidityInfo(provider);
            if(referrerReward == 0) {
                revert("don't have any reward");
            }

            amount = LIQUIDITY_REWARD.registrationV1(provider);
            referrerRewardAmount[referrer] += amount;
            emit RewardUpdated(referrer, amount);
        }
    }

    // Function to stake HAN token.
    function stake() public nonReentrant whenNotPaused {
        TotalReferrerInfo storage totalInfo = totalReferrer[msg.sender];
        require(HAN.balanceOf(address(this)) > referrerRewardAmount[msg.sender] * REWARD_PER_SECOND * YEAR / WEI_MULTIPLIER, "Total amount of rewards is too high");
        require(referrerRewardAmount[msg.sender] > 0, "Not a whitelisted user");
        uint256 amount = referrerRewardAmount[msg.sender];

        _addToReferrerArray(msg.sender, amount);

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

    // Function to return to provider list.
    function getProviderList() public view returns(address[] memory) {
        return providerList;
    }

    function _addToReferrerArray(address _user, uint256 _amount) private {
        Referrer memory newReferrer = Referrer({
            amount: _amount,
            lastClaimedTime: block.timestamp,
            withdrawalTime: block.timestamp + YEAR
        });
        referrerArray[_user].push(newReferrer);
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
    function pause() public onlyOwner nonReentrant {
        _pause();
    }
    function unpause() public onlyOwner nonReentrant {
        _unpause();
    }

    // Functions to recover wrong tokens or Ether sent to the contract.
    function recoverERC20(address _tokenAddress, uint256 _tokenAmount) external onlyOwner nonReentrant {
        IERC20(_tokenAddress).transfer(msg.sender, _tokenAmount);
        emit RecoveredERC20(_tokenAddress, _tokenAmount);
    }
    function recoverERC721(address _tokenAddress, uint256 _tokenId) external onlyOwner nonReentrant {
        IERC721(_tokenAddress).safeTransferFrom(address(this),msg.sender,_tokenId);
        emit RecoveredERC721(_tokenAddress, _tokenId);
    }
    function recoverReferrerRewardAmount(address _removeReferrer, uint256 _removeAmount, address _addReferrer, uint256 _addAmount) external onlyOwner nonReentrant {
        if(_removeAmount > referrerRewardAmount[_removeReferrer]) {
            revert("removeAmount is too high");
        }
        referrerRewardAmount[_removeReferrer] -= _removeAmount;
        referrerRewardAmount[_addReferrer] += _addAmount;
        emit RecoveredReferrerRewardAmount(_removeReferrer, _removeAmount, _addReferrer, _addAmount);
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
    event ProviderAdded(address indexed user);
    event ReferrerAdded(address indexed user);
    event RewardUpdated(address indexed user, uint256 amount);
    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);
    event RecoveredERC20(address token, uint256 amount);
    event RecoveredERC721(address token, uint256 tokenId);
    event RecoveredReferrerRewardAmount(address indexed removeUser, uint256 removeAmount, address indexed addUser, uint256 addAmount);
    event RecoveredEther(address indexed to, uint256 amount);
}
