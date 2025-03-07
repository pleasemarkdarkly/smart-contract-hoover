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
// @unsupported: ovm
pragma solidity >0.5.0 <0.8.0;
pragma experimental ABIEncoderV2;

/* Library Imports */
import { Lib_OVMCodec } from "../../libraries/codec/Lib_OVMCodec.sol";
import { Lib_AddressResolver } from "../../libraries/resolver/Lib_AddressResolver.sol";
import { Lib_Bytes32Utils } from "../../libraries/utils/Lib_Bytes32Utils.sol";
import { Lib_EthUtils } from "../../libraries/utils/Lib_EthUtils.sol";
import { Lib_ErrorUtils } from "../../libraries/utils/Lib_ErrorUtils.sol";
import { Lib_PredeployAddresses } from "../../libraries/constants/Lib_PredeployAddresses.sol";

/* Interface Imports */
import { iOVM_ExecutionManager } from "../../iOVM/execution/iOVM_ExecutionManager.sol";
import { iOVM_StateManager } from "../../iOVM/execution/iOVM_StateManager.sol";
import { iOVM_SafetyChecker } from "../../iOVM/execution/iOVM_SafetyChecker.sol";

/* Contract Imports */
import { OVM_DeployerWhitelist } from "../predeploys/OVM_DeployerWhitelist.sol";

/* External Imports */
import { Math } from "@openzeppelin/contracts/math/Math.sol";

/**
 * @title OVM_ExecutionManager
 * @dev The Execution Manager (EM) is the core of our OVM implementation, and provides a sandboxed
 * environment allowing us to execute OVM transactions deterministically on either Layer 1 or
 * Layer 2.
 * The EM's run() function is the first function called during the execution of any
 * transaction on L2.
 * For each context-dependent EVM operation the EM has a function which implements a corresponding
 * OVM operation, which will read state from the State Manager contract.
 * The EM relies on the Safety Checker to verify that code deployed to Layer 2 does not contain any
 * context-dependent operations.
 *
 * Compiler used: solc
 * Runtime target: EVM
 */
