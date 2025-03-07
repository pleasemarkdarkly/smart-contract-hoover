pragma solidity ^0.6.12;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./interfaces/IRouter.sol";
import "./interfaces/IFarm.sol";
import "./interfaces/IPair.sol";
import "./interfaces/IController.sol";
import "./StrategyStorage.sol";

contract FarmStrategy is FarmStrategyStorage{
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    event PriceViewChanged(address oldPriceView, address newPriceView);
    event Reinvestment(address pool, address token, uint256 amount);

    function initialize(address _lpToken, address _controller, address _router, uint256 _pid, address _farm, address _profit, address _priceView) external {
        require(msg.sender == admin, "UNAUTHORIZED");
        require(controller == address(0), "ALREADY INITIALIZED");
        lpToken = _lpToken;
        farm = _farm;
        profit = _profit;
        controller = _controller;
        router = _router;
        pid = _pid;
        priceView = _priceView;
        token0 = IPair(_lpToken).token0();
        token1 = IPair(_lpToken).token1();
    }

    function setFarm(address _farm) external onlyOwner{
        farm = _farm;
    }

    function earn(address[] memory _tokens, uint256[] memory _amounts, address[] memory _earnTokens ,uint256[] memory _amountLimits) external override{
        require(msg.sender == controller, "!controller");
        require((_tokens[0] == token0 && _tokens[1] == token1) || (_tokens[0] == token1 && _tokens[1] == token0), "Invalid token");
        require((_earnTokens[0] == token0 && _earnTokens[1] == token1) || (_earnTokens[0] == token1 && _earnTokens[1] == token0), "Invalid earn token");
        (_amountLimits[0], _amountLimits[1]) = _earnTokens[0] == token0 ? (_amountLimits[0], _amountLimits[1]) : (_amountLimits[1], _amountLimits[0]);
        require(_amounts[0] > 0 && _amounts[1] > 0, "Invalid amounts");
        (uint256 amount0, uint256 amount1) = _tokens[0] == token0 ? (_amounts[0], _amounts[1]) : (_amounts[1], _amounts[0]);
        earnInternal(amount0, amount1, _amountLimits[0], _amountLimits[1]);
    }

    function withdraw(uint256 amount) external override returns (address[] memory tokens, uint256[] memory amounts){
        require(msg.sender == controller, "!controller");
        withdrawFromFarm(amount);
        IERC20(lpToken).safeApprove(router, amount);
        lpTokenAmount = lpTokenAmount.sub(amount);
        tokens = new address[](2);
        tokens[0] = token0;
        tokens[1] = token1;
        amounts = new uint256[](2);
        (amounts[0], amounts[1]) = IRouter(router).removeLiquidity(token0, token1, amount, 0, 0, address(this), block.timestamp.add(1));
        if(token0 == profit){
            uint256 token0Balance = IERC20(token0).balanceOf(address(this));
            amounts[0] = token0Balance - profitAmount < amounts[0] ? token0Balance-profitAmount : amounts[0];
        }else if (token1 == profit){
            uint256 token1Balance = IERC20(token1).balanceOf(address(this));
            amounts[1] = token1Balance - profitAmount < amounts[1] ? token1Balance - profitAmount : amounts[1];
        }
        IERC20(token0).safeTransfer(controller, amounts[0]);
        IERC20(token1).safeTransfer(controller, amounts[1]);
    }

    //用于提取未用于投资的token
    function withdraw(address token) external override returns (uint256){
        require(msg.sender == controller, "!controller");
        require(token == token0 || token == token1, "Invalid token");
        uint256 balance = IERC20(token).balanceOf(address(this));
        if(token == profit) balance = balance.add(reinvestmentAmount).sub(profitAmount);
        IERC20(token).safeTransfer(controller, balance);
        return balance;
    }

    function uint2str(uint i) internal view returns (string memory c) {
        if (i == 0) return "0";
        uint j = i;
        uint length;
        while (j != 0){
            length++;
            j /= 10;
        }
        bytes memory bstr = new bytes(length);
        uint k = length - 1;
        while (i != 0){
            bstr[k--] = byte(uint8(48 + i % 10));
            i /= 10;
        }
        c = string(bstr);
    }

    function withdrawProfit(address token, uint256 amount) external override returns(uint256, address[] memory, uint256[] memory){
        require(msg.sender == controller, "!controller");
        address[] memory withdrawTokens = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        withdrawFromFarm(0);
        uint256 profitAmountLimit = profitAmount.sub(reinvestmentAmount);
        uint256 tokenPrice = PriceView(priceView).getPrice(token);
        uint256 profitTokenPrice = PriceView(priceView).getPrice(profit);
        uint256 profitTokenAmount = amount.mul(tokenPrice).div(profitTokenPrice);
        
        if(profitTokenAmount > profitAmountLimit){
            profitTokenAmount = profitAmountLimit;
            amount = profitTokenAmount.mul(profitTokenPrice).div(tokenPrice);
        }
        profitAmount = profitAmount.sub(profitTokenAmount);
        withdrawTokens[0] = profit;
        amounts[0] = profitTokenAmount;
        IERC20(profit).safeTransfer(controller, profitTokenAmount);
        return (amount, withdrawTokens, amounts);
    }

    function withdraw(address[] memory tokens, uint256 amount) external override returns (uint256, address[] memory, uint256[] memory){
        require(msg.sender == controller, "!controller");
        uint256 count = 1;
        address token = tokens[0];
        if(token != token0 && token != token1) count++; 
        address[] memory withdrawTokens = new address[](count);
        uint256[] memory amounts = new uint256[](count);
        uint256 tokenAmount = amount;
        uint256 balance = IERC20(token).balanceOf(address(this));
        if(token == profit) balance = balance.sub(profitAmount.sub(reinvestmentAmount));
        if(balance >= tokenAmount){
            amounts[0] = tokenAmount;
            withdrawTokens[0] = token;
        }
        else if(tokens.length == 1){
            uint256 _lpTokenAmount = caculateLPTokenAmount(token, tokenAmount.sub(balance));
            if(_lpTokenAmount == 0){
                withdrawTokens[0] = token;
                amounts[0] = balance;
                tokenAmount = balance;
            }else{
                lpTokenAmount = lpTokenAmount.sub(_lpTokenAmount);
                withdrawFromFarm(_lpTokenAmount);
                IERC20(lpToken).safeApprove(router, _lpTokenAmount);
                (uint256 amount0, uint256 amount1) = IRouter(router).removeLiquidity(token0, token1, _lpTokenAmount, 0, 0, address(this), block.timestamp.add(1));
                if(token == token0){
                    tokenAmount = tokenAmount > amount0.add(balance) ? amount0.add(balance) : tokenAmount;
                    amounts[0] = tokenAmount;
                    withdrawTokens[0] = token;
                }
                else if(token == token1){
                    tokenAmount = tokenAmount > amount1.add(balance) ? amount1.add(balance) : tokenAmount;
                    amounts[0] = tokenAmount;
                    withdrawTokens[0] = token;
                }else{
                    uint256 tokenPrice = PriceView(priceView).getPrice(token);
                    uint256 token0Price = PriceView(priceView).getPrice(token0);
                    uint256 token1Price = PriceView(priceView).getPrice(token1);
                    uint256 tokenAmountInUSD = tokenAmount.mul(tokenPrice);
                    uint256 needAmount0 = tokenAmountInUSD.div(token0Price).div(2);
                    uint256 needAmount1 = tokenAmountInUSD.div(token1Price).div(2);
                    require(needAmount0 <= amount0 && needAmount1 <= amount1, "Wrong amount");
                    amounts[0] = needAmount0;
                    amounts[1] = needAmount1;
                    withdrawTokens[0] = token0;
                    withdrawTokens[1] = token1;
                }
            }
        }
        else{
            address otherToken = tokens[1];
            require(token == token0 && otherToken == token1 || token == token1 && otherToken == token0, "Invalid token");
            (uint256 reserve0, uint256 reserve1,) = IPair(lpToken).getReserves();
            (uint256 tokenReserve, uint256 otherTokenReserve) = token == IPair(lpToken).token0() ? (reserve0, reserve1) : (reserve1, reserve0);
            uint256 otherTokenAmount = tokenAmount.mul(otherTokenReserve).div(tokenReserve);
            uint256 otherTokenBalance = IERC20(otherToken).balanceOf(address(this));
            if(otherTokenAmount > otherTokenBalance){
                tokenAmount = otherTokenBalance.mul(tokenReserve).div(otherTokenReserve);
                otherTokenAmount = otherTokenBalance;
            } 
            amounts[0] = otherTokenAmount;
            withdrawTokens[0] = otherToken;
        }
        amount = tokenAmount;
        for(uint256 i = 0; i < amounts.length; i ++){
            if(withdrawTokens[i] == address(0) || amounts[i] == 0) continue;
            IERC20(withdrawTokens[i]).safeTransfer(controller, amounts[i]);
        }
        return (amount, withdrawTokens, amounts);
    }

    //token和profit单独算
    // function withdraw(address[] memory tokens, uint256 amount, uint256 _profitAmount) external override returns (uint256, uint256, address[] memory, uint256[] memory){
    //     require(msg.sender == controller, "!controller");
    //     uint256 count = amount > 0 && _profitAmount > 0 ? 2 : 1;
    //     address token = tokens[0];
    //     if(token != token0 && token != token1 && amount > 0) count++; 
    //     address[] memory withdrawTokens = new address[](count);
    //     uint256[] memory amounts = new uint256[](count);
    //     if(amount > 0){
    //         uint256 tokenAmount = amount;
    //         uint256 balance = IERC20(token).balanceOf(address(this));
    //         if(token == profit) balance = balance.add(reinvestmentAmount).sub(profitAmount);
    //         if(tokens.length == 1){
    //             uint256 _lpTokenAmount = caculateLPTokenAmount(token, tokenAmount.sub(balance));
    //             lpTokenAmount = lpTokenAmount.sub(_lpTokenAmount);
    //             withdrawFromFarm(_lpTokenAmount);
    //             IERC20(lpToken).safeApprove(router, _lpTokenAmount);
    //             (uint256 amount0, uint256 amount1) = IRouter(router).removeLiquidity(token0, token1, _lpTokenAmount, 0, 0, address(this), block.timestamp.add(1));
    //             if(token == token0){
    //                 tokenAmount = tokenAmount > amount0.add(balance) ? amount0.add(balance) : tokenAmount;
    //                 amounts[0] = tokenAmount;
    //                 withdrawTokens[0] = token;
    //             }
    //             else if(token == token1){
    //                 tokenAmount = tokenAmount > amount1.add(balance) ? amount1.add(balance) : tokenAmount;
    //                 amounts[0] = tokenAmount;
    //                 withdrawTokens[0] = token;
    //             }else{
    //                 uint256 tokenPrice = PriceView(priceView).getPrice(token);
    //                 uint256 token0Price = PriceView(priceView).getPrice(token0);
    //                 uint256 token1Price = PriceView(priceView).getPrice(token1);
    //                 uint256 tokenAmountInUSD = tokenAmount.mul(tokenPrice);
    //                 uint256 needAmount0 = tokenAmountInUSD.div(token0Price).div(2);
    //                 uint256 needAmount1 = tokenAmountInUSD.div(token1Price).div(2);
    //                 require(needAmount0 <= amount0 && needAmount1 <= amount1, "Wrong amount");
    //                 amounts[0] = needAmount0;
    //                 amounts[1] = needAmount1;
    //                 withdrawTokens[0] = token0;
    //                 withdrawTokens[1] = token1;
    //             }
    //         }
    //         else{
    //             address otherToken = tokens[1];
    //             require(token == token0 && otherToken == token1 || token == token1 && otherToken == token0, "Invalid token");
    //             (uint256 reserve0, uint256 reserve1,) = IPair(lpToken).getReserves();
    //             (uint256 tokenReserve, uint256 otherTokenReserve) = token == IPair(lpToken).token0() ? (reserve0, reserve1) : (reserve1, reserve0);
    //             uint256 otherTokenAmount = tokenAmount.mul(otherTokenReserve).div(tokenReserve);
    //             uint256 otherTokenBalance = IERC20(otherToken).balanceOf(address(this));
    //             require(false, uint2str(otherTokenAmount));
    //             if(otherTokenAmount > otherTokenBalance){
    //                 tokenAmount = otherTokenBalance.mul(tokenReserve).div(otherTokenReserve);
    //                 otherTokenAmount = otherTokenBalance;
    //             } 
    //             amounts[0] = otherTokenAmount;
    //             withdrawTokens[0] = otherToken;
    //         }
    //         amount = tokenAmount;
    //     }
        
    //     if(_profitAmount > 0){
    //         uint256 tokenPrice = PriceView(priceView).getPrice(tokens[0]);
    //         uint256 profitTokenPrice = PriceView(priceView).getPrice(profit);
    //         uint256 profitTokenAmount = _profitAmount.mul(tokenPrice).div(profitTokenPrice);
    //         if(count == 1) withdrawFromFarm(0);
    //         uint256 profitBalance = IERC20(profit).balanceOf(address(this));
    //         uint256 profitAmountLimit = profitBalance > profitAmount? profitAmount: profitBalance;
    //         if(profitTokenAmount > profitAmountLimit){
    //             profitTokenAmount = profitAmountLimit;
    //             _profitAmount = profitTokenAmount.mul(profitTokenPrice).div(tokenPrice);
    //         }
    //         reinvestmentAmount = reinvestmentAmount > profitTokenAmount ? reinvestmentAmount.sub(profitTokenAmount) : 0;
    //         profitAmount = profitAmount.sub(profitTokenAmount);
    //         withdrawTokens[count - 1] = profit;
    //         amounts[count - 1] = profitTokenAmount;
    //     }
    //     for(uint256 i = 0; i < amounts.length; i ++){
    //         IERC20(withdrawTokens[i]).safeTransfer(controller, amounts[i]);
    //     }
    //     return (amount, _profitAmount, withdrawTokens, amounts);
    // }

    //TODO 损失率达到一定阈值任何人都能将lp token赎回并移除流动性，token留在本合约；需要设定阈值

    //TODO 赎回所有token,需要确定给谁

    function harvest() external {
        withdrawFromFarm(0);
    }

    function reinvestment(address[] memory pools, address[] memory tokens, uint256[] memory amounts) external override{
        require(msg.sender == controller, "!controller");
        require(profit == tokens[0], "Invalid token");
        require(IController(controller).acceptedPools(tokens[0], pools[0]), "Invalid pool");
        withdrawFromFarm(0);
        reinvestmentAmount = reinvestmentAmount.add(amounts[0]);
        require(reinvestmentAmount <= profitAmount);
        IERC20(tokens[0]).safeTransfer(pools[0], amounts[0]);
        emit Reinvestment(pools[0], tokens[0], amounts[0]);
    }

    function setPriceView(address _priceView) external{
        require(msg.sender == admin, "!admin");
        address oldPriceView = priceView;
        priceView = _priceView;
        emit PriceViewChanged(oldPriceView, _priceView);
    }

    function getTokens() external view override returns (address[] memory tokens){
        tokens = new address[](2);
        tokens[0] = token0;
        tokens[1] = token1;
    } 

    function getProfitTokens() external view override returns (address[] memory tokens){
        tokens = new address[](1);
        tokens[0] = profit;
    }

    function getTokenAmounts() external view override returns (address[] memory tokens, uint256[] memory amounts){
        uint256 count = token0 == profit || token1 == profit ? 2 : 3;
        tokens = new address[](count);
        amounts = new uint256[](count);
        tokens[0] = token0;
        tokens[1] = token1;
        uint256 totalSupply = IPair(lpToken).totalSupply(); //TODO IPair设置feeTo地址话totalSupply不准
        amounts[0] = totalSupply == 0 ? 0 : lpTokenAmount.mul(IERC20(token0).balanceOf(lpToken)).div(totalSupply);
        amounts[1] = totalSupply == 0 ? 0 : lpTokenAmount.mul(IERC20(token1).balanceOf(lpToken)).div(totalSupply);
        amounts[0] = amounts[0].add(IERC20(token0).balanceOf(address(this)));
        amounts[1] = amounts[1].add(IERC20(token1).balanceOf(address(this)));
        uint256 pending = IFarm(farm).pending(pid, address(this));
        if(count == 3){
            tokens[2] = profit;
            amounts[2] = IERC20(profit).balanceOf(address(this));
            amounts[2] = amounts[2].add(pending);
        }else{
            (amounts[0],amounts[1]) = token0 == profit ? (amounts[0].add(pending), amounts[1]) : (amounts[0], amounts[1].add(pending));
        }
    }

    function getProfitAmount() view public returns (uint256){
        return profitAmount.add(IFarm(farm).pending(pid, address(this)));
    }

    function earnInternal(uint256 amount0, uint256 amount1, uint256 minAmount0, uint256 minAmount1) internal{
        IERC20(token0).safeTransferFrom(controller, address(this), amount0);
        IERC20(token1).safeTransferFrom(controller, address(this), amount1);
        //TODO 1.是否要限制amountMin; 2.添加完后可能会有剩余token
        IERC20(token0).safeApprove(router, amount0);
        IERC20(token1).safeApprove(router, amount1);
        (,, uint256 liquidity) = IRouter(router).addLiquidity(token0,token1,amount0,amount1,minAmount0,minAmount1,address(this),block.timestamp.add(1));
        IERC20(token0).safeApprove(router, 0);
        IERC20(token1).safeApprove(router, 0);
        lpTokenAmount = lpTokenAmount.add(liquidity);
        uint256 profitBalance = IERC20(profit).balanceOf(address(this));
        IERC20(lpToken).safeApprove(farm, liquidity);
        IFarm(farm).deposit(pid, liquidity);
        profitAmount = profitAmount.add(IERC20(profit).balanceOf(address(this)).sub(profitBalance));
    }

    function withdrawFromFarm(uint256 amount) internal{
        uint256 profitBalance = IERC20(profit).balanceOf(address(this));
        IFarm(farm).withdraw(pid, amount);
        profitAmount = profitAmount.add(IERC20(profit).balanceOf(address(this)).sub(profitBalance));
    }

    function caculateLPTokenAmount(address token, uint256 amount) internal view returns (uint256){
        uint256 token0Balance = IERC20(token0).balanceOf(lpToken);
        uint256 token1Balance = IERC20(token1).balanceOf(lpToken);
        uint256 totalSupply = IPair(lpToken).totalSupply();
        uint256 tokenBalance;
        if(token == token0){
            tokenBalance = token0Balance;
        }
        else if(token == token1){
            tokenBalance = token1Balance;
        }
        else{
            uint256 tokenPrice = PriceView(priceView).getPrice(token);
            uint256 token0Price = PriceView(priceView).getPrice(token0);
            amount = amount.mul(tokenPrice).div(token0Price).div(2);
            token = token0;
            tokenBalance = token0Balance;
        }
        uint256 lpLimit0 = totalSupply.div(token0Balance);
        uint256 lpLimit1 = totalSupply.div(token1Balance);
        uint256 lpLimit = lpLimit0 < lpLimit1 ? lpLimit1.add(1) : lpLimit0.add(1);
        uint256 _lpTokenAmount = amount.mul(totalSupply);
        _lpTokenAmount = _lpTokenAmount.div(tokenBalance).add(1);
        if(_lpTokenAmount > lpTokenAmount) _lpTokenAmount = lpTokenAmount;
        if(_lpTokenAmount == 0) return 0;
        if(_lpTokenAmount < lpLimit) _lpTokenAmount = lpLimit;
        return _lpTokenAmount;
    }

    function hasItem(address[] memory _array, address _item) internal pure returns (bool){
        for(uint256 i = 0; i < _array.length; i++){
            if(_array[i] == _item) return true;
        }
        return false;
    }
}

