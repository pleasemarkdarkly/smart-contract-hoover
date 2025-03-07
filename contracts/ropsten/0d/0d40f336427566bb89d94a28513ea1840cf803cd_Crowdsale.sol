pragma solidity ^0.4.24;


/*** @title Ownable
 * @dev The Ownable contract has an owner address, and provides basic authorization control
 * functions, this simplifies the implementation of "user permissions".*/

 
 contract Ownable {
  
  address private _owner;

  event OwnershipRenounced(address indexed previousOwner);
  event OwnershipTransferred( address indexed previousOwner, address indexed newOwner);

  /*@dev The Ownable constructor sets the original `owner` of the contract to the sender
   * account.*/
  
  constructor() public {_owner = msg.sender;}

  /*@return the address of the owner.*/
  
  function owner() public view returns(address) {return _owner;}

  /*@dev Throws if called by any account other than the owner.*/
  
  modifier onlyOwner() {require(isOwner());
  _;}

  /*@return true if `msg.sender` is the owner of the contract.*/
  
  function isOwner() public view returns(bool) {return msg.sender == _owner;}

  /*@dev Allows the current owner to relinquish control of the contract.
   * @notice Renouncing to ownership will leave the contract without an owner.
   * It will not be possible to call the functions with the `onlyOwner`
   * modifier anymore.*/
   
  function renounceOwnership() public onlyOwner {
  emit OwnershipRenounced(_owner);
    _owner = address(0);}

  /*@dev Allows the current owner to transfer control of the contract to a newOwner.
   * @param newOwner The address to transfer ownership to.*/
   
  function transferOwnership(address newOwner) public onlyOwner {
    _transferOwnership(newOwner);}

  /*@dev Transfers control of the contract to a newOwner.
   * @param newOwner The address to transfer ownership to.*/
   
  function _transferOwnership(address newOwner) internal {
    require(newOwner != address(0));
    emit OwnershipTransferred(_owner, newOwner);
    _owner = newOwner;}
}

/*@title SafeMath
 * @dev Math operations with safety checks that revert on error*/

 library SafeMath {

  /*@dev Multiplies two numbers, reverts on overflow.*/
  
  function mul(uint256 a, uint256 b) internal pure returns (uint256) {
    // Gas optimization: this is cheaper than requiring &#39;a&#39; not being zero, but the
    // benefit is lost if &#39;b&#39; is also tested.
	
    if (a == 0) {return 0;}

    uint256 c = a * b;
    require(c / a == b);
    return c;}

  /*@dev Integer division of two numbers truncating the quotient, reverts on division by zero.*/
 
 function div(uint256 a, uint256 b) internal pure returns (uint256) {
    require(b > 0); 
	// Solidity only automatically asserts when dividing by 0
    uint256 c = a / b;
    // assert(a == b * c + a % b); 
	// There is no case in which this doesn&#39;t hold
    return c;}

  /*@dev Subtracts two numbers, reverts on overflow (i.e. if subtrahend is greater than minuend).*/
  
  function sub(uint256 a, uint256 b) internal pure returns (uint256) {
    require(b <= a);
    uint256 c = a - b;
    return c;}

  /*@dev Adds two numbers, reverts on overflow.*/
    function add(uint256 a, uint256 b) internal pure returns (uint256) {
    uint256 c = a + b;
    require(c >= a);
    return c;}

  /*@dev Divides two numbers and returns the remainder (unsigned integer modulo),
  * reverts when dividing by zero.*/
  
  function mod(uint256 a, uint256 b) internal pure returns (uint256) {
    require(b != 0);
    return a % b;}
}

/*@title SafeERC20
 * @dev Wrappers around ERC20 operations that throw on failure.
 * To use this library you can add a `using SafeERC20 for ERC20;` statement to your contract,
 * which allows you to call the safe operations as `token.safeTransfer(...)`, etc.*/
 