contract OVM_ExecutionManager is iOVM_ExecutionManager, Lib_AddressResolver {

    /********************************
     * External Contract References *
     ********************************/

    iOVM_SafetyChecker internal ovmSafetyChecker;
    iOVM_StateManager internal ovmStateManager;


    /*******************************
     * Execution Context Variables *
     *******************************/

    GasMeterConfig internal gasMeterConfig;
    GlobalContext internal globalContext;
    TransactionContext internal transactionContext;
    MessageContext internal messageContext;
    TransactionRecord internal transactionRecord;
    MessageRecord internal messageRecord;


    /**************************
     * Gas Metering Constants *
     **************************/

    address constant GAS_METADATA_ADDRESS = 0x06a506A506a506A506a506a506A506A506A506A5;
    uint256 constant NUISANCE_GAS_SLOAD = 20000;
    uint256 constant NUISANCE_GAS_SSTORE = 20000;
    uint256 constant MIN_NUISANCE_GAS_PER_CONTRACT = 30000;
    uint256 constant NUISANCE_GAS_PER_CONTRACT_BYTE = 100;
    uint256 constant MIN_GAS_FOR_INVALID_STATE_ACCESS = 30000;


    /**************************
     * Native Value Constants *
     **************************/

    // Public so we can access and make assertions in integration tests.
    uint256 public constant CALL_WITH_VALUE_INTRINSIC_GAS = 90000;


    /**************************
     * Default Context Values *
     **************************/

    uint256 constant DEFAULT_UINT256 = 0xdefa017defa017defa017defa017defa017defa017defa017defa017defa017d;
    address constant DEFAULT_ADDRESS = 0xdEfa017defA017DeFA017DEfa017DeFA017DeFa0;


    /*************************************
     * Container Contract Address Prefix *
     *************************************/

    /**
     * @dev The Execution Manager and State Manager each have this 30 byte prefix, and are uncallable.
     */
    address constant CONTAINER_CONTRACT_PREFIX = 0xDeadDeAddeAddEAddeadDEaDDEAdDeaDDeAD0000;


    /***************
     * Constructor *
     ***************/

    /**
     * @param _libAddressManager Address of the Address Manager.
     */
    constructor(
        address _libAddressManager,
        GasMeterConfig memory _gasMeterConfig,
        GlobalContext memory _globalContext
    )
        Lib_AddressResolver(_libAddressManager)
    {
        ovmSafetyChecker = iOVM_SafetyChecker(resolve("OVM_SafetyChecker"));
        gasMeterConfig = _gasMeterConfig;
        globalContext = _globalContext;
        _resetContext();
    }


    /**********************
     * Function Modifiers *
     **********************/

    /**
     * Applies dynamically-sized refund to a transaction to account for the difference in execution
     * between L1 and L2, so that the overall cost of the ovmOPCODE is fixed.
     * @param _cost Desired gas cost for the function after the refund.
     */
    modifier netGasCost(
        uint256 _cost
    ) {
        uint256 gasProvided = gasleft();
        _;
        uint256 gasUsed = gasProvided - gasleft();

        // We want to refund everything *except* the specified cost.
        if (_cost < gasUsed) {
            transactionRecord.ovmGasRefund += gasUsed - _cost;
        }
    }

    /**
     * Applies a fixed-size gas refund to a transaction to account for the difference in execution
     * between L1 and L2, so that the overall cost of an ovmOPCODE can be lowered.
     * @param _discount Amount of gas cost to refund for the ovmOPCODE.
     */
    modifier fixedGasDiscount(
        uint256 _discount
    ) {
        uint256 gasProvided = gasleft();
        _;
        uint256 gasUsed = gasProvided - gasleft();

        // We want to refund the specified _discount, unless this risks underflow.
        if (_discount < gasUsed) {
            transactionRecord.ovmGasRefund += _discount;
        } else {
            // refund all we can without risking underflow.
            transactionRecord.ovmGasRefund += gasUsed;
        }
    }

    /**
     * Makes sure we're not inside a static context.
     */
    modifier notStatic() {
        if (messageContext.isStatic == true) {
            _revertWithFlag(RevertFlag.STATIC_VIOLATION);
        }
        _;
    }


    /************************************
     * Transaction Execution Entrypoint *
     ************************************/

    /**
     * Starts the execution of a transaction via the OVM_ExecutionManager.
     * @param _transaction Transaction data to be executed.
     * @param _ovmStateManager iOVM_StateManager implementation providing account state.
     */
    function run(
        Lib_OVMCodec.Transaction memory _transaction,
        address _ovmStateManager
    )
        override
        external
        returns (
            bytes memory
        )
    {
        // Make sure that run() is not re-enterable.  This condition should always be satisfied
        // Once run has been called once, due to the behavior of _isValidInput().
        if (transactionContext.ovmNUMBER != DEFAULT_UINT256) {
            return bytes("");
        }

        // Store our OVM_StateManager instance (significantly easier than attempting to pass the
        // address around in calldata).
        ovmStateManager = iOVM_StateManager(_ovmStateManager);

        // Make sure this function can't be called by anyone except the owner of the
        // OVM_StateManager (expected to be an OVM_StateTransitioner). We can revert here because
        // this would make the `run` itself invalid.
        require(
            // This method may return false during fraud proofs, but always returns true in L2 nodes' State Manager precompile.
            ovmStateManager.isAuthenticated(msg.sender),
            "Only authenticated addresses in ovmStateManager can call this function"
        );

        // Initialize the execution context, must be initialized before we perform any gas metering
        // or we'll throw a nuisance gas error.
        _initContext(_transaction);

        // TEMPORARY: Gas metering is disabled for minnet.
        // // Check whether we need to start a new epoch, do so if necessary.
        // _checkNeedsNewEpoch(_transaction.timestamp);

        // Make sure the transaction's gas limit is valid. We don't revert here because we reserve
        // reverts for INVALID_STATE_ACCESS.
        if (_isValidInput(_transaction) == false) {
            _resetContext();
            return bytes("");
        }

        // TEMPORARY: Gas metering is disabled for minnet.
        // // Check gas right before the call to get total gas consumed by OVM transaction.
        // uint256 gasProvided = gasleft();

        // Run the transaction, make sure to meter the gas usage.
        (, bytes memory returndata) = ovmCALL(
            _transaction.gasLimit - gasMeterConfig.minTransactionGasLimit,
            _transaction.entrypoint,
            0,
            _transaction.data
        );

        // TEMPORARY: Gas metering is disabled for minnet.
        // // Update the cumulative gas based on the amount of gas used.
        // uint256 gasUsed = gasProvided - gasleft();
        // _updateCumulativeGas(gasUsed, _transaction.l1QueueOrigin);

        // Wipe the execution context.
        _resetContext();

        return returndata;
    }


    /******************************
     * Opcodes: Execution Context *
     ******************************/

    /**
     * @notice Overrides CALLER.
     * @return _CALLER Address of the CALLER within the current message context.
     */
    function ovmCALLER()
        override
        external
        view
        returns (
            address _CALLER
        )
    {
        return messageContext.ovmCALLER;
    }

    /**
     * @notice Overrides ADDRESS.
     * @return _ADDRESS Active ADDRESS within the current message context.
     */
    function ovmADDRESS()
        override
        public
        view
        returns (
            address _ADDRESS
        )
    {
        return messageContext.ovmADDRESS;
    }

    /**
     * @notice Overrides CALLVALUE.
     * @return _CALLVALUE Value sent along with the call according to the current message context.
     */
    function ovmCALLVALUE()
        override
        public
        view
        returns (
            uint256 _CALLVALUE
        )
    {
        return messageContext.ovmCALLVALUE;
    }

    /**
     * @notice Overrides TIMESTAMP.
     * @return _TIMESTAMP Value of the TIMESTAMP within the transaction context.
     */
    function ovmTIMESTAMP()
        override
        external
        view
        returns (
            uint256 _TIMESTAMP
        )
    {
        return transactionContext.ovmTIMESTAMP;
    }

    /**
     * @notice Overrides NUMBER.
     * @return _NUMBER Value of the NUMBER within the transaction context.
     */
    function ovmNUMBER()
        override
        external
        view
        returns (
            uint256 _NUMBER
        )
    {
        return transactionContext.ovmNUMBER;
    }

    /**
     * @notice Overrides GASLIMIT.
     * @return _GASLIMIT Value of the block's GASLIMIT within the transaction context.
     */
    function ovmGASLIMIT()
        override
        external
        view
        returns (
            uint256 _GASLIMIT
        )
    {
        return transactionContext.ovmGASLIMIT;
    }

    /**
     * @notice Overrides CHAINID.
     * @return _CHAINID Value of the chain's CHAINID within the global context.
     */
    function ovmCHAINID()
        override
        external
        view
        returns (
            uint256 _CHAINID
        )
    {
        return globalContext.ovmCHAINID;
    }

    /*********************************
     * Opcodes: L2 Execution Context *
     *********************************/

    /**
     * @notice Specifies from which source (Sequencer or Queue) this transaction originated from.
     * @return _queueOrigin Enum indicating the ovmL1QUEUEORIGIN within the current message context.
     */
    function ovmL1QUEUEORIGIN()
        override
        external
        view
        returns (
            Lib_OVMCodec.QueueOrigin _queueOrigin
        )
    {
        return transactionContext.ovmL1QUEUEORIGIN;
    }

    /**
     * @notice Specifies which L1 account, if any, sent this transaction by calling enqueue().
     * @return _l1TxOrigin Address of the account which sent the tx into L2 from L1.
     */
    function ovmL1TXORIGIN()
        override
        external
        view
        returns (
            address _l1TxOrigin
        )
    {
        return transactionContext.ovmL1TXORIGIN;
    }

    /********************
     * Opcodes: Halting *
     ********************/

    /**
     * @notice Overrides REVERT.
     * @param _data Bytes data to pass along with the REVERT.
     */
    function ovmREVERT(
        bytes memory _data
    )
        override
        public
    {
        _revertWithFlag(RevertFlag.INTENTIONAL_REVERT, _data);
    }


    /******************************
     * Opcodes: Contract Creation *
     ******************************/

    /**
     * @notice Overrides CREATE.
     * @param _bytecode Code to be used to CREATE a new contract.
     * @return Address of the created contract.
     * @return Revert data, if and only if the creation threw an exception.
     */
    function ovmCREATE(
        bytes memory _bytecode
    )
        override
        public
        notStatic
        fixedGasDiscount(40000)
        returns (
            address,
            bytes memory
        )
    {
        // Creator is always the current ADDRESS.
        address creator = ovmADDRESS();

        // Check that the deployer is whitelisted, or
        // that arbitrary contract deployment has been enabled.
        _checkDeployerAllowed(creator);

        // Generate the correct CREATE address.
        address contractAddress = Lib_EthUtils.getAddressForCREATE(
            creator,
            _getAccountNonce(creator)
        );

        return _createContract(
            contractAddress,
            _bytecode,
            MessageType.ovmCREATE
        );
    }

    /**
     * @notice Overrides CREATE2.
     * @param _bytecode Code to be used to CREATE2 a new contract.
     * @param _salt Value used to determine the contract's address.
     * @return Address of the created contract.
     * @return Revert data, if and only if the creation threw an exception.
     */
    function ovmCREATE2(
        bytes memory _bytecode,
        bytes32 _salt
    )
        override
        external
        notStatic
        fixedGasDiscount(40000)
        returns (
            address,
            bytes memory
        )
    {
        // Creator is always the current ADDRESS.
        address creator = ovmADDRESS();

        // Check that the deployer is whitelisted, or
        // that arbitrary contract deployment has been enabled.
        _checkDeployerAllowed(creator);

        // Generate the correct CREATE2 address.
        address contractAddress = Lib_EthUtils.getAddressForCREATE2(
            creator,
            _bytecode,
            _salt
        );

        return _createContract(
            contractAddress,
            _bytecode,
            MessageType.ovmCREATE2
        );
    }


    /*******************************
     * Account Abstraction Opcodes *
     ******************************/

    /**
     * Retrieves the nonce of the current ovmADDRESS.
     * @return _nonce Nonce of the current contract.
     */
    function ovmGETNONCE()
        override
        external
        returns (
            uint256 _nonce
        )
    {
        return _getAccountNonce(ovmADDRESS());
    }

    /**
     * Bumps the nonce of the current ovmADDRESS by one.
     */
    function ovmINCREMENTNONCE()
        override
        external
        notStatic
    {
        address account = ovmADDRESS();
        uint256 nonce = _getAccountNonce(account);

        // Prevent overflow.
        if (nonce + 1 > nonce) {
            _setAccountNonce(account, nonce + 1);
        }
    }

    /**
     * Creates a new EOA contract account, for account abstraction.
     * @dev Essentially functions like ovmCREATE or ovmCREATE2, but we can bypass a lot of checks
     *      because the contract we're creating is trusted (no need to do safety checking or to
     *      handle unexpected reverts). Doesn't need to return an address because the address is
     *      assumed to be the user's actual address.
     * @param _messageHash Hash of a message signed by some user, for verification.
     * @param _v Signature `v` parameter.
     * @param _r Signature `r` parameter.
     * @param _s Signature `s` parameter.
     */
    function ovmCREATEEOA(
        bytes32 _messageHash,
        uint8 _v,
        bytes32 _r,
        bytes32 _s
    )
        override
        public
        notStatic
    {
        // Recover the EOA address from the message hash and signature parameters. Since we do the
        // hashing in advance, we don't have handle different message hashing schemes. Even if this
        // function were to return the wrong address (rather than explicitly returning the zero
        // address), the rest of the transaction would simply fail (since there's no EOA account to
        // actually execute the transaction).
        address eoa = ecrecover(
            _messageHash,
            _v + 27,
            _r,
            _s
        );

        // Invalid signature is a case we proactively handle with a revert. We could alternatively
        // have this function return a `success` boolean, but this is just easier.
        if (eoa == address(0)) {
            ovmREVERT(bytes("Signature provided for EOA contract creation is invalid."));
        }

        // If the user already has an EOA account, then there's no need to perform this operation.
        if (_hasEmptyAccount(eoa) == false) {
            return;
        }

        // We always need to initialize the contract with the default account values.
        _initPendingAccount(eoa);

        // Temporarily set the current address so it's easier to access on L2.
        address prevADDRESS = messageContext.ovmADDRESS;
        messageContext.ovmADDRESS = eoa;

        // Creates a duplicate of the OVM_ProxyEOA located at 0x42....09. Uses the following
        // "magic" prefix to deploy an exact copy of the code:
        // PUSH1 0x0D   # size of this prefix in bytes
        // CODESIZE
        // SUB          # subtract prefix size from codesize
        // DUP1
        // PUSH1 0x0D
        // PUSH1 0x00
        // CODECOPY     # copy everything after prefix into memory at pos 0
        // PUSH1 0x00
        // RETURN       # return the copied code
        address proxyEOA = Lib_EthUtils.createContract(abi.encodePacked(
            hex"600D380380600D6000396000f3",
            ovmEXTCODECOPY(
                Lib_PredeployAddresses.PROXY_EOA,
                0,
                ovmEXTCODESIZE(Lib_PredeployAddresses.PROXY_EOA)
            )
        ));

        // Reset the address now that we're done deploying.
        messageContext.ovmADDRESS = prevADDRESS;

        // Commit the account with its final values.
        _commitPendingAccount(
            eoa,
            address(proxyEOA),
            keccak256(Lib_EthUtils.getCode(address(proxyEOA)))
        );

        _setAccountNonce(eoa, 0);
    }


    /*********************************
     * Opcodes: Contract Interaction *
     *********************************/

    /**
     * @notice Overrides CALL.
     * @param _gasLimit Amount of gas to be passed into this call.
     * @param _address Address of the contract to call.
     * @param _value ETH value to pass with the call.
     * @param _calldata Data to send along with the call.
     * @return _success Whether or not the call returned (rather than reverted).
     * @return _returndata Data returned by the call.
     */
    function ovmCALL(
        uint256 _gasLimit,
        address _address,
        uint256 _value,
        bytes memory _calldata
    )
        override
        public
        fixedGasDiscount(100000)
        returns (
            bool _success,
            bytes memory _returndata
        )
    {
        // CALL updates the CALLER and ADDRESS.
        MessageContext memory nextMessageContext = messageContext;
        nextMessageContext.ovmCALLER = nextMessageContext.ovmADDRESS;
        nextMessageContext.ovmADDRESS = _address;
        nextMessageContext.ovmCALLVALUE = _value;

        return _callContract(
            nextMessageContext,
            _gasLimit,
            _address,
            _calldata,
            MessageType.ovmCALL
        );
    }

    /**
     * @notice Overrides STATICCALL.
     * @param _gasLimit Amount of gas to be passed into this call.
     * @param _address Address of the contract to call.
     * @param _calldata Data to send along with the call.
     * @return _success Whether or not the call returned (rather than reverted).
     * @return _returndata Data returned by the call.
     */
    function ovmSTATICCALL(
        uint256 _gasLimit,
        address _address,
        bytes memory _calldata
    )
        override
        public
        fixedGasDiscount(80000)
        returns (
            bool _success,
            bytes memory _returndata
        )
    {
        // STATICCALL updates the CALLER, updates the ADDRESS, and runs in a static, valueless context.
        MessageContext memory nextMessageContext = messageContext;
        nextMessageContext.ovmCALLER = nextMessageContext.ovmADDRESS;
        nextMessageContext.ovmADDRESS = _address;
        nextMessageContext.isStatic = true;
        nextMessageContext.ovmCALLVALUE = 0;

        return _callContract(
            nextMessageContext,
            _gasLimit,
            _address,
            _calldata,
            MessageType.ovmSTATICCALL
        );
    }

    /**
     * @notice Overrides DELEGATECALL.
     * @param _gasLimit Amount of gas to be passed into this call.
     * @param _address Address of the contract to call.
     * @param _calldata Data to send along with the call.
     * @return _success Whether or not the call returned (rather than reverted).
     * @return _returndata Data returned by the call.
     */
    function ovmDELEGATECALL(
        uint256 _gasLimit,
        address _address,
        bytes memory _calldata
    )
        override
        public
        fixedGasDiscount(40000)
        returns (
            bool _success,
            bytes memory _returndata
        )
    {
        // DELEGATECALL does not change anything about the message context.
        MessageContext memory nextMessageContext = messageContext;

        return _callContract(
            nextMessageContext,
            _gasLimit,
            _address,
            _calldata,
            MessageType.ovmDELEGATECALL
        );
    }

    /**
     * @notice Legacy ovmCALL function which did not support ETH value; this maintains backwards compatibility.
     * @param _gasLimit Amount of gas to be passed into this call.
     * @param _address Address of the contract to call.
     * @param _calldata Data to send along with the call.
     * @return _success Whether or not the call returned (rather than reverted).
     * @return _returndata Data returned by the call.
     */
    function ovmCALL(
        uint256 _gasLimit,
        address _address,
        bytes memory _calldata
    )
        override
        public
        returns(
            bool _success,
            bytes memory _returndata
        )
    {
        // Legacy ovmCALL assumed always-0 value.
        return ovmCALL(
            _gasLimit,
            _address,
            0,
            _calldata
        );
    }


    /************************************
     * Opcodes: Contract Storage Access *
     ************************************/

    /**
     * @notice Overrides SLOAD.
     * @param _key 32 byte key of the storage slot to load.
     * @return _value 32 byte value of the requested storage slot.
     */
    function ovmSLOAD(
        bytes32 _key
    )
        override
        external
        netGasCost(40000)
        returns (
            bytes32 _value
        )
    {
        // We always SLOAD from the storage of ADDRESS.
        address contractAddress = ovmADDRESS();

        return _getContractStorage(
            contractAddress,
            _key
        );
    }

    /**
     * @notice Overrides SSTORE.
     * @param _key 32 byte key of the storage slot to set.
     * @param _value 32 byte value for the storage slot.
     */
    function ovmSSTORE(
        bytes32 _key,
        bytes32 _value
    )
        override
        external
        notStatic
        netGasCost(60000)
    {
        // We always SSTORE to the storage of ADDRESS.
        address contractAddress = ovmADDRESS();

        _putContractStorage(
            contractAddress,
            _key,
            _value
        );
    }


    /*********************************
     * Opcodes: Contract Code Access *
     *********************************/

    /**
     * @notice Overrides EXTCODECOPY.
     * @param _contract Address of the contract to copy code from.
     * @param _offset Offset in bytes from the start of contract code to copy beyond.
     * @param _length Total number of bytes to copy from the contract's code.
     * @return _code Bytes of code copied from the requested contract.
     */
    function ovmEXTCODECOPY(
        address _contract,
        uint256 _offset,
        uint256 _length
    )
        override
        public
        returns (
            bytes memory _code
        )
    {
        return Lib_EthUtils.getCode(
            _getAccountEthAddress(_contract),
            _offset,
            _length
        );
    }

    /**
     * @notice Overrides EXTCODESIZE.
     * @param _contract Address of the contract to query the size of.
     * @return _EXTCODESIZE Size of the requested contract in bytes.
     */
    function ovmEXTCODESIZE(
        address _contract
    )
        override
        public
        returns (
            uint256 _EXTCODESIZE
        )
    {
        return Lib_EthUtils.getCodeSize(
            _getAccountEthAddress(_contract)
        );
    }

    /**
     * @notice Overrides EXTCODEHASH.
     * @param _contract Address of the contract to query the hash of.
     * @return _EXTCODEHASH Hash of the requested contract.
     */
    function ovmEXTCODEHASH(
        address _contract
    )
        override
        external
        returns (
            bytes32 _EXTCODEHASH
        )
    {
        return Lib_EthUtils.getCodeHash(
            _getAccountEthAddress(_contract)
        );
    }


    /***************************************
     * Public Functions: ETH Value Opcodes *
     ***************************************/

    /**
     * @notice Overrides BALANCE.
     * NOTE: In the future, this could be optimized to directly invoke EM._getContractStorage(...).
     * @param _contract Address of the contract to query the OVM_ETH balance of.
     * @return _BALANCE OVM_ETH balance of the requested contract.
     */
    function ovmBALANCE(
        address _contract
    )
        override
        public
        returns (
            uint256 _BALANCE
        )
    {
        // Easiest way to get the balance is query OVM_ETH as normal.
        bytes memory balanceOfCalldata = abi.encodeWithSignature(
            "balanceOf(address)",
            _contract
        );

        // Static call because this should be a read-only query.
        (bool success, bytes memory returndata) = ovmSTATICCALL(
            gasleft(),
            Lib_PredeployAddresses.OVM_ETH,
            balanceOfCalldata
        );

        // All balanceOf queries should successfully return a uint, otherwise this must be an OOG.
        if (!success || returndata.length != 32) {
            _revertWithFlag(RevertFlag.OUT_OF_GAS);
        }

        // Return the decoded balance.
        return abi.decode(returndata, (uint256));
    }

    /**
     * @notice Overrides SELFBALANCE.
     * @return _BALANCE OVM_ETH balance of the requesting contract.
     */
    function ovmSELFBALANCE()
        override
        external
        returns (
            uint256 _BALANCE
        )
    {
        return ovmBALANCE(ovmADDRESS());
    }


    /***************************************
     * Public Functions: Execution Context *
     ***************************************/

    function getMaxTransactionGasLimit()
        external
        view
        override
        returns (
            uint256 _maxTransactionGasLimit
        )
    {
        return gasMeterConfig.maxTransactionGasLimit;
    }

    /********************************************
     * Public Functions: Deployment Whitelisting *
     ********************************************/

    /**
     * Checks whether the given address is on the whitelist to ovmCREATE/ovmCREATE2, and reverts if not.
     * @param _deployerAddress Address attempting to deploy a contract.
     */
    function _checkDeployerAllowed(
        address _deployerAddress
    )
        internal
    {
        // From an OVM semantics perspective, this will appear identical to
        // the deployer ovmCALLing the whitelist.  This is fine--in a sense, we are forcing them to.
        (bool success, bytes memory data) = ovmSTATICCALL(
            gasleft(),
            Lib_PredeployAddresses.DEPLOYER_WHITELIST,
            abi.encodeWithSelector(
                OVM_DeployerWhitelist.isDeployerAllowed.selector,
                _deployerAddress
            )
        );
        bool isAllowed = abi.decode(data, (bool));

        if (!isAllowed || !success) {
            _revertWithFlag(RevertFlag.CREATOR_NOT_ALLOWED);
        }
    }

    /********************************************
     * Internal Functions: Contract Interaction *
     ********************************************/

    /**
     * Creates a new contract and associates it with some contract address.
     * @param _contractAddress Address to associate the created contract with.
     * @param _bytecode Bytecode to be used to create the contract.
     * @return Final OVM contract address.
     * @return Revertdata, if and only if the creation threw an exception.
     */
    function _createContract(
        address _contractAddress,
        bytes memory _bytecode,
        MessageType _messageType
    )
        internal
        returns (
            address,
            bytes memory
        )
    {
        // We always update the nonce of the creating account, even if the creation fails.
        _setAccountNonce(ovmADDRESS(), _getAccountNonce(ovmADDRESS()) + 1);

        // We're stepping into a CREATE or CREATE2, so we need to update ADDRESS to point
        // to the contract's associated address and CALLER to point to the previous ADDRESS.
        MessageContext memory nextMessageContext = messageContext;
        nextMessageContext.ovmCALLER = messageContext.ovmADDRESS;
        nextMessageContext.ovmADDRESS = _contractAddress;

        // Run the common logic which occurs between call-type and create-type messages,
        // passing in the creation bytecode and `true` to trigger create-specific logic.
        (bool success, bytes memory data) = _handleExternalMessage(
            nextMessageContext,
            gasleft(),
            _contractAddress,
            _bytecode,
            _messageType
        );

        // Yellow paper requires that address returned is zero if the contract deployment fails.
        return (
            success ? _contractAddress : address(0),
            data
        );
    }

    /**
     * Calls the deployed contract associated with a given address.
     * @param _nextMessageContext Message context to be used for the call.
     * @param _gasLimit Amount of gas to be passed into this call.
     * @param _contract OVM address to be called.
     * @param _calldata Data to send along with the call.
     * @return _success Whether or not the call returned (rather than reverted).
     * @return _returndata Data returned by the call.
     */
    function _callContract(
        MessageContext memory _nextMessageContext,
        uint256 _gasLimit,
        address _contract,
        bytes memory _calldata,
        MessageType _messageType
    )
        internal
        returns (
            bool _success,
            bytes memory _returndata
        )
    {
        // We reserve addresses of the form 0xdeaddeaddead...NNNN for the container contracts in L2 geth.
        // So, we block calls to these addresses since they are not safe to run as an OVM contract itself.
        if (
            (uint256(_contract) & uint256(0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff0000))
            == uint256(CONTAINER_CONTRACT_PREFIX)
        ) {
            // EVM does not return data in the success case, see: https://github.com/ethereum/go-ethereum/blob/aae7660410f0ef90279e14afaaf2f429fdc2a186/core/vm/instructions.go#L600-L604
            return (true, hex'');
        }

        // Both 0x0000... and the EVM precompiles have the same address on L1 and L2 --> no trie lookup needed.
        address codeContractAddress =
            uint(_contract) < 100
            ? _contract
            : _getAccountEthAddress(_contract);

        return _handleExternalMessage(
            _nextMessageContext,
            _gasLimit,
            codeContractAddress,
            _calldata,
            _messageType
        );
    }

    /**
     * Handles all interactions which involve the execution manager calling out to untrusted code (both calls and creates).
     * Ensures that OVM-related measures are enforced, including L2 gas refunds, nuisance gas, and flagged reversions.
     *
     * @param _nextMessageContext Message context to be used for the external message.
     * @param _gasLimit Amount of gas to be passed into this message. NOTE: this argument is overwritten in some cases to avoid stack-too-deep.
     * @param _contract OVM address being called or deployed to
     * @param _data Data for the message (either calldata or creation code)
     * @param _messageType What type of ovmOPCODE this message corresponds to.
     * @return Whether or not the message (either a call or deployment) succeeded.
     * @return Data returned by the message.
     */
    function _handleExternalMessage(
        MessageContext memory _nextMessageContext,
        // NOTE: this argument is overwritten in some cases to avoid stack-too-deep.
        uint256 _gasLimit,
        address _contract,
        bytes memory _data,
        MessageType _messageType
    )
        internal
        returns (
            bool,
            bytes memory
        )
    {
        uint256 messageValue = _nextMessageContext.ovmCALLVALUE;
        // If there is value in this message, we need to transfer the ETH over before switching contexts.
        if (
            messageValue > 0
            && _isValueType(_messageType)
        ) {
            // Handle out-of-intrinsic gas consistent with EVM behavior -- the subcall "appears to revert" if we don't have enough gas to transfer the ETH.
            // Similar to dynamic gas cost of value exceeding gas here:
            // https://github.com/ethereum/go-ethereum/blob/c503f98f6d5e80e079c1d8a3601d188af2a899da/core/vm/interpreter.go#L268-L273
            if (gasleft() < CALL_WITH_VALUE_INTRINSIC_GAS) {
                return (false, hex"");
            }

            // If there *is* enough gas to transfer ETH, then we need to make sure this amount of gas is reserved (i.e. not
            // given to the _contract.call below) to guarantee that _handleExternalMessage can't run out of gas.
            // In particular, in the event that the call fails, we will need to transfer the ETH back to the sender.
            // Taking the lesser of _gasLimit and gasleft() - CALL_WITH_VALUE_INTRINSIC_GAS guarantees that the second
            // _attemptForcedEthTransfer below, if needed, always has enough gas to succeed.
            _gasLimit = Math.min(
                _gasLimit,
                gasleft() - CALL_WITH_VALUE_INTRINSIC_GAS // Cannot overflow due to the above check.
            );

            // Now transfer the value of the call.
            // The target is interpreted to be the next message's ovmADDRESS account.
            bool transferredOvmEth = _attemptForcedEthTransfer(
                _nextMessageContext.ovmADDRESS,
                messageValue
            );

            // If the ETH transfer fails (should only be possible in the case of insufficient balance), then treat this as a revert.
            // This mirrors EVM behavior, see https://github.com/ethereum/go-ethereum/blob/2dee31930c9977af2a9fcb518fb9838aa609a7cf/core/vm/evm.go#L298
            if (!transferredOvmEth) {
                return (false, hex"");
            }
        }

        // We need to switch over to our next message context for the duration of this call.
        MessageContext memory prevMessageContext = messageContext;
        _switchMessageContext(prevMessageContext, _nextMessageContext);

        // Nuisance gas is a system used to bound the ability for an attacker to make fraud proofs
        // expensive by touching a lot of different accounts or storage slots. Since most contracts
        // only use a few storage slots during any given transaction, this shouldn't be a limiting
        // factor.
        uint256 prevNuisanceGasLeft = messageRecord.nuisanceGasLeft;
        uint256 nuisanceGasLimit = _getNuisanceGasLimit(_gasLimit);
        messageRecord.nuisanceGasLeft = nuisanceGasLimit;

        // Make the call and make sure to pass in the gas limit. Another instance of hidden
        // complexity. `_contract` is guaranteed to be a safe contract, meaning its return/revert
        // behavior can be controlled. In particular, we enforce that flags are passed through
        // revert data as to retrieve execution metadata that would normally be reverted out of
        // existence.

        bool success;
        bytes memory returndata;
        if (_isCreateType(_messageType)) {
            // safeCREATE() is a function which replicates a CREATE message, but uses return values
            // Which match that of CALL (i.e. bool, bytes).  This allows many security checks to be
            // to be shared between untrusted call and create call frames.
            (success, returndata) = address(this).call{gas: _gasLimit}(
                abi.encodeWithSelector(
                    this.safeCREATE.selector,
                    _data,
                    _contract
                )
            );
        } else {
            (success, returndata) = _contract.call{gas: _gasLimit}(_data);
        }

        // If the message threw an exception, its value should be returned back to the sender.
        // So, we force it back, BEFORE returning the messageContext to the previous addresses.
        // This operation is part of the reason we "reserved the intrinsic gas" above.
        if (
            messageValue > 0
            && _isValueType(_messageType)
            && !success
        ) {
            bool transferredOvmEth = _attemptForcedEthTransfer(
                prevMessageContext.ovmADDRESS,
                messageValue
            );

            // Since we transferred it in above and the call reverted, the transfer back should always pass.
            // This code path should NEVER be triggered since we sent `messageValue` worth of OVM_ETH into the target
            // and reserved sufficient gas to execute the transfer, but in case there is some edge case which has
            // been missed, we revert the entire frame (and its parent) to make sure the ETH gets sent back.
            if (!transferredOvmEth) {
                _revertWithFlag(RevertFlag.OUT_OF_GAS);
            }
        }

        // Switch back to the original message context now that we're out of the call and all OVM_ETH is in the right place.
        _switchMessageContext(_nextMessageContext, prevMessageContext);

        // Assuming there were no reverts, the message record should be accurate here. We'll update
        // this value in the case of a revert.
        uint256 nuisanceGasLeft = messageRecord.nuisanceGasLeft;

        // Reverts at this point are completely OK, but we need to make a few updates based on the
        // information passed through the revert.
        if (success == false) {
            (
                RevertFlag flag,
                uint256 nuisanceGasLeftPostRevert,
                uint256 ovmGasRefund,
                bytes memory returndataFromFlag
            ) = _decodeRevertData(returndata);

            // INVALID_STATE_ACCESS is the only flag that triggers an immediate abort of the
            // parent EVM message. This behavior is necessary because INVALID_STATE_ACCESS must
            // halt any further transaction execution that could impact the execution result.
            if (flag == RevertFlag.INVALID_STATE_ACCESS) {
                _revertWithFlag(flag);
            }

            // INTENTIONAL_REVERT, UNSAFE_BYTECODE, STATIC_VIOLATION, and CREATOR_NOT_ALLOWED aren't
            // dependent on the input state, so we can just handle them like standard reverts. Our only change here
            // is to record the gas refund reported by the call (enforced by safety checking).
            if (
                flag == RevertFlag.INTENTIONAL_REVERT
                || flag == RevertFlag.UNSAFE_BYTECODE
                || flag == RevertFlag.STATIC_VIOLATION
                || flag == RevertFlag.CREATOR_NOT_ALLOWED
            ) {
                transactionRecord.ovmGasRefund = ovmGasRefund;
            }

            // INTENTIONAL_REVERT needs to pass up the user-provided return data encoded into the
            // flag, *not* the full encoded flag.  Additionally, we surface custom error messages
            // to developers in the case of unsafe creations for improved devex.
            // All other revert types return no data.
            if (
                flag == RevertFlag.INTENTIONAL_REVERT
                || flag == RevertFlag.UNSAFE_BYTECODE
            ) {
                returndata = returndataFromFlag;
            } else {
                returndata = hex'';
            }

            // Reverts mean we need to use up whatever "nuisance gas" was used by the call.
            // EXCEEDS_NUISANCE_GAS explicitly reduces the remaining nuisance gas for this message
            // to zero. OUT_OF_GAS is a "pseudo" flag given that messages return no data when they
            // run out of gas, so we have to treat this like EXCEEDS_NUISANCE_GAS. All other flags
            // will simply pass up the remaining nuisance gas.
            nuisanceGasLeft = nuisanceGasLeftPostRevert;
        }

        // We need to reset the nuisance gas back to its original value minus the amount used here.
        messageRecord.nuisanceGasLeft = prevNuisanceGasLeft - (nuisanceGasLimit - nuisanceGasLeft);

        return (
            success,
            returndata
        );
    }

    /**
     * Handles the creation-specific safety measures required for OVM contract deployment.
     * This function sanitizes the return types for creation messages to match calls (bool, bytes),
     * by being an external function which the EM can call, that mimics the success/fail case of the CREATE.
     * This allows for consistent handling of both types of messages in _handleExternalMessage().
     * Having this step occur as a separate call frame also allows us to easily revert the
     * contract deployment in the event that the code is unsafe.
     *
     * @param _creationCode Code to pass into CREATE for deployment.
     * @param _address OVM address being deployed to.
     */
    function safeCREATE(
        bytes memory _creationCode,
        address _address
    )
        external
    {
        // The only way this should callable is from within _createContract(),
        // and it should DEFINITELY not be callable by a non-EM code contract.
        if (msg.sender != address(this)) {
            return;
        }
        // Check that there is not already code at this address.
        if (_hasEmptyAccount(_address) == false) {
            // Note: in the EVM, this case burns all allotted gas.  For improved
            // developer experience, we do return the remaining gas.
            _revertWithFlag(
                RevertFlag.CREATE_COLLISION
            );
        }

        // Check the creation bytecode against the OVM_SafetyChecker.
        if (ovmSafetyChecker.isBytecodeSafe(_creationCode) == false) {
            // Note: in the EVM, this case burns all allotted gas.  For improved
            // developer experience, we do return the remaining gas.
            _revertWithFlag(
                RevertFlag.UNSAFE_BYTECODE,
                Lib_ErrorUtils.encodeRevertString("Contract creation code contains unsafe opcodes. Did you use the right compiler or pass an unsafe constructor argument?")
            );
        }

        // We always need to initialize the contract with the default account values.
        _initPendingAccount(_address);

        // Actually execute the EVM create message.
        // NOTE: The inline assembly below means we can NOT make any evm calls between here and then.
        address ethAddress = Lib_EthUtils.createContract(_creationCode);

        if (ethAddress == address(0)) {
            // If the creation fails, the EVM lets us grab its revert data. This may contain a revert flag
            // to be used above in _handleExternalMessage, so we pass the revert data back up unmodified.
            assembly {
                returndatacopy(0,0,returndatasize())
                revert(0, returndatasize())
            }
        }

        // Again simply checking that the deployed code is safe too. Contracts can generate
        // arbitrary deployment code, so there's no easy way to analyze this beforehand.
        bytes memory deployedCode = Lib_EthUtils.getCode(ethAddress);
        if (ovmSafetyChecker.isBytecodeSafe(deployedCode) == false) {
            _revertWithFlag(
                RevertFlag.UNSAFE_BYTECODE,
                Lib_ErrorUtils.encodeRevertString("Constructor attempted to deploy unsafe bytecode.")
            );
        }

        // Contract creation didn't need to be reverted and the bytecode is safe. We finish up by
        // associating the desired address with the newly created contract's code hash and address.
        _commitPendingAccount(
            _address,
            ethAddress,
            Lib_EthUtils.getCodeHash(ethAddress)
        );
    }

    /******************************************
     * Internal Functions: Value Manipulation *
     ******************************************/

    /**
     * Invokes an ovmCALL to OVM_ETH.transfer on behalf of the current ovmADDRESS, allowing us to force movement of OVM_ETH in correspondence with ETH's native value functionality.
     * WARNING: this will send on behalf of whatever the messageContext.ovmADDRESS is in storage at the time of the call.
     * NOTE: In the future, this could be optimized to directly invoke EM._setContractStorage(...).
     * @param _to Amount of OVM_ETH to be sent.
     * @param _value Amount of OVM_ETH to send.
     * @return _success Whether or not the transfer worked.
     */
    function _attemptForcedEthTransfer(
        address _to,
        uint256 _value
    )
        internal
        returns(
            bool _success
        )
    {
        bytes memory transferCalldata = abi.encodeWithSignature(
            "transfer(address,uint256)",
            _to,
            _value
        );

        // OVM_ETH inherits from the UniswapV2ERC20 standard.  In this implementation, its return type
        // is a boolean.  However, the implementation always returns true if it does not revert.
        // Thus, success of the call frame is sufficient to infer success of the transfer itself.
        (bool success, ) = ovmCALL(
            gasleft(),
            Lib_PredeployAddresses.OVM_ETH,
            0,
            transferCalldata
        );

        return success;
    }

    /******************************************
     * Internal Functions: State Manipulation *
     ******************************************/

    /**
     * Checks whether an account exists within the OVM_StateManager.
     * @param _address Address of the account to check.
     * @return _exists Whether or not the account exists.
     */
    function _hasAccount(
        address _address
    )
        internal
        returns (
            bool _exists
        )
    {
        _checkAccountLoad(_address);
        return ovmStateManager.hasAccount(_address);
    }

    /**
     * Checks whether a known empty account exists within the OVM_StateManager.
     * @param _address Address of the account to check.
     * @return _exists Whether or not the account empty exists.
     */
    function _hasEmptyAccount(
        address _address
    )
        internal
        returns (
            bool _exists
        )
    {
        _checkAccountLoad(_address);
        return ovmStateManager.hasEmptyAccount(_address);
    }

    /**
     * Sets the nonce of an account.
     * @param _address Address of the account to modify.
     * @param _nonce New account nonce.
     */
    function _setAccountNonce(
        address _address,
        uint256 _nonce
    )
        internal
    {
        _checkAccountChange(_address);
        ovmStateManager.setAccountNonce(_address, _nonce);
    }

    /**
     * Gets the nonce of an account.
     * @param _address Address of the account to access.
     * @return _nonce Nonce of the account.
     */
    function _getAccountNonce(
        address _address
    )
        internal
        returns (
            uint256 _nonce
        )
    {
        _checkAccountLoad(_address);
        return ovmStateManager.getAccountNonce(_address);
    }

    /**
     * Retrieves the Ethereum address of an account.
     * @param _address Address of the account to access.
     * @return _ethAddress Corresponding Ethereum address.
     */
    function _getAccountEthAddress(
        address _address
    )
        internal
        returns (
            address _ethAddress
        )
    {
        _checkAccountLoad(_address);
        return ovmStateManager.getAccountEthAddress(_address);
    }

    /**
     * Creates the default account object for the given address.
     * @param _address Address of the account create.
     */
    function _initPendingAccount(
        address _address
    )
        internal
    {
        // Although it seems like `_checkAccountChange` would be more appropriate here, we don't
        // actually consider an account "changed" until it's inserted into the state (in this case
        // by `_commitPendingAccount`).
        _checkAccountLoad(_address);
        ovmStateManager.initPendingAccount(_address);
    }

    /**
     * Stores additional relevant data for a new account, thereby "committing" it to the state.
     * This function is only called during `ovmCREATE` and `ovmCREATE2` after a successful contract
     * creation.
     * @param _address Address of the account to commit.
     * @param _ethAddress Address of the associated deployed contract.
     * @param _codeHash Hash of the code stored at the address.
     */
    function _commitPendingAccount(
        address _address,
        address _ethAddress,
        bytes32 _codeHash
    )
        internal
    {
        _checkAccountChange(_address);
        ovmStateManager.commitPendingAccount(
            _address,
            _ethAddress,
            _codeHash
        );
    }

    /**
     * Retrieves the value of a storage slot.
     * @param _contract Address of the contract to query.
     * @param _key 32 byte key of the storage slot.
     * @return _value 32 byte storage slot value.
     */
    function _getContractStorage(
        address _contract,
        bytes32 _key
    )
        internal
        returns (
            bytes32 _value
        )
    {
        _checkContractStorageLoad(_contract, _key);
        return ovmStateManager.getContractStorage(_contract, _key);
    }

    /**
     * Sets the value of a storage slot.
     * @param _contract Address of the contract to modify.
     * @param _key 32 byte key of the storage slot.
     * @param _value 32 byte storage slot value.
     */
    function _putContractStorage(
        address _contract,
        bytes32 _key,
        bytes32 _value
    )
        internal
    {
        // We don't set storage if the value didn't change. Although this acts as a convenient
        // optimization, it's also necessary to avoid the case in which a contract with no storage
        // attempts to store the value "0" at any key. Putting this value (and therefore requiring
        // that the value be committed into the storage trie after execution) would incorrectly
        // modify the storage root.
        if (_getContractStorage(_contract, _key) == _value) {
            return;
        }

        _checkContractStorageChange(_contract, _key);
        ovmStateManager.putContractStorage(_contract, _key, _value);
    }

    /**
     * Validation whenever a contract needs to be loaded. Checks that the account exists, charges
     * nuisance gas if the account hasn't been loaded before.
     * @param _address Address of the account to load.
     */
    function _checkAccountLoad(
        address _address
    )
        internal
    {
        // See `_checkContractStorageLoad` for more information.
        if (gasleft() < MIN_GAS_FOR_INVALID_STATE_ACCESS) {
            _revertWithFlag(RevertFlag.OUT_OF_GAS);
        }

        // See `_checkContractStorageLoad` for more information.
        if (ovmStateManager.hasAccount(_address) == false) {
            _revertWithFlag(RevertFlag.INVALID_STATE_ACCESS);
        }

        // Check whether the account has been loaded before and mark it as loaded if not. We need
        // this because "nuisance gas" only applies to the first time that an account is loaded.
        (
            bool _wasAccountAlreadyLoaded
        ) = ovmStateManager.testAndSetAccountLoaded(_address);

        // If we hadn't already loaded the account, then we'll need to charge "nuisance gas" based
        // on the size of the contract code.
        if (_wasAccountAlreadyLoaded == false) {
            _useNuisanceGas(
                (Lib_EthUtils.getCodeSize(_getAccountEthAddress(_address)) * NUISANCE_GAS_PER_CONTRACT_BYTE) + MIN_NUISANCE_GAS_PER_CONTRACT
            );
        }
    }

    /**
     * Validation whenever a contract needs to be changed. Checks that the account exists, charges
     * nuisance gas if the account hasn't been changed before.
     * @param _address Address of the account to change.
     */
    function _checkAccountChange(
        address _address
    )
        internal
    {
        // Start by checking for a load as we only want to charge nuisance gas proportional to
        // contract size once.
        _checkAccountLoad(_address);

        // Check whether the account has been changed before and mark it as changed if not. We need
        // this because "nuisance gas" only applies to the first time that an account is changed.
        (
            bool _wasAccountAlreadyChanged
        ) = ovmStateManager.testAndSetAccountChanged(_address);

        // If we hadn't already loaded the account, then we'll need to charge "nuisance gas" based
        // on the size of the contract code.
        if (_wasAccountAlreadyChanged == false) {
            ovmStateManager.incrementTotalUncommittedAccounts();
            _useNuisanceGas(
                (Lib_EthUtils.getCodeSize(_getAccountEthAddress(_address)) * NUISANCE_GAS_PER_CONTRACT_BYTE) + MIN_NUISANCE_GAS_PER_CONTRACT
            );
        }
    }

    /**
     * Validation whenever a slot needs to be loaded. Checks that the account exists, charges
     * nuisance gas if the slot hasn't been loaded before.
     * @param _contract Address of the account to load from.
     * @param _key 32 byte key to load.
     */
    function _checkContractStorageLoad(
        address _contract,
        bytes32 _key
    )
        internal
    {
        // Another case of hidden complexity. If we didn't enforce this requirement, then a
        // contract could pass in just enough gas to cause the INVALID_STATE_ACCESS check to fail
        // on L1 but not on L2. A contract could use this behavior to prevent the
        // OVM_ExecutionManager from detecting an invalid state access. Reverting with OUT_OF_GAS
        // allows us to also charge for the full message nuisance gas, because you deserve that for
        // trying to break the contract in this way.
        if (gasleft() < MIN_GAS_FOR_INVALID_STATE_ACCESS) {
            _revertWithFlag(RevertFlag.OUT_OF_GAS);
        }

        // We need to make sure that the transaction isn't trying to access storage that hasn't
        // been provided to the OVM_StateManager. We'll immediately abort if this is the case.
        // We know that we have enough gas to do this check because of the above test.
        if (ovmStateManager.hasContractStorage(_contract, _key) == false) {
            _revertWithFlag(RevertFlag.INVALID_STATE_ACCESS);
        }

        // Check whether the slot has been loaded before and mark it as loaded if not. We need
        // this because "nuisance gas" only applies to the first time that a slot is loaded.
        (
            bool _wasContractStorageAlreadyLoaded
        ) = ovmStateManager.testAndSetContractStorageLoaded(_contract, _key);

        // If we hadn't already loaded the account, then we'll need to charge some fixed amount of
        // "nuisance gas".
        if (_wasContractStorageAlreadyLoaded == false) {
            _useNuisanceGas(NUISANCE_GAS_SLOAD);
        }
    }

    /**
     * Validation whenever a slot needs to be changed. Checks that the account exists, charges
     * nuisance gas if the slot hasn't been changed before.
     * @param _contract Address of the account to change.
     * @param _key 32 byte key to change.
     */
    function _checkContractStorageChange(
        address _contract,
        bytes32 _key
    )
        internal
    {
        // Start by checking for load to make sure we have the storage slot and that we charge the
        // "nuisance gas" necessary to prove the storage slot state.
        _checkContractStorageLoad(_contract, _key);

        // Check whether the slot has been changed before and mark it as changed if not. We need
        // this because "nuisance gas" only applies to the first time that a slot is changed.
        (
            bool _wasContractStorageAlreadyChanged
        ) = ovmStateManager.testAndSetContractStorageChanged(_contract, _key);

        // If we hadn't already changed the account, then we'll need to charge some fixed amount of
        // "nuisance gas".
        if (_wasContractStorageAlreadyChanged == false) {
            // Changing a storage slot means that we're also going to have to change the
            // corresponding account, so do an account change check.
            _checkAccountChange(_contract);

            ovmStateManager.incrementTotalUncommittedContractStorage();
            _useNuisanceGas(NUISANCE_GAS_SSTORE);
        }
    }


    /************************************
     * Internal Functions: Revert Logic *
     ************************************/

    /**
     * Simple encoding for revert data.
     * @param _flag Flag to revert with.
     * @param _data Additional user-provided revert data.
     * @return _revertdata Encoded revert data.
     */
    function _encodeRevertData(
        RevertFlag _flag,
        bytes memory _data
    )
        internal
        view
        returns (
            bytes memory _revertdata
        )
    {
        // Out of gas and create exceptions will fundamentally return no data, so simulating it shouldn't either.
        if (
            _flag == RevertFlag.OUT_OF_GAS
        ) {
            return bytes('');
        }

        // INVALID_STATE_ACCESS doesn't need to return any data other than the flag.
        if (_flag == RevertFlag.INVALID_STATE_ACCESS) {
            return abi.encode(
                _flag,
                0,
                0,
                bytes('')
            );
        }

        // Just ABI encode the rest of the parameters.
        return abi.encode(
            _flag,
            messageRecord.nuisanceGasLeft,
            transactionRecord.ovmGasRefund,
            _data
        );
    }

    /**
     * Simple decoding for revert data.
     * @param _revertdata Revert data to decode.
     * @return _flag Flag used to revert.
     * @return _nuisanceGasLeft Amount of nuisance gas unused by the message.
     * @return _ovmGasRefund Amount of gas refunded during the message.
     * @return _data Additional user-provided revert data.
     */
    function _decodeRevertData(
        bytes memory _revertdata
    )
        internal
        pure
        returns (
            RevertFlag _flag,
            uint256 _nuisanceGasLeft,
            uint256 _ovmGasRefund,
            bytes memory _data
        )
    {
        // A length of zero means the call ran out of gas, just return empty data.
        if (_revertdata.length == 0) {
            return (
                RevertFlag.OUT_OF_GAS,
                0,
                0,
                bytes('')
            );
        }

        // ABI decode the incoming data.
        return abi.decode(_revertdata, (RevertFlag, uint256, uint256, bytes));
    }

    /**
     * Causes a message to revert or abort.
     * @param _flag Flag to revert with.
     * @param _data Additional user-provided data.
     */
    function _revertWithFlag(
        RevertFlag _flag,
        bytes memory _data
    )
        internal
        view
    {
        bytes memory revertdata = _encodeRevertData(
            _flag,
            _data
        );

        assembly {
            revert(add(revertdata, 0x20), mload(revertdata))
        }
    }

    /**
     * Causes a message to revert or abort.
     * @param _flag Flag to revert with.
     */
    function _revertWithFlag(
        RevertFlag _flag
    )
        internal
    {
        _revertWithFlag(_flag, bytes(''));
    }


    /******************************************
     * Internal Functions: Nuisance Gas Logic *
     ******************************************/

    /**
     * Computes the nuisance gas limit from the gas limit.
     * @dev This function is currently using a naive implementation whereby the nuisance gas limit
     *      is set to exactly equal the lesser of the gas limit or remaining gas. It's likely that
     *      this implementation is perfectly fine, but we may change this formula later.
     * @param _gasLimit Gas limit to compute from.
     * @return _nuisanceGasLimit Computed nuisance gas limit.
     */
    function _getNuisanceGasLimit(
        uint256 _gasLimit
    )
        internal
        view
        returns (
            uint256 _nuisanceGasLimit
        )
    {
        return _gasLimit < gasleft() ? _gasLimit : gasleft();
    }

    /**
     * Uses a certain amount of nuisance gas.
     * @param _amount Amount of nuisance gas to use.
     */
    function _useNuisanceGas(
        uint256 _amount
    )
        internal
    {
        // Essentially the same as a standard OUT_OF_GAS, except we also retain a record of the gas
        // refund to be given at the end of the transaction.
        if (messageRecord.nuisanceGasLeft < _amount) {
            _revertWithFlag(RevertFlag.EXCEEDS_NUISANCE_GAS);
        }

        messageRecord.nuisanceGasLeft -= _amount;
    }


    /************************************
     * Internal Functions: Gas Metering *
     ************************************/

    /**
     * Checks whether a transaction needs to start a new epoch and does so if necessary.
     * @param _timestamp Transaction timestamp.
     */
    function _checkNeedsNewEpoch(
        uint256 _timestamp
    )
        internal
    {
        if (
            _timestamp >= (
                _getGasMetadata(GasMetadataKey.CURRENT_EPOCH_START_TIMESTAMP)
                + gasMeterConfig.secondsPerEpoch
            )
        ) {
            _putGasMetadata(
                GasMetadataKey.CURRENT_EPOCH_START_TIMESTAMP,
                _timestamp
            );

            _putGasMetadata(
                GasMetadataKey.PREV_EPOCH_SEQUENCER_QUEUE_GAS,
                _getGasMetadata(
                    GasMetadataKey.CUMULATIVE_SEQUENCER_QUEUE_GAS
                )
            );

            _putGasMetadata(
                GasMetadataKey.PREV_EPOCH_L1TOL2_QUEUE_GAS,
                _getGasMetadata(
                    GasMetadataKey.CUMULATIVE_L1TOL2_QUEUE_GAS
                )
            );
        }
    }

    /**
     * Validates the input values of a transaction.
     * @return _valid Whether or not the transaction data is valid.
     */
    function _isValidInput(
        Lib_OVMCodec.Transaction memory _transaction
    )
        view
        internal
        returns (
            bool
        )
    {
        // Prevent reentrancy to run():
        // This check prevents calling run with the default ovmNumber.
        // Combined with the first check in run():
        //      if (transactionContext.ovmNUMBER != DEFAULT_UINT256) { return; }
        // It should be impossible to re-enter since run() returns before any other call frames are created.
        // Since this value is already being written to storage, we save much gas compared to
        // using the standard nonReentrant pattern.
        if (_transaction.blockNumber == DEFAULT_UINT256)  {
            return false;
        }

        if (_isValidGasLimit(_transaction.gasLimit, _transaction.l1QueueOrigin) == false) {
            return false;
        }

        return true;
    }

    /**
     * Validates the gas limit for a given transaction.
     * @param _gasLimit Gas limit provided by the transaction.
     * param _queueOrigin Queue from which the transaction originated.
     * @return _valid Whether or not the gas limit is valid.
     */
    function _isValidGasLimit(
        uint256 _gasLimit,
        Lib_OVMCodec.QueueOrigin // _queueOrigin
    )
        view
        internal
        returns (
            bool _valid
        )
    {
        // Always have to be below the maximum gas limit.
        if (_gasLimit > gasMeterConfig.maxTransactionGasLimit) {
            return false;
        }

        // Always have to be above the minimum gas limit.
        if (_gasLimit < gasMeterConfig.minTransactionGasLimit) {
            return false;
        }

        // TEMPORARY: Gas metering is disabled for minnet.
        return true;
        // GasMetadataKey cumulativeGasKey;
        // GasMetadataKey prevEpochGasKey;
        // if (_queueOrigin == Lib_OVMCodec.QueueOrigin.SEQUENCER_QUEUE) {
        //     cumulativeGasKey = GasMetadataKey.CUMULATIVE_SEQUENCER_QUEUE_GAS;
        //     prevEpochGasKey = GasMetadataKey.PREV_EPOCH_SEQUENCER_QUEUE_GAS;
        // } else {
        //     cumulativeGasKey = GasMetadataKey.CUMULATIVE_L1TOL2_QUEUE_GAS;
        //     prevEpochGasKey = GasMetadataKey.PREV_EPOCH_L1TOL2_QUEUE_GAS;
        // }

        // return (
        //     (
        //         _getGasMetadata(cumulativeGasKey)
        //         - _getGasMetadata(prevEpochGasKey)
        //         + _gasLimit
        //     ) < gasMeterConfig.maxGasPerQueuePerEpoch
        // );
    }

    /**
     * Updates the cumulative gas after a transaction.
     * @param _gasUsed Gas used by the transaction.
     * @param _queueOrigin Queue from which the transaction originated.
     */
    function _updateCumulativeGas(
        uint256 _gasUsed,
        Lib_OVMCodec.QueueOrigin _queueOrigin
    )
        internal
    {
        GasMetadataKey cumulativeGasKey;
        if (_queueOrigin == Lib_OVMCodec.QueueOrigin.SEQUENCER_QUEUE) {
            cumulativeGasKey = GasMetadataKey.CUMULATIVE_SEQUENCER_QUEUE_GAS;
        } else {
            cumulativeGasKey = GasMetadataKey.CUMULATIVE_L1TOL2_QUEUE_GAS;
        }

        _putGasMetadata(
            cumulativeGasKey,
            (
                _getGasMetadata(cumulativeGasKey)
                + gasMeterConfig.minTransactionGasLimit
                + _gasUsed
                - transactionRecord.ovmGasRefund
            )
        );
    }

    /**
     * Retrieves the value of a gas metadata key.
     * @param _key Gas metadata key to retrieve.
     * @return _value Value stored at the given key.
     */
    function _getGasMetadata(
        GasMetadataKey _key
    )
        internal
        returns (
            uint256 _value
        )
    {
        return uint256(_getContractStorage(
            GAS_METADATA_ADDRESS,
            bytes32(uint256(_key))
        ));
    }

    /**
     * Sets the value of a gas metadata key.
     * @param _key Gas metadata key to set.
     * @param _value Value to store at the given key.
     */
    function _putGasMetadata(
        GasMetadataKey _key,
        uint256 _value
    )
        internal
    {
        _putContractStorage(
            GAS_METADATA_ADDRESS,
            bytes32(uint256(_key)),
            bytes32(uint256(_value))
        );
    }


    /*****************************************
     * Internal Functions: Execution Context *
     *****************************************/

    /**
     * Swaps over to a new message context.
     * @param _prevMessageContext Context we're switching from.
     * @param _nextMessageContext Context we're switching to.
     */
    function _switchMessageContext(
        MessageContext memory _prevMessageContext,
        MessageContext memory _nextMessageContext
    )
        internal
    {
        // These conditionals allow us to avoid unneccessary SSTOREs.  However, they do mean that the current storage
        // value for the messageContext MUST equal the _prevMessageContext argument, or an SSTORE might be erroneously skipped.
        if (_prevMessageContext.ovmCALLER != _nextMessageContext.ovmCALLER) {
            messageContext.ovmCALLER = _nextMessageContext.ovmCALLER;
        }

        if (_prevMessageContext.ovmADDRESS != _nextMessageContext.ovmADDRESS) {
            messageContext.ovmADDRESS = _nextMessageContext.ovmADDRESS;
        }

        if (_prevMessageContext.isStatic != _nextMessageContext.isStatic) {
            messageContext.isStatic = _nextMessageContext.isStatic;
        }

        if (_prevMessageContext.ovmCALLVALUE != _nextMessageContext.ovmCALLVALUE) {
            messageContext.ovmCALLVALUE = _nextMessageContext.ovmCALLVALUE;
        }
    }

    /**
     * Initializes the execution context.
     * @param _transaction OVM transaction being executed.
     */
    function _initContext(
        Lib_OVMCodec.Transaction memory _transaction
    )
        internal
    {
        transactionContext.ovmTIMESTAMP = _transaction.timestamp;
        transactionContext.ovmNUMBER = _transaction.blockNumber;
        transactionContext.ovmTXGASLIMIT = _transaction.gasLimit;
        transactionContext.ovmL1QUEUEORIGIN = _transaction.l1QueueOrigin;
        transactionContext.ovmL1TXORIGIN = _transaction.l1TxOrigin;
        transactionContext.ovmGASLIMIT = gasMeterConfig.maxGasPerQueuePerEpoch;

        messageRecord.nuisanceGasLeft = _getNuisanceGasLimit(_transaction.gasLimit);
    }

    /**
     * Resets the transaction and message context.
     */
    function _resetContext()
        internal
    {
        transactionContext.ovmL1TXORIGIN = DEFAULT_ADDRESS;
        transactionContext.ovmTIMESTAMP = DEFAULT_UINT256;
        transactionContext.ovmNUMBER = DEFAULT_UINT256;
        transactionContext.ovmGASLIMIT = DEFAULT_UINT256;
        transactionContext.ovmTXGASLIMIT = DEFAULT_UINT256;
        transactionContext.ovmL1QUEUEORIGIN = Lib_OVMCodec.QueueOrigin.SEQUENCER_QUEUE;

        transactionRecord.ovmGasRefund = DEFAULT_UINT256;

        messageContext.ovmCALLER = DEFAULT_ADDRESS;
        messageContext.ovmADDRESS = DEFAULT_ADDRESS;
        messageContext.isStatic = false;

        messageRecord.nuisanceGasLeft = DEFAULT_UINT256;

        // Reset the ovmStateManager.
        ovmStateManager = iOVM_StateManager(address(0));
    }


    /******************************************
     * Internal Functions: Message Typechecks *
     ******************************************/

    /**
     * Returns whether or not the given message type is a CREATE-type.
     * @param _messageType the message type in question.
     */
    function _isCreateType(
        MessageType _messageType
    )
        internal
        pure
        returns(
            bool
        )
    {
        return (
            _messageType == MessageType.ovmCREATE
            || _messageType == MessageType.ovmCREATE2
        );
    }

    /**
     * Returns whether or not the given message type (potentially) requires the transfer of ETH value along with the message.
     * @param _messageType the message type in question.
     */
    function _isValueType(
        MessageType _messageType
    )
        internal
        pure
        returns(
            bool
        )
    {
        // ovmSTATICCALL and ovmDELEGATECALL types do not accept or transfer value.
        return (
            _messageType == MessageType.ovmCALL
            || _messageType == MessageType.ovmCREATE
            || _messageType == MessageType.ovmCREATE2
        );
    }


    /*****************************
     * L2-only Helper Functions *
     *****************************/

    /**
     * Unreachable helper function for simulating eth_calls with an OVM message context.
     * This function will throw an exception in all cases other than when used as a custom entrypoint in L2 Geth to simulate eth_call.
     * @param _transaction the message transaction to simulate.
     * @param _from the OVM account the simulated call should be from.
     * @param _value the amount of ETH value to send.
     * @param _ovmStateManager the address of the OVM_StateManager precompile in the L2 state.
     */
    function simulateMessage(
        Lib_OVMCodec.Transaction memory _transaction,
        address _from,
        uint256 _value,
        iOVM_StateManager _ovmStateManager
    )
        external
        returns (
            bytes memory
        )
    {
        // Prevent this call from having any effect unless in a custom-set VM frame
        require(msg.sender == address(0));

        // Initialize the EM's internal state, ignoring nuisance gas.
        ovmStateManager = _ovmStateManager;
        _initContext(_transaction);
        messageRecord.nuisanceGasLeft = uint(-1);

        // Set the ovmADDRESS to the _from so that the subsequent call frame "comes from" them.
        messageContext.ovmADDRESS = _from;

        // Execute the desired message.
        bool isCreate = _transaction.entrypoint == address(0);
        if (isCreate) {
            (address created, bytes memory revertData) = ovmCREATE(_transaction.data);
            if (created == address(0)) {
                return abi.encode(false, revertData);
            } else {
                // The eth_call RPC endpoint for to = undefined will return the deployed bytecode
                // in the success case, differing from standard create messages.
                return abi.encode(true, Lib_EthUtils.getCode(created));
            }
        } else {
            (bool success, bytes memory returndata) = ovmCALL(
                _transaction.gasLimit,
                _transaction.entrypoint,
                _value,
                _transaction.data
            );
            return abi.encode(success, returndata);
        }
    }
}