pragma solidity ^0.6.12;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "./interfaces/IFactory.sol";
import "./interfaces/IPair.sol";

interface IToken{
    function decimals() view external returns (uint256);
}

contract PriceView {
    using SafeMath for uint256;
    IFactory public factory;
    address public anchorToken;
    address public usdt;
    uint256 constant private one = 1e18;

    constructor(address _anchorToken, address _usdt, IFactory _factory) public {
        anchorToken = _anchorToken;
        usdt = _usdt;
        factory = _factory;
    }

    function getPrice(address token) view external returns (uint256){
        if(token == anchorToken) return one;
        address pair = factory.getPair(token, anchorToken);
        (uint256 reserve0, uint256 reserve1,) = IPair(pair).getReserves();
        (uint256 tokenReserve, uint256 anchorTokenReserve) = token == IPair(pair).token0() ? (reserve0, reserve1) : (reserve1, reserve0);
        return one.mul(anchorTokenReserve).div(tokenReserve);
    }

    function getPriceInUSDT(address token) view external returns (uint256){
        uint256 decimals = IToken(token).decimals();
        if(token == usdt) return 10 ** decimals;
        decimals = IToken(anchorToken).decimals();
        uint256 price = 10 ** decimals;
        if(token != anchorToken){
            decimals = IToken(token).decimals();
            address pair = factory.getPair(token, anchorToken);
            (uint256 reserve0, uint256 reserve1,) = IPair(pair).getReserves();
            (uint256 tokenReserve, uint256 anchorTokenReserve) = token == IPair(pair).token0() ? (reserve0, reserve1) : (reserve1, reserve0);
            price = (10 ** decimals).mul(anchorTokenReserve).div(tokenReserve);
        }
        if(anchorToken != usdt){
            address pair = factory.getPair(anchorToken, usdt);
            (uint256 reserve0, uint256 reserve1,) = IPair(pair).getReserves();
            (uint256 anchorTokenReserve, uint256 usdtReserve) = anchorToken == IPair(pair).token0() ? (reserve0, reserve1) : (reserve1, reserve0);
            price = price.mul(usdtReserve).div(anchorTokenReserve);
        }
        return price;
    }
}