library SafeERC20 {

function safeTransfer(IERC20 token,address to, uint256 value) internal{
    require(token.transfer(to, value));}

  function safeTransferFrom(IERC20 token, address from,address to,uint256 value) internal {
    require(token.transferFrom(from, to, value));}

  function safeApprove(IERC20 token, address spender, uint256 value) internal {
    require(token.approve(spender, value));}
}

/**
 * @title ERC20 interface
 * @dev see https://github.com/ethereum/EIPs/issues/20
 */
interface IERC20 {
  function totalSupply() external view returns (uint256);
  function balanceOf(address who) external view returns (uint256);
  function allowance(address owner, address spender) external view returns (uint256);
  function transfer(address to, uint256 value) external returns (bool);
  function approve(address spender, uint256 value) external returns (bool);
  function transferFrom(address from, address to, uint256 value) external returns (bool);
  event Transfer(address indexed from, address indexed to, uint256 value);
  event Approval(address indexed owner, address indexed spender,uint256 value);
}

/*@title Standard ERC20 token @dev Implementation of the basic standard token. */
 
 contract ERC20 is IERC20 {
 
 using SafeMath for uint256;
  
  mapping (address => uint256) private _balances;
  mapping (address => mapping (address => uint256)) private _allowed;
  
  uint256 private _totalSupply;

  /*@dev Total number of tokens in existence */
  function totalSupply() public view returns (uint256) { return _totalSupply; }

  /*@dev Gets the balance of the specified address. * @param owner The address to query the balance of.
  * @return An uint256 representing the amount owned by the passed address. */
  
  function balanceOf(address owner) public view returns (uint256) { return _balances[owner];}

  /*@dev Function to check the amount of tokens that an owner allowed to a spender.
   * @param owner address The address which owns the funds.
   * @param spender address The address which will spend the funds.
   * @return A uint256 specifying the amount of tokens still available for the spender. */
  
  function allowance( address owner, address spender) public view returns (uint256) {
    return _allowed[owner][spender]; }

  /*@dev Transfer token for a specified address @param to The address to transfer to.
  * @param value The amount to be transferred. */
  
  function transfer(address to, uint256 value) public returns (bool) {
    require(value <= _balances[msg.sender]);
    require(to != address(0));
    _balances[msg.sender] = _balances[msg.sender].sub(value);
    _balances[to] = _balances[to].add(value);
    emit Transfer(msg.sender, to, value);
    return true;  }

  /*@dev Approve the passed address to spend the specified amount of tokens on behalf of msg.sender.
   * Beware that changing an allowance with this method brings the risk that someone may use both the old
   * and the new allowance by unfortunate transaction ordering. One possible solution to mitigate this
   * race condition is to first reduce the spender&#39;s allowance to 0 and set the desired value afterwards:
    * @param spender The address which will spend the funds.
   * @param value The amount of tokens to be spent. */
  
  function approve(address spender, uint256 value) public returns (bool) {
    require(spender != address(0));
    _allowed[msg.sender][spender] = value;
    emit Approval(msg.sender, spender, value);
    return true; }

  /*@dev Transfer tokens from one address to another
   * @param from address The address which you want to send tokens from
   * @param to address The address which you want to transfer to
   * @param value uint256 the amount of tokens to be transferred*/
  
  function transferFrom(address from, address to, uint256 value ) public returns (bool) {
    require(value <= _balances[from]);
    require(value <= _allowed[from][msg.sender]);
    require(to != address(0));
    _balances[from] = _balances[from].sub(value);
    _balances[to] = _balances[to].add(value);
    _allowed[from][msg.sender] = _allowed[from][msg.sender].sub(value);
    emit Transfer(from, to, value);
    return true; }

  /*@dev Increase the amount of tokens that an owner allowed to a spender.
   * approve should be called when allowed_[_spender] == 0. To increment
   * allowed value is better to use this function to avoid 2 calls (and wait until
   * the first transaction is mined)
   * From MonolithDAO Token.sol
   * @param spender The address which will spend the funds.
   * @param addedValue The amount of tokens to increase the allowance by. */
  
  function increaseAllowance( address spender,  uint256 addedValue ) public returns (bool) {
    require(spender != address(0));
    _allowed[msg.sender][spender] = (
      _allowed[msg.sender][spender].add(addedValue));
    emit Approval(msg.sender, spender, _allowed[msg.sender][spender]);
    return true;  }

  /*@dev Decrease the amount of tokens that an owner allowed to a spender.
   * approve should be called when allowed_[_spender] == 0. To decrement
   * allowed value is better to use this function to avoid 2 calls (and wait until
   * the first transaction is mined)
   * From MonolithDAO Token.sol
   * @param spender The address which will spend the funds.
   * @param subtractedValue The amount of tokens to decrease the allowance by.*/
 
 function decreaseAllowance( address spender, uint256 subtractedValue) public returns (bool) {
    require(spender != address(0));
    _allowed[msg.sender][spender] = ( _allowed[msg.sender][spender].sub(subtractedValue));
    emit Approval(msg.sender, spender, _allowed[msg.sender][spender]);
    return true;}

  /*@dev Internal function that burns an amount of the token of a given * account.
   * @param account The account whose tokens will be burnt.
   * @param amount The amount that will be burnt. */
   
  function _burn(address account, uint256 amount) internal {
    require(account != 0);
    require(amount <= _balances[account]);
    _totalSupply = _totalSupply.sub(amount);
    _balances[account] = _balances[account].sub(amount);
    emit Transfer(account, address(0), amount); }

  /*@dev Internal function that burns an amount of the token of a given
   * account, deducting from the sender&#39;s allowance for said account. Uses the* internal burn function.
   * @param account The account whose tokens will be burnt.
   * @param amount The amount that will be burnt. */
   
  function _burnFrom(address account, uint256 amount) internal {
    require(amount <= _allowed[account][msg.sender]);

    // this function needs to emit an event with the updated approval.
	
    _allowed[account][msg.sender] = _allowed[account][msg.sender].sub( amount);
    _burn(account, amount); }
}

