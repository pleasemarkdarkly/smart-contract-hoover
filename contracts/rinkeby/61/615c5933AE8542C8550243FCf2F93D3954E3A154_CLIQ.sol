pragma solidity ^0.4.24;

/**
 * Token Smart contract for Staking Platform
 * Token Name: Cliq Token
 * Token Symbol: CLIQ
 * Decimal: 18
 * Initial Supply : 1000000000000
 */

/**
 * @title SafeMath
 * @dev Unsigned math operations with safety checks that revert on error
 */
library SafeMath {
    /**
     * @dev Multiplies two unsigned integers, reverts on overflow.
     */
    function mul(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a == 0) {
            return 0;
        }
        uint256 c = a * b;
        require(c / a == b, "Calculation error");
        return c;
    }

    /**
     * @dev Integer division of two unsigned integers truncating the qu
     * otient, reverts on division by zero.
     */
    function div(uint256 a, uint256 b) internal pure returns (uint256) {
        // Solidity only automatically asserts when dividing by 0
        require(b > 0, "Calculation error");
        uint256 c = a / b;
        // assert(a == b * c + a % b); // There is no case in which this doesn't hold
        return c;
    }

    /**
     * @dev Subtracts two unsigned integers, reverts on overflow (i.e. if subtrahend is greater than minuend).
     */
    function sub(uint256 a, uint256 b) internal pure returns (uint256) {
        require(b <= a, "Calculation error");
        uint256 c = a - b;
        return c;
    }

    /**
     * @dev Adds two unsigned integers, reverts on overflow.
     */
    function add(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 c = a + b;
        require(c >= a, "Calculation error");
        return c;
    }

    /**
     * @dev Divides two unsigned integers and returns the remainder (unsigned integer modulo),
     * reverts when dividing by zero.
     */
    function mod(uint256 a, uint256 b) internal pure returns (uint256) {
        require(b != 0, "Calculation error");
        return a % b;
    }
}

/**
 * @title ERC20 interface
 * @dev see https://eips.ethereum.org/EIPS/eip-20
 */

interface IERC20 {
    function transfer(address to, uint256 value) external returns (bool);

    function approve(address spender, uint256 value) external returns (bool);

    function transferFrom(
        address from,
        address to,
        uint256 value
    ) external returns (bool);

    function totalSupply() external view returns (uint256);

    function balanceOf(address who) external view returns (uint256);

    function allowance(address owner, address spender)
        external
        view
        returns (uint256);

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(
        address indexed owner,
        address indexed spender,
        uint256 value
    );
}

/**
 * @title CLIQ Contract
 */