// SPDX-License-Identifier: MIT
pragma solidity >0.5.0 <0.8.0;

/* Interface Imports */
import { iOVM_DeployerWhitelist } from "../../iOVM/predeploys/iOVM_DeployerWhitelist.sol";

/**
 * @title OVM_DeployerWhitelist
 * @dev The Deployer Whitelist is a temporary predeploy used to provide additional safety during the
 * initial phases of our mainnet roll out. It is owned by the Optimism team, and defines accounts
 * which are allowed to deploy contracts on Layer2. The Execution Manager will only allow an
 * ovmCREATE or ovmCREATE2 operation to proceed if the deployer's address whitelisted.
 *
 * Compiler used: optimistic-solc
 * Runtime target: OVM
 */
contract OVM_DeployerWhitelist is iOVM_DeployerWhitelist {

    /**********************
     * Contract Constants *
     **********************/

    bool public initialized;
    bool public allowArbitraryDeployment;
    address override public owner;
    mapping (address => bool) public whitelist;


    /**********************
     * Function Modifiers *
     **********************/

    /**
     * Blocks functions to anyone except the contract owner.
     */
    modifier onlyOwner() {
        require(
            msg.sender == owner,
            "Function can only be called by the owner of this contract."
        );
        _;
    }


    /********************
     * Public Functions *
     ********************/

    /**
     * Initializes the whitelist.
     * @param _owner Address of the owner for this contract.
     * @param _allowArbitraryDeployment Whether or not to allow arbitrary contract deployment.
     */
    function initialize(
        address _owner,
        bool _allowArbitraryDeployment
    )
        override
        external
    {
        if (initialized == true) {
            return;
        }

        initialized = true;
        allowArbitraryDeployment = _allowArbitraryDeployment;
        owner = _owner;
    }

    /**
     * Adds or removes an address from the deployment whitelist.
     * @param _deployer Address to update permissions for.
     * @param _isWhitelisted Whether or not the address is whitelisted.
     */
    function setWhitelistedDeployer(
        address _deployer,
        bool _isWhitelisted
    )
        override
        external
        onlyOwner
    {
        whitelist[_deployer] = _isWhitelisted;
    }

    /**
     * Updates the owner of this contract.
     * @param _owner Address of the new owner.
     */
    function setOwner(
        address _owner
    )
        override
        public
        onlyOwner
    {
        owner = _owner;
    }

    /**
     * Updates the arbitrary deployment flag.
     * @param _allowArbitraryDeployment Whether or not to allow arbitrary contract deployment.
     */
    function setAllowArbitraryDeployment(
        bool _allowArbitraryDeployment
    )
        override
        public
        onlyOwner
    {
        allowArbitraryDeployment = _allowArbitraryDeployment;
    }

    /**
     * Permanently enables arbitrary contract deployment and deletes the owner.
     */
    function enableArbitraryContractDeployment()
        override
        external
        onlyOwner
    {
        setAllowArbitraryDeployment(true);
        setOwner(address(0));
    }

    /**
     * Checks whether an address is allowed to deploy contracts.
     * @param _deployer Address to check.
     * @return _allowed Whether or not the address can deploy contracts.
     */
    function isDeployerAllowed(
        address _deployer
    )
        override
        external
        returns (
            bool
        )
    {
        return (
            initialized == false
            || allowArbitraryDeployment == true
            || whitelist[_deployer]
        );
    }
}

