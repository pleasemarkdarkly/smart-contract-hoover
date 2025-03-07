/**
 *Submitted for verification at Etherscan.io on 2021-06-07
*/

// File: @openzeppelin/contracts/math/SafeMath.sol

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

// File: @openzeppelin/contracts/token/ERC20/IERC20.sol


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

// File: @openzeppelin/contracts/utils/Address.sol


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

// File: @openzeppelin/contracts/token/ERC20/SafeERC20.sol


pragma solidity >=0.6.0 <0.8.0;




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

// File: contracts/interfaces/IFarm.sol

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

// File: contracts/interfaces/ISVaultNetValue.sol

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

// File: contracts/interfaces/IController.sol

pragma solidity ^0.6.12;


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
}

// File: @openzeppelin/contracts/utils/Context.sol


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

// File: @openzeppelin/contracts/access/Ownable.sol


pragma solidity >=0.6.0 <0.8.0;

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

// File: contracts/interfaces/IFactory.sol

pragma solidity >=0.5.0;

interface IFactory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

// File: contracts/interfaces/IPair.sol

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

// File: contracts/PriceView.sol

pragma solidity ^0.6.12;




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

// File: contracts/interfaces/IStrategy.sol

pragma solidity ^0.6.12;

abstract contract IStrategy {
    function earn(address[] memory tokens, uint256[] memory amounts, address[] memory earnTokens, uint256[] memory amountLimits) external virtual;
    function withdraw(address token) external virtual returns (uint256);
    function withdraw(uint256 amount) external virtual returns (address[] memory tokens, uint256[] memory amounts);
    function withdraw(address[] memory tokens, uint256 amount) external virtual returns (uint256, address[] memory, uint256[] memory);
    function withdrawProfit(address token, uint256 amount) external virtual returns (uint256, address[] memory, uint256[] memory);
    //function withdraw(address[] memory tokens, uint256 amount, uint256 _profitAmount) external virtual returns (uint256, uint256, address[] memory, uint256[] memory);
    function getTokenAmounts() external view virtual returns (address[] memory tokens, uint256[] memory amounts);
    function getTokens() external view virtual returns (address[] memory tokens);
    function getProfitTokens() external view virtual returns (address[] memory tokens);
}

// File: contracts/StrategyStorage.sol

pragma solidity ^0.6.12;




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

// File: contracts/BoardRoomMDXStrategy.sol

pragma solidity ^0.6.12;







