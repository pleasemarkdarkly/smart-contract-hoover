// SPDX-License-Identifier: MIT

pragma solidity =0.6.12;

import './libraries/SafeMath.sol';
import './libraries/TransferHelper.sol';
import './interfaces/IERC20.sol';
import './interfaces/IWETH.sol';
import './interfaces/ICentaurFactory.sol';
import './interfaces/ICentaurPool.sol';
import './interfaces/ICentaurRouter.sol';

contract CentaurRouter is ICentaurRouter {
	using SafeMath for uint;

	address public immutable override factory;
    address public immutable override WETH;

    modifier ensure(uint deadline) {
        require(deadline >= block.timestamp, 'CentaurSwap: EXPIRED');
        _;
    }

    constructor(address _factory, address _WETH) public {
        factory = _factory;
        WETH = _WETH;
    }

    receive() external payable {
        assert(msg.sender == WETH); // only accept ETH via fallback from the WETH contract
    }

    // **** ADD LIQUIDITY ****
    function _addLiquidity(
        address _baseToken,
        uint _amount,
        uint _minLiquidity
    ) internal view virtual returns (uint liquidity) {
		ICentaurPool pool = ICentaurPool(ICentaurFactory(factory).getPool(_baseToken));

        uint _totalSupply = pool.totalSupply();
        uint _baseTokenTargetAmount = pool.baseTokenTargetAmount();
        liquidity = _amount;

        if (_totalSupply == 0) {
            liquidity = _amount.add(_baseTokenTargetAmount);
        } else {
            liquidity = _amount.mul(_totalSupply).div(_baseTokenTargetAmount);
        }

    	require(liquidity > _minLiquidity, 'CentaurSwap: INSUFFICIENT_OUTPUT_AMOUNT');
    }

    function addLiquidity(
        address _baseToken,
        uint _amount,
        address _to,
        uint _minLiquidity,
        uint _deadline
    ) external virtual override ensure(_deadline) returns (uint amount, uint liquidity) {
        address pool = ICentaurFactory(factory).getPool(_baseToken);
        require(pool != address(0), 'CentaurSwap: POOL_NOT_FOUND');

        (liquidity) = _addLiquidity(_baseToken, _amount, _minLiquidity);
        
        TransferHelper.safeTransferFrom(_baseToken, msg.sender, pool, _amount);
        liquidity = ICentaurPool(pool).mint(_to);
        require(liquidity > _minLiquidity, 'CentaurSwap: INSUFFICIENT_OUTPUT_AMOUNT');

        return (_amount, liquidity);
    }

    function addLiquidityETH(
        address _to,
        uint _minLiquidity,
        uint _deadline
    ) external virtual override payable ensure(_deadline) returns (uint amount, uint liquidity) {
        address pool = ICentaurFactory(factory).getPool(WETH);
        require(pool != address(0), 'CentaurSwap: POOL_NOT_FOUND');

        IWETH(WETH).deposit{value: msg.value}();
        assert(IWETH(WETH).transfer(pool, msg.value));
        liquidity = ICentaurPool(pool).mint(_to);

        require(liquidity > _minLiquidity, 'CentaurSwap: INSUFFICIENT_OUTPUT_AMOUNT');
        
        return (msg.value, liquidity);
    }

    function removeLiquidity(
        address _baseToken,
        uint _liquidity,
        address _to,
        uint _minAmount,
        uint _deadline
    ) public virtual override ensure(_deadline) returns (uint amount) {
        address pool = ICentaurFactory(factory).getPool(_baseToken);
        require(pool != address(0), 'CentaurSwap: POOL_NOT_FOUND');

        ICentaurPool(pool).transferFrom(msg.sender, pool, _liquidity); // send liquidity to pool
        amount = ICentaurPool(pool).burn(_to);
        require(amount > _minAmount, 'CentaurSwap: INSUFFICIENT_OUTPUT_AMOUNT');

        return amount;
    }

    function removeLiquidityETH(
        uint _liquidity,
        address _to,
        uint _minAmount,
        uint _deadline
    ) public virtual override ensure(_deadline) returns (uint amount) {
        amount = removeLiquidity(
            WETH,
            _liquidity,
            address(this),
            _minAmount,
            _deadline
        );

        IWETH(WETH).withdraw(amount);
        TransferHelper.safeTransferETH(_to, amount);

        return amount;
    }

    function swapExactTokensForTokens(
        address _fromToken,
        uint _amountIn,
        address _toToken,
        uint _amountOutMin,
        address _to,
        uint _deadline
    ) external virtual override ensure(_deadline) returns (uint amount) {
        require(getAmountOut(_fromToken, _toToken, _amountIn) >= _amountOutMin, 'CentaurSwap: INSUFFICIENT_OUTPUT_AMOUNT');
        
        (address inputTokenPool, address outputTokenPool) = validatePools(_fromToken, _toToken);

        TransferHelper.safeTransferFrom(_fromToken, msg.sender, inputTokenPool, _amountIn);

        (uint finalAmountIn, uint value) = ICentaurPool(inputTokenPool).swapFrom(msg.sender);
        amount = ICentaurPool(outputTokenPool).swapTo(msg.sender, _fromToken, finalAmountIn, value, _to);
    }

    function swapTokensForExactTokens(
        address _fromToken,
        uint _amountInMax,
        address _toToken,
        uint _amountOut,
        address _to,
        uint _deadline
    ) external virtual override ensure(_deadline) returns (uint amount) {
        uint amountIn = getAmountIn(_fromToken, _toToken, _amountOut);
        require(amountIn <= _amountInMax, 'CentaurSwap: EXCESSIVE_INPUT_AMOUNT');
        
        (address inputTokenPool, address outputTokenPool) = validatePools(_fromToken, _toToken);

        TransferHelper.safeTransferFrom(_fromToken, msg.sender, inputTokenPool, amountIn);

        (uint finalAmountIn, uint value) = ICentaurPool(inputTokenPool).swapFrom(msg.sender);
        amount = ICentaurPool(outputTokenPool).swapTo(msg.sender, _fromToken, finalAmountIn, value, _to);
    }

    function swapSettle(address _sender, address _pool) external virtual override returns (uint amount) {
        amount = ICentaurPool(_pool).swapSettle(_sender);
    }

    function swapSettleMultiple(address _sender, address[] memory _pools) external virtual override {
        for(uint i = 0; i < _pools.length; i++) {
            ICentaurPool(_pools[i]).swapSettle(_sender);
        }
    }

    function validatePools(address _fromToken, address _toToken) public view virtual override returns (address inputTokenPool, address outputTokenPool) {
        inputTokenPool = ICentaurFactory(factory).getPool(_fromToken);
        require(inputTokenPool != address(0), 'CentaurSwap: POOL_NOT_FOUND');

        outputTokenPool = ICentaurFactory(factory).getPool(_toToken);
        require(outputTokenPool != address(0), 'CentaurSwap: POOL_NOT_FOUND');

        return (inputTokenPool, outputTokenPool);
    } 

    function getAmountOut(
        address _fromToken,
        address _toToken,
        uint _amountIn
    ) public view virtual override returns (uint amountOut) {
        uint poolFee = ICentaurFactory(factory).poolFee();
        uint value = ICentaurPool(ICentaurFactory(factory).getPool(_fromToken)).getValueFromAmountIn(_amountIn);
        uint amountOutBeforeFees = ICentaurPool(ICentaurFactory(factory).getPool(_toToken)).getAmountOutFromValue(value);
        amountOut = (amountOutBeforeFees).mul(uint(100 ether).sub(poolFee)).div(100 ether);
    }

    function getAmountIn(
        address _fromToken,
        address _toToken,
        uint _amountOut
    ) public view virtual override returns (uint amountIn) {
        uint poolFee = ICentaurFactory(factory).poolFee();
        uint amountOut = _amountOut.mul(100 ether).div(uint(100 ether).sub(poolFee));
        uint value = ICentaurPool(ICentaurFactory(factory).getPool(_toToken)).getValueFromAmountOut(amountOut);
        amountIn = ICentaurPool(ICentaurFactory(factory).getPool(_fromToken)).getAmountInFromValue(value);
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
        return sub(a, b, "SafeMath: subtraction overflow");
    }

    /**
     * @dev Returns the subtraction of two unsigned integers, reverting with custom message on
     * overflow (when the result is negative).
     *
     * Counterpart to Solidity's `-` operator.
     *
     * Requirements:
     *
     * - Subtraction cannot overflow.
     */
    function sub(uint256 a, uint256 b, string memory errorMessage) internal pure returns (uint256) {
        require(b <= a, errorMessage);
        uint256 c = a - b;

        return c;
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
        // Gas optimization: this is cheaper than requiring 'a' not being zero, but the
        // benefit is lost if 'b' is also tested.
        // See: https://github.com/OpenZeppelin/openzeppelin-contracts/pull/522
        if (a == 0) {
            return 0;
        }

        uint256 c = a * b;
        require(c / a == b, "SafeMath: multiplication overflow");

        return c;
    }

    /**
     * @dev Returns the integer division of two unsigned integers. Reverts on
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
        return div(a, b, "SafeMath: division by zero");
    }

    /**
     * @dev Returns the integer division of two unsigned integers. Reverts with custom message on
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
    function div(uint256 a, uint256 b, string memory errorMessage) internal pure returns (uint256) {
        require(b > 0, errorMessage);
        uint256 c = a / b;
        // assert(a == b * c + a % b); // There is no case in which this doesn't hold

        return c;
    }

    /**
     * @dev Returns the remainder of dividing two unsigned integers. (unsigned integer modulo),
     * Reverts when dividing by zero.
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
        return mod(a, b, "SafeMath: modulo by zero");
    }

    /**
     * @dev Returns the remainder of dividing two unsigned integers. (unsigned integer modulo),
     * Reverts with custom message when dividing by zero.
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
        require(b != 0, errorMessage);
        return a % b;
    }
}

// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity >=0.6.0;

// helper methods for interacting with ERC20 tokens and sending ETH that do not consistently return true/false
library TransferHelper {
    function safeApprove(address token, address to, uint value) internal {
        // bytes4(keccak256(bytes('approve(address,uint256)')));
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(0x095ea7b3, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), 'TransferHelper: APPROVE_FAILED');
    }

    function safeTransfer(address token, address to, uint value) internal {
        // bytes4(keccak256(bytes('transfer(address,uint256)')));
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(0xa9059cbb, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), 'TransferHelper: TRANSFER_FAILED');
    }

    function safeTransferFrom(address token, address from, address to, uint value) internal {
        // bytes4(keccak256(bytes('transferFrom(address,address,uint256)')));
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(0x23b872dd, from, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), 'TransferHelper: TRANSFER_FROM_FAILED');
    }

    function safeTransferETH(address to, uint value) internal {
        (bool success,) = to.call{value:value}(new bytes(0));
        require(success, 'TransferHelper: ETH_TRANSFER_FAILED');
    }
}

// SPDX-License-Identifier: MIT

pragma solidity >=0.6.0 <0.8.0;

/**
 * @dev Interface of the ERC20 standard as defined in the EIP.
 */
interface IERC20 {
    function symbol() external pure returns (string memory);
    /**
     * @dev Returns the token decimal.
     */
    function decimals() external pure returns (uint8);

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

pragma solidity >=0.5.0;

interface IWETH {
    function deposit() external payable;
    function transfer(address to, uint value) external returns (bool);
    function withdraw(uint) external;
}

// SPDX-License-Identifier: MIT

pragma solidity >=0.5.0;

interface ICentaurFactory {
    event PoolCreated(address indexed token, address pool, uint);

    function poolFee() external view returns (uint);

    function poolLogic() external view returns (address);
    function cloneFactory() external view returns (address);
    function settlement() external view returns (address);
    function router() external view returns (address);

    function getPool(address token) external view returns (address pool);
    function allPools(uint) external view returns (address pool);
    function allPoolsLength() external view returns (uint);
    function isValidPool(address pool) external view returns (bool);

    function createPool(address token, address oracle, uint poolUtilizationPercentage) external returns (address pool);
    function addPool(address pool) external;
    function removePool(address pool) external;

    function setPoolLiquidityParameter(address, uint) external;
    function setPoolTradeEnabled(address, bool) external;
    function setPoolDepositEnabled(address, bool) external;
    function setPoolWithdrawEnabled(address, bool) external;
    function setAllPoolsTradeEnabled(bool) external;
    function setAllPoolsDepositEnabled(bool) external;
    function setAllPoolsWithdrawEnabled(bool) external;

    function emergencyWithdrawFromPool(address, address, uint, address) external;

    function setPoolFee(uint) external;
    function setPoolLogic(address) external;
    function setCloneFactory(address) external;
    function setSettlement(address) external;
    function setRouter(address) external;
}

// SPDX-License-Identifier: MIT

pragma solidity >=0.5.0;

interface ICentaurPool {
    event Approval(address indexed owner, address indexed spender, uint value);
    event Transfer(address indexed from, address indexed to, uint value);

    function name() external pure returns (string memory);
    function symbol() external pure returns (string memory);
    function decimals() external pure returns (uint8);
    function totalSupply() external view returns (uint);
    function balanceOf(address owner) external view returns (uint);
    function allowance(address owner, address spender) external view returns (uint);

    function approve(address spender, uint value) external returns (bool);
    function transfer(address to, uint value) external returns (bool);
    function transferFrom(address from, address to, uint value) external returns (bool);

    event Mint(address indexed sender, uint amount);
    event Burn(address indexed sender, uint amount, address indexed to);
    event AmountIn(address indexed sender, uint amount);
    event AmountOut(address indexed sender, uint amount, address indexed to);
    event EmergencyWithdraw(uint256 _timestamp, address indexed _token, uint256 _amount, address indexed _to);

    function factory() external view returns (address);
    function settlement() external view returns (address);
    function baseToken() external view returns (address);
    function baseTokenDecimals() external view returns (uint);
    function oracle() external view returns (address);
    function oracleDecimals() external view returns (uint);
    function baseTokenTargetAmount() external view returns (uint);
    function baseTokenBalance() external view returns (uint);
    function liquidityParameter() external view returns (uint);

    function init(address, address, address, uint) external;

    function mint(address to) external returns (uint liquidity);
    function burn(address to) external returns (uint amount);

    function swapTo(address _sender, address _fromToken, uint _amountIn, uint _value, address _receiver) external returns (uint maxAmount);
    function swapFrom(address _sender) external returns (uint amount, uint value);
    function swapSettle(address _sender) external returns (uint);

    function getOraclePrice() external view returns (uint price);
    function getAmountOutFromValue(uint _value) external view returns (uint amount);
    function getValueFromAmountIn(uint _amount) external view returns (uint value);
    function getAmountInFromValue(uint _value) external view returns (uint amount);
    function getValueFromAmountOut(uint _amount) external view returns (uint value);

    function setFactory(address) external;
    function setTradeEnabled(bool) external;
    function setDepositEnabled(bool) external;
    function setWithdrawEnabled(bool) external;
    function setLiquidityParameter(uint) external;
    function emergencyWithdraw(address, uint, address) external;
}

// SPDX-License-Identifier: MIT

pragma solidity >=0.6.2;

interface ICentaurRouter {
    function factory() external pure returns (address);
    function WETH() external pure returns (address);

    function addLiquidity(
        address _baseToken,
        uint _amount,
        address _to,
        uint _minLiquidity,
        uint _deadline
    ) external returns (uint amount, uint liquidity);
    function addLiquidityETH(
        address _to,
        uint _minLiquidity,
        uint _deadline
    ) external payable returns (uint amount, uint liquidity);
    function removeLiquidity(
        address _baseToken,
        uint _liquidity,
        address _to,
        uint _minAmount,
        uint _deadline
    ) external returns (uint amount);
    function removeLiquidityETH(
        uint _liquidity,
        address _to,
        uint _minAmount,
        uint _deadline
    ) external returns (uint amount);
    function swapExactTokensForTokens(
        address _fromToken,
        uint _amountIn,
        address _toToken,
        uint _amountOutMin,
        address to,
        uint _deadline
    ) external returns (uint amount);
    function swapTokensForExactTokens(
        address _fromToken,
        uint _amountInMax,
        address _toToken,
        uint _amountOut,
        address _to,
        uint _deadline
    ) external returns (uint amount);
    function swapSettle(address _sender, address _pool) external returns (uint amount);
    function swapSettleMultiple(address _sender, address[] memory _pools) external;
    // function removeLiquidityWithPermit(
    //     address tokenA,
    //     address tokenB,
    //     uint liquidity,
    //     uint amountAMin,
    //     uint amountBMin,
    //     address to,
    //     uint deadline,
    //     bool approveMax, uint8 v, bytes32 r, bytes32 s
    // ) external returns (uint amountA, uint amountB);
    // function removeLiquidityETHWithPermit(
    //     address token,
    //     uint liquidity,
    //     uint amountTokenMin,
    //     uint amountETHMin,
    //     address to,
    //     uint deadline,
    //     bool approveMax, uint8 v, bytes32 r, bytes32 s
    // ) external returns (uint amountToken, uint amountETH);
    
    // function swapExactETHForTokens(uint amountOutMin, address[] calldata path, address to, uint deadline)
    //     external
    //     payable
    //     returns (uint[] memory amounts);
    // function swapTokensForExactETH(uint amountOut, uint amountInMax, address[] calldata path, address to, uint deadline)
    //     external
    //     returns (uint[] memory amounts);
    // function swapExactTokensForETH(uint amountIn, uint amountOutMin, address[] calldata path, address to, uint deadline)
    //     external
    //     returns (uint[] memory amounts);
    // function swapETHForExactTokens(uint amountOut, address[] calldata path, address to, uint deadline)
    //     external
    //     payable
    //     returns (uint[] memory amounts);

    // function quote(uint amountA, uint reserveA, uint reserveB) external pure returns (uint amountB);
    function validatePools(address _fromToken, address _toToken) external view returns (address inputTokenPool, address outputTokenPool);
    function getAmountOut(address _fromToken, address _toToken, uint _amountIn) external view returns (uint amountOut);
    function getAmountIn(address _fromToken, address _toToken, uint _amountOut) external view returns (uint amountIn);
    // function getAmountIn(uint amountOut, uint reserveIn, uint reserveOut) external pure returns (uint amountIn);
    // function getAmountsOut(uint amountIn, address[] calldata path) external view returns (uint[] memory amounts);
    // function getAmountsIn(uint amountOut, address[] calldata path) external view returns (uint[] memory amounts);
}

{
  "optimizer": {
    "enabled": false,
    "runs": 200
  },
  "outputSelection": {
    "*": {
      "*": [
        "evm.bytecode",
        "evm.deployedBytecode",
        "abi"
      ]
    }
  },
  "libraries": {}
}