// SPDX-License-Identifier: MIT
pragma solidity >0.5.0 <0.8.0;
pragma experimental ABIEncoderV2;

/* Library Imports */
import { Lib_OVMCodec } from "../../libraries/codec/Lib_OVMCodec.sol";

interface iOVM_ExecutionManager {
    /**********
     * Enums *
     *********/

    enum RevertFlag {
        OUT_OF_GAS,
        INTENTIONAL_REVERT,
        EXCEEDS_NUISANCE_GAS,
        INVALID_STATE_ACCESS,
        UNSAFE_BYTECODE,
        CREATE_COLLISION,
        STATIC_VIOLATION,
        CREATOR_NOT_ALLOWED
    }

    enum GasMetadataKey {
        CURRENT_EPOCH_START_TIMESTAMP,
        CUMULATIVE_SEQUENCER_QUEUE_GAS,
        CUMULATIVE_L1TOL2_QUEUE_GAS,
        PREV_EPOCH_SEQUENCER_QUEUE_GAS,
        PREV_EPOCH_L1TOL2_QUEUE_GAS
    }

    enum MessageType {
        ovmCALL,
        ovmSTATICCALL,
        ovmDELEGATECALL,
        ovmCREATE,
        ovmCREATE2
    }

    /***********
     * Structs *
     ***********/

