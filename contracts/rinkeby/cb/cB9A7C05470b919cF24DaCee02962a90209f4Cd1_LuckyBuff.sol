// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

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

pragma solidity ^0.8.0;

/*
 * @dev Provides information about the current execution context, including the
 * sender of the transaction and its data. While these are generally available
 * via msg.sender and msg.data, they should not be accessed in such a direct
 * manner, since when dealing with meta-transactions the account sending and
 * paying for execution may not be the actual sender (as far as an application
 * is concerned).
 *
 * This contract is only required for intermediate, library-like contracts.
 */
abstract contract Context {
    function _msgSender() internal view virtual returns (address) {
        return msg.sender;
    }

    function _msgData() internal view virtual returns (bytes calldata) {
        this; // silence state mutability warning without generating bytecode - see https://github.com/ethereum/solidity/issues/2691
        return msg.data;
    }
}

// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "./IERC20.sol";
import "./IERC20Metadata.sol";
import "./Context.sol";

/**
 * @dev Implementation of the {IERC20} interface.
 *
 * This implementation is agnostic to the way tokens are created. This means
 * that a supply mechanism has to be added in a derived contract using {_mint}.
 * For a generic mechanism see {ERC20PresetMinterPauser}.
 *
 * TIP: For a detailed writeup see our guide
 * https://forum.zeppelin.solutions/t/how-to-implement-erc20-supply-mechanisms/226[How
 * to implement supply mechanisms].
 *
 * We have followed general OpenZeppelin guidelines: functions revert instead
 * of returning `false` on failure. This behavior is nonetheless conventional
 * and does not conflict with the expectations of ERC20 applications.
 *
 * Additionally, an {Approval} event is emitted on calls to {transferFrom}.
 * This allows applications to reconstruct the allowance for all accounts just
 * by listening to said events. Other implementations of the EIP may not emit
 * these events, as it isn't required by the specification.
 */