/*@title Burnable Token
 * @dev Token that can be irreversibly burned (destroyed).*/

 contract ERC20Burnable is ERC20 {

  /*@dev Burns a specific amount of tokens. * @param value The amount of token to be burned.*/
  
  function burn(uint256 value) public { _burn(msg.sender, value); }

  /*@dev Burns a specific amount of tokens from the target address and decrements allowance
   * @param from address The address which you want to send tokens from
   * @param value uint256 The amount of token to be burned */
   
  function burnFrom(address from, uint256 value) public { _burnFrom(from, value);}

  /*@dev Overrides ERC20._burn in order for burn and burnFrom to emit * an additional Burn event.*/
  
  function _burn(address who, uint256 value) internal { super._burn(who, value); }
}

/**
 * @title ERC20Detailed token
 * @dev The decimals are only for visualization purposes.
 * All the operations are done using the smallest and indivisible token unit,
 * just as on Ethereum all the operations are done in wei.
 */
contract MCSToken is Ownable, IERC20, ERC20Burnable {
  using SafeERC20 for IERC20;
  mapping (address => uint256) public balances;
  
  string private _name;
  string private _symbol;
  uint8 private _decimals;
  uint256 public totalSupply = (10 ** 8) * (10 ** 18); // hundred million, 18 decimal places;  
  
  function MCS() public onlyOwner {
        balances[msg.sender] = totalSupply;
            }
  constructor(string name, string symbol, uint8 decimals) public {
    _name = name;
    _symbol = symbol;
    _decimals = decimals; }

 
  /*@return the name of the token.*/
  
  function name() public view returns(string) { return _name; }

  /*@return the symbol of the token. */
  
  function symbol() public view returns(string) { return _symbol; }

  /*@return the number of decimals of the token.*/
  
  function decimals() public view returns(uint8) { return _decimals; }

}



