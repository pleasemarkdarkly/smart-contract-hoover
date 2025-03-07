// SPDX-License-Identifier: MIT
//This is the upgraded Treasury

pragma solidity 0.6.12;

/**
 * This contract is a fork of Basis Cash Treasury contract, adapted to send a certain percentage
 * of mint tokens of allocateSeigniorage function to an initializable and changeable fund.
 * by PaprPrintr
 *
 * _____                     _____        _         _         
 *|  __ \                   |  __ \      (_)       | |        
 *| |__) |__ _  _ __   _ __ | |__) |_ __  _  _ __  | |_  _ __ 
 *|  ___// _` || '_ \ | '__||  ___/| '__|| || '_ \ | __|| '__|
 *| |   | (_| || |_) || |   | |    | |   | || | | || |_ | |   
 *|_|    \__,_|| .__/ |_|   |_|    |_|   |_||_| |_| \__||_|   
 *             |_|                                         
 */


import "@openzeppelin/contracts/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import './interfaces/ISimpleERCFund.sol';
import './owner/DoubleOperator.sol';

import "./lib/Babylonian.sol";
import "./owner/Operator.sol";
import "./utils/ContractGuard.sol";
import "./interfaces/IBasisAsset.sol";
import "./interfaces/IOracle.sol";
import "./interfaces/IBoardroom.sol";



/**
 * @title Basis Cash Treasury contract
 * @notice Monetary policy logic to adjust supplies of basis cash assets
 * @author Summer Smith & Rick Sanchez
 */