pragma solidity ^0.6.12;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./PriceView.sol";
import "./interfaces/IStrategy.sol";

contract StrategyAdminStorage is Ownable {
    address public admin;

    address public implementation;
}

abstract contract FarmStrategyStorage is StrategyAdminStorage, IStrategy {
    address public controller;
    address public router;
    address public priceView;
    address public token0; //token0地址
    address public token1;//token1地址
    address public lpToken; //lpToken地址
    uint256 public lpTokenAmount;
    uint256 public pid; //farm pid
    address public farm; //farm合约地址
    address public profit; //收益token
    uint256 public profitAmount; //收益token数量
    uint256 public reinvestmentAmount;
}

abstract contract BoardRoomMDXStrategyStorage is StrategyAdminStorage, IStrategy {
    address public controller;
    address public router;
    address public WETH;
    address public priceView;
    address public wantToken;
    uint256 public wantTokenAmount;
    uint256 public pid; //farm pid
    address public farm; //farm合约地址
    address public profit; //收益token
    uint256 public profitAmount; //收益token数量
    uint256 public reinvestmentAmount;
}

pragma solidity ^0.6.12;
pragma experimental ABIEncoderV2;

import "./ISVaultNetValue.sol";

interface IController {
    struct TokenAmount{
        address token;
        uint256 amount;
    }
    function withdraw(uint256 _amount, uint256 _profitAmount) external returns (TokenAmount[] memory);
    function accrueProfit() external returns (ISVaultNetValue.NetValue[] memory netValues);
    function getStrategies() view external returns(address[] memory);
    function getFixedPools() view external returns(address[] memory);
    function getFlexiblePools() view external returns(address[] memory);
    function allocatedProfit(address _pool) view external returns(uint256);
    function acceptedPools(address token, address pool) view external returns(bool);
}