/**
 * @title Crowdsale
 * @dev Crowdsale is a base contract for managing a token crowdsale,
 * allowing investors to purchase tokens with ether. This contract implements
 * such functionality in its most fundamental form and can be extended to provide additional
 * functionality and/or custom behavior.
 * The external interface represents the basic interface for purchasing tokens, and conform
 * the base architecture for crowdsales. They are *not* intended to be modified / overridden.
 * The internal interface conforms the extensible and modifiable surface of crowdsales. Override
 * the methods to add functionality. Consider using &#39;super&#39; where appropriate to concatenate
 * behavior.
 */
contract Crowdsale is Ownable, ERC20{
  using SafeMath for uint256;
  using SafeERC20 for IERC20;

  address multisig;

  uint restrictedPercent;

  address restricted;
  // The token being sold
  MCSToken public token;

  uint public start;

  uint public period;

  uint256 public totalSupply;
      
  uint public hardcap;

  uint public softcap;
   // Address where funds are collected 
  address public wallet;
 // How many token units a buyer gets per wei.
  // The rate is the conversion between wei and the smallest and indivisible token unit.
  // So, if you are using a rate of 1 with a ERC20Detailed token with 3 decimals called TOK
  // 1 wei will give you 1 unit, or 0.001 TOK.
  uint256 public rate;
  // Amount of wei raised
  uint256 public weiRaised;

  /*Event for token purchase logging
   * @param purchaser who paid for the tokens
   * @param beneficiary who got the tokens
   * @param value weis paid for purchase
   * @param amount amount of tokens purchased */
   
  event TokensPurchased(address indexed purchaser,address indexed beneficiary,uint256 value,uint256 amount);

  /*@param rate Number of token units a buyer gets per wei
   * @dev The rate is the conversion between wei and the smallest and indivisible
   * token unit. So, if you are using a rate of 1 with a ERC20Detailed token
   * with 3 decimals called TOK, 1 wei will give you 1 unit, or 0.001 TOK.
   * @param wallet Address where collected funds will be forwarded to
   * @param token Address of the token being sold*/
   
// ------------------------------------------------------------------------
// Constructor
// ------------------------------------------------------------------------

  function PRESALE ( ) public  {
    require(rate > 0);
    require(wallet != address(0));
    require(token != address(0));
     token = MCSToken(0x005dd5f95e135cd739945d50113fbe492c43bf2b4b);
     multisig = 0xd0C7eFd2acc5223c5cb0A55e2F1D5f1bB904035d;
     restricted = 0xd0C7eFd2acc5223c5cb0A55e2F1D5f1bB904035d;
     restrictedPercent = 15;
     rate = 189000000000000000000;
     start = 1538352000;
     period = 15;
     hardcap = 2000000000000000000000000;
     softcap = 498393000000000000000000;
	 totalSupply = token.totalSupply();// hundred million, 18 decimal places;
	 wallet = 0xd0C7eFd2acc5223c5cb0A55e2F1D5f1bB904035d;
    }  

  // -----------------------------------------
  // Crowdsale external interface
  // -----------------------------------------
  /*@dev fallback function ***DO NOT OVERRIDE***/
 
 function () external payable {
     buyTokens(msg.sender);
      BonusTokens();
     
 }

  /*@return the token being sold. */
  
  function token() public view returns(MCSToken) {return token;}

  /*@return the address where funds are collected.*/
  
  function wallet() public view returns(address) { return wallet;}

  /*@return the number of token units a buyer gets per wei. */
  
  function rate() public view returns(uint256) {return rate; }

  /*@return the mount of wei raised.*/
  
  function weiRaised() public view returns (uint256) { return weiRaised; }

  /*@dev low level token purchase ***DO NOT OVERRIDE***
   * @param beneficiary Address performing the token purchase*/
   
  
  function buyTokens(address beneficiary) public payable {

    uint256 weiAmount = msg.value;
    _preValidatePurchase(beneficiary, weiAmount);

    // calculate token amount to be created
	
    uint256 tokens = _getTokenAmount(weiAmount);

    // update state
	
    weiRaised = weiRaised.add(weiAmount);

    _processPurchase(beneficiary, tokens);
    emit TokensPurchased( msg.sender, beneficiary, weiAmount, tokens);
    _updatePurchasingState(beneficiary, weiAmount);
    _forwardFunds();
    _postValidatePurchase(beneficiary, weiAmount);
  }
  
   modifier saleIsOn() {
    require(now > start && now < start + period * 1 days);
    _;
  }

  function BonusTokens() public saleIsOn payable {
    multisig.transfer(msg.value);
    uint tokens = rate.mul(msg.value).div(1 ether);
    uint bonusTokens = 0;
    if(now < start + (period * 1 days).div(4)) {
      bonusTokens = tokens.div(4);
    } else if(now >= start + (period * 1 days).div(4) && now < start + (period * 1 days).div(4).mul(2)) {
      bonusTokens = tokens.div(10);
    } else if(now >= start + (period * 1 days).div(4).mul(2) && now < start + (period * 1 days).div(4).mul(3)) {
      bonusTokens = tokens.div(20);
    }
    uint tokensWithBonus = tokens.add(bonusTokens);
    token.transfer(msg.sender, tokensWithBonus);
    uint restrictedTokens = tokens.mul(restrictedPercent).div(100 - restrictedPercent);
    token.transfer(restricted, restrictedTokens);
  }

  // -----------------------------------------
  // Internal interface (extensible)
  // -----------------------------------------
  /*@dev Validation of an incoming purchase. Use require statements to revert state when conditions are not met. Use `super` in contracts that inherit from Crowdsale to extend their validations.
   * Example from CappedCrowdsale.sol&#39;s _preValidatePurchase method:
   *  super._preValidatePurchase(beneficiary, weiAmount); require(weiRaised().add(weiAmount) <= cap);
   * @param beneficiary Address performing the token purchase
   * @param weiAmount Value in wei involved in the purchase*/  
   
   function _preValidatePurchase( address beneficiary, uint256 weiAmount ) internal {
    require(beneficiary != address(0));
    require(weiAmount != 0); }

  /*@dev Validation of an executed purchase. Observe state and use revert statements to undo rollback when valid conditions are not met.
   * @param beneficiary Address performing the token purchase
   * @param weiAmount Value in wei involved in the purchase*/
   
  function _postValidatePurchase( address beneficiary, uint256 weiAmount) internal {
    // optional override
	}

  /*@dev Source of tokens. Override this method to modify the way in which the crowdsale ultimately gets and sends its tokens.
   * @param beneficiary Address performing the token purchase
   * @param tokenAmount Number of tokens to be emitted*/
   
  function _deliverTokens( address beneficiary, uint256 tokenAmount) internal {
    
   token.transfer(beneficiary, tokenAmount); }

  /*@dev Executed when a purchase has been validated and is ready to be executed. Not necessarily emits/sends tokens.
   * @param beneficiary Address receiving the tokens
   * @param tokenAmount Number of tokens to be purchased */
   
  function _processPurchase( address beneficiary, uint256 tokenAmount) internal {
    _deliverTokens(beneficiary, tokenAmount); }

  /*@dev Override for extensions that require an internal state to check for validity (current user contributions, etc.)
   * @param beneficiary Address receiving the tokens
   * @param weiAmount Value in wei involved in the purchase*/
   
  function _updatePurchasingState( address beneficiary, uint256 weiAmount) internal {
    // optional override
  }

  /*@dev Override to extend the way in which ether is converted to tokens.
   * @param weiAmount Value in wei to be converted into tokens
   * @return Number of tokens that can be purchased with the specified _weiAmount*/
  
  function _getTokenAmount(uint256 weiAmount) internal view returns (uint256) {
    return weiAmount.mul(rate); }

  /*@dev Determines how ETH is stored/forwarded on purchases.*/
  
  function _forwardFunds() internal {
    wallet.transfer(msg.value);}
}