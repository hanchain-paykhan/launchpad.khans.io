// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV2V3Interface.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./LaunchpadMusiKhanNftV2.sol";

contract LaunchpadMusiKhanV2 is Ownable, Pausable, ReentrancyGuard {

    LaunchpadMusiKhanNftV2 public constant MUSIKHAN_NFT_V2 = LaunchpadMusiKhanNftV2(0x0B49864fDB8d7a432DD58AFBaA17742954c8C3Fc);
    IERC20 public constant WETH_TOKEN = IERC20(0x4200000000000000000000000000000000000006);
    IERC20 public constant HANEP_TOKEN = IERC20(0xC3248A1bd9D72fa3DA6E6ba701E58CbF818354eB);
    address public constant ETH_PRICE_FEED = 0x13e3Ee699D1909E989722E753853AE30b17e08c5;
    address public constant SEQUENCER_UPTIME_FEED = 0x371EAD81c9102C9BF4874A9075FFFf170F2Ee389;
    address public constant PAIR_ADDRESS = 0xB0Efaf46a1de55C54f333f93B1F0641e73bC16D0;
    uint256 private constant GRACE_PERIOD_TIME = 3600;

    AggregatorV2V3Interface internal ethFeed = AggregatorV2V3Interface(ETH_PRICE_FEED);
    AggregatorV2V3Interface internal sequencerUptimeFeed = AggregatorV2V3Interface(SEQUENCER_UPTIME_FEED);

    error GracePeriodNotOver();
    error SequencerDown();

    mapping(address => string) public musikhanNftURI;
    mapping(address => uint256) public tokenId;
    mapping (string => bool) public isTokenURIUsed;

    uint8 public immutable usdcDecimals = ethFeed.decimals();
    uint8 public immutable hanepDecimals = 18;
    uint256 public musikhanUSDPrice = 2100000000;
    uint256 public musikhanAmount = 100 ether;

    address[] private registeredTokens;

    function getRegisteredTokens() public view returns(address[] memory) {
        return registeredTokens;
    }

    function calculateHanepPrice(uint256 _amount) public view returns (uint256) {
        require(_amount % musikhanAmount == 0, "The Musikhan amount must be a multiple of 100 units");

        uint256 hanepPrice = getHANePTokenUSDPrice();
        uint256 price = musikhanUSDPrice * 10 ** 18 / hanepPrice;

        return price * _amount / 10 ** 18;    
    }

    function getHANePTokenUSDPrice() public view returns (uint256) {
        (, int256 answer, uint256 startedAt, ,) = sequencerUptimeFeed.latestRoundData();

        bool isSequencerUp = answer == 0;
        if (!isSequencerUp) {
            revert SequencerDown();
        }

        uint256 timeSinceUp = block.timestamp - startedAt;
        if (timeSinceUp <= GRACE_PERIOD_TIME) {
            revert GracePeriodNotOver();
        }


        (, int ethPrice, , ,) = ethFeed.latestRoundData();

        uint256 reserve0 = WETH_TOKEN.balanceOf(PAIR_ADDRESS);
        require (reserve0 != 0, "WETH_TOKEN : Invalid amount");

        uint256 reserve1 = HANEP_TOKEN.balanceOf(PAIR_ADDRESS);
        require (reserve1 != 0, "HANEP_TOKEN : Invalid amount");

        uint256 price =  uint(ethPrice) * reserve0 / reserve1;

        return price;
    }

    function setMusikhanUSDPrice(uint256 _price) external onlyOwner nonReentrant whenNotPaused {
        musikhanUSDPrice = _price;
        emit PriceSet(_price);
    }

    function setMusikhanAmount(uint256 _amount) external onlyOwner nonReentrant whenNotPaused {
        musikhanAmount = _amount;
        emit AmountSet(_amount);
    }

    function addMusikhanToken(address _token, uint256 _tokenId, string memory _tokenURI) external onlyOwner nonReentrant whenNotPaused{
        require(bytes(musikhanNftURI[_token]).length == 0, "TokenUri already registered");
        require(_tokenId == MUSIKHAN_NFT_V2.totalSupply() + 1, "The tokenId must be one greater than the last minted token id");
        require(!isTokenURIUsed[_tokenURI], "This is an already registered token URI.");

        registeredTokens.push(_token);

        IERC20(_token).transferFrom(msg.sender, address(this), musikhanAmount);

        musikhanNftURI[_token] = _tokenURI;
        tokenId[_token] = _tokenId;
        isTokenURIUsed[_tokenURI] = true;

        MUSIKHAN_NFT_V2.addTotalSupply();

        emit TokenAdded(_token, _tokenId, _tokenURI);
    }

    function burnHANePToReceiveMusikhan(address _token) external nonReentrant whenNotPaused {
        uint256 burnAmount = uint256(calculateHanepPrice(musikhanAmount));
        require(HANEP_TOKEN.transferFrom(msg.sender, address(this), burnAmount), "HANEP_TOKEN : Transfer failed");

        IERC20(_token).transfer(msg.sender, musikhanAmount);
        MUSIKHAN_NFT_V2.mint(msg.sender, tokenId[_token], _token, musikhanNftURI[_token]);

        _removeTokenFromRegistry(_token);
        delete musikhanNftURI[_token];

        emit TokensBurntAndReceived(_token, musikhanAmount, burnAmount);
    }

    function _removeTokenFromRegistry(address _token) internal {
        uint256 index;
        bool found = false;

        for (uint i = 0; i < registeredTokens.length; i++) {
            if (registeredTokens[i] == _token) {
                index = i;
                found = true;
                break;
            }
        }

        if (found) {
            registeredTokens[index] = registeredTokens[registeredTokens.length - 1];
            registeredTokens.pop();
        }
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

    event TokensBurntAndReceived(address musikhanToken, uint256 musikhanAmount, uint256 hanepBurnAmount);
    event TokenAdded(address musikhanToken, uint256 tokecnId, string tokenURI);
    event RecoveredERC20(address token, uint256 amount);
    event RecoveredERC721(address token, uint256 tokenId);
    event PriceSet(uint256 price);
    event AmountSet(uint256 amount);
}