// SPDX-License-Identifier: MIT
pragma solidity >=0.5.0;

interface IFactory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

pragma solidity ^0.6.12;

interface IFarm {
    struct UserInfo {
        uint256 amount;     // How many LP tokens the user has provided.
        uint256 rewardDebt;
    }
    function deposit(uint256 _pid, uint256 _amount) external;
    function withdraw(uint256 _pid, uint256 _amount) external;
    function pending(uint256 _pid, address _user) external view returns (uint256);
    //function userInfo(uint256 _pid, address _user) external view returns (UserInfo);
}

// SPDX-License-Identifier: MIT
pragma solidity >=0.5.0;

interface IPair {
    function totalSupply() external view returns (uint);
    function balanceOf(address owner) external view returns (uint);

    function approve(address spender, uint value) external returns (bool);
    function transfer(address to, uint value) external returns (bool);
    function transferFrom(address from, address to, uint value) external returns (bool);

    function factory() external view returns (address);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function price0CumulativeLast() external view returns (uint);
    function price1CumulativeLast() external view returns (uint);
    function kLast() external view returns (uint);
}

// SPDX-License-Identifier: MIT
pragma solidity >=0.6.2;

interface IRouter {
    function factory() external pure returns (address);
    function WETH() external pure returns (address);

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external returns (uint amountA, uint amountB, uint liquidity);
    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint liquidity,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external returns (uint amountA, uint amountB);
    function removeLiquidityETH(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external returns (uint amountToken, uint amountETH);
    function getTokenInPair(address pair,address token) 
        external
        view
        returns (uint balance);
    function quote(uint amountA, uint reserveA, uint reserveB) external pure returns (uint amountB);
    function getAmountOut(uint amountIn, uint reserveIn, uint reserveOut) external pure returns (uint amountOut);
    function getAmountIn(uint amountOut, uint reserveIn, uint reserveOut) external pure returns (uint amountIn);
    function getAmountsOut(uint amountIn, address[] calldata path) external view returns (uint[] memory amounts);
    function getAmountsIn(uint amountOut, address[] calldata path) external view returns (uint[] memory amounts);
}

pragma solidity ^0.6.12;
pragma experimental ABIEncoderV2;

interface ISVaultNetValue {
    function getNetValue(address pool) external view returns (NetValue memory);

