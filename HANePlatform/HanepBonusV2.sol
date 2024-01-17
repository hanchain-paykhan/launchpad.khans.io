// SPDX-License-Identifier: MIT
pragma solidity ^0.7.0;
pragma abicoder v2;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "./LiquidityReward_HANeP_4.sol";

contract HanepBonusV2 is ReentrancyGuard, Ownable, Pausable {
    IERC20 public constant HANeP = IERC20(0xC3248A1bd9D72fa3DA6E6ba701E58CbF818354eB);
    LiquidityReward_HANeP_4 public constant LIQUIDITY_REWARD = LiquidityReward_HANeP_4(0xbF5288E237b6c4Ff01af24d301fF7504Ea12F2F0);

    // Structure to store the information of a liquidity provider.
    struct Staker {
        uint256 amount;
        uint256 startTime;
        uint256 lastClaimedTime;
        uint256 withdrawalTime; 
    }
    mapping(address => Staker[]) private stakerArray;

    // structure to store the total information of a liquidity TotalInfo.
    struct TotalInfo {
        uint256 totalDividendAmount;
        uint256 totalStakedAmount;
        uint256 totalRewardReleased;
        uint256 unclaimedRewards;
    }
    mapping(address => TotalInfo) public totalInfo;

    uint256 public constant YEAR = 31536000; // Time in seconds for one year.
    uint256 public constant REWARD_PER_SECOND = 43189120370; // 1 HANeP token per second
    uint256 private constant WEI_MULTIPLIER = 1e18; // Constant for Ethereum unit conversion.

    uint256 public totalSupply; // Total amount of HANeP token staked
    address[] private referrerList; // Array to store the information of a liquidity referrerList.
    address[] private providerList; // Array to store the information of a liquidity providerList.
    mapping (address => bool) public isProvider; // Mapping to store the information of a liquidity isProvider.
    mapping (address => bool) public isReferrer; // Mapping to store the information of a liquidity isReferrer.
    mapping(address => uint256) public referrerRewardAmount; // Mapping to store the information of a liquidity referrerRewardAmount.
    mapping(address => uint256) public providerRewardAmount; // Mapping to store the information of a liquidity providerRewardAmount.

    // Function to add the address of a liquidity referrer.
    function addReferrerList(address[] memory _providers, address[] memory _referrers) external nonReentrant onlyOwner {
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

            amount = LIQUIDITY_REWARD.registrationReferrer(provider);
            totalInfo[referrer].totalDividendAmount += amount;
            referrerRewardAmount[referrer] += amount;
            emit RewardUpdated(referrer, amount);
        }
    }

    // Function to add the address of a liquidity provider.
    function addProviderlist(address[] memory _accounts, uint256[] memory _amounts) external nonReentrant onlyOwner {
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
            totalInfo[user].totalDividendAmount += _amounts[i];
            providerRewardAmount[user] += _amounts[i];
            RewardUpdated(user, _amounts[i]);
        }
    }

    // Function to stake HANeP token.
    function stakeDividends() public nonReentrant whenNotPaused {
        TotalInfo storage total = totalInfo[msg.sender];
        uint256 amount = total.totalDividendAmount;
        require(HANeP.balanceOf(address(this)) > amount * REWARD_PER_SECOND * 365 days / 10**18, "Total amount of rewards is too high");
        require(amount > 0, "Not a whitelisted user");
        
        _addToStakerArray(msg.sender, amount);
        LIQUIDITY_REWARD.registrationProvider(msg.sender);
        total.totalStakedAmount += amount;
        totalSupply += amount;

        delete total.totalDividendAmount;
        delete providerRewardAmount[msg.sender];
        delete referrerRewardAmount[msg.sender];

        emit Staked(msg.sender, amount);
    }

    // Function to stake HANeP token.
    function stake(uint256 _amount) public nonReentrant whenNotPaused {
        TotalInfo storage total = totalInfo[msg.sender];
        uint256 amount = _amount;
        require(HANeP.balanceOf(address(this)) > amount * REWARD_PER_SECOND * 365 days / 10**18, "Total amount of rewards is too high");
        require(amount > 0, "Not a whitelisted user");

        _addToStakerArray(msg.sender, amount);
        HANeP.transferFrom(msg.sender, address(this), amount);

        total.totalStakedAmount += amount;
        totalSupply += amount;
        emit Staked(msg.sender, amount);
    }

    // Function to withdraw HANeP token.
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

    // Function to claim rewards.
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

    // Function to return to reward amount.
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

    // Function to return to remaining duration.
    function remainingDuration(address _user ,uint _index) public view returns (uint256) {
        Staker storage staker = stakerArray[_user][_index];
        if(staker.withdrawalTime > block.timestamp) {
            return staker.withdrawalTime - block.timestamp;
        } else {
            return 0;
        }
    }

    // Function to return to the total amount of rewards.
    function getStakerArray(address _user) public view returns(Staker[] memory) {
        return stakerArray[_user];
    }

    function getReferrerList() public view returns(address[] memory) {
        return referrerList;
    }

    function getProviderList() public view returns(address[] memory) {
        return providerList;
    }

    // private function to add a liquidity provider to the array.
    function _addToStakerArray(address _user, uint256 _amount) private {
        Staker memory newStaker = Staker({
        amount : _amount,
        startTime : block.timestamp,
        lastClaimedTime: block.timestamp,
        withdrawalTime : block.timestamp + YEAR

        });
        stakerArray[_user].push(newStaker);
    }
    // private function to remove a liquidity provider from the array.
    function _removeStaker(uint256 _index) private {
        require(_index < stakerArray[msg.sender].length, "Invalid index");
        stakerArray[msg.sender][_index] = stakerArray[msg.sender][stakerArray[msg.sender].length - 1];
        stakerArray[msg.sender].pop();
    }

    // private function to calculate rewards for a user.
    function _calculateRewards(address _user, uint256 _index) internal view returns (uint256) {
        Staker memory staker = stakerArray[_user][_index];
        uint256 reward;
        uint256 stakedTime = block.timestamp - staker.lastClaimedTime; // Calculate the time elapsed since the last reward claim.
        reward = staker.amount * stakedTime * REWARD_PER_SECOND / WEI_MULTIPLIER; // Calculate the reward based on elapsed time.
        return reward;
    }

    function pause() external nonReentrant onlyOwner {
        _pause();
    }
    function unpause() external nonReentrant onlyOwner {
        _unpause();
    }
    function recoverERC20(address _tokenAddress, uint256 _tokenAmount) external nonReentrant onlyOwner {
        IERC20(_tokenAddress).transfer(msg.sender, _tokenAmount);
        emit RecoveredERC20(_tokenAddress, _tokenAmount);
    }
    function recoverERC721(address _tokenAddress, uint256 _tokenId) external nonReentrant onlyOwner {
        IERC721(_tokenAddress).safeTransferFrom(address(this),msg.sender,_tokenId);
        emit RecoveredERC721(_tokenAddress, _tokenId);
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