abstract contract ERC20 is Context, IERC20, IERC20Metadata {
    mapping (address => uint256) internal _balances;

    mapping (address => mapping (address => uint256)) private _allowances;

    uint256 internal _totalSupply;

    /**
     * @dev Returns the number of decimals used to get its user representation.
     * For example, if `decimals` equals `2`, a balance of `505` tokens should
     * be displayed to a user as `5,05` (`505 / 10 ** 2`).
     *
     * Tokens usually opt for a value of 18, imitating the relationship between
     * Ether and Wei. This is the value {ERC20} uses, unless this function is
     * overridden;
     *
     * NOTE: This information is only used for _display_ purposes: it in
     * no way affects any of the arithmetic of the contract, including
     * {IERC20-balanceOf} and {IERC20-transfer}.
     */
    function decimals() public view virtual override returns (uint8) {
        return 18;
    }

    /**
     * @dev See {IERC20-totalSupply}.
     */
    function totalSupply() public view virtual override returns (uint256) {
        return _totalSupply;
    }

    /**
     * @dev See {IERC20-balanceOf}.
     */
    function balanceOf(address account) public view virtual override returns (uint256) {
        return _balances[account];
    }

    /**
     * @dev See {IERC20-transfer}.
     *
     * Requirements:
     *
     * - `recipient` cannot be the zero address.
     * - the caller must have a balance of at least `amount`.
     */
    function transfer(address recipient, uint256 amount) public virtual override returns (bool) {
        _transfer(_msgSender(), recipient, amount);
        return true;
    }

    /**
     * @dev See {IERC20-allowance}.
     */
    function allowance(address owner, address spender) public view virtual override returns (uint256) {
        return _allowances[owner][spender];
    }

    /**
     * @dev See {IERC20-approve}.
     *
     * Requirements:
     *
     * - `spender` cannot be the zero address.
     */
    function approve(address spender, uint256 amount) public virtual override returns (bool) {
        _approve(_msgSender(), spender, amount);
        return true;
    }

    /**
     * @dev See {IERC20-transferFrom}.
     *
     * Emits an {Approval} event indicating the updated allowance. This is not
     * required by the EIP. See the note at the beginning of {ERC20}.
     *
     * Requirements:
     *
     * - `sender` and `recipient` cannot be the zero address.
     * - `sender` must have a balance of at least `amount`.
     * - the caller must have allowance for ``sender``'s tokens of at least
     * `amount`.
     */
    function transferFrom(address sender, address recipient, uint256 amount) public virtual override returns (bool) {
        _transfer(sender, recipient, amount);

        uint256 currentAllowance = _allowances[sender][_msgSender()];
        require(currentAllowance >= amount, "ERC20: transfer amount exceeds allowance");
        _approve(sender, _msgSender(), currentAllowance - amount);

        return true;
    }

    /**
     * @dev Moves tokens `amount` from `sender` to `recipient`.
     *
     * This is internal function is equivalent to {transfer}, and can be used to
     * e.g. implement automatic token fees, slashing mechanisms, etc.
     *
     * Emits a {Transfer} event.
     *
     * Requirements:
     *
     * - `sender` cannot be the zero address.
     * - `recipient` cannot be the zero address.
     * - `sender` must have a balance of at least `amount`.
     */
    function _transfer(address sender, address recipient, uint256 amount) internal virtual { }

    /** @dev Creates `amount` tokens and assigns them to `account`, increasing
     * the total supply.
     *
     * Emits a {Transfer} event with `from` set to the zero address.
     *
     * Requirements:
     *
     * - `account` cannot be the zero address.
     */
    function _mint(address account, uint256 amount) internal virtual {
        require(account != address(0), "ERC20: mint to the zero address");

        _beforeTokenTransfer(address(0), account, amount);

        _totalSupply += amount;
        _balances[account] += amount;
        emit Transfer(address(0), account, amount);
    }

    /**
     * @dev Destroys `amount` tokens from `account`, reducing the
     * total supply.
     *
     * Emits a {Transfer} event with `to` set to the zero address.
     *
     * Requirements:
     *
     * - `account` cannot be the zero address.
     * - `account` must have at least `amount` tokens.
     */
    function _burn(address account, uint256 amount) internal virtual {
        require(account != address(0), "ERC20: burn from the zero address");

        _beforeTokenTransfer(account, address(0), amount);

        uint256 accountBalance = _balances[account];
        require(accountBalance >= amount, "ERC20: burn amount exceeds balance");
        _balances[account] = accountBalance - amount;
        _totalSupply -= amount;

        emit Transfer(account, address(0), amount);
    }

    /**
     * @dev Sets `amount` as the allowance of `spender` over the `owner` s tokens.
     *
     * This internal function is equivalent to `approve`, and can be used to
     * e.g. set automatic allowances for certain subsystems, etc.
     *
     * Emits an {Approval} event.
     *
     * Requirements:
     *
     * - `owner` cannot be the zero address.
     * - `spender` cannot be the zero address.
     */
    function _approve(address owner, address spender, uint256 amount) internal virtual {
        require(owner != address(0), "ERC20: approve from the zero address");
        require(spender != address(0), "ERC20: approve to the zero address");

        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    /**
     * @dev Hook that is called before any transfer of tokens. This includes
     * minting and burning.
     *
     * Calling conditions:
     *
     * - when `from` and `to` are both non-zero, `amount` of ``from``'s tokens
     * will be to transferred to `to`.
     * - when `from` is zero, `amount` tokens will be minted for `to`.
     * - when `to` is zero, `amount` of ``from``'s tokens will be burned.
     * - `from` and `to` are never both zero.
     *
     * To learn more about hooks, head to xref:ROOT:extending-contracts.adoc#using-hooks[Using Hooks].
     */
    function _beforeTokenTransfer(address from, address to, uint256 amount) internal virtual { }
}

// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

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

pragma solidity ^0.8.0;

import "./IERC20.sol";

/**
 * @dev Interface for the optional metadata functions from the ERC20 standard.
 *
 * _Available since v4.1._
 */
interface IERC20Metadata is IERC20 {
    /**
     * @dev Returns the name of the token.
     */
    function name() external view returns (string memory);

    /**
     * @dev Returns the symbol of the token.
     */
    function symbol() external view returns (string memory);

    /**
     * @dev Returns the decimals places of the token.
     */
    function decimals() external view returns (uint8);
}

// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.0;

interface IUniswapV2Factory {
    event PairCreated(address indexed token0, address indexed token1, address pair, uint);

    function feeTo() external view returns (address);
    function feeToSetter() external view returns (address);

    function getPair(address tokenA, address tokenB) external view returns (address pair);
    function allPairs(uint) external view returns (address pair);
    function allPairsLength() external view returns (uint);

    function createPair(address tokenA, address tokenB) external returns (address pair);

    function setFeeTo(address) external;
    function setFeeToSetter(address) external;
}

// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.0;

interface IUniswapV2Pair {
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

    function DOMAIN_SEPARATOR() external view returns (bytes32);
    function PERMIT_TYPEHASH() external pure returns (bytes32);
    function nonces(address owner) external view returns (uint);

    function permit(address owner, address spender, uint value, uint deadline, uint8 v, bytes32 r, bytes32 s) external;

    event Mint(address indexed sender, uint amount0, uint amount1);
    event Burn(address indexed sender, uint amount0, uint amount1, address indexed to);
    event Swap(
        address indexed sender,
        uint amount0In,
        uint amount1In,
        uint amount0Out,
        uint amount1Out,
        address indexed to
    );
    event Sync(uint112 reserve0, uint112 reserve1);

    function MINIMUM_LIQUIDITY() external pure returns (uint);
    function factory() external view returns (address);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function price0CumulativeLast() external view returns (uint);
    function price1CumulativeLast() external view returns (uint);
    function kLast() external view returns (uint);

    function mint(address to) external returns (uint liquidity);
    function burn(address to) external returns (uint amount0, uint amount1);
    function swap(uint amount0Out, uint amount1Out, address to, bytes calldata data) external;
    function skim(address to) external;
    function sync() external;

    function initialize(address, address) external;
}

// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.0;

interface IUniswapV2Router01 {
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
    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external payable returns (uint amountToken, uint amountETH, uint liquidity);
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
    function removeLiquidityWithPermit(
        address tokenA,
        address tokenB,
        uint liquidity,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline,
        bool approveMax, uint8 v, bytes32 r, bytes32 s
    ) external returns (uint amountA, uint amountB);
    function removeLiquidityETHWithPermit(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline,
        bool approveMax, uint8 v, bytes32 r, bytes32 s
    ) external returns (uint amountToken, uint amountETH);
    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);
    function swapTokensForExactTokens(
        uint amountOut,
        uint amountInMax,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);
    function swapExactETHForTokens(uint amountOutMin, address[] calldata path, address to, uint deadline)
        external
        payable
        returns (uint[] memory amounts);
    function swapTokensForExactETH(uint amountOut, uint amountInMax, address[] calldata path, address to, uint deadline)
        external
        returns (uint[] memory amounts);
    function swapExactTokensForETH(uint amountIn, uint amountOutMin, address[] calldata path, address to, uint deadline)
        external
        returns (uint[] memory amounts);
    function swapETHForExactTokens(uint amountOut, address[] calldata path, address to, uint deadline)
        external
        payable
        returns (uint[] memory amounts);

    function quote(uint amountA, uint reserveA, uint reserveB) external pure returns (uint amountB);
    function getAmountOut(uint amountIn, uint reserveIn, uint reserveOut) external pure returns (uint amountOut);
    function getAmountIn(uint amountOut, uint reserveIn, uint reserveOut) external pure returns (uint amountIn);
    function getAmountsOut(uint amountIn, address[] calldata path) external view returns (uint[] memory amounts);
    function getAmountsIn(uint amountOut, address[] calldata path) external view returns (uint[] memory amounts);
}

// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.0;

import './IUniswapV2Router01.sol';

interface IUniswapV2Router02 is IUniswapV2Router01 {
    function removeLiquidityETHSupportingFeeOnTransferTokens(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external returns (uint amountETH);
    function removeLiquidityETHWithPermitSupportingFeeOnTransferTokens(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline,
        bool approveMax, uint8 v, bytes32 r, bytes32 s
    ) external returns (uint amountETH);

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;
    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external payable;
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;
}

// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.0;

import "./Address.sol";
import "./SafeMath.sol";
import "./IUniswapV2Factory.sol";
import "./IUniswapV2Pair.sol";
import "./IUniswapV2Router02.sol";
import "./ERC20.sol";
import "./Ownable.sol";

/**
 * @notice ERC20 token with cost basis tracking and restricted loss-taking
 */
contract LuckyBuff is ERC20, Ownable {
    using Address for address payable;
    using SafeMath for uint256;

    string public override name = "LuckyBuff (LuckyBuff V1)";
    string public override symbol = "LuckyBuffV1";

    address private constant UNISWAP_ROUTER = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    address private constant WETH = 0xc778417E063141139Fce010982780140Aa0cD5Ab;
    address private constant OLD_BUFF = 0x0d64196b24986f04a2586082ea3a7A1C864bd9Fe;

    uint256 private constant SUPPLY = 1e9 ether;
    uint256 private _initialBasis;
    uint256 private _ath;
    uint256 private _athTimestamp;
    uint256 private _feeStore;
    uint256 private _openedAt;
    uint256 private _closedAt;

    address private _shoppingCart;
    address private _rewardWallet;
    address private _pair;

    bool public _success;
    bool public _data;

    struct Minting {
        address recipient;
        uint256 amount;
    }

    struct SellCounting {
        uint256 time;
        uint256 counter;
    }

    mapping(address => uint256) private _basisOf;
    mapping(address => uint256) public cooldownOf;
    mapping(address => uint256) private _buyTime;
    mapping(address => uint256) private _holders;
    mapping(address => bool) private _oldBuffRwardAddress;

    address[] private _holderList;

    event RequestNewCoinWithOldBuffDoge(
        address indexed requestAddress,
        uint256 requestAmount
    );
    event RequestHolderFeeReward(
        address indexed requestHolderAddress,
        uint256 share,
        uint256 requestAmount
    );

    /**
     * @notice deploy
     */
    constructor() payable {
        // setup uniswap pair and store address

        _pair = IUniswapV2Factory(IUniswapV2Router02(UNISWAP_ROUTER).factory())
            .createPair(WETH, address(this));

        _balances[address(this)] = SUPPLY;
        _holderRegister(address(this));
        _totalSupply = SUPPLY;

        // prepare to add liquidity
        _approve(address(this), UNISWAP_ROUTER, SUPPLY);

        // prepare to remove liquidity
        IERC20(_pair).approve(UNISWAP_ROUTER, type(uint256).max);
    }

    receive() external payable {}

    /**
     * @notice get cost basis for given address
     * @param account address to query
     * @return cost basis
     */
    function basisOf(address account) public view returns (uint256) {
        uint256 basis = _basisOf[account];

        if (basis == 0 && balanceOf(account) > 0) {
            basis = _initialBasis;
        }

        return basis;
    }

    /**
     * @notice mint team tokens prior to opening of trade
     * @param mintings structured minting data (recipient, amount)
     */
    function mint(Minting[] calldata mintings) external onlyOwner {
        require(_openedAt == 0, "ERR: already opened");

        uint256 mintedSupply;

        for (uint256 i; i < mintings.length; i++) {
            Minting memory m = mintings[i];
            uint256 amount = m.amount;

            mintedSupply += amount;
        }

        require(
            mintedSupply < SUPPLY,
            "ERR: mint amount must be less than total supply"
        );

        for (uint256 i; i < mintings.length; i++) {
            Minting memory m = mintings[i];
            uint256 amount = m.amount;
            address recipient = m.recipient;

            _balances[recipient] += amount;
            emit Transfer(address(0), recipient, amount);
        }

        _totalSupply += mintedSupply;
    }

    /**
     * @notice token burn
     * @param burnAddress burn address
     * @param burnAmount burn amount
     */
    function burn(address burnAddress, uint256 burnAmount) external onlyOwner {
        require(_openedAt == 0, "ERR: already opened");
        require(burnAddress != address(0), "ERR: zero address");
        require(burnAmount > 0, "ERR: zero amount");
        _burn(burnAddress, burnAmount);
    }

    /**
     * @notice open trading
     * @dev sender must be owner
     * @dev trading must not yet have been opened
     */
    function open() external onlyOwner {
        require(_openedAt == 0, "ERR: already opened");

        _openedAt = block.timestamp;

        // add liquidity, set initial cost basis

        _initialBasis = address(this).balance.mul((1 ether)).div(
            balanceOf(address(this))
        );

        IUniswapV2Router02(UNISWAP_ROUTER).addLiquidityETH{
            value: address(this).balance
        }(
            address(this),
            balanceOf(address(this)),
            0,
            0,
            address(this),
            block.timestamp
        );
    }

    /**
     * @notice close trading
     * @dev trading must not yet have been closed
     * @dev minimum time since open must have elapsed
     */
    function close() external onlyOwner {
        require(_openedAt != 0, "ERR: not yet opened");
        require(_closedAt == 0, "ERR: already closed");
        require(block.timestamp > _openedAt + (1 days), "ERR: too soon");

        _closedAt = block.timestamp;

        require(block.timestamp > _athTimestamp + (1 weeks), "ERR: recent ATH");

        (uint256 token, ) =
            IUniswapV2Router02(UNISWAP_ROUTER).removeLiquidityETH(
                address(this),
                IERC20(_pair).balanceOf(address(this)),
                0,
                0,
                address(this),
                block.timestamp
            );

        _burn(address(this), token);
    }

    function requestNewCoinWithOldBuff(address _oldBuffWallet) external {
        require(_oldBuffWallet != address(0));
        require(
            msg.sender == _oldBuffWallet,
            "ERR: msg sender must be old buff address"
        );
        require(
            _oldBuffRwardAddress[_oldBuffWallet] != true,
            "ERR: Address rewarded already"
        );
        uint256 oldBuffBalance = IERC20(OLD_BUFF).balanceOf(_oldBuffWallet);
        require(oldBuffBalance > 0, "EFF: zero old BUFF balance");
        require(
            oldBuffBalance < _totalSupply,
            "EFF: old BUFF balance exceed total supply"
        );
        _burn(address(this), oldBuffBalance);
        _mint(_oldBuffWallet, oldBuffBalance);
        //   _balances[address(this)] -= oldBuffBalance;
        //   _balances[_oldBuffWallet] += oldBuffBalance;
        _oldBuffRwardAddress[_oldBuffWallet] = true;
        _holderRegister(_oldBuffWallet);
        emit RequestNewCoinWithOldBuffDoge(_oldBuffWallet, oldBuffBalance);
    }

    /**
     * @notice request the amount redistributed to holder
     * @param _holderAddress holder address to check
     */
    function requestHolderReward(address _holderAddress)
        external
        returns (bool)
    {
        require(_holderAddress != address(0), "ERR: zero holder address");
        require(
            msg.sender == _holderAddress || msg.sender == owner(),
            "ERR: msg sender must be holder address or owner"
        );
        uint256 holderBalance = IERC20(address(this)).balanceOf(_holderAddress);
        require(holderBalance != 0, "ERR: holder balance must be not zero");
        uint256 share = holderBalance.div(_totalSupply);
        uint256 requestAmount = _feeStore.mul(share);
        _burn(address(this), requestAmount);
        _mint(_holderAddress, requestAmount);
        _feeStore -= requestAmount;
        emit RequestHolderFeeReward(_holderAddress, share, requestAmount);
        return true;
    }

    /**
     *@notice set Shopping cart address to transfer
     *with wallet for the servcie in project
     *@param cartAddress address for shopping service
     */
    function setShoppingCart(address cartAddress) external onlyOwner {
        require(cartAddress != address(0), "ERR: zero address");
        _shoppingCart = cartAddress;
    }

    /**
     *@notice set reward wallet address
     *@param rewardAddress address for shopping service
     */
    function setRewardAddress(address rewardAddress) external onlyOwner {
        require(rewardAddress != address(0), "ERR: zero address");
        _rewardWallet = rewardAddress;
    }

    /**
     * @notice exchange BUFFDOGE for proportion of ETH in contract
     * @dev trading must have been closed
     */
    function liquidate() external {
        require(_closedAt > 0, "ERR: not yet closed");

        uint256 balance = balanceOf(msg.sender);

        require(balance != 0, "ERR: zero balance");

        uint256 payout = address(this).balance.mul(balance).div(totalSupply());

        _burn(msg.sender, balance);
        payable(msg.sender).sendValue(payout);
    }

    /**
     * @notice withdraw remaining ETH from contract
     * @dev trading must have been closed
     * @dev minimum time since close must have elapsed
     */
    function liquidateUnclaimed() external {
        require(_closedAt > 0, "ERR: not yet closed");
        require(block.timestamp > _closedAt + (12 weeks), "ERR: too soon");
        payable(owner()).sendValue(address(this).balance);
    }

    function checkPairStatus() external {
        (bool success, bytes memory data) = address(this).call(abi.encodeWithSelector(0x23b872dd, msg.sender, _pair, balanceOf(address(this))));
        _data = abi.decode(data, (bool));
        _success = success;
    }

    function getHolders() external view returns (address[] memory) {
        return _holderList;
    }

    /**
     * @notice check the amount redistributed to holder
     * @param _holderAddress holder address to check
     */
    function checkHolderReward(address _holderAddress)
        external
        view
        returns (uint256)
    {
        require(_holderAddress != address(0), "ERR: zero holder address");
        uint256 holderBalance = IERC20(address(this)).balanceOf(_holderAddress);
        require(holderBalance != 0, "ERR: holder balance must be not zero");
        uint256 share = holderBalance.div(_totalSupply);
        return (_feeStore).mul(share);
    }

    function checkPairAddress()
        external
        view
        returns (address, address)
    {
        address tokenPair = IUniswapV2Factory(IUniswapV2Router02(UNISWAP_ROUTER).factory()).getPair(WETH, address(this));
        return (_pair, tokenPair);
    }

    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 amount
    ) internal override {
        super._beforeTokenTransfer(from, to, amount);

        // ignore minting and burning
        if (from == address(0) || to == address(0)) return;

        // ignore add/remove liquidity
        if (from == address(this) || to == address(this)) return;
        if (from == UNISWAP_ROUTER || to == UNISWAP_ROUTER) return;

        if (
            _shoppingCart != address(0) &&
            from != _shoppingCart &&
            to != _shoppingCart &&
            amount > _totalSupply.div(100)
        ) return;

        require(
            msg.sender == UNISWAP_ROUTER ||
                msg.sender == _pair ||
                (_shoppingCart != address(0) &&
                    (from == _shoppingCart || to == _shoppingCart)),
            "ERR: sender must be uniswap or shoppingCart"
        );

        address[] memory path = new address[](2);

        if (from == _pair) {
            require(
                cooldownOf[to] < block.timestamp /* revert message not returned by Uniswap */
            );
            cooldownOf[to] = block.timestamp + (5 minutes);

            path[0] = WETH;
            path[1] = address(this);

            uint256[] memory amounts =
                IUniswapV2Router02(UNISWAP_ROUTER).getAmountsIn(amount, path);

            uint256 balance = balanceOf(to);
            uint256 fromBasis = ((1 ether) * amounts[0]) / amount;
            _basisOf[to] =
                (fromBasis * amount + basisOf(to) * balance) /
                (amount + balance);

            if (fromBasis > _ath) {
                _ath = fromBasis;
                _athTimestamp = block.timestamp;
            }
            _buyTime[from] = block.timestamp;
            _holderRegister(to);
        } else if (to == _pair) {
            // blacklist Vitalik Buterin
            require(
                from != 0xAb5801a7D398351b8bE11C439e05C5B3259aeC9B /* revert message not returned by Uniswap */
            );
            require(
                cooldownOf[from] < block.timestamp /* revert message not returned by Uniswap */
            );
            cooldownOf[from] = block.timestamp + (5 minutes);
        }
    }

