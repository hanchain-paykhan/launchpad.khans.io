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

interface IWETH {
    function deposit() external payable;
    function withdraw(uint) external;
}

// This code implements a system where liquidity providers can provide Ether, which is converted into WETH and WBTC, and then supplied as liquidity to the Uniswap V3 pool. Rewards are paid in HANeP tokens, and liquidity providers can remove their liquidity and claim rewards at any time.

contract LiquidityReward_HANeP_1 is Ownable, ReentrancyGuard, Pausable {

    AggregatorV2V3Interface public constant PRICE_FEED = AggregatorV2V3Interface(0x13e3Ee699D1909E989722E753853AE30b17e08c5); // Address of the Chainlink oracle for Ethereum price feed.

    // Addresses related to Uniswap V3.
    INonfungiblePositionManager public constant POSITION_MANAGER = INonfungiblePositionManager(0xC36442b4a4522E871399CD717aBDD847Ab11FE88);
    IUniswapV3Factory public constant FACTORY = IUniswapV3Factory(0x1F98431c8aD98523631AE4a59f267346ea31F984);
    ISwapRouter public constant SWAP_ROUTER = ISwapRouter(0xE592427A0AEce92De3Edee1F18E0157C05861564);
    IUniswapV3Pool public constant WBTC_POOL = IUniswapV3Pool(0xcA1b837C87c6563910c2BEFA48834fA2a8c3D72D);

    // Addresses of WETH, WBTC, and HANeP tokens.
    IWETH public constant WETH = IWETH(0x4200000000000000000000000000000000000006);
    IERC20 public constant WBTC = IERC20(0x68f180fcCe6836688e9084f035309E29Bf0A2095);
    IERC20 public constant HANeP = IERC20(0xC3248A1bd9D72fa3DA6E6ba701E58CbF818354eB);

    uint256 public constant REWARD_PER_SECOND = 191936168949772000; // Defines the reward per second.
    uint256 public constant YEAR = 31536000; // Time in seconds for one year.
    uint256 private constant WEI_MULTIPLIER = 1e18; // Constant for Ethereum unit conversion.
    uint256 public constant PRICE = 75000000000; // Default price setting in USD (decimal 8).

    // Constants for Uniswap pool configuration.
    uint24 public constant FEE = 10000;
    int24 public immutable TICK_LOWER = -887200;
    int24 public immutable TICK_UPPER = 887200;
    
    // Variables related to liquidity.
    uint256 public suppliedWBTC;
    uint256 public suppliedHANeP;
    uint256 public purchaseHANeP;
    uint256 public totalUnderlyingLiquidity;
    uint256 public percent = 525; // 52.5%
    uint256 public slippage = 25; // 2.5%

    // Structure to store information about liquidity providers.
    struct LiquidityProvider {
        uint256 liquidity; // Amount of provided liquidity.
        uint256 tokenId; // Token ID of the provided liquidity.
        uint256 wbtcAmount; // Amount of WBTC tokens provided.
        uint256 hanepAmount; // Amount of HANeP tokens provided.
        uint256 totalReward; // Total accumulated rewards.
        uint256 unclaimedRewards; // Amount of rewards not yet claimed.
        uint256 lastClaimedTime; // Last time rewards were claimed.
        uint256 lockupPeriod; // Time when liquidity can be removed.
        bool hasAddedLiquidity; // Whether liquidity has been provided or not.
    }
    mapping (address => LiquidityProvider) public providers; // Mapping to store information about liquidity providers.

    // Function to convert Ether to WETH, swap some for WBTC, and add liquidity to the Uniswap V3 pool.
    function addLiquidity() external payable nonReentrant {
        LiquidityProvider storage provider = providers[msg.sender];
        require(!provider.hasAddedLiquidity, "Liquidity already added"); // Check if liquidity has already been provided.
        
        WETH.deposit{value: msg.value}(); // Convert Ether to WETH.
        
        uint256 providedEthAmount = msg.value; // Store the amount of Ether provided.
        uint256 currentEthAmount = getEthAmount(PRICE); // Calculate the amount of Ether for the given PRICE.
        uint256 lowerBound = currentEthAmount * (1000 - slippage) / 1000; // Calculate the minimum amount of Ether considering slippage.
        uint256 upperBound = currentEthAmount * (1000 + slippage) / 1000; // Calculate the maximum amount of Ether considering slippage.
        require(providedEthAmount >= lowerBound && providedEthAmount <= upperBound, "Slippage limits exceeded"); // Check for slippage.

        uint256 amount = providedEthAmount * percent / 1000; // Calculate the amount of WETH based on the specified percent.
        uint256 wbtcTokenAmount = _swapWETHForWBTC(amount); // Swap WETH for WBTC.
        uint256 hanepTokenAmount = getEquivalentHANePForWBTC(wbtcTokenAmount); // Calculate the equivalent amount of HANeP tokens for the swapped WBTC.
        purchaseHANeP = _swapWETHForHANeP(providedEthAmount - amount); // Swap the remaining WETH for HANeP.

        _safeApprove(WBTC, address(POSITION_MANAGER), wbtcTokenAmount); // Approve WBTC tokens.
        _safeApprove(HANeP, address(POSITION_MANAGER), hanepTokenAmount); // Approve HANeP tokens.

        (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) = _addLiquidityToUniswap(wbtcTokenAmount, hanepTokenAmount);

        // Update the contract's supplied HANeP and WBTC amounts and total liquidity.
        suppliedWBTC += amount0;
        suppliedHANeP += amount1;
        totalUnderlyingLiquidity += liquidity;

        // Store the liquidity provider's information.
        provider.tokenId = tokenId; 
        provider.liquidity = liquidity;
        provider.wbtcAmount = amount0;
        provider.hanepAmount = amount1;
        provider.lastClaimedTime = block.timestamp;
        provider.lockupPeriod = block.timestamp + YEAR;
        provider.hasAddedLiquidity = true;

        emit LiquidityAdded(msg.sender, tokenId, amount0, amount1, liquidity);
    }

    // Function to remove liquidity and retrieve tokens.
    function removeLiquidity() external nonReentrant {
        LiquidityProvider storage provider = providers[msg.sender];
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

        provider.unclaimedRewards += _calculateRewards(msg.sender); // Calculate and add rewards to unclaimed rewards.

        emit LiquidityRemoved(msg.sender, provider.tokenId, provider.unclaimedRewards);

        // Reset the liquidity provider's information.
        delete provider.tokenId;
        delete provider.liquidity;
        delete provider.wbtcAmount;
        delete provider.hanepAmount;
        delete provider.lockupPeriod;
    }

    // Function for liquidity providers to claim accumulated rewards.
    function claimRewards() external nonReentrant {
        LiquidityProvider storage provider = providers[msg.sender];
        uint256 reward = _calculateRewards(msg.sender) + provider.unclaimedRewards; // Calculate accumulated and unclaimed rewards.
        require(reward > 0, "No rewards to claim"); // Check if there are rewards to claim.
        
        HANeP.transfer(msg.sender, reward); // Transfer the calculated rewards.

        provider.unclaimedRewards = 0; // Reset unclaimed rewards.
        provider.totalReward += reward; // Add the rewarded amount to total rewards.
        provider.lastClaimedTime = block.timestamp; // Update the last claimed time.

        emit RewardsClaimed(msg.sender, reward);
    }

    // Function to view the reward amount for a specific user.
    function rewardView(address _user) public view returns (uint256) {
        uint256 reward = _calculateRewards(_user);
        return reward;
    }

    // Function to convert USD price to Ethereum. (decimal 8)
    function getEthAmount(uint256 _usdPrice) public view returns (uint256) {
        (, int ethPrice, , ,) = PRICE_FEED.latestRoundData();

        uint256 ethPriceInUSD = uint256(ethPrice);
        uint256 ethAmount = _usdPrice * WEI_MULTIPLIER / ethPriceInUSD;

        return ethAmount;
    }

    // Function to view the remaining time for liquidity removal.
    function remainingDuration(address _user) public view returns (uint256) {
        LiquidityProvider memory provider = providers[_user];
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


    // Internal function to calculate rewards for a user.
    function _calculateRewards(address _user) internal view returns (uint256) {
        LiquidityProvider memory provider = providers[_user];
        uint256 reward = 0;
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

    // Function for the contract owner to set the percent
    function setPercent(uint256 _percent) external onlyOwner nonReentrant {
        percent = _percent;
        emit SetPersent(_percent);
    }
    function setSlippage(uint256 _slippage) external onlyOwner nonReentrant {
        slippage = _slippage;
        emit SetSlippage(_slippage);
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
    event SetPersent(uint256 indexed persent);
    event SetSlippage(uint256 indexed slippage);
    event ERC20Recovered(address indexed token, address indexed to, uint256 amount);
    event EtherRecovered(address indexed to, uint256 amount);
}
