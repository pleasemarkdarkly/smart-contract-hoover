// SPDX-License-Identifier: MIT

pragma solidity 0.8.4;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import "./interfaces/IERC20Detailed.sol";

contract Portal is ReentrancyGuard {
    using SafeERC20 for IERC20Detailed;

    uint256 public startBlock;

    uint256 public endBlock;

    uint256 public totalStaked;

    uint256 public lastRewardBlock;

    uint256 public stakeLimit;

    uint256 public contractStakeLimit;

    uint256[] public rewardPerBlock;

    uint256[] public accumulatedRewardMultiplier;

    address[] public rewardsTokens;

    IERC20Detailed public stakingToken;

    struct UserInfo {
        uint256 firstStakedBlockNumber;
        uint256 amountStaked; // How many tokens the user has staked.
        uint256[] rewardDebt; //
        uint256[] tokensOwed; // How many tokens the contract owes to the user.
    }

    mapping(address => UserInfo) public userInfo;

    constructor(
        uint256 _startBlock,
        uint256 _endBlock,
        uint256 _stakeLimit,
        uint256 _contractStakeLimit,
        uint256[] memory _rewardPerBlock,
        address[] memory _rewardsTokens,
        IERC20Detailed _stakingToken
    ) {
        require(_startBlock > block.number, "Portal:: Invalid starting block.");
        require(_endBlock > block.number, "Portal:: Invalid ending block.");
        require(_rewardPerBlock.length == _rewardsTokens.length, "Portal:: Invalid rewards.");
        require(_stakeLimit != 0, "Portal:: Invalid user stake limit.");
        require(_contractStakeLimit != 0, "Portal:: Invalid total stake limit.");

        stakingToken = _stakingToken;
        rewardPerBlock = _rewardPerBlock;
        startBlock = _startBlock;
        endBlock = _endBlock;
        rewardsTokens = _rewardsTokens;
        lastRewardBlock = startBlock;
        stakeLimit = _stakeLimit;
        contractStakeLimit = _contractStakeLimit;

        for (uint256 i = 0; i < rewardsTokens.length; i++) {
            accumulatedRewardMultiplier.push(0);
        }
    }

    modifier onlyInsideBlockBounds() {
        require(block.number > startBlock, "Stake::Staking has not yet started");
        require(block.number <= endBlock, "Stake::Staking has finished");
        _;
    }

    modifier onlyUnderStakeLimit(address staker, uint256 newStake) {
        require(userInfo[staker].amountStaked + newStake <= stakeLimit, "Portal:: Stake limit exceed.");
        require(totalStaked + newStake <= contractStakeLimit, "Portal:: Contract Stake limit exceed.");
        _;
    }

    function stake(uint256 _tokenAmount) public nonReentrant {
        _stake(_tokenAmount, msg.sender);
    }

    function _stake(uint256 _tokenAmount, address staker) internal onlyInsideBlockBounds onlyUnderStakeLimit(staker, _tokenAmount) {
        require(_tokenAmount > 0, "Portal:: Cannot stake 0");

        UserInfo storage user = userInfo[staker];

        // if no amount has been staked this is considered the initial stake
        if (user.amountStaked == 0) {
            onInitialStake(staker);
        }

        updateRewardMultipliers(); // Update the accumulated multipliers for everyone
        updateUserAccruedReward(staker); // Update the accrued reward for this specific user

        user.amountStaked = user.amountStaked + _tokenAmount;
        totalStaked = totalStaked + _tokenAmount;

        uint256 rewardsTokensLength = rewardsTokens.length;

        for (uint256 i = 0; i < rewardsTokensLength; i++) {
            uint256 tokenDecimals = IERC20Detailed(rewardsTokens[i]).decimals();
            uint256 tokenMultiplier = 10**tokenDecimals;
            uint256 totalDebt = (user.amountStaked * accumulatedRewardMultiplier[i]) / tokenMultiplier;
            user.rewardDebt[i] = totalDebt;
        }

        stakingToken.transferFrom(msg.sender, address(this), _tokenAmount);
    }

    function claim() public nonReentrant {
        _claim(msg.sender);
    }

    function _claim(address claimer) internal {
        UserInfo storage user = userInfo[claimer];
        updateRewardMultipliers();
        updateUserAccruedReward(claimer);

        uint256 rewardsTokensLength = rewardsTokens.length;

        for (uint256 i = 0; i < rewardsTokensLength; i++) {
            uint256 reward = user.tokensOwed[i];
            user.tokensOwed[i] = 0;
            IERC20Detailed(rewardsTokens[i]).transfer(claimer, reward);
        }
    }

    function withdraw(uint256 _tokenAmount) public nonReentrant {
        _withdraw(_tokenAmount, msg.sender);
    }

    function _withdraw(uint256 _tokenAmount, address staker) internal {
        require(_tokenAmount > 0, "Portal:: Cannot withdraw 0");

        UserInfo storage user = userInfo[staker];

        updateRewardMultipliers();
        updateUserAccruedReward(staker);

        user.amountStaked = user.amountStaked - _tokenAmount;
        totalStaked = totalStaked - _tokenAmount;

        uint256 rewardsTokensLength = rewardsTokens.length;

        for (uint256 i = 0; i < rewardsTokensLength; i++) {
            uint256 tokenDecimals = IERC20Detailed(rewardsTokens[i]).decimals();
            uint256 tokenMultiplier = 10**tokenDecimals;
            uint256 totalDebt = (user.amountStaked * accumulatedRewardMultiplier[i]) / (tokenMultiplier);
            user.rewardDebt[i] = totalDebt;
        }

        stakingToken.transfer(staker, _tokenAmount);
    }

    function exit() public nonReentrant {
        _exit(msg.sender);
    }

    function _exit(address exiter) internal {
        UserInfo storage user = userInfo[exiter];
        _claim(exiter);
        _withdraw(user.amountStaked, exiter);
    }

    function balanceOf(address _userAddress) public view returns (uint256) {
        UserInfo storage user = userInfo[_userAddress];
        return user.amountStaked;
    }

    function onInitialStake(address _userAddress) internal {
        UserInfo storage user = userInfo[_userAddress];
        user.firstStakedBlockNumber = block.number;
    }

    function updateRewardMultipliers() public {
        uint256 currentBlock = block.number;

        if (currentBlock > lastRewardBlock) {
            uint256 applicableBlock = (currentBlock < endBlock) ? currentBlock : endBlock;
            uint256 blocksSinceLastReward = applicableBlock - lastRewardBlock;

            if (blocksSinceLastReward > 0) {
                if (totalStaked > 0) {
                    for (uint256 i = 0; i < rewardsTokens.length; i++) {
                        uint256 tokenDecimals = IERC20Detailed(rewardsTokens[i]).decimals();
                        uint256 tokenMultiplier = 10**tokenDecimals;

                        uint256 newReward = blocksSinceLastReward * rewardPerBlock[i];
                        uint256 rewardMultiplierIncrease = (newReward * tokenMultiplier) / totalStaked;
                        accumulatedRewardMultiplier[i] = accumulatedRewardMultiplier[i] + rewardMultiplierIncrease;
                    }
                }

                lastRewardBlock = applicableBlock;
            }
        }
    }

    function updateUserAccruedReward(address _userAddress) internal {
        UserInfo storage user = userInfo[_userAddress];

        initialiseUserRewardDebt(_userAddress);
        initialiseUserTokensOwed(_userAddress);

        if (user.amountStaked == 0) {
            return;
        }

        uint256 rewardsTokensLength = rewardsTokens.length;

        for (uint256 tokenIndex = 0; tokenIndex < rewardsTokensLength; tokenIndex++) {
            updateUserRewardForToken(_userAddress, tokenIndex);
        }
    }

    function initialiseUserTokensOwed(address _userAddress) internal {
        UserInfo storage user = userInfo[_userAddress];

        if (user.tokensOwed.length != rewardsTokens.length) {
            uint256 rewardsTokensLength = rewardsTokens.length;

            for (uint256 i = user.tokensOwed.length; i < rewardsTokensLength; i++) {
                user.tokensOwed.push(0);
            }
        }
    }

    function initialiseUserRewardDebt(address _userAddress) internal {
        UserInfo storage user = userInfo[_userAddress];

        if (user.rewardDebt.length != rewardsTokens.length) {
            uint256 rewardsTokensLength = rewardsTokens.length;

            for (uint256 i = user.rewardDebt.length; i < rewardsTokensLength; i++) {
                user.rewardDebt.push(0);
            }
        }
    }

    function updateUserRewardForToken(address _userAddress, uint256 tokenIndex) internal {
        UserInfo storage user = userInfo[_userAddress];
        uint256 tokenDecimals = IERC20Detailed(rewardsTokens[tokenIndex]).decimals();
        uint256 tokenMultiplier = 10**tokenDecimals;

        uint256 totalDebt = (user.amountStaked * accumulatedRewardMultiplier[tokenIndex]) / tokenMultiplier;
        uint256 pendingDebt = totalDebt - user.rewardDebt[tokenIndex];

        if (pendingDebt > 0) {
            user.tokensOwed[tokenIndex] = user.tokensOwed[tokenIndex] + pendingDebt;
            user.rewardDebt[tokenIndex] = totalDebt;
        }
    }

    function hasStakingStarted() public view returns (bool) {
        return (block.number >= startBlock);
    }

    function getUserRewardDebt(address _userAddress, uint256 _index) external view returns (uint256) {
        UserInfo storage user = userInfo[_userAddress];
        return user.rewardDebt[_index];
    }

    function getUserOwedTokens(address _userAddress, uint256 _index) external view returns (uint256) {
        UserInfo storage user = userInfo[_userAddress];
        return user.tokensOwed[_index];
    }

    function getUserAccumulatedReward(address _userAddress, uint256 tokenIndex) public view returns (uint256) {
        uint256 currentBlock = block.number;
        uint256 applicableBlock = (currentBlock < endBlock) ? currentBlock : endBlock;
        uint256 blocksSinceLastReward = applicableBlock - lastRewardBlock;

        uint256 tokenDecimals = IERC20Detailed(rewardsTokens[tokenIndex]).decimals();
        uint256 tokenMultiplier = 10**tokenDecimals;

        uint256 newReward = blocksSinceLastReward * rewardPerBlock[tokenIndex];
        uint256 rewardMultiplierIncrease = (newReward * tokenMultiplier) / totalStaked;
        uint256 currentMultiplier = accumulatedRewardMultiplier[tokenIndex] + rewardMultiplierIncrease;

        UserInfo storage user = userInfo[_userAddress];

        uint256 totalDebt = (user.amountStaked * currentMultiplier) / tokenMultiplier;
        uint256 pendingDebt = totalDebt - user.rewardDebt[tokenIndex];
        return user.tokensOwed[tokenIndex] + pendingDebt;
    }

    function getUserTokensOwedLength(address _userAddress) external view returns (uint256) {
        UserInfo storage user = userInfo[_userAddress];
        return user.tokensOwed.length;
    }

    function getUserRewardDebtLength(address _userAddress) external view returns (uint256) {
        UserInfo storage user = userInfo[_userAddress];
        return user.rewardDebt.length;
    }

    function extend(
        uint256 _endBlock,
        uint256[] memory _rewardsPerBlock,
        uint256[] memory _currentRemainingRewards,
        uint256[] memory _newRemainingRewards
    ) external nonReentrant {
        require(_endBlock > block.number, "Portal:: End block must be in the future");
        require(_endBlock >= endBlock, "Portal:: End block must be after the current end block");
        require(_rewardsPerBlock.length == rewardsTokens.length, "Portal:: Rewards amounts length is less than expected");
        updateRewardMultipliers();

        for (uint256 i = 0; i < _rewardsPerBlock.length; i++) {
            address rewardsToken = rewardsTokens[i];

            if (_currentRemainingRewards[i] > _newRemainingRewards[i]) {
                // Some reward leftover needs to be returned
                IERC20Detailed(rewardsToken).transfer(msg.sender, (_currentRemainingRewards[i] - _newRemainingRewards[i]));
            }

            rewardPerBlock[i] = _rewardsPerBlock[i];
        }

        endBlock = _endBlock;
    }

    function withdrawLPRewards(address recipient, address lpTokenContract) external nonReentrant {
        uint256 currentReward = IERC20Detailed(lpTokenContract).balanceOf(address(this));
        require(currentReward > 0, "Portal:: There are no rewards from liquidity pools");

        require(lpTokenContract != address(stakingToken), "Portal:: cannot withdraw from the LP tokens");

        uint256 rewardsTokensLength = rewardsTokens.length;

        for (uint256 i = 0; i < rewardsTokensLength; i++) {
            require(lpTokenContract != rewardsTokens[i], "Portal:: Cannot withdraw from token rewards");
        }
        IERC20Detailed(lpTokenContract).transfer(recipient, currentReward);
    }

    function calculateRewardsAmount(
        uint256 _startBlock,
        uint256 _endBlock,
        uint256 _rewardPerBlock
    ) internal pure returns (uint256) {
        require(_rewardPerBlock > 0, "Pool:: Rewards per block must be greater than zero");
        uint256 rewardsPeriod = _endBlock - _startBlock;
        return _rewardPerBlock * rewardsPeriod;
    }

    function getRewardTokensCount() public view returns (uint256) {
        return rewardsTokens.length;
    }
}

// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "../IERC20.sol";
import "../../../utils/Address.sol";

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
        uint256 newAllowance = token.allowance(address(this), spender) + value;
        _callOptionalReturn(token, abi.encodeWithSelector(token.approve.selector, spender, newAllowance));
    }

    function safeDecreaseAllowance(IERC20 token, address spender, uint256 value) internal {
        unchecked {
            uint256 oldAllowance = token.allowance(address(this), spender);
            require(oldAllowance >= value, "SafeERC20: decreased allowance below zero");
            uint256 newAllowance = oldAllowance - value;
            _callOptionalReturn(token, abi.encodeWithSelector(token.approve.selector, spender, newAllowance));
        }
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

pragma solidity ^0.8.0;

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

    constructor () {
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

// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

/**
 * @dev Interface of the ERC20 standard as defined in the EIP. Does not include
 * the optional functions; to access them see `ERC20Detailed`.
 */
interface IERC20Detailed {
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
     * Emits a `Transfer` event.
     */
    function transfer(address recipient, uint256 amount) external returns (bool);

    /**
     * @dev Returns the remaining number of tokens that `spender` will be
     * allowed to spend on behalf of `owner` through `transferFrom`. This is
     * zero by default.
     *
     * This value changes when `approve` or `transferFrom` are called.
     */
    function allowance(address owner, address spender) external view returns (uint256);

    /**
     * @dev Sets `amount` as the allowance of `spender` over the caller's tokens.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * > Beware that changing an allowance with this method brings the risk
     * that someone may use both the old and the new allowance by unfortunate
     * transaction ordering. One possible solution to mitigate this race
     * condition is to first reduce the spender's allowance to 0 and set the
     * desired value afterwards:
     * https://github.com/ethereum/EIPs/issues/20#issuecomment-263524729
     *
     * Emits an `Approval` event.
     */
    function approve(address spender, uint256 amount) external returns (bool);

    /**
     * @dev Moves `amount` tokens from `sender` to `recipient` using the
     * allowance mechanism. `amount` is then deducted from the caller's
     * allowance.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * Emits a `Transfer` event.
     */
    function transferFrom(
        address sender,
        address recipient,
        uint256 amount
    ) external returns (bool);

    /**
     * @dev Emitted when `value` tokens are moved from one account (`from`) to
     * another (`to`).
     *
     * Note that `value` may be zero.
     */
    event Transfer(address indexed from, address indexed to, uint256 value);

    /**
     * @dev Emitted when the allowance of a `spender` for an `owner` is set by
     * a call to `approve`. `value` is the new allowance.
     */
    event Approval(address indexed owner, address indexed spender, uint256 value);

    /**
     * @dev Returns the name of the token.
     */
    function name() external view returns (string memory);

    /**
     * @dev Returns the symbol of the token, usually a shorter version of the
     * name.
     */
    function symbol() external view returns (string memory);

    /**
     * @dev Returns the number of decimals used to get its user representation.
     * For example, if `decimals` equals `2`, a balance of `505` tokens should
     * be displayed to a user as `5,05` (`505 / 10 ** 2`).
     *
     * Tokens usually opt for a value of 18, imitating the relationship between
     * Ether and Wei.
     *
     * > Note that this information is only used for _display_ purposes: it in
     * no way affects any of the arithmetic of the contract, including
     * `IERC20.balanceOf` and `IERC20.transfer`.
     */
    function decimals() external view returns (uint8);
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

{
  "metadata": {
    "bytecodeHash": "none"
  },
  "optimizer": {
    "enabled": true,
    "runs": 800
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