    struct GasMeterConfig {
        uint256 minTransactionGasLimit;
        uint256 maxTransactionGasLimit;
        uint256 maxGasPerQueuePerEpoch;
        uint256 secondsPerEpoch;
    }

    struct GlobalContext {
        uint256 ovmCHAINID;
    }

    struct TransactionContext {
        Lib_OVMCodec.QueueOrigin ovmL1QUEUEORIGIN;
        uint256 ovmTIMESTAMP;
        uint256 ovmNUMBER;
        uint256 ovmGASLIMIT;
        uint256 ovmTXGASLIMIT;
        address ovmL1TXORIGIN;
    }

    struct TransactionRecord {
        uint256 ovmGasRefund;
    }

    struct MessageContext {
        address ovmCALLER;
        address ovmADDRESS;
        uint256 ovmCALLVALUE;
        bool isStatic;
    }

    struct MessageRecord {
        uint256 nuisanceGasLeft;
    }


    /************************************
     * Transaction Execution Entrypoint *
     ************************************/

    function run(
        Lib_OVMCodec.Transaction calldata _transaction,
        address _txStateManager
    ) external returns (bytes memory);


    /*******************
     * Context Opcodes *
     *******************/

    function ovmCALLER() external view returns (address _caller);
    function ovmADDRESS() external view returns (address _address);
    function ovmCALLVALUE() external view returns (uint _callValue);
    function ovmTIMESTAMP() external view returns (uint256 _timestamp);
    function ovmNUMBER() external view returns (uint256 _number);
    function ovmGASLIMIT() external view returns (uint256 _gasLimit);
    function ovmCHAINID() external view returns (uint256 _chainId);


    /**********************
     * L2 Context Opcodes *
     **********************/

    function ovmL1QUEUEORIGIN() external view returns (Lib_OVMCodec.QueueOrigin _queueOrigin);
    function ovmL1TXORIGIN() external view returns (address _l1TxOrigin);


    /*******************
     * Halting Opcodes *
     *******************/

    function ovmREVERT(bytes memory _data) external;


    /*****************************
     * Contract Creation Opcodes *
     *****************************/

    function ovmCREATE(bytes memory _bytecode) external returns (address _contract, bytes memory _revertdata);
    function ovmCREATE2(bytes memory _bytecode, bytes32 _salt) external returns (address _contract, bytes memory _revertdata);


    /*******************************
     * Account Abstraction Opcodes *
     ******************************/

    function ovmGETNONCE() external returns (uint256 _nonce);
    function ovmINCREMENTNONCE() external;
    function ovmCREATEEOA(bytes32 _messageHash, uint8 _v, bytes32 _r, bytes32 _s) external;


    /****************************
     * Contract Calling Opcodes *
     ****************************/

