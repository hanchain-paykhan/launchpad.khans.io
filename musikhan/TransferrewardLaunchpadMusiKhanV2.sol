// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

contract TransferrewardLaunchpadMusiKhanV2 is Ownable, ReentrancyGuard, Pausable {
    IERC721 public constant TRANSFER_TOKEN = IERC721(0x0B49864fDB8d7a432DD58AFBaA17742954c8C3Fc);
    IERC20 public constant REWARD_TOKEN = IERC20(0xC3248A1bd9D72fa3DA6E6ba701E58CbF818354eB);

    struct Transmitter {
        uint256[] tokenIds;
        uint256 totalReward;
        uint256 unclaimedRewards;
        uint256 lastClaimedTime;
    }

    struct TokenInfo {
        uint256 tokenTransferTime;
        uint256 remainingReward;
    }

    uint256 public constant REWARD_PER_SECOND = 1041666666666;
    uint256 public constant ONE_YEAR = 365 days;

    uint256 public totalSupply;
    uint256[] private totalTokenIds;

    mapping(address => Transmitter) public transmitter;
    mapping(uint256 => TokenInfo) public tokenInfo;

    function transferToken(uint256 _tokenId) external nonReentrant whenNotPaused {
        uint256 expectedAnnualReward = ONE_YEAR * (totalSupply * REWARD_PER_SECOND);
        uint256 currentBalance = REWARD_TOKEN.balanceOf(address(this));
        uint256 minimalBalanceRequired = expectedAnnualReward + ONE_YEAR * REWARD_PER_SECOND;
        require(currentBalance >= minimalBalanceRequired, "Insufficient reward token balance");
        require(TRANSFER_TOKEN.ownerOf(_tokenId) == msg.sender, "Only the owner of the token can transfer");

        Transmitter storage sender = transmitter[msg.sender];        
        TokenInfo storage info = tokenInfo[_tokenId];

        sender.unclaimedRewards += _calculateRewards(msg.sender);
        sender.lastClaimedTime = block.timestamp;
        sender.tokenIds.push(_tokenId);
        totalTokenIds.push(_tokenId);

        info.remainingReward = REWARD_PER_SECOND * ONE_YEAR;
        info.tokenTransferTime = block.timestamp;

        totalSupply++;

        TRANSFER_TOKEN.transferFrom(msg.sender, address(this), _tokenId);

        emit Transferred(msg.sender, _tokenId);
    }

    function claimRewards() external nonReentrant whenNotPaused {
        Transmitter storage sender = transmitter[msg.sender];

        uint256 reward = sender.unclaimedRewards + _calculateRewards(msg.sender);

        require(reward > 0, "You have no rewards to claim");
        require(reward < REWARD_TOKEN.balanceOf(address(this)), "Not enough tokens");

        sender.unclaimedRewards = 0;
        sender.lastClaimedTime = block.timestamp;
        sender.totalReward += reward;

        REWARD_TOKEN.transfer(msg.sender, reward);
        
        emit RewardPaid(msg.sender, reward);
    }

    function getTransmitterData(address _user) public view returns (Transmitter memory) {
        return transmitter[_user];
    }

    function getTotalTokenIds() public view returns (uint256[] memory) {
        return totalTokenIds;
    }

    function rewardView(address _user) public view returns (uint256) {
        Transmitter memory sender = transmitter[_user];

        uint256 reward = 0;
        uint256 stakedTime = block.timestamp - sender.lastClaimedTime;
        for (uint i = 0; i < sender.tokenIds.length; i++) {
            uint256 tokenId = sender.tokenIds[i];
            uint256 potentialReward = stakedTime * REWARD_PER_SECOND;
            uint256 remainingReward = tokenInfo[tokenId].remainingReward;

            if (remainingReward <= potentialReward) {
                reward += remainingReward;
            } else {
                reward += potentialReward;
            }
        }
        return reward + sender.unclaimedRewards;
    }

    function _calculateRewards(address _user) internal returns (uint256) {
        Transmitter storage sender = transmitter[_user];

        uint256 reward = 0;
        uint256 stakedTime = block.timestamp - sender.lastClaimedTime;

        if(sender.tokenIds.length == 0) {
            return reward;
        }

        for (uint i = 0; i < sender.tokenIds.length; i++) {
            
            uint256 tokenId = sender.tokenIds[i];
            uint256 potentialReward = stakedTime * REWARD_PER_SECOND;
            uint256 remainingReward = tokenInfo[tokenId].remainingReward;

            if (remainingReward <= potentialReward) {
                reward += remainingReward;
                tokenInfo[tokenId].remainingReward = 0;
            } else {
                reward += potentialReward;
                tokenInfo[tokenId].remainingReward -= potentialReward;
            }
        }
        return reward;
    }

    function pause() external onlyOwner nonReentrant {
        _pause();
    }

    function unpause() external onlyOwner nonReentrant {
        _unpause();
    }

    function recoverERC20(address _tokenAddress, uint256 _tokenAmount) external onlyOwner nonReentrant {
        IERC20(_tokenAddress).transfer(msg.sender, _tokenAmount);
        emit RecoveredERC20(_tokenAddress, _tokenAmount);
    }

    function recoverERC721(address _tokenAddress, uint256 _tokenId) external onlyOwner nonReentrant {
        IERC721(_tokenAddress).safeTransferFrom(address(this), msg.sender, _tokenId);
        emit RecoveredERC721(_tokenAddress, _tokenId);
    }

    function setTransmitter(address _user, uint256 _tokenId, uint256 _totalReward, uint256 _unclaimedRewards, uint256 _lastClaimedTime,  uint256 _tokenTransferTime, uint256 _remainingReward) external onlyOwner nonReentrant {
        Transmitter storage sender = transmitter[_user];
        TokenInfo storage info = tokenInfo[_tokenId];

        sender.totalReward = _totalReward;
        sender.unclaimedRewards = _unclaimedRewards;
        sender.lastClaimedTime = _lastClaimedTime;
        sender.tokenIds.push(_tokenId);

        totalTokenIds.push(_tokenId);

        info.tokenTransferTime = _tokenTransferTime;
        info.remainingReward = _remainingReward;

        totalSupply++;
    }

    event Transferred(address owner, uint256 tokenId);
    event RewardPaid(address indexed user, uint256 reward);
    event RecoveredERC20(address token, uint256 amount);
    event RecoveredERC721(address token, uint256 tokenId);
}