pragma solidity ^0.4.24;


/**
 * @title ERC20 interface 
 * 
 */
contract ERC20 {
  function totalSupply() public view returns (uint256);
  function balanceOf(address who) public view returns (uint256);
  function transfer(address to, uint256 value) public returns (bool);
  function allowance(address owner, address spender) public view returns (uint256);
  function transferFrom(address from, address to, uint256 value) public returns (bool);
  function approve(address spender, uint256 value) public returns (bool);
  event Approval(address indexed owner, address indexed spender, uint256 value);
  event Transfer(address indexed from, address indexed to, uint256 value);
}






/**
 * @title SafeMath
 * @dev Math operations with safety checks that throw on error
 */
library SafeMath {

  /**
  * @dev Multiplies two numbers, throws on overflow.
  */
  function mul(uint256 a, uint256 b) internal pure returns (uint256) {
    if (a == 0) {
      return 0;
    }
    uint256 c = a * b;
    assert(c / a == b);
    return c;
  }

  /**
  * @dev Integer division of two numbers, truncating the quotient.
  */
  function div(uint256 a, uint256 b) internal pure returns (uint256) {
    // assert(b > 0); // Solidity automatically throws when dividing by 0
    uint256 c = a / b;
    // assert(a == b * c + a % b); // There is no case in which this doesn&#39;t hold
    return c;
  }

  /**
  * @dev Substracts two numbers, throws on overflow (i.e. if subtrahend is greater than minuend).
  */
  function sub(uint256 a, uint256 b) internal pure returns (uint256) {
    assert(b <= a);
    return a - b;
  }

  /**
  * @dev Adds two numbers, throws on overflow.
  */
  function add(uint256 a, uint256 b) internal pure returns (uint256) {
    uint256 c = a + b;
    assert(c >= a);
    return c;
  }

  function uint2str(uint i) internal pure returns (string){
      if (i == 0) return "0";
      uint j = i;
      uint length;
      while (j != 0){
          length++;
          j /= 10;
      }
      bytes memory bstr = new bytes(length);
      uint k = length - 1;
      while (i != 0){
          bstr[k--] = byte(48 + i % 10);
          i /= 10;
      }
      return string(bstr);
  }

 

  
}



/**
 * @title Ownable
 * @dev The Ownable contract has an owner address, and provides basic authorization control
 * functions, this simplifies the implementation of "user permissions".
 */
contract Ownable {
  address public owner;
  address public adminOwner;

  event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
  /**
   * @dev The Ownable constructor sets the original `owner` of the contract to the sender
   * account.
   */
  constructor() public {
    owner = msg.sender;
    adminOwner = msg.sender;
  }
  /**
   * @dev Throws if called by any account other than the owner.
   */
  modifier onlyOwner() {
    require(msg.sender == owner);
    _;
  }

  /**
   * @dev Throws if called by any account other than the admin.
   */
  modifier onlyAdmin() {
    require(msg.sender == adminOwner);
    _;
  }

  /**
   * @dev Throws if called by any account other than the owner or admin.
   */
  modifier onlyOwnerOrAdmin() {
    require(msg.sender == adminOwner || msg.sender == owner);
    _;
  }

  /**
   * @dev Allows the current owner to transfer control of the contract to a newOwner.
   * @param newOwner The address to transfer ownership to.
   */
  function transferOwnership(address newOwner) public onlyOwner {
    require(newOwner != address(0));
    emit OwnershipTransferred(owner, newOwner);
    owner = newOwner;
  }

  /**
   * @dev Allows the current adminOwner to transfer control of the contract to a newOwner.
   * @param newOwner The address to transfer ownership to.
   */
  function transferAdminOwnership(address newOwner) public onlyOwner {
    require(newOwner != address(0));
    emit OwnershipTransferred(adminOwner, newOwner);
    adminOwner = newOwner;
  }

}




/**
 * @title lockedPrivatesale
 * Contract is not payable.
 * Owner or admin can allocate tokens.
 * Tokens will be released in 3 steps / dates. 
 *
 *
 *
 */
