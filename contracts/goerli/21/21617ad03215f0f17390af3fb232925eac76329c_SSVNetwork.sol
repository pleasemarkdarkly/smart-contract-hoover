// File: contracts/SSVNetwork.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.2;

import "./ISSVNetwork.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

contract SSVNetwork is Initializable, OwnableUpgradeable, ISSVNetwork {
    ISSVRegistry private SSVRegistryContract;
    IERC20 token;

    mapping(bytes => OperatorBalanceSnapshot) internal operatorBalances;
    mapping(bytes => ValidatorUsageSnapshot) internal validatorUsages;

    mapping(address => Balance) public addressBalances;

    bool initialized;

    function initialize(ISSVRegistry _SSVRegistryAddress, IERC20 _token) public virtual override initializer {
        __SSVNetwork_init(_SSVRegistryAddress, _token);
    }

    function __SSVNetwork_init(ISSVRegistry _SSVRegistryAddress, IERC20 _token) internal initializer {
        __Ownable_init_unchained();
        __SSVNetwork_init_unchained(_SSVRegistryAddress, _token);
    }

    function __SSVNetwork_init_unchained(ISSVRegistry _SSVRegistryAddress, IERC20 _token) internal initializer {
        SSVRegistryContract = _SSVRegistryAddress;
        token = _token;
        SSVRegistryContract.initialize();
    }

    modifier onlyValidator(bytes calldata _publicKey) {
        address owner = SSVRegistryContract.getValidatorOwner(_publicKey);
        require(
            owner != address(0),
            "Validator with public key is not exists"
        );
        require(msg.sender == owner, "Caller is not validator owner");
        _;
    }

    modifier onlyOperator(bytes calldata _publicKey) {
        address owner = SSVRegistryContract.getOperatorOwner(_publicKey);
        require(
            owner != address(0),
            "Operator with public key is not exists"
        );
        require(msg.sender == owner, "Caller is not operator owner");
        _;
    }

    // uint256 minValidatorBlockSubscription;

    /**
     * @dev See {ISSVNetwork-updateOperatorFee}.
     */
    function updateOperatorFee(bytes calldata _pubKey, uint256 _fee) onlyOperator(_pubKey) public virtual override {
        updateOperatorBalance(_pubKey);
        SSVRegistryContract.updateOperatorFee(_pubKey, _fee);
    }

    /**
     * @dev See {ISSVNetwork-operatorBalanceOf}.
     */
    function operatorBalanceOf(bytes memory _pubKey) public view override returns (uint256) {
        return operatorBalances[_pubKey].balance +
               SSVRegistryContract.getOperatorCurrentFee(_pubKey) *
               (block.number - operatorBalances[_pubKey].blockNumber) *
               operatorBalances[_pubKey].validatorCount;
    }

    /**
     * @dev See {ISSVNetwork-updateOperatorBalance}.
     */
    function updateOperatorBalance(bytes memory _pubKey) public override {
        OperatorBalanceSnapshot storage balanceSnapshot = operatorBalances[_pubKey];
        balanceSnapshot.balance = operatorBalanceOf(_pubKey);
        balanceSnapshot.blockNumber = block.number;
    }

    function totalBalanceOf(address _ownerAddress) public override view returns (uint256) {
        bytes[] memory validators = SSVRegistryContract.getValidatorsByAddress(_ownerAddress);
        bytes[] memory operators = SSVRegistryContract.getOperatorsByAddress(_ownerAddress);
        uint balance = addressBalances[_ownerAddress].deposited + addressBalances[_ownerAddress].earned;

        for (uint256 index = 0; index < operators.length; ++index) {
            balance += operatorBalanceOf(operators[index]);
        }

        balance -= addressBalances[_ownerAddress].withdrawn + addressBalances[_ownerAddress].used;

        for (uint256 index = 0; index < validators.length; ++index) {
            balance -= validatorUsageOf(validators[index]);
        }

        return balance;
    }

    /**
     * @dev See {ISSVNetwork-registerOperator}.
     */
    function registerOperator(
        string calldata _name,
        bytes calldata _publicKey,
        uint256 _fee
    ) public override {
        SSVRegistryContract.registerOperator(
            _name,
            msg.sender,
            _publicKey,
            _fee
        );
        // trigger update operator fee function
        operatorBalances[_publicKey] = OperatorBalanceSnapshot(block.number, 0, 0);
    }

    /**
     * @dev See {ISSVNetwork-validatorUsageOf}.
     */
    function validatorUsageOf(bytes memory _pubKey) public view override returns (uint256) {
        ValidatorUsageSnapshot storage balanceSnapshot = validatorUsages[_pubKey];
        return balanceSnapshot.balance + SSVRegistryContract.getValidatorUsage(_pubKey, balanceSnapshot.blockNumber, block.number);
    }

    /**
     * @dev See {ISSVNetwork-updateValidatorUsage}.
     */
    function updateValidatorUsage(bytes memory _pubKey) public override {
        ValidatorUsageSnapshot storage usageSnapshot = validatorUsages[_pubKey];
        usageSnapshot.balance = validatorUsageOf(_pubKey);
        usageSnapshot.blockNumber = block.number;
    }

    /**
     * @dev See {ISSVNetwork-registerValidator}.
     */
    // TODO: add transfer tokens logic here based on passed value in function params
    function registerValidator(
        bytes calldata _publicKey,
        bytes[] calldata _operatorPublicKeys,
        bytes[] calldata _sharesPublicKeys,
        bytes[] calldata _encryptedKeys,
        uint256 _tokenAmount
    ) public virtual override {
        // TODO: tokensAmount validation based on calculation operator pub key and minimum period of time
        // for each operatorPubKey: minValidatorBlockSubscription * (fee1 + fee2 + fee3)
        SSVRegistryContract.registerValidator(
            msg.sender,
            _publicKey,
            _operatorPublicKeys,
            _sharesPublicKeys,
            _encryptedKeys
        );
        validatorUsages[_publicKey] = ValidatorUsageSnapshot(block.number, 0);

        for (uint256 index = 0; index < _operatorPublicKeys.length; ++index) {
            bytes calldata operatorPubKey = _operatorPublicKeys[index];
            updateOperatorBalance(operatorPubKey);
            operatorBalances[operatorPubKey].validatorCount++;
        }

        deposit(_tokenAmount);
    }

    function deposit(uint _tokenAmount) public override {
        token.transferFrom(msg.sender, address(this), _tokenAmount);
        addressBalances[msg.sender].deposited += _tokenAmount;
    }

    /**
     * @dev See {ISSVNetwork-updateValidator}.
     */
    function updateValidator(
        bytes calldata _publicKey,
        bytes[] calldata _operatorPublicKeys,
        bytes[] calldata _sharesPublicKeys, 
        bytes[] calldata _encryptedKeys,
        uint256 _tokenAmount
    ) onlyValidator(_publicKey) public virtual override {
        updateValidatorUsage(_publicKey);
        bytes[] memory currentOperatorPubKeys = SSVRegistryContract.getOperatorPubKeysInUse(_publicKey);
        // calculate balances for current operators in use
        for (uint256 index = 0; index < currentOperatorPubKeys.length; ++index) {
            bytes memory operatorPubKey = currentOperatorPubKeys[index];
            updateOperatorBalance(operatorPubKey);
            operatorBalances[operatorPubKey].validatorCount--;
        }

        // calculate balances for new operators in use
        for (uint256 index = 0; index < _operatorPublicKeys.length; ++index) {
            bytes memory operatorPubKey = _operatorPublicKeys[index];
            updateOperatorBalance(operatorPubKey);
            operatorBalances[operatorPubKey].validatorCount++;
        }

        SSVRegistryContract.updateValidator(
            _publicKey,
            _operatorPublicKeys,
            _sharesPublicKeys,
            _encryptedKeys
        );

        deposit(_tokenAmount);
    }

    function unregisterValidator(bytes calldata _publicKey) internal {
        updateValidatorUsage(_publicKey);

        // calculate balances for current operators in use and update their balances
        bytes[] memory currentOperatorPubKeys = SSVRegistryContract.getOperatorPubKeysInUse(_publicKey);
        for (uint256 index = 0; index < currentOperatorPubKeys.length; ++index) {
            bytes memory operatorPubKey = currentOperatorPubKeys[index];
            updateOperatorBalance(operatorPubKey);
            operatorBalances[operatorPubKey].validatorCount--;
        }
    }

    /**
     * @dev See {ISSVNetwork-deleteValidator}.
     */
    function deleteValidator(bytes calldata _publicKey) onlyValidator(_publicKey) public virtual override {
        unregisterValidator(_publicKey);
        address owner = SSVRegistryContract.getValidatorOwner(_publicKey);
        require(totalBalanceOf(owner) > validatorUsageOf(_publicKey), "Not enough balance");
        addressBalances[owner].used += validatorUsageOf(_publicKey);
        delete validatorUsages[_publicKey];
        SSVRegistryContract.deleteValidator(msg.sender, _publicKey);
    }

    /**
     * @dev See {ISSVNetwork-deleteOperator}.
     */
    function deleteOperator(bytes calldata _publicKey) onlyOperator(_publicKey) public virtual override {
        require(operatorBalances[_publicKey].validatorCount == 0, "operator has validators");
        address owner = SSVRegistryContract.getOperatorOwner(_publicKey);
        addressBalances[owner].earned += operatorBalances[_publicKey].balance;
        delete operatorBalances[_publicKey];
        SSVRegistryContract.deleteOperator(msg.sender, _publicKey);
    }

    function activateValidator(bytes calldata _pubKey) override external {
        validatorUsages[_pubKey].blockNumber = block.number;
        // calculate balances for current operators in use and update their balances
        bytes[] memory currentOperatorPubKeys = SSVRegistryContract.getOperatorPubKeysInUse(_pubKey);
        for (uint256 index = 0; index < currentOperatorPubKeys.length; ++index) {
            bytes memory operatorPubKey = currentOperatorPubKeys[index];
            updateOperatorBalance(operatorPubKey);
            operatorBalances[operatorPubKey].validatorCount++;
        }

        SSVRegistryContract.activateValidator(_pubKey);
    }

    function deactivateValidator(bytes calldata _pubKey) override external {
        unregisterValidator(_pubKey);

        SSVRegistryContract.deactivateValidator(_pubKey);
    }

    function activateOperator(bytes calldata _pubKey) override external {
        SSVRegistryContract.activateOperator(_pubKey);
    }

    function deactivateOperator(bytes calldata _pubKey) override external {
        require(operatorBalances[_pubKey].validatorCount == 0, "operator has validators");

        SSVRegistryContract.deactivateOperator(_pubKey);
    }

    function withdraw(uint256 _tokenAmount) override public {
        require(totalBalanceOf(msg.sender) > _tokenAmount, "not enough balance");
        addressBalances[msg.sender].withdrawn += _tokenAmount;
        token.transfer(msg.sender, _tokenAmount);
    }
}