contract BoardRoomMDXStrategy is BoardRoomMDXStrategyStorage{
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    function initialize(address _wantToken, address _controller, uint256 _pid, address _farm, address _profit, address _priceView) external {
        require(msg.sender == admin, "UNAUTHORIZED");
        require(controller == address(0), "ALREADY INITIALIZED");
        wantToken = _wantToken;
        farm = _farm;
        profit = _profit;
        controller = _controller;
        pid = _pid;
        priceView = _priceView;
    }

    function earn(address[] memory _tokens, uint256[] memory _amounts, address[] memory _earnTokens, uint256[] memory _amountLimits) external override{
        require(msg.sender == controller, "!controller");
        require(_tokens.length == 1 && _tokens[0] == wantToken, "Invalid token"); 
        require(_amounts.length == 1 && _amounts[0] > 0, "Invalid amounts");
        earnInternal(_amounts[0]);
    }

    function withdraw(uint256 amount) external override returns (address[] memory tokens, uint256[] memory amounts){
        require(msg.sender == controller, "!controller");
        withdrawFromFarm(amount);
        wantTokenAmount = wantTokenAmount.sub(amount);
        tokens = new address[](1);
        tokens[0] = wantToken;
        amounts = new uint256[](1); 
        amounts[0] = amount;
        IERC20(wantToken).safeTransfer(controller, amount);
    }

    function withdraw(address _token) external override returns (uint256){
        require(msg.sender == controller, "!controller");
        require(_token == wantToken, "Invalid token");
        uint256 balance = IERC20(_token).balanceOf(address(this));
        if(_token == profit) balance = balance.add(reinvestmentAmount).sub(profitAmount);
        IERC20(_token).safeTransfer(controller, balance);
        return balance;
    }

    function withdrawProfit(address token, uint256 amount) external override returns(uint256, address[] memory, uint256[] memory){
        address[] memory withdrawTokens = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        withdrawTokens[0] = profit;
        withdrawFromFarm(0);
        if(token == profit){
            amount = amount > profitAmount.sub(reinvestmentAmount) ? profitAmount.sub(reinvestmentAmount) : amount;
            profitAmount = profitAmount.sub(amount);
            amounts[0] = amount;
            
        }else{
            uint256 tokenPrice = PriceView(priceView).getPrice(token);
            uint256 profitTokenPrice = PriceView(priceView).getPrice(profit);
            uint256 profitTokenAmount = amount.mul(tokenPrice).div(profitTokenPrice);
            if(profitTokenAmount > profitAmount.sub(reinvestmentAmount)){
                profitTokenAmount = profitAmount.sub(reinvestmentAmount);
                amount = profitTokenAmount.mul(profitTokenPrice).div(tokenPrice);
            }
            profitAmount = profitAmount.sub(profitTokenAmount);
            amounts[0] = profitTokenAmount;
        }
        if(amounts[0] > 0) IERC20(profit).safeTransfer(controller, amounts[0]);
        return (amount, withdrawTokens, amounts);
    }

    function withdraw(address[] memory tokens, uint256 _amount) external override returns(uint256,address[] memory, uint256[] memory){
        require(msg.sender == controller, "!controller");
        require(tokens.length == 1, "Invalid tokens length");
        address[] memory withdrawTokens = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        withdrawTokens[0] = wantToken;
        if(_amount > 0 && wantTokenAmount > 0){
            if(tokens[0] == wantToken){
                uint256 amount = _amount > wantTokenAmount ? wantTokenAmount : _amount;
                withdrawFromFarm(amount);
                amounts[0] = amount;
                wantTokenAmount = wantTokenAmount.sub(amount);
                _amount = amount;
            }else{
                uint256 tokenPrice = PriceView(priceView).getPrice(tokens[0]);
                uint256 wantTokenPrice = PriceView(priceView).getPrice(wantToken);
                uint256 tokenAmountInUSD = _amount.mul(tokenPrice);
                uint256 needAmount = tokenAmountInUSD.div(wantTokenPrice);
                if(needAmount > wantTokenAmount){
                    needAmount = wantTokenAmount;
                    _amount = needAmount.mul(wantTokenPrice).div(tokenPrice);
                }
                withdrawFromFarm(needAmount);
                amounts[0] = needAmount;
                wantTokenAmount = wantTokenAmount.sub(needAmount);
            }
            IERC20(wantToken).safeTransfer(controller, amounts[0]);
        }else{
            _amount = 0;
        }
        return (_amount, withdrawTokens, amounts);
    }

    // function withdraw(address[] memory tokens, uint256 _amount, uint256 _profitAmount) external override returns (uint256, uint256, address[] memory, uint256[] memory){
    //     require(msg.sender == controller, "!controller");
    //     require(tokens.length == 1, "Invalid tokens length");
    //     uint256 count = _amount > 0 && _profitAmount > 0 && wantToken != profit ? 2 : 1;
    //     address[] memory withdrawTokens = new address[](count);
    //     uint256[] memory amounts = new uint256[](count);
    //     if(_amount > 0 && wantTokenAmount > 0){
    //         if(tokens[0] == wantToken){
    //             uint256 amount = _amount > wantTokenAmount ? wantTokenAmount : _amount;
    //             withdrawFromFarm(amount);
    //             amounts[0] = amount;
    //             withdrawTokens[0] = tokens[0];
    //             wantTokenAmount = wantTokenAmount.sub(amount);
    //         }else{
    //             uint256 tokenPrice = PriceView(priceView).getPrice(tokens[0]);
    //             uint256 wantTokenPrice = PriceView(priceView).getPrice(wantToken);
    //             uint256 tokenAmountInUSD = _amount.mul(tokenPrice);
    //             uint256 needAmount = tokenAmountInUSD.div(wantTokenPrice);
    //             if(needAmount > wantTokenAmount){
    //                 needAmount = wantTokenAmount;
    //                 _amount = needAmount.mul(wantTokenPrice).div(tokenPrice);
    //             }
    //             amounts[0] = needAmount;
    //             withdrawTokens[0] = wantToken;
    //             wantTokenAmount = wantTokenAmount.sub(needAmount);
    //         }
    //     }
        
    //     if(_profitAmount > 0){
    //         if(tokens[0] == profit){
    //             withdrawFromFarm(0);
    //             uint256 amount = _profitAmount > profitAmount ? profitAmount : _profitAmount;
    //             _profitAmount = amount;
    //             reinvestmentAmount = reinvestmentAmount > amount ? reinvestmentAmount.sub(amount) : 0;
    //             profitAmount = profitAmount.sub(amount);
    //             amounts[0] = amounts[0].add(amount);
    //             withdrawTokens[0] = tokens[0];
    //         }else{
    //             uint256 tokenPrice = PriceView(priceView).getPrice(tokens[0]);
    //             uint256 profitTokenPrice = PriceView(priceView).getPrice(profit);
    //             uint256 profitTokenAmount = _profitAmount.mul(tokenPrice).div(profitTokenPrice);
    //             if(profitTokenAmount > profitAmount){
    //                 profitTokenAmount = profitAmount;
    //                 _profitAmount = profitTokenAmount.mul(profitTokenPrice).div(tokenPrice);
    //             }
    //             reinvestmentAmount = reinvestmentAmount > profitTokenAmount ? reinvestmentAmount.sub(profitTokenAmount) : 0;
    //             profitAmount = profitAmount.sub(profitTokenAmount);
    //             withdrawTokens[count - 1] = profit;
    //             amounts[count - 1] = amounts[count - 1].add(profitTokenAmount);
    //         }
    //     }
    //     for(uint256 i = 0; i < amounts.length; i ++){
    //         IERC20(withdrawTokens[i]).safeTransfer(controller, amounts[i]);
    //     }
    //     return (_amount, _profitAmount, withdrawTokens, amounts);
    // }

    function harvest() external {
        withdrawFromFarm(0);
    }

    function reinvestment(address strategy, address token, uint256 amount) external {
        require(profit == token, "Invalid token");
        address[] memory strategies = IController(controller).getStrategies();
        require(hasItem(strategies, strategy), "Invalid strategy");
        address[] memory _profitTokens = IStrategy(strategy).getProfitTokens();
        require(hasItem(_profitTokens, token), "Invalid strategy without token");
        reinvestmentAmount = reinvestmentAmount.add(amount);
        require(reinvestmentAmount <= profitAmount);
        IERC20(token).safeTransfer(strategy, amount);
    }

    function getTokens() external view override returns (address[] memory tokens){
        tokens = new address[](1);
        tokens[0] = wantToken;
    } 

    function getProfitTokens() external view override returns (address[] memory tokens){
        tokens = new address[](1);
        tokens[0] = profit;
    }

    function getTokenAmounts() external view override returns (address[] memory tokens, uint256[] memory amounts){
        uint256 count = wantToken == profit ? 1 : 2;
        tokens = new address[](count);
        amounts = new uint256[](count);
        tokens[0] = wantToken;
        amounts[0] = wantTokenAmount.add(IERC20(wantToken).balanceOf(address(this)));
        uint256 pending = IFarm(farm).pending(pid, address(this));
        if(count == 2){
            tokens[1] = profit;
            amounts[1] = IERC20(profit).balanceOf(address(this));
            amounts[1] = amounts[1].add(pending);
        }else{
            amounts[0] = amounts[0].add(pending);
        }
    }

    function getProfitAmount() view public returns (uint256){
        //Be careful! pendingSashimi is just for sashimi, other farm need to change method name
        return profitAmount.add(IFarm(farm).pending(pid, address(this)));
    }

    function earnInternal(uint256 amount) internal{
        wantTokenAmount = wantTokenAmount.add(amount);
        IERC20(wantToken).safeTransferFrom(controller, address(this), amount);
        uint256 profitBalance = IERC20(profit).balanceOf(address(this));
        if(wantToken == profit) profitBalance = profitBalance.sub(amount);
        IERC20(wantToken).safeApprove(farm, amount);
        IFarm(farm).deposit(pid, amount);
        profitAmount = profitAmount.add(IERC20(profit).balanceOf(address(this)).sub(profitBalance));
    }

    function withdrawFromFarm(uint256 amount) internal{
        uint256 profitBalance = IERC20(profit).balanceOf(address(this));
        IFarm(farm).withdraw(pid, amount);
        if(wantToken == profit) profitBalance = profitBalance.add(amount);
        profitAmount = profitAmount.add(IERC20(profit).balanceOf(address(this)).sub(profitBalance));
    }

    function hasItem(address[] memory _array, address _item) internal pure returns (bool){
        for(uint256 i = 0; i < _array.length; i++){
            if(_array[i] == _item) return true;
        }
        return false;
    }
}