contract Treasury is ContractGuard   {
    using SafeERC20 for IERC20;
    using AddressUpgradeable for address;
    using SafeMath for uint256;

    /* ========= CONSTANT VARIABLES ======== */

    uint256 public constant PERIOD = 0.1 hours;

    /* ========== STATE VARIABLES ========== */

    // governance
    address public operator;

    // flags
    bool public migrated;
    bool public initialized;

    // epoch
    uint256 public startTime;
    uint256 public epoch;
    uint256 public epochSupplyContractionLeft;

    // core components
    address public fund;
    address public papr; // "Cash"
    address public ink; // "Bond"
    address public printr; //"Share"

    address public boardroom;
    address public paprOracle;

    // price
    uint256 public paprPriceOne;
    uint256 public paprPriceCeiling;
    uint256 public paprPriceOverExpansionCeiling;

    uint256 public seigniorageSaved;

    // protocol parameters
    uint256 public maxSupplyExpansionPercent;
    uint256 public maxSupplyExpansionPercentInDebtPhase;
    uint256 public inkDepletionFloorPercent;
    uint256 public seigniorageExpansionFloorPercent;
    uint256 public maxSupplyContractionPercent;
    uint256 public maxDeptRatioPercent;
    uint256 public BootstrapEpochs;
    uint256 public BootstrapSupplyExpansionPercent;
    uint256 public paprMultiplierStepExpansion;

    // multiplier when the price is above 1.5
    uint256 public printingRatioMultiplier; //%

    // paperprinter fund
    uint256 public fundAllocationRate; // %

    /* =================== Events =================== */
 
    event Initialized(address indexed executor, uint256 at);
    event Migration(address indexed target);
    event RedeemedInks(address indexed from, uint256 amount);
    event BoughtInks(address indexed from, uint256 amount);
    event TreasuryFunded(uint256 timestamp, uint256 seigniorage);
    event BoardroomFunded(uint256 timestamp, uint256 seigniorage);

//==========================================//
    /* =================== Modifier =================== */

    modifier onlyOperator() {
        require(operator == msg.sender, "Caller is not the operator");
        _;
    }

    function checkCondition() private {
        require(!migrated, "Migrated");
        require(now >= startTime, "Not started yet");
    }

    function checkEpoch() private  {
        require(now >= nextEpochPoint(), "Not opened yet");

        epoch = epoch.add(1);
        epochSupplyContractionLeft = IERC20(papr).totalSupply().mul(maxSupplyContractionPercent).div(10000);
    }

    function checkOperator() private {
        require(
            IBasisAsset(papr).operator() == address(this) &&
                IBasisAsset(ink).operator() == address(this) &&
                IBasisAsset(printr).operator() == address(this) &&
                Operator(boardroom).operator() == address(this), 
            "Need more permission"
        );
    }

    /* ========== VIEW FUNCTIONS ========== */

    // flags
    function isMigrated() public view returns (bool) {
        return migrated;
    }

    function isInitialized() public view returns (bool) {
        return initialized;
    }

    // epoch
    function nextEpochPoint() public view returns (uint256) {
        return startTime.add(epoch.mul(PERIOD));
    }

    // oracle
    function getPaprPrice() public view returns (uint256 paprPrice) {
        try IOracle(paprOracle).consult(papr, 1e18) returns (uint256 price) {
            return price;
        } catch {
            revert("Failed to consult papr price from the oracle");
        }
    }

    // budget
    function getReserve() public view returns (uint256) {
        return seigniorageSaved;
    }

    /* ========== GOVERNANCE ========== */

    function initialize(
        address _papr,
        address _ink,
        address _printr,
        uint256 _startTime,
        address _fund
    )  public {
        require(!initialized, "Initialized");
        papr = _papr;
        ink = _ink;
        printr = _printr;
        startTime = _startTime;
        fund = _fund;

        paprMultiplierStepExpansion = 10e16; // 10 cents
        paprPriceOne = 10e17;
        paprPriceOverExpansionCeiling = 15e17;
        paprPriceCeiling = paprPriceOne.mul(101).div(100);
        migrated = false;

        maxSupplyExpansionPercent = 350;
        maxSupplyExpansionPercentInDebtPhase = 450;
        inkDepletionFloorPercent = 10000;
        seigniorageExpansionFloorPercent = 3500;
        maxSupplyContractionPercent = 400;
        maxDeptRatioPercent = 3500;
        epoch = 0;
        epochSupplyContractionLeft = 0;
        printingRatioMultiplier = 0;
        fundAllocationRate = 500;

        BootstrapEpochs = 2;
        BootstrapSupplyExpansionPercent = 450;

        seigniorageSaved = IERC20(papr).balanceOf(address(this));

        initialized = true;
        operator = msg.sender;
        emit Initialized(msg.sender, block.number);
    }

    function setOperator(address _operator) external onlyOperator {
        operator = _operator;
    }

    function setBoardroom(address _boardroom) external onlyOperator {
        boardroom = _boardroom;
    }

    function setPaprOracle(address _paprOracle) external onlyOperator {
        paprOracle = _paprOracle;
    }

    function setPaprPriceCeilingAndprintingRatioMultiplier(uint256 _paprPriceCeiling, uint256 _printingRatioMultiplier) external onlyOperator {
        require(_paprPriceCeiling >= paprPriceOne && _paprPriceCeiling <= paprPriceOne.mul(120).div(100), "out of range"); // [$1.0, $1.2]
        paprPriceCeiling = _paprPriceCeiling;
        require(_printingRatioMultiplier >= 0 && _printingRatioMultiplier <= 1000, "out of range"); // [0%, 10%]
        printingRatioMultiplier = _printingRatioMultiplier;
    }

    function setMaxSupplyExpansionPercents(uint256 _maxSupplyExpansionPercent, uint256 _maxSupplyExpansionPercentInDebtPhase) external onlyOperator {
        require(_maxSupplyExpansionPercent >= 10 && _maxSupplyExpansionPercent <= 1000, "_maxSupplyExpansionPercent: out of range"); // [0.1%, 10%]
        require(
            _maxSupplyExpansionPercentInDebtPhase >= 10 && _maxSupplyExpansionPercentInDebtPhase <= 1500,
            "_maxSupplyExpansionPercentInDebtPhase: out of range"
        ); // [0.1%, 15%]
        require(
            _maxSupplyExpansionPercent <= _maxSupplyExpansionPercentInDebtPhase,
            "_maxSupplyExpansionPercent is over _maxSupplyExpansionPercentInDebtPhase"
        );
        maxSupplyExpansionPercent = _maxSupplyExpansionPercent;
        maxSupplyExpansionPercentInDebtPhase = _maxSupplyExpansionPercentInDebtPhase;
    }

    function setInkDepletionFloorPercent(uint256 _inkDepletionFloorPercent) external onlyOperator {
        require(_inkDepletionFloorPercent >= 500 && _inkDepletionFloorPercent <= 10000, "out of range"); // [5%, 100%]
        inkDepletionFloorPercent = _inkDepletionFloorPercent;
    }

    function setMaxSupplyContractionPercent(uint256 _maxSupplyContractionPercent) external onlyOperator {
        require(_maxSupplyContractionPercent >= 100 && _maxSupplyContractionPercent <= 1500, "out of range"); // [0.1%, 15%]
        maxSupplyContractionPercent = _maxSupplyContractionPercent;
    }

    function setMaxDeptRatioPercent(uint256 _maxDeptRatioPercent) external onlyOperator {
        require(_maxDeptRatioPercent >= 1000 && _maxDeptRatioPercent <= 10000, "out of range"); // [10%, 100%]
        maxDeptRatioPercent = _maxDeptRatioPercent;
    }

    // Modifiy PaperPrinter fund address (onlyOperator) :

    function setCoreAddresses(address newFund, uint256 _fundRate, address _papr, address _ink, address _printr) external onlyOperator {
        fund = newFund;
        require(_fundRate <= 2000); // _rate <= 20%
        fundAllocationRate = _fundRate;
        papr = _papr;
        ink = _ink;
        printr = _printr;
    }

    function migrate(address target) external onlyOperator {
        require(!migrated, "Migrated");
        checkOperator();

        // papr
        Operator(papr).transferOperator(target);
        Operator(papr).transferOwnership(target);
        IERC20(papr).transfer(target, IERC20(papr).balanceOf(address(this)));

        // ink
        Operator(ink).transferOperator(target);
        Operator(ink).transferOwnership(target);
        IERC20(ink).transfer(target, IERC20(ink).balanceOf(address(this)));

        // printr
        Operator(printr).transferOperator(target);
        Operator(printr).transferOwnership(target);
        IERC20(printr).transfer(target, IERC20(printr).balanceOf(address(this)));

        migrated = true;
        emit Migration(target);
    }

    /* ========== MUTABLE FUNCTIONS ========== */

    function _updatePaprPrice() internal {
        try IOracle(paprOracle).update() {} catch {}
    }

    function buyInks(uint256 amount, uint256 targetPrice) external onlyOneBlock {
        checkCondition();
        checkOperator();
        require(amount > 0, "Cannot purchase inks with zero amount");

        uint256 paprPrice = getPaprPrice();
        require(paprPrice == targetPrice, "Papr price moved");
        require(
            paprPrice < paprPriceOne, // price < $1
            "PaprPrice not eligible for ink purchase"
        );

        require(amount <= epochSupplyContractionLeft, "Not enough ink left to purchase");

        uint256 _boughtInk = amount.mul(1e18).div(paprPrice);
        uint256 paprSupply = IERC20(papr).totalSupply();
        uint256 newInkSupply = IERC20(ink).totalSupply().add(_boughtInk);
        require(newInkSupply <= paprSupply.mul(maxDeptRatioPercent).div(10000), "over max debt ratio");

        IBasisAsset(papr).burnFrom(msg.sender, amount);
        IBasisAsset(ink).mint(msg.sender, _boughtInk);

        epochSupplyContractionLeft = epochSupplyContractionLeft.sub(amount);
        _updatePaprPrice();

        emit BoughtInks(msg.sender, amount);
    }

    function redeemInks(uint256 amount, uint256 targetPrice) external onlyOneBlock {
        checkCondition();
        checkOperator();
        require(amount > 0, "Cannot redeem inks with zero amount");

        uint256 paprPrice = getPaprPrice();
        require(paprPrice == targetPrice, "Papr price moved");
        require(
            paprPrice > paprPriceCeiling, // price > $1.01
            "PaprPrice not eligible for ink purchase"
        );
        require(IERC20(papr).balanceOf(address(this)) >= amount, "Treasury has no more budget");

        seigniorageSaved = seigniorageSaved.sub(Math.min(seigniorageSaved, amount));

        IBasisAsset(ink).burnFrom(msg.sender, amount);
        IERC20(papr).safeTransfer(msg.sender, amount);

        _updatePaprPrice();

        emit RedeemedInks(msg.sender, amount);
    }

    function _sendToBoardRoom(uint256 _amount) internal {
        IBasisAsset(papr).mint(address(this), _amount);
        IERC20(papr).safeApprove(boardroom, _amount);
        IBoardroom(boardroom).allocateSeigniorage(_amount);
        emit BoardroomFunded(now, _amount);
    }

    // Mint, approve and send PAPR to fund :

    function _sendToFund(uint256 _amount) internal {
        IBasisAsset(papr).mint(address(this), _amount);
        IERC20(papr).safeApprove(fund, _amount);
        ISimpleERCFund(fund).deposit(papr,_amount,'Treasury: Seigniorage Allocation');
    }


    // return number of times over the cents step

    function _countTimesOverCents() internal returns (uint256) {
    
        uint256 paprPrice = getPaprPrice();
        uint256 count;
        if (paprPrice > paprPriceOverExpansionCeiling) {
            paprPrice = paprPrice.sub(paprPriceOverExpansionCeiling);
            count = paprPrice.div(paprMultiplierStepExpansion);
            return uint(count);
        } 

         else {
             return 0;

         }
  
    }

    function allocateSeigniorage() external onlyOneBlock onlyOperator {
        checkCondition();
        checkEpoch();
        checkOperator();
        _updatePaprPrice(); 
        uint256 paprSupply = IERC20(papr).totalSupply().sub(seigniorageSaved);
        if (epoch < BootstrapEpochs) {
            // Bootstrap (early epochs)
            _sendToBoardRoom(paprSupply.mul(BootstrapSupplyExpansionPercent).div(10000));
        } else {
            uint256 paprPrice = getPaprPrice();
            if (paprPrice > paprPriceCeiling) {
                // Expansion ($PAPR Price > 1$): there is some seigniorage to be allocated
                uint256 inkSupply = IERC20(ink).totalSupply();
                uint256 _percentage = paprPrice.sub(paprPriceOne);
                uint256 _savedForInk;
                uint256 _savedForBoardRoom;
                //Allocating to fund when saved enough to pay debt
                uint256 _savedForFund;

                if (seigniorageSaved >= inkSupply.mul(inkDepletionFloorPercent).div(10000)) {
                    // saved enough to pay dept, mint as usual rate
                    uint256 _mse = maxSupplyExpansionPercent.mul(1e14);
                    if (_percentage > _mse) {
                        _percentage = _mse;
                    }

                    uint256 ratio = printingRatioMultiplier.mul(1e14).mul(_countTimesOverCents()).div(1e19);
                    uint256 percentCombined = _percentage.mul(paprPriceOne.add(ratio));
                    uint256 _seigniorage = paprSupply.mul(percentCombined).div(1e18);

                     _savedForFund = _seigniorage.mul(fundAllocationRate).div(10000);
                     _savedForBoardRoom = _seigniorage.sub(_savedForFund); 
                }
                
                 else {
                    // have not saved enough to pay dept, mint more
                    uint256 _mse = maxSupplyExpansionPercentInDebtPhase.mul(1e14);
                    if (_percentage > _mse) {
                        _percentage = _mse;
                    }

                    uint256 ratio = printingRatioMultiplier.mul(1e14).mul(_countTimesOverCents()).div(1e19);
                    uint256 percentCombined = _percentage.mul(paprPriceOne.add(ratio));
                    uint256 _seigniorage = paprSupply.mul(percentCombined).div(1e18);

                    // reducing boardroom allocation, allocating dedicated % only
                    _savedForBoardRoom = _seigniorage.mul(seigniorageExpansionFloorPercent).div(10000);
                    // seignorage allocated to Treasury 
                    _savedForInk = _seigniorage.sub(_savedForBoardRoom);

                }
                if (_savedForBoardRoom > 0) {
                    _sendToBoardRoom(_savedForBoardRoom);
                }
                if (_savedForInk > 0) {
                    seigniorageSaved = seigniorageSaved.add(_savedForInk);
                    IBasisAsset(papr).mint(address(this), _savedForInk);
                    emit TreasuryFunded(now, _savedForInk);
                }
                if (_savedForFund > 0) {
                    _sendToFund(_savedForFund);

                }
            }
        }
    }

    function governanceRecoverUnsupported(
        IERC20 _token,
        uint256 _amount,
        address _to
    ) external onlyOperator {
        // do not allow to drain core tokens
        require(address(_token) != address(papr), "papr");
        require(address(_token) != address(ink), "ink");
        require(address(_token) != address(printr), "printr");
        _token.safeTransfer(_to, _amount);
    }

    /* ========== BOARDROOM CONTROLLING FUNCTIONS ========== */

    function boardroomSetOperator(address _operator) external onlyOperator {
        IBoardroom(boardroom).setOperator(_operator);
    }

    function boardroomSetLockUp(uint256 _withdrawLockupEpochs, uint256 _rewardLockupEpochs) external onlyOperator {
        IBoardroom(boardroom).setLockUp(_withdrawLockupEpochs, _rewardLockupEpochs);
    }

    function boardroomAllocateSeigniorage(uint256 amount) external onlyOperator {
        IBoardroom(boardroom).allocateSeigniorage(amount);
    }

    function boardroomGovernanceRecoverUnsupported(
        address _token,
        uint256 _amount,
        address _to
    ) external onlyOperator {
        IBoardroom(boardroom).governanceRecoverUnsupported(_token, _amount, _to);
    }
}

