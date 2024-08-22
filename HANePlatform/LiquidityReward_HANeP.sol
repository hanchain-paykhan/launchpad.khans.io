// SPDX-License-Identifier: MIT
pragma solidity ^0.7.0;
pragma abicoder v2;

import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-periphery/contracts/libraries/OracleLibrary.sol";
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

contract LiquidityReward_HANeP is Ownable, ReentrancyGuard, Pausable {
    AggregatorV2V3Interface private constant PRICE_FEED = AggregatorV2V3Interface(0x13e3Ee699D1909E989722E753853AE30b17e08c5);
    INonfungiblePositionManager private constant POSITION_MANAGER = INonfungiblePositionManager(0xC36442b4a4522E871399CD717aBDD847Ab11FE88);
    ISwapRouter private constant SWAP_ROUTER = ISwapRouter(0xE592427A0AEce92De3Edee1F18E0157C05861564);
    IUniswapV3Pool public constant WBTC_POOL = IUniswapV3Pool(0xcA1b837C87c6563910c2BEFA48834fA2a8c3D72D);

    IWETH private constant WETH = IWETH(0x4200000000000000000000000000000000000006);
    IERC20 public constant WBTC = IERC20(0x68f180fcCe6836688e9084f035309E29Bf0A2095);
    IERC20 public constant HANeP = IERC20(0xC3248A1bd9D72fa3DA6E6ba701E58CbF818354eB);

    address private constant BASE_POOL_1 = 0xD7294c3eA1426298A50ceA50dF5bCDE96571C88B;
    address private constant BASE_POOL_2 = 0x85C31FFA3706d1cce9d525a00f1C7D4A2911754c;
    address private constant BASE_POOL_3 = 0x73B14a78a0D396C521f954532d43fd5fFe385216;
    address private constant BASE_POOL_4 = 0x37FFd11972128fd624337EbceB167C8C0A5115FF;

    uint256 public constant REWARD_PER_SECOND = 60826809472875600;
    uint256 public constant PERIOD = 2592000;
    uint256 private constant WEI_MULTIPLIER = 1e18;

    int24 private constant TICK_LOWER = -887200;
    int24 private constant TICK_UPPER = 887200;
    uint24 public fee;
    uint256 public purchaseHANeP;
    uint256 public suppliedWBTC;
    uint256 public suppliedHANeP;
    uint256 public totalUnderlyingLiquidity;
    uint256 public round;

    struct LiquidityProvider {
        uint256 round;
        uint256 liquidity;
        uint256 tokenId;
        uint256 wbtcAmount;
        uint256 hanepAmount;
        uint256 lastClaimedTime;
        uint256 lockupPeriod;
    }

    struct TotalLiquidityInfo {
        uint256 totalLiquidity;
        uint256 totalWbtcAmount;
        uint256 totalHanepAmount;
        uint256 totalRewardReleased;
        uint256 unclaimedRewards;
    }

    mapping (address =>  LiquidityProvider[]) private providerArray;
    mapping (address => TotalLiquidityInfo) public totalLiquidityInfo;
    mapping (address => mapping(uint256 => uint256)) public hanepTokensByRound;
    mapping (uint256 => uint256) public thresholdByRound;

    function addLiquidity() external payable nonReentrant whenNotPaused {
        TotalLiquidityInfo storage totalInfo = totalLiquidityInfo[msg.sender];
        require(round > 0, "The round has not started yet, you cannot supply liquidity.");
        
        WETH.deposit{value: msg.value}();        
        uint256 amount = msg.value / 2;

        fee = _checkPool();

        uint256 wbtcTokenAmount = _swapWETHForWBTC(amount, fee);
        uint256 hanepTokenAmount = getEquivalentHANePForWBTC(wbtcTokenAmount);
        purchaseHANeP = _swapWETHForHANeP(amount);

        _safeApprove(WBTC, address(POSITION_MANAGER), wbtcTokenAmount);
        _safeApprove(HANeP, address(POSITION_MANAGER), hanepTokenAmount);
        (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) = _addLiquidityToUniswap(wbtcTokenAmount, hanepTokenAmount);

        suppliedWBTC += amount0;
        suppliedHANeP += amount1;
        totalUnderlyingLiquidity += liquidity;
        totalInfo.totalLiquidity += liquidity;
        totalInfo.totalWbtcAmount += amount0;
        totalInfo.totalHanepAmount += amount1;
        hanepTokensByRound[msg.sender][round] += amount1;

        _addToProviderArray(msg.sender, round, tokenId, liquidity, amount0, amount1);

        emit LiquidityAdded(msg.sender, tokenId, amount0, amount1, liquidity);
    }

    function removeLiquidity(uint256 _index) external nonReentrant whenNotPaused {
        LiquidityProvider memory provider = providerArray[msg.sender][_index];
        TotalLiquidityInfo storage totalInfo = totalLiquidityInfo[msg.sender];
        require(provider.lockupPeriod < block.timestamp, "Lockup period is not over yet");

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

        uint256 getRound = provider.round;
        suppliedWBTC -= provider.wbtcAmount;
        suppliedHANeP -= provider.hanepAmount;
        totalUnderlyingLiquidity -= provider.liquidity;
        totalInfo.totalLiquidity -= provider.liquidity;
        totalInfo.totalWbtcAmount -= provider.wbtcAmount;
        totalInfo.totalHanepAmount -= provider.hanepAmount;
        hanepTokensByRound[msg.sender][getRound] -= provider.hanepAmount;
        totalInfo.unclaimedRewards += _calculateRewards(msg.sender, _index);

        _removeElement(_index);

        emit LiquidityRemoved(msg.sender, provider.tokenId, provider.liquidity);
    }

    function claimRewards() external nonReentrant whenNotPaused {
        TotalLiquidityInfo storage totalInfo = totalLiquidityInfo[msg.sender];
        uint256 reward = 0;

        for(uint i = 0; i < providerArray[msg.sender].length; i++) {
            LiquidityProvider storage provider = providerArray[msg.sender][i];
            uint256 rewardValue = _calculateRewards(msg.sender, i);
            if (rewardValue > 0) {
                reward += rewardValue;
                provider.lastClaimedTime = block.timestamp;
            }
        }
        require(reward + totalInfo.unclaimedRewards > 0, "No rewards to claim");
        HANeP.transfer(msg.sender, reward + totalInfo.unclaimedRewards);
        totalInfo.totalRewardReleased += reward + totalInfo.unclaimedRewards;
        totalInfo.unclaimedRewards = 0;
        emit RewardsClaimed(msg.sender, reward);
    }

    function initializeRound(uint256 _round, uint256 _threshold) external onlyOwner nonReentrant {
        round = _round;
        thresholdByRound[round] = _threshold;
        emit RoundInitialized(round, _threshold);
    }

    function recoverERC20(address _tokenAddress, uint256 _tokenAmount) external onlyOwner nonReentrant {
        IERC20(_tokenAddress).transfer(msg.sender, _tokenAmount);
        emit ERC20Recovered(_tokenAddress, msg.sender, _tokenAmount);
    }

    function recoverEther(address payable _recipient, uint256 _ethAmount) external onlyOwner nonReentrant{
        _recipient.transfer(_ethAmount);
        emit EtherRecovered(_recipient, _ethAmount);
    }

    function pause() external onlyOwner nonReentrant {
        _pause();
    }

    function unpause() external onlyOwner nonReentrant {
        _unpause();
    }

    function isEligibleForParticipation(address _user, uint256 _round) public view returns (bool) {
        if(thresholdByRound[_round] == 0) {
            return false;
        }
        bool meetsLiquidityRequirement = hanepTokensByRound[_user][_round] >= thresholdByRound[_round];
        return meetsLiquidityRequirement;
    }

    function getProviders(address _user) public view returns(LiquidityProvider[] memory) {
        return providerArray[_user];
    }

    function remainingDuration(address _user, uint256 _index) public view returns (uint256) {
        LiquidityProvider memory provider = providerArray[_user][_index];
        if(provider.lockupPeriod > block.timestamp) { 
            return provider.lockupPeriod - block.timestamp;
        } else {
            return 0;
        }
    }

    function rewardView(address _user) public view returns (uint256) {
        uint256 reward;
        for(uint i = 0; i < providerArray[_user].length; i++) {
            uint256 rewardValue = _calculateRewards(_user, i);
            if (rewardValue > 0) {
                reward += rewardValue;
            }
        }
        if(reward == 0) {
            return 0;
        }
        return reward;
    }

    function getUSDPrice(uint256 _ethAmount) public view returns (uint256) {
        (, int ethPrice, , ,) = PRICE_FEED.latestRoundData();

        uint256 ethPriceInUSD = uint256(ethPrice);
        uint256 usdPrice = _ethAmount * ethPriceInUSD / WEI_MULTIPLIER;

        return usdPrice;
    }

    function getEthAmount(uint256 _usdPrice) public view returns (uint256) {
        (, int ethPrice, , ,) = PRICE_FEED.latestRoundData();

        uint256 ethPriceInUSD = uint256(ethPrice);
        uint256 ethAmount = _usdPrice * WEI_MULTIPLIER / ethPriceInUSD;

        return ethAmount;
    }

    function getEquivalentHANePForWBTC(uint _wbtcAmount) public view returns (uint256) {
        (, int24 tick, , , , , ) = WBTC_POOL.slot0();

        uint btcPrice = OracleLibrary.getQuoteAtTick(
            tick,
            uint128(_wbtcAmount),
            WBTC_POOL.token0(),
            WBTC_POOL.token1()
        );
        return btcPrice;
    }

    function _checkPool() private view returns (uint24) {
        uint256 balance1 = WBTC.balanceOf(BASE_POOL_1);
        uint256 balance2 = WBTC.balanceOf(BASE_POOL_2);
        uint256 balance3 = WBTC.balanceOf(BASE_POOL_3);
        uint256 balance4 = WBTC.balanceOf(BASE_POOL_4);
        
        if (balance1 > balance2 && balance1 > balance3 && balance1 > balance4) {
            return 100;
        } else if (balance2 > balance1 && balance2 > balance3 && balance2 > balance4) {
            return 500;
        } else if (balance3 > balance1 && balance3 > balance2 && balance3 > balance4) {
            return 3000;
        } else if (balance4 > balance1 && balance4 > balance2 && balance4 > balance3) {
            return 10000;
        } else {
            return 3000;
        }
    }

    function _calculateRewards(address _user, uint256 _index) private view returns (uint256) {
        LiquidityProvider memory provider = providerArray[_user][_index];
        uint256 reward;
        uint256 stakedTime = block.timestamp - provider.lastClaimedTime;
        reward = provider.liquidity * stakedTime * REWARD_PER_SECOND / WEI_MULTIPLIER;
        return reward;
    }

    function _swapWETHForWBTC(uint256 _wethAmount, uint24 _fee) private returns (uint256) {
        
        uint256 wbtcBalanceBefore = WBTC.balanceOf(address(this));

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: address(WETH),
            tokenOut: address(WBTC),
            fee: _fee,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: _wethAmount,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });
        
        IERC20(address(WETH)).approve(address(SWAP_ROUTER), _wethAmount);
        SWAP_ROUTER.exactInputSingle(params);

        uint256 wbtcBalanceAfter = WBTC.balanceOf(address(this));

        uint256 wbtcReceived = wbtcBalanceAfter - wbtcBalanceBefore;
        emit SwapWETHForWBTC(msg.sender, _wethAmount, wbtcReceived);
        return wbtcReceived;
    }

    function _swapWETHForHANeP(uint256 _wethAmount) private returns (uint256) {

        uint256 hanepBalanceBefore = HANeP.balanceOf(address(this));

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: address(WETH),
            tokenOut: address(HANeP),
            fee: 10000,
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
            fee: 10000,
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

    function _addToProviderArray(address _user, uint256 _round, uint256 _tokenId, uint256 _liquidity, uint256 _wbtcAmount, uint256 _hanepAmount) private {
        LiquidityProvider memory newProvider = LiquidityProvider({
            round: _round,
            tokenId: _tokenId,
            liquidity: _liquidity,
            wbtcAmount: _wbtcAmount,
            hanepAmount: _hanepAmount,
            lastClaimedTime: block.timestamp,
            lockupPeriod: block.timestamp + PERIOD
        });
        providerArray[_user].push(newProvider);
    }

    function _safeApprove(IERC20 _token, address _spender, uint256 _amount) private {
        uint256 currentAllowance = _token.allowance(address(this), _spender);

        if (currentAllowance != _amount) {
            if (currentAllowance > 0) {
                _token.approve(_spender, 0);
            }
            _token.approve(_spender, _amount);
            emit SafeApprove(address(_token), _spender, _amount);
        }
    }

    function _removeElement(uint256 _index) private {
        require(_index < providerArray[msg.sender].length, "Invalid index");
        providerArray[msg.sender][_index] = providerArray[msg.sender][providerArray[msg.sender].length - 1];
        providerArray[msg.sender].pop();
    }

    event LiquidityAdded(address indexed provider, uint256 tokenId, uint256 wbtcAmount, uint256 hanepAmount, uint256 liquidity);
    event LiquidityRemoved(address indexed provider, uint256 tokenId, uint256 liquidity);
    event RewardsClaimed(address indexed provider, uint256 reward);
    event SwapWETHForWBTC(address indexed sender, uint256 wethAmount, uint256 wbtcReceived);
    event SwapWETHForHANeP(address indexed sender, uint256 wethAmount, uint256 hanepReceived);
    event SafeApprove(address indexed token, address indexed spender, uint256 amount);
    event ERC20Recovered(address indexed token, address indexed to, uint256 amount);
    event EtherRecovered(address indexed to, uint256 amount);
    event RoundInitialized(uint256 indexed round, uint256 threshold);
}