// File: contracts/ISSVNetwork.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.2;

import "./ISSVRegistry.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface ISSVNetwork {
    struct OperatorBalanceSnapshot {
        uint256 blockNumber;
        uint256 validatorCount;
        uint256 balance;
    }

    struct ValidatorUsageSnapshot {
        uint256 blockNumber;
        uint256 balance;
    }

    struct Balance {
        uint256 deposited;
        uint256 withdrawn;
        uint256 earned;
        uint256 used;
    }

    function initialize(ISSVRegistry _SSVRegistryAddress, IERC20 _token) external;

    /**
     * @dev Emitted when the operator validator added.
     * @param ownerAddress The user's ethereum address that is the owner of the operator.
     * @param blockNumber Block number for changes.
     */
    event OperatorValidatorAdded(address ownerAddress, uint256 blockNumber);

    /**
     * @dev Get operator balance by address.
     * @param _publicKey Operator's Public Key.
     */
    function operatorBalanceOf(bytes memory _publicKey) external view returns (uint256);

    /**
     * @dev Registers new operator.
     * @param _name Operator's display name.
     * @param _publicKey Operator's Public Key. Will be used to encrypt secret shares of validators keys.
     */
    function registerOperator(
        string calldata _name,
        bytes calldata _publicKey,
        uint256 _fee
    ) external;

    /**
     * @dev Updates operator's fee by address.
     * @param _publicKey Operator's Public Key.
     * @param _fee The operators's updated fee.
     */
    function updateOperatorFee(bytes calldata _publicKey, uint256 _fee) external;

    /**
     * @dev Get validator usage by address.
     * @param _pubKey The validator's public key.
     */
    function validatorUsageOf(bytes memory _pubKey) external view returns (uint256);

    /**
     * @dev Updates operators's balance.
     * @param _pubKey The operators's public key.
     */
    function updateOperatorBalance(bytes memory _pubKey) external;

    /**
     * @dev Updates validator's usage.
     * @param _pubKey The validator's public key.
     */
    function updateValidatorUsage(bytes calldata _pubKey) external;

    function totalBalanceOf(address _ownerAddress) external view returns (uint256);

    /**
     * @dev Register new validator.
     * @param _publicKey Validator public key.
     * @param _operatorPublicKeys Operator public keys.
     * @param _sharesPublicKeys Shares public keys.
     * @param _encryptedKeys Encrypted private keys.
     */
    function registerValidator(
        bytes calldata _publicKey,
        bytes[] calldata _operatorPublicKeys,
        bytes[] calldata _sharesPublicKeys,
        bytes[] calldata _encryptedKeys,
        uint256 _tokenAmount
    ) external;

    function deposit(uint256 _tokenAmount) external;

    function withdraw(uint256 _tokenAmount) external;

    /**
     * @dev Update validator.
     * @param _publicKey Validator public key.
     * @param _operatorPublicKeys Operator public keys.
     * @param _sharesPublicKeys Shares public keys.
     * @param _encryptedKeys Encrypted private keys.
     */
    function updateValidator(
        bytes calldata _publicKey,
        bytes[] calldata _operatorPublicKeys,
        bytes[] calldata _sharesPublicKeys,
        bytes[] calldata _encryptedKeys,
        uint256 _tokenAmount
    ) external;

    /**
     * @dev Delete validator.
     * @param _publicKey Validator's public key.
     */
    function deleteValidator(bytes calldata _publicKey) external;

    /**
     * @dev Delete operator.
     * @param _publicKey Operator's public key.
     */
    function deleteOperator(bytes calldata _publicKey) external;

    function activateValidator(bytes calldata _pubKey) external;
    function deactivateValidator(bytes calldata _pubKey) external;

    function activateOperator(bytes calldata _pubKey) external;
    function deactivateOperator(bytes calldata _pubKey) external;
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

