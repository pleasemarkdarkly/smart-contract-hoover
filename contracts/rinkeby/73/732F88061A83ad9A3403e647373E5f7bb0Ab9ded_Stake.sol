// SPDX-License-Identifier: MIT

pragma solidity ^0.6.12;
pragma experimental ABIEncoderV2;
import "./@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./Ownable.sol";

contract Stake is Ownable {
    receive() external payable {}
    event UserDepositEvent(address indexed Stakeer, uint256 indexed StakeID);
    event UserWithdrawEvent(uint256 indexed stakeID, uint256 indexed amount, bool indexed WithdrawAll);
    event WithdrawSuccess(address receiver, uint256 amount);

    struct UserStakeInfo {
        uint256 StakeID;
        uint256 StakePlan;
        uint AvailableWithdrawTime;
        uint256 Amount;
    }

    struct StakePlan {
        address ERC20ContractAddress; //ERC20 token address
        uint StakeTime;  // How long for this stakeing
        uint APY; //Percent(need div 100)
    }

    uint public StakePlanCount;
    uint internal StakeID;
    IERC20 private _token;

    address public GasFeePool;

    mapping(address => UserStakeInfo[]) public mappingUserStaking ;
    mapping(uint => StakePlan)  public  mappingStakePlan;

    function addStakePlan(address ERC20 , uint StakeTime, uint APY) public onlyOwner {
        require(ERC20 != address(0) && StakeTime > 0, "Please input correct params.");
        mappingStakePlan[StakePlanCount].ERC20ContractAddress = ERC20;
        mappingStakePlan[StakePlanCount].StakeTime = StakeTime;
        mappingStakePlan[StakePlanCount].APY = APY;
        StakePlanCount+=1;
    }

    function deposit(uint stakePlanNumber, uint256 amount) public {
        _token = IERC20(mappingStakePlan[stakePlanNumber].ERC20ContractAddress);
        require(_token.transferFrom(msg.sender, address(this), amount) == true, "Fail to transfer");

        UserStakeInfo memory UserStakeInfoStructData;
        UserStakeInfoStructData.StakeID = StakeID;
        UserStakeInfoStructData.Amount = amount;
        UserStakeInfoStructData.StakePlan = stakePlanNumber;
        UserStakeInfoStructData.AvailableWithdrawTime = block.timestamp + mappingStakePlan[stakePlanNumber].StakeTime;
        mappingUserStaking[msg.sender].push(UserStakeInfoStructData);
        emit UserDepositEvent(msg.sender , StakeID);
        StakeID += 1;
    }

    function withdrawRequest(uint256 amount, uint256 StakeId, bool withdrawAll) public payable {
        require(msg.value > 0, "You must pay the gas fee");
        address payable receiver = payable(GasFeePool);
        receiver.transfer(msg.value);
        emit UserWithdrawEvent(StakeId, amount, withdrawAll);
    }


    function checkAllValidDeposit(address stakeUser) public view returns(UserStakeInfo[] memory) {
        UserStakeInfo[] memory data = new UserStakeInfo[](mappingUserStaking[stakeUser].length);
        for (uint i = 0; i < mappingUserStaking[stakeUser].length; i++) {
            UserStakeInfo memory Temp = mappingUserStaking[stakeUser][i];
            data[i] = Temp;
        }
        return data;
    }

    function checkDepositByStakeID(address stakeUser, uint StakeStakeID) public view returns(UserStakeInfo memory) {
        UserStakeInfo memory data;
        for (uint i = 0; i < mappingUserStaking[stakeUser].length; i++) {
            if (mappingUserStaking[stakeUser][i].StakeID == StakeStakeID) {
                data = mappingUserStaking[stakeUser][i];
                break;
            }
        }
        return data;
    }


    function setGasFeePool(address poolAddress) onlyOwner public {
        GasFeePool = poolAddress;
    }

    function withdraw(address receiver, uint256 amount, uint stakePlanNumber) public onlyOperators {
        _token = IERC20(mappingStakePlan[stakePlanNumber].ERC20ContractAddress);
        require(_token.transfer(receiver,amount) == true,"Fail to transfer");
        emit WithdrawSuccess(receiver,amount);
    }



    //        function checkAvailableWithdraw(address receiver) public view returns(uint256) {
    //            uint256 AvailableWithdraw = 0;
    //            for(uint i = 0;i < mappingUserStakeing[receiver].length; i++) {
    //                if (block.timestamp >= mappingUserStakeing[receiver][i].WithdrawTime) {
    //                    avaliableWithdraw += mappingUserStakeing[receiver][i].Amount;
    //                }
    //            }
    //            return AvailableWithdraw;
    //        }


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
// Audit on 5-Jan-2021 by Keno and BoringCrypto

// P1 - P3: OK
pragma solidity 0.6.12;

// Source: https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/access/Ownable.sol + Claimable.sol
// Edited by BoringCrypto

// T1 - T4: OK
contract OwnableData {
    // V1 - V5: OK
    address public owner;
    // V1 - V5: OK
    address public pendingOwner;

    mapping(address => bool) mappingOperators;
}

// T1 - T4: OK
contract Ownable is OwnableData {
    // E1: OK
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    constructor () internal {
        owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);
    }

    // F1 - F9: OK
    // C1 - C21: OK
    function transferOwnership(address newOwner, bool direct, bool renounce) public onlyOwner {
        if (direct) {
            // Checks
            require(newOwner != address(0) || renounce, "Ownable: zero address");

            // Effects
            emit OwnershipTransferred(owner, newOwner);
            owner = newOwner;
        } else {
            // Effects
            pendingOwner = newOwner;
        }
    }

    // F1 - F9: OK
    // C1 - C21: OK
    function claimOwnership() public {
        address _pendingOwner = pendingOwner;

        // Checks
        require(msg.sender == _pendingOwner, "Ownable: caller != pending owner");

        // Effects
        emit OwnershipTransferred(owner, _pendingOwner);
        owner = _pendingOwner;
        pendingOwner = address(0);
    }

    function setOperator(address operator) public onlyOwner {
        mappingOperators[operator] = true;
    }

    function removeOperator(address operator) public onlyOwner {
        mappingOperators[operator] = false;
    }

    // M1 - M5: OK
    // C1 - C21: OK
    modifier onlyOwner() {
        require(msg.sender == owner, "Ownable: caller is not the owner");
        _;
    }
    modifier onlyOperators() {
        require(mappingOperators[msg.sender] == true , "Caller in not the operator");
        _;
    }
}

{
  "optimizer": {
    "enabled": true,
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
  "metadata": {
    "useLiteralContent": true
  },
  "libraries": {}
}