pragma solidity ^0.6.0;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "./AMMWrapper.sol";
import "./interfaces/ISpender.sol";
import "./interfaces/IUniswapRouterV2.sol";
import "./interfaces/IUniswapV3SwapRouter.sol";
import "./interfaces/IPermanentStorage.sol";
import "./utils/UniswapV3PathLib.sol";

contract AMMWrapperWithPath is AMMWrapper {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    using Path for bytes;

    // Constants do not have storage slot.
    address public constant UNISWAP_V3_ROUTER_ADDRESS = 0xE592427A0AEce92De3Edee1F18E0157C05861564;

    event Swapped(
        TxMetaData,
        Order order
    );

    /************************************************************
    *              Constructor and init functions               *
    *************************************************************/
    constructor (
        address _operator,
        uint256 _subsidyFactor,
        address _userProxy,
        ISpender _spender,
        IPermanentStorage _permStorage,
        IWETH _weth
    ) public AMMWrapper(_operator, _subsidyFactor, _userProxy, _spender, _permStorage, _weth) {}

    /************************************************************
    *                   External functions                      *
    *************************************************************/
    function trade(
        Order memory _order,
        uint256 _feeFactor,
        bytes calldata _sig,
        bytes calldata _makerSpecificData,
        address[] calldata _path
    )
        payable
        external
        nonReentrant
        onlyUserProxy
        returns (uint256) 
    {
        require(_order.deadline >= block.timestamp, "AMMWrapper: expired order");
        TxMetaData memory txMetaData;
        InternalTxData memory internalTxData;

        // These variables are copied straight from function parameters and
        // used to bypass stack too deep error.
        txMetaData.subsidyFactor = uint16(subsidyFactor);
        txMetaData.feeFactor = uint16(_feeFactor);
        internalTxData.makerSpecificData = _makerSpecificData;
        internalTxData.path = _path;
        if (! permStorage.isRelayerValid(tx.origin)) {
            txMetaData.feeFactor = (txMetaData.subsidyFactor > txMetaData.feeFactor) ? txMetaData.subsidyFactor : txMetaData.feeFactor;
            txMetaData.subsidyFactor = 0;
        }

        // Assign trade vairables
        internalTxData.fromEth = (_order.takerAssetAddr == ZERO_ADDRESS || _order.takerAssetAddr == ETH_ADDRESS);
        internalTxData.toEth = (_order.makerAssetAddr == ZERO_ADDRESS || _order.makerAssetAddr == ETH_ADDRESS);
        if(_isCurve(_order.makerAddr)) {
            // PermanetStorage can recognize `ETH_ADDRESS` but not `ZERO_ADDRESS`.
            // Convert it to `ETH_ADDRESS` as passed in `_order.takerAssetAddr` or `_order.makerAssetAddr` might be `ZERO_ADDRESS`.
            internalTxData.takerAssetInternalAddr = internalTxData.fromEth ? ETH_ADDRESS : _order.takerAssetAddr;
            internalTxData.makerAssetInternalAddr = internalTxData.toEth ? ETH_ADDRESS : _order.makerAssetAddr;
        } else {
            internalTxData.takerAssetInternalAddr = internalTxData.fromEth ? address(weth) : _order.takerAssetAddr;
            internalTxData.makerAssetInternalAddr = internalTxData.toEth ? address(weth) : _order.makerAssetAddr;
        }

        txMetaData.transactionHash = _verify(
            _order,
            _sig
        );

        _prepare(_order, internalTxData);

        (txMetaData.source, txMetaData.receivedAmount) = _swapWithPath(
            _order,
            txMetaData,
            internalTxData
        );

        // Settle
        txMetaData.settleAmount = _settle(
            _order,
            txMetaData,
            internalTxData
        );

        emit Swapped(
            txMetaData,
            _order
        );

        return txMetaData.settleAmount;
    }

    /**
     * @dev internal function of `trade`.
     * Used to tell if maker is Curve.
     */
    function _isCurve(address _makerAddr) override internal pure returns (bool) {
        if (
            _makerAddr == UNISWAP_V2_ROUTER_02_ADDRESS ||
            _makerAddr == UNISWAP_V3_ROUTER_ADDRESS ||
            _makerAddr == SUSHISWAP_ROUTER_ADDRESS
        ) return false;
        else return true;
    }

    /**
     * @dev internal function of `trade`.
     * It executes the swap on chosen AMM.
     */
    function _swapWithPath(
        Order memory _order,
        TxMetaData memory _txMetaData,
        InternalTxData memory _internalTxData
    )
        internal
        approveTakerAsset(_internalTxData.takerAssetInternalAddr, _order.makerAddr)
        returns (string memory source, uint256 receivedAmount)
    {
        // Swap
        // minAmount = makerAssetAmount * (10000 - subsidyFactor) / 10000
        uint256 minAmount = _order.makerAssetAmount.mul((BPS_MAX.sub(_txMetaData.subsidyFactor))).div(BPS_MAX);

        if (_order.makerAddr == UNISWAP_V2_ROUTER_02_ADDRESS ||
            _order.makerAddr == SUSHISWAP_ROUTER_ADDRESS) {
            source = (_order.makerAddr == SUSHISWAP_ROUTER_ADDRESS) ? "SushiSwap" : "Uniswap V2";
            // Sushiswap shares the same interface as Uniswap's
            receivedAmount = _tradeUniswapV2TokenToToken(
                _order.makerAddr,
                _internalTxData.takerAssetInternalAddr,
                _internalTxData.makerAssetInternalAddr,
                _order.takerAssetAmount,
                minAmount,
                _order.deadline,
                _internalTxData.path
            );
        } else if (_order.makerAddr == UNISWAP_V3_ROUTER_ADDRESS) {
            receivedAmount = _tradeUniswapV3TokenToToken(
                _order.makerAddr,
                _internalTxData.takerAssetInternalAddr,
                _internalTxData.makerAssetInternalAddr,
                _order.deadline,
                _order.takerAssetAmount,
                minAmount,
                _internalTxData.makerSpecificData
            );
        } else {
            CurveData memory curveData;
            (
                curveData.fromTokenCurveIndex,
                curveData.toTokenCurveIndex,
                curveData.swapMethod,
            ) = permStorage.getCurvePoolInfo(
                _order.makerAddr,
                _internalTxData.takerAssetInternalAddr,
                _internalTxData.makerAssetInternalAddr
            );
            require(curveData.swapMethod != 0,"AMMWrapper: swap method not registered");
            if (curveData.fromTokenCurveIndex > 0 && curveData.toTokenCurveIndex > 0) {
                source = "Curve";
                // Substract index by 1 because indices stored in `permStorage` starts from 1
                curveData.fromTokenCurveIndex = curveData.fromTokenCurveIndex - 1;
                curveData.toTokenCurveIndex = curveData.toTokenCurveIndex - 1;
                // Curve does not return amount swapped so we need to record balance change instead.
                uint256 balanceBeforeTrade = _getSelfBalance(_internalTxData.makerAssetInternalAddr);
                _tradeCurveTokenToToken(
                    _order.makerAddr,
                    curveData.fromTokenCurveIndex,
                    curveData.toTokenCurveIndex,
                    _order.takerAssetAmount,
                    minAmount,
                    curveData.swapMethod
                );
                uint256 balanceAfterTrade = _getSelfBalance(_internalTxData.makerAssetInternalAddr);
                receivedAmount = balanceAfterTrade.sub(balanceBeforeTrade);
            } else {
                revert("AMMWrapper: unsupported makerAddr");
            }
        }
    }

    function _tradeUniswapV2TokenToToken(
        address _makerAddr,
        address _takerAssetAddr,
        address _makerAssetAddr,
        uint256 _takerAssetAmount,
        uint256 _makerAssetAmount,
        uint256 _deadline,
        address[] memory _path
    )
        internal 
        returns (uint256) 
    {
        IUniswapRouterV2 router = IUniswapRouterV2(_makerAddr);
        if (_path.length == 0) {
            _path = new address[](2);
            _path[0] = _takerAssetAddr;
            _path[1] = _makerAssetAddr;
        } else {
            require(_path.length >= 2, "AMMWrapper: path length must be at least two");
            require(_path[0] == _takerAssetAddr, "AMMWrapper: first element of path must match taker asset");
            require(_path[_path.length - 1] == _makerAssetAddr, "AMMWrapper: last element of path must match maker asset");
        }
        uint256[] memory amounts = router.swapExactTokensForTokens(
            _takerAssetAmount,
            _makerAssetAmount,
            _path,
            address(this),
            _deadline
        );
        return amounts[amounts.length - 1];
    }

    function _validateUniswapV3Path(
        bytes memory _path,
        address _takerAssetAddr,
        address _makerAssetAddr
    ) internal {
        (address tokenA, address tokenB, ) = _path.decodeFirstPool();

        if (_path.hasMultiplePools()) {
            _path = _path.skipToken();
            while (_path.hasMultiplePools()) {
                _path = _path.skipToken();
            }
            (, tokenB, ) = _path.decodeFirstPool();
        }

        require(tokenA == _takerAssetAddr, "AMMWrapper: first element of path must match taker asset");
        require(tokenB == _makerAssetAddr, "AMMWrapper: last element of path must match maker asset");
    }

    function _tradeUniswapV3TokenToToken(
        address _makerAddr,
        address _takerAssetAddr,
        address _makerAssetAddr,
        uint256 _deadline,
        uint256 _takerAssetAmount,
        uint256 _makerAssetAmount,
        bytes memory _makerSpecificData
    )
        internal 
        returns (uint256 amountOut) 
    {
        ISwapRouter router = ISwapRouter(_makerAddr);
        // swapType:
        // 1: exactInputSingle, 2: exactInput
        uint8 swapType = uint8(uint256(_makerSpecificData.readBytes32(0)));

        if (swapType == 1) {
            (, uint24 poolFee) = abi.decode(_makerSpecificData, (uint8, uint24));
            ISwapRouter.ExactInputSingleParams memory exactInputSingleParams;
            exactInputSingleParams.tokenIn = _takerAssetAddr;
            exactInputSingleParams.tokenOut = _makerAssetAddr;
            exactInputSingleParams.fee = poolFee;
            exactInputSingleParams.recipient = address(this);
            exactInputSingleParams.deadline = _deadline;
            exactInputSingleParams.amountIn = _takerAssetAmount;
            exactInputSingleParams.amountOutMinimum = _makerAssetAmount;
            exactInputSingleParams.sqrtPriceLimitX96 = 0;

            amountOut = router.exactInputSingle(exactInputSingleParams);
        } else if (swapType == 2) {
            (, bytes memory path) = abi.decode(_makerSpecificData, (uint8, bytes));
            _validateUniswapV3Path(path, _takerAssetAddr, _makerAssetAddr);
            ISwapRouter.ExactInputParams memory exactInputParams;
            exactInputParams.path = path;
            exactInputParams.recipient = address(this);
            exactInputParams.deadline = _deadline;
            exactInputParams.amountIn = _takerAssetAmount;
            exactInputParams.amountOutMinimum = _makerAssetAmount;

            amountOut = router.exactInput(exactInputParams);
        } else {
            revert("AMMWrapper: unsupported UniswapV3 swap type");
        }
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

pragma solidity ^0.6.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "./interfaces/ISpender.sol";
import "./interfaces/IUniswapExchange.sol";
import "./interfaces/IUniswapFactory.sol";
import "./interfaces/IUniswapRouterV2.sol";
import "./interfaces/ICurveFi.sol";
import "./interfaces/IAMM.sol";
import "./interfaces/IWeth.sol";
import "./interfaces/IPermanentStorage.sol";
import "./utils/AMMLibEIP712.sol";
import "./utils/SignatureValidator.sol";

contract AMMWrapper is
    IAMM,
    ReentrancyGuard,
    AMMLibEIP712,
    SignatureValidator
{
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // Constants do not have storage slot.
    string public constant version = "5.2.0";
    uint256 internal constant MAX_UINT = 2**256 - 1;
    uint256 internal constant BPS_MAX = 10000;
    address internal constant ETH_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    address internal constant ZERO_ADDRESS = address(0);
    address public immutable userProxy;
    IWETH public immutable weth;
    IPermanentStorage public immutable permStorage;
    address public constant UNISWAP_V2_ROUTER_02_ADDRESS = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    address public constant SUSHISWAP_ROUTER_ADDRESS = 0xd9e1cE17f2641f24aE83637ab66a2cca9C378B9F;

    // Below are the variables which consume storage slots.
    address public operator;
    uint256 public subsidyFactor;
    ISpender public spender;

    /* Struct and event declaration */
    // Group the local variables together to prevent
    // Compiler error: Stack too deep, try removing local variables.
    struct TxMetaData {
        string source;
        bytes32 transactionHash;
        uint256 settleAmount;
        uint256 receivedAmount;
        uint16 feeFactor;
        uint16 subsidyFactor;
    }

    struct InternalTxData {
        bool fromEth;
        bool toEth;
        address takerAssetInternalAddr;
        address makerAssetInternalAddr;
        address[] path;
        bytes makerSpecificData;
    }

    struct CurveData {
        int128 fromTokenCurveIndex;
        int128 toTokenCurveIndex;
        uint16 swapMethod;
    }

    // Operator events
    event TransferOwnership(address newOperator);
    event UpgradeSpender(address newSpender);
    event SetSubsidyFactor(uint256 newSubisdyFactor);
    event AllowTransfer(address spender);
    event DisallowTransfer(address spender);
    event DepositETH(uint256 ethBalance);

    event Swapped(
        string source,
        bytes32 indexed transactionHash,
        address indexed userAddr,
        address takerAssetAddr,
        uint256 takerAssetAmount,
        address makerAddr,
        address makerAssetAddr,
        uint256 makerAssetAmount,
        address receiverAddr,
        uint256 settleAmount,
        uint256 receivedAmount,
        uint16 feeFactor,
        uint16 subsidyFactor
    );


    receive() external payable {}


    /************************************************************
    *          Access control and ownership management          *
    *************************************************************/
    modifier onlyOperator() {
        require(operator == msg.sender, "AMMWrapper: not the operator");
        _;
    }

    modifier onlyUserProxy() {
        require(address(userProxy) == msg.sender, "AMMWrapper: not the UserProxy contract");
        _;
    }

    function transferOwnership(address _newOperator) external onlyOperator {
        require(_newOperator != address(0), "AMMWrapper: operator can not be zero address");
        operator = _newOperator;

        emit TransferOwnership(_newOperator);
    }

    /************************************************************
    *                 Internal function modifier                *
    *************************************************************/
    modifier approveTakerAsset(address _takerAssetInternalAddr, address _makerAddr) {
        bool isTakerAssetETH = _isInternalAssetETH(_takerAssetInternalAddr);
        if (! isTakerAssetETH) IERC20(_takerAssetInternalAddr).safeApprove(_makerAddr, MAX_UINT);

        _;

        if (! isTakerAssetETH) IERC20(_takerAssetInternalAddr).safeApprove(_makerAddr, 0);
    }

    /************************************************************
    *              Constructor and init functions               *
    *************************************************************/
    constructor (
        address _operator,
        uint256 _subsidyFactor,
        address _userProxy,
        ISpender _spender,
        IPermanentStorage _permStorage,
        IWETH _weth
    ) public {
        operator = _operator;
        subsidyFactor = _subsidyFactor;
        userProxy = _userProxy;
        spender = _spender;
        permStorage = _permStorage;
        weth = _weth;
    }


    /************************************************************
    *           Management functions for Operator               *
    *************************************************************/
    /**
     * @dev set new Spender
     */
    function upgradeSpender(address _newSpender) external onlyOperator {
        require(_newSpender != address(0), "AMMWrapper: spender can not be zero address");
        spender = ISpender(_newSpender);

        emit UpgradeSpender(_newSpender);
    }

    function setSubsidyFactor(uint256 _subsidyFactor) external onlyOperator {
        subsidyFactor = _subsidyFactor;

        emit SetSubsidyFactor(_subsidyFactor);
    }

    /**
     * @dev approve spender to transfer tokens from this contract. This is used to collect fee.
     */
    function setAllowance(address[] calldata _tokenList, address _spender) override external onlyOperator {
        for (uint256 i = 0 ; i < _tokenList.length; i++) {
            IERC20(_tokenList[i]).safeApprove(_spender, MAX_UINT);

            emit AllowTransfer(_spender);
        }
    }

    function closeAllowance(address[] calldata _tokenList, address _spender) override external onlyOperator {
        for (uint256 i = 0 ; i < _tokenList.length; i++) {
            IERC20(_tokenList[i]).safeApprove(_spender, 0);

            emit DisallowTransfer(_spender);
        }
    }

    /**
     * @dev convert collected ETH to WETH
     */
    function depositETH() external onlyOperator {
        uint256 balance = address(this).balance;
        if (balance > 0) {
            weth.deposit{value: balance}();

            emit DepositETH(balance);
        }
    }


    /************************************************************
    *                   External functions                      *
    *************************************************************/
    function trade(
        address _makerAddr,
        address _takerAssetAddr,
        address _makerAssetAddr,
        uint256 _takerAssetAmount,
        uint256 _makerAssetAmount,
        uint256 _feeFactor,
        address _userAddr,
        address payable _receiverAddr,
        uint256 _salt,
        uint256 _deadline,
        bytes calldata _sig
    )
        override
        payable
        external
        nonReentrant
        onlyUserProxy
        returns (uint256) 
    {
        Order memory order = Order(
            _makerAddr,
            _takerAssetAddr,
            _makerAssetAddr,
            _takerAssetAmount,
            _makerAssetAmount,
            _userAddr,
            _receiverAddr,
            _salt,
            _deadline
        );
        require(order.deadline >= block.timestamp, "AMMWrapper: expired order");
        TxMetaData memory txMetaData;
        InternalTxData memory internalTxData;

        // These variables are copied straight from function parameters and
        // used to bypass stack too deep error.
        txMetaData.subsidyFactor = uint16(subsidyFactor);
        txMetaData.feeFactor = uint16(_feeFactor);
        if (! permStorage.isRelayerValid(tx.origin)) {
            txMetaData.feeFactor = (txMetaData.subsidyFactor > txMetaData.feeFactor) ? txMetaData.subsidyFactor : txMetaData.feeFactor;
            txMetaData.subsidyFactor = 0;
        }

        // Assign trade vairables
        internalTxData.fromEth = (order.takerAssetAddr == ZERO_ADDRESS || order.takerAssetAddr == ETH_ADDRESS);
        internalTxData.toEth = (order.makerAssetAddr == ZERO_ADDRESS || order.makerAssetAddr == ETH_ADDRESS);
        if(_isCurve(order.makerAddr)) {
            // PermanetStorage can recognize `ETH_ADDRESS` but not `ZERO_ADDRESS`.
            // Convert it to `ETH_ADDRESS` as passed in `order.takerAssetAddr` or `order.makerAssetAddr` might be `ZERO_ADDRESS`.
            internalTxData.takerAssetInternalAddr = internalTxData.fromEth ? ETH_ADDRESS : order.takerAssetAddr;
            internalTxData.makerAssetInternalAddr = internalTxData.toEth ? ETH_ADDRESS : order.makerAssetAddr;
        } else {
            internalTxData.takerAssetInternalAddr = internalTxData.fromEth ? address(weth) : order.takerAssetAddr;
            internalTxData.makerAssetInternalAddr = internalTxData.toEth ? address(weth) : order.makerAssetAddr;
        }

        txMetaData.transactionHash = _verify(
            order,
            _sig
        );

        _prepare(order, internalTxData);

        (txMetaData.source, txMetaData.receivedAmount) = _swap(
            order,
            txMetaData,
            internalTxData
        );

        // Settle
        txMetaData.settleAmount = _settle(
            order,
            txMetaData,
            internalTxData
        );

        emit Swapped(
            txMetaData.source,
            txMetaData.transactionHash,
            order.userAddr,
            order.takerAssetAddr,
            order.takerAssetAmount,
            order.makerAddr,
            order.makerAssetAddr,
            order.makerAssetAmount,
            order.receiverAddr,
            txMetaData.settleAmount,
            txMetaData.receivedAmount,
            txMetaData.feeFactor,
            txMetaData.subsidyFactor
        );

        return txMetaData.settleAmount;
    }

    /**
     * @dev internal function of `trade`.
     * Used to tell if maker is Curve.
     */
    function _isCurve(address _makerAddr) virtual internal pure returns (bool) {
        if (
            _makerAddr == UNISWAP_V2_ROUTER_02_ADDRESS ||
            _makerAddr == SUSHISWAP_ROUTER_ADDRESS
        ) return false;
        else return true;
    }

    /**
     * @dev internal function of `trade`.
     * Used to tell if internal asset is ETH.
     */
    function _isInternalAssetETH(address _internalAssetAddr) internal pure returns (bool) {
        if (_internalAssetAddr == ETH_ADDRESS || _internalAssetAddr == ZERO_ADDRESS) return true;
        else return false;
    }

    /**
     * @dev internal function of `trade`.
     * Get this contract's eth balance or token balance.
     */
    function _getSelfBalance(address _makerAssetInternalAddr) internal view returns (uint256) {
        if (_isInternalAssetETH(_makerAssetInternalAddr)) {
            return address(this).balance;
        } else {
            return IERC20(_makerAssetInternalAddr).balanceOf(address(this));
        }
    }

    /**
     * @dev internal function of `trade`.
     * It verifies user signature and store tx hash to prevent replay attack.
     */
    function _verify(
        Order memory _order,
        bytes calldata _sig
    ) internal returns (bytes32 transactionHash) {
        // Verify user signature
        // TRADE_WITH_PERMIT_TYPEHASH = keccak256("tradeWithPermit(address makerAddr,address takerAssetAddr,address makerAssetAddr,uint256 takerAssetAmount,uint256 makerAssetAmount,address userAddr,address receiverAddr,uint256 salt,uint256 deadline)");
        transactionHash = keccak256(
            abi.encode(
                TRADE_WITH_PERMIT_TYPEHASH,
                _order.makerAddr,
                _order.takerAssetAddr,
                _order.makerAssetAddr,
                _order.takerAssetAmount,
                _order.makerAssetAmount,
                _order.userAddr,
                _order.receiverAddr,
                _order.salt,
                _order.deadline
            )
        );
        bytes32 EIP712SignDigest = keccak256(
            abi.encodePacked(
                EIP191_HEADER,
                EIP712_DOMAIN_SEPARATOR,
                transactionHash
            )
        );
        require(isValidSignature(_order.userAddr, EIP712SignDigest, bytes(""), _sig), "AMMWrapper: invalid user signature");
        // Set transaction as seen, PermanentStorage would throw error if transaction already seen.
        permStorage.setAMMTransactionSeen(transactionHash);
    }

    /**
     * @dev internal function of `trade`.
     * It executes the swap on chosen AMM.
     */
    function _prepare(Order memory _order, InternalTxData memory _internalTxData) internal {
        // Transfer asset from user and deposit to weth if needed
        if (_internalTxData.fromEth) {
            require(msg.value > 0, "AMMWrapper: msg.value is zero");
            require(_order.takerAssetAmount == msg.value, "AMMWrapper: msg.value doesn't match");
            // Deposit ETH to WETH if internal asset is WETH instead of ETH
            if (! _isInternalAssetETH(_internalTxData.takerAssetInternalAddr)) {
                weth.deposit{value: msg.value}();
            }
        } else {
            // other ERC20 tokens
            spender.spendFromUser(_order.userAddr, _order.takerAssetAddr, _order.takerAssetAmount);
        }
    }

    /**
     * @dev internal function of `trade`.
     * It executes the swap on chosen AMM.
     */
    function _swap(
        Order memory _order,
        TxMetaData memory _txMetaData,
        InternalTxData memory _internalTxData
    )
        internal
        approveTakerAsset(_internalTxData.takerAssetInternalAddr, _order.makerAddr)
        returns (string memory source, uint256 receivedAmount)
    {
        // Swap
        // minAmount = makerAssetAmount * (10000 - subsidyFactor) / 10000
        uint256 minAmount = _order.makerAssetAmount.mul((BPS_MAX.sub(_txMetaData.subsidyFactor))).div(BPS_MAX);

        if (_order.makerAddr == UNISWAP_V2_ROUTER_02_ADDRESS ||
            _order.makerAddr == SUSHISWAP_ROUTER_ADDRESS) {
            source = (_order.makerAddr == SUSHISWAP_ROUTER_ADDRESS) ? "SushiSwap" : "Uniswap V2";
            // Sushiswap shares the same interface as Uniswap's
            receivedAmount = _tradeUniswapV2TokenToToken(
                _order.makerAddr,
                _internalTxData.takerAssetInternalAddr,
                _internalTxData.makerAssetInternalAddr,
                _order.takerAssetAmount,
                minAmount,
                _order.deadline
            );
        } else {
            CurveData memory curveData;
            (
                curveData.fromTokenCurveIndex,
                curveData.toTokenCurveIndex,
                curveData.swapMethod,
            ) = permStorage.getCurvePoolInfo(
                _order.makerAddr,
                _internalTxData.takerAssetInternalAddr,
                _internalTxData.makerAssetInternalAddr
            );
            require(curveData.swapMethod != 0, "AMMWrapper: swap method not registered");
            if (curveData.fromTokenCurveIndex > 0 && curveData.toTokenCurveIndex > 0) {
                source = "Curve";
                // Substract index by 1 because indices stored in `permStorage` starts from 1
                curveData.fromTokenCurveIndex = curveData.fromTokenCurveIndex - 1;
                curveData.toTokenCurveIndex = curveData.toTokenCurveIndex - 1;
                // Curve does not return amount swapped so we need to record balance change instead.
                uint256 balanceBeforeTrade = _getSelfBalance(_internalTxData.makerAssetInternalAddr);
                _tradeCurveTokenToToken(
                    _order.makerAddr,
                    curveData.fromTokenCurveIndex,
                    curveData.toTokenCurveIndex,
                    _order.takerAssetAmount,
                    minAmount,
                    curveData.swapMethod
                );
                uint256 balanceAfterTrade = _getSelfBalance(_internalTxData.makerAssetInternalAddr);
                receivedAmount = balanceAfterTrade.sub(balanceBeforeTrade);
            } else {
                revert("AMMWrapper: unsupported makerAddr");
            }
        }
    }

    /**
     * @dev internal function of `trade`.
     * It collects fee from the trade or compensates the trade based on the actual amount swapped.
     */
    function _settle(
        Order memory _order,
        TxMetaData memory _txMetaData,
        InternalTxData memory _internalTxData
    )
        internal
        returns (uint256 settleAmount)
    {
        // Convert var type from uint16 to uint256
        uint256 _feeFactor = _txMetaData.feeFactor;
        uint256 _subsidyFactor = _txMetaData.subsidyFactor;

        if (_txMetaData.receivedAmount == _order.makerAssetAmount) {
            settleAmount = _txMetaData.receivedAmount;
        } else if (_txMetaData.receivedAmount > _order.makerAssetAmount) {
            // shouldCollectFee = ((receivedAmount - makerAssetAmount) / receivedAmount) > (feeFactor / 10000)
            bool shouldCollectFee = _txMetaData.receivedAmount.sub(_order.makerAssetAmount).mul(BPS_MAX) > _feeFactor.mul(_txMetaData.receivedAmount);
            if (shouldCollectFee) {
                // settleAmount = receivedAmount * (1 - feeFactor) / 10000
                settleAmount = _txMetaData.receivedAmount.mul(BPS_MAX.sub(_feeFactor)).div(BPS_MAX);
            } else {
                settleAmount = _order.makerAssetAmount;
            }
        } else {
            require(_subsidyFactor > 0, "AMMWrapper: this trade will not be subsidized");

            // If fee factor is smaller than subsidy factor, choose fee factor as actual subsidy factor
            // since we should subsidize less if we charge less.
            uint256 actualSubsidyFactor = (_subsidyFactor < _feeFactor) ? _subsidyFactor : _feeFactor;

            // inSubsidyRange = ((makerAssetAmount - receivedAmount) / receivedAmount) > (actualSubsidyFactor / 10000)
            bool inSubsidyRange = _order.makerAssetAmount.sub(_txMetaData.receivedAmount).mul(BPS_MAX) <= actualSubsidyFactor.mul(_txMetaData.receivedAmount);
            require(inSubsidyRange, "AMMWrapper: amount difference larger than subsidy amount");

            uint256 selfBalance = _getSelfBalance(_internalTxData.makerAssetInternalAddr);
            bool hasEnoughToSubsidize = selfBalance >= _order.makerAssetAmount;
            if (! hasEnoughToSubsidize && _isInternalAssetETH(_internalTxData.makerAssetInternalAddr)) {
                // We treat ETH and WETH the same so we have to convert WETH to ETH if ETH balance is not enough.
                uint256 amountShort = _order.makerAssetAmount.sub(selfBalance);
                if (amountShort <= weth.balanceOf(address(this))) {
                    // Withdraw the amount short from WETH
                    weth.withdraw(amountShort);
                    // Now we have enough
                    hasEnoughToSubsidize = true;
                }
            }
            require(hasEnoughToSubsidize, "AMMWrapper: not enough savings to subsidize");

            settleAmount = _order.makerAssetAmount;
        }

        // Transfer token/ETH to receiver
        if (_internalTxData.toEth) {
            // Withdraw from WETH if internal maker asset is WETH
            if (! _isInternalAssetETH(_internalTxData.makerAssetInternalAddr)) {
                weth.withdraw(settleAmount);
            }
            _order.receiverAddr.transfer(settleAmount);
        } else {
            // other ERC20 tokens
            IERC20(_order.makerAssetAddr).safeTransfer(_order.receiverAddr, settleAmount);
        }
    }

    function _tradeCurveTokenToToken(
        address _makerAddr,
        int128 i,
        int128 j,
        uint256 _takerAssetAmount,
        uint256 _makerAssetAmount,
        uint16 swapMethod
    ) 
        internal
    {
        ICurveFi curve = ICurveFi(_makerAddr);
        if (swapMethod == 1) {
            curve.exchange{value: msg.value}(i, j, _takerAssetAmount, _makerAssetAmount);
        } else if (swapMethod == 2) {
            curve.exchange_underlying{value: msg.value}(i, j, _takerAssetAmount, _makerAssetAmount);
        }
    }

    function _tradeUniswapV2TokenToToken(
        address _makerAddr,
        address _takerAssetAddr,
        address _makerAssetAddr,
        uint256 _takerAssetAmount,
        uint256 _makerAssetAmount,
        uint256 _deadline
    )
        internal 
        returns (uint256) 
    {
        IUniswapRouterV2 router = IUniswapRouterV2(_makerAddr);
        address[] memory path = new address[](2);
        path[0] = _takerAssetAddr;
        path[1] = _makerAssetAddr;
        uint256[] memory amounts = router.swapExactTokensForTokens(
            _takerAssetAmount,
            _makerAssetAmount,
            path,
            address(this),
            _deadline
        );
        return amounts[1];
    }
}

pragma solidity ^0.6.0;

interface ISpender {
    function spendFromUser(address _user, address _tokenAddr, uint256 _amount) external;
    function spendFromUserTo(address _user, address _tokenAddr, address _receiverAddr, uint256 _amount) external;
}

// SPDX-License-Identifier: MIT
pragma solidity >=0.5.0 <0.8.0;

interface IUniswapRouterV2 {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    )
        external
        returns (
            uint256 amountA,
            uint256 amountB,
            uint256 liquidity
        );

    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    )
        external
        payable
        returns (
            uint256 amountToken,
            uint256 amountETH,
            uint256 liquidity
        );

    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB);

    function getAmountsOut(uint256 amountIn, address[] calldata path)
        external
        view
        returns (uint256[] memory amounts);

    function getAmountsIn(uint256 amountOut, address[] calldata path)
        external
        view
        returns (uint256[] memory amounts);

    function swapETHForExactTokens(
        uint256 amountOut,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable returns (uint256[] memory amounts);

    function swapExactETHForTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable returns (uint256[] memory amounts);
}

// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0 <0.8.0;
pragma experimental ABIEncoderV2;

import "./IUniswapV3SwapCallback.sol";

/// @title Router token swapping functionality
/// @notice Functions for swapping tokens via Uniswap V3
interface ISwapRouter is IUniswapV3SwapCallback {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    /// @notice Swaps `amountIn` of one token for as much as possible of another token
    /// @param params The parameters necessary for the swap, encoded as `ExactInputSingleParams` in calldata
    /// @return amountOut The amount of the received token
    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);

    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    /// @notice Swaps `amountIn` of one token for as much as possible of another along the specified path
    /// @param params The parameters necessary for the multi-hop swap, encoded as `ExactInputParams` in calldata
    /// @return amountOut The amount of the received token
    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);

    struct ExactOutputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountOut;
        uint256 amountInMaximum;
        uint160 sqrtPriceLimitX96;
    }

    /// @notice Swaps as little as possible of one token for `amountOut` of another token
    /// @param params The parameters necessary for the swap, encoded as `ExactOutputSingleParams` in calldata
    /// @return amountIn The amount of the input token
    function exactOutputSingle(ExactOutputSingleParams calldata params) external payable returns (uint256 amountIn);

    struct ExactOutputParams {
        bytes path;
        address recipient;
        uint256 deadline;
        uint256 amountOut;
        uint256 amountInMaximum;
    }

    /// @notice Swaps as little as possible of one token for `amountOut` of another along the specified path (reversed)
    /// @param params The parameters necessary for the multi-hop swap, encoded as `ExactOutputParams` in calldata
    /// @return amountIn The amount of the input token
    function exactOutput(ExactOutputParams calldata params) external payable returns (uint256 amountIn);
}