pragma solidity ^0.6.0;

interface IBasisAsset {
    function mint(address recipient, uint256 amount) external returns (bool);

    function burn(uint256 amount) external;

    function burnFrom(address from, uint256 amount) external;

    function isOperator() external returns (bool);

    function operator() external view returns (address);
}

pragma solidity ^0.6.0;

interface IBoardroom {
    function balanceOf(address _director) external view returns (uint256);

    function earned(address _director) external view returns (uint256);

    function canWithdraw(address _director) external view returns (bool);

    function canClaimReward(address _director) external view returns (bool);

    function setOperator(address _operator) external;

    function setLockUp(uint256 _withdrawLockupEpochs, uint256 _rewardLockupEpochs) external;

    function stake(uint256 _amount) external;

    function withdraw(uint256 _amount) external;

    function exit() external;

    function claimReward() external;

    function allocateSeigniorage(uint256 _amount) external;

    function governanceRecoverUnsupported(
        address _token,
        uint256 _amount,
        address _to
    ) external;
}

pragma solidity ^0.6.0;

interface IOracle {
    function update() external;

    function consult(address token, uint256 amountIn)
        external
        view
        returns (uint256 amountOut);
    // function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestamp);
}

pragma solidity ^0.6.0;

interface ISimpleERCFund {
    function deposit(
        address token,
        uint256 amount,
        string memory reason
    ) external;