import "../utils/ContextUpgradeable.sol";
import "../proxy/utils/Initializable.sol";
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
abstract contract OwnableUpgradeable is Initializable, ContextUpgradeable {
    address private _owner;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /**
     * @dev Initializes the contract setting the deployer as the initial owner.
     */
    function __Ownable_init() internal initializer {
        __Context_init_unchained();
        __Ownable_init_unchained();
    }

    function __Ownable_init_unchained() internal initializer {
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
    uint256[49] private __gap;
}

// File: contracts/ISSVRegistry.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.2;

interface ISSVRegistry {
    struct Oess {
        uint256 index;
        bytes operatorPublicKey;
        bytes sharedPublicKey;
        bytes encryptedKey;
    }

    struct Operator {
        string name;
        address ownerAddress;
        bytes publicKey;
        uint256 score;
        bool active;
        uint256 index;
    }

    struct Validator {
        address ownerAddress;
        bytes publicKey;
        Oess[] oess;
        bool active;
        uint256 index;
    }

    struct OperatorFee {
        uint256 blockNumber;
        uint256 fee;
    }

    function initialize() external;

    /**
     * @dev Register new validator.
     * @param _ownerAddress The user's ethereum address that is the owner of the validator.
     * @param _publicKey Validator public key.
     * @param _operatorPublicKeys Operator public keys.
     * @param _sharesPublicKeys Shares public keys.
     * @param _encryptedKeys Encrypted private keys.
     */
    function registerValidator(
        address _ownerAddress,
        bytes calldata _publicKey,
        bytes[] calldata _operatorPublicKeys,
        bytes[] calldata _sharesPublicKeys,
        bytes[] calldata _encryptedKeys
    ) external;

    /**
     * @dev Register new operator.
     * @param _name Operator's display name.
     * @param _ownerAddress Operator's ethereum address that can collect fees.
     * @param _publicKey Operator's Public Key. Will be used to encrypt secret shares of validators keys.
     */
    function registerOperator(
        string calldata _name,
        address _ownerAddress,
        bytes calldata _publicKey,
        uint256 _fee
    ) external;

    /**
     * @dev Gets an operator by public key.
     * @param _publicKey Operator's Public Key.
     */
    function operators(bytes calldata _publicKey)
        external
        returns (
            string memory,
            address,
            bytes memory,
            uint256,
            bool,
            uint256
        );

    function getValidatorOwner(bytes calldata _publicKey) external view returns (address);

    function getOperatorOwner(bytes calldata _publicKey) external view returns (address);

    /**
     * @dev Gets an operator public keys by owner address.
     * @param _ownerAddress Owner Address.
     */
    function getOperatorsByAddress(address _ownerAddress)
        external view
        returns (bytes[] memory);

    /**
     * @dev Gets a validator public keys by owner address.
     * @param _ownerAddress Owner Address.
     */
    function getValidatorsByAddress(address _ownerAddress)
        external view
        returns (bytes[] memory);

    /**
     * @dev Gets an operator public keys by owner address.
     * @param _publicKey Operator's Public Key.
     */
    function getOperatorFee(bytes calldata _publicKey)
        external view
        returns (OperatorFee[] memory);

    /**
     * @dev Emitted when the operator has been added.
     * @param name Opeator's display name.
     * @param ownerAddress Operator's ethereum address that can collect fees.
     * @param publicKey Operator's Public Key. Will be used to encrypt secret shares of validators keys.
     */
    event OperatorAdded(string name, address ownerAddress, bytes publicKey);

    /**
     * @dev Emitted when the operator has been deleted.
     * @param publicKey Operator's Public Key.
     */
    event OperatorDeleted(string name, bytes publicKey);

    /**
     * @dev Emitted when the validator has been added.
     * @param ownerAddress The user's ethereum address that is the owner of the validator.
     * @param publicKey The public key of a validator.
     * @param oessList The OESS list for this validator.
     */
    event ValidatorAdded(
        address ownerAddress,
        bytes publicKey,
        Oess[] oessList
    );

    /**
     * @dev Emitted when the validator has been updated.
     * @param ownerAddress The user's ethereum address that is the owner of the validator.
     * @param publicKey The public key of a validator.
     * @param oessList The OESS list for this validator.
     */
    event ValidatorUpdated(
        address ownerAddress,
        bytes publicKey,
        Oess[] oessList
    );

    /**
     * @dev Emitted when the validator has been deleted.
     * @param publicKey Operator's Public Key.
     */
    event ValidatorDeleted(address ownerAddress, bytes publicKey);

    /**
     * @param validatorPublicKey The public key of a validator.
     * @param index Operator index.
     * @param operatorPublicKey Operator public key.
     * @param sharedPublicKey Share public key.
     * @param encryptedKey Encrypted private key.
     */
    event OessAdded(
        bytes validatorPublicKey,
        uint256 index,
        bytes operatorPublicKey,
        bytes sharedPublicKey,
        bytes encryptedKey
    );

    event ValidatorActive(address ownerAddress, bytes publicKey);
    event ValidatorInactive(address ownerAddress, bytes publicKey);

    event OperatorActive(address ownerAddress, bytes publicKey);
    event OperatorInactive(address ownerAddress, bytes publicKey);

    /**
     * @dev Updates a validator in the list.
     * @param _publicKey Validator public key.
     * @param _operatorPublicKeys Operator public keys.
     * @param _sharesPublicKeys Shares public keys.
     * @param _encryptedKeys Encrypted private keys.
     */
    function updateValidator(
        bytes calldata _publicKey,
        bytes[] calldata _operatorPublicKeys,
        bytes[] calldata _sharesPublicKeys,
        bytes[] calldata _encryptedKeys
    ) external;

    /**
     * @dev Deletes a validator from the list.
     * @param _ownerAddress The user's ethereum address that is the owner of the validator.
     * @param _publicKey Validator public key.
     */
    function deleteValidator(
        address _ownerAddress,
        bytes calldata _publicKey
    ) external;

    /**
     * @dev Deletes an operator from the list.
     * @param _ownerAddress The user's ethereum address that is the owner of the operator.
     * @param _publicKey Operator public key.
     */
    function deleteOperator(
        address _ownerAddress,
        bytes calldata _publicKey
    ) external;

    /**
     * @dev Gets operator current fee.
     * @param _operatorPublicKey Operator public key.
     */
    function getOperatorCurrentFee(bytes calldata _operatorPublicKey)
        external view
        returns (uint256);

    /**
     * @dev Gets validator usage fees.
     * @param _pubKey Validator public key.
     * @param _fromBlockNumber from which block number.
     * @param _toBlockNumber to which block number.
     */
    function getValidatorUsage(bytes calldata _pubKey, uint256 _fromBlockNumber, uint256 _toBlockNumber)
        external view
        returns (uint256);

    /**
     * @dev Update an operator fee.
     * @param _pubKey Operator's public key.
     * @param _fee new operator fee.
     */
    function updateOperatorFee(
        bytes calldata _pubKey,
        uint256 _fee
    ) external;

    /**
     * @param pubKey Operator's public key.
     * @param blockNumber from which block number.
     * @param fee updated fee value.
     */
    event OperatorFeeUpdated(
        bytes pubKey,
        uint256 blockNumber,
        uint256 fee
    );

    /**
     * @dev Get operators list which are in use of validator.
     * @param _validatorPubKey Validator public key.
     */
    function getOperatorPubKeysInUse(bytes calldata _validatorPubKey)
        external
        returns (bytes[] memory);

    function activateValidator(bytes calldata _pubKey) external;
    function deactivateValidator(bytes calldata _pubKey) external;

    function activateOperator(bytes calldata _pubKey) external;
    function deactivateOperator(bytes calldata _pubKey) external;
}

// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;
import "../proxy/utils/Initializable.sol";

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
abstract contract ContextUpgradeable is Initializable {
    function __Context_init() internal initializer {
        __Context_init_unchained();
    }

    function __Context_init_unchained() internal initializer {
    }
    function _msgSender() internal view virtual returns (address) {
        return msg.sender;
    }

    function _msgData() internal view virtual returns (bytes calldata) {
        this; // silence state mutability warning without generating bytecode - see https://github.com/ethereum/solidity/issues/2691
        return msg.data;
    }
    uint256[50] private __gap;
}

// SPDX-License-Identifier: MIT

// solhint-disable-next-line compiler-version
pragma solidity ^0.8.0;

/**
 * @dev This is a base contract to aid in writing upgradeable contracts, or any kind of contract that will be deployed
 * behind a proxy. Since a proxied contract can't have a constructor, it's common to move constructor logic to an
 * external initializer function, usually called `initialize`. It then becomes necessary to protect this initializer
 * function so it can only be called once. The {initializer} modifier provided by this contract will have this effect.
 *
 * TIP: To avoid leaving the proxy in an uninitialized state, the initializer function should be called as early as
 * possible by providing the encoded function call as the `_data` argument to {ERC1967Proxy-constructor}.
 *
 * CAUTION: When used with inheritance, manual care must be taken to not invoke a parent initializer twice, or to ensure
 * that all initializers are idempotent. This is not verified automatically as constructors are by Solidity.
 */
abstract contract Initializable {

    /**
     * @dev Indicates that the contract has been initialized.
     */
    bool private _initialized;

    /**
     * @dev Indicates that the contract is in the process of being initialized.
     */
    bool private _initializing;

    /**
     * @dev Modifier to protect an initializer function from being invoked twice.
     */
    modifier initializer() {
        require(_initializing || !_initialized, "Initializable: contract is already initialized");

        bool isTopLevelCall = !_initializing;
        if (isTopLevelCall) {
            _initializing = true;
            _initialized = true;
        }

        _;

        if (isTopLevelCall) {
            _initializing = false;
        }
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
  "libraries": {}
}