    // Valueless ovmCALL for maintaining backwards compatibility with legacy OVM bytecode.
    function ovmCALL(uint256 _gasLimit, address _address, bytes memory _calldata) external returns (bool _success, bytes memory _returndata);
    function ovmCALL(uint256 _gasLimit, address _address, uint256 _value, bytes memory _calldata) external returns (bool _success, bytes memory _returndata);
    function ovmSTATICCALL(uint256 _gasLimit, address _address, bytes memory _calldata) external returns (bool _success, bytes memory _returndata);
    function ovmDELEGATECALL(uint256 _gasLimit, address _address, bytes memory _calldata) external returns (bool _success, bytes memory _returndata);


    /****************************
     * Contract Storage Opcodes *
     ****************************/

    function ovmSLOAD(bytes32 _key) external returns (bytes32 _value);
    function ovmSSTORE(bytes32 _key, bytes32 _value) external;


    /*************************
     * Contract Code Opcodes *
     *************************/

    function ovmEXTCODECOPY(address _contract, uint256 _offset, uint256 _length) external returns (bytes memory _code);
    function ovmEXTCODESIZE(address _contract) external returns (uint256 _size);
    function ovmEXTCODEHASH(address _contract) external returns (bytes32 _hash);


    /*********************
     * ETH Value Opcodes *
     *********************/

    function ovmBALANCE(address _contract) external returns (uint256 _balance);
    function ovmSELFBALANCE() external returns (uint256 _balance);


    /***************************************
     * Public Functions: Execution Context *
     ***************************************/

    function getMaxTransactionGasLimit() external view returns (uint _maxTransactionGasLimit);
}

// SPDX-License-Identifier: MIT
pragma solidity >0.5.0 <0.8.0;

/**
 * @title iOVM_SafetyChecker
 */
interface iOVM_SafetyChecker {

    /********************
     * Public Functions *
     ********************/

    function isBytecodeSafe(bytes calldata _bytecode) external pure returns (bool);
}

// SPDX-License-Identifier: MIT
pragma solidity >0.5.0 <0.8.0;
pragma experimental ABIEncoderV2;

/* Library Imports */
import { Lib_OVMCodec } from "../../libraries/codec/Lib_OVMCodec.sol";

/**
 * @title iOVM_StateManager
 */
interface iOVM_StateManager {

    /*******************
     * Data Structures *
     *******************/

    enum ItemState {
        ITEM_UNTOUCHED,
        ITEM_LOADED,
        ITEM_CHANGED,
        ITEM_COMMITTED
    }

    /***************************
     * Public Functions: Misc *
     ***************************/

    function isAuthenticated(address _address) external view returns (bool);

    /***************************
     * Public Functions: Setup *
     ***************************/

    function owner() external view returns (address _owner);
    function ovmExecutionManager() external view returns (address _ovmExecutionManager);
    function setExecutionManager(address _ovmExecutionManager) external;


    /************************************
     * Public Functions: Account Access *
     ************************************/

    function putAccount(address _address, Lib_OVMCodec.Account memory _account) external;
    function putEmptyAccount(address _address) external;
    function getAccount(address _address) external view returns (Lib_OVMCodec.Account memory _account);
    function hasAccount(address _address) external view returns (bool _exists);
    function hasEmptyAccount(address _address) external view returns (bool _exists);
    function setAccountNonce(address _address, uint256 _nonce) external;
    function getAccountNonce(address _address) external view returns (uint256 _nonce);
    function getAccountEthAddress(address _address) external view returns (address _ethAddress);
    function getAccountStorageRoot(address _address) external view returns (bytes32 _storageRoot);
    function initPendingAccount(address _address) external;
    function commitPendingAccount(address _address, address _ethAddress, bytes32 _codeHash) external;
    function testAndSetAccountLoaded(address _address) external returns (bool _wasAccountAlreadyLoaded);
    function testAndSetAccountChanged(address _address) external returns (bool _wasAccountAlreadyChanged);
    function commitAccount(address _address) external returns (bool _wasAccountCommitted);
    function incrementTotalUncommittedAccounts() external;
    function getTotalUncommittedAccounts() external view returns (uint256 _total);
    function wasAccountChanged(address _address) external view returns (bool);
    function wasAccountCommitted(address _address) external view returns (bool);


    /************************************
     * Public Functions: Storage Access *
     ************************************/

    function putContractStorage(address _contract, bytes32 _key, bytes32 _value) external;
    function getContractStorage(address _contract, bytes32 _key) external view returns (bytes32 _value);
    function hasContractStorage(address _contract, bytes32 _key) external view returns (bool _exists);
    function testAndSetContractStorageLoaded(address _contract, bytes32 _key) external returns (bool _wasContractStorageAlreadyLoaded);
    function testAndSetContractStorageChanged(address _contract, bytes32 _key) external returns (bool _wasContractStorageAlreadyChanged);
    function commitContractStorage(address _contract, bytes32 _key) external returns (bool _wasContractStorageCommitted);
    function incrementTotalUncommittedContractStorage() external;
    function getTotalUncommittedContractStorage() external view returns (uint256 _total);
    function wasContractStorageChanged(address _contract, bytes32 _key) external view returns (bool);
    function wasContractStorageCommitted(address _contract, bytes32 _key) external view returns (bool);
}

// SPDX-License-Identifier: MIT
pragma solidity >0.5.0 <0.8.0;

/**
 * @title iOVM_DeployerWhitelist
 */
interface iOVM_DeployerWhitelist {

    /********************
     * Public Functions *
     ********************/

    function initialize(address _owner, bool _allowArbitraryDeployment) external;
    function owner() external returns (address _owner);
    function setWhitelistedDeployer(address _deployer, bool _isWhitelisted) external;
    function setOwner(address _newOwner) external;
    function setAllowArbitraryDeployment(bool _allowArbitraryDeployment) external;
    function enableArbitraryContractDeployment() external;
    function isDeployerAllowed(address _deployer) external returns (bool _allowed);
}

// SPDX-License-Identifier: MIT
pragma solidity >0.5.0 <0.8.0;
pragma experimental ABIEncoderV2;

/* Library Imports */
import { Lib_RLPReader } from "../rlp/Lib_RLPReader.sol";
import { Lib_RLPWriter } from "../rlp/Lib_RLPWriter.sol";
import { Lib_BytesUtils } from "../utils/Lib_BytesUtils.sol";
import { Lib_Bytes32Utils } from "../utils/Lib_Bytes32Utils.sol";

/**
 * @title Lib_OVMCodec
 */
library Lib_OVMCodec {

    /*********
     * Enums *
     *********/

    enum QueueOrigin {
        SEQUENCER_QUEUE,
        L1TOL2_QUEUE
    }


    /***********
     * Structs *
     ***********/

    struct Account {
        uint256 nonce;
        uint256 balance;
        bytes32 storageRoot;
        bytes32 codeHash;
        address ethAddress;
        bool isFresh;
    }

    struct EVMAccount {
        uint256 nonce;
        uint256 balance;
        bytes32 storageRoot;
        bytes32 codeHash;
    }

    struct ChainBatchHeader {
        uint256 batchIndex;
        bytes32 batchRoot;
        uint256 batchSize;
        uint256 prevTotalElements;
        bytes extraData;
    }

    struct ChainInclusionProof {
        uint256 index;
        bytes32[] siblings;
    }

    struct Transaction {
        uint256 timestamp;
        uint256 blockNumber;
        QueueOrigin l1QueueOrigin;
        address l1TxOrigin;
        address entrypoint;
        uint256 gasLimit;
        bytes data;
    }

    struct TransactionChainElement {
        bool isSequenced;
        uint256 queueIndex;  // QUEUED TX ONLY
        uint256 timestamp;   // SEQUENCER TX ONLY
        uint256 blockNumber; // SEQUENCER TX ONLY
        bytes txData;        // SEQUENCER TX ONLY
    }

    struct QueueElement {
        bytes32 transactionHash;
        uint40 timestamp;
        uint40 blockNumber;
    }


    /**********************
     * Internal Functions *
     **********************/

    /**
     * Encodes a standard OVM transaction.
     * @param _transaction OVM transaction to encode.
     * @return Encoded transaction bytes.
     */
    function encodeTransaction(
        Transaction memory _transaction
    )
        internal
        pure
        returns (
            bytes memory
        )
    {
        return abi.encodePacked(
            _transaction.timestamp,
            _transaction.blockNumber,
            _transaction.l1QueueOrigin,
            _transaction.l1TxOrigin,
            _transaction.entrypoint,
            _transaction.gasLimit,
            _transaction.data
        );
    }

    /**
     * Hashes a standard OVM transaction.
     * @param _transaction OVM transaction to encode.
     * @return Hashed transaction
     */
    function hashTransaction(
        Transaction memory _transaction
    )
        internal
        pure
        returns (
            bytes32
        )
    {
        return keccak256(encodeTransaction(_transaction));
    }

    /**
     * Converts an OVM account to an EVM account.
     * @param _in OVM account to convert.
     * @return Converted EVM account.
     */
    function toEVMAccount(
        Account memory _in
    )
        internal
        pure
        returns (
            EVMAccount memory
        )
    {
        return EVMAccount({
            nonce: _in.nonce,
            balance: _in.balance,
            storageRoot: _in.storageRoot,
            codeHash: _in.codeHash
        });
    }

    /**
     * @notice RLP-encodes an account state struct.
     * @param _account Account state struct.
     * @return RLP-encoded account state.
     */
    function encodeEVMAccount(
        EVMAccount memory _account
    )
        internal
        pure
        returns (
            bytes memory
        )
    {
        bytes[] memory raw = new bytes[](4);

        // Unfortunately we can't create this array outright because
        // Lib_RLPWriter.writeList will reject fixed-size arrays. Assigning
        // index-by-index circumvents this issue.
        raw[0] = Lib_RLPWriter.writeBytes(
            Lib_Bytes32Utils.removeLeadingZeros(
                bytes32(_account.nonce)
            )
        );
        raw[1] = Lib_RLPWriter.writeBytes(
            Lib_Bytes32Utils.removeLeadingZeros(
                bytes32(_account.balance)
            )
        );
        raw[2] = Lib_RLPWriter.writeBytes(abi.encodePacked(_account.storageRoot));
        raw[3] = Lib_RLPWriter.writeBytes(abi.encodePacked(_account.codeHash));

        return Lib_RLPWriter.writeList(raw);
    }

    /**
     * @notice Decodes an RLP-encoded account state into a useful struct.
     * @param _encoded RLP-encoded account state.
     * @return Account state struct.
     */
    function decodeEVMAccount(
        bytes memory _encoded
    )
        internal
        pure
        returns (
            EVMAccount memory
        )
    {
        Lib_RLPReader.RLPItem[] memory accountState = Lib_RLPReader.readList(_encoded);

        return EVMAccount({
            nonce: Lib_RLPReader.readUint256(accountState[0]),
            balance: Lib_RLPReader.readUint256(accountState[1]),
            storageRoot: Lib_RLPReader.readBytes32(accountState[2]),
            codeHash: Lib_RLPReader.readBytes32(accountState[3])
        });
    }

    /**
     * Calculates a hash for a given batch header.
     * @param _batchHeader Header to hash.
     * @return Hash of the header.
     */
    function hashBatchHeader(
        Lib_OVMCodec.ChainBatchHeader memory _batchHeader
    )
        internal
        pure
        returns (
            bytes32
        )
    {
        return keccak256(
            abi.encode(
                _batchHeader.batchRoot,
                _batchHeader.batchSize,
                _batchHeader.prevTotalElements,
                _batchHeader.extraData
            )
        );
    }
}

// SPDX-License-Identifier: MIT
pragma solidity >0.5.0 <0.8.0;

/**
 * @title Lib_PredeployAddresses
 */
library Lib_PredeployAddresses {
    address internal constant L2_TO_L1_MESSAGE_PASSER = 0x4200000000000000000000000000000000000000;
    address internal constant L1_MESSAGE_SENDER = 0x4200000000000000000000000000000000000001;
    address internal constant DEPLOYER_WHITELIST = 0x4200000000000000000000000000000000000002;
    address internal constant ECDSA_CONTRACT_ACCOUNT = 0x4200000000000000000000000000000000000003;
    address internal constant SEQUENCER_ENTRYPOINT = 0x4200000000000000000000000000000000000005;
    address payable internal constant OVM_ETH = 0x4200000000000000000000000000000000000006;
    address internal constant L2_CROSS_DOMAIN_MESSENGER = 0x4200000000000000000000000000000000000007;
    address internal constant LIB_ADDRESS_MANAGER = 0x4200000000000000000000000000000000000008;
    address internal constant PROXY_EOA = 0x4200000000000000000000000000000000000009;
    address internal constant EXECUTION_MANAGER_WRAPPER = 0x420000000000000000000000000000000000000B;
    address internal constant SEQUENCER_FEE_WALLET = 0x4200000000000000000000000000000000000011;
    address internal constant ERC1820_REGISTRY = 0x1820a4B7618BdE71Dce8cdc73aAB6C95905faD24;
    address internal constant L2_STANDARD_BRIDGE = 0x4200000000000000000000000000000000000010;
}

// SPDX-License-Identifier: MIT
pragma solidity >0.5.0 <0.8.0;

/* External Imports */
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title Lib_AddressManager
 */
contract Lib_AddressManager is Ownable {

    /**********
     * Events *
     **********/

    event AddressSet(
        string indexed _name,
        address _newAddress,
        address _oldAddress
    );


    /*************
     * Variables *
     *************/

    mapping (bytes32 => address) private addresses;


    /********************
     * Public Functions *
     ********************/

    /**
     * Changes the address associated with a particular name.
     * @param _name String name to associate an address with.
     * @param _address Address to associate with the name.
     */
    function setAddress(
        string memory _name,
        address _address
    )
        external
        onlyOwner
    {
        bytes32 nameHash = _getNameHash(_name);
        address oldAddress = addresses[nameHash];
        addresses[nameHash] = _address;

        emit AddressSet(
            _name,
            _address,
            oldAddress
        );
    }

    /**
     * Retrieves the address associated with a given name.
     * @param _name Name to retrieve an address for.
     * @return Address associated with the given name.
     */
    function getAddress(
        string memory _name
    )
        external
        view
        returns (
            address
        )
    {
        return addresses[_getNameHash(_name)];
    }


    /**********************
     * Internal Functions *
     **********************/

    /**
     * Computes the hash of a name.
     * @param _name Name to compute a hash for.
     * @return Hash of the given name.
     */
    function _getNameHash(
        string memory _name
    )
        internal
        pure
        returns (
            bytes32
        )
    {
        return keccak256(abi.encodePacked(_name));
    }
}

// SPDX-License-Identifier: MIT
pragma solidity >0.5.0 <0.8.0;

/* Library Imports */
import { Lib_AddressManager } from "./Lib_AddressManager.sol";

/**
 * @title Lib_AddressResolver
 */