    function withdraw(
        address token,
        uint256 amount,
        address to,
        string memory reason
    ) external;
}

pragma solidity ^0.6.0;

library Babylonian {
    function sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
        // else z = 0
    }
}

// SPDX-License-Identifier: MIT

pragma solidity ^0.6.0;

import "@openzeppelin/contracts/GSN/Context.sol";
import '../utils/DoubleOwnable.sol';

contract DoubleOperator is Context, DoubleOwnable {
    address private _primaryOperator;
    address private _secondaryOperator;

    event PrimaryOperatorTransferred(
        address indexed previousOperator,
        address indexed newOperator
    );
    event SecondaryOperatorTransferred(
        address indexed previousOperator,
        address indexed newOperator
    );

    constructor() internal {
        _primaryOperator = _msgSender();
        emit PrimaryOperatorTransferred(address(0), _primaryOperator);
    }

    function primaryOperator() public view returns (address) {
        return _primaryOperator;
    }
    function operator() public view returns (address) {
        return _secondaryOperator;
    }
    

    modifier onlyDoubleOperator() {
        require(
           (_primaryOperator == msg.sender || _secondaryOperator == msg.sender),
            'operator: caller is not the operator'
        );
        _;
    }

    function isOperator() public view returns (bool) {
        return _msgSender() == _primaryOperator || _msgSender() == _secondaryOperator;
    }

    function transferPrimaryOperator(address newOperator_) public onlyPrimaryOwner {
        _transferPrimaryOperator(newOperator_);
    }

    function _transferPrimaryOperator(address newOperator_) internal {
        require(
            newOperator_ != address(0),
            'operator: zero address given for new operator'
        );
        emit PrimaryOperatorTransferred(address(0), newOperator_);
        _primaryOperator = newOperator_;
    }

    function setSecondaryOperator(address newOperator_) external onlyPrimaryOwner {
        require(
            newOperator_ != address(0),
            'operator: zero address given for new operator'
        );
        emit SecondaryOperatorTransferred(address(0), newOperator_);
        _secondaryOperator = newOperator_;
    }
}

