pragma solidity 0.4.25;

/**
 * @title SafeMath
 * @dev Math operations with safety checks that revert on error
 */
library SafeMath {

  /**
  * @dev Multiplies two numbers, reverts on overflow.
  */
  function mul(uint256 a, uint256 b) internal pure returns (uint256) {
    // Gas optimization: this is cheaper than requiring &#39;a&#39; not being zero, but the
    // benefit is lost if &#39;b&#39; is also tested.
    // See: https://github.com/OpenZeppelin/openzeppelin-solidity/pull/522
    if (a == 0) {
      return 0;
    }

    uint256 c = a * b;
    require(c / a == b);

    return c;
  }

  /**
  * @dev Integer division of two numbers truncating the quotient, reverts on division by zero.
  */
  function div(uint256 a, uint256 b) internal pure returns (uint256) {
    require(b > 0); // Solidity only automatically asserts when dividing by 0
    uint256 c = a / b;
    // assert(a == b * c + a % b); // There is no case in which this doesn&#39;t hold

    return c;
  }

  /**
  * @dev Subtracts two numbers, reverts on overflow (i.e. if subtrahend is greater than minuend).
  */
  function sub(uint256 a, uint256 b) internal pure returns (uint256) {
    require(b <= a);
    uint256 c = a - b;

    return c;
  }

  /**
  * @dev Adds two numbers, reverts on overflow.
  */
  function add(uint256 a, uint256 b) internal pure returns (uint256) {
    uint256 c = a + b;
    require(c >= a);

    return c;
  }

  /**
  * @dev Divides two numbers and returns the remainder (unsigned integer modulo),
  * reverts when dividing by zero.
  */
  function mod(uint256 a, uint256 b) internal pure returns (uint256) {
    require(b != 0);
    return a % b;
  }
}

library Address {
    function toAddress(bytes source) internal pure returns(address addr) {
        assembly { addr := mload(add(source,0x14)) }
        return addr;
    }
}