    struct NetValue {
        address pool;
        address token;
        uint256 amount;
        uint256 amountInETH;
        uint256 totalTokens; //本金加收益
        uint256 totalTokensInETH; //本金加收益
    }
}

pragma solidity ^0.6.12;

abstract contract IStrategy {
    function earn(address[] memory tokens, uint256[] memory amounts, address[] memory earnTokens, uint256[] memory amountLimits) external virtual;
    function withdraw(address token) external virtual returns (uint256);
    function withdraw(uint256 amount) external virtual returns (address[] memory tokens, uint256[] memory amounts);
    function withdraw(address[] memory tokens, uint256 amount) external virtual returns (uint256, address[] memory, uint256[] memory);
    function withdrawProfit(address token, uint256 amount) external virtual returns (uint256, address[] memory, uint256[] memory);
    //function withdraw(address[] memory tokens, uint256 amount, uint256 _profitAmount) external virtual returns (uint256, uint256, address[] memory, uint256[] memory);
    function reinvestment(address[] memory pools, address[] memory tokens, uint256[] memory amounts) external virtual;
    function getTokenAmounts() external view virtual returns (address[] memory tokens, uint256[] memory amounts);
    function getTokens() external view virtual returns (address[] memory tokens);
    function getProfitTokens() external view virtual returns (address[] memory tokens);
}

// SPDX-License-Identifier: MIT

pragma solidity >=0.6.0 <0.8.0;

import "../utils/Context.sol";
/**
 * @dev Contract module which provides a basic access control mechanism, where
 * there is an account (an owner) that can be granted exclusive access to
 * specific functions.
 *
 * By default, the owner account will be the one that deploys the contract. This
 * can later be changed with {transferOwnership}.
 *
 * This module is used through inheritance. It will make available the modifier
 * `onlyOwner`, which can be applied to your functions to restrict their use to
 * the owner.
 */
abstract contract Ownable is Context {
    address private _owner;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /**
     * @dev Initializes the contract setting the deployer as the initial owner.
     */
    constructor () internal {
        address msgSender = _msgSender();
        _owner = msgSender;
        emit OwnershipTransferred(address(0), msgSender);
    }

    /**
     * @dev Returns the address of the current owner.
     */
    function owner() public view virtual returns (address) {
        return _owner;
    }

    /**
     * @dev Throws if called by any account other than the owner.
     */
    modifier onlyOwner() {
        require(owner() == _msgSender(), "Ownable: caller is not the owner");
        _;
    }

    /**
     * @dev Leaves the contract without owner. It will not be possible to call
     * `onlyOwner` functions anymore. Can only be called by the current owner.
     *
     * NOTE: Renouncing ownership will leave the contract without an owner,
     * thereby removing any functionality that is only available to the owner.
     */
    function renounceOwnership() public virtual onlyOwner {
        emit OwnershipTransferred(_owner, address(0));
        _owner = address(0);
    }

    /**
     * @dev Transfers ownership of the contract to a new account (`newOwner`).
     * Can only be called by the current owner.
     */
    function transferOwnership(address newOwner) public virtual onlyOwner {
        require(newOwner != address(0), "Ownable: new owner is the zero address");
        emit OwnershipTransferred(_owner, newOwner);
        _owner = newOwner;
    }
}

// SPDX-License-Identifier: MIT

pragma solidity >=0.6.0 <0.8.0;

/**
 * @dev Wrappers over Solidity's arithmetic operations with added overflow
 * checks.
 *
 * Arithmetic operations in Solidity wrap on overflow. This can easily result
 * in bugs, because programmers usually assume that an overflow raises an
 * error, which is the standard behavior in high level programming languages.
 * `SafeMath` restores this intuition by reverting the transaction when an
 * operation overflows.
 *
 * Using this library instead of the unchecked operations eliminates an entire
 * class of bugs, so it's recommended to use it always.
 */
library SafeMath {
    /**
     * @dev Returns the addition of two unsigned integers, with an overflow flag.
     *
     * _Available since v3.4._
     */
    function tryAdd(uint256 a, uint256 b) internal pure returns (bool, uint256) {
        uint256 c = a + b;
        if (c < a) return (false, 0);
        return (true, c);
    }

    /**
     * @dev Returns the substraction of two unsigned integers, with an overflow flag.
     *
     * _Available since v3.4._
     */
    function trySub(uint256 a, uint256 b) internal pure returns (bool, uint256) {
        if (b > a) return (false, 0);
        return (true, a - b);
    }

    /**
     * @dev Returns the multiplication of two unsigned integers, with an overflow flag.
     *
     * _Available since v3.4._
     */
    function tryMul(uint256 a, uint256 b) internal pure returns (bool, uint256) {
        // Gas optimization: this is cheaper than requiring 'a' not being zero, but the
        // benefit is lost if 'b' is also tested.
        // See: https://github.com/OpenZeppelin/openzeppelin-contracts/pull/522
        if (a == 0) return (true, 0);
        uint256 c = a * b;
        if (c / a != b) return (false, 0);
        return (true, c);
    }

    /**
     * @dev Returns the division of two unsigned integers, with a division by zero flag.
     *
     * _Available since v3.4._
     */
    function tryDiv(uint256 a, uint256 b) internal pure returns (bool, uint256) {
        if (b == 0) return (false, 0);
        return (true, a / b);
    }

    /**
     * @dev Returns the remainder of dividing two unsigned integers, with a division by zero flag.
     *
     * _Available since v3.4._
     */
    function tryMod(uint256 a, uint256 b) internal pure returns (bool, uint256) {
        if (b == 0) return (false, 0);
        return (true, a % b);
    }

    /**
     * @dev Returns the addition of two unsigned integers, reverting on
     * overflow.
     *
     * Counterpart to Solidity's `+` operator.
     *
     * Requirements:
     *
     * - Addition cannot overflow.
     */
    function add(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 c = a + b;
        require(c >= a, "SafeMath: addition overflow");
        return c;
    }

    /**
     * @dev Returns the subtraction of two unsigned integers, reverting on
     * overflow (when the result is negative).
     *
     * Counterpart to Solidity's `-` operator.
     *
     * Requirements:
     *
     * - Subtraction cannot overflow.
     */
    function sub(uint256 a, uint256 b) internal pure returns (uint256) {
        require(b <= a, "SafeMath: subtraction overflow");
        return a - b;
    }

    /**
     * @dev Returns the multiplication of two unsigned integers, reverting on
     * overflow.
     *
     * Counterpart to Solidity's `*` operator.
     *
     * Requirements:
     *
     * - Multiplication cannot overflow.
     */
    function mul(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a == 0) return 0;
        uint256 c = a * b;
        require(c / a == b, "SafeMath: multiplication overflow");
        return c;
    }