contract CLIQ is IERC20 {
    using SafeMath for uint256;

    address private _owner; // Variable for Owner of the Contract.
    string private _name; // Variable for Name of the token.
    string private _symbol; // Variable for symbol of the token.
    uint8 private _decimals; // variable to maintain decimal precision of the token.
    uint256 private _totalSupply; // Variable for total supply of token.
    uint256 public airdropcount = 0; // variable to keep track on number of airdrop

    mapping(address => uint256) private _balances;

    mapping(address => mapping(address => uint256)) private _allowed;

    constructor(
        string memory name,
        string memory symbol,
        uint8 decimals,
        uint256 totalSupply,
        address owner
    ) public {
        _name = name;
        _symbol = symbol;
        _decimals = decimals;
        _totalSupply = totalSupply * (10**uint256(decimals));
        _balances[owner] = _totalSupply;
        _owner = owner;
        // _tokenStakePoolAddress = tokenStakePoolAddress;
    }

    /*
     * ----------------------------------------------------------------------------------------------------------------------
     * Functions for owner
     * ----------------------------------------------------------------------------------------------------------------------
     */

    /**
     * @dev get address of smart contract owner
     * @return address of owner
     */
    function getowner() public view returns (address) {
        return _owner;
    }

    /**
     * @dev modifier to check if the message sender is owner
     */
    modifier onlyOwner() {
        require(isOwner(), "You are not authenticate to make this transfer");
        _;
    }

    /**
     * @dev Internal function for modifier
     */
    function isOwner() internal view returns (bool) {
        return msg.sender == _owner;
    }

    /**
     * @dev Transfer ownership of the smart contract. For owner only
     * @return request status
     */
    function transferOwnership(address newOwner)
        public
        onlyOwner
        returns (bool)
    {
        _owner = newOwner;
        return true;
    }

    /*
     * ---------------------------------------------------------------------------------------------------------------------
     * View only functions
     * ---------------------------------------------------------------------------------------------------------------------
     */

    /**
     * @return the name of the token.
     */
    function name() public view returns (string memory) {
        return _name;
    }

    /**
     * @return the symbol of the token.
     */
    function symbol() public view returns (string memory) {
        return _symbol;
    }

    /**
     * @return the number of decimals of the token.
     */
    function decimals() public view returns (uint8) {
        return _decimals;
    }

    /**
     * @dev Total number of tokens in existence.
     */
    function totalSupply() public view returns (uint256) {
        return _totalSupply;
    }

    /**
     * @dev Gets the balance of the specified address.
     * @param owner The address to query the balance of.
     * @return A uint256 representing the amount owned by the passed address.
     */
    function balanceOf(address owner) public view returns (uint256) {
        return _balances[owner];
    }

    /**
     * @dev Function to check the amount of tokens that an owner allowed to a spender.
     * @param owner address The address which owns the funds.
     * @param spender address The address which will spend the funds.
     * @return A uint256 specifying the amount of tokens still available for the spender.
     */
    function allowance(address owner, address spender)
        public
        view
        returns (uint256)
    {
        return _allowed[owner][spender];
    }

    /*
     * -------------------------------------------------------------------------------------------------------------------------
     * Transfer, allow, mint and burn functions
     * -------------------------------------------------------------------------------------------------------------------------
     */

    /**
     * @dev Transfer token to a specified address.
     * @param to The address to transfer to.
     * @param value The amount to be transferred.
     */
    function transfer(address to, uint256 value) public returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }

    /**
     * @dev Transfer tokens from one address to another.
     * @param from address The address which you want to send tokens from
     * @param to address The address which you want to transfer to
     * @param value uint256 the amount of tokens to be transferred
     */
    function transferFrom(
        address from,
        address to,
        uint256 value
    ) public returns (bool) {
        _transfer(from, to, value);
        _approve(from, msg.sender, _allowed[from][msg.sender].sub(value));
        return true;
    }

    /**
     * @dev Transfer token for a specified addresses.
     * @param from The address to transfer from.
     * @param to The address to transfer to.
     * @param value The amount to be transferred.
     */
    function _transfer(
        address from,
        address to,
        uint256 value
    ) internal {
        require(from != address(0), "Invalid from Address");
        require(to != address(0), "Invalid to Address");
        require(value > 0, "Invalid Amount");
        _balances[from] = _balances[from].sub(value);
        _balances[to] = _balances[to].add(value);
        emit Transfer(from, to, value);
    }

    /**
     * @dev Approve the passed address to spend the specified amount of tokens on behalf of msg.sender.
     * @param spender The address which will spend the funds.
     * @param value The amount of tokens to be spent.
     */
    function approve(address spender, uint256 value) public returns (bool) {
        _approve(msg.sender, spender, value);
        return true;
    }

    /**
     * @dev Approve an address to spend another addresses' tokens.
     * @param owner The address that owns the tokens.
     * @param spender The address that will spend the tokens.
     * @param value The number of tokens that can be spent.
     */
    function _approve(
        address owner,
        address spender,
        uint256 value
    ) internal {
        require(spender != address(0), "Invalid address");
        require(owner != address(0), "Invalid address");
        require(value > 0, "Invalid Amount");
        _allowed[owner][spender] = value;
        emit Approval(owner, spender, value);
    }

    /**
     * @dev Increase the amount of tokens that an owner allowed to a spender.
     * @param spender The address which will spend the funds.
     * @param addedValue The amount of tokens to increase the allowance by.
     */
    function increaseAllowance(address spender, uint256 addedValue)
        public
        returns (bool)
    {
        require(addedValue != 0, "Invalid Value");
        _approve(
            msg.sender,
            spender,
            _allowed[msg.sender][spender].add(addedValue)
        );
        return true;
    }

    /**
     * @dev Decrease the amount of tokens that an owner allowed to a spender.
     * @param spender The address which will spend the funds.
     * @param subtractedValue The amount of tokens to decrease the allowance by.
     */
    function decreaseAllowance(address spender, uint256 subtractedValue)
        public
        returns (bool)
    {
        require(subtractedValue != 0, "Invalid Value");
        _approve(
            msg.sender,
            spender,
            _allowed[msg.sender][spender].sub(subtractedValue)
        );
        return true;
    }

    /**
     * @dev Airdrop function to airdrop tokens. Best works upto 50 addresses in one time. Maximum limit is 200 addresses in one time.
     * @param _addresses array of address in serial order
     * @param _amount amount in serial order with respect to address array
     */
    function airdropByOwner(
        address[] memory _addresses,
        uint256[] memory _amount
    ) public onlyOwner returns (bool) {
        require(_addresses.length == _amount.length, "Invalid Array");
        uint256 count = _addresses.length;
        for (uint256 i = 0; i < count; i++) {
            _transfer(msg.sender, _addresses[i], _amount[i]);
            airdropcount = airdropcount + 1;
        }
        return true;
    }

    /**
     * @dev Internal function that burns an amount of the token of a given account.
     * @param account The account whose tokens will be burnt.
     * @param value The amount that will be burnt.
     */
    function _burn(address account, uint256 value) internal {
        require(account != address(0), "Invalid account");
        require(value > 0, "Invalid Amount");
        _totalSupply = _totalSupply.sub(value);
        _balances[account] = _balances[account].sub(value);
        emit Transfer(account, address(0), value);
    }

    /**
     * @dev Burns a specific amount of tokens.
     * @param value The amount of token to be burned.
     */
    function burn(uint256 value) public onlyOwner {
        _burn(msg.sender, value);
    }

    /**
     * Function to mint tokens
     * @param value The amount of tokens to mint.
     */
    function mint(uint256 value) public onlyOwner returns (bool) {
        require(value > 0, "The amount should be greater than 0");
        _balances[msg.sender] = _balances[msg.sender].add(value);
        _totalSupply = _totalSupply.add(value);
        emit Transfer(address(0), msg.sender, value);
        return true;
    }

    //Get BNB balance from this contract
    function getContractBNBBalance() public view returns (uint256) {
        return (address(this).balance);
    }
}

{
  "remappings": [],
  "optimizer": {
    "enabled": false,
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