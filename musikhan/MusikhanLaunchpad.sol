// SPDX-License-Identifier: MIT
pragma solidity ^0.8.7;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV2V3Interface.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import "./IMusikhan.sol";
import "./HANePlatform.sol";

/*
    1. Calculate HANeP token price: Using Chainlink Oracles to get the current price of ETH in USD and then calculating HANeP's current price based on the balance of WETH and HANeP in the Uniswap pool.
    2. Musikhan token exchange: Allows users to burn HANeP tokens to receive Musikhan tokens. The price of Musikhan tokens is based on the current price of HANeP tokens.
 */

contract MusikhanLaunchpad is Ownable, Pausable, ReentrancyGuard {
    IERC20 public constant weth = IERC20(0x4200000000000000000000000000000000000006);    // Optimism
    HANePlatform public constant hanep = HANePlatform(0xC3248A1bd9D72fa3DA6E6ba701E58CbF818354eB);    // Optimism
    // HANePlatform public constant hanep = HANePlatform(0xE947Af98dC5c2FCfcc2D2F89325812ba5d332b41); // Optimism Goerli
    
    address public constant ethPriceFeedAddress = 0x13e3Ee699D1909E989722E753853AE30b17e08c5; // ETH/USD Optimism
    // address public constant ethPriceFeedAddress = 0x57241A37733983F97C4Ab06448F244A1E0Ca0ba8; // ETH/USD Optimism Goerli

    address public constant sequencerUptimeFeedAddress = 0x371EAD81c9102C9BF4874A9075FFFf170F2Ee389; // Optimism
    // address public constant sequencerUptimeFeedAddress = 0x4C4814aa04433e0FB31310379a4D6946D5e1D353; // Optimism Goerli
    
    address public constant pairAddress = 0xB0Efaf46a1de55C54f333f93B1F0641e73bC16D0; // WETH/HANeP UnisapV3 Pool Optimism
    uint256 private constant GRACE_PERIOD_TIME = 3600;

    error SequencerDown();
    error GracePeriodNotOver();

    AggregatorV2V3Interface internal ethFeed = AggregatorV2V3Interface(ethPriceFeedAddress);
    AggregatorV2V3Interface internal sequencerUptimeFeed = AggregatorV2V3Interface(sequencerUptimeFeedAddress);

    // Initialize variables: Decimals of ETH and the price of Musikhan token (in USD).
    uint8 public ethDecimals = ethFeed.decimals(); 
    uint8 public decimals = 18;
    uint256 public musikhanUSDPrice = 2100000000 ;  // 21 dollars

    // An array to store the addresses of registered tokens.
    address[] internal registeredTokens;

    mapping(address => uint256) public remainingAmount;

    // This function returns an array that stores the addresses of registered tokens.
    function getRegisteredTokens() public view returns(address[] memory) {
        return registeredTokens;
    }

    // This function calculates and returns the amount of hanep tokens per unit of Musikhan token. 
    // The _amount parameter is the amount of Musikhan tokens used for the calculation.
    // This is a view function, so it only queries data without changing the state.
    function calculateHanepCost(uint256 _amount) public view returns (uint256) {
        // The amount of Musikhan tokens must be a multiple of 100. Otherwise, an error is thrown.
        require(_amount % 100 ether == 0, "The Musikhan amount must be a multiple of 100 units");

        // Retrieve the current price of the hanep token.
        uint256 hanepPrice = getHANePTokenUSDPrice();

        // Calculate the price per unit of Musikhan token.
        uint256 price = musikhanUSDPrice * 10 ** 18 / hanepPrice;

        // Return the final price. This price is in hanep tokens and represents the amount of hanep tokens required to purchase the given amount of Musikhan tokens.
        return price * _amount / 10 ** 18;    
    }

    // This function returns the current price of the hanep token in USD.
    // This is a view function, so it only queries data without changing the state.
    function getHANePTokenUSDPrice() public view returns (uint256) {
        // Using Chainlink Oracles, get the latest status of the sequencer.
        (, int256 answer, uint256 startedAt, ,) = sequencerUptimeFeed.latestRoundData();

        // Check if the sequencer is operating. If not, throw a SequencerDown error.
        bool isSequencerUp = answer == 0;
        if (!isSequencerUp) {
            revert SequencerDown();
        }

        // Calculate the time the sequencer has been running.
        uint256 timeSinceUp = block.timestamp - startedAt;
        // If the sequencer has just started operating (within GRACE_PERIOD_TIME), throw a GracePeriodNotOver error.
        if (timeSinceUp <= GRACE_PERIOD_TIME) {
            revert GracePeriodNotOver();
        }

        // Using Chainlink Oracles, get the current price of ETH in USD.
        (, int ethPrice, , ,) = ethFeed.latestRoundData();

        // Get the current balance of WETH (wrapped ether) from the Uniswap pool.
        uint256 reserve0 = weth.balanceOf(pairAddress);  // Optimism
        require (reserve0 != 0, "weth : Invalid amount");

        // Get the current balance of HANeP tokens from the Uniswap pool.
        uint256 reserve1 = hanep.balanceOf(pairAddress); // Optimism
        require (reserve1 != 0, "hanep : Invalid amount");

        // Calculate the current price of the HANeP token.
        // This price is based on the current ETH price and the balances of the two tokens in the Uniswap pool.
        uint256 price =  uint(ethPrice) * reserve0 / reserve1;
        // Return the calculated price of the HANeP token.
        return price;
    }

    // Function to set the price of the Musikhan token. Can be called only by the owner.
    function setMusikhanUSDPrice(uint256 _price) public onlyOwner {
        musikhanUSDPrice = _price;
        emit PriceSet(_price);
    }

    // This function adds a Musikhan token to the contract and transfers the required amount to this contract.
    // If the token isn't already registered, it's added to the list of registered tokens.
    // Can be called only by the owner.
    function addMusikhanToken(address _token, uint256 _amount) public onlyOwner {
        bool isRegistered = false;

        // Check if the given token address is in the list of registered tokens.
        // If it's already registered, set isRegistered to true.
        for (uint i = 0; i < registeredTokens.length; i++) {
            if (registeredTokens[i] == _token) {
                isRegistered = true;
                break;
            }
        }

        // If the token isn't already registered, add its address to the list of registered tokens.
        if (!isRegistered) {
            registeredTokens.push(_token);
        }

        // Transfer the given amount of tokens from msg.sender to this contract.
        // Use the IMusikhan interface to call the transferFrom function.
        IMusikhan(_token).transferFrom(msg.sender, address(this), _amount);
        remainingAmount[_token] = _amount;

        // Emit an event to log that the token has been successfully added.
        emit TokenAdded(_token, _amount);
    }

    // This function allows users to burn HANeP tokens to receive Musikhan tokens.
    // The _token parameter is the address of the Musikhan token they want to receive, 
    // and the _musikhanAmount parameter is the amount of Musikhan tokens they want.
    function burnHANePToReceiveMusikhan(address _token, uint256 _musikhanAmount) public nonReentrant {
        // First, calculate the amount of HANeP tokens required for the Musikhan tokens the user wants.
        uint256 burnAmount = uint256(calculateHanepCost(_musikhanAmount));

        // Ensure the user has transferred enough HANeP tokens. If not, the transfer fails.
        require(hanep.transferFrom(msg.sender, address(this), burnAmount), "Transfer failed");

    // Burn the calculated amount of HANeP tokens.
        hanep.burn(burnAmount);
    
        // Transfer the requested amount of Musikhan tokens to the user.
        IMusikhan(_token).transfer(msg.sender, _musikhanAmount);

        remainingAmount[_token] -= _musikhanAmount;

        // If there are no remaining Musikhan tokens of that type in the contract, remove the token from the registry.
        if(remainingAmount[_token] == 0) {
            removeTokenFromRegistry(_token);
        }

        // Emit an event to log that the tokens have been successfully burnt and received.
        emit TokensBurntAndReceived(_token, _musikhanAmount, burnAmount);
    }

    // This function is called internally to remove a specific Musikhan token from the registry when it's no longer available.
    function removeTokenFromRegistry(address _token) internal {
        uint256 index;
        bool found = false;

        // Iterate over the list of registered tokens to find the given token address.
        for (uint i = 0; i < registeredTokens.length; i++) {
            if (registeredTokens[i] == _token) {
                index = i;
                found = true;
                break;
            }
        }

        // If the token is found, replace its spot with the last token in the array, then shorten the array.
        // This maintains the array's structure while decreasing its length.
        if (found) {
            registeredTokens[index] = registeredTokens[registeredTokens.length - 1];
            registeredTokens.pop();
        }
    }

    // This function can be called only by the contract's owner. It's used to recover ERC20 tokens in emergencies.
    // This function acts as a safety mechanism to prevent mistakes or abuse.
    function recoverERC20Tokens(address _tokenAddress, uint256 _tokenAmount) external onlyOwner {
        // Transfer the given amount of tokens from this contract to the caller.
        IERC20(_tokenAddress).transfer(msg.sender, _tokenAmount);
        emit RecoveredERC20(_tokenAddress, _tokenAmount);
    }

    // Event to notify that a specific amount of Musikhan tokens have been burnt and a corresponding amount of HANeP tokens have been burnt.
    event TokensBurntAndReceived(address musikhanToken, uint256 musikhanAmount, uint256 hanepBurnAmount);

    // Event to notify that a new Musikhan token has been added to the contract.
    event TokenAdded(address musikhanToken, uint256 amount);

    // Event to notify of the recovered token address and amount in case of emergencies.
    event RecoveredERC20(address token, uint256 amount);

    // Event to notify of the changed price for Musikhan tokens.
    event PriceSet(uint256 amount);
}