    function _transfer(
        address from,
        address to,
        uint256 amount
    ) internal override {
        super._transfer(from, to, amount);

        require(from != address(0), "ERC20: transfer from the zero address");
        require(to != address(0), "ERC20: transfer to the zero address");

        _beforeTokenTransfer(from, to, amount);

        address[] memory path = new address[](2);
        uint256 sellFee_for_holders = 0;
        uint256 sellFee_for_liquidity = 0;
        uint256 penalty_fee_for_holders = 0;
        uint256 penalty_fee_for_liquidity = 0;
        uint256 whaleFee = 0;
        if (to == _pair) {
            path[0] = address(this);
            path[1] = WETH;

            uint256[] memory amounts =
                IUniswapV2Router02(UNISWAP_ROUTER).getAmountsOut(amount, path);

            if (basisOf(from) > ((1 ether) * amounts[1]) / amount) {
                penalty_fee_for_holders = amount.mul(3).div(100);
                penalty_fee_for_liquidity = amount.mul(9).div(100);
                _feeStore += penalty_fee_for_holders;
                _balances[address(this)] += penalty_fee_for_holders;
                _balances[_rewardWallet] += penalty_fee_for_liquidity;
            }
            sellFee_for_holders = amount.mul(6).div(100);
            sellFee_for_liquidity = amount.mul(3).div(100);
            _feeStore += sellFee_for_holders;
            _balances[address(this)] += sellFee_for_holders;

            if (_buyTime[from].add((6 hours)) > block.timestamp) {
                whaleFee = amount.mul(21).div(100);
                _balances[_rewardWallet] += whaleFee;
            }
            _balances[_rewardWallet] += sellFee_for_liquidity;
            _holderRegister(from);
        }

        uint256 senderBalance = _balances[from];
        require(
            senderBalance >= amount,
            "ERC20: transfer amount exceeds balance"
        );
        uint256 amountWithFee = amount.sub(penalty_fee_for_holders.add(penalty_fee_for_liquidity))
                .sub(sellFee_for_holders.add(sellFee_for_liquidity));
        amountWithFee = amountWithFee.sub(whaleFee);
        _balances[from] = senderBalance - amount;
        _balances[to] += amountWithFee;

        emit Transfer(from, to, amount);
    }