pragma solidity ^0.6.0;

interface IPermanentStorage {
    function wethAddr() external view returns (address);
    function getCurvePoolInfo(address _makerAddr, address _takerAssetAddr, address _makerAssetAddr) external view returns (int128 takerAssetIndex, int128 makerAssetIndex, uint16 swapMethod, bool supportGetDx);
    function setCurvePoolInfo(address _makerAddr, address[] calldata _underlyingCoins, address[] calldata _coins, bool _supportGetDx) external;
    function isTransactionSeen(bytes32 _transactionHash) external view returns (bool);  // Kept for backward compatability. Should be removed from AMM 5.2.1 upward
    function isAMMTransactionSeen(bytes32 _transactionHash) external view returns (bool);
    function isRFQTransactionSeen(bytes32 _transactionHash) external view returns (bool);
    function isRelayerValid(address _relayer) external view returns (bool);
    function setTransactionSeen(bytes32 _transactionHash) external;  // Kept for backward compatability. Should be removed from AMM 5.2.1 upward
    function setAMMTransactionSeen(bytes32 _transactionHash) external;
    function setRFQTransactionSeen(bytes32 _transactionHash) external;
    function setRelayersValid(address[] memory _relayers, bool[] memory _isValids) external;
}

// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.6.0;

library BytesLib {
    function slice(
        bytes memory _bytes,
        uint256 _start,
        uint256 _length
    ) internal pure returns (bytes memory) {
        require(_length + 31 >= _length, 'slice_overflow');
        require(_start + _length >= _start, 'slice_overflow');
        require(_bytes.length >= _start + _length, 'slice_outOfBounds');

        bytes memory tempBytes;

        assembly {
            switch iszero(_length)
                case 0 {
                    // Get a location of some free memory and store it in tempBytes as
                    // Solidity does for memory variables.
                    tempBytes := mload(0x40)

                    // The first word of the slice result is potentially a partial
                    // word read from the original array. To read it, we calculate
                    // the length of that partial word and start copying that many
                    // bytes into the array. The first word we copy will start with
                    // data we don't care about, but the last `lengthmod` bytes will
                    // land at the beginning of the contents of the new array. When
                    // we're done copying, we overwrite the full first word with
                    // the actual length of the slice.
                    let lengthmod := and(_length, 31)

                    // The multiplication in the next line is necessary
                    // because when slicing multiples of 32 bytes (lengthmod == 0)
                    // the following copy loop was copying the origin's length
                    // and then ending prematurely not copying everything it should.
                    let mc := add(add(tempBytes, lengthmod), mul(0x20, iszero(lengthmod)))
                    let end := add(mc, _length)

                    for {
                        // The multiplication in the next line has the same exact purpose
                        // as the one above.
                        let cc := add(add(add(_bytes, lengthmod), mul(0x20, iszero(lengthmod))), _start)
                    } lt(mc, end) {
                        mc := add(mc, 0x20)
                        cc := add(cc, 0x20)
                    } {
                        mstore(mc, mload(cc))
                    }

                    mstore(tempBytes, _length)

                    //update free-memory pointer
                    //allocating the array padded to 32 bytes like the compiler does now
                    mstore(0x40, and(add(mc, 31), not(31)))
                }
                //if we want a zero-length slice let's just return a zero-length array
                default {
                    tempBytes := mload(0x40)
                    //zero out the 32 bytes slice we are about to return
                    //we need to do it because Solidity does not garbage collect
                    mstore(tempBytes, 0)

                    mstore(0x40, add(tempBytes, 0x20))
                }
        }

        return tempBytes;
    }

    function toAddress(bytes memory _bytes, uint256 _start) internal pure returns (address) {
        require(_start + 20 >= _start, 'toAddress_overflow');
        require(_bytes.length >= _start + 20, 'toAddress_outOfBounds');
        address tempAddress;

        assembly {
            tempAddress := div(mload(add(add(_bytes, 0x20), _start)), 0x1000000000000000000000000)
        }

        return tempAddress;
    }

    function toUint24(bytes memory _bytes, uint256 _start) internal pure returns (uint24) {
        require(_start + 3 >= _start, 'toUint24_overflow');
        require(_bytes.length >= _start + 3, 'toUint24_outOfBounds');
        uint24 tempUint;

        assembly {
            tempUint := mload(add(add(_bytes, 0x3), _start))
        }

        return tempUint;
    }
}