pragma solidity ^0.6.0;

import '@openzeppelin/contracts/GSN/Context.sol';
import '@openzeppelin/contracts/access/Ownable.sol';

contract Operator is Context, Ownable {
    address private _operator;

    event OperatorTransferred(
        address indexed previousOperator,
        address indexed newOperator
    );

    constructor() internal {
        _operator = _msgSender();
        emit OperatorTransferred(address(0), _operator);
    }

    function operator() public view returns (address) {
        return _operator;
    }

    modifier onlyOperator() {
        require(
            _operator == msg.sender,
            'operator: caller is not the operator'
        );
        _;
    }

    function isOperator() public view returns (bool) {
        return _msgSender() == _operator;
    }

    function transferOperator(address newOperator_) public onlyOwner {
        _transferOperator(newOperator_);
    }

    function _transferOperator(address newOperator_) internal {
        require(
            newOperator_ != address(0),
            'operator: zero address given for new operator'
        );
        emit OperatorTransferred(address(0), newOperator_);
        _operator = newOperator_;
    }
}

pragma solidity ^0.6.12;

contract ContractGuard {
    mapping(uint256 => mapping(address => bool)) private _status;

    function checkSameOriginReentranted() internal view returns (bool) {
        return _status[block.number][tx.origin];
    }

    function checkSameSenderReentranted() internal view returns (bool) {
        return _status[block.number][msg.sender];
    }

    modifier onlyOneBlock() {
        require(
            !checkSameOriginReentranted(),
            'ContractGuard: one block, one function'
        );
        require(
            !checkSameSenderReentranted(),
            'ContractGuard: one block, one function'
        );

        _;

        _status[block.number][tx.origin] = true;
        _status[block.number][msg.sender] = true;
    }
}

