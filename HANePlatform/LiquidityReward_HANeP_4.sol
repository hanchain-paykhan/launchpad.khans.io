// SPDX-License-Identifier: MIT
pragma solidity ^0.7.0;
pragma abicoder v2;

import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-periphery/contracts/libraries/OracleLibrary.sol";
import '@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol';
import '@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol';
import '@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol';
import "@chainlink/contracts/src/v0.7/interfaces/AggregatorV2V3Interface.sol";
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "./LiquidityReward_2.sol";

// This code implements a system where liquidity providers can provide Ether, which is converted into WETH and WBTC, and then supplied as liquidity to the Uniswap V3 pool. Rewards are paid in HANeP tokens, and liquidity providers can remove their liquidity and claim rewards at any time.

contract LiquidityReward_HANeP_4 is Ownable, ReentrancyGuard, Pausable {
    AggregatorV2V3Interface public constant PRICE_FEED = AggregatorV2V3Interface(0x13e3Ee699D1909E989722E753853AE30b17e08c5); // Address of the Chainlink oracle for Ethereum price feed.
    LiquidityReward_2 public constant LIQUIDITY_REWARD = LiquidityReward_2(0x5B7bF2B2Bb08d90D9a651e1C3Db2B94c3d9067EE); // Address of the LiquidityReward contract.

    // Addresses related to Uniswap V3.
    INonfungiblePositionManager public constant POSITION_MANAGER = INonfungiblePositionManager(0xC36442b4a4522E871399CD717aBDD847Ab11FE88);
    IUniswapV3Factory public constant FACTORY = IUniswapV3Factory(0x1F98431c8aD98523631AE4a59f267346ea31F984);
    ISwapRouter public constant SWAP_ROUTER = ISwapRouter(0xE592427A0AEce92De3Edee1F18E0157C05861564);
    IUniswapV3Pool public constant WBTC_POOL = IUniswapV3Pool(0xcA1b837C87c6563910c2BEFA48834fA2a8c3D72D);

    // Addresses of WETH, WBTC, and HANeP tokens.
    IWETH public constant WETH = IWETH(0x4200000000000000000000000000000000000006);
    IERC20 public constant WBTC = IERC20(0x68f180fcCe6836688e9084f035309E29Bf0A2095);
    IERC20 public constant HANeP = IERC20(0xC3248A1bd9D72fa3DA6E6ba701E58CbF818354eB);

    uint256 public constant REWARD_PER_SECOND = 198927221461187000; // Defines the reward per second.
    uint256 public constant YEAR = 31536000; // Time in seconds for one year.
    uint256 public constant PRICE = 1000000000000; // 기본 가격 설정입니다. usd(decimal 8)
    uint256 private constant WBTC_MULTIPLIER = 1e8; // Constant for WBTC unit conversion.
    uint256 private constant WEI_MULTIPLIER = 1e18; // Constant for Ethereum unit conversion.

    // Constants for Uniswap pool configuration.
    uint24 public constant FEE = 10000;
    uint256 public SLIPPAGE = 25; // 2.5%
    int24 public immutable TICK_LOWER = -887200;
    int24 public immutable TICK_UPPER = 887200;
    
    // Variables related to liquidity.
    uint256 public percent = 10;
    uint256 public suppliedWBTC;
    uint256 public suppliedHANeP;
    uint256 public purchaseHANeP;
    uint256 public totalUnderlyingLiquidity;
    address public authorizedAddress;

    // Variables related to musikhan token.
    uint256 public totalMusikhanTransferred;
    address[] private musikhanList;
    address[] private transferredUserList;
    mapping(address => uint256) public musikhanAmount;
    mapping(address => mapping(address => uint256)) public userMusikhanBalance;
    mapping(address => mapping(address => uint256)) public transferredAmountsByUser;

    // Structure to store information about liquidity providers.
    struct LiquidityProvider {
        uint256 liquidity; // Amount of provided liquidity.
        uint256 tokenId; // Token ID of the provided liquidity.
        uint256 wbtcAmount; // Amount of WBTC tokens provided.
        uint256 hanepAmount; // Amount of HANeP tokens provided.
        uint256 lastClaimedTime; // Last time rewards were claimed.
        uint256 lockupPeriod; // Time when liquidity can be removed.
    }
    mapping (address => LiquidityProvider[]) public providerArray; // Mapping to store information about liquidity providers.

    struct TotalLiquidityInfo {
        uint256 totalLiquidity; // Total liquidity supplied
        uint256 totalWbtcAmount; // Total WBTC token amount supplied
        uint256 totalHanepAmount; // Total HANeP token amount supplied
        uint256 totalRewardReleased; // Total reward released to the provider
        uint256 unclaimedRewards; // Unclaimed rewards of the provider
        uint256 referrerReward; // Referrer reward of the provider
        uint256 liquidityReward; // Provider reward of the provider
    }
    mapping (address => TotalLiquidityInfo) public totalLiquidityInfo; // Mapping to store the total information of a liquidity provider.

    // Function to convert Ether to WETH, swap some for WBTC, and add liquidity to the Uniswap V3 pool.
    function addLiquidity(uint256 _usdPrice) external payable nonReentrant {
        TotalLiquidityInfo storage totalInfo = totalLiquidityInfo[msg.sender];
        (,,,,,,,,bool hasAddedLiquidity) = LIQUIDITY_REWARD.providers(msg.sender);
        require(hasAddedLiquidity, "Liquidity was not supplied to hanchain pool.");
        require(_usdPrice % PRICE == 0, "USD price must be a multiple of the base price unit");
        
        WETH.deposit{value: msg.value}(); // Convert Ether to WETH.
        
        uint256 providedEthAmount = msg.value;
        uint256 currentEthAmount = getEthAmount(PRICE);

        require(providedEthAmount >= currentEthAmount, "Provided amount is less than the required minimum");

        uint256 amount = _verifyPriceAndSlippage(providedEthAmount, _usdPrice); // Calculate the amount of Ether to be swapped for WBTC.
        uint256 amountToSwap = amount * 58 / 100; // 58% of the provided amount is swapped for HANeP.

        uint256 wbtcTokenAmount = _swapWETHForWBTC(amount); // Swap WETH for WBTC.
        uint256 hanepTokenAmount = getEquivalentHANePForWBTC(wbtcTokenAmount); // Calculate the equivalent amount of HANeP tokens for the swapped WBTC.

        purchaseHANeP += _swapWETHForHANeP(amountToSwap); // Swap WETH for HANeP.

        _safeApprove(WBTC, address(POSITION_MANAGER), wbtcTokenAmount); // Approve WBTC tokens.
        _safeApprove(HANeP, address(POSITION_MANAGER), hanepTokenAmount); // Approve HANeP tokens.

        (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) = _addLiquidityToUniswap(wbtcTokenAmount, hanepTokenAmount);

        // Update the contract's supplied HANeP and WBTC amounts and total liquidity.
        suppliedWBTC += amount0;
        suppliedHANeP += amount1;
        totalUnderlyingLiquidity += liquidity;

        // Update the liquidity provider's total information.
        totalInfo.totalLiquidity += liquidity; // Add the liquidity to the liquidity provider's total liquidity.
        totalInfo.totalWbtcAmount += amount0; // Add the HANeP amount to the liquidity provider's total WBTC amount.
        totalInfo.totalHanepAmount += amount1; // Add the WBTC amount to the liquidity provider's total HANeP amount.
        totalInfo.referrerReward += amount1 * 2 / percent; // Add the referrer reward to the liquidity provider's referrer reward.
        totalInfo.liquidityReward += amount1; // Add the provider reward to the liquidity provider's provider reward.
        _addToProviderArray(msg.sender, tokenId, liquidity, amount0, amount1);

        // Check if the user address already exists in the transferredUserList
        bool isUserAlreadyAdded = false;
        for (uint256 i = 0; i < transferredUserList.length; i++) {
            if (transferredUserList[i] == msg.sender) {
                isUserAlreadyAdded = true;
                break;
            }
        }
        if (!isUserAlreadyAdded) {
            transferredUserList.push(msg.sender);
        }

        _distributeMusikhan(_usdPrice);

        emit LiquidityAdded(msg.sender, tokenId, amount0, amount1, liquidity);
    }

    // Function to remove liquidity and retrieve tokens.
    function removeLiquidity(uint256 _index) external nonReentrant {
        LiquidityProvider memory provider = providerArray[msg.sender][_index];
        TotalLiquidityInfo storage totalInfo = totalLiquidityInfo[msg.sender];
        require(provider.lockupPeriod < block.timestamp, "Lockup period is not over yet"); // Check if the lockup period has passed.

        // Remove liquidity and retrieve tokens.
        INonfungiblePositionManager.DecreaseLiquidityParams memory params = INonfungiblePositionManager.DecreaseLiquidityParams({
            tokenId: provider.tokenId,
            liquidity: uint128(provider.liquidity),
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp
        });
        POSITION_MANAGER.decreaseLiquidity(params);

        INonfungiblePositionManager.CollectParams memory collectParams = INonfungiblePositionManager.CollectParams({
            tokenId: provider.tokenId,
            recipient: msg.sender,
            amount0Max: type(uint128).max, 
            amount1Max: type(uint128).max 
        });
        POSITION_MANAGER.collect(collectParams);

        // Deduct the contract's supplied HANeP and WBTC amounts and total liquidity.
        suppliedWBTC -= provider.wbtcAmount;
        suppliedHANeP -= provider.hanepAmount;
        totalUnderlyingLiquidity -= provider.liquidity;

        // Update the liquidity provider's total information.
        totalInfo.totalLiquidity -= provider.liquidity; // Deduct the liquidity from the liquidity provider's total liquidity.
        totalInfo.totalWbtcAmount -= provider.wbtcAmount; // Deduct the WBTC amount from the liquidity provider's total WBTC amount.
        totalInfo.totalHanepAmount -= provider.hanepAmount; // Deduct the HANeP amount from the liquidity provider's total HANeP amount.
        totalInfo.unclaimedRewards += _calculateRewards(msg.sender, _index); // Calculate and add rewards to unclaimed rewards.

        emit LiquidityRemoved(msg.sender, provider.tokenId, provider.liquidity);

        _removeElement(_index); // Remove the liquidity provider's information from the array.
    }

    // Function for liquidity providers to claim accumulated rewards.
    function claimRewards() external nonReentrant {
        TotalLiquidityInfo storage totalInfo = totalLiquidityInfo[msg.sender];
        uint256 reward = 0;

        for(uint i = 0; i < providerArray[msg.sender].length; i++) {
            LiquidityProvider storage provider = providerArray[msg.sender][i];
            uint256 rewardValue = _calculateRewards(msg.sender, i); // Calculate the reward for the liquidity provider.
            if (rewardValue > 0) {
                reward += rewardValue;
                provider.lastClaimedTime = block.timestamp;
            }
        }
        require(reward + totalInfo.unclaimedRewards > 0, "No rewards to claim"); // Check if there are rewards to claim.

        HANeP.transfer(msg.sender, reward + totalInfo.unclaimedRewards); // Transfer the calculated rewards.

        totalInfo.totalRewardReleased += reward + totalInfo.unclaimedRewards; // Update the total amount of rewards released.
        totalInfo.unclaimedRewards = 0; // Reset the unclaimed rewards.

        emit RewardsClaimed(msg.sender, reward);
    }

    // Function to add a musikhan token list.
    function addMusikhans(address[] calldata _musikhans, uint256[] calldata _musikhanAmounts) external onlyOwner nonReentrant {
        require(_musikhans.length == _musikhanAmounts.length, "Arrays must be of the same length");
        // Check for duplicate addresses
        for (uint256 i = 0; i < _musikhans.length; i++) {
            for (uint256 j = i + 1; j < _musikhans.length; j++) {
                require(_musikhans[i] != _musikhans[j], "Duplicate addresses not allowed");
            }
        }
        // Add the addresses to the musikhanList if they don't already exist
        for (uint256 i = 0; i < _musikhans.length; i++) {
            address musikhan = _musikhans[i];
            uint256 amount = _musikhanAmounts[i];

            // check if the address already exists in the musikhanList
            bool isAddressExists = false;
            for (uint256 j = 0; j < musikhanList.length; j++) {
                if (musikhan == musikhanList[j]) {
                    isAddressExists = true;
                    break;
                }
            }

            if (!isAddressExists) {
                musikhanList.push(musikhan);
            }

            // Update the musikhanAmount mapping
            musikhanAmount[musikhan] += amount;
            IERC20(musikhan).transferFrom(msg.sender, address(this), amount);
            emit MusikhanAdded(musikhan, amount);
        }
    }

    // Function set the persent.
    function setPersent(uint256 _percent) external onlyOwner nonReentrant {
        percent = _percent;
        emit SetPersent(_percent);
    }   

    // Function to set the v1 authorized address.
    function setAuthorizedAddress(address _authorizedAddress) external onlyOwner nonReentrant {
        authorizedAddress = _authorizedAddress;
        emit AuthorizedAddressSet(_authorizedAddress);
    }

    // Function to add a referrer list.
    function registrationReferrer(address _user) external nonReentrant returns (uint256) {
        require(msg.sender == authorizedAddress, "Not authorized");
        TotalLiquidityInfo storage totalInfo = totalLiquidityInfo[_user];
        uint256 reward = 0;
        reward += totalInfo.referrerReward; // Store the referrer reward.
        require(reward > 0, "No referrer reward"); // Check if the liquidity provider has a referrer reward.
        totalInfo.referrerReward = 0; // Reset the referrer reward.
        emit ReferrerRegistered(_user, reward);
        return reward;
    }

    // Function to add a provider list.
    function registrationProvider(address _user) external nonReentrant returns (uint256) {
        require(msg.sender == authorizedAddress, "Not authorized");
        TotalLiquidityInfo storage totalInfo = totalLiquidityInfo[_user];
        uint256 reward = 0;
        reward += totalInfo.liquidityReward; // Store the provider reward.
        totalInfo.liquidityReward = 0; // Reset the provider reward.
        emit ProviderRegistered(_user, reward);
        return reward;
    }

    // Function to view the reward amount for a specific user.
    function rewardView(address _user) public view returns (uint256) {
        uint256 reward;
        for(uint i = 0; i < providerArray[_user].length; i++) {
            uint256 rewardValue = _calculateRewards(_user, i); // Calculate the reward for the liquidity provider.
            if (rewardValue > 0) {
                reward += rewardValue;
            }
        }
        if(reward == 0) {
            return 0;
        }
        return reward;
    }

    // Function to convert Ethereum price to USD. (decimal 18)
    function getUSDPrice(uint256 _ethAmount) public view returns (uint256) {
        (, int ethPrice, , ,) = PRICE_FEED.latestRoundData();

        uint256 ethPriceInUSD = uint256(ethPrice);
        uint256 usdPrice = _ethAmount * ethPriceInUSD / WEI_MULTIPLIER;

        return usdPrice;
    }

    // Function to convert USD price to Ethereum. (decimal 8)
    function getEthAmount(uint256 _usdPrice) public view returns (uint256) {
        (, int ethPrice, , ,) = PRICE_FEED.latestRoundData();

        uint256 ethPriceInUSD = uint256(ethPrice);
        uint256 ethAmount = _usdPrice * WEI_MULTIPLIER / ethPriceInUSD;

        return ethAmount;
    }

    // Function to view the remaining time for liquidity removal.
    function remainingDuration(address _user, uint256 _index) public view returns (uint256) {
        LiquidityProvider memory provider = providerArray[_user][_index];
        if(provider.lockupPeriod > block.timestamp) { 
            return provider.lockupPeriod - block.timestamp;
        } else {
            return 0;
        }
    }

    // Function to calculate the equivalent amount of HANeP tokens for a given amount of WBTC.
    function getEquivalentHANePForWBTC(uint _wbtcAmount) public view returns (uint) {
        (, int24 tick, , , , , ) = WBTC_POOL.slot0();

        uint btcPrice = OracleLibrary.getQuoteAtTick(
            tick,
            uint128(_wbtcAmount),
            WBTC_POOL.token0(),
            WBTC_POOL.token1()
        );
        return btcPrice;
    }

    // Function to view the information of a liquidity provider Array.
    function getProviders(address _user) public view returns(LiquidityProvider[] memory) {
        return providerArray[_user];
    }

    // Function to view the information of musikhan token.
    function getMusikhanBalances() public view returns (address[] memory, uint256[] memory) {
        uint256 length = musikhanList.length;
        address[] memory addresses = new address[](length);
        uint256[] memory balances = new uint256[](length);

        for (uint256 i = 0; i < length; i++) {
            addresses[i] = musikhanList[i];
            balances[i] = musikhanAmount[musikhanList[i]];
        }

        return (addresses, balances);
    }

    // Function to view musikhan token list.
    function getMusikhanList() public view returns (address[] memory) {
        return musikhanList;
    }

    // Function to view the total amount of musikhan token.
    function getTotalMusikhanAmount() public view returns (uint256) {
        uint256 totalAmount = 0;
        for (uint256 i = 0; i < musikhanList.length; i++) {
            totalAmount += musikhanAmount[musikhanList[i]];
        }
        return totalAmount;
    }

    // Function to view the total amount of musikhan token transferred.
    function getTokenTransfersToUsers(address _tokenAddress) external view returns (address[] memory, uint256[] memory) {
        uint256 length = transferredUserList.length;
        uint256 count = 0;

        for (uint256 i = 0; i < length; i++) {
            if (transferredAmountsByUser[_tokenAddress][transferredUserList[i]] > 0) {
                count++;
            }
        }

        address[] memory users = new address[](count);
        uint256[] memory amounts = new uint256[](count);
        uint256 index = 0;

        for (uint256 i = 0; i < length; i++) {
            if (transferredAmountsByUser[_tokenAddress][transferredUserList[i]] > 0) {
                users[index] = transferredUserList[i];
                amounts[index] = transferredAmountsByUser[_tokenAddress][transferredUserList[i]];
                index++;
            }
        }

        return (users, amounts);
    }

    // Internal function to calculate rewards for a user.
    function _calculateRewards(address _user, uint256 _index) internal view returns (uint256) {
        LiquidityProvider memory provider = providerArray[_user][_index];
        uint256 reward;
        uint256 stakedTime = block.timestamp - provider.lastClaimedTime; // Calculate the time elapsed since the last reward claim.
        reward = provider.liquidity * stakedTime * REWARD_PER_SECOND / WEI_MULTIPLIER; // Calculate the reward based on elapsed time.
        return reward;
    }

    // Internal function to swap WETH for WBTC.
    function _swapWETHForWBTC(uint256 _wethAmount) internal returns (uint256) {
        
        uint256 wbtcBalanceBefore = WBTC.balanceOf(address(this)); // Check WBTC balance before the swap.

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: address(WETH),
            tokenOut: address(WBTC),
            fee: FEE,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: _wethAmount,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });
        
        IERC20(address(WETH)).approve(address(SWAP_ROUTER), _wethAmount);
        SWAP_ROUTER.exactInputSingle(params);

        uint256 wbtcBalanceAfter = WBTC.balanceOf(address(this)); // Check WBTC balance after the swap.

        uint256 wbtcReceived = wbtcBalanceAfter - wbtcBalanceBefore; // Store the amount of WBTC received from the swap.
        emit SwapWETHForWBTC(msg.sender, _wethAmount, wbtcReceived);
        return wbtcReceived;
    }

    function _swapWETHForHANeP(uint256 _wethAmount) internal returns (uint256) {

        uint256 hanepBalanceBefore = HANeP.balanceOf(address(this));

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: address(WETH),
            tokenOut: address(HANeP),
            fee: FEE,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: _wethAmount,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });

        IERC20(address(WETH)).approve(address(SWAP_ROUTER), _wethAmount);
        SWAP_ROUTER.exactInputSingle(params);

        uint256 hanepBalanceAfter = HANeP.balanceOf(address(this));

        uint256 hanepReceived = hanepBalanceAfter - hanepBalanceBefore;
        emit SwapWETHForHANeP(msg.sender, _wethAmount, hanepReceived);
        return hanepReceived;
    }

    function _distributeMusikhan(uint256 _usdPrice) internal {
        uint256 etherValue = _usdPrice / WBTC_MULTIPLIER;
        uint256 musikhan = etherValue * WEI_MULTIPLIER / 100;
        uint256 totalBalance = 0;
        uint256[] memory amounts = new uint256[](musikhanList.length);

        totalMusikhanTransferred += musikhan;

        for (uint256 i = 0; i < musikhanList.length; i++) {
            uint256 balance = musikhanAmount[musikhanList[i]];
            totalBalance += balance;

            if (totalBalance >= musikhan) {
                amounts[i] = musikhan - (totalBalance - balance);
                break;
            } else {
                amounts[i] = balance;
            }
        }

        require(totalBalance >= musikhan, "Insufficient total balance");

        for (uint256 i = 0; i < musikhanList.length; i++) {
            if (amounts[i] > 0) {
                IERC20(musikhanList[i]).transfer(msg.sender, amounts[i]);
                musikhanAmount[musikhanList[i]] -= amounts[i];
                transferredAmountsByUser[musikhanList[i]][msg.sender] += amounts[i];
                userMusikhanBalance[msg.sender][musikhanList[i]] += amounts[i];
            }
        }
    }

    function _verifyPriceAndSlippage(uint256 _providedEthAmount, uint256 _usdPrice) internal view returns (uint256) {
        uint256 amount = _providedEthAmount / 2;
        uint256 calculatedPrice = getUSDPrice(amount * 2);
        uint256 slippageTolerance = calculatedPrice * SLIPPAGE / 1000;

        uint256 lowerBound = calculatedPrice - slippageTolerance;
        uint256 upperBound = calculatedPrice + slippageTolerance;
        
        require(_usdPrice >= lowerBound && _usdPrice <= upperBound, "USD price must be within the slippage tolerance of the calculated amount");

        return amount;
    }

    function _addLiquidityToUniswap(uint256 _wbtcTokenAmount, uint256 _hanepTokenAmount) private returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) {
        INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
            token0: address(WBTC),
            token1: address(HANeP),
            fee: FEE,
            tickLower: TICK_LOWER,
            tickUpper: TICK_UPPER,
            amount0Desired: _wbtcTokenAmount,
            amount1Desired: _hanepTokenAmount,
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(this),
            deadline: block.timestamp
        });

        (tokenId, liquidity, amount0, amount1) = POSITION_MANAGER.mint(params);
        return (tokenId, liquidity, amount0, amount1);
    }

    // private function to add a liquidity provider to the array.
    function _addToProviderArray(address _user, uint256 _tokenId, uint256 _liquidity, uint256 _wbtcAmount, uint256 _hanepAmount) private {
        LiquidityProvider memory newProvider = LiquidityProvider({
            tokenId: _tokenId,
            liquidity: _liquidity,
            wbtcAmount: _wbtcAmount,
            hanepAmount: _hanepAmount,
            lastClaimedTime: block.timestamp,
            lockupPeriod: block.timestamp + YEAR
        });
        providerArray[_user].push(newProvider);
    }

    // Internal function to safely approve tokens.
    function _safeApprove(IERC20 _token, address _spender, uint256 _amount) internal {
        uint256 currentAllowance = _token.allowance(address(this), _spender);

        if (currentAllowance != _amount) {
            if (currentAllowance > 0) {
                _token.approve(_spender, 0);
            }
            _token.approve(_spender, _amount);
            emit SafeApprove(address(_token), _spender, _amount);
        }
    }

    // Internal function to remove an element from the array.
    function _removeElement(uint256 _index) internal {
        require(_index < providerArray[msg.sender].length, "Invalid index");
        providerArray[msg.sender][_index] = providerArray[msg.sender][providerArray[msg.sender].length - 1];
        providerArray[msg.sender].pop();
    }

    // Functions to recover wrong tokens or Ether sent to the contract.
    function recoverERC20(address _tokenAddress, uint256 _tokenAmount) external onlyOwner nonReentrant {
        IERC20(_tokenAddress).transfer(msg.sender, _tokenAmount);
        emit ERC20Recovered(_tokenAddress, msg.sender, _tokenAmount);
    }
    function recoverEther(address payable _recipient, uint256 _ethAmount) external onlyOwner nonReentrant{
        _recipient.transfer(_ethAmount);
        emit EtherRecovered(_recipient, _ethAmount);
    }

    // Functions to pause or unpause the contract.
    function pause() external onlyOwner nonReentrant {
        _pause();
    }
    function unpause() external onlyOwner nonReentrant {
        _unpause();
    }

    // Definitions of events for each major operation.
    event LiquidityAdded(address indexed provider, uint256 tokenId, uint256 wbtcAmount, uint256 hanepAmount, uint256 liquidity);
    event LiquidityRemoved(address indexed provider, uint256 tokenId, uint256 liquidity);
    event RewardsClaimed(address indexed provider, uint256 reward);
    event SwapWETHForWBTC(address indexed sender, uint256 wethAmount, uint256 wbtcReceived);
    event SwapWETHForHANeP(address indexed sender, uint256 wethAmount, uint256 hanepReceived);
    event SafeApprove(address indexed token, address indexed spender, uint256 amount);
    event ReferrerRegistered(address indexed user, uint256 reward);
    event ProviderRegistered(address indexed user, uint256 reward);
    event MusikhanAdded(address indexed musikhan, uint256 amount);
    event AuthorizedAddressSet(address indexed newAuthorizedAddress);
    event SetPersent(uint256 indexed persent);
    event ERC20Recovered(address indexed token, address indexed to, uint256 amount);
    event EtherRecovered(address indexed to, uint256 amount);
}