    /**
     * @dev Returns the integer division of two unsigned integers, reverting on
     * division by zero. The result is rounded towards zero.
     *
     * Counterpart to Solidity's `/` operator. Note: this function uses a
     * `revert` opcode (which leaves remaining gas untouched) while Solidity
     * uses an invalid opcode to revert (consuming all remaining gas).
     *
     * Requirements:
     *
     * - The divisor cannot be zero.
     */
    function div(uint256 a, uint256 b) internal pure returns (uint256) {
        require(b > 0, "SafeMath: division by zero");
        return a / b;
    }

    /**
     * @dev Returns the remainder of dividing two unsigned integers. (unsigned integer modulo),
     * reverting when dividing by zero.
     *
     * Counterpart to Solidity's `%` operator. This function uses a `revert`
     * opcode (which leaves remaining gas untouched) while Solidity uses an
     * invalid opcode to revert (consuming all remaining gas).
     *
     * Requirements:
     *
     * - The divisor cannot be zero.
     */
    function mod(uint256 a, uint256 b) internal pure returns (uint256) {
        require(b > 0, "SafeMath: modulo by zero");
        return a % b;
    }

    /**
     * @dev Returns the subtraction of two unsigned integers, reverting with custom message on
     * overflow (when the result is negative).
     *
     * CAUTION: This function is deprecated because it requires allocating memory for the error
     * message unnecessarily. For custom revert reasons use {trySub}.
     *
     * Counterpart to Solidity's `-` operator.
     *
     * Requirements:
     *
     * - Subtraction cannot overflow.
     */
    function sub(uint256 a, uint256 b, string memory errorMessage) internal pure returns (uint256) {
        require(b <= a, errorMessage);
        return a - b;
    }

    /**
     * @dev Returns the integer division of two unsigned integers, reverting with custom message on
     * division by zero. The result is rounded towards zero.
     *
     * CAUTION: This function is deprecated because it requires allocating memory for the error
     * message unnecessarily. For custom revert reasons use {tryDiv}.
     *
     * Counterpart to Solidity's `/` operator. Note: this function uses a
     * `revert` opcode (which leaves remaining gas untouched) while Solidity
     * uses an invalid opcode to revert (consuming all remaining gas).
     *
     * Requirements:
     *
     * - The divisor cannot be zero.
     */
    function div(uint256 a, uint256 b, string memory errorMessage) internal pure returns (uint256) {
        require(b > 0, errorMessage);
        return a / b;
    }

    /**
     * @dev Returns the remainder of dividing two unsigned integers. (unsigned integer modulo),
     * reverting with custom message when dividing by zero.
     *
     * CAUTION: This function is deprecated because it requires allocating memory for the error
     * message unnecessarily. For custom revert reasons use {tryMod}.
     *
     * Counterpart to Solidity's `%` operator. This function uses a `revert`
     * opcode (which leaves remaining gas untouched) while Solidity uses an
     * invalid opcode to revert (consuming all remaining gas).
     *
     * Requirements:
     *
     * - The divisor cannot be zero.
     */
    function mod(uint256 a, uint256 b, string memory errorMessage) internal pure returns (uint256) {
        require(b > 0, errorMessage);
        return a % b;
    }
}

// SPDX-License-Identifier: MIT

pragma solidity >=0.6.0 <0.8.0;

/**
 * @dev Interface of the ERC20 standard as defined in the EIP.
 */
interface IERC20 {
    /**
     * @dev Returns the amount of tokens in existence.
     */
    function totalSupply() external view returns (uint256);

    /**
     * @dev Returns the amount of tokens owned by `account`.
     */
    function balanceOf(address account) external view returns (uint256);

    /**
     * @dev Moves `amount` tokens from the caller's account to `recipient`.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * Emits a {Transfer} event.
     */
    function transfer(address recipient, uint256 amount) external returns (bool);