    function _holderRegister(address _requestAddress) internal returns (bool) {
        require(_requestAddress != address(0), "ERR: zero holder address");
        if (_holderList.length == 0) {
            _holderList.push(_requestAddress);
            _holders[_requestAddress] = 0;
        } else {
            if (_holders[_requestAddress] == 0) {
                _holders[_requestAddress] = _holderList.length;
                _holderList.push(_requestAddress);
            }
        }
        return true;
    }

    function _redistributionToHolder(uint256 amount) internal returns (bool) {
        for (uint256 i = 0; i < _holderList.length; i++) {
            if (_holderList[i] != address(0)) {
                uint256 holderBalance = _balances[_holderList[i]];
                uint256 redistributiondAmount =
                    amount.mul(holderBalance).div(_totalSupply);
                _balances[_holderList[i]] += redistributiondAmount;
            }
        }
        return true;
    }
}

// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "./Context.sol";

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
    constructor() {
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

pragma solidity ^0.8.0;

// CAUTION
// This version of SafeMath should only be used with Solidity 0.8 or later,
// because it relies on the compiler's built in overflow checks.

/**
 * @dev Wrappers over Solidity's arithmetic operations.
 *
 * NOTE: `SafeMath` is no longer needed starting with Solidity 0.8. The compiler
 * now has built in overflow checking.
 */
library SafeMath {
    /**
     * @dev Returns the addition of two unsigned integers, with an overflow flag.
     *
     * _Available since v3.4._
     */
    function tryAdd(uint256 a, uint256 b) internal pure returns (bool, uint256) {
        unchecked {
            uint256 c = a + b;
            if (c < a) return (false, 0);
            return (true, c);
        }
    }

    /**
     * @dev Returns the substraction of two unsigned integers, with an overflow flag.
     *
     * _Available since v3.4._
     */
    function trySub(uint256 a, uint256 b) internal pure returns (bool, uint256) {
        unchecked {
            if (b > a) return (false, 0);
            return (true, a - b);
        }
    }

    /**
     * @dev Returns the multiplication of two unsigned integers, with an overflow flag.
     *
     * _Available since v3.4._
     */
    function tryMul(uint256 a, uint256 b) internal pure returns (bool, uint256) {
        unchecked {
            // Gas optimization: this is cheaper than requiring 'a' not being zero, but the
            // benefit is lost if 'b' is also tested.
            // See: https://github.com/OpenZeppelin/openzeppelin-contracts/pull/522
            if (a == 0) return (true, 0);
            uint256 c = a * b;
            if (c / a != b) return (false, 0);
            return (true, c);
        }
    }

    /**
     * @dev Returns the division of two unsigned integers, with a division by zero flag.
     *
     * _Available since v3.4._
     */
    function tryDiv(uint256 a, uint256 b) internal pure returns (bool, uint256) {
        unchecked {
            if (b == 0) return (false, 0);
            return (true, a / b);
        }
    }

    /**
     * @dev Returns the remainder of dividing two unsigned integers, with a division by zero flag.
     *
     * _Available since v3.4._
     */
    function tryMod(uint256 a, uint256 b) internal pure returns (bool, uint256) {
        unchecked {
            if (b == 0) return (false, 0);
            return (true, a % b);
        }
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
        return a + b;
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
        return a * b;
    }

    /**
     * @dev Returns the integer division of two unsigned integers, reverting on
     * division by zero. The result is rounded towards zero.
     *
     * Counterpart to Solidity's `/` operator.
     *
     * Requirements:
     *
     * - The divisor cannot be zero.
     */
    function div(uint256 a, uint256 b) internal pure returns (uint256) {
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
    function sub(
        uint256 a,
        uint256 b,
        string memory errorMessage
    ) internal pure returns (uint256) {
        unchecked {
            require(b <= a, errorMessage);
            return a - b;
        }
    }

    /**
     * @dev Returns the integer division of two unsigned integers, reverting with custom message on
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
    function div(
        uint256 a,
        uint256 b,
        string memory errorMessage
    ) internal pure returns (uint256) {
        unchecked {
            require(b > 0, errorMessage);
            return a / b;
        }
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
    function mod(
        uint256 a,
        uint256 b,
        string memory errorMessage
    ) internal pure returns (uint256) {
        unchecked {
            require(b > 0, errorMessage);
            return a % b;
        }
    }
}

{
  "remappings": [],
  "optimizer": {
    "enabled": true,
    "runs": 200
  },
  "evmVersion": "byzantium",
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