contract lockedPrivatesale is Ownable {
  using SafeMath for uint256;

  uint256 private constant decimalFactor = 10**uint256(18);


  event FundsBooked(address backer, uint256 amount, bool isContribution);
  event FundTransfer(address backer, uint256 amount, bool isContribution);
  event LogTokenClaimed(address indexed _recipient, uint256 _amountClaimed, uint256 _totalAllocated, uint256 _grandTotalClaimed);
  event LogNewAllocation(address indexed _recipient, uint256 _totalAllocated);
  event LogRemoveAllocation(address indexed _recipient, uint256 _tokenAmountRemoved);
  event LogOwnerAllocation(address indexed _recipient, uint256 _totalAllocated);
   

  // Amount of tokens claimed
  uint256 public grandTotalClaimed = 0;

  // The token being sold
  ERC20 public token;

  // Amount of tokens Raised
  uint256 public tokensTotal = 0;

  // Max token amout
  uint256 public hardCap = 0;
  

  //Tokens will be released in 3 steps/dates
  uint256 public step1;
  uint256 public step2;
  uint256 public step3;

  // Buyers total allocation
  mapping (address => uint256) public allocationsTotal;

  // User total Claimed
  mapping (address => uint256) public totalClaimed;

  // List of allocation step 1
  mapping (address => uint256) public allocations1;

  // List of allocation step 2
  mapping (address => uint256) public allocations2;

  // List of allocation step 3
  mapping (address => uint256) public allocations3;

  //Buyers
  mapping(address => bool) public buyers;

  //List of all addresses
  address[] private addresses;
  
 
  constructor(uint256 _step1, uint256 _step2, uint256 _step3, ERC20 _token) public {
     
    require(_token != address(0));


    require(_step1 >= now);
    require(_step2 >= _step1);
    require(_step3 >= _step2);

    step1       = _step1;
    step2       = _step2;
    step3       = _step3;

    token = _token;
  }

  
  /**
   * @dev fallback function ***DO NOT OVERRIDE***
   */
  function () public {
    //Not payable
  }

 
  // @return true if buyer
  function isBuyer(address _buyer) public constant returns (bool) {
      return buyers[_buyer];
  }


  /**
    * @dev Set allocation 
    * @param _recipient 
    * @param _tokenAmount Amount Allocated tokens + 18 decimals
    */
  function setAllocation (address _recipient, uint256 _tokenAmount) onlyOwnerOrAdmin  public{
      require(_tokenAmount > 0);      
      require(_recipient != address(0)); 

      //Check hardCap 
      require(_validateHardCap(_tokenAmount));

      //Allocate tokens
      _setAllocation(_recipient, _tokenAmount);    

      //Increese token amount
      tokensTotal = tokensTotal.add(_tokenAmount);  

      //Logg Allocation
      emit LogOwnerAllocation(_recipient, _tokenAmount);
  }

  /**
    * @dev Set available allocation 
    * @param _recipient 
    *  
    */
  function removeAllocation(address _recipient) onlyOwner  public{         
      require(_recipient != address(0)); 
      require(totalClaimed[_recipient] == 0); //Check if user claimed tokens


      //_recipient total amount
      uint256 _tokenAmountRemoved = allocationsTotal[_recipient];

      //Decreese token amount
      tokensTotal = tokensTotal.sub(_tokenAmountRemoved);

      //Reset allocations
      allocations1[_recipient]      = 0; 
      allocations2[_recipient]      = 0; 
      allocations3[_recipient]      = 0;
      allocationsTotal[_recipient]  = 0; // Remove 

      emit LogRemoveAllocation(_recipient, _tokenAmountRemoved);
  }


 /**
   * @dev Set internal allocation 
   *  _buyer The adress of the buyer
   *  _tokenAmount Amount Allocated tokens + 18 decimals
   */
  function _setAllocation (address _buyer, uint256 _tokenAmount) internal{

      if(!isBuyer(_buyer)){
        //Add buyer to buyers list 
        buyers[_buyer] = true;

        //Add _buyer to addresses list
        addresses.push(_buyer);

        //Init buyer
        allocationsTotal[_buyer] = 0;

      }  

      //Add tokens to buyers allocation
      allocationsTotal[_buyer]  = allocationsTotal[_buyer].add(_tokenAmount); 

      //Spilt amount in 3
      uint256 splitAmount = allocationsTotal[_buyer].div(3);
      uint256 diff        = allocationsTotal[_buyer].sub(splitAmount+splitAmount+splitAmount);


      //Sale steps
      allocations1[_buyer]   = splitAmount;            // step 1 
      allocations2[_buyer]   = splitAmount;            // step 2
      allocations3[_buyer]   = splitAmount.add(diff);  // step 3


      //Logg Allocation
      emit LogNewAllocation(_buyer, _tokenAmount);

  }


  /**
    * @dev Return address available allocation
    * @param _recipient 
    */
  function checkAvailableTokens (address _recipient) public view returns (uint256) {
    //Check have bought tokens
    require(isBuyer(_recipient));

    uint256 availableTokens = 0;

    if(now >= step1  && now >= step2  && now >= step3 ){      
      availableTokens = availableTokens.add(allocations3[_recipient]); 
      availableTokens = availableTokens.add(allocations2[_recipient]);
      availableTokens = availableTokens.add(allocations1[_recipient]);
    } else if(now >= step1  && now >= step2 ){
      availableTokens = availableTokens.add(allocations2[_recipient]);
      availableTokens = availableTokens.add(allocations1[_recipient]); 
    }else if(now >= step1){
      availableTokens = allocations1[_recipient]; 
    } 

    return availableTokens;
  }

  /**
    * @dev Transfer a recipients available allocation to their address
    * @param _recipients Array of addresses to withdraw tokens for
    */
  function distributeManyTokens(address[] _recipients) onlyOwnerOrAdmin public {
    for (uint256 i = 0; i < _recipients.length; i++) {
      distributeTokens( _recipients[i]);
    }
  }

  /**
    * @dev Transfer a recipients available allocation to their address
    * @param _recipient The address to withdraw tokens for
    */
  function distributeTokens(address _recipient) onlyOwnerOrAdmin public {
    //Check date
    require(now >= step1);
    //Check have bought tokens
    require(isBuyer(_recipient));


    uint256 availableTokens = 0;
    
    if(now >= step1  && now >= step2  && now >= step3 ){      

      availableTokens = availableTokens.add(allocations3[_recipient]); 
      availableTokens = availableTokens.add(allocations2[_recipient]);
      availableTokens = availableTokens.add(allocations1[_recipient]);

      //Reset all allocations
      allocations3[_recipient] = 0;
      allocations2[_recipient] = 0;
      allocations1[_recipient] = 0;


    } else if(now >= step1  && now >= step2 ){
      
      availableTokens = availableTokens.add(allocations2[_recipient]);
      availableTokens = availableTokens.add(allocations1[_recipient]); 

      //Reset step 1 & step 2 allocation
      allocations2[_recipient] = 0;
      allocations1[_recipient] = 0;


    }else if(now >= step1){

      availableTokens = allocations1[_recipient];

      //Reset step 1 allocation
      allocations1[_recipient] = 0; 


    }

    require(availableTokens>0);    

    //Check if contract has tokens
    require(token.balanceOf(this)>=availableTokens);
    //Transfer tokens
    require(token.transfer(_recipient, availableTokens));

    //Add claimed tokens to totalClaimed
    totalClaimed[_recipient] = totalClaimed[_recipient].add(availableTokens);

    //Add claimed tokens to grandTotalClaimed
    grandTotalClaimed = grandTotalClaimed.add(availableTokens);

    emit LogTokenClaimed(_recipient, availableTokens, allocationsTotal[_recipient], grandTotalClaimed);
  }


   


  // @return false is hardcap is reached
  function _validateHardCap(uint256 _tokenAmount) internal view returns (bool) {
      if(tokensTotal.add(_tokenAmount)>hardCap){
        //If tokensSold is more then hardCap return false
        return false;
      }else{
        //If tokensSold is less then hardCap return true
        return true;
      }
  }


  
  function returnTokensListOfAddresses() onlyOwnerOrAdmin public view returns (address[]) {    
    return addresses;
  }

   

  // Allow transfer of tokens back to owner or reserve wallet
  function returnTokens() public onlyOwner {
    uint256 balance = token.balanceOf(this);
    require(token.transfer(owner, balance));
  }

  // Owner can transfer other tokens that are sent here by mistake
  function refundOtherTokens(address _recipient, ERC20 _token) public onlyOwner {
    require(_token != token);
    uint256 balance = _token.balanceOf(this);
    require(_token.transfer(_recipient, balance));
  }


}


/**
 * @title EDPrivateSale
 * @dev Only owner or admin can allocate tokens. Tokens can be booked in advanced without the token contract.
 * Tokens will be released in 3 steps / dates. 
 * A token needs to be attached to this contract and this contract needs to have balance to be able to send tokens to collector
 *
 *
*/
contract EDPrivateSale is lockedPrivatesale {
  constructor(
    uint256 _step1, 
    uint256 _step2, 
    uint256 _step3,    
    ERC20 _token
  ) public lockedPrivatesale(_step1, _step2, _step3, _token) {

    // 75,000,000 tokens
    hardCap = 75000000 * (10**uint256(18)); 

  }
}