abstract contract Lib_AddressResolver {

    /*************
     * Variables *
     *************/

    Lib_AddressManager public libAddressManager;


    /***************
     * Constructor *
     ***************/

    /**
     * @param _libAddressManager Address of the Lib_AddressManager.
     */
    constructor(
        address _libAddressManager
    ) {
        libAddressManager = Lib_AddressManager(_libAddressManager);
    }


    /********************
     * Public Functions *
     ********************/

    /**
     * Resolves the address associated with a given name.
     * @param _name Name to resolve an address for.
     * @return Address associated with the given name.
     */
    function resolve(
        string memory _name
    )
        public
        view
        returns (
            address
        )
    {
        return libAddressManager.getAddress(_name);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity >0.5.0 <0.8.0;

/**
 * @title Lib_RLPReader
 * @dev Adapted from "RLPReader" by Hamdi Allam ([email protected]).
 */
library Lib_RLPReader {

    /*************
     * Constants *
     *************/

    uint256 constant internal MAX_LIST_LENGTH = 32;


    /*********
     * Enums *
     *********/

    enum RLPItemType {
        DATA_ITEM,
        LIST_ITEM
    }


    /***********
     * Structs *
     ***********/

    struct RLPItem {
        uint256 length;
        uint256 ptr;
    }


    /**********************
     * Internal Functions *
     **********************/

    /**
     * Converts bytes to a reference to memory position and length.
     * @param _in Input bytes to convert.
     * @return Output memory reference.
     */
    function toRLPItem(
        bytes memory _in
    )
        internal
        pure
        returns (
            RLPItem memory
        )
    {
        uint256 ptr;
        assembly {
            ptr := add(_in, 32)
        }

        return RLPItem({
            length: _in.length,
            ptr: ptr
        });
    }

    /**
     * Reads an RLP list value into a list of RLP items.
     * @param _in RLP list value.
     * @return Decoded RLP list items.
     */
    function readList(
        RLPItem memory _in
    )
        internal
        pure
        returns (
            RLPItem[] memory
        )
    {
        (
            uint256 listOffset,
            ,
            RLPItemType itemType
        ) = _decodeLength(_in);

        require(
            itemType == RLPItemType.LIST_ITEM,
            "Invalid RLP list value."
        );

        // Solidity in-memory arrays can't be increased in size, but *can* be decreased in size by
        // writing to the length. Since we can't know the number of RLP items without looping over
        // the entire input, we'd have to loop twice to accurately size this array. It's easier to
        // simply set a reasonable maximum list length and decrease the size before we finish.
        RLPItem[] memory out = new RLPItem[](MAX_LIST_LENGTH);

        uint256 itemCount = 0;
        uint256 offset = listOffset;
        while (offset < _in.length) {
            require(
                itemCount < MAX_LIST_LENGTH,
                "Provided RLP list exceeds max list length."
            );

            (
                uint256 itemOffset,
                uint256 itemLength,
            ) = _decodeLength(RLPItem({
                length: _in.length - offset,
                ptr: _in.ptr + offset
            }));

            out[itemCount] = RLPItem({
                length: itemLength + itemOffset,
                ptr: _in.ptr + offset
            });

            itemCount += 1;
            offset += itemOffset + itemLength;
        }

        // Decrease the array size to match the actual item count.
        assembly {
            mstore(out, itemCount)
        }

        return out;
    }

    /**
     * Reads an RLP list value into a list of RLP items.
     * @param _in RLP list value.
     * @return Decoded RLP list items.
     */
    function readList(
        bytes memory _in
    )
        internal
        pure
        returns (
            RLPItem[] memory
        )
    {
        return readList(
            toRLPItem(_in)
        );
    }

    /**
     * Reads an RLP bytes value into bytes.
     * @param _in RLP bytes value.
     * @return Decoded bytes.
     */
    function readBytes(
        RLPItem memory _in
    )
        internal
        pure
        returns (
            bytes memory
        )
    {
        (
            uint256 itemOffset,
            uint256 itemLength,
            RLPItemType itemType
        ) = _decodeLength(_in);

        require(
            itemType == RLPItemType.DATA_ITEM,
            "Invalid RLP bytes value."
        );

        return _copy(_in.ptr, itemOffset, itemLength);
    }

    /**
     * Reads an RLP bytes value into bytes.
     * @param _in RLP bytes value.
     * @return Decoded bytes.
     */
    function readBytes(
        bytes memory _in
    )
        internal
        pure
        returns (
            bytes memory
        )
    {
        return readBytes(
            toRLPItem(_in)
        );
    }

    /**
     * Reads an RLP string value into a string.
     * @param _in RLP string value.
     * @return Decoded string.
     */
    function readString(
        RLPItem memory _in
    )
        internal
        pure
        returns (
            string memory
        )
    {
        return string(readBytes(_in));
    }

    /**
     * Reads an RLP string value into a string.
     * @param _in RLP string value.
     * @return Decoded string.
     */
    function readString(
        bytes memory _in
    )
        internal
        pure
        returns (
            string memory
        )
    {
        return readString(
            toRLPItem(_in)
        );
    }

    /**
     * Reads an RLP bytes32 value into a bytes32.
     * @param _in RLP bytes32 value.
     * @return Decoded bytes32.
     */
    function readBytes32(
        RLPItem memory _in
    )
        internal
        pure
        returns (
            bytes32
        )
    {
        require(
            _in.length <= 33,
            "Invalid RLP bytes32 value."
        );

        (
            uint256 itemOffset,
            uint256 itemLength,
            RLPItemType itemType
        ) = _decodeLength(_in);

        require(
            itemType == RLPItemType.DATA_ITEM,
            "Invalid RLP bytes32 value."
        );

        uint256 ptr = _in.ptr + itemOffset;
        bytes32 out;
        assembly {
            out := mload(ptr)

            // Shift the bytes over to match the item size.
            if lt(itemLength, 32) {
                out := div(out, exp(256, sub(32, itemLength)))
            }
        }

        return out;
    }

    /**
     * Reads an RLP bytes32 value into a bytes32.
     * @param _in RLP bytes32 value.
     * @return Decoded bytes32.
     */
    function readBytes32(
        bytes memory _in
    )
        internal
        pure
        returns (
            bytes32
        )
    {
        return readBytes32(
            toRLPItem(_in)
        );
    }

    /**
     * Reads an RLP uint256 value into a uint256.
     * @param _in RLP uint256 value.
     * @return Decoded uint256.
     */
    function readUint256(
        RLPItem memory _in
    )
        internal
        pure
        returns (
            uint256
        )
    {
        return uint256(readBytes32(_in));
    }

    /**
     * Reads an RLP uint256 value into a uint256.
     * @param _in RLP uint256 value.
     * @return Decoded uint256.
     */
    function readUint256(
        bytes memory _in
    )
        internal
        pure
        returns (
            uint256
        )
    {
        return readUint256(
            toRLPItem(_in)
        );
    }

    /**
     * Reads an RLP bool value into a bool.
     * @param _in RLP bool value.
     * @return Decoded bool.
     */
    function readBool(
        RLPItem memory _in
    )
        internal
        pure
        returns (
            bool
        )
    {
        require(
            _in.length == 1,
            "Invalid RLP boolean value."
        );

        uint256 ptr = _in.ptr;
        uint256 out;
        assembly {
            out := byte(0, mload(ptr))
        }

        require(
            out == 0 || out == 1,
            "Lib_RLPReader: Invalid RLP boolean value, must be 0 or 1"
        );

        return out != 0;
    }

    /**
     * Reads an RLP bool value into a bool.
     * @param _in RLP bool value.
     * @return Decoded bool.
     */
    function readBool(
        bytes memory _in
    )
        internal
        pure
        returns (
            bool
        )
    {
        return readBool(
            toRLPItem(_in)
        );
    }

    /**
     * Reads an RLP address value into a address.
     * @param _in RLP address value.
     * @return Decoded address.
     */
    function readAddress(
        RLPItem memory _in
    )
        internal
        pure
        returns (
            address
        )
    {
        if (_in.length == 1) {
            return address(0);
        }

        require(
            _in.length == 21,
            "Invalid RLP address value."
        );

        return address(readUint256(_in));
    }

    /**
     * Reads an RLP address value into a address.
     * @param _in RLP address value.
     * @return Decoded address.
     */
    function readAddress(
        bytes memory _in
    )
        internal
        pure
        returns (
            address
        )
    {
        return readAddress(
            toRLPItem(_in)
        );
    }

    /**
     * Reads the raw bytes of an RLP item.
     * @param _in RLP item to read.
     * @return Raw RLP bytes.
     */
    function readRawBytes(
        RLPItem memory _in
    )
        internal
        pure
        returns (
            bytes memory
        )
    {
        return _copy(_in);
    }


    /*********************
     * Private Functions *
     *********************/

    /**
     * Decodes the length of an RLP item.
     * @param _in RLP item to decode.
     * @return Offset of the encoded data.
     * @return Length of the encoded data.
     * @return RLP item type (LIST_ITEM or DATA_ITEM).
     */
    function _decodeLength(
        RLPItem memory _in
    )
        private
        pure
        returns (
            uint256,
            uint256,
            RLPItemType
        )
    {
        require(
            _in.length > 0,
            "RLP item cannot be null."
        );

        uint256 ptr = _in.ptr;
        uint256 prefix;
        assembly {
            prefix := byte(0, mload(ptr))
        }

        if (prefix <= 0x7f) {
            // Single byte.

            return (0, 1, RLPItemType.DATA_ITEM);
        } else if (prefix <= 0xb7) {
            // Short string.

            uint256 strLen = prefix - 0x80;

            require(
                _in.length > strLen,
                "Invalid RLP short string."
            );

            return (1, strLen, RLPItemType.DATA_ITEM);
        } else if (prefix <= 0xbf) {
            // Long string.
            uint256 lenOfStrLen = prefix - 0xb7;

            require(
                _in.length > lenOfStrLen,
                "Invalid RLP long string length."
            );

            uint256 strLen;
            assembly {
                // Pick out the string length.
                strLen := div(
                    mload(add(ptr, 1)),
                    exp(256, sub(32, lenOfStrLen))
                )
            }

            require(
                _in.length > lenOfStrLen + strLen,
                "Invalid RLP long string."
            );

            return (1 + lenOfStrLen, strLen, RLPItemType.DATA_ITEM);
        } else if (prefix <= 0xf7) {
            // Short list.
            uint256 listLen = prefix - 0xc0;

            require(
                _in.length > listLen,
                "Invalid RLP short list."
            );

            return (1, listLen, RLPItemType.LIST_ITEM);
        } else {
            // Long list.
            uint256 lenOfListLen = prefix - 0xf7;

            require(
                _in.length > lenOfListLen,
                "Invalid RLP long list length."
            );

            uint256 listLen;
            assembly {
                // Pick out the list length.
                listLen := div(
                    mload(add(ptr, 1)),
                    exp(256, sub(32, lenOfListLen))
                )
            }

            require(
                _in.length > lenOfListLen + listLen,
                "Invalid RLP long list."
            );

            return (1 + lenOfListLen, listLen, RLPItemType.LIST_ITEM);
        }
    }

    /**
     * Copies the bytes from a memory location.
     * @param _src Pointer to the location to read from.
     * @param _offset Offset to start reading from.
     * @param _length Number of bytes to read.
     * @return Copied bytes.
     */
    function _copy(
        uint256 _src,
        uint256 _offset,
        uint256 _length
    )
        private
        pure
        returns (
            bytes memory
        )
    {
        bytes memory out = new bytes(_length);
        if (out.length == 0) {
            return out;
        }

        uint256 src = _src + _offset;
        uint256 dest;
        assembly {
            dest := add(out, 32)
        }

        // Copy over as many complete words as we can.
        for (uint256 i = 0; i < _length / 32; i++) {
            assembly {
                mstore(dest, mload(src))
            }

            src += 32;
            dest += 32;
        }

        // Pick out the remaining bytes.
        uint256 mask = 256 ** (32 - (_length % 32)) - 1;
        assembly {
            mstore(
                dest,
                or(
                    and(mload(src), not(mask)),
                    and(mload(dest), mask)
                )
            )
        }

        return out;
    }

    /**
     * Copies an RLP item into bytes.
     * @param _in RLP item to copy.
     * @return Copied bytes.
     */
    function _copy(
        RLPItem memory _in
    )
        private
        pure
        returns (
            bytes memory
        )
    {
        return _copy(_in.ptr, 0, _in.length);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity >0.5.0 <0.8.0;
pragma experimental ABIEncoderV2;

/**
 * @title Lib_RLPWriter
 * @author Bakaoh (with modifications)
 */
library Lib_RLPWriter {

    /**********************
     * Internal Functions *
     **********************/

    /**
     * RLP encodes a byte string.
     * @param _in The byte string to encode.
     * @return The RLP encoded string in bytes.
     */
    function writeBytes(
        bytes memory _in
    )
        internal
        pure
        returns (
            bytes memory
        )
    {
        bytes memory encoded;

        if (_in.length == 1 && uint8(_in[0]) < 128) {
            encoded = _in;
        } else {
            encoded = abi.encodePacked(_writeLength(_in.length, 128), _in);
        }

        return encoded;
    }

    /**
     * RLP encodes a list of RLP encoded byte byte strings.
     * @param _in The list of RLP encoded byte strings.
     * @return The RLP encoded list of items in bytes.
     */
    function writeList(
        bytes[] memory _in
    )
        internal
        pure
        returns (
            bytes memory
        )
    {
        bytes memory list = _flatten(_in);
        return abi.encodePacked(_writeLength(list.length, 192), list);
    }

    /**
     * RLP encodes a string.
     * @param _in The string to encode.
     * @return The RLP encoded string in bytes.
     */
    function writeString(
        string memory _in
    )
        internal
        pure
        returns (
            bytes memory
        )
    {
        return writeBytes(bytes(_in));
    }

    /**
     * RLP encodes an address.
     * @param _in The address to encode.
     * @return The RLP encoded address in bytes.
     */
    function writeAddress(
        address _in
    )
        internal
        pure
        returns (
            bytes memory
        )
    {
        return writeBytes(abi.encodePacked(_in));
    }

    /**
     * RLP encodes a bytes32 value.
     * @param _in The bytes32 to encode.
     * @return _out The RLP encoded bytes32 in bytes.
     */
    function writeBytes32(
        bytes32 _in
    )
        internal
        pure
        returns (
            bytes memory _out
        )
    {
        return writeBytes(abi.encodePacked(_in));
    }

    /**
     * RLP encodes a uint.
     * @param _in The uint256 to encode.
     * @return The RLP encoded uint256 in bytes.
     */
    function writeUint(
        uint256 _in
    )
        internal
        pure
        returns (
            bytes memory
        )
    {
        return writeBytes(_toBinary(_in));
    }

    /**
     * RLP encodes a bool.
     * @param _in The bool to encode.
     * @return The RLP encoded bool in bytes.
     */
    function writeBool(
        bool _in
    )
        internal
        pure
        returns (
            bytes memory
        )
    {
        bytes memory encoded = new bytes(1);
        encoded[0] = (_in ? bytes1(0x01) : bytes1(0x80));
        return encoded;
    }


    /*********************
     * Private Functions *
     *********************/

    /**
     * Encode the first byte, followed by the `len` in binary form if `length` is more than 55.
     * @param _len The length of the string or the payload.
     * @param _offset 128 if item is string, 192 if item is list.
     * @return RLP encoded bytes.
     */
    function _writeLength(
        uint256 _len,
        uint256 _offset
    )
        private
        pure
        returns (
            bytes memory
        )
    {
        bytes memory encoded;

        if (_len < 56) {
            encoded = new bytes(1);
            encoded[0] = byte(uint8(_len) + uint8(_offset));
        } else {
            uint256 lenLen;
            uint256 i = 1;
            while (_len / i != 0) {
                lenLen++;
                i *= 256;
            }

            encoded = new bytes(lenLen + 1);
            encoded[0] = byte(uint8(lenLen) + uint8(_offset) + 55);
            for(i = 1; i <= lenLen; i++) {
                encoded[i] = byte(uint8((_len / (256**(lenLen-i))) % 256));
            }
        }

        return encoded;
    }

    /**
     * Encode integer in big endian binary form with no leading zeroes.
     * @notice TODO: This should be optimized with assembly to save gas costs.
     * @param _x The integer to encode.
     * @return RLP encoded bytes.
     */
    function _toBinary(
        uint256 _x
    )
        private
        pure
        returns (
            bytes memory
        )
    {
        bytes memory b = abi.encodePacked(_x);

        uint256 i = 0;
        for (; i < 32; i++) {
            if (b[i] != 0) {
                break;
            }
        }

        bytes memory res = new bytes(32 - i);
        for (uint256 j = 0; j < res.length; j++) {
            res[j] = b[i++];
        }

        return res;
    }

    /**
     * Copies a piece of memory to another location.
     * @notice From: https://github.com/Arachnid/solidity-stringutils/blob/master/src/strings.sol.
     * @param _dest Destination location.
     * @param _src Source location.
     * @param _len Length of memory to copy.
     */
    function _memcpy(
        uint256 _dest,
        uint256 _src,
        uint256 _len
    )
        private
        pure
    {
        uint256 dest = _dest;
        uint256 src = _src;
        uint256 len = _len;

        for(; len >= 32; len -= 32) {
            assembly {
                mstore(dest, mload(src))
            }
            dest += 32;
            src += 32;
        }

        uint256 mask = 256 ** (32 - len) - 1;
        assembly {
            let srcpart := and(mload(src), not(mask))
            let destpart := and(mload(dest), mask)
            mstore(dest, or(destpart, srcpart))
        }
    }

    /**
     * Flattens a list of byte strings into one byte string.
     * @notice From: https://github.com/sammayo/solidity-rlp-encoder/blob/master/RLPEncode.sol.
     * @param _list List of byte strings to flatten.
     * @return The flattened byte string.
     */
    function _flatten(
        bytes[] memory _list
    )
        private
        pure
        returns (
            bytes memory
        )
    {
        if (_list.length == 0) {
            return new bytes(0);
        }

        uint256 len;
        uint256 i = 0;
        for (; i < _list.length; i++) {
            len += _list[i].length;
        }

        bytes memory flattened = new bytes(len);
        uint256 flattenedPtr;
        assembly { flattenedPtr := add(flattened, 0x20) }

        for(i = 0; i < _list.length; i++) {
            bytes memory item = _list[i];

            uint256 listPtr;
            assembly { listPtr := add(item, 0x20)}

            _memcpy(flattenedPtr, listPtr, item.length);
            flattenedPtr += _list[i].length;
        }

        return flattened;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity >0.5.0 <0.8.0;

/**
 * @title Lib_Byte32Utils
 */
library Lib_Bytes32Utils {

    /**********************
     * Internal Functions *
     **********************/

    /**
     * Converts a bytes32 value to a boolean. Anything non-zero will be converted to "true."
     * @param _in Input bytes32 value.
     * @return Bytes32 as a boolean.
     */
    function toBool(
        bytes32 _in
    )
        internal
        pure
        returns (
            bool
        )
    {
        return _in != 0;
    }

    /**
     * Converts a boolean to a bytes32 value.
     * @param _in Input boolean value.
     * @return Boolean as a bytes32.
     */
    function fromBool(
        bool _in
    )
        internal
        pure
        returns (
            bytes32
        )
    {
        return bytes32(uint256(_in ? 1 : 0));
    }

    /**
     * Converts a bytes32 value to an address. Takes the *last* 20 bytes.
     * @param _in Input bytes32 value.
     * @return Bytes32 as an address.
     */
    function toAddress(
        bytes32 _in
    )
        internal
        pure
        returns (
            address
        )
    {
        return address(uint160(uint256(_in)));
    }

    /**
     * Converts an address to a bytes32.
     * @param _in Input address value.
     * @return Address as a bytes32.
     */
    function fromAddress(
        address _in
    )
        internal
        pure
        returns (
            bytes32
        )
    {
        return bytes32(uint256(_in));
    }

    /**
     * Removes the leading zeros from a bytes32 value and returns a new (smaller) bytes value.
     * @param _in Input bytes32 value.
     * @return Bytes32 without any leading zeros.
     */
    function removeLeadingZeros(
        bytes32 _in
    )
        internal
        pure
        returns (
            bytes memory
        )
    {
        bytes memory out;

        assembly {
            // Figure out how many leading zero bytes to remove.
            let shift := 0
            for { let i := 0 } and(lt(i, 32), eq(byte(i, _in), 0)) { i := add(i, 1) } {
                shift := add(shift, 1)
            }

            // Reserve some space for our output and fix the free memory pointer.
            out := mload(0x40)
            mstore(0x40, add(out, 0x40))

            // Shift the value and store it into the output bytes.
            mstore(add(out, 0x20), shl(mul(shift, 8), _in))

            // Store the new size (with leading zero bytes removed) in the output byte size.
            mstore(out, sub(32, shift))
        }

        return out;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity >0.5.0 <0.8.0;

/**
 * @title Lib_BytesUtils
 */
library Lib_BytesUtils {

    /**********************
     * Internal Functions *
     **********************/

    function slice(
        bytes memory _bytes,
        uint256 _start,
        uint256 _length
    )
        internal
        pure
        returns (
            bytes memory
        )
    {
        require(_length + 31 >= _length, "slice_overflow");
        require(_start + _length >= _start, "slice_overflow");
        require(_bytes.length >= _start + _length, "slice_outOfBounds");

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

    function slice(
        bytes memory _bytes,
        uint256 _start
    )
        internal
        pure
        returns (
            bytes memory
        )
    {
        if (_start >= _bytes.length) {
            return bytes('');
        }

        return slice(_bytes, _start, _bytes.length - _start);
    }

    function toBytes32PadLeft(
        bytes memory _bytes
    )
        internal
        pure
        returns (
            bytes32
        )
    {
        bytes32 ret;
        uint256 len = _bytes.length <= 32 ? _bytes.length : 32;
        assembly {
            ret := shr(mul(sub(32, len), 8), mload(add(_bytes, 32)))
        }
        return ret;
    }

    function toBytes32(
        bytes memory _bytes
    )
        internal
        pure
        returns (
            bytes32
        )
    {
        if (_bytes.length < 32) {
            bytes32 ret;
            assembly {
                ret := mload(add(_bytes, 32))
            }
            return ret;
        }

        return abi.decode(_bytes,(bytes32)); // will truncate if input length > 32 bytes
    }

    function toUint256(
        bytes memory _bytes
    )
        internal
        pure
        returns (
            uint256
        )
    {
        return uint256(toBytes32(_bytes));
    }

    function toUint24(
        bytes memory _bytes,
        uint256 _start
    )
        internal
        pure
        returns (
            uint24
        )
    {
        require(_start + 3 >= _start, "toUint24_overflow");
        require(_bytes.length >= _start + 3 , "toUint24_outOfBounds");
        uint24 tempUint;

        assembly {
            tempUint := mload(add(add(_bytes, 0x3), _start))
        }

        return tempUint;
    }

    function toUint8(
        bytes memory _bytes,
        uint256 _start
    )
        internal
        pure
        returns (
            uint8
        )
    {
        require(_start + 1 >= _start, "toUint8_overflow");
        require(_bytes.length >= _start + 1 , "toUint8_outOfBounds");
        uint8 tempUint;

        assembly {
            tempUint := mload(add(add(_bytes, 0x1), _start))
        }

        return tempUint;
    }

    function toAddress(
        bytes memory _bytes,
        uint256 _start
    )
        internal
        pure
        returns (
            address
        )
    {
        require(_start + 20 >= _start, "toAddress_overflow");
        require(_bytes.length >= _start + 20, "toAddress_outOfBounds");
        address tempAddress;

        assembly {
            tempAddress := div(mload(add(add(_bytes, 0x20), _start)), 0x1000000000000000000000000)
        }

        return tempAddress;
    }

    function toNibbles(
        bytes memory _bytes
    )
        internal
        pure
        returns (
            bytes memory
        )
    {
        bytes memory nibbles = new bytes(_bytes.length * 2);

        for (uint256 i = 0; i < _bytes.length; i++) {
            nibbles[i * 2] = _bytes[i] >> 4;
            nibbles[i * 2 + 1] = bytes1(uint8(_bytes[i]) % 16);
        }

        return nibbles;
    }

    function fromNibbles(
        bytes memory _bytes
    )
        internal
        pure
        returns (
            bytes memory
        )
    {
        bytes memory ret = new bytes(_bytes.length / 2);

        for (uint256 i = 0; i < ret.length; i++) {
            ret[i] = (_bytes[i * 2] << 4) | (_bytes[i * 2 + 1]);
        }

        return ret;
    }

    function equal(
        bytes memory _bytes,
        bytes memory _other
    )
        internal
        pure
        returns (
            bool
        )
    {
        return keccak256(_bytes) == keccak256(_other);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity >0.5.0 <0.8.0;
pragma experimental ABIEncoderV2;

/**
 * @title Lib_ErrorUtils
 */
library Lib_ErrorUtils {

    /**********************
     * Internal Functions *
     **********************/

    /**
     * Encodes an error string into raw solidity-style revert data.
     * (i.e. ascii bytes, prefixed with bytes4(keccak("Error(string))"))
     * Ref: https://docs.soliditylang.org/en/v0.8.2/control-structures.html?highlight=Error(string)#panic-via-assert-and-error-via-require
     * @param _reason Reason for the reversion.
     * @return Standard solidity revert data for the given reason.
     */
    function encodeRevertString(
        string memory _reason
    )
        internal
        pure
        returns (
            bytes memory
        )
    {
        return abi.encodeWithSignature(
            "Error(string)",
            _reason
        );
    }
}

// SPDX-License-Identifier: MIT
// @unsupported: ovm
pragma solidity >0.5.0 <0.8.0;
pragma experimental ABIEncoderV2;

/* Library Imports */
import { Lib_RLPWriter } from "../rlp/Lib_RLPWriter.sol";
import { Lib_Bytes32Utils } from "./Lib_Bytes32Utils.sol";

/**
 * @title Lib_EthUtils
 */
library Lib_EthUtils {

    /**********************
     * Internal Functions *
     **********************/

    /**
     * Gets the code for a given address.
     * @param _address Address to get code for.
     * @param _offset Offset to start reading from.
     * @param _length Number of bytes to read.
     * @return Code read from the contract.
     */
    function getCode(
        address _address,
        uint256 _offset,
        uint256 _length
    )
        internal
        view
        returns (
            bytes memory
        )
    {
        bytes memory code;
        assembly {
            code := mload(0x40)
            mstore(0x40, add(code, add(_length, 0x20)))
            mstore(code, _length)
            extcodecopy(_address, add(code, 0x20), _offset, _length)
        }

        return code;
    }

    /**
     * Gets the full code for a given address.
     * @param _address Address to get code for.
     * @return Full code of the contract.
     */
    function getCode(
        address _address
    )
        internal
        view
        returns (
            bytes memory
        )
    {
        return getCode(
            _address,
            0,
            getCodeSize(_address)
        );
    }

    /**
     * Gets the size of a contract's code in bytes.
     * @param _address Address to get code size for.
     * @return Size of the contract's code in bytes.
     */
    function getCodeSize(
        address _address
    )
        internal
        view
        returns (
            uint256
        )
    {
        uint256 codeSize;
        assembly {
            codeSize := extcodesize(_address)
        }

        return codeSize;
    }

    /**
     * Gets the hash of a contract's code.
     * @param _address Address to get a code hash for.
     * @return Hash of the contract's code.
     */
    function getCodeHash(
        address _address
    )
        internal
        view
        returns (
            bytes32
        )
    {
        bytes32 codeHash;
        assembly {
            codeHash := extcodehash(_address)
        }

        return codeHash;
    }

    /**
     * Creates a contract with some given initialization code.
     * @param _code Contract initialization code.
     * @return Address of the created contract.
     */
    function createContract(
        bytes memory _code
    )
        internal
        returns (
            address
        )
    {
        address created;
        assembly {
            created := create(
                0,
                add(_code, 0x20),
                mload(_code)
            )
        }

        return created;
    }

    /**
     * Computes the address that would be generated by CREATE.
     * @param _creator Address creating the contract.
     * @param _nonce Creator's nonce.
     * @return Address to be generated by CREATE.
     */
    function getAddressForCREATE(
        address _creator,
        uint256 _nonce
    )
        internal
        pure
        returns (
            address
        )
    {
        bytes[] memory encoded = new bytes[](2);
        encoded[0] = Lib_RLPWriter.writeAddress(_creator);
        encoded[1] = Lib_RLPWriter.writeUint(_nonce);

        bytes memory encodedList = Lib_RLPWriter.writeList(encoded);
        return Lib_Bytes32Utils.toAddress(keccak256(encodedList));
    }

    /**
     * Computes the address that would be generated by CREATE2.
     * @param _creator Address creating the contract.
     * @param _bytecode Bytecode of the contract to be created.
     * @param _salt 32 byte salt value mixed into the hash.
     * @return Address to be generated by CREATE2.
     */
    function getAddressForCREATE2(
        address _creator,
        bytes memory _bytecode,
        bytes32 _salt
    )
        internal
        pure
        returns (
            address
        )
    {
        bytes32 hashedData = keccak256(abi.encodePacked(
            byte(0xff),
            _creator,
            _salt,
            keccak256(_bytecode)
        ));

        return Lib_Bytes32Utils.toAddress(hashedData);
    }
}

{
  "evmVersion": "istanbul",
  "libraries": {},
  "metadata": {
    "bytecodeHash": "ipfs",
    "useLiteralContent": true
  },
  "optimizer": {
    "enabled": true,
    "runs": 200
  },
  "remappings": [],
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