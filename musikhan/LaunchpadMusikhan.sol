// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV2V3Interface.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import "./LaunchpadMusiKhanNFT.sol";
/*
    1. HANeP token price calculation: Using Chainlink oracle to get the current USD price of ETH, and calculate the current price of HANeP based on the balance of WETH and HANeP in the Uniswap pool.  
    2. Musikhan token exchange: Allows users to burn HANeP tokens to receive Musikhan tokens. At this time, the price of the Musikhan token is based on the current price of the HANeP token.
 */

contract LaunchpadMusiKhan is Ownable, Pausable, ReentrancyGuard {

    // Contract constructor. It generates a hash by receiving _code.
    constructor(string memory _code) {
        hashedCode = keccak256(abi.encodePacked(_code));
    }

    LaunchpadMusiKhanNFT public constant MUSIKHAN_NFT = LaunchpadMusiKhanNFT(0xA7333Ec665D8F3f617a4C1e9F299ad05Bda908B7); // Optimism
    // LaunchpadMusiKhanNFT public constant MUSIKHAN_NFT = LaunchpadMusiKhanNFT(0x462B4C6546300b20d62016e44ABf9d8F03A2cEB1); // Optimism Goerli

    IERC20 public constant WETH_TOKEN = IERC20(0x4200000000000000000000000000000000000006);    // Optimism

    IERC20 public constant HANEP_TOKEN = IERC20(0xC3248A1bd9D72fa3DA6E6ba701E58CbF818354eB);    // Optimism
    // IERC20 public constant HANEP_TOKEN = IERC20(0xE947Af98dC5c2FCfcc2D2F89325812ba5d332b41); // Optimism Goerli

    address public constant ETH_PRICE_FEED = 0x13e3Ee699D1909E989722E753853AE30b17e08c5; // ETH/USD Optimism
    // address public constant ETH_PRICE_FEED = 0x57241A37733983F97C4Ab06448F244A1E0Ca0ba8; // ETH/USD Optimism Goerli

    address public constant SEQUENCER_UPTIME_FEED = 0x371EAD81c9102C9BF4874A9075FFFf170F2Ee389; // Optimism
    // address public constant SEQUENCER_UPTIME_FEED = 0x4C4814aa04433e0FB31310379a4D6946D5e1D353; // Optimism Goerli
    
    address public constant PAIR_ADDRESS = 0xB0Efaf46a1de55C54f333f93B1F0641e73bC16D0; // WETH/HANeP UnisapV3 Pool Optimism
    uint256 private constant GRACE_PERIOD_TIME = 3600;

    AggregatorV2V3Interface internal ethFeed = AggregatorV2V3Interface(ETH_PRICE_FEED);
    AggregatorV2V3Interface internal sequencerUptimeFeed = AggregatorV2V3Interface(SEQUENCER_UPTIME_FEED);

    error GracePeriodNotOver();
    error SequencerDown();

    // Declare a mapping to store the URI and token ID of LaunchpadMusiKhan NFT.
    mapping(address => string) public musikhanNftURI;
    mapping(address => uint256) public tokenId;

    // Variable to check the duplication of LaunchpadMusiKhan NFT's tokenURI
    mapping (string => bool) public isTokenURIUsed;

    bytes32 private hashedCode; // Hashed code needed for minting
    uint256 public nftCount; // Variable to store the number of NFTs.

    // Declare the decimal places of USDC and HANeP.
    uint8 public immutable usdcDecimals = ethFeed.decimals();
    uint8 public immutable hanepDecimals = 18;

    // Declare the USD price and quantity of Musikhan tokens.
    uint256 public musikhanUSDPrice = 2100000000 ;  // 21 dollars
    uint256 public musikhanAmount = 100 ether; // 100 Musikhan tokens

    // An array to store the addresses of registered tokens.
    address[] private registeredTokens;

    // This function returns an array that stores the addresses of registered tokens.
    function getRegisteredTokens() public view returns(address[] memory) {
        return registeredTokens;
    }

    // This function calculates and returns the price of hanep tokens per unit of Musikhan token. 
    // The _amount parameter is the amount of Musikhan tokens to be used for calculation. 
    // This function is a view function, it does not change the state and only queries data.
    function calculateHanepCost(uint256 _amount) public view returns (uint256) {
        // The amount of Musikhan tokens must be a multiple of 100. If not, an error occurs.
        require(_amount % musikhanAmount == 0, "The Musikhan amount must be a multiple of 100 units");

        // Get the current price of hanep tokens
        uint256 hanepPrice = getHANePTokenUSDPrice();

        // Calculate the price per unit of Musikhan token.
        uint256 price = musikhanUSDPrice * 10 ** 18 / hanepPrice;

        // Calculate and return the final price. This price is the amount of hanep tokens, 
        // which represents the amount of hanep tokens needed to purchase the given amount of Musikhan tokens.
        return price * _amount / 10 ** 18;    
    }

    // This function returns the current price of the hanep token in USD. 
    // This function is a view function, it does not change the state and only queries data.
    function getHANePTokenUSDPrice() public view returns (uint256) {
        // Use Chainlink Oracles to get the latest status of the sequencer.
        (, int256 answer, uint256 startedAt, ,) = sequencerUptimeFeed.latestRoundData();

        // Check if the sequencer is running. If not, raise a SequencerDown error.
        bool isSequencerUp = answer == 0;
        if (!isSequencerUp) {
            revert SequencerDown();
        }

        // Calculate the running time of the sequencer.
        uint256 timeSinceUp = block.timestamp - startedAt;
        // If the sequencer has recently started running (within GRACE_PERIOD_TIME), 
        // raise a GracePeriodNotOver error.
        if (timeSinceUp <= GRACE_PERIOD_TIME) {
            revert GracePeriodNotOver();
        }

        // Use Chainlink Oracles to get the current price of ETH in USD.
        (, int ethPrice, , ,) = ethFeed.latestRoundData();

        // Get the current balance of WETH (wrapped ether) in the Uniswap pool.
        uint256 reserve0 = WETH_TOKEN.balanceOf(PAIR_ADDRESS);  // Optimism
        require (reserve0 != 0, "WETH_TOKEN : Invalid amount");

        // Get the current balance of HANeP tokens in the Uniswap pool.
        uint256 reserve1 = HANEP_TOKEN.balanceOf(PAIR_ADDRESS); // Optimism
        require (reserve1 != 0, "HANEP_TOKEN : Invalid amount");

        // Calculate the current price of HANeP tokens. 
        // This price is based on the current ETH price and the balance of the two tokens in the Uniswap pool.
        uint256 price =  uint(ethPrice) * reserve0 / reserve1;
        // Return the calculated price of HANeP tokens.
        return price;
    }

    // Function to set the price of Musikhan tokens. Only the owner can call it.
    function setMusikhanUSDPrice(uint256 _price) public onlyOwner {
        musikhanUSDPrice = _price;
        emit PriceSet(_price);
    }

    // Function to set the quantity of Musikhan Tokens that can be registered. Only the owner can call it.
    function setMusikhanAmount(uint256 _amount) public onlyOwner {
        musikhanAmount = _amount;
        emit AmountSet(_amount);
    }

    // Function to add Musikhan tokens to the contract and transfer the required amount to this contract. 
    // This function also adds the token to the registration token list if it is not yet registered.
    // This function can only be called by the owner.
    function addMusikhanToken(address _token, uint256 _tokenId, string memory _tokenURI) public onlyOwner {
        // If already registered, terminate the function and raise an error.
        require(bytes(musikhanNftURI[_token]).length == 0, "TokenUri already registered");
        require(_tokenId == nftCount + 1, "The tokenId must be one greater than the last minted token id");
        require(!isTokenURIUsed[_tokenURI], "This is an already registered token URI.");

        // If the token is not registered, add the address to the registered token array.
        registeredTokens.push(_token);

        // Transfer the given amount of tokens from msg.sender to this contract.
        // At this time, use the IMusikhan interface to call the transferFrom function.
        IERC20(_token).transferFrom(msg.sender, address(this), musikhanAmount);

        // Save information in the Musikhan Token duplicate check and token id mapping
        musikhanNftURI[_token] = _tokenURI;
        tokenId[_token] = _tokenId;
        isTokenURIUsed[_tokenURI] = true;

        nftCount = MUSIKHAN_NFT.addTotalSupply(hashedCode);

        // Log that the token has been successfully added.
        emit TokenAdded(_token, _tokenId, _tokenURI);
    }

    // This function is used for users to burn HANeP tokens to receive Musikhan tokens.
    // The _token parameter is the address of the Musikhan token you want to receive, 
    // and the _musikhanAmount parameter is the amount of Musikhan tokens you want to receive.
    function burnHANePToReceiveMusikhan(address _token) public nonReentrant {
        // First, calculate the amount of HANeP tokens corresponding to the amount of Musikhan tokens the user wants to receive.
        uint256 burnAmount = uint256(calculateHanepCost(musikhanAmount));

        // Check if the user has transferred enough HANeP tokens. If not, the transfer fails.
        require(HANEP_TOKEN.transferFrom(msg.sender, address(this), burnAmount), "HANEP_TOKEN : Transfer failed");
        
        // Transfer the requested amount of Musikhan tokens to the user.
        IERC20(_token).transfer(msg.sender, musikhanAmount);

        // Issue the NFT of the Musikhan token.
        MUSIKHAN_NFT.mint(msg.sender, tokenId[_token], hashedCode, musikhanNftURI[_token]);

        // Remove the token from the registration list.
        _removeTokenFromRegistry(_token);
        delete musikhanNftURI[_token];

        // Log that the token burn and transfer was successful.
        emit TokensBurntAndReceived(_token, musikhanAmount, burnAmount);
    }

    // This function is called internally when a specific Musikhan token is no longer available to remove it from the registration list.
    // This function can only be called within the removeTokenFromRegistry function and cannot be called from outside.
    function _removeTokenFromRegistry(address _token) internal {
        uint256 index;
        bool found = false;

        // Iterate through the list of registered tokens to find the token with the given address.
        for (uint i = 0; i < registeredTokens.length; i++) {
            if (registeredTokens[i] == _token) {
                index = i;
                found = true;
                break;
            }
        }

        // If the token is found, put the last token in the found token's position and shorten the length of the array.
        // This way, you can maintain the structure of the array while reducing the length of the array.
        if (found) {
            registeredTokens[index] = registeredTokens[registeredTokens.length - 1];
            registeredTokens.pop();
        }
    }

    // This function can only be called by the owner of the contract and is used to recover ERC20 tokens tied to the contract.
    // This feature is a safety measure for use in emergencies to prevent errors or abuse.
    function recoverERC20Tokens(address _tokenAddress, uint256 _tokenAmount) external onlyOwner {
        // Transfer the given amount of tokens from the given address token to the caller of the contract.
        IERC20(_tokenAddress).transfer(msg.sender, _tokenAmount);
        emit RecoveredERC20(_tokenAddress, _tokenAmount);
    }

    // Event: Notify that a specific Musikhan token has been burned and as a result, a certain amount of HANeP tokens have been burned.
    event TokensBurntAndReceived(address musikhanToken, uint256 musikhanAmount, uint256 hanepBurnAmount);

    // Event: Notify that a new Musikhan token has been added to the contract.
    event TokenAdded(address musikhanToken, uint256 tokenId, string tokenURI);

    // Event: Notify the token address and amount recovered due to an emergency.
    event RecoveredERC20(address token, uint256 amount);

    // Event: Notify the changed price of the Musikhan token.
    event PriceSet(uint256 price);

    // Event: Notifies the updated quantity of Musikhan tokens
    event AmountSet(uint256 amount);
}