// SPDX-License-Identifier: MIT

pragma solidity ^0.6.12;

import "@openzeppelin/contracts/GSN/Context.sol";

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
abstract contract DoubleOwnable is Context {
    address private _primaryOwner;
    address private _secondaryOwner;

    event PrimaryOwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event SecondaryOwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /**
     * @dev Initializes the contract setting the deployer as the initial owner.
     */
    constructor () public {
        address msgSender = _msgSender();
        _primaryOwner = msgSender;
        emit PrimaryOwnershipTransferred(address(0), msgSender);
    }

    /**
     * @dev Returns the address of the current primary owner.
     */
    function primaryOwner() public view virtual returns (address) {
        return _primaryOwner;
    }

    /**
     * @dev Returns the address of the current secondary owner.
     */
    function secondaryOwner() public view virtual returns (address) {
        return _secondaryOwner;
    }

    /**
     * @dev Throws if called by any account other than the primary owner.
     */
    modifier onlyPrimaryOwner() {
        require(primaryOwner() == _msgSender(), "Ownable: caller is not the owner");
        _;
    }

    /**
     * @dev Throws if called by any account other than the both owners.
     */
    modifier onlyOwner() {
        require(primaryOwner() == _msgSender() || secondaryOwner() == _msgSender(), "Ownable: caller is not the owner");
        _;
    }

    /**
     * @dev Leaves the contract without owner. It will not be possible to call
     * `onlyPrimaryOwner` functions anymore. Can only be called by the current owner.
     *
     * NOTE: Renouncing ownership will leave the contract without an owner,
     * thereby removing any functionality that is only available to the owner.
     */
    function renounceOwnership() public virtual onlyPrimaryOwner {
        emit PrimaryOwnershipTransferred(_primaryOwner, address(0));
        _primaryOwner = address(0);
    }

    /**
     * @dev Transfers ownership of the contract to a new account (`newOwner`).
     * Can only be called by the current owner.
     */
    function transferPrimaryOwnership(address newOwner) public virtual onlyPrimaryOwner {
        require(newOwner != address(0), "Ownable: new owner is the zero address");
        emit PrimaryOwnershipTransferred(_primaryOwner, newOwner);
        _primaryOwner = newOwner;
    }

    /**
     * @dev Set secondary ownership of the contract to a new account (`newOwner`).
     * Can only be called by the primary owner.
     */

    function setSecondaryOwnership(address newOwner) public virtual onlyPrimaryOwner {
        require(newOwner != address(0), "Ownable: new owner is the zero address");
        emit SecondaryOwnershipTransferred(_secondaryOwner, newOwner);
        _secondaryOwner = newOwner;
    }
}

// SPDX-License-Identifier: MIT

pragma solidity >=0.6.0 <0.8.0;

import "../utils/Context.sol";

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
 * @dev Standard math utilities missing in the Solidity language.
 */
library Math {
    /**
     * @dev Returns the largest of two numbers.
     */
    function max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a >= b ? a : b;
    }

    /**
     * @dev Returns the smallest of two numbers.
     */
    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    /**
     * @dev Returns the average of two numbers. The result is rounded towards
     * zero.
     */
    function average(uint256 a, uint256 b) internal pure returns (uint256) {
        // (a + b) / 2 can overflow, so we distribute
        return (a / 2) + (b / 2) + ((a % 2 + b % 2) / 2);
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
import "../../utils/AddressUpgreadeable.sol";

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
    using AddressUpgradeable for address;

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
 * @dev Collection of functions related to the address type
 */
library AddressUpgradeable {
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

{
  "remappings": [],
  "optimizer": {
    "enabled": false,
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