/// @title Functions for manipulating path data for multihop swaps
library Path {
    using BytesLib for bytes;

    /// @dev The length of the bytes encoded address
    uint256 private constant ADDR_SIZE = 20;
    /// @dev The length of the bytes encoded fee
    uint256 private constant FEE_SIZE = 3;

    /// @dev The offset of a single token address and pool fee
    uint256 private constant NEXT_OFFSET = ADDR_SIZE + FEE_SIZE;
    /// @dev The offset of an encoded pool key
    uint256 private constant POP_OFFSET = NEXT_OFFSET + ADDR_SIZE;
    /// @dev The minimum length of an encoding that contains 2 or more pools
    uint256 private constant MULTIPLE_POOLS_MIN_LENGTH = POP_OFFSET + NEXT_OFFSET;

    /// @notice Returns true iff the path contains two or more pools
    /// @param path The encoded swap path
    /// @return True if path contains two or more pools, otherwise false
    function hasMultiplePools(bytes memory path) internal pure returns (bool) {
        return path.length >= MULTIPLE_POOLS_MIN_LENGTH;
    }

    /// @notice Decodes the first pool in path
    /// @param path The bytes encoded swap path
    /// @return tokenA The first token of the given pool
    /// @return tokenB The second token of the given pool
    /// @return fee The fee level of the pool
    function decodeFirstPool(bytes memory path)
        internal
        pure
        returns (
            address tokenA,
            address tokenB,
            uint24 fee
        )
    {
        tokenA = path.toAddress(0);
        fee = path.toUint24(ADDR_SIZE);
        tokenB = path.toAddress(NEXT_OFFSET);
    }

    /// @notice Skips a token + fee element from the buffer and returns the remainder
    /// @param path The swap path
    /// @return The remaining token + fee elements in the path
    function skipToken(bytes memory path) internal pure returns (bytes memory) {
        return path.slice(NEXT_OFFSET, path.length - NEXT_OFFSET);
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

/**
 * @dev Contract module that helps prevent reentrant calls to a function.
 *
 * Inheriting from `ReentrancyGuard` will make the {nonReentrant} modifier
 * available, which can be applied to functions to make sure there are no nested
 * (reentrant) calls to them.
 *
 * Note that because there is a single `nonReentrant` guard, functions marked as
 * `nonReentrant` may not call one another. This can be worked around by making
 * those functions `private`, and then adding `external` `nonReentrant` entry
 * points to them.
 *
 * TIP: If you would like to learn more about reentrancy and alternative ways
 * to protect against it, check out our blog post
 * https://blog.openzeppelin.com/reentrancy-after-istanbul/[Reentrancy After Istanbul].
 */
abstract contract ReentrancyGuard {
    // Booleans are more expensive than uint256 or any type that takes up a full
    // word because each write operation emits an extra SLOAD to first read the
    // slot's contents, replace the bits taken up by the boolean, and then write
    // back. This is the compiler's defense against contract upgrades and
    // pointer aliasing, and it cannot be disabled.

    // The values being non-zero value makes deployment a bit more expensive,
    // but in exchange the refund on every call to nonReentrant will be lower in
    // amount. Since refunds are capped to a percentage of the total
    // transaction's gas, it is best to keep them low in cases like this one, to
    // increase the likelihood of the full refund coming into effect.
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;

    uint256 private _status;

    constructor () internal {
        _status = _NOT_ENTERED;
    }

    /**
     * @dev Prevents a contract from calling itself, directly or indirectly.
     * Calling a `nonReentrant` function from another `nonReentrant`
     * function is not supported. It is possible to prevent this from happening
     * by making the `nonReentrant` function external, and make it call a
     * `private` function that does the actual work.
     */
    modifier nonReentrant() {
        // On the first call to nonReentrant, _notEntered will be true
        require(_status != _ENTERED, "ReentrancyGuard: reentrant call");

        // Any calls to nonReentrant after this point will fail
        _status = _ENTERED;

        _;

        // By storing the original value once again, a refund is triggered (see
        // https://eips.ethereum.org/EIPS/eip-2200)
        _status = _NOT_ENTERED;
    }
}

pragma solidity >=0.5.0 <0.8.0;

interface IUniswapExchange {
    // Address of ERC20 token sold on this exchange
    function tokenAddress() external view returns (address token);
    // Address of Uniswap Factory
    function factoryAddress() external view returns (address factory);
    // Provide Liquidity
    function addLiquidity(uint256 min_liquidity, uint256 max_tokens, uint256 deadline) external payable returns (uint256);
    function removeLiquidity(uint256 amount, uint256 min_eth, uint256 min_tokens, uint256 deadline) external returns (uint256, uint256);
    // Get Prices
    function getEthToTokenInputPrice(uint256 eth_sold) external view returns (uint256 tokens_bought);
    function getEthToTokenOutputPrice(uint256 tokens_bought) external view returns (uint256 eth_sold);
    function getTokenToEthInputPrice(uint256 tokens_sold) external view returns (uint256 eth_bought);
    function getTokenToEthOutputPrice(uint256 eth_bought) external view returns (uint256 tokens_sold);
    // Trade ETH to ERC20
    function ethToTokenSwapInput(uint256 min_tokens, uint256 deadline) external payable returns (uint256 tokens_bought);
    function ethToTokenTransferInput(uint256 min_tokens, uint256 deadline, address recipient) external payable returns (uint256  tokens_bought);
    function ethToTokenSwapOutput(uint256 tokens_bought, uint256 deadline) external payable returns (uint256  eth_sold);
    function ethToTokenTransferOutput(uint256 tokens_bought, uint256 deadline, address recipient) external payable returns (uint256  eth_sold);
    // Trade ERC20 to ETH
    function tokenToEthSwapInput(uint256 tokens_sold, uint256 min_eth, uint256 deadline) external returns (uint256  eth_bought);
    function tokenToEthTransferInput(uint256 tokens_sold, uint256 min_eth, uint256 deadline, address recipient) external returns (uint256  eth_bought);
    function tokenToEthSwapOutput(uint256 eth_bought, uint256 max_tokens, uint256 deadline) external returns (uint256  tokens_sold);
    function tokenToEthTransferOutput(uint256 eth_bought, uint256 max_tokens, uint256 deadline, address recipient) external returns (uint256  tokens_sold);
    // Trade ERC20 to ERC20
    function tokenToTokenSwapInput(uint256 tokens_sold, uint256 min_tokens_bought, uint256 min_eth_bought, uint256 deadline, address token_addr) external returns (uint256  tokens_bought);
    function tokenToTokenTransferInput(uint256 tokens_sold, uint256 min_tokens_bought, uint256 min_eth_bought, uint256 deadline, address recipient, address token_addr) external returns (uint256  tokens_bought);
    function tokenToTokenSwapOutput(uint256 tokens_bought, uint256 max_tokens_sold, uint256 max_eth_sold, uint256 deadline, address token_addr) external returns (uint256  tokens_sold);
    function tokenToTokenTransferOutput(uint256 tokens_bought, uint256 max_tokens_sold, uint256 max_eth_sold, uint256 deadline, address recipient, address token_addr) external returns (uint256  tokens_sold);
    // Trade ERC20 to Custom Pool
    function tokenToExchangeSwapInput(uint256 tokens_sold, uint256 min_tokens_bought, uint256 min_eth_bought, uint256 deadline, address exchange_addr) external returns (uint256  tokens_bought);
    function tokenToExchangeTransferInput(uint256 tokens_sold, uint256 min_tokens_bought, uint256 min_eth_bought, uint256 deadline, address recipient, address exchange_addr) external returns (uint256  tokens_bought);
    function tokenToExchangeSwapOutput(uint256 tokens_bought, uint256 max_tokens_sold, uint256 max_eth_sold, uint256 deadline, address exchange_addr) external returns (uint256  tokens_sold);
    function tokenToExchangeTransferOutput(uint256 tokens_bought, uint256 max_tokens_sold, uint256 max_eth_sold, uint256 deadline, address recipient, address exchange_addr) external returns (uint256  tokens_sold);
    // ERC20 comaptibility for liquidity tokens
    function name() external view returns (bytes32);
    function symbol() external view returns (bytes32);
    function decimals() external view returns (uint256);
    function transfer(address _to, uint256 _value) external returns (bool);
    function transferFrom(address _from, address _to, uint256 value) external returns (bool);
    function approve(address _spender, uint256 _value) external returns (bool);
    function allowance(address _owner, address _spender) external view returns (uint256);
    function balanceOf(address _owner) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    // Never use
    function setup(address token_addr) external;
}

pragma solidity >=0.5.0 <0.8.0;

interface IUniswapFactory {
    event PairCreated(
        address indexed token0,
        address indexed token1,
        address pair,
        uint256
    );

    function getPair(address tokenA, address tokenB)
        external
        view
        returns (address pair);

    function allPairs(uint256) external view returns (address pair);
    function allPairsLength() external view returns (uint256);
    function feeTo() external view returns (address);
    function feeToSetter() external view returns (address);
    function createPair(address tokenA, address tokenB)
        external
        returns (address pair);

    // Create Exchange
    function createExchange(address token) external returns (address exchange);
    // Get Exchange and Token Info
    function getExchange(address token) external view returns (address exchange);
    function getToken(address exchange) external view returns (address token);
    function getTokenWithId(uint256 tokenId) external view returns (address token);
    // Never use
    function initializeFactory(address template) external;
}

pragma solidity >=0.5.0 <0.8.0;

interface ICurveFi {
    function get_virtual_price() external returns (uint256 out);
    function add_liquidity(
        uint256[2] calldata amounts,
        uint256 deadline
    ) external;

    function add_liquidity(
        // sBTC pool
        uint256[3] calldata amounts,
        uint256 min_mint_amount
    ) external;

    function add_liquidity(
        // bUSD pool
        uint256[4] calldata amounts,
        uint256 min_mint_amount
    ) external;

    function get_dx(
        int128 i,
        int128 j,
        uint256 dy
    ) external view returns (uint256 out);

    function get_dx_underlying(
        int128 i,
        int128 j,
        uint256 dy
    ) external view returns (uint256 out);

    function get_dy(
        int128 i,
        int128 j,
        uint256 dx
    ) external view returns (uint256 out);

    function get_dy_underlying(
        int128 i,
        int128 j,
        uint256 dx
    ) external view returns (uint256 out);

    function exchange(
        int128 i,
        int128 j,
        uint256 dx,
        uint256 min_dy
    ) external payable;

    function exchange(
        int128 i,
        int128 j,
        uint256 dx,
        uint256 min_dy,
        uint256 deadline
    ) external payable;

    function exchange_underlying(
        int128 i,
        int128 j,
        uint256 dx,
        uint256 min_dy
    ) external payable;

    function exchange_underlying(
        int128 i,
        int128 j,
        uint256 dx,
        uint256 min_dy,
        uint256 deadline
    ) external payable;

    function remove_liquidity(
        uint256 _amount,
        uint256 deadline,
        uint256[2] calldata min_amounts
    ) external;

    function remove_liquidity_imbalance(
        uint256[2] calldata amounts,
        uint256 deadline
    ) external;

    function remove_liquidity_imbalance(
        uint256[3] calldata amounts,
        uint256 max_burn_amount
    ) external;

    function remove_liquidity(uint256 _amount, uint256[3] calldata amounts)
        external;

    function remove_liquidity_imbalance(
        uint256[4] calldata amounts,
        uint256 max_burn_amount
    ) external;

    function remove_liquidity(uint256 _amount, uint256[4] calldata amounts)
        external;

    function commit_new_parameters(
        int128 amplification,
        int128 new_fee,
        int128 new_admin_fee
    ) external;

    function apply_new_parameters() external;

    function revert_new_parameters() external;

    function commit_transfer_ownership(address _owner) external;

    function apply_transfer_ownership() external;

    function revert_transfer_ownership() external;

    function withdraw_admin_fees() external;

    function coins(int128 arg0) external returns (address out);

    function underlying_coins(int128 arg0) external returns (address out);

    function balances(int128 arg0) external returns (uint256 out);

    function A() external returns (int128 out);

    function fee() external returns (int128 out);

    function admin_fee() external returns (int128 out);

    function owner() external returns (address out);

    function admin_actions_deadline() external returns (uint256 out);

    function transfer_ownership_deadline() external returns (uint256 out);

    function future_A() external returns (int128 out);

    function future_fee() external returns (int128 out);

    function future_admin_fee() external returns (int128 out);

    function future_owner() external returns (address out);
}

pragma solidity ^0.6.0;

import "./ISetAllowance.sol";

interface IAMM is ISetAllowance {
    function trade(
        address _makerAddress,
        address _fromAssetAddress,
        address _toAssetAddress,
        uint256 _takerAssetAmount,
        uint256 _makerAssetAmount,
        uint256 _feeFactor,
        address _spender,
        address payable _receiver,
        uint256 _nonce,
        uint256 _deadline,
        bytes memory _sig
    ) payable external returns (uint256);
}

pragma solidity ^0.6.0;

interface IWETH {
    function balanceOf(address account) external view returns (uint256);
    function deposit() external payable;
    function withdraw(uint256 amount) external;
    function transferFrom(address src, address dst, uint wad) external returns (bool);
}

pragma solidity ^0.6.0;

import "./BaseLibEIP712.sol";

contract AMMLibEIP712 is BaseLibEIP712 {
    /***********************************|
    |             Constants             |
    |__________________________________*/

    struct Order {
        address makerAddr;
        address takerAssetAddr;
        address makerAssetAddr;
        uint256 takerAssetAmount;
        uint256 makerAssetAmount;
        address userAddr;
        address payable receiverAddr;
        uint256 salt;
        uint256 deadline;
    }

    // keccak256("tradeWithPermit(address makerAddr,address takerAssetAddr,address makerAssetAddr,uint256 takerAssetAmount,uint256 makerAssetAmount,address userAddr,address receiverAddr,uint256 salt,uint256 deadline)");
    bytes32 public constant TRADE_WITH_PERMIT_TYPEHASH = keccak256(
        abi.encodePacked(
            "tradeWithPermit(",
            "address makerAddr,",
            "address takerAssetAddr,",
            "address makerAssetAddr,",
            "uint256 takerAssetAmount,",
            "uint256 makerAssetAmount,",
            "address userAddr,",
            "address receiverAddr,",
            "uint256 salt,",
            "uint256 deadline",
            ")"
        )
    );
}

pragma solidity ^0.6.0;

import "../interfaces/IERC1271Wallet.sol";
import "./LibBytes.sol";

interface IWallet {
    /// @dev Verifies that a signature is valid.
    /// @param hash Message hash that is signed.
    /// @param signature Proof of signing.
    /// @return isValid Validity of order signature.
    function isValidSignature(
        bytes32 hash,
        bytes memory signature
    )
        external
        view
        returns (bool isValid);
}

/**
 * @dev Contains logic for signature validation.
 * Signatures from wallet contracts assume ERC-1271 support (https://github.com/ethereum/EIPs/blob/master/EIPS/eip-1271.md)
 * Notes: Methods are strongly inspired by contracts in https://github.com/0xProject/0x-monorepo/blob/development/
 */
contract SignatureValidator {
  using LibBytes for bytes;

  /***********************************|
  |             Variables             |
  |__________________________________*/

  // bytes4(keccak256("isValidSignature(bytes,bytes)"))
  bytes4 constant internal ERC1271_MAGICVALUE = 0x20c13b0b;

  // bytes4(keccak256("isValidSignature(bytes32,bytes)"))
  bytes4 constant internal ERC1271_MAGICVALUE_BYTES32 = 0x1626ba7e;

  // keccak256("isValidWalletSignature(bytes32,address,bytes)")
  bytes4 constant internal ERC1271_FALLBACK_MAGICVALUE_BYTES32 = 0xb0671381;

  // Allowed signature types.
  enum SignatureType {
    Illegal,                     // 0x00, default value
    Invalid,                     // 0x01
    EIP712,                      // 0x02
    EthSign,                     // 0x03
    WalletBytes,                 // 0x04  standard 1271 wallet type
    WalletBytes32,               // 0x05  standard 1271 wallet type
    Wallet,                      // 0x06  0x wallet type for signature compatibility
    NSignatureTypes              // 0x07, number of signature types. Always leave at end.
  }

  /***********************************|
  |        Signature Functions        |
  |__________________________________*/

  /**
   * @dev Verifies that a hash has been signed by the given signer.
   * @param _signerAddress  Address that should have signed the given hash.
   * @param _hash           Hash of the EIP-712 encoded data
   * @param _data           Full EIP-712 data structure that was hashed and signed
   * @param _sig            Proof that the hash has been signed by signer.
   *      For non wallet signatures, _sig is expected to be an array tightly encoded as
   *      (bytes32 r, bytes32 s, uint8 v, uint256 nonce, SignatureType sigType)
   * @return isValid True if the address recovered from the provided signature matches the input signer address.
   */
  function isValidSignature(
    address _signerAddress,
    bytes32 _hash,
    bytes memory _data,
    bytes memory _sig
  )
    public
    view
    returns (bool isValid)
  {
    require(
      _sig.length > 0,
      "SignatureValidator#isValidSignature: length greater than 0 required"
    );

    require(
      _signerAddress != address(0x0),
      "SignatureValidator#isValidSignature: invalid signer"
    );

    // Pop last byte off of signature byte array.
    uint8 signatureTypeRaw = uint8(_sig.popLastByte());

    // Ensure signature is supported
    require(
      signatureTypeRaw < uint8(SignatureType.NSignatureTypes),
      "SignatureValidator#isValidSignature: unsupported signature"
    );

    // Extract signature type
    SignatureType signatureType = SignatureType(signatureTypeRaw);

    // Variables are not scoped in Solidity.
    uint8 v;
    bytes32 r;
    bytes32 s;
    address recovered;

    // Always illegal signature.
    // This is always an implicit option since a signer can create a
    // signature array with invalid type or length. We may as well make
    // it an explicit option. This aids testing and analysis. It is
    // also the initialization value for the enum type.
    if (signatureType == SignatureType.Illegal) {
      revert("SignatureValidator#isValidSignature: illegal signature");


    // Signature using EIP712
    } else if (signatureType == SignatureType.EIP712) {
      require(
        _sig.length == 97,
        "SignatureValidator#isValidSignature: length 97 required"
      );
      r = _sig.readBytes32(0);
      s = _sig.readBytes32(32);
      v = uint8(_sig[64]);
      recovered = ecrecover(_hash, v, r, s);
      isValid = _signerAddress == recovered;
      return isValid;


    // Signed using web3.eth_sign() or Ethers wallet.signMessage()
    } else if (signatureType == SignatureType.EthSign) {
      require(
        _sig.length == 97,
        "SignatureValidator#isValidSignature: length 97 required"
      );
      r = _sig.readBytes32(0);
      s = _sig.readBytes32(32);
      v = uint8(_sig[64]);
      recovered = ecrecover(
        keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", _hash)),
        v,
        r,
        s
      );
      isValid = _signerAddress == recovered;
      return isValid;


    // Signature verified by wallet contract with data validation.
    } else if (signatureType == SignatureType.WalletBytes) {
      isValid = ERC1271_MAGICVALUE == IERC1271Wallet(_signerAddress).isValidSignature(_data, _sig);
      return isValid;


    // Signature verified by wallet contract without data validation.
    } else if (signatureType == SignatureType.WalletBytes32) {
      isValid = ERC1271_MAGICVALUE_BYTES32 == IERC1271Wallet(_signerAddress).isValidSignature(_hash, _sig);
      return isValid;


    } else if (signatureType == SignatureType.Wallet) {
      isValid = isValidWalletSignature(
          _hash,
          _signerAddress,
          _sig
      );
      return isValid;
    }

    // Anything else is illegal (We do not return false because
    // the signature may actually be valid, just not in a format
    // that we currently support. In this case returning false
    // may lead the caller to incorrectly believe that the
    // signature was invalid.)
    revert("SignatureValidator#isValidSignature: unsupported signature");
  }

  /// @dev Verifies signature using logic defined by Wallet contract.
  /// @param hash Any 32 byte hash.
  /// @param walletAddress Address that should have signed the given hash
  ///                      and defines its own signature verification method.
  /// @param signature Proof that the hash has been signed by signer.
  /// @return isValid True if signature is valid for given wallet..
  function isValidWalletSignature(
      bytes32 hash,
      address walletAddress,
      bytes memory signature
  )
      internal
      view
      returns (bool isValid)
  {
      bytes memory _calldata = abi.encodeWithSelector(
          IWallet(walletAddress).isValidSignature.selector,
          hash,
          signature
      );
      bytes32 magic_salt = bytes32(bytes4(keccak256("isValidWalletSignature(bytes32,address,bytes)")));
      assembly {
          if iszero(extcodesize(walletAddress)) {
              // Revert with `Error("WALLET_ERROR")`
              mstore(0, 0x08c379a000000000000000000000000000000000000000000000000000000000)
              mstore(32, 0x0000002000000000000000000000000000000000000000000000000000000000)
              mstore(64, 0x0000000c57414c4c45545f4552524f5200000000000000000000000000000000)
              mstore(96, 0)
              revert(0, 100)
          }

          let cdStart := add(_calldata, 32)
          let success := staticcall(
              gas(),              // forward all gas
              walletAddress,    // address of Wallet contract
              cdStart,          // pointer to start of input
              mload(_calldata),  // length of input
              cdStart,          // write output over input
              32                // output size is 32 bytes
          )

          if iszero(eq(returndatasize(), 32)) {
              // Revert with `Error("WALLET_ERROR")`
              mstore(0, 0x08c379a000000000000000000000000000000000000000000000000000000000)
              mstore(32, 0x0000002000000000000000000000000000000000000000000000000000000000)
              mstore(64, 0x0000000c57414c4c45545f4552524f5200000000000000000000000000000000)
              mstore(96, 0)
              revert(0, 100)
          }

          switch success
          case 0 {
              // Revert with `Error("WALLET_ERROR")`
              mstore(0, 0x08c379a000000000000000000000000000000000000000000000000000000000)
              mstore(32, 0x0000002000000000000000000000000000000000000000000000000000000000)
              mstore(64, 0x0000000c57414c4c45545f4552524f5200000000000000000000000000000000)
              mstore(96, 0)
              revert(0, 100)
          }
          case 1 {
              // Signature is valid if call did not revert and returned true
              isValid := eq(
                  and(mload(cdStart), 0xffffffff00000000000000000000000000000000000000000000000000000000),
                  and(magic_salt, 0xffffffff00000000000000000000000000000000000000000000000000000000)
              )
          }
      }
      return isValid;
  }
}

pragma solidity ^0.6.0;

interface ISetAllowance {
    function setAllowance(address[] memory tokenList, address spender) external;
    function closeAllowance(address[] memory tokenList, address spender) external;
}

pragma solidity ^0.6.0;

contract BaseLibEIP712 {
    /***********************************|
    |             Constants             |
    |__________________________________*/

    // EIP-191 Header
    string public constant EIP191_HEADER = "\x19\x01";

    // EIP712Domain
    string public constant EIP712_DOMAIN_NAME = "Tokenlon";
    string public constant EIP712_DOMAIN_VERSION = "v5";

    // EIP712Domain Separator
    bytes32 public immutable EIP712_DOMAIN_SEPARATOR = keccak256(
        abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256(bytes(EIP712_DOMAIN_NAME)),
            keccak256(bytes(EIP712_DOMAIN_VERSION)),
            getChainID(),
            address(this)
        )
    );

    /**
        * @dev Return `chainId`
        */
    function getChainID() internal pure returns (uint) {
        uint chainId;
        assembly {
            chainId := chainid()
        }
        return chainId;
    }
}

pragma solidity ^0.6.0;


interface  IERC1271Wallet {

  /**
   * @notice Verifies whether the provided signature is valid with respect to the provided data
   * @dev MUST return the correct magic value if the signature provided is valid for the provided data
   *   > The bytes4 magic value to return when signature is valid is 0x20c13b0b : bytes4(keccak256("isValidSignature(bytes,bytes)")
   *   > This function MAY modify Ethereum's state
   * @param _data       Arbitrary length data signed on the behalf of address(this)
   * @param _signature  Signature byte array associated with _data
   * @return magicValue Magic value 0x20c13b0b if the signature is valid and 0x0 otherwise
   *
   */
  function isValidSignature(
    bytes calldata _data,
    bytes calldata _signature)
    external
    view
    returns (bytes4 magicValue);

  /**
   * @notice Verifies whether the provided signature is valid with respect to the provided hash
   * @dev MUST return the correct magic value if the signature provided is valid for the provided hash
   *   > The bytes4 magic value to return when signature is valid is 0x20c13b0b : bytes4(keccak256("isValidSignature(bytes,bytes)")
   *   > This function MAY modify Ethereum's state
   * @param _hash       keccak256 hash that was signed
   * @param _signature  Signature byte array associated with _data
   * @return magicValue Magic value 0x20c13b0b if the signature is valid and 0x0 otherwise
   */
  function isValidSignature(
    bytes32 _hash,
    bytes calldata _signature)
    external
    view
    returns (bytes4 magicValue);
}

/*
  Copyright 2018 ZeroEx Intl.
  Licensed under the Apache License, Version 2.0 (the "License");
  you may not use this file except in compliance with the License.
  You may obtain a copy of the License at
  http://www.apache.org/licenses/LICENSE-2.0
  Unless required by applicable law or agreed to in writing, software
  distributed under the License is distributed on an "AS IS" BASIS,
  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
  See the License for the specific language governing permissions and
  limitations under the License.
  This is a truncated version of the original LibBytes.sol library from ZeroEx.
*/

pragma solidity ^0.6.0;


library LibBytes {
  using LibBytes for bytes;

  /***********************************|
  |        Pop Bytes Functions        |
  |__________________________________*/

  /**
   * @dev Pops the last byte off of a byte array by modifying its length.
   * @param b Byte array that will be modified.
   * @return result The byte that was popped off.
   */
  function popLastByte(bytes memory b)
    internal
    pure
    returns (bytes1 result)
  {
    require(
      b.length > 0,
      "LibBytes#popLastByte: greater than zero length required"
    );

    // Store last byte.
    result = b[b.length - 1];

    assembly {
      // Decrement length of byte array.
      let newLen := sub(mload(b), 1)
      mstore(b, newLen)
    }
    return result;
  }

  /// @dev Reads an address from a position in a byte array.
  /// @param b Byte array containing an address.
  /// @param index Index in byte array of address.
  /// @return result address from byte array.
  function readAddress(
    bytes memory b,
    uint256 index
  )
    internal
    pure
    returns (address result)
  {
    require(
      b.length >= index + 20,  // 20 is length of address
      "LibBytes#readAddress greater or equal to 20 length required"
    );

    // Add offset to index:
    // 1. Arrays are prefixed by 32-byte length parameter (add 32 to index)
    // 2. Account for size difference between address length and 32-byte storage word (subtract 12 from index)
    index += 20;

    // Read address from array memory
    assembly {
      // 1. Add index to address of bytes array
      // 2. Load 32-byte word from memory
      // 3. Apply 20-byte mask to obtain address
      result := and(mload(add(b, index)), 0xffffffffffffffffffffffffffffffffffffffff)
    }
    return result;
  }

  /***********************************|
  |        Read Bytes Functions       |
  |__________________________________*/

  /**
   * @dev Reads a bytes32 value from a position in a byte array.
   * @param b Byte array containing a bytes32 value.
   * @param index Index in byte array of bytes32 value.
   * @return result bytes32 value from byte array.
   */
  function readBytes32(
    bytes memory b,
    uint256 index
  )
    internal
    pure
    returns (bytes32 result)
  {
    require(
      b.length >= index + 32,
      "LibBytes#readBytes32 greater or equal to 32 length required"
    );

    // Arrays are prefixed by a 256 bit length parameter
    index += 32;

    // Read the bytes32 from array memory
    assembly {
      result := mload(add(b, index))
    }
    return result;
  }

  /// @dev Reads an unpadded bytes4 value from a position in a byte array.
  /// @param b Byte array containing a bytes4 value.
  /// @param index Index in byte array of bytes4 value.
  /// @return result bytes4 value from byte array.
  function readBytes4(
    bytes memory b,
    uint256 index
  )
    internal
    pure
    returns (bytes4 result)
  {
    require(
      b.length >= index + 4,
      "LibBytes#readBytes4 greater or equal to 4 length required"
    );

    // Arrays are prefixed by a 32 byte length field
    index += 32;

    // Read the bytes4 from array memory
    assembly {
      result := mload(add(b, index))
      // Solidity does not require us to clean the trailing bytes.
      // We do it anyway
      result := and(result, 0xFFFFFFFF00000000000000000000000000000000000000000000000000000000)
    }
    return result;
  }

  function readBytes2(
    bytes memory b,
    uint256 index
  )
    internal
    pure
    returns (bytes2 result)
  {
    require(
      b.length >= index + 2,
      "LibBytes#readBytes2 greater or equal to 2 length required"
    );

    // Arrays are prefixed by a 32 byte length field
    index += 32;

    // Read the bytes4 from array memory
    assembly {
      result := mload(add(b, index))
      // Solidity does not require us to clean the trailing bytes.
      // We do it anyway
      result := and(result, 0xFFFF000000000000000000000000000000000000000000000000000000000000)
    }
    return result;
  }
}

// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0 <0.8.0;

/// @title Callback for IUniswapV3PoolActions#swap
/// @notice Any contract that calls IUniswapV3PoolActions#swap must implement this interface
interface IUniswapV3SwapCallback {
    /// @notice Called to `msg.sender` after executing a swap via IUniswapV3Pool#swap.
    /// @dev In the implementation you must pay the pool tokens owed for the swap.
    /// The caller of this method must be checked to be a UniswapV3Pool deployed by the canonical UniswapV3Factory.
    /// amount0Delta and amount1Delta can both be 0 if no tokens were swapped.
    /// @param amount0Delta The amount of token0 that was sent (negative) or must be received (positive) by the pool by
    /// the end of the swap. If positive, the callback must send that amount of token0 to the pool.
    /// @param amount1Delta The amount of token1 that was sent (negative) or must be received (positive) by the pool by
    /// the end of the swap. If positive, the callback must send that amount of token1 to the pool.
    /// @param data Any data passed through by the caller via the IUniswapV3PoolActions#swap call
    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data
    ) external;
}

{
  "optimizer": {
    "enabled": true,
    "runs": 1000
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
  "metadata": {
    "useLiteralContent": true
  },
  "libraries": {}
}