    /**
     * @dev Returns the remaining number of tokens that `spender` will be
     * allowed to spend on behalf of `owner` through {transferFrom}. This is
     * zero by default.
     *
     * This value changes when {approve} or {transferFrom} are called.
     */
    function allowance(address owner, address spender) external view returns (uint256);

    /**
     * @dev Sets `amount` as the allowance of `spender` over the caller's tokens.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * IMPORTANT: Beware that changing an allowance with this method brings the risk
     * that someone may use both the old and the new allowance by unfortunate
     * transaction ordering. One possible solution to mitigate this race
     * condition is to first reduce the spender's allowance to 0 and set the
     * desired value afterwards:
     * https://github.com/ethereum/EIPs/issues/20#issuecomment-263524729
     *
     * Emits an {Approval} event.
     */
    function approve(address spender, uint256 amount) external returns (bool);

    /**
     * @dev Moves `amount` tokens from `sender` to `recipient` using the
     * allowance mechanism. `amount` is then deducted from the caller's
     * allowance.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * Emits a {Transfer} event.
     */
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);

    /**
     * @dev Emitted when `value` tokens are moved from one account (`from`) to
     * another (`to`).
     *
     * Note that `value` may be zero.
     */
    event Transfer(address indexed from, address indexed to, uint256 value);

    /**
     * @dev Emitted when the allowance of a `spender` for an `owner` is set by
     * a call to {approve}. `value` is the new allowance.
     */
    event Approval(address indexed owner, address indexed spender, uint256 value);
}

// SPDX-License-Identifier: MIT

pragma solidity >=0.6.0 <0.8.0;

import "./IERC20.sol";
import "../../math/SafeMath.sol";
import "../../utils/Address.sol";

/**
 * @title SafeERC20
 * @dev Wrappers around ERC20 operations that throw on failure (when the token
 * contract returns false). Tokens that return no value (and instead revert or
 * throw on failure) are also supported, non-reverting calls are assumed to be
 * successful.
 * To use this library you can add a `using SafeERC20 for IERC20;` statement to your contract,
 * which allows you to call the safe operations as `token.safeTransfer(...)`, etc.
 */
library SafeERC20 {
    using SafeMath for uint256;
    using Address for address;

    function safeTransfer(IERC20 token, address to, uint256 value) internal {
        _callOptionalReturn(token, abi.encodeWithSelector(token.transfer.selector, to, value));
    }

    function safeTransferFrom(IERC20 token, address from, address to, uint256 value) internal {
        _callOptionalReturn(token, abi.encodeWithSelector(token.transferFrom.selector, from, to, value));
    }

    /**
     * @dev Deprecated. This function has issues similar to the ones found in
     * {IERC20-approve}, and its usage is discouraged.
     *
     * Whenever possible, use {safeIncreaseAllowance} and
     * {safeDecreaseAllowance} instead.
     */
    function safeApprove(IERC20 token, address spender, uint256 value) internal {
        // safeApprove should only be called when setting an initial allowance,
        // or when resetting it to zero. To increase and decrease it, use
        // 'safeIncreaseAllowance' and 'safeDecreaseAllowance'
        // solhint-disable-next-line max-line-length
        require((value == 0) || (token.allowance(address(this), spender) == 0),
            "SafeERC20: approve from non-zero to non-zero allowance"
        );
        _callOptionalReturn(token, abi.encodeWithSelector(token.approve.selector, spender, value));
    }

    function safeIncreaseAllowance(IERC20 token, address spender, uint256 value) internal {
        uint256 newAllowance = token.allowance(address(this), spender).add(value);
        _callOptionalReturn(token, abi.encodeWithSelector(token.approve.selector, spender, newAllowance));
    }

    function safeDecreaseAllowance(IERC20 token, address spender, uint256 value) internal {
        uint256 newAllowance = token.allowance(address(this), spender).sub(value, "SafeERC20: decreased allowance below zero");
        _callOptionalReturn(token, abi.encodeWithSelector(token.approve.selector, spender, newAllowance));
    }

    /**
     * @dev Imitates a Solidity high-level call (i.e. a regular function call to a contract), relaxing the requirement
     * on the return value: the return value is optional (but if data is returned, it must not be false).
     * @param token The token targeted by the call.
     * @param data The call data (encoded using abi.encode or one of its variants).
     */
    function _callOptionalReturn(IERC20 token, bytes memory data) private {
        // We need to perform a low level call here, to bypass Solidity's return data size checking mechanism, since
        // we're implementing it ourselves. We use {Address.functionCall} to perform this call, which verifies that
        // the target address contains contract code and also asserts for success in the low-level call.

        bytes memory returndata = address(token).functionCall(data, "SafeERC20: low-level call failed");
        if (returndata.length > 0) { // Return data is optional
            // solhint-disable-next-line max-line-length
            require(abi.decode(returndata, (bool)), "SafeERC20: ERC20 operation did not succeed");
        }
    }
}

// SPDX-License-Identifier: MIT

pragma solidity >=0.6.2 <0.8.0;

/**
 * @dev Collection of functions related to the address type
 */