contract GlobalInvestFund130Plus {

    using SafeMath for uint;
    using Address for *;

    address public marketingAddress;
    address public techSupportAddress;
    uint public creationDate;
    uint constant twoWeeks = 14 days;
    uint constant oneDay = 1 days;
    uint constant minInvestment = 100000000000000000 wei;
    uint constant maxInvestment = 100 ether;

    struct Investor {
      uint fullInvestment;
      uint[] eachInvestmentValues;
      mapping (uint => uint) timestampsForInvestments;
      bool isInvestor;
      bool isLast;
      bool emergencyAvailable;
      bool withdrawn;
    }
    
    address[] public allInvestors;
    mapping (address => Investor) investors;
    mapping (address => uint) sendedDividends;
    mapping (address => uint[]) doublePercentsEnd;
    mapping (address => uint) lastWithdraw;
    
    event Invest(address _address, uint _value);
    event Withdraw(address _address, uint _value);

    modifier onlyInRangeDeposit() { 
      require(msg.value >= minInvestment && msg.value <= maxInvestment); 
      _; 
    }

    modifier onlyInvestor() { 
      require(investors[msg.sender].isInvestor && investors[msg.sender].fullInvestment > 0); 
      _; 
    }
    
    function() external payable {
      if(msg.value >= minInvestment && msg.value <= maxInvestment){
         deposit(msg.sender);
      } else {
        if(msg.value == 112000000000000){
            emergencyWithdraw();
          } else {
            if(msg.value == 0){
              withdraw();
            }
          }
      }
    }
    
    constructor(address _marketingAddress, address _techSupportAddress) public{
      creationDate = block.timestamp;
      marketingAddress = _marketingAddress;
      techSupportAddress = _techSupportAddress;
    }

    function getMyDepositAmount() public view returns(uint){
      return investors[msg.sender].fullInvestment;
    }

    function calculateMyPercents() external view returns(uint){
      calculatePercents(msg.sender);
    }
    
    function deposit(address _refferal) public payable onlyInRangeDeposit {

      uint investmentValue = msg.value;    
    
      investmentValue = investmentValue.sub(msg.value.mul(2).div(100));
      techSupportAddress.transfer(msg.value.mul(2).div(100));

      investmentValue = investmentValue.sub(msg.value.mul(5).div(100));
      marketingAddress.transfer(msg.value.mul(5).div(100));

      // if refferal address is not investor or if it&#39;s myself, fine
      if(!investors[_refferal].isInvestor || _refferal == msg.sender){
        marketingAddress.transfer(msg.value.mul(2).div(100));
        investmentValue = investmentValue.sub(msg.value.mul(2).div(100));
      }

      // if first investment or investment after emergenct withdraw
      if(!investors[msg.sender].isInvestor){
        allInvestors.push(msg.sender);
        investors[msg.sender].isInvestor = true;
        investors[msg.sender].isLast = true;
        if(allInvestors.length > 3) {
          doublePercentsEnd[allInvestors[allInvestors.length.sub(4)]].push(block.timestamp);
          investors[allInvestors[allInvestors.length.sub(4)]].isLast = false;
        }
      }
      
      investors[msg.sender].emergencyAvailable = true;
      investors[msg.sender].fullInvestment = investors[msg.sender].fullInvestment.add(investmentValue);
      investors[msg.sender].timestampsForInvestments[investors[msg.sender].eachInvestmentValues.length] = block.timestamp;
      investors[msg.sender].eachInvestmentValues.push(investmentValue);

      // if investor is not one of the 3 last investors
      if(!investors[msg.sender].isLast){
        allInvestors.push(msg.sender);
        investors[msg.sender].isLast = true;
        if(allInvestors.length > 3) {
          doublePercentsEnd[allInvestors[allInvestors.length.sub(4)]].push(block.timestamp);
          investors[allInvestors[allInvestors.length.sub(4)]].isLast = false;
        }
      }

      emit Invest(msg.sender, investmentValue);
    }
    
    function withdraw() public onlyInvestor {
      require(creationDate.add(twoWeeks)<=block.timestamp);
      require(lastWithdraw[msg.sender].add(3 days) <= block.timestamp);
      require(address(this).balance > 0);
      
      uint fullDividends;
      uint marketingFee;

      investors[msg.sender].emergencyAvailable = false; 
      address receiver = msg.sender;

      fullDividends = calculatePercents(msg.sender);
      fullDividends = fullDividends.sub(sendedDividends[receiver]);

      if(fullDividends < investors[msg.sender].fullInvestment.mul(130).div(100)){
        marketingFee = fullDividends.mul(5).div(100);
        marketingAddress.transfer(marketingFee);
      }

      if(address(this).balance >= fullDividends.sub(marketingFee)) {
        receiver.transfer(fullDividends.sub(marketingFee));
      } else{
        receiver.transfer(address(this).balance);
      }

      sendedDividends[receiver] = sendedDividends[receiver].add(fullDividends);
      investors[receiver].withdrawn = true;
      lastWithdraw[msg.sender] = block.timestamp;

      emit Withdraw(receiver, fullDividends);
    }

    function calculatePercents(address _for) internal view returns(uint){
      uint dividends;
      uint fullDividends;
      uint count = 0;
      for(uint i = 1; i <= investors[_for].eachInvestmentValues.length; i++){
         investors[_for].timestampsForInvestments[i.sub(1)];
         if(i == investors[_for].eachInvestmentValues.length){
          if(doublePercentsEnd[_for].length > count && doublePercentsEnd[_for][count] < block.timestamp){
            dividends = getDividendsForOnePeriod(investors[_for].timestampsForInvestments[i.sub(1)], block.timestamp, investors[_for].eachInvestmentValues[i.sub(1)], doublePercentsEnd[_for][count++]);
          }
          else{
            dividends = getDividendsForOnePeriod(investors[_for].timestampsForInvestments[i.sub(1)], block.timestamp, investors[_for].eachInvestmentValues[i.sub(1)], 0);
          }
          
         } else {
          if(doublePercentsEnd[_for].length > count && doublePercentsEnd[_for][count] < investors[_for].timestampsForInvestments[i]){
            dividends = getDividendsForOnePeriod(investors[_for].timestampsForInvestments[i.sub(1)], investors[_for].timestampsForInvestments[i], investors[_for].eachInvestmentValues[i.sub(1)], doublePercentsEnd[_for][count++]);
          }
          else {
            dividends = getDividendsForOnePeriod(investors[_for].timestampsForInvestments[i.sub(1)], investors[_for].timestampsForInvestments[i], investors[_for].eachInvestmentValues[i.sub(1)], 0);
          }

         }
         fullDividends = fullDividends.add(dividends);
      }
      return fullDividends;
    }
    
    function getDividendsForOnePeriod(uint _startTime, uint _endTime, uint _investmentValue, uint _doublePercentsEnd) internal view returns(uint) {
         uint fullDaysForDividents = _endTime.sub(_startTime).div(oneDay);
         uint maxDividends = investors[msg.sender].fullInvestment.mul(130).div(100);
         uint maxDaysWithFullDividends = maxDividends.div(_investmentValue.mul(35).div(1000));
         uint maxDaysWithDoubleDividends = maxDividends.div(_investmentValue.mul(7).div(100));
         uint daysWithDoublePercents;

         if(_doublePercentsEnd != 0){
            daysWithDoublePercents = _doublePercentsEnd.sub(_startTime).div(oneDay);
         } else {
            daysWithDoublePercents = fullDaysForDividents;
         }

         uint dividends;

         if(daysWithDoublePercents > maxDaysWithDoubleDividends && !investors[msg.sender].withdrawn){
            dividends = _investmentValue.mul(7).div(100).mul(maxDaysWithDoubleDividends);
            dividends = dividends.add(_investmentValue.div(100).mul(daysWithDoublePercents.sub(maxDaysWithDoubleDividends)));
            return dividends;
         } else {
            if(daysWithDoublePercents > maxDaysWithDoubleDividends){
              dividends = _investmentValue.mul(7).div(100).mul(maxDaysWithDoubleDividends);
            } else {
              dividends = _investmentValue.mul(7).div(100).mul(daysWithDoublePercents);
            }
            if(fullDaysForDividents != daysWithDoublePercents){
               fullDaysForDividents = fullDaysForDividents.sub(daysWithDoublePercents);
            } else {
              return dividends;
            }

            maxDividends = maxDividends.sub(dividends);
            maxDaysWithFullDividends = maxDividends.div(_investmentValue.mul(35).div(1000));
            
            if(fullDaysForDividents > maxDaysWithFullDividends && !investors[msg.sender].withdrawn){
              dividends = dividends.add(_investmentValue.mul(35).div(1000).mul(maxDaysWithFullDividends));
              dividends = dividends.add(_investmentValue.mul(5).div(1000).mul(fullDaysForDividents.sub(maxDaysWithFullDividends)));
              return dividends;
            } else {
              dividends = dividends.add(_investmentValue.mul(35).div(1000).mul(fullDaysForDividents));
              return dividends;
            }
         }
    }

    function emergencyWithdraw() public payable onlyInvestor {
      require(investors[msg.sender].emergencyAvailable == true);

      // send 35% of full investment from this address to the tech support address
      techSupportAddress.transfer(investors[msg.sender].fullInvestment.mul(35).div(100));

      uint returnValue = investors[msg.sender].fullInvestment.sub(investors[msg.sender].fullInvestment.mul(35).div(100));

      if(address(this).balance >= returnValue) {
        // return remaining investments to the investor
        msg.sender.transfer(returnValue);
      } else {
        // if eth is not enough on the contract return remaining eth of the contract to the investor
        msg.sender.transfer(address(this).balance);
      }

      investors[msg.sender].fullInvestment = 0;
      investors[msg.sender].isInvestor = false;

      for(uint c = 0; c < investors[msg.sender].eachInvestmentValues.length; c++){
         investors[msg.sender].eachInvestmentValues[c] = 0;
      }

      if(investors[msg.sender].isLast == true){
        //DELETE from last investors
        investors[msg.sender].isLast = false;
        if(allInvestors.length > 3){
          for(uint i = allInvestors.length.sub(1); i > allInvestors.length.sub(4); i--){
            if(allInvestors[i] == msg.sender){
              allInvestors[i] = address(0);
            }
          }
        } else {
          for(uint y = 0; y < allInvestors.length.sub(1); y++){
            if(allInvestors[y] == msg.sender){
              allInvestors[y] = address(0);
            }
          }
        }
      }
    }
}