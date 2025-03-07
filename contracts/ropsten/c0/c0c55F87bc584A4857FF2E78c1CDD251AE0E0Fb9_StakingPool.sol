//SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "../interfaces/IStakingPool.sol";
import "../interfaces/IRewardDistributor.sol";
import "../interfaces/IMoonKnight.sol";
import "../utils/PermissionGroup.sol";

contract StakingPool is IStakingPool, PermissionGroup {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.UintSet;

    uint public constant BASE_APY = 5;
    uint private constant ONE_YEAR_IN_SECONDS = 31536000;

    IERC20 public immutable acceptedToken;
    IRewardDistributor public immutable rewardDistributorContract;
    IMoonKnight public knightContract;
    uint public baseExp = 1000;
    uint public maxApy = 30;
    uint public endTime;
    mapping(uint => uint) public knightExp;
    mapping(address => mapping(uint => StakingData)) public stakingData;

    // All staking Knights of an address
    mapping(address => EnumerableSet.UintSet) private _stakingKnights;

    constructor(
        IERC20 tokenAddr,
        IMoonKnight knightAddr,
        IRewardDistributor distributorAddr
    ) {
        acceptedToken = tokenAddr;
        knightContract = knightAddr;
        rewardDistributorContract = distributorAddr;
    }

    function setMoonKnightContract(IMoonKnight knightAddr) external onlyOwner {
        require(address(knightAddr) != address(0));
        knightContract = knightAddr;
    }

    function setMaxApy(uint value) external onlyOwner {
        require(value > BASE_APY);
        maxApy = value;
    }

    function setBaseExp(uint value) external onlyOwner {
        require(value > 0);
        baseExp = value;
    }

    function endReward() external onlyOwner {
        endTime = block.timestamp;
    }

    function stake(uint knightId, uint amount, uint lockedMonths) external override {
        address account = msg.sender;

        StakingData storage stakingKnight = stakingData[account][knightId];

        if (block.timestamp < stakingKnight.lockedTime) {
            require(lockedMonths >= stakingKnight.lockedMonths, "StakingPool: lockMonths must be equal or higher");
        }

        _harvest(knightId, account);

        uint apy = lockedMonths * BASE_APY;
        stakingKnight.APY = apy == 0 ? BASE_APY : apy > maxApy ? maxApy : apy;
        stakingKnight.balance += amount;
        stakingKnight.lockedTime = block.timestamp + lockedMonths * 30 days;
        stakingKnight.lockedMonths = lockedMonths;

        _stakingKnights[account].add(knightId);

        acceptedToken.safeTransferFrom(account, address(this), amount);

        emit Staked(knightId, account, amount, lockedMonths);
    }

    function unstake(uint knightId, uint amount) external override {
        address account = msg.sender;
        StakingData storage stakingKnight = stakingData[account][knightId];

        require(block.timestamp >= stakingKnight.lockedTime, "StakingPool: still locked");
        require(stakingKnight.balance >= amount, "StakingPool: insufficient balance");

        _harvest(knightId, account);

        uint newBalance = stakingKnight.balance - amount;
        stakingKnight.balance = newBalance;

        if (newBalance == 0) {
            _stakingKnights[account].remove(knightId);
            stakingKnight.APY = 0;
            stakingKnight.lockedTime = 0;
            stakingKnight.lockedMonths = 0;
        }

        acceptedToken.safeTransfer(account, amount);

        emit Unstaked(knightId, account, amount);
    }

    function claim(uint knightId) external override {
        address account = msg.sender;
        StakingData storage stakingKnight = stakingData[account][knightId];

        require(stakingKnight.balance > 0);

        _harvest(knightId, account);

        uint reward = stakingKnight.reward;
        stakingKnight.reward = 0;
        rewardDistributorContract.distributeReward(account, reward);

        emit Claimed(knightId, account, reward);
    }

    function convertExpToLevels(uint knightId, uint levelUpAmount) external override {
        _harvest(knightId, msg.sender);

        uint currentLevel = knightContract.getKnightLevel(knightId);
        uint currentExp = knightExp[knightId];
        uint requiredExp = (levelUpAmount * (2 * currentLevel + levelUpAmount - 1) / 2) * baseExp * 1e18;

        require(currentExp >= requiredExp, "StakingPool: not enough exp");

        knightExp[knightId] -= requiredExp;
        knightContract.levelUp(knightId, levelUpAmount);
    }

    function earned(uint knightId, address account) public view override returns (uint expEarned, uint tokenEarned) {
        StakingData memory stakingKnight = stakingData[account][knightId];
        uint lastUpdatedTime = stakingKnight.lastUpdatedTime;
        uint currentTime = endTime != 0 ? endTime : block.timestamp;
        uint stakedTime = lastUpdatedTime > currentTime ? 0 : currentTime - lastUpdatedTime;
        uint stakedTimeInSeconds = lastUpdatedTime == 0 ? 0 : stakedTime;
        uint stakingDuration = stakingKnight.balance * stakedTimeInSeconds;

        expEarned = stakingDuration / 1e5;
        tokenEarned = stakingDuration / ONE_YEAR_IN_SECONDS * stakingKnight.APY / 100;
    }

    function balanceOf(uint knightId, address account) external view override returns (uint) {
        return stakingData[account][knightId].balance;
    }

    function _harvest(uint knightId, address account) private {
        (uint expEarned, uint tokenEarned) = earned(knightId, account);

        knightExp[knightId] += expEarned;

        StakingData storage stakingKnight = stakingData[account][knightId];
        stakingKnight.lastUpdatedTime = block.timestamp;
        stakingKnight.reward += tokenEarned;
    }
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
 * @dev Library for managing
 * https://en.wikipedia.org/wiki/Set_(abstract_data_type)[sets] of primitive
 * types.
 *
 * Sets have the following properties:
 *
 * - Elements are added, removed, and checked for existence in constant time
 * (O(1)).
 * - Elements are enumerated in O(n). No guarantees are made on the ordering.
 *
 * ```
 * contract Example {
 *     // Add the library methods
 *     using EnumerableSet for EnumerableSet.AddressSet;
 *
 *     // Declare a set state variable
 *     EnumerableSet.AddressSet private mySet;
 * }
 * ```
 *
 * As of v3.3.0, sets of type `bytes32` (`Bytes32Set`), `address` (`AddressSet`)
 * and `uint256` (`UintSet`) are supported.
 */
library EnumerableSet {
    // To implement this library for multiple types with as little code
    // repetition as possible, we write it in terms of a generic Set type with
    // bytes32 values.
    // The Set implementation uses private functions, and user-facing
    // implementations (such as AddressSet) are just wrappers around the
    // underlying Set.
    // This means that we can only create new EnumerableSets for types that fit
    // in bytes32.

    struct Set {
        // Storage of set values
        bytes32[] _values;

        // Position of the value in the `values` array, plus 1 because index 0
        // means a value is not in the set.
        mapping (bytes32 => uint256) _indexes;
    }

    /**
     * @dev Add a value to a set. O(1).
     *
     * Returns true if the value was added to the set, that is if it was not
     * already present.
     */
    function _add(Set storage set, bytes32 value) private returns (bool) {
        if (!_contains(set, value)) {
            set._values.push(value);
            // The value is stored at length-1, but we add 1 to all indexes
            // and use 0 as a sentinel value
            set._indexes[value] = set._values.length;
            return true;
        } else {
            return false;
        }
    }

    /**
     * @dev Removes a value from a set. O(1).
     *
     * Returns true if the value was removed from the set, that is if it was
     * present.
     */
    function _remove(Set storage set, bytes32 value) private returns (bool) {
        // We read and store the value's index to prevent multiple reads from the same storage slot
        uint256 valueIndex = set._indexes[value];

        if (valueIndex != 0) { // Equivalent to contains(set, value)
            // To delete an element from the _values array in O(1), we swap the element to delete with the last one in
            // the array, and then remove the last element (sometimes called as 'swap and pop').
            // This modifies the order of the array, as noted in {at}.

            uint256 toDeleteIndex = valueIndex - 1;
            uint256 lastIndex = set._values.length - 1;

            // When the value to delete is the last one, the swap operation is unnecessary. However, since this occurs
            // so rarely, we still do the swap anyway to avoid the gas cost of adding an 'if' statement.

            bytes32 lastvalue = set._values[lastIndex];

            // Move the last value to the index where the value to delete is
            set._values[toDeleteIndex] = lastvalue;
            // Update the index for the moved value
            set._indexes[lastvalue] = toDeleteIndex + 1; // All indexes are 1-based

            // Delete the slot where the moved value was stored
            set._values.pop();

            // Delete the index for the deleted slot
            delete set._indexes[value];

            return true;
        } else {
            return false;
        }
    }

    /**
     * @dev Returns true if the value is in the set. O(1).
     */
    function _contains(Set storage set, bytes32 value) private view returns (bool) {
        return set._indexes[value] != 0;
    }

    /**
     * @dev Returns the number of values on the set. O(1).
     */
    function _length(Set storage set) private view returns (uint256) {
        return set._values.length;
    }

   /**
    * @dev Returns the value stored at position `index` in the set. O(1).
    *
    * Note that there are no guarantees on the ordering of values inside the
    * array, and it may change when more values are added or removed.
    *
    * Requirements:
    *
    * - `index` must be strictly less than {length}.
    */
    function _at(Set storage set, uint256 index) private view returns (bytes32) {
        require(set._values.length > index, "EnumerableSet: index out of bounds");
        return set._values[index];
    }

    // Bytes32Set

    struct Bytes32Set {
        Set _inner;
    }

    /**
     * @dev Add a value to a set. O(1).
     *
     * Returns true if the value was added to the set, that is if it was not
     * already present.
     */
    function add(Bytes32Set storage set, bytes32 value) internal returns (bool) {
        return _add(set._inner, value);
    }

    /**
     * @dev Removes a value from a set. O(1).
     *
     * Returns true if the value was removed from the set, that is if it was
     * present.
     */
    function remove(Bytes32Set storage set, bytes32 value) internal returns (bool) {
        return _remove(set._inner, value);
    }

    /**
     * @dev Returns true if the value is in the set. O(1).
     */
    function contains(Bytes32Set storage set, bytes32 value) internal view returns (bool) {
        return _contains(set._inner, value);
    }

    /**
     * @dev Returns the number of values in the set. O(1).
     */
    function length(Bytes32Set storage set) internal view returns (uint256) {
        return _length(set._inner);
    }

   /**
    * @dev Returns the value stored at position `index` in the set. O(1).
    *
    * Note that there are no guarantees on the ordering of values inside the
    * array, and it may change when more values are added or removed.
    *
    * Requirements:
    *
    * - `index` must be strictly less than {length}.
    */
    function at(Bytes32Set storage set, uint256 index) internal view returns (bytes32) {
        return _at(set._inner, index);
    }

    // AddressSet

    struct AddressSet {
        Set _inner;
    }

    /**
     * @dev Add a value to a set. O(1).
     *
     * Returns true if the value was added to the set, that is if it was not
     * already present.
     */
    function add(AddressSet storage set, address value) internal returns (bool) {
        return _add(set._inner, bytes32(uint256(uint160(value))));
    }

    /**
     * @dev Removes a value from a set. O(1).
     *
     * Returns true if the value was removed from the set, that is if it was
     * present.
     */
    function remove(AddressSet storage set, address value) internal returns (bool) {
        return _remove(set._inner, bytes32(uint256(uint160(value))));
    }

    /**
     * @dev Returns true if the value is in the set. O(1).
     */
    function contains(AddressSet storage set, address value) internal view returns (bool) {
        return _contains(set._inner, bytes32(uint256(uint160(value))));
    }

    /**
     * @dev Returns the number of values in the set. O(1).
     */
    function length(AddressSet storage set) internal view returns (uint256) {
        return _length(set._inner);
    }

   /**
    * @dev Returns the value stored at position `index` in the set. O(1).
    *
    * Note that there are no guarantees on the ordering of values inside the
    * array, and it may change when more values are added or removed.
    *
    * Requirements:
    *
    * - `index` must be strictly less than {length}.
    */
    function at(AddressSet storage set, uint256 index) internal view returns (address) {
        return address(uint160(uint256(_at(set._inner, index))));
    }


    // UintSet

    struct UintSet {
        Set _inner;
    }

    /**
     * @dev Add a value to a set. O(1).
     *
     * Returns true if the value was added to the set, that is if it was not
     * already present.
     */
    function add(UintSet storage set, uint256 value) internal returns (bool) {
        return _add(set._inner, bytes32(value));
    }

    /**
     * @dev Removes a value from a set. O(1).
     *
     * Returns true if the value was removed from the set, that is if it was
     * present.
     */
    function remove(UintSet storage set, uint256 value) internal returns (bool) {
        return _remove(set._inner, bytes32(value));
    }

    /**
     * @dev Returns true if the value is in the set. O(1).
     */
    function contains(UintSet storage set, uint256 value) internal view returns (bool) {
        return _contains(set._inner, bytes32(value));
    }

    /**
     * @dev Returns the number of values on the set. O(1).
     */
    function length(UintSet storage set) internal view returns (uint256) {
        return _length(set._inner);
    }

   /**
    * @dev Returns the value stored at position `index` in the set. O(1).
    *
    * Note that there are no guarantees on the ordering of values inside the
    * array, and it may change when more values are added or removed.
    *
    * Requirements:
    *
    * - `index` must be strictly less than {length}.
    */
    function at(UintSet storage set, uint256 index) internal view returns (uint256) {
        return uint256(_at(set._inner, index));
    }
}

//SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IStakingPool {
    event Staked(uint indexed knightId, address indexed account, uint amount, uint lockedMonths);
    event Unstaked(uint indexed knightId, address indexed account, uint amount);
    event Exited(address indexed account, uint totalBalance);
    event Claimed(uint indexed knightId, address indexed account, uint reward);

    struct StakingData {
        uint balance;
        uint APY;
        uint lastUpdatedTime;
        uint lockedTime;
        uint lockedMonths;
        uint reward;
    }

    /**
     * @notice Stake FARA crystals for farming knight EXP & FARA token.
     */
    function stake(uint knightId, uint amount, uint lockedMonths) external;

    /**
     * @notice Unstake FARA crystals from a knight.
     */
    function unstake(uint knightId, uint amount) external;

    /**
     * @notice Harvest all EXP and reward earned from a Knight.
     */
    function claim(uint knightId) external;

    /**
     * @notice Convert all accumulated exp from staking to knight's levels.
     */
    function convertExpToLevels(uint knightId, uint levelUpAmount) external;

    /**
     * @notice Gets EXP and FARA earned by a knight so far.
     */
    function earned(uint knightId, address account) external view returns (uint expEarned, uint tokenEarned);

    /**
     * @notice Gets total FARA staked of a Knight.
     */
    function balanceOf(uint knightId, address account) external view returns (uint);
}

//SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IRewardDistributor {
    /**
     * @notice Distribute reward earned from Staking Pool
     */
    function distributeReward(address account, uint amount) external;
}

//SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IMoonKnight {
    struct Knight {
        string name;
        uint level;
        uint floorPrice;
        uint mainWeapon;
        uint subWeapon;
        uint headgear;
        uint armor;
        uint footwear;
        uint pants;
        uint gloves;
        uint mount;
        uint troop;
    }

    struct Version {
        uint startingIndex;
        uint currentSupply;
        uint maxSupply;
        uint salePrice;
        uint startTime;
        uint revealTime;
        string provenance; // This is the provenance record of all MoonKnight artworks in existence.
    }

    event KnightCreated(uint indexed knightId, uint floorPrice);
    event KnightListed(uint indexed knightId, uint price);
    event KnightDelisted(uint indexed knightId);
    event KnightBought(uint indexed knightId, address buyer, address seller, uint price);
    event KnightOffered(uint indexed knightId, address buyer, uint price);
    event KnightOfferCanceled(uint indexed knightId, address buyer);
    event KnightPriceIncreased(uint indexed knightId, uint floorPrice, uint increasedAmount);
    event NameChanged(uint indexed knightId, string newName);
    event PetAdopted(uint indexed knightId, uint indexed petId);
    event PetReleased(uint indexed knightId, uint indexed petId);
    event SkillLearned(uint indexed knightId, uint indexed skillId);
    event ItemsEquipped(uint indexed knightId, uint[] itemIds);
    event ItemsUnequipped(uint indexed knightId, uint[] itemIds);
    event KnightLeveledUp(uint indexed knightId, uint level, uint amount);
    event DuelConcluded(uint indexed winningKnightId, uint indexed losingKnightId, uint penaltyAmount);
    event StartingIndexFinalized(uint versionId, uint startingIndex);
    event NewVersionAdded(uint versionId);

    /**
     * @notice Claims moon knights when it's on presale phase.
     */
    function claimMoonKnight(uint versionId, uint amount) external payable;

    /**
     * @notice Changes a knight's name.
     *
     * Requirements:
     * - `newName` must be a valid string.
     * - `newName` is not duplicated to other.
     * - Token required: `serviceFeeInToken`.
     */
    function changeKnightName(uint knightId, string memory newName) external;

    /**
     * @notice Anyone can call this function to manually add `floorPrice` to a knight.
     *
     * Requirements:
     * - `msg.value` must not be zero.
     * - knight's `floorPrice` must be under `floorPriceCap`.
     * - Token required: `serviceFeeInToken` * value
     */
    function addFloorPriceToKnight(uint knightId) external payable;

    /**
     * @notice Owner equips items to their knight by burning ERC1155 Equipment NFTs.
     *
     * Requirements:
     * - caller must be owner of the knight.
     */
    function equipItems(uint knightId, uint[] memory itemIds) external;

    /**
     * @notice Owner removes items from their knight. ERC1155 Equipment NFTs are minted back to the owner.
     *
     * Requirements:
     * - caller must be owner of the knight.
     */
    function removeItems(uint knightId, uint[] memory itemIds) external;

    /**
     * @notice Burns a knight to claim its `floorPrice`.
     *
     * - Not financial advice: DONT DO THAT.
     * - Remember to remove all items before calling this function.
     */
    function sacrificeKnight(uint knightId) external;

    /**
     * @notice Lists a knight on sale.
     *
     * Requirements:
     * - `price` cannot be under knight's `floorPrice`.
     * - Caller must be the owner of the knight.
     */
    function list(uint knightId, uint price) external;

    /**
     * @notice Delist a knight on sale.
     */
    function delist(uint knightId) external;

    /**
     * @notice Instant buy a specific knight on sale.
     *
     * Requirements:
     * - Target knight must be currently on sale.
     * - Sent value must be exact the same as current listing price.
     */
    function buy(uint knightId) external payable;

    /**
     * @notice Gives offer for a knight.
     *
     * Requirements:
     * - Owner cannot offer.
     */
    function offer(uint knightId, uint offerValue) external payable;

    /**
     * @notice Owner take an offer to sell their knight.
     *
     * Requirements:
     * - Cannot take offer under knight's `floorPrice`.
     * - Offer value must be at least equal to `minPrice`.
     */
    function takeOffer(uint knightId, address offerAddr, uint minPrice) external;

    /**
     * @notice Cancels an offer for a specific knight.
     */
    function cancelOffer(uint knightId) external;

    /**
     * @notice Learns a skill for given Knight.
     */
    function learnSkill(uint knightId, uint skillId) external;

    /**
     * @notice Adopts a Pet.
     */
    function adoptPet(uint knightId, uint petId) external;

    /**
     * @notice Abandons a Pet attached to a Knight.
     */
    function abandonPet(uint knightId) external;

    /**
     * @notice Operators can level up a Knight
     */
    function levelUp(uint knightId, uint amount) external;

    /**
     * @notice Finalizes the battle aftermath of 2 knights.
     */
    function finalizeDuelResult(uint winningKnightId, uint losingKnightId, uint penaltyInBps) external;

    /**
     * @notice Gets knight information.
     */
    function getKnight(uint knightId) external view returns (
        string memory name,
        uint level,
        uint floorPrice,
        uint pet,
        uint[] memory skills,
        uint[9] memory equipment
    );

    /**
     * @notice Gets current level of given knight.
     */
    function getKnightLevel(uint knightId) external view returns (uint);
}

//SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Context.sol";

contract PermissionGroup is Ownable {
    // List of authorized address to perform some restricted actions
    mapping(address => bool) public operators;

    modifier onlyOperator() {
        require(operators[msg.sender], "PermissionGroup: not operator");
        _;
    }

    /**
     * @notice Adds an address as operator.
     */
    function addOperator(address operator) external onlyOwner {
        operators[operator] = true;
    }

    /**
    * @notice Removes an address as operator.
    */
    function removeOperator(address operator) external onlyOwner {
        operators[operator] = false;
    }
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

// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

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
    constructor () {
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

{
  "optimizer": {
    "enabled": true,
    "runs": 322
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