library Address {
    /**
     * @dev Returns true if `account` is a contract.
     *
     * [IMPORTANT]
     * ====
     * It is unsafe to assume that an address for which this function returns
     * false is an externally-owned account (EOA) and not a contract.
     *
     * Among others, `isContract` will return false for the following
     * types of addresses:
     *
     *  - an externally-owned account
     *  - a contract in construction
     *  - an address where a contract will be created
     *  - an address where a contract lived, but was destroyed
     * ====
     */
    function isContract(address account) internal view returns (bool) {
        // This method relies on extcodesize, which returns 0 for contracts in
        // construction, since the code is only stored at the end of the
        // constructor execution.

        uint256 size;
        // solhint-disable-next-line no-inline-assembly
        assembly { size := extcodesize(account) }
        return size > 0;
    }

    /**
     * @dev Replacement for Solidity's `transfer`: sends `amount` wei to
     * `recipient`, forwarding all available gas and reverting on errors.
     *
     * https://eips.ethereum.org/EIPS/eip-1884[EIP1884] increases the gas cost
     * of certain opcodes, possibly making contracts go over the 2300 gas limit
     * imposed by `transfer`, making them unable to receive funds via
     * `transfer`. {sendValue} removes this limitation.
     *
     * https://diligence.consensys.net/posts/2019/09/stop-using-soliditys-transfer-now/[Learn more].
     *
     * IMPORTANT: because control is transferred to `recipient`, care must be
     * taken to not create reentrancy vulnerabilities. Consider using
     * {ReentrancyGuard} or the
     * https://solidity.readthedocs.io/en/v0.5.11/security-considerations.html#use-the-checks-effects-interactions-pattern[checks-effects-interactions pattern].
     */
    function sendValue(address payable recipient, uint256 amount) internal {
        require(address(this).balance >= amount, "Address: insufficient balance");

        // solhint-disable-next-line avoid-low-level-calls, avoid-call-value
        (bool success, ) = recipient.call{ value: amount }("");
        require(success, "Address: unable to send value, recipient may have reverted");
    }

    /**
     * @dev Performs a Solidity function call using a low level `call`. A
     * plain`call` is an unsafe replacement for a function call: use this
     * function instead.
     *
     * If `target` reverts with a revert reason, it is bubbled up by this
     * function (like regular Solidity function calls).
     *
     * Returns the raw returned data. To convert to the expected return value,
     * use https://solidity.readthedocs.io/en/latest/units-and-global-variables.html?highlight=abi.decode#abi-encoding-and-decoding-functions[`abi.decode`].
     *
     * Requirements:
     *
     * - `target` must be a contract.
     * - calling `target` with `data` must not revert.
     *
     * _Available since v3.1._
     */
    function functionCall(address target, bytes memory data) internal returns (bytes memory) {
      return functionCall(target, data, "Address: low-level call failed");
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-}[`functionCall`], but with
     * `errorMessage` as a fallback revert reason when `target` reverts.
     *
     * _Available since v3.1._
     */
    function functionCall(address target, bytes memory data, string memory errorMessage) internal returns (bytes memory) {
        return functionCallWithValue(target, data, 0, errorMessage);
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-}[`functionCall`],
     * but also transferring `value` wei to `target`.
     *
     * Requirements:
     *
     * - the calling contract must have an ETH balance of at least `value`.
     * - the called Solidity function must be `payable`.
     *
     * _Available since v3.1._
     */
    function functionCallWithValue(address target, bytes memory data, uint256 value) internal returns (bytes memory) {
        return functionCallWithValue(target, data, value, "Address: low-level call with value failed");
    }

    /**
     * @dev Same as {xref-Address-functionCallWithValue-address-bytes-uint256-}[`functionCallWithValue`], but
     * with `errorMessage` as a fallback revert reason when `target` reverts.
     *
     * _Available since v3.1._
     */
    function functionCallWithValue(address target, bytes memory data, uint256 value, string memory errorMessage) internal returns (bytes memory) {
        require(address(this).balance >= value, "Address: insufficient balance for call");
        require(isContract(target), "Address: call to non-contract");

        // solhint-disable-next-line avoid-low-level-calls
        (bool success, bytes memory returndata) = target.call{ value: value }(data);
        return _verifyCallResult(success, returndata, errorMessage);
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-}[`functionCall`],
     * but performing a static call.
     *
     * _Available since v3.3._
     */
    function functionStaticCall(address target, bytes memory data) internal view returns (bytes memory) {
        return functionStaticCall(target, data, "Address: low-level static call failed");
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-string-}[`functionCall`],
     * but performing a static call.
     *
     * _Available since v3.3._
     */
    function functionStaticCall(address target, bytes memory data, string memory errorMessage) internal view returns (bytes memory) {
        require(isContract(target), "Address: static call to non-contract");

        // solhint-disable-next-line avoid-low-level-calls
        (bool success, bytes memory returndata) = target.staticcall(data);
        return _verifyCallResult(success, returndata, errorMessage);
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-}[`functionCall`],
     * but performing a delegate call.
     *
     * _Available since v3.4._
     */
    function functionDelegateCall(address target, bytes memory data) internal returns (bytes memory) {
        return functionDelegateCall(target, data, "Address: low-level delegate call failed");
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-string-}[`functionCall`],
     * but performing a delegate call.
     *
     * _Available since v3.4._
     */
    function functionDelegateCall(address target, bytes memory data, string memory errorMessage) internal returns (bytes memory) {
        require(isContract(target), "Address: delegate call to non-contract");

        // solhint-disable-next-line avoid-low-level-calls
        (bool success, bytes memory returndata) = target.delegatecall(data);
        return _verifyCallResult(success, returndata, errorMessage);
    }

    function _verifyCallResult(bool success, bytes memory returndata, string memory errorMessage) private pure returns(bytes memory) {
        if (success) {
            return returndata;
        } else {
            // Look for revert reason and bubble it up if present
            if (returndata.length > 0) {
                // The easiest way to bubble the revert reason is using memory via assembly

                // solhint-disable-next-line no-inline-assembly
                assembly {
                    let returndata_size := mload(returndata)
                    revert(add(32, returndata), returndata_size)
                }
            } else {
                revert(errorMessage);
            }
        }
    }
}

// SPDX-License-Identifier: MIT

pragma solidity >=0.6.0 <0.8.0;

/*
 * @dev Provides information about the current execution context, including the
 * sender of the transaction and its data. While these are generally available
 * via msg.sender and msg.data, they should not be accessed in such a direct
 * manner, since when dealing with GSN meta-transactions the account sending and
 * paying for execution may not be the actual sender (as far as an application
 * is concerned).
 *
 * This contract is only required for intermediate, library-like contracts.
 */
abstract contract Context {
    function _msgSender() internal view virtual returns (address payable) {
        return msg.sender;
    }

    function _msgData() internal view virtual returns (bytes memory) {
        this; // silence state mutability warning without generating bytecode - see https://github.com/ethereum/solidity/issues/2691
        return msg.data;
    }
}

{
  "remappings": [],
  "optimizer": {
    "enabled": true,
    "runs": 200
  },
  "evmVersion": "istanbul",
  "libraries": {},
  "outputSelection": {
    "*": {
      "*": [
        "evm.bytecode",
        "evm.deployedBytecode",
        "abi"
      ]
    }
  }
}